{-# LANGUAGE CPP #-}

-- | Spawn an unattended coding-agent process from a request and an
-- already-rendered command.
--
-- An unattended run has no terminal and no human present: the coding
-- agent drives its own tool loop, changes files inside directories the
-- caller explicitly authorized, and finishes with a process result.
--
-- This module renders no command-line flags. Vendor packages own that
-- translation and produce the 'AgentCommand' this module consumes, so
-- the runner never imports a vendor renderer and can be exercised
-- entirely with hand-written argument vectors.
--
-- A non-zero exit code is a __successful__ run, reported in
-- 'AgentRunResult'. The distinction a caller needs is between \"the tool
-- never started or never finished\" and \"the tool ran and this is what
-- happened\"; a coding agent that attempts its task and fails has run.
module Baikai.Agent.Run
  ( runAgentCommand,

    -- * Exposed for testing
    timeoutMicros,
  )
where

import Baikai.Agent
  ( AgentCapturedOutput (..),
    AgentCommand,
    AgentOutputMode (..),
    AgentPromptTransport (..),
    AgentRunFailure (..),
    AgentRunRequest,
    AgentRunResult,
    agentRunResult,
  )
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( SomeAsyncException (..),
    SomeException,
    displayException,
    fromException,
    throwIO,
    try,
  )
import Control.Lens ((&), (.~), (^.))
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode)
import System.IO (Handle, hClose, hFlush, stderr, stdout)
import System.Process qualified as P
import System.Timeout qualified as Timeout
#if defined(BAIKAI_POSIX_SIGNALS)
import System.Posix.Signals qualified as Signals
#endif

-- | Run one unattended coding-agent command.
--
-- Both arguments are required and neither is redundant. The request
-- supplies every process-level setting — working directory, timeout,
-- output discipline, output limit, and declared environment variables —
-- while the command supplies the executable, the argument vector, and
-- the prompt transport. 'AgentCommand' deliberately carries no working
-- directory, because Claude Code has no working-directory flag and two
-- copies of a working directory could disagree, which would be a
-- sandbox escape rather than a cosmetic bug.
--
-- The outcomes:
--
-- * ran, whatever its exit code — @Right@ carrying that code
-- * working directory absent — @Left WorkingDirMissing@, nothing spawned
-- * a declared variable unset or empty — @Left MissingEnvironment@
-- * executable not startable — @Left SpawnFailed@
-- * still running at the deadline — @Left RunTimedOut@, whole process
--   group terminated
runAgentCommand ::
  AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
runAgentCommand req cmd = do
  -- Preconditions first, cheapest and most informative before costliest.
  -- Without the directory check a missing directory surfaces as an
  -- opaque spawn failure that appears to blame the coding-agent binary.
  dirExists <- doesDirectoryExist (req ^. #workingDir)
  if not dirExists
    then pure (Left (WorkingDirMissing (req ^. #workingDir)))
    else do
      missing <- missingEnvironment (req ^. #envPassthrough)
      if not (null missing)
        then pure (Left (MissingEnvironment missing))
        else spawn req cmd

-- | Every declared variable that is unset or empty, collected rather
-- than short-circuited so an operator fixing a job configuration sees
-- all of them in one run.
missingEnvironment :: [Text] -> IO [Text]
missingEnvironment names = do
  states <- traverse check names
  pure [name | (name, absent) <- states, absent]
  where
    check name = do
      value <- lookupEnv (Text.unpack name)
      pure (name, maybe True null value)

spawn ::
  AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
spawn req cmd = do
  let spec =
        (P.proc (cmd ^. #executable) (cmd ^. #arguments))
          { P.cwd = Just (req ^. #workingDir),
            P.std_in = stdinSpec,
            P.std_out = outSpec,
            P.std_err = outSpec,
            -- A coding agent runs shell commands as its own children.
            -- Its own group is what lets a timeout reach them.
            P.create_group = True,
            -- The child inherits the parent's environment in full. Both
            -- tools need HOME, PATH, and their own credential files;
            -- envPassthrough is a precondition check, not a filter.
            P.env = Nothing
          }
      stdinSpec = case cmd ^. #promptTransport of
        PromptOnStdin -> P.CreatePipe
        -- The prompt is already the last element of the argument vector.
        -- Supplying standard input as well is specifically harmful for
        -- Codex, which appends piped input as a separate <stdin> block,
        -- so the agent would receive the prompt twice.
        PromptAsArgument -> P.NoStream
      outSpec = case req ^. #output of
        InheritOutput -> P.Inherit
        CaptureOutput -> P.CreatePipe
        TeeOutput -> P.CreatePipe
  start <- getCurrentTime
  outcome <- trySync (P.withCreateProcess spec (consume req cmd start))
  case outcome of
    Right result -> pure result
    Left e ->
      pure
        ( Left
            ( SpawnFailed
                (cmd ^. #executable)
                (Text.pack (displayException e))
            )
        )

consume ::
  AgentRunRequest ->
  AgentCommand ->
  UTCTime ->
  Maybe Handle ->
  Maybe Handle ->
  Maybe Handle ->
  P.ProcessHandle ->
  IO (Either AgentRunFailure AgentRunResult)
consume req cmd start mIn mOut mErr ph = do
  case (cmd ^. #promptTransport, mIn) of
    (PromptOnStdin, Just hIn) -> writePromptAsync hIn (cmd ^. #promptText)
    _ -> pure ()
  -- Start draining both streams *before* waiting for the process. An
  -- operating-system pipe holds a bounded amount of data, typically 64
  -- kilobytes; if the parent waits for the child to exit before reading,
  -- a child that writes more than that blocks on write while the parent
  -- blocks on wait and neither proceeds. Waiting first looks more
  -- natural and is the classic deadlock — do not "simplify" it.
  --
  -- Both drains are forked, rather than one of them running here, so
  -- that the timeout below can fire while a stream is still open. A
  -- drain on this thread would block until the child exits, which would
  -- make the timeout unreachable in the two capturing modes.
  outVar <- forkDrain limit teeOut mOut
  errVar <- forkDrain limit teeErr mErr
  waited <- waitWithTimeout (timeoutMicros (req ^. #timeout)) ph
  case waited of
    Nothing -> do
      terminateGroup ph
      -- Report the configured limit rather than the measured elapsed
      -- time: the caller asked for a limit and wants to be told which
      -- one was hit, and the elapsed time is slightly larger because of
      -- the grace period.
      pure (Left (RunTimedOut (maybe 0 id (req ^. #timeout))))
    Just code -> do
      capturedOut <- takeMVar outVar
      capturedErr <- takeMVar errVar
      end <- getCurrentTime
      pure
        ( Right
            ( agentRunResult (req ^. #provider) code (diffUTCTime end start)
                & #stdout .~ capturedOut
                & #stderr .~ capturedErr
            )
        )
  where
    limit = req ^. #outputLimit
    (teeOut, teeErr) = case req ^. #output of
      TeeOutput -> (Just stdout, Just stderr)
      InheritOutput -> (Nothing, Nothing)
      CaptureOutput -> (Nothing, Nothing)

-- | Write the prompt and close the handle, on its own thread.
--
-- Closing is what signals end-of-input: without it both tools wait for
-- more prompt text and the run hangs until its timeout, a failure that
-- looks like a slow model rather than a bug.
--
-- The write is forked because a child that never reads its standard
-- input would otherwise block this thread before it could reach the
-- timeout. Failures are ignored: a child that exits without reading its
-- prompt makes the write fail, and that is the child's business, not a
-- reason to report the run as unstartable.
writePromptAsync :: Handle -> Text -> IO ()
writePromptAsync h promptBody =
  void . forkIO . void $
    (try :: IO () -> IO (Either SomeException ())) $ do
      -- Encode explicitly rather than using hPutStr, whose behavior
      -- depends on the handle's locale encoding and would corrupt a
      -- non-ASCII prompt on a machine with a non-UTF-8 locale.
      BS.hPut h (Text.encodeUtf8 promptBody)
      hClose h

-- | Drain one stream on its own thread, delivering the result through
-- an 'MVar'. A stream that was inherited rather than piped has no
-- handle and yields 'OutputNotCaptured' immediately.
forkDrain ::
  Maybe Int -> Maybe Handle -> Maybe Handle -> IO (MVar AgentCapturedOutput)
forkDrain limit tee source = do
  var <- newEmptyMVar
  case source of
    Nothing -> putMVar var OutputNotCaptured
    Just h ->
      void . forkIO $ do
        -- A plain 'try' rather than 'trySync' here on purpose: nothing
        -- delivers an asynchronous exception to this thread, and
        -- re-throwing one would leave the MVar empty and hang whoever
        -- takes it. A drain that fails yields no capture rather than
        -- propagating; the handles are closed under us on timeout, and
        -- that is a normal end rather than an error.
        result <- try (drain limit tee h) :: IO (Either SomeException AgentCapturedOutput)
        putMVar var (either (const OutputNotCaptured) id result)
  pure var

-- | Read a stream to the end, retaining at most the byte limit.
--
-- Once the retained bytes reach the limit the excess is read and
-- discarded rather than the pipe being closed early: closing the read
-- end makes the child's next write fail, which for a coding agent
-- usually means a crash and a confusing error attributed to the tool
-- rather than to the limit.
--
-- A 'Nothing' limit retains everything. That is unbounded by request;
-- the configuration layer supplies a default limit so an operator who
-- says nothing still gets a bound.
drain :: Maybe Int -> Maybe Handle -> Handle -> IO AgentCapturedOutput
drain limit tee h = go [] 0 False
  where
    go chunks retained dropped = do
      chunk <- BS.hGetSome h chunkSize
      if BS.null chunk
        then
          let bytes = BS.concat (reverse chunks)
           in pure (if dropped then OutputTruncated bytes else OutputCaptured bytes)
        else do
          echo chunk
          case limit of
            Nothing -> go (chunk : chunks) (retained + BS.length chunk) dropped
            Just cap
              | retained >= cap -> go chunks retained True
              | otherwise -> do
                  let kept = BS.take (cap - retained) chunk
                  go
                    (kept : chunks)
                    (retained + BS.length kept)
                    (dropped || BS.length kept < BS.length chunk)
    -- Flush per chunk: an unattended run can take many minutes, and an
    -- operator watching a log wants progress rather than a silent block
    -- that appears all at once at the end.
    echo chunk = case tee of
      Nothing -> pure ()
      Just target -> BS.hPut target chunk >> hFlush target

-- | Chunk size for pipe reads, matching the batch CLI provider in
-- @baikai-openai@.
chunkSize :: Int
chunkSize = 4096

-- | Convert a timeout in seconds to the microseconds
-- 'System.Timeout.timeout' expects.
--
-- Zero and negative durations mean __no timeout__ rather than \"expire
-- immediately\": a configuration file saying @timeout 0@ almost
-- certainly means unset, and immediately killing every run would be a
-- baffling failure. A duration too large to fit an 'Int' likewise means
-- no timeout, because a saturated deadline would be indistinguishable
-- from a much shorter one.
timeoutMicros :: Maybe NominalDiffTime -> Maybe Int
timeoutMicros Nothing = Nothing
timeoutMicros (Just seconds)
  | seconds <= 0 = Nothing
  | micros > toInteger (maxBound :: Int) = Nothing
  | otherwise = Just (fromInteger micros)
  where
    micros = ceiling (seconds * 1000000)

-- | Wait for the child, bounded by the timeout when there is one.
--
-- Only the wait is wrapped, never the whole spawn: a timeout firing
-- mid-drain would lose the output collected so far and the chance to
-- terminate cleanly.
waitWithTimeout :: Maybe Int -> P.ProcessHandle -> IO (Maybe ExitCode)
waitWithTimeout Nothing ph = Just <$> P.waitForProcess ph
waitWithTimeout (Just micros) ph = Timeout.timeout micros (P.waitForProcess ph)

-- | How long a timed-out run is given to clean up after the interrupt
-- before it is terminated outright. Long enough for a coding agent to
-- flush its state, short enough that an automated pipeline is not left
-- waiting on a tool that is not going to stop.
gracePeriodMicros :: Int
gracePeriodMicros = 2000000

-- | Signal the child's whole process group, escalating from interrupt
-- to terminate.
--
-- Signalling the group rather than the child is the point: a coding
-- agent runs shell commands as its own children, and terminating only
-- the agent leaves those grandchildren running, holding the working tree
-- open and possibly still writing to it — which for an unattended run a
-- script is about to inspect and commit is a correctness problem rather
-- than untidiness.
--
-- The escalation to a group-wide terminate happens whether or not the
-- interrupt stopped the agent itself, and that is not belt-and-braces.
-- POSIX requires a non-interactive shell to set @SIGINT@ to /ignored/ in
-- the background commands it starts, so an interrupt that kills the
-- agent outright can leave the very children this is meant to reach
-- still running. Only a group-wide terminate collects them.
--
-- Every signal is wrapped because a process that has already exited
-- makes these throw, and a race between the timeout firing and the
-- process exiting on its own is normal rather than exceptional. The
-- final wait always runs so the child is reaped instead of lingering as
-- a zombie.
terminateGroup :: P.ProcessHandle -> IO ()
terminateGroup ph = do
  -- Read the identifier before any wait: 'P.getPid' yields 'Nothing'
  -- once the process has been reaped, and the group is named after its
  -- leader.
  leader <- P.getPid ph
  _ <- trySync (P.interruptProcessGroupOf ph)
  stopped <- Timeout.timeout gracePeriodMicros (P.waitForProcess ph)
  _ <- trySync (terminateProcessGroup leader)
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      _ <- trySync (P.terminateProcess ph)
      _ <- trySync (P.waitForProcess ph)
      pure ()

-- | Send @SIGTERM@ to a whole process group, named by its leader.
--
-- The @process@ package offers a group-wide /interrupt/ but no
-- group-wide /terminate/, so this reaches for the POSIX signal API
-- directly. On a platform without it the group's leader has already
-- been interrupted and is terminated by the caller; only survivors that
-- ignored the interrupt are missed.
terminateProcessGroup :: Maybe P.Pid -> IO ()
#if defined(BAIKAI_POSIX_SIGNALS)
terminateProcessGroup Nothing = pure ()
terminateProcessGroup (Just leader) =
  Signals.signalProcessGroup Signals.sigTERM leader
#else
terminateProcessGroup _ = pure ()
#endif

-- | Catch synchronous exceptions while re-throwing asynchronous ones.
--
-- Swallowing an asynchronous exception would break the timeout, whose
-- own exception is delivered asynchronously to this thread.
trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  result <- try action
  case result of
    Left e
      | Just (SomeAsyncException _) <- (fromException e :: Maybe SomeAsyncException) ->
          throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)
