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
-- through 'Stream.finallyIO' so an early-aborting consumer eventually
-- records a synthetic 'CallFailed' and never leaks the worker. Sink
-- exceptions are captured by the worker and reported once on stderr
-- during cleanup; they do not propagate into the provider call.
module Baikai.Trace
  ( -- * Re-exports
    TraceEvent (..),
    TraceSink (..),

    -- * Wrappers
    withTrace,
    withTraceWith,
    withTraceStream,
    withTraceStreamWith,
    runRequestWith,
    runRequestWithRegistry,

    -- * Helpers
    newEventId,
    summarizeContext,
  )
where

import Baikai.Context (Context)
import Baikai.Cost (usdAsScientific)
import Baikai.Cost.Log
  ( CallLogEntry (..),
    CallLogHandle,
    appendEntry,
    summarizeContext,
  )
-- 'Baikai.Evidence.CallStatus' has a @CallFailed@ constructor and so
-- does 'Baikai.Trace.Event.TraceEvent'. They mean different things and
-- both belong in this module, so the status constructors stay behind
-- the @Evidence.@ qualifier.
import Baikai.Evidence
  ( EvidenceStrictness (..),
    ModelCallEvidence,
    newCallId,
    noThinkingRequested,
  )
import Baikai.Evidence qualified as Evidence
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
import Baikai.Provider.Registry (ProviderRegistry, globalProviderRegistry)
import Baikai.Response (Response)
import Baikai.Stream (reassembleResponse, streamRequestWith)
import Baikai.Stream.Event (AssistantMessageEvent (..), TerminalPayload (..))
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, unless)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Foreign.StablePtr (StablePtr, freeStablePtr, newStablePtr)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

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
withTraceStream ::
  TraceSink ->
  Model ->
  Context ->
  Options ->
  Stream IO AssistantMessageEvent
withTraceStream = withTraceStreamWith globalProviderRegistry

-- | Decorate a streaming provider call through an explicit registry handle.
withTraceStreamWith ::
  ProviderRegistry ->
  TraceSink ->
  Model ->
  Context ->
  Options ->
  Stream IO AssistantMessageEvent
withTraceStreamWith reg (TraceSink sinkFold) m ctx opts =
  Stream.concatEffect $ do
    state <- newTraceState
    let c = state ^. #chan
        d = state ^. #done
    _ <-
      forkIO $ do
        let stepDrain () = do
              msg <- readChan c
              pure (fmap (\e -> (e, ())) msg)
        result <-
          try
            ( Stream.unfoldrM stepDrain ()
                & Stream.fold sinkFold
            ) ::
            IO (Either SomeException ())
        case result of
          Left e -> writeIORef (state ^. #sinkError) (Just e)
          Right () -> pure ()
        putMVar d ()
    eid <- newCallId
    start <- getCurrentTime
    writeChan c $
      Just
        CallStarted
          { eventId = eid,
            timestamp = start,
            provider = m ^. #provider,
            model = m ^. #modelId,
            maxTokens = resolvedMaxTokens m opts,
            promptSummary = summarizeContext ctx
          }
    pure $
      Stream.finallyIO
        (finalizeTrace state eid start m opts)
        (Stream.mapM (traceEvent state eid start m opts) (streamRequestWith reg m ctx opts))

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
withTrace ::
  (MonadUnliftIO m) =>
  TraceSink -> Model -> Context -> Options -> m Response
withTrace = withTraceWith globalProviderRegistry

-- | Synchronous trace wrapper that dispatches through an explicit provider
-- registry handle.
withTraceWith ::
  (MonadUnliftIO m) =>
  ProviderRegistry ->
  TraceSink ->
  Model ->
  Context ->
  Options ->
  m Response
withTraceWith reg sink model ctx opts =
  withRunInIO $ \_ ->
    Stream.fold
      (reassembleResponse model)
      (withTraceStreamWith reg sink model ctx opts)

-- ============================================================
-- Per-call trace state
-- ============================================================

data TraceState = TraceState
  { chan :: !(Chan (Maybe TraceEvent)),
    done :: !(MVar ()),
    closed :: !(IORef Bool),
    sinkError :: !(IORef (Maybe SomeException)),
    terminalSent :: !(IORef Bool),
    stableRoot :: !(IORef (Maybe (StablePtr TraceState)))
  }
  deriving stock (Generic)

newTraceState :: IO TraceState
newTraceState = do
  c <- newChan
  d <- newEmptyMVar
  r <- newIORef False
  e <- newIORef Nothing
  t <- newIORef False
  root <- newIORef Nothing
  let state = TraceState {chan = c, done = d, closed = r, sinkError = e, terminalSent = t, stableRoot = root}
  sp <- newStablePtr state
  writeIORef root (Just sp)
  pure state

finalizeTrace :: TraceState -> Text -> UTCTime -> Model -> Options -> IO ()
finalizeTrace s eid start m opts = do
  alreadyClosed <-
    atomicModifyIORef' (s ^. #closed) (\b -> (True, b))
  unless alreadyClosed $ do
    sent <- readIORef (s ^. #terminalSent)
    unless sent $ do
      now <- getCurrentTime
      writeChan (s ^. #chan) $
        Just
          CallFailed
            { eventId = eid,
              timestamp = now,
              provider = m ^. #provider,
              model = m ^. #modelId,
              latencyMs = millisBetween start now,
              errorMessage = "aborted: stream consumer stopped before the terminal event"
            }
      -- The consumer stopped before the terminal event, so no adapter
      -- ever handed evidence back and this layer has to build it. The
      -- status is 'CallAborted' rather than 'CallFailed': an abort is
      -- the consumer's doing, and reporting it as a provider failure
      -- would misattribute it. The digests are over
      -- 'Build.dispatchEnvelope' — see its documentation for what that
      -- does and does not commit to.
      mev <-
        Build.minimalEvidence
          m
          opts
          (Build.transportForModel m)
          noThinkingRequested
          (Build.dispatchEnvelope m opts)
          start
          now
          Evidence.CallAborted
      pushEvidence s eid now m mev
    writeChan (s ^. #chan) Nothing
    takeMVar (s ^. #done)
    reportSinkError s opts
    releaseStableRoot s

-- | Push the 'CallEvidence' event for a call, when there is one.
--
-- An absent evidence value means one of two things and this layer must
-- not try to tell them apart: the caller opted out, or a provider has
-- not been taught to build evidence. In both cases the correct
-- behaviour is identical — push nothing. Synthesising a record from
-- what this layer knows would reintroduce exactly the cost the opt-out
-- gate exists to remove on the first path, and would attribute a record
-- to a transport that did not make it on the second.
--
-- The event's 'eventId' is the /trace/ identifier, the same one on this
-- call's @call_started@ and terminal lines, so all four kinds join. The
-- evidence's own @callId@ is a separate identifier in a separate
-- namespace and travels inside @data.evidence@; this event is what ties
-- the two together.
pushEvidence ::
  TraceState -> Text -> UTCTime -> Model -> Maybe ModelCallEvidence -> IO ()
pushEvidence s eid now m mev =
  forM_ mev $ \ev ->
    writeChan (s ^. #chan) $
      Just
        CallEvidence
          { eventId = eid,
            timestamp = now,
            provider = m ^. #provider,
            model = m ^. #modelId,
            evidence = ev
          }

releaseStableRoot :: TraceState -> IO ()
releaseStableRoot s = do
  msp <- atomicModifyIORef' (s ^. #stableRoot) (\sp -> (Nothing, sp))
  forM_ msp freeStablePtr

-- | Report a sink failure through the strictness-aware hook.
--
-- The strictness comes from the caller's evidence request; a caller who
-- asked for no evidence is 'EvidenceBestEffort', which is baikai's
-- long-standing behaviour of reporting once on stderr and letting the
-- call succeed. Making a strict caller's call fail here is
-- @docs\/plans\/57@'s work and lands as a change to
-- 'Build.onSinkFailure' alone.
reportSinkError :: TraceState -> Options -> IO ()
reportSinkError s opts = do
  merr <- readIORef (s ^. #sinkError)
  forM_ merr (Build.onSinkFailure (strictnessOf opts))

-- | The strictness a call was dispatched under. A call with no evidence
-- request is best-effort.
strictnessOf :: Options -> EvidenceStrictness
strictnessOf opts =
  maybe EvidenceBestEffort (^. #strictness) (opts ^. #evidence)

traceEvent ::
  TraceState ->
  Text ->
  UTCTime ->
  Model ->
  Options ->
  AssistantMessageEvent ->
  IO AssistantMessageEvent
traceEvent state eid start m opts ev = do
  case ev of
    EventDone TerminalPayload {message = msg, evidence = mev} -> do
      now <- getCurrentTime
      let latency = millisBetween start now
          mu = assistantUsageFromMsg msg
          finished =
            CallFinished
              { eventId = eid,
                timestamp = now,
                provider = m ^. #provider,
                model = m ^. #modelId,
                latencyMs = latency,
                inputTokens = fmap Usage.inputTokens mu,
                outputTokens = fmap Usage.outputTokens mu,
                -- Every count here is 'Just' exactly when the terminal
                -- message carried a 'Usage' at all. A zero is reported
                -- as zero, for the same reason the cost below is: an
                -- absent field must mean "baikai has no usage for this
                -- call", never "the count happened to be zero".
                cachedInputTokens = fmap Usage.cacheReadTokens mu,
                cacheWriteTokens = fmap Usage.cacheWriteTokens mu,
                reasoningTokens = mu >>= Usage.reasoningTokens,
                totalTokens = fmap Usage.totalTokens mu,
                -- Report the computed cost whether or not it is zero. It
                -- used to be suppressed at zero, which made a genuinely
                -- free call indistinguishable from a call whose cost
                -- baikai could not compute — and the subscription-based
                -- CLI providers always compute zero, so that was the
                -- common case rather than a corner.
                usd = fmap (usdAsScientific . Usage.cost) mu
              }
      writeChan (state ^. #chan) (Just finished)
      pushEvidence state eid now m mev
      writeIORef (state ^. #terminalSent) True
      finalizeTrace state eid start m opts
    EventError TerminalPayload {message = msg, evidence = mev} -> do
      now <- getCurrentTime
      let latency = millisBetween start now
          errMsg = case msg of
            AssistantMessage AssistantPayload {errorMessage = Just t} -> t
            _ -> "stream terminated with EventError"
          failed =
            CallFailed
              { eventId = eid,
                timestamp = now,
                provider = m ^. #provider,
                model = m ^. #modelId,
                latencyMs = latency,
                errorMessage = errMsg
              }
      writeChan (state ^. #chan) (Just failed)
      pushEvidence state eid now m mev
      writeIORef (state ^. #terminalSent) True
      finalizeTrace state eid start m opts
    _ -> pure ()
  pure ev

-- ============================================================
-- Cost-log convenience wrapper
-- ============================================================

-- | Combine tracing with call-log persistence in one call. Traces
-- the streaming call, drains it into a 'Response', then appends a
-- 'CallLogEntry' to the given handle.
runRequestWith ::
  (MonadUnliftIO m) =>
  TraceSink ->
  CallLogHandle ->
  Model ->
  Context ->
  Options ->
  m Response
runRequestWith = runRequestWithRegistry globalProviderRegistry

-- | Combine tracing with call-log persistence while dispatching through an
-- explicit provider registry handle.
runRequestWithRegistry ::
  (MonadUnliftIO m) =>
  ProviderRegistry ->
  TraceSink ->
  CallLogHandle ->
  Model ->
  Context ->
  Options ->
  m Response
runRequestWithRegistry reg sink h m ctx opts = do
  resp <- withTraceWith reg sink m ctx opts
  now <- liftIO getCurrentTime
  let mu = assistantUsage resp
      entry =
        CallLogEntry
          { timestamp = now,
            provider = m ^. #provider,
            model = m ^. #modelId,
            inputTokens = mu >>= positiveNat . Usage.inputTokens,
            outputTokens = mu >>= positiveNat . Usage.outputTokens,
            cachedInputTokens = mu >>= positiveNat . Usage.cacheReadTokens,
            reasoningTokens = mu >>= Usage.reasoningTokens,
            -- Report a zero cost as zero. Suppressing it made "this
            -- call was free" indistinguishable from "baikai could not
            -- price this call", and the CLI providers always price at
            -- zero.
            usd = fmap (usdAsScientific . Usage.cost) mu,
            latencyMs = resp ^. #latencyMs,
            promptSummary = summarizeContext ctx
          }
  appendEntry h entry
  pure resp

-- ============================================================
-- Internal helpers
-- ============================================================

-- | Project the assistant turn's 'Usage' out of a response.
assistantUsage :: Response -> Maybe Usage
assistantUsage resp = Just ((resp ^. #message) ^. #usage)

assistantUsageFromMsg :: Message -> Maybe Usage
assistantUsageFromMsg = \case
  AssistantMessage AssistantPayload {usage = u} -> Just u
  _ -> Nothing

positiveNat :: Natural -> Maybe Natural
positiveNat 0 = Nothing
positiveNat n = Just n

resolvedMaxTokens :: Model -> Options -> Natural
resolvedMaxTokens m opts = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)

millisBetween :: UTCTime -> UTCTime -> Int
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

-- ============================================================
-- Event id
-- ============================================================

-- | Generate an identifier for one traced call.
--
-- Delegates to 'newCallId'. The previous implementation combined the
-- process-start POSIX /second/ with a process-local counter and
-- produced 16 hexadecimal characters, which meant two processes
-- started within the same second emitted identical identifier
-- sequences. 'newCallId' produces 32 characters and is unique across
-- processes.
newEventId :: IO Text
newEventId = newCallId
{-# DEPRECATED newEventId "Use Baikai.Evidence.newCallId; newEventId's ids were only unique within one process." #-}
