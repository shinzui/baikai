{-# LANGUAGE CPP #-}

-- | Real, offline subprocess fixtures shared by core and adapter regressions.
-- Keep the copies in each package identical: each source distribution must
-- contain its own test dependencies.
module CliProcessFixture
  ( Fixture (..),
    withFixture,
    awaitReady,
    assertStopped,
    cancelAndJoin,
    processState,
    writeExecutable,
  )
where

import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (readMVar)
import Control.Concurrent.MVar qualified
import Control.Exception (SomeAsyncException, bracket, finally, fromException, try)
import Control.Monad (forM_, unless, void)
import Data.List (isInfixOf)
import System.Directory (doesFileExist, getPermissions, setOwnerExecutable, setPermissions)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as P
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertBool, assertFailure)
#ifndef mingw32_HOST_OS
import System.Posix.Signals (sigKILL, signalProcess)
#endif

data Fixture = Fixture
  { directory :: FilePath,
    executable :: FilePath,
    parentFile :: FilePath,
    childFile :: FilePath,
    readyFile :: FilePath
  }

-- The optional prefix can implement a successful normal invocation and hang
-- only in --version. Every fixture sleeps 30s so success cannot be natural expiry.
withFixture :: Bool -> Bool -> String -> (Fixture -> IO a) -> IO a
withFixture resistant early prefix use = withSystemTempDirectory "baikai-cli-cancellation" $ \dir -> do
  let sleeper = dir </> "sleeper"
      parent = dir </> "parent"
      child = dir </> "child"
      ready = dir </> "ready"
      body =
        unlines $
          ["#!/bin/sh", prefix]
            <> ["trap '' INT TERM" | resistant]
            <> [ "echo $$ > '" <> parent <> "'",
                 "sh -c 'echo $$ > \"" <> child <> "\"; exec \"" <> sleeper <> "\" 30' &",
                 "while [ ! -s '" <> child <> "' ]; do sleep 0.01; done",
                 "echo ready > '" <> ready <> "'"
               ]
            <> [if early then "exit 0" else "wait"]
  P.callProcess "/bin/ln" ["-s", "/bin/sleep", sleeper]
  exe <- writeExecutable dir "vendor" body
  let fixture = Fixture dir exe parent child ready
  -- Capture process identities before use returns/fails; identity comparison in
  -- emergency cleanup avoids signalling a PID reused after a fixture exits.
  bracket (pure fixture) cleanupFixture use

cleanupFixture :: Fixture -> IO ()
cleanupFixture fixture = forM_ [childFile fixture, parentFile fixture] $ \file -> do
  exists <- doesFileExist file
  if not exists
    then pure ()
    else do
      pid <- read <$> readFile file
      state <- processState pid
      -- Both the script and sleeper executable have this invocation's unique
      -- directory in their command line, including after exec. A reused PID
      -- belonging to a different invocation cannot match that identity.
      (_, identity, _) <- P.readProcessWithExitCode "/bin/ps" ["-p", show pid, "-o", "lstart=,command="] ""
      let ours = (directory fixture <> "/") `isInfixOf` identity
      unless (null state || 'Z' `elem` state || not ours) $ do
        (_, current, _) <- P.readProcessWithExitCode "/bin/ps" ["-p", show pid, "-o", "lstart=,command="] ""
        if current /= identity
          then pure ()
          else do
            killFixturePid pid

killFixturePid :: Int -> IO ()
#ifndef mingw32_HOST_OS
killFixturePid pid = void (try (signalProcess sigKILL (fromIntegral pid)) :: IO (Either IOError ()))
#else
killFixturePid _ = pure ()
#endif

writeExecutable :: FilePath -> String -> String -> IO FilePath
writeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

awaitReady :: Fixture -> IO (Int, Int)
awaitReady fixture = do
  ready <- timeout 2000000 poll
  case ready of
    Nothing -> assertFailure "fixture did not publish readiness within two seconds"
    Just () -> (,) <$> (read <$> readFile (parentFile fixture)) <*> (read <$> readFile (childFile fixture))
  where
    poll = do
      exists <- doesFileExist (readyFile fixture)
      if exists then pure () else threadDelay 10000 >> poll

processState :: Int -> IO String
processState pid = do
  (code, out, err) <- P.readProcessWithExitCode "/bin/ps" ["-p", show pid, "-o", "stat="] ""
  case code of
    ExitSuccess -> pure out
    ExitFailure 1 | null out && null err -> pure ""
    _ -> assertFailure ("ps observation failed: " <> show (code, out, err))

assertStopped :: (Int, Int) -> IO ()
assertStopped (parent, child) = do
  parentState <- processState parent
  assertBool ("direct child remains: " <> parentState) (null parentState)
  childState <- processState child
  assertBool ("descendant is running: " <> childState) (null childState || 'Z' `elem` childState)
  -- Removal of an adopted zombie is diagnostic, distinct from termination.
  unless (null childState) $ do
    removed <- timeout 200000 (let poll = processState child >>= \s -> if null s then pure () else threadDelay 10000 >> poll in poll)
    case removed of
      Nothing -> putStrLn "fixture descendant stopped; adoptive parent has not yet reaped zombie"
      Just () -> pure ()

cancelAndJoin :: Bool -> IO a -> Fixture -> ((Int, Int) -> IO ()) -> IO ()
cancelAndJoin repeated action fixture after = do
  done <- Control.Concurrent.MVar.newEmptyMVar
  tid <- forkFinally (void action) (Control.Concurrent.MVar.putMVar done)
  let stop = void (forkIO (killThread tid))
  ( do
      pids <- awaitReady fixture
      stop
      if repeated then void (forkIO (threadDelay 40000 >> killThread tid)) else pure ()
      -- Keep the original 200ms observation without using it as acknowledgement.
      threadDelay 200000
      diagnostic <- processState (snd pids)
      putStrLn ("descendant state at 200ms: " <> show diagnostic)
      terminal <- timeout 2800000 (readMVar done)
      case terminal of
        Just (Left e) | Just _ <- (fromException e :: Maybe SomeAsyncException) -> after pids
        other -> assertFailure ("expected acknowledged async cancellation within 3s, got " <> show other)
    )
    `finally` do
      stop
      cleanupFixture fixture
      joined <- timeout 3000000 (readMVar done)
      case joined of
        Nothing -> assertFailure "fixture worker failed to finish after emergency cleanup"
        Just _ -> pure ()
