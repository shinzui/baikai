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
-- > withCallLog (CallLogConfig "/tmp/baikai.jsonl" True) $ \h -> do
-- >   _ <- runRequestWithLog h model context options
-- >   pure ()
module Baikai.Cost.Log
  ( CallLogConfig (..),
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
  ( AssistantPayload (..),
    Message (..),
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
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (find)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.IO (BufferMode (LineBuffering), IOMode (AppendMode), hSetBuffering, withFile)

-- | Where (and whether) to write the call log.
data CallLogConfig = CallLogConfig
  { path :: !FilePath,
    enabled :: !Bool
  }
  deriving stock (Eq, Show, Generic)

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
    latencyMs :: !Integer,
    promptSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Opaque handle for an open call log.
data CallLogHandle = CallLogHandle
  { chan :: !(Chan (Maybe CallLogEntry)),
    done :: !(MVar ()),
    cfg :: !CallLogConfig
  }

-- | Open a handle. When @enabled = True@, fork the worker thread
-- that drains entries to @path@ in append mode.
openCallLog :: (MonadIO m) => CallLogConfig -> m CallLogHandle
openCallLog c = liftIO $ do
  ch <- newChan
  d <- newEmptyMVar
  case enabled c of
    False -> putMVar d ()
    True -> do
      _ <- forkIO (worker (path c) ch d)
      pure ()
  pure CallLogHandle {chan = ch, done = d, cfg = c}

-- | Signal shutdown and block until the worker has drained every
-- pending entry to disk.
closeCallLog :: (MonadIO m) => CallLogHandle -> m ()
closeCallLog h = liftIO $ do
  case enabled (cfg h) of
    True -> writeChan (chan h) Nothing
    False -> pure ()
  takeMVar (done h)

-- | Bracketed lifetime: open the handle, run the body, close
-- exactly once on every path (including exceptions).
withCallLog :: (MonadUnliftIO m) => CallLogConfig -> (CallLogHandle -> m a) -> m a
withCallLog c body =
  withRunInIO $ \run ->
    bracket (openCallLog c) closeCallLog (run . body)

-- | Non-blocking enqueue. When the handle is disabled, returns
-- immediately without touching the channel.
appendEntry :: (MonadIO m) => CallLogHandle -> CallLogEntry -> m ()
appendEntry h entry
  | not (enabled (cfg h)) = pure ()
  | otherwise = liftIO (writeChan (chan h) (Just entry))

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
      u = case resp ^. #message of
        AssistantMessage AssistantPayload {usage = uu} -> uu
        _ -> error "runRequestWithLog: provider returned a non-assistant message"
      meaningfulCost = (Usage.cost u) ^. #usd > 0
      entry =
        CallLogEntry
          { timestamp = now,
            provider = resp ^. #provider,
            model = (resp ^. #model) ^. #modelId,
            inputTokens = positive (Usage.inputTokens u),
            outputTokens = positive (Usage.outputTokens u),
            cachedInputTokens = positive (Usage.cacheReadTokens u),
            reasoningTokens = Usage.reasoningTokens u,
            usd = if meaningfulCost then Just (usdAsScientific (Usage.cost u)) else Nothing,
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
worker :: FilePath -> Chan (Maybe CallLogEntry) -> MVar () -> IO ()
worker p ch d =
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
    putMVar d ()
  where
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
