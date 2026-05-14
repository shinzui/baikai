{-# LANGUAGE NamedFieldPuns #-}

-- | OpenTelemetry adapter for the baikai 'TraceSink' interface.
--
-- 'otelSink' (or 'otelSinkWith') wraps an 'Otel.Tracer' as a baikai
-- 'TraceSink' so that wiring it through 'Baikai.Trace.withTrace' emits
-- one OpenTelemetry span per provider call. Span attributes follow the
-- OpenTelemetry GenAI semantic conventions where possible
-- (@gen_ai.system@, @gen_ai.request.model@, @gen_ai.usage.input_tokens@);
-- baikai-specific data uses the @baikai.@ prefix (@baikai.event_id@,
-- @baikai.latency_ms@, @baikai.cost.usd@, @baikai.error@).
--
-- The sink is a stateful streamly 'Fold' whose state is a @Map Text Span@
-- keyed by 'eventId'. A 'CallStarted' opens a span and inserts it; a
-- matching 'CallFinished' or 'CallFailed' closes the span and removes the
-- entry. The fold's finalizer closes any spans still in flight at
-- end-of-stream so no span ever leaks.
module Baikai.Trace.Sink.OpenTelemetry
  ( otelSink
  , otelSinkWith
  , OtelSinkOptions (..)
  , defaultOtelSinkOptions
  ) where

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
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Common (Timestamp (..))
import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Trace.Core qualified as Otel
import Streamly.Data.Fold qualified as Fold
import System.Clock qualified as Clock

-- | Tunable knobs for 'otelSinkWith'.
data OtelSinkOptions = OtelSinkOptions
  { spanName :: !Text
  -- ^ Name to give each emitted span. Default: @"baikai.call"@.
  , includePromptSummary :: !Bool
  -- ^ If 'True', attach the redacted prompt summary as
  -- @gen_ai.prompt_summary@. 'False' by default to avoid logging user
  -- content into observability backends.
  }

-- | Defaults: span name @baikai.call@, prompt summary off.
defaultOtelSinkOptions :: OtelSinkOptions
defaultOtelSinkOptions =
  OtelSinkOptions
    { spanName = "baikai.call"
    , includePromptSummary = False
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

stepEvent
  :: Otel.Tracer
  -> OtelSinkOptions
  -> Map.Map Text Otel.Span
  -> TraceEvent
  -> IO (Map.Map Text Otel.Span)
stepEvent tracer OtelSinkOptions {spanName, includePromptSummary} m ev = case ev of
  CallStarted {eventId, timestamp, provider, model, maxTokens, promptSummary} -> do
    let baseAttrs :: HashMap.HashMap Text Attr.Attribute
        baseAttrs =
          HashMap.fromList
            [ ("gen_ai.system", Attr.toAttribute provider)
            , ("gen_ai.request.model", Attr.toAttribute model)
            , ("gen_ai.request.max_tokens", Attr.toAttribute (fromIntegral maxTokens :: Int))
            , ("baikai.event_id", Attr.toAttribute eventId)
            ]
        attrs =
          if includePromptSummary
            then HashMap.insert "gen_ai.prompt_summary" (Attr.toAttribute promptSummary) baseAttrs
            else baseAttrs
        sargs =
          Otel.defaultSpanArguments
            { Otel.kind = Otel.Client
            , Otel.attributes = attrs
            , Otel.startTime = Just (utcToTimestamp timestamp)
            }
    sp <- Otel.createSpan tracer Context.empty spanName sargs
    pure (Map.insert eventId sp m)
  CallFinished {eventId, timestamp, model, latencyMs, inputTokens, outputTokens, usd} ->
    case Map.lookup eventId m of
      Nothing -> pure m
      Just sp -> do
        let attrs :: HashMap.HashMap Text Attr.Attribute
            attrs =
              HashMap.fromList $
                [ ("gen_ai.response.model", Attr.toAttribute model)
                , ("baikai.latency_ms", Attr.toAttribute (fromIntegral latencyMs :: Int))
                ]
                  <> maybe [] (\n -> [("gen_ai.usage.input_tokens", Attr.toAttribute (fromIntegral n :: Int))]) inputTokens
                  <> maybe [] (\n -> [("gen_ai.usage.output_tokens", Attr.toAttribute (fromIntegral n :: Int))]) outputTokens
                  <> maybe [] (\s -> [("baikai.cost.usd", Attr.toAttribute (Scientific.toRealFloat s :: Double))]) usd
        Otel.addAttributes sp attrs
        Otel.setStatus sp Otel.Ok
        Otel.endSpan sp (Just (utcToTimestamp timestamp))
        pure (Map.delete eventId m)
  CallFailed {eventId, timestamp, latencyMs, errorMessage} ->
    case Map.lookup eventId m of
      Nothing -> pure m
      Just sp -> do
        Otel.addAttributes sp $
          HashMap.fromList
            [ ("baikai.latency_ms", Attr.toAttribute (fromIntegral latencyMs :: Int))
            , ("baikai.error", Attr.toAttribute errorMessage)
            ]
        Otel.setStatus sp (Otel.Error errorMessage)
        Otel.endSpan sp (Just (utcToTimestamp timestamp))
        pure (Map.delete eventId m)

-- | Convert a 'UTCTime' to an OpenTelemetry 'Timestamp'.
--
-- 'Timestamp' is a newtype around 'Clock.TimeSpec' (seconds and
-- nanoseconds since the Unix epoch). 'utcTimeToPOSIXSeconds' produces a
-- 'NominalDiffTime'; we go via the 'Real' instance to split into whole
-- seconds and remaining nanoseconds without dropping below microsecond
-- precision.
utcToTimestamp :: UTCTime -> Timestamp
utcToTimestamp t =
  let posix :: Rational
      posix = toRational (utcTimeToPOSIXSeconds t)
      secs :: Int64
      secs = floor posix
      nanos :: Int64
      nanos = floor ((posix - toRational secs) * 1_000_000_000)
   in Timestamp (Clock.TimeSpec secs nanos)
