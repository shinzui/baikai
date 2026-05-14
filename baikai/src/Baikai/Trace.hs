{-# LANGUAGE ScopedTypeVariables #-}

-- | The 'withTrace' wrapper and supporting helpers.
--
-- 'withTrace' lifts any 'Provider' call into one that emits a
-- 'CallStarted' event before the call and a 'CallFinished' or
-- 'CallFailed' event after, routing both through a user-supplied
-- 'TraceSink'. The sink lives behind a streamly 'Fold', so composition
-- (file plus stdout, redaction, batched OTel export) is just fold
-- composition.
--
-- Per-call plumbing: open a 'Chan' of @Maybe TraceEvent@, fork a worker
-- thread that drains the channel through the sink's fold, push events,
-- write a 'Nothing' sentinel to end the stream, then wait for the worker
-- to flush. Both the success and failure paths drain the worker before
-- returning or re-throwing.
module Baikai.Trace
  ( -- * Re-exports
    TraceEvent (..)
  , TraceSink (..)

    -- * Wrappers
  , withTrace
  , runRequestWith

    -- * Helpers
  , newEventId
  , summarizePrompt
  ) where

import Baikai.Content (TextContent (..), UserContent (..))
import Baikai.Cost (usdAsScientific)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogEntry (..)
  , CallLogHandle
  , appendEntry
  )
import Baikai.Message (Message (..))
import Baikai.Model (Model (..))
import Baikai.Prelude
import Baikai.Provider (Provider (..))
import Baikai.Request (Request)
import Baikai.Response (Response)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Bits (unsafeShiftL, (.&.), (.|.))
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as V
import Numeric (showHex)
import Streamly.Data.Stream qualified as Stream
import System.IO.Unsafe (unsafePerformIO)

-- | Wrap a provider call with structured tracing.
--
-- Opens a per-call channel, forks a worker that drains events through
-- the sink's fold, emits 'CallStarted', invokes the provider, emits
-- 'CallFinished' (success) or 'CallFailed' (any synchronous exception),
-- closes the channel, waits for the worker to drain, then returns the
-- response or re-throws the original exception. The worker is guaranteed
-- to have drained the terminal event before this function returns.
withTrace
  :: (Provider p, MonadUnliftIO m)
  => TraceSink -> p -> Request -> m Response
withTrace (TraceSink sinkFold) p req = withRunInIO $ \_run -> do
  chan <- newChan :: IO (Chan (Maybe TraceEvent))
  done <- newEmptyMVar

  _ <- forkIO $ do
    let step :: () -> IO (Maybe (TraceEvent, ()))
        step () = do
          m <- readChan chan
          pure (fmap (\e -> (e, ())) m)
    Stream.unfoldrM step ()
      & Stream.fold sinkFold
    putMVar done ()

  eid <- newEventId
  start <- getCurrentTime
  writeChan chan $
    Just
      CallStarted
        { eventId = eid
        , timestamp = start
        , provider = providerName p
        , model = unModel (req ^. #model)
        , maxTokens = req ^. #maxTokens
        , promptSummary = summarizePrompt req
        }

  result <- try (runRequest p req :: IO Response)
  end <- getCurrentTime
  let latency :: Integer
      latency = round (1000 * diffUTCTime end start)
  case result of
    Right resp -> do
      let mu = assistantUsage resp
          meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
      writeChan chan $
        Just
          CallFinished
            { eventId = eid
            , timestamp = end
            , provider = providerName p
            , model = unModel (resp ^. #model)
            , latencyMs = latency
            , inputTokens = fmap Usage.inputTokens mu
            , outputTokens = fmap Usage.outputTokens mu
            , usd = if meaningfulCost then fmap (usdAsScientific . Usage.cost) mu else Nothing
            }
      writeChan chan Nothing
      takeMVar done
      pure resp
    Left (e :: SomeException) -> do
      writeChan chan $
        Just
          CallFailed
            { eventId = eid
            , timestamp = end
            , provider = providerName p
            , model = unModel (req ^. #model)
            , latencyMs = latency
            , errorMessage = Text.pack (displayException e)
            }
      writeChan chan Nothing
      takeMVar done
      throwIO e

-- | Convenience: combine tracing with the call-log persistence in one
-- call. Traces the call, then appends a 'CallLogEntry' to the given
-- handle. The entry build mirrors 'Baikai.Cost.Log.runRequestWithLog'.
runRequestWith
  :: (Provider p, MonadUnliftIO m)
  => TraceSink
  -> CallLogHandle
  -> p
  -> Request
  -> m Response
runRequestWith sink h p req = do
  resp <- withTrace sink p req
  now <- liftIO getCurrentTime
  let mu = assistantUsage resp
      meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
      entry =
        CallLogEntry
          { timestamp = now
          , provider = resp ^. #provider
          , model = unModel (resp ^. #model)
          , inputTokens = mu >>= positiveNat . Usage.inputTokens
          , outputTokens = mu >>= positiveNat . Usage.outputTokens
          , cachedInputTokens = mu >>= positiveNat . Usage.cacheReadTokens
          , reasoningTokens = mu >>= Usage.reasoningTokens
          , usd = if meaningfulCost then fmap (usdAsScientific . Usage.cost) mu else Nothing
          , latencyMs = resp ^. #latencyMs
          , promptSummary = summarizePrompt req
          }
  appendEntry h entry
  pure resp

-- | Project the assistant turn's 'Usage' out of a response. Returns
-- 'Nothing' when the response carries a non-assistant message (which
-- providers never produce in practice).
assistantUsage :: Response -> Maybe Usage
assistantUsage resp = case resp ^. #message of
  AssistantMessage {usage = u} -> Just u
  _ -> Nothing

-- | 'Cost.usd' accessor named to avoid colliding with the
-- 'TraceEvent.usd' field selector.
usdRat :: Cost.Cost -> Rational
usdRat = Cost.usd

-- | 'Just n' when @n > 0@, otherwise 'Nothing'. Keeps zero-valued
-- counters out of the trace event when the dimension was not exercised.
positiveNat :: Natural -> Maybe Natural
positiveNat 0 = Nothing
positiveNat n = Just n

-- | Return a short hex id unique within the current process. Combines
-- the low 16 bits of POSIX seconds at first-access with the low 16 bits
-- of a monotonically increasing counter, formatted as 8 hex chars.
--
-- The id is intended only to correlate a 'CallStarted' with its matching
-- 'CallFinished' or 'CallFailed' inside one process run; uniqueness
-- across separate process runs is not guaranteed.
newEventId :: IO Text
newEventId = do
  n <- atomicModifyIORef' eventCounter (\k -> (k + 1, k))
  let raw :: Word
      raw = (eventBase .&. 0xFFFF) `unsafeShiftL` 16 .|. (n .&. 0xFFFF)
      hex = showHex raw ""
      padded = replicate (8 - length hex) '0' <> hex
  pure (Text.pack padded)

eventCounter :: IORef Word
eventCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE eventCounter #-}

eventBase :: Word
eventBase = unsafePerformIO $ do
  t <- getPOSIXTime
  pure (fromIntegral (floor t :: Integer))
{-# NOINLINE eventBase #-}

-- | Extract up to 200 characters of the most recent user message's text
-- content. Returns empty when no 'UserMessage' is present.
summarizePrompt :: Request -> Text
summarizePrompt req =
  let users = V.filter isUser (req ^. #messages)
   in if V.null users
        then Text.empty
        else case V.last users of
          UserMessage {userContent = cs} -> Text.take 200 (concatUserText cs)
          _ -> Text.empty
  where
    isUser UserMessage {} = True
    isUser _ = False

concatUserText :: V.Vector UserContent -> Text
concatUserText =
  Text.concat
    . V.toList
    . V.mapMaybe
      ( \case
          UserText (TextContent t) -> Just t
          _ -> Nothing
      )
