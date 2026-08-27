-- | Opt-in JSONL call log for AI API calls.
--
-- Each open handle owns a 'Chan' and a worker thread. 'appendEntry'
-- is a cheap channel push that returns immediately; the worker
-- drains the channel to disk through a streamly fold. Disk latency
-- therefore never pads the apparent latency of 'completeRequest'.
--
-- The usual pattern is 'withCallLog', which opens a handle, runs
-- the body, and flushes pending entries on the way out:
--
-- > withCallLog (callLogConfig "/tmp/baikai.jsonl") $ \h -> do
-- >   _ <- runRequestWithLog h model context options
-- >   pure ()
--
-- If the worker cannot open or write the log file, the close path
-- reports one warning on stderr and returns. Logging failures do not
-- mask the request body or hang release actions.
--
-- 'closeCallLog' is idempotent: the first caller claims the handle,
-- writes the sentinel and waits for the worker; a second caller returns
-- at once rather than blocking forever on a worker that has already
-- finished. An 'appendEntry' after the close is a no-op, because the
-- worker that would have drained it is gone. The close wait itself is
-- unbounded, unlike the trace bridge's: the call log's purpose is
-- durability, its close runs once per process rather than once per
-- call, and its writer is a local file the operator chose rather than a
-- third-party fold.
module Baikai.Cost.Log
  ( CallLogConfig (path, enabled),
    callLogConfig,
    CallLogEntry (..),
    CallLogHandle,
    openCallLog,
    closeCallLog,
    withCallLog,
    appendEntry,
    runRequestWithLog,
    runRequestWithLogWith,
    summarizeContext,
  )
where

import Baikai.Content (TextContent (..), UserContent (..))
import Baikai.Context (Context)
import Baikai.Cost (usdAsScientific)
import Baikai.Message
  ( Message (..),
    UserPayload (..),
  )
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Registry
  ( ProviderRegistry,
    completeRequestWith,
    globalProviderRegistry,
  )
import Baikai.Response (Response)
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Lens ((^.))
import Control.Monad (forM_, unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (find)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.IO (BufferMode (LineBuffering), IOMode (AppendMode), hPutStrLn, hSetBuffering, stderr, withFile)

-- | Where (and whether) to write the call log.
--
-- Construction: the constructor is deliberately not exported. Start
-- from 'callLogConfig' and override fields by record update.
data CallLogConfig = CallLogConfig
  { path :: !FilePath,
    enabled :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | A call log at the given path, enabled.
callLogConfig :: FilePath -> CallLogConfig
callLogConfig logPath = CallLogConfig {path = logPath, enabled = True}

-- | One line of the JSONL call log. Wire shape preserved from EP-0:
-- @cachedInputTokens@ keeps its name so existing log readers keep
-- parsing.
data CallLogEntry = CallLogEntry
  { timestamp :: !UTCTime,
    provider :: !Text,
    model :: !Text,
    inputTokens :: !(Maybe Natural),
    outputTokens :: !(Maybe Natural),
    cachedInputTokens :: !(Maybe Natural),
    reasoningTokens :: !(Maybe Natural),
    usd :: !(Maybe Scientific),
    latencyMs :: !Int,
    promptSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Opaque handle for an open call log.
data CallLogHandle = CallLogHandle
  { chan :: !(Chan (Maybe CallLogEntry)),
    done :: !(MVar ()),
    cfg :: !CallLogConfig,
    workerError :: !(IORef (Maybe SomeException)),
    -- | Claimed by the first 'closeCallLog'. A second close returns
    -- immediately and an 'appendEntry' after it enqueues nothing.
    closed :: !(IORef Bool)
  }

-- | Open a handle. When @enabled = True@, fork the worker thread
-- that drains entries to @path@ in append mode.
openCallLog :: (MonadIO m) => CallLogConfig -> m CallLogHandle
openCallLog c = liftIO $ do
  ch <- newChan
  d <- newEmptyMVar
  e <- newIORef Nothing
  cl <- newIORef False
  case enabled c of
    False -> putMVar d ()
    True -> do
      _ <- forkIO (worker (path c) ch d e)
      pure ()
  pure CallLogHandle {chan = ch, done = d, cfg = c, workerError = e, closed = cl}

-- | Signal shutdown and block until the worker has drained every
-- pending entry to disk.
--
-- Idempotent. The first caller claims the handle and does the work; a
-- second returns at once. Before the claim existed, a second close
-- blocked forever on an 'MVar' the worker had already emptied — which
-- 'withCallLog' made easy to hit, since its bracket closes a handle a
-- body may also have closed. 'readMVar' rather than 'takeMVar' for the
-- same reason: the slot stays filled.
closeCallLog :: (MonadIO m) => CallLogHandle -> m ()
closeCallLog h = liftIO $ do
  alreadyClosed <- atomicModifyIORef' (closed h) (\b -> (True, b))
  unless alreadyClosed $ do
    case enabled (cfg h) of
      True -> writeChan (chan h) Nothing
      False -> pure ()
    readMVar (done h)
    merr <- readIORef (workerError h)
    forM_ merr $ \e ->
      hPutStrLn
        stderr
        ("baikai: call log worker failed; pending entries were dropped: " <> displayException e)

-- | Bracketed lifetime: open the handle, run the body, close
-- exactly once on every path (including exceptions).
withCallLog :: (MonadUnliftIO m) => CallLogConfig -> (CallLogHandle -> m a) -> m a
withCallLog c body =
  withRunInIO $ \run ->
    bracket (openCallLog c) closeCallLog (run . body)

-- | Non-blocking enqueue. When the handle is disabled, or has already
-- been closed, returns immediately without touching the channel — the
-- worker that would have drained the entry is gone, so enqueuing it
-- would only grow a channel nobody reads.
appendEntry :: (MonadIO m) => CallLogHandle -> CallLogEntry -> m ()
appendEntry h entry
  | not (enabled (cfg h)) = pure ()
  | otherwise = liftIO $ do
      isClosed <- readIORef (closed h)
      unless isClosed (writeChan (chan h) (Just entry))

-- | Dispatch through the registry, then (if logging is enabled)
-- enqueue a single JSONL record summarizing the call.
runRequestWithLog ::
  (MonadIO m) =>
  CallLogHandle ->
  Model ->
  Context ->
  Options ->
  m Response
runRequestWithLog = runRequestWithLogWith globalProviderRegistry

-- | Dispatch through the selected registry, then (if logging is enabled)
-- enqueue a single JSONL record summarizing the call.
runRequestWithLogWith ::
  (MonadIO m) =>
  ProviderRegistry ->
  CallLogHandle ->
  Model ->
  Context ->
  Options ->
  m Response
runRequestWithLogWith reg h m ctx opts = do
  resp <- liftIO (completeRequestWith reg m ctx opts)
  now <- liftIO getCurrentTime
  let u :: Usage
      u = (resp ^. #message) ^. #usage
      entry =
        CallLogEntry
          { timestamp = now,
            provider = resp ^. #provider,
            model = (resp ^. #model) ^. #modelId,
            inputTokens = positive (Usage.inputTokens u),
            outputTokens = positive (Usage.outputTokens u),
            cachedInputTokens = positive (Usage.cacheReadTokens u),
            reasoningTokens = Usage.reasoningTokens u,
            -- A zero cost is reported as zero. The other entry-building
            -- site ('Baikai.Trace.runRequestWithRegistry') used to
            -- suppress it too; leaving one of the two behind would make
            -- the same record type mean different things depending on
            -- which entry point produced it.
            usd = Just (usdAsScientific (Usage.cost u)),
            latencyMs = resp ^. #latencyMs,
            promptSummary = summarizeContext ctx
          }
  appendEntry h entry
  pure resp

-- | 'Just n' when @n > 0@, otherwise 'Nothing'. Keeps zero counts
-- out of the JSONL when the call did not exercise that dimension.
positive :: Natural -> Maybe Natural
positive 0 = Nothing
positive n = Just n

-- | Worker loop: pull 'Maybe CallLogEntry' off the channel, drain
-- through a streamly fold that writes each entry as one JSON line.
worker :: FilePath -> Chan (Maybe CallLogEntry) -> MVar () -> IORef (Maybe SomeException) -> IO ()
worker p ch d errRef = do
  result <- try drainToFile :: IO (Either SomeException ())
  case result of
    Left e -> writeIORef errRef (Just e)
    Right () -> pure ()
  putMVar d ()
  where
    drainToFile =
      withFile p AppendMode $ \fh -> do
        hSetBuffering fh LineBuffering
        let step :: () -> IO (Maybe (CallLogEntry, ()))
            step () = do
              msg <- readChan ch
              case msg of
                Nothing -> pure Nothing
                Just e -> pure (Just (e, ()))
        Stream.unfoldrM step ()
          & Stream.fold (Fold.drainMapM (writeEntry fh))

    writeEntry fh entry =
      BSL.hPut fh (Aeson.encode entry <> "\n")

-- | Concatenate the first user message's text blocks, truncated to
-- 200 characters. Returns empty when no user message is present.
summarizeContext :: Context -> Text
summarizeContext ctx =
  case find isUser (Vector.toList (ctx ^. #messages)) of
    Just (UserMessage UserPayload {content = cs}) -> Text.take 200 (concatUserText cs)
    _ -> Text.empty
  where
    isUser UserMessage {} = True
    isUser _ = False

-- | Concatenate the text-block payloads of a 'UserContent' vector.
-- Image blocks contribute nothing.
concatUserText :: Vector.Vector UserContent -> Text
concatUserText = Text.concat . Vector.toList . Vector.mapMaybe pickText
  where
    pickText (UserText (TextContent t)) = Just t
    pickText _ = Nothing
