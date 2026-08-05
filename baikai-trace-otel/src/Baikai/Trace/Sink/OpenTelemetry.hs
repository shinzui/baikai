{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

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
module Baikai.Trace.Sink.OpenTelemetry
  ( otelSink,
    otelSinkWith,
    OtelSinkOptions (..),
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
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word64)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Attributes.Map qualified as AttrMap
import OpenTelemetry.Common (Timestamp, mkTimestamp)
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.SemanticConventions qualified as SC
import OpenTelemetry.Trace.Core qualified as Otel
import Streamly.Data.Fold qualified as Fold

-- | Tunable knobs for 'otelSinkWith'.
data OtelSinkOptions = OtelSinkOptions
  { -- | Name to give each emitted span. Default: @"baikai.call"@.
    spanName :: !Text,
    -- | If 'True', attach the redacted prompt summary as
    -- @gen_ai.prompt_summary@. 'False' by default to avoid logging user
    -- content into observability backends.
    includePromptSummary :: !Bool
  }

-- | Defaults: span name @baikai.call@, prompt summary off.
defaultOtelSinkOptions :: OtelSinkOptions
defaultOtelSinkOptions =
  OtelSinkOptions
    { spanName = "baikai.call",
      includePromptSummary = False
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
stepEvent tracer OtelSinkOptions {spanName, includePromptSummary} m ev = case ev of
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
    sp <- Otel.createSpan tracer Context.empty spanName sargs
    pure (Map.insert eventId sp m)
  CallFinished {eventId, timestamp, model, latencyMs, inputTokens, outputTokens, usd} ->
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
                    AttrMap.insertByKey SC.genAi_response_model model $
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
    -- Note that under "Baikai.Trace"'s emission order this event
    -- arrives /after/ the matching 'CallFinished' or 'CallFailed', by
    -- which point the span has been ended and removed from the map, so
    -- the lookup below misses and nothing is attached. That is
    -- deliberate: reordering the trace events to suit this sink would
    -- change when a terminal event reaches every other consumer. The
    -- attach path is live for hand-fed and replayed event streams,
    -- which is what the sink's tests drive.
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
-- Read through a record pattern rather than bare selectors:
-- 'Ev.ModelCallEvidence' and 'Ev.EvidenceRequest' both carry @runId@,
-- so under @DuplicateRecordFields@ a bare @Ev.runId ev@ is an ambiguous
-- occurrence. Matching on the constructor resolves every field at once
-- and costs this package no new dependency.
evidenceAttributes :: Ev.ModelCallEvidence -> HashMap.HashMap Text Attr.Attribute
evidenceAttributes
  Ev.ModelCallEvidence
    { Ev.schemaVersion,
      Ev.runId,
      Ev.callId,
      Ev.requestedModel,
      Ev.observedModel,
      Ev.strength,
      Ev.requestCommitment,
      Ev.requestConfiguration
    } =
    maybe id (HashMap.insert "gen_ai.response.model" . Attr.toAttribute) observed $
      HashMap.fromList
        [ ("baikai.evidence.schema_version", Attr.toAttribute schemaVersion),
          ("baikai.evidence.run_id", Attr.toAttribute runId),
          ("baikai.evidence.call_id", Attr.toAttribute callId),
          ("baikai.evidence.strength", Attr.toAttribute (strengthText strength)),
          ("gen_ai.request.model", Attr.toAttribute requestedModel),
          ("baikai.evidence.request_commitment", Attr.toAttribute requestCommitment),
          ("baikai.evidence.request_configuration", Attr.toAttribute requestConfiguration)
        ]
    where
      observed = Ev.observedValue observedModel

-- | Render an 'Ev.EvidenceStrength' with the same spelling the JSON
-- encoding uses, so a span attribute and a trace line agree.
strengthText :: Ev.EvidenceStrength -> Text
strengthText = \case
  Ev.EvidenceRequestedOnly -> "requested_only"
  Ev.EvidenceCorrelated -> "correlated"
  Ev.EvidenceModelObserved -> "model_observed"
  Ev.EvidenceFullyObserved -> "fully_observed"

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
