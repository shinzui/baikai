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
-- terminal event to the consumer.
--
-- Cleanup — the 'Nothing' sentinel on the channel, then a wait for
-- the worker — runs exactly once per call. On a normal terminal it
-- runs on the calling thread, so when 'withTrace' returns the sink
-- has processed this call's events. When the consumer abandons the
-- stream instead, it runs from streamly's garbage-collection hook:
-- the synthetic 'CallFailed' and its @aborted@ evidence record are
-- delivered at the next major collection after the stream becomes
-- unreachable, and are __not guaranteed before process exit__. A
-- caller who needs the record before exiting drains the stream to
-- its terminal ('withTrace', or a fold that keeps consuming) rather
-- than stopping early.
--
-- The wait for the worker is bounded by 'sinkDrainBoundMicros'. A
-- sink that blocks forever costs the call one second, after which
-- the worker is abandoned and the stall is reported. Sink
-- exceptions — and stalls — are recorded by the worker and reported
-- once on stderr during cleanup; they fail the call only under
-- 'Baikai.Evidence.EvidenceRequired', where a record whose delivery
-- was never confirmed is not one the caller can account for.
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
import Baikai.Error (BaikaiError, providerError)
-- 'Baikai.Evidence.CallStatus' has a @CallFailed@ constructor and so
-- does 'Baikai.Trace.Event.TraceEvent'. They mean different things and
-- both belong in this module, so the status constructors stay behind
-- the @Evidence.@ qualifier.
import Baikai.Evidence
  ( ModelCallEvidence,
    newCallId,
  )
import Baikai.Evidence qualified as Evidence
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
import Baikai.Provider.Registry (ProviderRegistry, globalProviderRegistry)
import Baikai.Provider.Registry qualified as Registry
import Baikai.Response (Response)
import Baikai.StopReason (StopReason (ErrorReason))
import Baikai.Stream (reassembleResponse, streamRequestWith)
import Baikai.Stream.Event (AssistantMessageEvent (..), TerminalPayload (..))
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (Exception (..), SomeException, mask, onException, try, uninterruptibleMask_)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Foreign.StablePtr (StablePtr, freeStablePtr, newStablePtr)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)

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
        -- The cleanup path cannot change a call's outcome — the stream
        -- is already over — so a fatal sink failure discovered here has
        -- nowhere to go but the stderr line 'reportSinkError' already
        -- wrote. The terminal event below is where it can still matter.
        (void (finalizeTrace reg state eid start m opts))
        (Stream.mapM (traceEvent reg state eid start m opts) (streamRequestWith reg m ctx opts))

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

-- | Close the trace for a call and report whether its sink failure must
-- fail the call.
--
-- 'Nothing' is the ordinary outcome, including a best-effort call whose
-- sink threw: that is reported on stderr and the call succeeds, which is
-- baikai's long-standing behaviour. 'Just' happens only for a caller who
-- required evidence and did not get it.
--
-- Runs at most once per call — the second caller sees 'closed' already
-- set and returns 'Nothing' — which is why the terminal event calls it
-- before the 'Stream.finallyIO' cleanup does. The terminal is where the
-- answer can still change the call's outcome; by cleanup time the
-- stream is over.
finalizeTrace ::
  ProviderRegistry -> TraceState -> Text -> UTCTime -> Model -> Options -> IO (Maybe BaikaiError)
finalizeTrace reg s eid start m opts = mask $ \restore -> do
  alreadyClosed <-
    atomicModifyIORef' (s ^. #closed) (\b -> (True, b))
  if alreadyClosed
    then pure Nothing
    else do
      sent <- readIORef (s ^. #terminalSent)
      unless sent $ do
        now <- getCurrentTime
        let abortText = "aborted: stream consumer stopped before the terminal event"
            aborted =
              CallFailed
                { eventId = eid,
                  timestamp = now,
                  provider = m ^. #provider,
                  model = m ^. #modelId,
                  latencyMs = millisBetween start now,
                  errorMessage = abortText
                }
        -- The consumer stopped before the terminal event, so no adapter
        -- ever handed evidence back and this layer has to build it. The
        -- status is 'CallAborted' rather than 'CallFailed': an abort is
        -- the consumer's doing, and reporting it as a provider failure
        -- would misattribute it. The digests are over
        -- 'Build.dispatchEnvelope' — see its documentation for what that
        -- does and does not commit to.
        --
        -- The translation comes from the registered adapter's own
        -- 'Registry.describeThinking': the adapter /did/ run on this
        -- path, so its description is the truthful one and the only one
        -- @docs\/adr\/0003-the-adapter-owns-the-translation-description.md@
        -- permits. Where no provider is registered there is nothing to
        -- ask, and 'Build.requestedTranslation' says the caller\'s level
        -- was never translated. Either way the caller\'s own level is
        -- recorded, which passing 'Evidence.noThinkingRequested' here
        -- silently denied.
        mProvider <- Registry.lookupApiProviderWith reg (m ^. #api)
        let translation = case mProvider of
              Just p -> Registry.describeThinking p m opts
              Nothing -> Build.requestedTranslation opts
        mev <-
          Build.minimalEvidence
            m
            opts
            (Build.transportForModel m)
            translation
            (Build.dispatchEnvelope m opts)
            start
            now
            Evidence.CallAborted
            -- 'errorInfo' is 'Just' whenever the status is not
            -- 'CallSucceeded', so an abort needs one. Its category is
            -- 'OtherError' rather than any provider-failure category,
            -- because nothing about the provider went wrong: the consumer
            -- stopped reading. The message says exactly that.
            (Just (providerError abortText))
        commitTerminal s eid now m mev aborted
      writeChan (s ^. #chan) Nothing
      -- The claim-through-sentinel region above cannot be interrupted;
      -- the wait below can, which is the whole point of the 'mask' /
      -- 'restore' pair. The GC-hook path enters here already under
      -- 'Control.Exception.mask_', and 'restore' puts back /that/ state,
      -- in which a blocking 'readMVar' is still interruptible — so
      -- 'timeout' can deliver its exception on either path. The
      -- 'onException' releases the root if the wait is interrupted: the
      -- sentinel is already queued, so the worker cannot block on the
      -- channel again and no longer needs rooting.
      drained <- restore (awaitWorker s) `onException` releaseStableRoot s
      unless drained $
        atomicModifyIORef' (s ^. #sinkError) $ \old ->
          (Just (fromMaybe (toException (TraceSinkStalled sinkDrainBoundMicros)) old), ())
      fatal <- reportSinkError s opts
      releaseStableRoot s
      pure fatal

-- | How long 'finalizeTrace' waits for the trace worker after writing
-- the shutdown sentinel.
--
-- On expiry the worker is abandoned, not killed, and the call proceeds.
-- One second is chosen because a call produces at most four events, the
-- wait covers only their delivery and the sink's end-of-stream action,
-- and a sink whose per-call latency approaches a second is
-- mis-configured for per-call tracing — an OpenTelemetry exporter
-- belongs behind the non-blocking batch processor. Not a public option:
-- if the bound ever proves tight the answer is an 'Options' field.
sinkDrainBoundMicros :: Int
sinkDrainBoundMicros = 1_000_000

-- | The trace sink did not confirm delivery within
-- 'sinkDrainBoundMicros', carried here as the microsecond bound.
--
-- Stored in the trace state's @sinkError@ as a plain exception, so the
-- strict-mode decision in "Baikai.Evidence.Build" applies to it exactly
-- as it does to a sink that threw: best-effort callers get the stderr
-- line and their answer, a caller who required evidence gets a failed
-- call. Not exported — it renders as text through both paths, and an
-- exported type is a name the surface freeze would have to keep.
newtype TraceSinkStalled = TraceSinkStalled Int
  deriving stock (Show)

instance Exception TraceSinkStalled where
  displayException (TraceSinkStalled us) =
    "the trace sink did not confirm delivery within "
      <> show (us `div` 1000)
      <> " ms; its worker was abandoned, and events already queued may still be \
         \delivered later"

-- | Wait for the worker to signal completion, for at most
-- 'sinkDrainBoundMicros'. 'True' when it did.
--
-- On 'False' the worker is left running: killing it would abort the
-- sink's fold mid-step and lose its end-of-stream action. An abandoned
-- worker finishes when the sink unblocks, or is reaped with
-- 'Control.Exception.BlockedIndefinitelyOnMVar' — which its 'try'
-- catches — when whatever it blocks on becomes unreachable.
--
-- 'readMVar', not 'takeMVar', so the worker's eventual 'putMVar' can
-- never block on a slot this thread emptied.
awaitWorker :: TraceState -> IO Bool
awaitWorker s = isJust <$> timeout sinkDrainBoundMicros (readMVar (s ^. #done))

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

-- | Commit a call's terminal to the sink: mark the terminal as sent,
-- push the evidence record (when there is one), then push the terminal
-- event.
--
-- One unit with respect to asynchronous exceptions. An exception
-- delivered between the terminal push and the flag write made
-- 'finalizeTrace' read the flag as unset and push a second evidence
-- record and an @aborted@ 'CallFailed' after the real terminal, so a
-- sink saw two records and two contradictory terminals for one call.
-- Plain 'Control.Exception.mask_' closes the window everywhere except
-- inside 'writeChan', whose internal 'takeMVar' on the channel's write
-- lock is interruptible; it never blocks in practice, because the
-- worker only reads, but "never in practice" is what this exists to
-- remove. Every write here is a non-blocking push to an unbounded
-- 'Chan' or one 'IORef' write, so the uninterruptible block holds for
-- microseconds and cannot become an un-cancellable hang.
--
-- The flag goes /first/ so a synchronous failure inside the block
-- yields a missing terminal — which the abort machinery tolerates —
-- rather than a duplicated one. The wait for the worker is outside the
-- block, in 'finalizeTrace'.
commitTerminal ::
  TraceState -> Text -> UTCTime -> Model -> Maybe ModelCallEvidence -> TraceEvent -> IO ()
commitTerminal s eid now m mev terminal =
  uninterruptibleMask_ $ do
    writeIORef (s ^. #terminalSent) True
    pushEvidence s eid now m mev
    writeChan (s ^. #chan) (Just terminal)

releaseStableRoot :: TraceState -> IO ()
releaseStableRoot s = do
  msp <- atomicModifyIORef' (s ^. #stableRoot) (\sp -> (Nothing, sp))
  forM_ msp freeStablePtr

-- | Report a sink failure on stderr, and say whether it must also fail
-- the call.
--
-- The strictness comes from the caller's evidence request; a caller who
-- asked for no evidence is 'EvidenceBestEffort'. Both audiences are
-- served: the stderr line is for whoever is watching the process, and
-- the returned error is for the program.
reportSinkError :: TraceState -> Options -> IO (Maybe BaikaiError)
reportSinkError s opts = do
  merr <- readIORef (s ^. #sinkError)
  case merr of
    Nothing -> pure Nothing
    Just e -> do
      -- A stall is not a throw, and 'Build.onSinkFailure's line says
      -- the events "were dropped", which is the one thing an abandoned
      -- worker's events were not: they are still queued and may yet be
      -- delivered. The fatality decision below is identical for both.
      case fromException e of
        Just stalled@TraceSinkStalled {} ->
          hPutStrLn stderr ("baikai: " <> displayException stalled)
        Nothing -> Build.onSinkFailure strictness e
      pure
        ( if Build.sinkFailureIsFatal strictness
            then Just (Build.sinkFailureError e)
            else Nothing
        )
  where
    strictness = Build.strictnessOf opts

traceEvent ::
  ProviderRegistry ->
  TraceState ->
  Text ->
  UTCTime ->
  Model ->
  Options ->
  AssistantMessageEvent ->
  IO AssistantMessageEvent
traceEvent reg state eid start m opts ev = do
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
      -- Evidence goes out *before* the terminal, so a sink that keys
      -- per-call state off the started/terminal pair still has the
      -- call's state open when it arrives. The OpenTelemetry sink ends
      -- and removes its span on the terminal, so the other order left
      -- its evidence branch unreachable from a live stream.
      commitTerminal state eid now m mev finished
      fatal <- finalizeTrace reg state eid start m opts
      -- A strict caller whose record did not survive gets a failed call
      -- rather than an answer they cannot account for. This is the only
      -- place in baikai where a call that reached the provider and came
      -- back is nevertheless reported as failed.
      pure (maybe ev (failTerminal ev) fatal)
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
      commitTerminal state eid now m mev failed
      -- Already an error: a sink failure on top changes nothing the
      -- caller can act on, and overwriting the provider's own error with
      -- baikai's would lose the more useful of the two.
      _ <- finalizeTrace reg state eid start m opts
      pure ev
    _ -> pure ev

-- | Rewrite a successful terminal into a failed one carrying baikai's
-- own error, preserving everything else about it — including the
-- evidence, which is exactly what a caller investigating this failure
-- wants to read.
failTerminal :: AssistantMessageEvent -> BaikaiError -> AssistantMessageEvent
failTerminal ev be = case ev of
  EventDone p ->
    EventError
      ( p
          & #reason
          .~ ErrorReason
          & #errorInfo
          .~ Just be
          & #message
          %~ markFailed
      )
  other -> other
  where
    markFailed = \case
      AssistantMessage p ->
        AssistantMessage
          (p & #stopReason .~ ErrorReason & #errorMessage .~ Just (be ^. #message))
      other -> other

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
