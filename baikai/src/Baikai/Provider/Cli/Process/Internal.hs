{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | Internal batch-process ownership shared by the vendor adapters. Not
-- covered by the public PVP interface. POSIX groups contain inherited children,
-- not processes deliberately escaping into another group or session.
module Baikai.Provider.Cli.Process.Internal
  ( withOwnedProcess,
    withOwnedWorker,
  )
where

import Control.Concurrent (forkIO, forkIOWithUnmask, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, tryReadMVar)
import Control.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    displayException,
    finally,
    fromException,
    mask,
    onException,
    throwIO,
    try,
  )
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import System.IO (Handle, hClose, stderr)
import System.Process qualified as P
#ifndef mingw32_HOST_OS
import Data.ByteString.Char8 qualified as BS8
import Data.Maybe (mapMaybe)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode (..))
import System.Posix.Process (getProcessStatus)
import System.Posix.Signals (Signal, sigINT, sigTERM, sigKILL, signalProcess, signalProcessGroup)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Types (ProcessID, ProcessGroupID)
import Text.Read (readMaybe)
#endif

-- | Run a callback with ordinary interruptibility, then finish release in a
-- private masked worker. Repeated cancellation interrupts only the join, never
-- release. Every worker exit publishes completion. Preserve the first async
-- exception, including one delivered after a successful callback.
ownedScope :: IO resource -> (resource -> IO ()) -> (resource -> IO a) -> IO a
ownedScope acquire release use = mask $ \restore -> do
  done <- newEmptyMVar
  resource <- acquire
  outcome <- try (restore (use resource))
  _ <- forkIO $ try (release resource) >>= putMVar done
  let initial = case outcome of
        Left e | isAsync e -> Just e
        _ -> Nothing
      join first =
        ((,first) <$> readMVar done) `catch` \e ->
          if isAsync e
            then join (case first of Nothing -> Just e; Just _ -> first)
            else throwIO e
  (cleaned, cancellation) <- join initial
  case cancellation of
    Just e -> do
      -- Cancellation remains asynchronous even if cleanup diagnosed a failure.
      -- Make that exceptional failure visible rather than silently losing it.
      case cleaned of
        Left failure -> void (try (BS.hPut stderr (Text.encodeUtf8 (Text.pack ("baikai CLI cleanup failed: " <> displayException failure <> "\n")))) :: IO (Either SomeException ()))
        Right () -> pure ()
      throwIO e
    Nothing -> case cleaned of
      Left e -> throwIO (e :: SomeException)
      Right () -> either throwIO pure outcome
  where
    isAsync e = case fromException e :: Maybe SomeAsyncException of
      Just _ -> True
      Nothing -> False

-- | The supplied join action returns the reader's value or exception. On every
-- scope exit an unfinished reader is cancelled and joined before pipe closure.
withOwnedWorker :: forall a b. IO a -> (IO a -> IO b) -> IO b
withOwnedWorker action use = ownedScope acquire release $ \(_, done) ->
  use (readMVar done >>= either throwIO pure)
  where
    acquire = do
      done <- newEmptyMVar
      tid <- forkIOWithUnmask $ \unmask -> do
        result <- try (unmask action)
        putMVar done (result :: Either SomeException a)
      pure (tid, done)
    release (tid, done) = do
      completed <- tryReadMVar done
      case completed of
        Nothing -> killThread tid
        Just _ -> pure ()
      void (readMVar done)

-- | Own handles, group identity, and synchronous direct-child reaping. Reader
-- scopes must be nested inside this callback, so no reader retains a handle lock
-- when release closes the pipes. Windows has direct-child-only cleanup.
withOwnedProcess ::
  P.CreateProcess ->
  (Maybe Handle -> Maybe Handle -> Maybe Handle -> P.ProcessHandle -> IO a) ->
  IO a
withOwnedProcess spec use = ownedScope (acquireProcess spec) releaseProcess $ \(handles, _) ->
  let (input, output, err, ph) = handles in use input output err ph

type ProcessHandles = (Maybe Handle, Maybe Handle, Maybe Handle, P.ProcessHandle)

#ifdef mingw32_HOST_OS
type GroupIdentity = ()

acquireProcess :: P.CreateProcess -> IO (ProcessHandles, GroupIdentity)
acquireProcess spec = do
  handles <- P.createProcess spec {P.create_group = True}
  pure (handles, ())

releaseProcess :: (ProcessHandles, GroupIdentity) -> IO ()
releaseProcess (handles@(_, _, _, ph), _) =
  (P.terminateProcess ph >> void (P.waitForProcess ph)) `finally` closeHandles handles
#else
type GroupIdentity = (ProcessGroupID, ProcessID)

acquireProcess :: P.CreateProcess -> IO (ProcessHandles, GroupIdentity)
acquireProcess spec = do
  handles@(_, _, _, ph) <- P.createProcess spec
    {P.create_group = True, P.new_session = False, P.delegate_ctlc = False}
  -- No callback can reap the leader before the anchor has joined. Even a
  -- quickly exiting leader is still an unreaped group member at this point.
  anchored <- try $ do
    group <- P.getPid ph >>= maybe (ioError (userError "CLI leader PID unavailable")) pure
    anchor <- throwErrnoIfMinus1 "CLI group anchor" (c_anchor (fromIntegral group))
    pure (group, fromIntegral anchor)
  case anchored of
    Right identity -> pure (handles, identity)
    Left (e :: SomeException) ->
      -- The unreaped leader reserves the group during acquisition failure.
      -- This nested scope also protects failed-acquisition cleanup from repeats.
      ownedScope (pure handles) cleanupFailure (\_ -> throwIO e)
  where
    cleanupFailure handles@(_, _, _, ph) =
      (do
        pid <- P.getPid ph
        forM_ pid $ \group -> terminateGroup group (-1) `onException` signalGroup sigKILL group
        ) `finally` (void (P.waitForProcess ph) `finally` closeHandles handles)

releaseProcess :: (ProcessHandles, GroupIdentity) -> IO ()
releaseProcess (handles@(_, _, _, ph), (group, anchor)) =
  ((terminateGroup group anchor `onException` signalGroup sigKILL group)
    `finally` void (P.waitForProcess ph))
    `finally` (finishAnchor `finally` closeHandles handles)
  where
    finishAnchor = do
      -- Darwin reports EPERM when signalling a zombie-only group/PID.
      -- Signalling is already complete, so we may now reap the anchor.
      status <- getProcessStatus False False anchor
      case status of
        Just _ -> pure ()
        Nothing -> signalPid sigKILL anchor >> void (getProcessStatus True False anchor)
#endif

closeHandles :: ProcessHandles -> IO ()
closeHandles (input, output, err, _) =
  -- finally ensures one failed close cannot skip the other owned descriptors.
  forM_ input hClose `finally` (forM_ output hClose `finally` forM_ err hClose)

#ifndef mingw32_HOST_OS
foreign import ccall safe "baikai_cli_group_anchor" c_anchor :: CInt -> IO CInt

signalGroup :: Signal -> ProcessGroupID -> IO ()
signalGroup signal group = absentOnly (signalProcessGroup signal group)

signalPid :: Signal -> ProcessID -> IO ()
signalPid signal pid = absentOnly (signalProcess signal pid)

-- Only ESRCH is benign. EPERM and all other observation/signal errors propagate.
absentOnly :: IO () -> IO ()
absentOnly action = action `catch` \e -> do
  if isDoesNotExistError e then pure () else throwIO (e :: IOError)

terminateGroup :: ProcessGroupID -> ProcessID -> IO ()
terminateGroup group anchor = do
  live <- runningMembers group anchor
  if null live then pure () else do
    signalGroup sigINT group
    interrupted <- settle 100000
    if interrupted then pure () else do
      signalGroup sigTERM group
      terminated <- settle 500000
      if terminated then pure () else do
        -- The anchor is killed too, but stays unreaped until all observations
        -- and group signals finish. Its zombie membership reserves the PGID.
        signalGroup sigKILL group
        killed <- settle 1000000
        if killed then pure () else ioError (userError "CLI group has live survivors after SIGKILL")
  where
    settle :: Int -> IO Bool
    settle micros = do
      start <- getMonotonicTimeNSec
      let deadline = start + fromIntegral micros * 1000
          poll = do
            members <- runningMembers group anchor
            if null members then pure True else do
              now <- getMonotonicTimeNSec
              if now >= deadline then pure False else threadDelay 10000 >> poll
      poll

-- Darwin and Linux both expose PID, PGID, and process state via POSIX ps.
-- A zombie is no longer running; adopted grandchildren are reaped elsewhere.
-- Never infer successful cleanup from kill(0), which includes zombies.
runningMembers :: ProcessGroupID -> ProcessID -> IO [ProcessID]
runningMembers group anchor = do
  (code, bytes) <- P.withCreateProcess
    (P.proc "/bin/ps" ["-axo", "pid=,pgid=,stat="])
      { P.std_in = P.NoStream, P.std_out = P.CreatePipe, P.std_err = P.CreatePipe }
    $ \_ output err ph -> case (output, err) of
      (Just out, Just errors) -> withOwnedWorker (BS.hGetContents errors) $ \joinErr -> do
        captured <- BS.hGetContents out
        void joinErr
        status <- P.waitForProcess ph
        pure (status, captured)
      _ -> ioError (userError "ps capture handles unavailable")
  case code of
    ExitFailure n -> ioError (userError ("CLI group observation failed: ps exit " <> show n))
    ExitSuccess -> do
      rows <- traverse parseRow (BS8.lines bytes)
      pure (mapMaybe running rows)
  where
    parseRow row = case BS8.words row of
      [pid, pgid, state] -> case (readMaybe (BS8.unpack pid), readMaybe (BS8.unpack pgid)) of
        (Just p, Just g) -> pure (p, g, state)
        _ -> invalid
      _ -> invalid
      where invalid = ioError (userError "CLI group observation: malformed ps row")
    running (pid, pgid, state)
      | pgid == group && pid /= anchor && not (BS8.elem 'Z' state) = Just pid
      | otherwise = Nothing
#endif
