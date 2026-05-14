{-# LANGUAGE ScopedTypeVariables #-}

-- | The 'withTrace' wrapper and supporting helpers.
--
-- After EP-3, the trace bridge is stream-shaped at the core:
-- 'withTraceStream' returns a 'Stream IO AssistantMessageEvent'
-- that side-effects 'CallStarted' / 'CallFinished' / 'CallFailed'
-- events to a user-supplied 'TraceSink' as the stream's lifecycle
-- unfolds. 'withTrace' is the synchronous draining wrapper:
-- @withTrace sink m ctx opts = Stream.fold (reassembleResponse m)
-- (withTraceStream sink m ctx opts)@.
--
-- Per-call plumbing: open a 'Chan' of @Maybe TraceEvent@, fork a
-- worker thread that drains the channel through the sink's fold,
-- push 'CallStarted' eagerly (before the first
-- 'AssistantMessageEvent' is emitted), then watch for the stream's
-- terminal event ('EventDone' or 'EventError') and push the
-- matching 'CallFinished' / 'CallFailed' before yielding the
-- terminal event to the consumer. Cleanup ('Nothing' sentinel on
-- the channel + 'takeMVar' on the worker) is idempotent and runs
-- through 'Stream.finallyIO' so an early-aborting consumer never
-- leaks the worker.
module Baikai.Trace
  ( -- * Re-exports
    TraceEvent (..)
  , TraceSink (..)

    -- * Wrappers
  , withTrace
  , withTraceStream
  , runRequestWith

    -- * Helpers
  , newEventId
  , summarizeContext
  ) where

import Baikai.Context (Context)
import Baikai.Cost (usdAsScientific)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogEntry (..)
  , CallLogHandle
  , appendEntry
  , summarizeContext
  )
import Baikai.Message (Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
import Baikai.Response (Response)
import Baikai.Stream (reassembleResponse, streamRequest)
import Baikai.Stream.Event (AssistantMessageEvent (..))
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
-- Control.Exception no longer needed; producer errors flow through
-- the stream as 'EventError'.
import Control.Monad (unless)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Bits (unsafeShiftL, (.&.), (.|.))
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.IO.Unsafe (unsafePerformIO)

-- ============================================================
-- Stream-shaped trace bridge
-- ============================================================

-- | Decorate a streaming provider call with structured tracing
-- events emitted to the supplied 'TraceSink'.
--
-- The returned stream yields the same 'AssistantMessageEvent's as
-- 'Baikai.Stream.streamRequest'. As a side effect: one 'CallStarted'
-- event is pushed to the sink before the first
-- 'AssistantMessageEvent' is observed, and one 'CallFinished' (on
-- 'EventDone') or 'CallFailed' (on 'EventError') is pushed before
-- the terminal event is yielded to the consumer. Intermediate delta
-- events are not traced — emitting one trace per token would
-- explode trace volume.
withTraceStream
  :: TraceSink
  -> Model
  -> Context
  -> Options
  -> Stream IO AssistantMessageEvent
withTraceStream (TraceSink sinkFold) m ctx opts =
  Stream.concatEffect $ do
    state <- newTraceState
    let chan = tsChan state
        done = tsDone state
    _ <-
      forkIO $ do
        let stepDrain () = do
              msg <- readChan chan
              pure (fmap (\e -> (e, ())) msg)
        Stream.unfoldrM stepDrain ()
          & Stream.fold sinkFold
        putMVar done ()
    eid <- newEventId
    start <- getCurrentTime
    writeChan chan $
      Just
        CallStarted
          { eventId = eid
          , timestamp = start
          , provider = m ^. #provider
          , model = m ^. #modelId
          , maxTokens = resolvedMaxTokens m opts
          , promptSummary = summarizeContext ctx
          }
    pure $
      Stream.finallyIO (cleanupTrace state)
        (Stream.mapM (traceEvent state eid start m) (streamRequest m ctx opts))

-- | Synchronous trace wrapper. Drains 'withTraceStream' into a
-- 'Response' through 'reassembleResponse'.
--
-- Unlike the EP-2 'withTrace' (which re-threw the producer's
-- exception), this implementation never throws for producer-side
-- failures: errors flow through the stream as a terminal
-- 'EventError' and the drained 'Response' carries
-- @stopReason = ErrorReason@ plus 'errorMessage'. The masterplan's
-- Vision & Scope section commits to "partial output is always
-- recoverable" and the plan's Decision Log records that producer
-- failures must surface as response data, not exceptions.
-- Downstream-of-the-fold exceptions (e.g. an 'appendEntry' that
-- fails) still propagate unchanged.
withTrace
  :: MonadUnliftIO m
  => TraceSink -> Model -> Context -> Options -> m Response
withTrace sink model ctx opts =
  withRunInIO $ \_ ->
    Stream.fold
      (reassembleResponse model)
      (withTraceStream sink model ctx opts)

-- ============================================================
-- Per-call trace state
-- ============================================================

data TraceState = TraceState
  { tsChan :: !(Chan (Maybe TraceEvent))
  , tsDone :: !(MVar ())
  , tsClosed :: !(IORef Bool)
  }

newTraceState :: IO TraceState
newTraceState = do
  c <- newChan
  d <- newEmptyMVar
  r <- newIORef False
  pure TraceState {tsChan = c, tsDone = d, tsClosed = r}

cleanupTrace :: TraceState -> IO ()
cleanupTrace s = do
  alreadyClosed <-
    atomicModifyIORef' (tsClosed s) (\b -> (True, b))
  unless alreadyClosed $ do
    writeChan (tsChan s) Nothing
    takeMVar (tsDone s)

traceEvent
  :: TraceState
  -> Text
  -> UTCTime
  -> Model
  -> AssistantMessageEvent
  -> IO AssistantMessageEvent
traceEvent state eid start m ev = do
  case ev of
    EventDone {message = msg} -> do
      now <- getCurrentTime
      let latency = millisBetween start now
          mu = assistantUsageFromMsg msg
          meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
          finished =
            CallFinished
              { eventId = eid
              , timestamp = now
              , provider = m ^. #provider
              , model = m ^. #modelId
              , latencyMs = latency
              , inputTokens = fmap Usage.inputTokens mu
              , outputTokens = fmap Usage.outputTokens mu
              , usd =
                  if meaningfulCost
                    then fmap (usdAsScientific . Usage.cost) mu
                    else Nothing
              }
      writeChan (tsChan state) (Just finished)
      cleanupTrace state
    EventError {errorPartial = msg} -> do
      now <- getCurrentTime
      let latency = millisBetween start now
          errMsg = case msg of
            AssistantMessage {errorMessage = Just t} -> t
            _ -> "stream terminated with EventError"
          failed =
            CallFailed
              { eventId = eid
              , timestamp = now
              , provider = m ^. #provider
              , model = m ^. #modelId
              , latencyMs = latency
              , errorMessage = errMsg
              }
      writeChan (tsChan state) (Just failed)
      cleanupTrace state
    _ -> pure ()
  pure ev

-- ============================================================
-- Cost-log convenience wrapper
-- ============================================================

-- | Combine tracing with call-log persistence in one call. Traces
-- the streaming call, drains it into a 'Response', then appends a
-- 'CallLogEntry' to the given handle.
runRequestWith
  :: MonadUnliftIO m
  => TraceSink
  -> CallLogHandle
  -> Model
  -> Context
  -> Options
  -> m Response
runRequestWith sink h m ctx opts = do
  resp <- withTrace sink m ctx opts
  now <- liftIO getCurrentTime
  let mu = assistantUsage resp
      meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
      entry =
        CallLogEntry
          { timestamp = now
          , provider = m ^. #provider
          , model = m ^. #modelId
          , inputTokens = mu >>= positiveNat . Usage.inputTokens
          , outputTokens = mu >>= positiveNat . Usage.outputTokens
          , cachedInputTokens = mu >>= positiveNat . Usage.cacheReadTokens
          , reasoningTokens = mu >>= Usage.reasoningTokens
          , usd =
              if meaningfulCost
                then fmap (usdAsScientific . Usage.cost) mu
                else Nothing
          , latencyMs = resp ^. #latencyMs
          , promptSummary = summarizeContext ctx
          }
  appendEntry h entry
  pure resp

-- ============================================================
-- Internal helpers
-- ============================================================

-- | Project the assistant turn's 'Usage' out of a response.
assistantUsage :: Response -> Maybe Usage
assistantUsage resp = case resp ^. #message of
  AssistantMessage {usage = u} -> Just u
  _ -> Nothing

assistantUsageFromMsg :: Message -> Maybe Usage
assistantUsageFromMsg = \case
  AssistantMessage {usage = u} -> Just u
  _ -> Nothing

usdRat :: Cost.Cost -> Rational
usdRat = Cost.usd

positiveNat :: Natural -> Maybe Natural
positiveNat 0 = Nothing
positiveNat n = Just n

resolvedMaxTokens :: Model -> Options -> Natural
resolvedMaxTokens m opts = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

-- ============================================================
-- Event id
-- ============================================================

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
