{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | OpenTelemetry adapter for the baikai 'TraceSink' interface.
--
-- 'otelSink' (or 'otelSinkWith') wraps an 'Otel.Tracer' as a baikai
-- 'TraceSink' so that wiring it through 'Baikai.Trace.withTrace' emits
-- one OpenTelemetry span per provider call. Span attributes follow the
-- OpenTelemetry GenAI semantic conventions where possible
-- (@gen_ai.provider.name@, @gen_ai.request.model@, @gen_ai.usage.input_tokens@);
-- baikai-specific data uses the @baikai.@ prefix (@baikai.event_id@,
-- @baikai.latency_ms@, @baikai.cost.usd@, @baikai.error@).
--
-- The sink is a stateful streamly 'Fold' whose state is a @Map Text Span@
-- keyed by 'eventId'. A 'CallStarted' opens a span and inserts it; a
-- matching 'CallFinished' or 'CallFailed' closes the span and removes the
-- entry. The fold's finalizer closes any spans still in flight at
-- end-of-stream so no span ever leaks.
--
-- Every span is a root unless 'OtelSinkOptions.parentContext' supplies
-- one; see that field for why the parent is fixed per sink rather than
-- read from the ambient context.
module Baikai.Trace.Sink.OpenTelemetry
  ( otelSink,
    otelSinkWith,
    OtelSinkOptions (spanName, includePromptSummary, parentContext),
    defaultOtelSinkOptions,
  )
where

import Baikai.Evidence qualified as Ev
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Control.Monad (forM_)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word64)
import GHC.Generics (Generic)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Attributes.Map qualified as AttrMap
import OpenTelemetry.Common (Timestamp, mkTimestamp)
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.SemanticConventions qualified as SC
import OpenTelemetry.Trace.Core qualified as Otel
import Streamly.Data.Fold qualified as Fold

-- | Tunable knobs for 'otelSinkWith'.
--
-- Construction: the constructor is deliberately not exported. Start
-- from 'defaultOtelSinkOptions' and override fields by record update,
-- so that a field added in a later release cannot break a call site.
data OtelSinkOptions = OtelSinkOptions
  { -- | Name to give each emitted span. Default: @"baikai.call"@.
    spanName :: !Text,
    -- | If 'True', attach the redacted prompt summary as
    -- @gen_ai.prompt_summary@. 'False' by default to avoid logging user
    -- content into observability backends.
    includePromptSummary :: !Bool,
    -- | The context whose span becomes the parent of every span this
    -- sink opens. 'Nothing', the default, makes each call span a root,
    -- as it always was.
    --
    -- A value fixed when the sink is built, not an action run per call:
    -- the fold runs on baikai's trace worker thread, where the caller's
    -- thread-local context is invisible, so reading the ambient context
    -- at span-creation time would read the worker's, which is empty. To
    -- nest a call under your own span, capture the context on your own
    -- thread — @ctx <- getContext@, or
    -- @Context.insertSpan mySpan Context.empty@ — and build the sink for
    -- that request.
    parentContext :: !(Maybe Context.Context)
  }
  -- No 'Eq' or 'Show': 'OpenTelemetry.Context.Context' has neither, and
  -- a hand-written instance ignoring the field would be a lie. 'Generic'
  -- is here so @#spanName@ resolves without the constructor.
  deriving stock (Generic)

-- | Defaults: span name @baikai.call@, prompt summary off.
defaultOtelSinkOptions :: OtelSinkOptions
defaultOtelSinkOptions =
  OtelSinkOptions
    { spanName = "baikai.call",
      includePromptSummary = False,
      parentContext = Nothing
    }

-- | Adapt a 'Otel.Tracer' to a baikai 'TraceSink' with the default options.
otelSink :: Otel.Tracer -> TraceSink
otelSink tracer = otelSinkWith tracer defaultOtelSinkOptions

-- | Adapt a 'Otel.Tracer' to a baikai 'TraceSink' with custom options.
otelSinkWith :: Otel.Tracer -> OtelSinkOptions -> TraceSink
otelSinkWith tracer opts =
  TraceSink (Fold.rmapM finalizer (Fold.foldlM' step (pure Map.empty)))
  where
    step :: Map.Map Text Otel.Span -> TraceEvent -> IO (Map.Map Text Otel.Span)
    step = stepEvent tracer opts

    finalizer :: Map.Map Text Otel.Span -> IO ()
    finalizer remaining =
      forM_ (Map.elems remaining) (\sp -> Otel.endSpan sp Nothing)

stepEvent ::
  Otel.Tracer ->
  OtelSinkOptions ->
  Map.Map Text Otel.Span ->
  TraceEvent ->
  IO (Map.Map Text Otel.Span)
stepEvent tracer OtelSinkOptions {spanName, includePromptSummary, parentContext} m ev = case ev of
  CallStarted {eventId, timestamp, provider, model, maxTokens, promptSummary} -> do
    let baseAttrs :: HashMap.HashMap Text Attr.Attribute
        baseAttrs =
          AttrMap.insertByKey SC.genAi_provider_name provider $
            AttrMap.insertByKey SC.genAi_operation_name ("chat" :: Text) $
              AttrMap.insertByKey SC.genAi_request_model model $
                AttrMap.insertByKey SC.genAi_request_maxTokens (fromIntegral maxTokens :: Int64) $
                  HashMap.fromList
                    [ ("baikai.event_id", Attr.toAttribute eventId)
                    ]
        attrs =
          if includePromptSummary
            then HashMap.insert "gen_ai.prompt_summary" (Attr.toAttribute promptSummary) baseAttrs
            else baseAttrs
        sargs =
          Otel.defaultSpanArguments
            { Otel.kind = Otel.Client,
              Otel.attributes = attrs,
              Otel.startTime = Just (utcToTimestamp timestamp)
            }
    sp <- Otel.createSpan tracer (fromMaybe Context.empty parentContext) spanName sargs
    pure (Map.insert eventId sp m)
  -- 'model' is deliberately not bound here. It is the /requested/ model
  -- id on every 'TraceEvent' constructor, and 'gen_ai.response.model'
  -- names what the provider served — an observation, which arrives on
  -- 'CallEvidence' as 'observedModel'. Setting it here labelled the
  -- requested id as the response model on every call that had no
  -- evidence, and, because 'Otel.addAttributes' replaces an existing key
  -- and evidence is pushed before the terminal, overwrote the genuinely
  -- observed value on every call that did.
  CallFinished {eventId, timestamp, latencyMs, inputTokens, outputTokens, usd} ->
    case Map.lookup eventId m of
      -- A terminal without a live span is unreachable for normal withTraceStream
      -- usage because each traced call drives a fresh fold. Keep the silent drop so
      -- hand-fed or replayed event streams cannot crash the sink.
      Nothing -> pure m
      Just sp -> do
        let attrs :: HashMap.HashMap Text Attr.Attribute
            attrs =
              maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_inputTokens (fromIntegral n :: Int64)) inputTokens $
                maybe id (\n -> AttrMap.insertByKey SC.genAi_usage_outputTokens (fromIntegral n :: Int64)) outputTokens $
                  maybe id (\s -> HashMap.insert "baikai.cost.usd" (Attr.toAttribute (Scientific.toRealFloat s :: Double))) usd $
                    HashMap.fromList
                      [ ("baikai.latency_ms", Attr.toAttribute latencyMs)
                      ]
        Otel.addAttributes sp attrs
        Otel.setStatus sp Otel.Ok
        Otel.endSpan sp (Just (utcToTimestamp timestamp))
        pure (Map.delete eventId m)
  CallFailed {eventId, timestamp, latencyMs, errorMessage} ->
    case Map.lookup eventId m of
      -- A terminal without a live span is unreachable for normal withTraceStream
      -- usage because each traced call drives a fresh fold. Keep the silent drop so
      -- hand-fed or replayed event streams cannot crash the sink.
      Nothing -> pure m
      Just sp -> do
        Otel.addAttributes sp $
          HashMap.fromList
            [ ("baikai.latency_ms", Attr.toAttribute latencyMs),
              ("baikai.error", Attr.toAttribute errorMessage)
            ]
        Otel.setStatus sp (Otel.Error errorMessage)
        Otel.endSpan sp (Just (utcToTimestamp timestamp))
        pure (Map.delete eventId m)
  CallEvidence {eventId, evidence} ->
    -- Evidence neither opens nor closes a span: it is additional
    -- description of a call the started/terminal pair already delimits.
    --
    -- The salient fields go on as flat attributes rather than one
    -- serialised blob, because observability backends index flat
    -- attributes and treat embedded JSON as opaque text. The two
    -- digests are the only content-adjacent values that belong here;
    -- nothing from the prompt, the thinking text, or a tool payload
    -- appears in an evidence record at all.
    --
    -- "Baikai.Trace" emits this event /before/ the matching
    -- 'CallFinished' or 'CallFailed', which is what makes the lookup
    -- below find an open span. It did not always: the terminal came
    -- first, the span was ended and removed, and this branch was
    -- unreachable from a live stream. If that ordering is ever changed
    -- back, these attributes silently stop appearing — the lookup
    -- misses and nothing fails.
    --
    -- A miss is still tolerated rather than treated as an error,
    -- because a hand-fed or replayed stream may legitimately carry
    -- evidence for a call this sink never saw start.
    case Map.lookup eventId m of
      Nothing -> pure m
      Just sp -> do
        Otel.addAttributes sp (evidenceAttributes evidence)
        pure m

-- | The flat attribute set for one 'ModelCallEvidence'.
--
-- 'Ev.observedModel' is attached only when the provider actually
-- reported one. Attaching the requested model under an "observed" key
-- when the provider said nothing would be exactly the backfill the
-- 'Ev.Observed' type exists to prevent, and an observability backend
-- gives no way to tell the two apart after the fact.
--
-- Read through 'OverloadedRecordDot' rather than bare selectors:
-- 'Ev.ModelCallEvidence' and 'Ev.EvidenceRequest' both carry @runId@,
-- so under @DuplicateRecordFields@ a bare @Ev.runId ev@ is an ambiguous
-- occurrence. A record pattern would also resolve every field at once,
-- but the constructor is no longer exported.
evidenceAttributes :: Ev.ModelCallEvidence -> HashMap.HashMap Text Attr.Attribute
evidenceAttributes ev =
  maybe id (HashMap.insert "gen_ai.response.model" . Attr.toAttribute) observed $
    HashMap.fromList
      [ ("baikai.evidence.schema_version", Attr.toAttribute ev.schemaVersion),
        ("baikai.evidence.run_id", Attr.toAttribute ev.runId),
        ("baikai.evidence.call_id", Attr.toAttribute ev.callId),
        ("baikai.evidence.strength", Attr.toAttribute (Ev.renderEvidenceStrength ev.strength)),
        ("gen_ai.request.model", Attr.toAttribute ev.requestedModel),
        ("baikai.evidence.request_commitment", Attr.toAttribute ev.requestCommitment),
        ("baikai.evidence.request_configuration", Attr.toAttribute ev.requestConfiguration)
      ]
  where
    observed = Ev.observedValue ev.observedModel

-- | Convert a 'UTCTime' to an OpenTelemetry 'Timestamp'.
--
-- 'Timestamp' stores nanoseconds since the Unix epoch. 'utcTimeToPOSIXSeconds'
-- produces a 'NominalDiffTime'; we go via the 'Real' instance to split into
-- whole seconds and remaining nanoseconds without dropping below microsecond
-- precision.
utcToTimestamp :: UTCTime -> Timestamp
utcToTimestamp t =
  let posix :: Rational
      posix = toRational (utcTimeToPOSIXSeconds t)
      secs :: Word64
      secs = floor posix
      nanos :: Word64
      nanos = floor ((posix - toRational secs) * 1_000_000_000)
   in mkTimestamp secs nanos
