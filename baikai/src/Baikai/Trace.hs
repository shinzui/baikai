{-# LANGUAGE ScopedTypeVariables #-}

-- | Call tracing with bounded sink cleanup.
--
-- 'withTraceFold' owns the entire IO lifetime of a call and its consumer fold.
-- 'withTraceList' collects its events, and 'withTrace' reassembles its response.
-- Their explicit-registry @With@ variants have the same guarantee: cancellation
-- anywhere in the fold finalizes tracing before the original exception reaches
-- the caller. Before terminal commitment, a healthy sink has processed the abort
-- evidence at that point; after commitment it retains the terminal evidence.
-- 'runRequestWith' and 'runRequestWithRegistry' inherit this guarantee for the
-- traced call, before appending the call log.
--
-- 'withTraceStream' and 'withTraceStreamWith' instead decorate a general stream.
-- Their step handlers clean up synchronously on a terminal or an exception inside
-- a step. Abandonment between steps relies on Streamly's garbage-collection hook;
-- its abort record is not guaranteed before process exit.
--
-- Per call a worker drains a channel into the user 'TraceSink': 'CallStarted',
-- optional 'CallEvidence', and one 'CallFinished' or 'CallFailed'. A terminal's
-- evidence is forwarded unchanged; an abort uses Baikai's evidence builder and
-- the adapter's own translation description. Opt-out emits no evidence.
--
-- Cleanup submits one terminal and sentinel and waits at most one second in
-- total, even if an interrupted wait is resumed. A blocked worker is abandoned
-- and may deliver later. Sink failures and stalls are reported on stderr; strict
-- successful calls fail when delivery was not confirmed. Cancellation always
-- preserves the original exception. Exactly-once submission is not a guarantee
-- of durable external delivery. A short, nonblocking sink can store the complete
-- evidence in a caller-owned cell; the caller reads it in its exception handler.
module Baikai.Trace
  ( -- * Re-exports
    TraceEvent (..),
    TraceSink (..),

    -- * Wrappers
    withTrace,
    withTraceWith,
    withTraceFold,
    withTraceFoldWith,
    withTraceList,
    withTraceListWith,
    withTraceStream,
    withTraceStreamWith,
    runRequestWith,
    runRequestWithRegistry,

    -- * Helpers
    summarizeContext,
  )
where

import Baikai.Context (Context)
import Baikai.Cost (usdAsScientific)
import Baikai.Cost qualified as Cost
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

import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Evidence
  ( ModelCallEvidence,
    newCallId,
  )
import Baikai.Evidence qualified as Evidence
import Baikai.Evidence.Build qualified as Build
import Baikai.Internal.Data (recoverDataBlocks)
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude hiding (Fold)
import Baikai.Provider.Registry (ProviderRegistry, globalProviderRegistry)
import Baikai.Provider.Registry qualified as Registry
import Baikai.Response (Response, flattenAssistantData)
import Baikai.StopReason (StopReason (ErrorReason))
import Baikai.Stream (reassembleResponse, streamRequestWith)
import Baikai.Stream.Event (AssistantMessageEvent (..), BlockEndPayload (..), DataEndPayload (..), TerminalPayload (..), ThinkingEndPayload (..), ToolCallEndPayload (..))
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (Exception (..), SomeException, catch, finally, mask, onException, throwIO, try, uninterruptibleMask_)
import Control.Monad (forM_, unless, void)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (fromMaybe, isJust)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as V
import Data.Word (Word64)
import Foreign.StablePtr (StablePtr, freeStablePtr, newStablePtr)
import GHC.Clock (getMonotonicTimeNSec)
import Streamly.Data.Fold (Fold)
import Streamly.Data.Fold qualified as Fold
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
withTraceStreamWith reg sink m ctx opts =
  Stream.concatEffect $ mask $ \_ -> do
    (state, eid, start) <- acquireTrace sink m ctx opts
    pure $
      Stream.finallyIO
        (void (finalizeTrace reg state eid start m opts))
        (tracedStream reg state eid start m ctx opts)

-- | Drain a traced call with a caller-supplied fold. Owns cleanup across the
-- entire fold, including its steps and final action. On cancellation before
-- terminal commitment, a healthy sink receives abort evidence before the original
-- exception propagates. After commitment the terminal evidence is retained.
-- Delivery is bounded by one second; a stalled worker may deliver later.
withTraceFold ::
  TraceSink -> Model -> Context -> Options -> Fold IO AssistantMessageEvent b -> IO b
withTraceFold = withTraceFoldWith globalProviderRegistry

-- | 'withTraceFold' with an explicit provider registry.
withTraceFoldWith ::
  ProviderRegistry -> TraceSink -> Model -> Context -> Options -> Fold IO AssistantMessageEvent b -> IO b
withTraceFoldWith reg sink m ctx opts consumer = mask $ \restore -> do
  (state, eid, start) <- acquireTrace sink m ctx opts
  let cleanup = void (finalizeTrace reg state eid start m opts)
  result <- try $ do
    value <- restore (Stream.fold consumer (tracedStream reg state eid start m ctx opts))
    -- An early-finishing fold reaches cleanup without a provider terminal.
    -- Keep this first drain inside the handler too: cancellation can land at
    -- its interruptible wait, and must resume the same budget before rethrow.
    cleanup
    pure value
  case result of
    Left (original :: SomeException) -> do
      -- Cleanup diagnostics or evidence construction must never replace the
      -- exception that stopped collection. Release the root even on failure.
      cleanup `catch` \(_ :: SomeException) -> releaseStableRoot state
      throwIO original
    Right value -> pure value

-- | Collect all events with the lifetime guarantee of 'withTraceFold'.
withTraceList :: TraceSink -> Model -> Context -> Options -> IO [AssistantMessageEvent]
withTraceList = withTraceListWith globalProviderRegistry

-- | 'withTraceList' with an explicit provider registry.
withTraceListWith ::
  ProviderRegistry -> TraceSink -> Model -> Context -> Options -> IO [AssistantMessageEvent]
withTraceListWith reg sink m ctx opts = withTraceFoldWith reg sink m ctx opts Fold.toList

-- Acquisition is masked by both callers until their cleanup handler is installed.
-- The worker explicitly unmasks user sink code, independently of its parent.
acquireTrace :: TraceSink -> Model -> Context -> Options -> IO (TraceState, Text, UTCTime)
acquireTrace (TraceSink sinkFold) m ctx opts = do
  eid <- newCallId
  start <- getCurrentTime
  state <- newTraceState
  let c = state ^. #chan
      worker :: (forall a. IO a -> IO a) -> IO ()
      worker unmask = do
        let stepDrain () = fmap (fmap (\e -> (e, ()))) (readChan c)
        result <- try (unmask (Stream.fold sinkFold (Stream.unfoldrM stepDrain ())))
        case result of
          Left (e :: SomeException) -> writeIORef (state ^. #sinkError) (Just e)
          Right () -> pure ()
        putMVar (state ^. #done) ()
  ( do
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
      _ <- forkIOWithUnmask worker
      pure (state, eid, start)
    )
    `onException` releaseStableRoot state

tracedStream ::
  ProviderRegistry -> TraceState -> Text -> UTCTime -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
tracedStream reg state eid start m ctx opts =
  Stream.mapM (traceEvent reg state eid start m opts) (streamRequestWith reg m ctx opts)

-- | Synchronous trace wrapper. Applies 'withTraceFold' to
-- 'reassembleResponse', owning cleanup across the entire fold.
--
-- This never throws for producer-side failures: errors flow through
-- the stream as a terminal 'EventError' and the drained 'Response'
-- carries @stopReason = ErrorReason@ plus 'errorMessage'. Partial
-- output must always be recoverable, so a producer failure surfaces as
-- response data rather than as an exception.
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
  liftIO (withTraceFoldWith reg sink model ctx opts (reassembleResponse model))

-- ============================================================
-- Per-call trace state
-- ============================================================

data TraceState = TraceState
  { chan :: !(Chan (Maybe TraceEvent)),
    done :: !(MVar ()),
    closed :: !(IORef Bool),
    drainDeadline :: !(IORef Word64),
    finalized :: !(IORef Bool),
    sinkError :: !(IORef (Maybe SomeException)),
    terminalSent :: !(IORef Bool),
    dataBlocks :: !(IORef (IntMap.IntMap AssistantContent)),
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
  dat <- newIORef IntMap.empty
  deadline <- newIORef 0
  finished <- newIORef False
  root <- newIORef Nothing
  let state = TraceState {chan = c, done = d, closed = r, sinkError = e, terminalSent = t, dataBlocks = dat, stableRoot = root, drainDeadline = deadline, finalized = finished}
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
-- Closure submits at most one terminal and sentinel. Drain completion is
-- tracked separately: an interrupted wait may be resumed by the fold owner,
-- using the original deadline. The terminal path can still fail strict
-- success; cleanup while unwinding never changes the original exception.
finalizeTrace ::
  ProviderRegistry -> TraceState -> Text -> UTCTime -> Model -> Options -> IO (Maybe BaikaiError)
finalizeTrace reg s eid start m opts = flip onException (releaseStableRoot s) $ mask $ \restore -> do
  alreadyClosed <-
    atomicModifyIORef' (s ^. #closed) (\b -> (True, b))
  unless alreadyClosed $
    ( do
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
                    inputTokens = Nothing,
                    outputTokens = Nothing,
                    cachedInputTokens = Nothing,
                    cacheWriteTokens = Nothing,
                    reasoningTokens = Nothing,
                    totalTokens = Nothing,
                    costBasis = Nothing,
                    usageAvailability = Nothing,
                    usd = Nothing,
                    structuredData = Nothing,
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
    )
      `finally` do
        -- The sentinel and deadline are published together. Neither operation
        -- blocks: the unbounded channel has only this thread as its writer here.
        uninterruptibleMask_ $ do
          now <- getMonotonicTimeNSec
          writeIORef (s ^. #drainDeadline) (now + fromIntegral sinkDrainBoundMicros * 1000)
          writeChan (s ^. #chan) Nothing
  finished <- readIORef (s ^. #finalized)
  if finished
    then pure Nothing
    else do
      -- An interrupted terminal finalizer has closed the channel but has not
      -- completed the drain. An enclosing owner resumes the remaining budget.
      drained <- restore (awaitWorker s) `onException` releaseStableRoot s
      unless drained $
        atomicModifyIORef' (s ^. #sinkError) $ \old ->
          (Just (fromMaybe (toException (TraceSinkStalled sinkDrainBoundMicros)) old), ())
      fatal <- reportSinkError s opts `onException` releaseStableRoot s
      writeIORef (s ^. #finalized) True
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
awaitWorker s = do
  deadline <- readIORef (s ^. #drainDeadline)
  now <- getMonotonicTimeNSec
  let remaining = if now < deadline then fromIntegral ((deadline - now + 999) `div` 1000) else 1
  isJust <$> timeout remaining (readMVar (s ^. #done))

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
  let remember i block = atomicModifyIORef' (state ^. #dataBlocks) (\old -> (IntMap.insert i block old, ()))
  case ev of
    DataEnd DataEndPayload {contentIndex = i, content = d} -> remember i (AssistantData d)
    TextEnd BlockEndPayload {contentIndex = i, content = t} -> remember i (AssistantText (TextContent t))
    ThinkingEnd ThinkingEndPayload {contentIndex = i, content = t} -> remember i (AssistantThinking t)
    ToolCallEnd ToolCallEndPayload {contentIndex = i, toolCall = t} -> remember i (AssistantToolCall t)
    _ -> pure ()
  closed <- readIORef (state ^. #dataBlocks)
  let dataFor failed msg = case msg of
        AssistantMessage p ->
          let blocks = p ^. #content
              recovered
                | V.null blocks = V.fromList (IntMap.elems closed)
                | failed = recoverDataBlocks closed blocks
                | otherwise = blocks
              ds = flattenAssistantData recovered
           in if V.null ds then Nothing else Just ds
        _ -> Nothing
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
                costBasis = mu >>= Cost.nonEmptyBasis . Usage.cost,
                usageAvailability = mu >>= Usage.availability,
                structuredData = dataFor False msg,
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
          mu = assistantUsageFromMsg msg
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
                inputTokens = fmap Usage.inputTokens mu,
                outputTokens = fmap Usage.outputTokens mu,
                cachedInputTokens = fmap Usage.cacheReadTokens mu,
                cacheWriteTokens = fmap Usage.cacheWriteTokens mu,
                reasoningTokens = mu >>= Usage.reasoningTokens,
                totalTokens = fmap Usage.totalTokens mu,
                costBasis = mu >>= Cost.nonEmptyBasis . Usage.cost,
                usageAvailability = mu >>= Usage.availability,
                structuredData = dataFor True msg,
                usd = fmap (usdAsScientific . Usage.cost) mu,
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
            cacheWriteTokens = fmap Usage.cacheWriteTokens mu,
            costBasis = mu >>= Cost.nonEmptyBasis . Usage.cost,
            usageAvailability = mu >>= Usage.availability,
            reasoningTokens = mu >>= Usage.reasoningTokens,
            -- Report a zero cost as zero. Suppressing it made "this
            -- call was free" indistinguishable from "baikai could not
            -- price this call", and the CLI providers always price at
            -- zero.
            usd = fmap (usdAsScientific . Usage.cost) mu,
            latencyMs = resp ^. #latencyMs,
            structuredData = let ds = flattenAssistantData ((resp ^. #message) ^. #content) in if V.null ds then Nothing else Just ds,
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
