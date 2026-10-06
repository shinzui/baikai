{-# LANGUAGE CPP #-}

module CliProcessSpec (tests) where

import Baikai.Provider.Cli.Internal (ExecutableIdentity (..), executableIdentity)
import Baikai.Provider.Cli.Process.Internal
import CliProcessFixture
import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay, throwTo)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (..), SomeException, finally, fromException, throwIO, try)
import Control.Monad (void)
import Data.ByteString qualified as BS
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering)
import System.Process qualified as P
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
#ifndef mingw32_HOST_OS
tests = testGroup "CliProcessSpec: shared owned process scopes"
  [ testCase "sleeping descendant" $ cancelled False False False,
    testCase "leader exits with descendant holding pipes" $ cancelled False True False,
    testCase "callback reaps leader before cancellation" $ cancelled False True True,
    testCase "SIGKILL-resistant group and repeated cancellation" $ cancelled True False False,
    testCase "normal process exit and direct-child reaping" $ do
      pidCell <- newEmptyMVar
      anchors <- newEmptyMVar
      code <- withOwnedProcess (P.proc "/bin/sh" ["-c", "exit 0"]) $ \_ _ _ ph -> do
        pid <- P.getPid ph
        putMVar pidCell pid
        members <- maybe (assertFailure "missing leader PID") (groupPids . fromIntegral) pid
        putMVar anchors [p | p <- members, Just (fromIntegral p) /= pid]
        P.waitForProcess ph
      code @?= ExitSuccess
      readMVar pidCell >>= maybe (assertFailure "missing leader PID") (\pid -> processState (fromIntegral pid) >>= (@?= ""))
      recordedAnchors <- readMVar anchors
      length recordedAnchors @?= 1
      mapM_ (\pid -> processState pid >>= (@?= "")) recordedAnchors,
    testCase "synchronous callback failure still terminates descendants" $ withFixture False False "" $ \fixture -> do
      pidsCell <- newEmptyMVar
      result <- try $ withOwnedProcess (spec fixture) $ \_ _ _ _ -> do
        awaitReady fixture >>= putMVar pidsCell
        throwIO (userError "callback failed")
      case result :: Either SomeException () of
        Left _ -> readMVar pidsCell >>= assertStopped
        Right () -> assertFailure "callback exception swallowed",
    testCase "successful callback still cleans resistant descendants" $ withFixture True False "" $ \fixture -> do
      pids <- withOwnedProcess (spec fixture) $ \_ _ _ _ -> awaitReady fixture
      assertStopped pids,
    testCase "first cancellation during successful-callback cleanup survives repeats" $
      withFixture True False "" $ \fixture -> do
        returned <- newEmptyMVar
        done <- newEmptyMVar
        let action = withOwnedProcess (spec fixture) $ \_ _ _ _ -> do
              pids <- awaitReady fixture
              putMVar returned pids
        tid <- forkFinally action (putMVar done)
        (do
          ready <- timeout 2000000 (readMVar returned)
          pids <- maybe (assertFailure "callback did not publish readiness within two seconds") pure ready
          threadDelay 50000
          _ <- forkIO (throwTo tid UserInterrupt)
          _ <- forkIO (threadDelay 50000 >> killThread tid)
          terminal <- timeout 3000000 (readMVar done)
          case terminal of
            Just (Left e) -> (fromException e :: Maybe AsyncException) @?= Just UserInterrupt
            _ -> assertFailure "first cancellation during cleanup was lost"
          assertStopped pids
          ) `finally` do
            _ <- forkIO (killThread tid)
            void (timeout 3000000 (readMVar done)),
    testCase "cleanup failure publishes completion and preserves cancellation" $ do
      result <- timeout 2000000 $ try $ withOwnedProcess
        (P.proc "/bin/sh" ["-c", "exit 0"]) {P.std_in = P.CreatePipe}
        $ \input _ _ ph -> case input of
          Nothing -> assertFailure "missing stdin pipe"
          Just pipe -> do
            hSetBuffering pipe (BlockBuffering (Just 4096))
            BS.hPut pipe "pending buffered input"
            void (P.waitForProcess ph)
            -- Releasing stdin flushes to a dead child and fails with EPIPE.
            -- The finalizer must still publish completion and retain cancellation.
            throwIO ThreadKilled
      case result :: Maybe (Either SomeException ()) of
        Just (Left e) -> (fromException e :: Maybe AsyncException) @?= Just ThreadKilled
        _ -> assertFailure "cleanup failure lost cancellation or completion",
    testCase "failed spawn is reported" $ do
      result <- try (withOwnedProcess (P.proc "/nonexistent/baikai-fixture" []) (\_ _ _ _ -> pure ()))
      case result :: Either SomeException () of
        Left _ -> pure ()
        Right () -> assertFailure "spawn unexpectedly succeeded",
    testCase "blocked owned reader is joined before release returns" $ do
      started <- newEmptyMVar
      finished <- newEmptyMVar
      gate <- newEmptyMVar
      withOwnedWorker ((putMVar started () >> readMVar gate) `finally` putMVar finished ()) $ \_ -> readMVar started
      tryReadMVar finished >>= (@?= Just ()),
    testCase "reader error reaches join" $ do
      result <- try (withOwnedWorker (throwIO (userError "reader failed") :: IO ()) id)
      case result :: Either SomeException () of
        Left _ -> pure ()
        Right () -> assertFailure "reader failure swallowed",
    testCase "unrelated sentinel survives group cancellation" $
      withOwnedProcess (P.proc "/bin/sleep" ["30"]) $ \_ _ _ sentinel -> do
        sentinelPid <- P.getPid sentinel
        cancelled False False False
        maybe (assertFailure "sentinel PID missing") (\pid -> processState (fromIntegral pid) >>= assertBool "sentinel stopped" . not . null) sentinelPid,
    testCase "version-probe cancellation owns descendants" $ withFixture False False "" $ \fixture ->
      cancelAndJoin False (executableIdentity (executable fixture)) fixture assertStopped,
    testCase "version-probe timeout owns descendants and reports no version" $ withFixture False False "" $ \fixture -> do
      bounded <- timeout 8000000 (executableIdentity (executable fixture))
      case bounded of
        Nothing -> assertFailure "version timeout failed to finish"
        Just identity -> version identity @?= Nothing
      awaitReady fixture >>= assertStopped
  ]
  where
    spec fixture = (P.proc (executable fixture) [])
      {P.std_in = P.NoStream, P.std_out = P.CreatePipe, P.std_err = P.CreatePipe}
    cancelled resistant early reap = withFixture resistant early "" $ \fixture -> do
      anchorCell <- newEmptyMVar
      let action = withOwnedProcess (spec fixture) $ \_ output err ph -> case (output, err) of
            (Just out, Just errors) -> withOwnedWorker (BS.hGetContents errors) $ \joinErr -> do
              if reap then do
                group <- P.getPid ph >>= maybe (assertFailure "missing group PID") (pure . fromIntegral)
                (_, child) <- awaitReady fixture
                void (P.waitForProcess ph)
                members <- groupPids group
                let anchors = filter (/= child) members
                length anchors @?= 1
                putMVar anchorCell anchors
                writeFile (directory fixture </> "reaped") "ready"
              else pure ()
              _ <- BS.hGetContents out
              void joinErr
            _ -> assertFailure "missing capture handles"
      let readyFixture = if reap then fixture {readyFile = directory fixture </> "reaped"} else fixture
      cancelAndJoin resistant action readyFixture $ \pids -> do
        assertStopped pids
        if reap then readMVar anchorCell >>= mapM_ (\pid -> processState pid >>= (@?= "")) else pure ()

-- Inspect only this invocation's group, and record the anchor while its owner
-- still holds it. Checking it after return proves the private direct child was
-- reaped too, even when the callback reaped the CLI leader itself.
groupPids :: Int -> IO [Int]
groupPids group = do
  (code, out, err) <- P.readProcessWithExitCode "/bin/ps" ["-axo", "pid=,pgid="] ""
  code @?= ExitSuccess
  err @?= ""
  pure [read pid | row <- lines out, [pid, pgid] <- [words row], read pgid == group]
#else
tests = testGroup "CliProcessSpec: Windows direct-child cleanup"
  [testCase "normal direct-child exit" $ do
    code <- withOwnedProcess (P.proc "cmd" ["/c", "exit", "0"]) (\_ _ _ ph -> P.waitForProcess ph)
    code @?= ExitSuccess]
#endif
