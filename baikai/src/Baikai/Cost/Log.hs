-- | Opt-in JSONL call log for AI API calls.
--
-- Each open handle owns a 'Chan' and a worker thread. 'appendEntry' is a
-- cheap channel push that returns immediately; the worker drains the channel
-- to disk through a streamly fold. Disk latency therefore never pads the
-- apparent latency of 'runRequest'.
--
-- The usual pattern is 'withCallLog', which opens a handle, runs the body,
-- and flushes pending entries on the way out:
--
-- > withCallLog (CallLogConfig "/tmp/baikai.jsonl" True) $ \\h -> do
-- >   _ <- runRequestWithLog h api req
-- >   pure ()
module Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry (..)
  , CallLogHandle
  , openCallLog
  , closeCallLog
  , withCallLog
  , appendEntry
  , runRequestWithLog
  ) where

import Baikai.Cost (usdAsScientific)
import Baikai.Message (Role (..))
import Baikai.Model (Model (..))
import Baikai.Provider (Provider, runRequest)
import Baikai.Request (Request)
import Baikai.Response (Response)
import Baikai.Usage (Usage)
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.Foldable (find)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import qualified Streamly.Data.Fold as Fold
import qualified Streamly.Data.Stream as Stream
import System.IO (BufferMode (LineBuffering), IOMode (AppendMode), hSetBuffering, withFile)

-- | Where (and whether) to write the call log.
--
-- When @enabled = False@, 'openCallLog' still returns a handle but skips
-- spawning the worker thread; 'appendEntry' short-circuits before touching
-- the channel.
data CallLogConfig = CallLogConfig
  { path :: !FilePath
  , enabled :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | One line of the JSONL call log.
data CallLogEntry = CallLogEntry
  { timestamp :: !UTCTime
  , provider :: !Text
  , model :: !Text
  , inputTokens :: !(Maybe Natural)
  , outputTokens :: !(Maybe Natural)
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  , usd :: !(Maybe Scientific)
  , latencyMs :: !Integer
  , promptSummary :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Opaque handle for an open call log. Carries the channel that
-- 'appendEntry' pushes onto and the synchronization needed to drain it on
-- close.
data CallLogHandle = CallLogHandle
  { chan :: !(Chan (Maybe CallLogEntry))
  , done :: !(MVar ())
  , cfg :: !CallLogConfig
  }

-- | Open a handle. When @enabled = True@, also fork the worker thread that
-- drains entries to @path@ in append mode. Performs no disk I/O on its own
-- when @enabled = False@.
openCallLog :: MonadIO m => CallLogConfig -> m CallLogHandle
openCallLog c = liftIO $ do
  ch <- newChan
  d <- newEmptyMVar
  case enabled c of
    False -> putMVar d ()
    True -> do
      _ <- forkIO (worker (path c) ch d)
      pure ()
  pure CallLogHandle {chan = ch, done = d, cfg = c}

-- | Signal shutdown and block until the worker has drained every pending
-- entry to disk. Calling 'closeCallLog' on a closed handle blocks forever;
-- use 'withCallLog' to guarantee exactly-once close on every path including
-- exceptions.
closeCallLog :: MonadIO m => CallLogHandle -> m ()
closeCallLog h = liftIO $ do
  case enabled (cfg h) of
    True -> writeChan (chan h) Nothing
    False -> pure ()
  takeMVar (done h)

-- | Bracketed lifetime. Stays in 'IO' because 'bracket' requires
-- 'MonadUnliftIO', which 'effectful''s 'Eff' does not satisfy. A future
-- @baikai-effectful@ package will provide an 'Eff'-native wrapper.
withCallLog :: CallLogConfig -> (CallLogHandle -> IO a) -> IO a
withCallLog c = bracket (openCallLog c) closeCallLog

-- | Non-blocking. When the handle is disabled, returns immediately without
-- touching the channel. Otherwise pushes the entry onto the worker's queue.
appendEntry :: MonadIO m => CallLogHandle -> CallLogEntry -> m ()
appendEntry h entry
  | not (enabled (cfg h)) = pure ()
  | otherwise = liftIO (writeChan (chan h) (Just entry))

-- | Run a request through the provider and, if logging is enabled, enqueue a
-- single JSONL record summarizing the call.
runRequestWithLog ::
  (Provider p, MonadIO m) =>
  CallLogHandle ->
  p ->
  Request ->
  m Response
runRequestWithLog h pr req = do
  resp <- runRequest pr req
  now <- liftIO getCurrentTime
  let u :: Maybe Usage
      u = resp ^. #usage
      entry =
        CallLogEntry
          { timestamp = now
          , provider = resp ^. #provider
          , model = unModel (resp ^. #model)
          , inputTokens = fmap (^. #inputTokens) u
          , outputTokens = fmap (^. #outputTokens) u
          , cachedInputTokens = u >>= (^. #cachedInputTokens)
          , reasoningTokens = u >>= (^. #reasoningTokens)
          , usd = fmap usdAsScientific (resp ^. #cost)
          , latencyMs = resp ^. #latencyMs
          , promptSummary = Text.take 200 (firstUserMessage req)
          }
  appendEntry h entry
  pure resp

-- | Worker loop: pull 'Maybe CallLogEntry' off the channel, drain through a
-- streamly fold that writes each entry as one JSON line, exit cleanly on
-- 'Nothing' and signal 'done'.
worker :: FilePath -> Chan (Maybe CallLogEntry) -> MVar () -> IO ()
worker p ch d =
  withFile p AppendMode $ \fh -> do
    hSetBuffering fh LineBuffering
    let step :: () -> IO (Maybe (CallLogEntry, ()))
        step () = do
          m <- readChan ch
          case m of
            Nothing -> pure Nothing
            Just e -> pure (Just (e, ()))
    Stream.unfoldrM step ()
      & Stream.fold (Fold.drainMapM (writeEntry fh))
    putMVar d ()
  where
    writeEntry fh entry =
      BSL.hPut fh (Aeson.encode entry <> "\n")

-- | First user-role message body in the request, or empty when absent.
firstUserMessage :: Request -> Text
firstUserMessage req =
  case find isUser (Vector.toList (req ^. #messages)) of
    Just m -> m ^. #content
    Nothing -> Text.empty
  where
    isUser m = m ^. #role == User
