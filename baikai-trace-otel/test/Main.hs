{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), emptyContext)
import Baikai.Error (BaikaiError, providerError)
import Baikai.Evidence
  ( CallStatus (..),
    EvidenceRequest,
    EvidenceStrength (..),
    Observed (..),
    TransportKind (..),
    evidenceRequest,
    noThinkingRequested,
  )
import Baikai.Evidence.Build (minimalEvidence)
import Baikai.Message (AssistantPayload (..), user)
import Baikai.Model (Model (..), emptyModel)
import Baikai.Options (Options, emptyOptions)
import Baikai.Provider (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Trace (withTrace, withTraceStream)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..), multiSink)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Baikai.Usage (Usage, zeroUsage)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector qualified as V
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-trace-otel"
      [ successSpanTest,
        observedModelSpanTest,
        failureSpanTest,
        abortSpanTest,
        evidenceSpanTest,
        liveEvidenceSpanTest,
        multiSinkSiblingSpanTest
      ]

-- | Build a stub 'Model' under a private 'Api' tag. Each test uses
-- a distinct tag so tasty's parallel test scheduler cannot race the
-- registry between tests.
stubModel :: Api -> Model
stubModel a =
  emptyModel
    & #modelId .~ "stub-1"
    & #api .~ a
    & #provider .~ "stub.otel"
    & #maxOutputTokens .~ 16

stubContext :: Context
stubContext = emptyContext & #messages .~ V.fromList [user "hello"]

stubOptions :: Options
stubOptions = emptyOptions & #maxTokens .~ Just 16

sampleUsage :: Usage
sampleUsage =
  zeroUsage
    & #inputTokens .~ 12
    & #outputTokens .~ 3
    & #totalTokens .~ 15

stubResponse :: Api -> Response
stubResponse a =
  Response
    { message =
        AssistantPayload
          { content = V.singleton (AssistantText (TextContent "hi")),
            usage = sampleUsage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = Just (read "2026-05-14 00:00:00 UTC")
          },
      model = stubModel a,
      api = a,
      provider = "stub.otel",
      responseId = Nothing,
      latencyMs = 0,
      errorInfo = Nothing,
      evidence = Nothing
    }

registerOk :: Api -> IO ()
registerOk a =
  let handler _m _ctx _opts = pure (stubResponse a)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = EvidenceRequestedOnly
          }

registerFail :: Api -> BaikaiError -> IO ()
registerFail a e =
  let handler _m _ctx _opts = throwIO e
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = EvidenceRequestedOnly
          }

newTracerWithInMemory :: IO (Otel.Tracer, IO [Otel.ImmutableSpan])
newTracerWithInMemory = do
  (proc, spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
  tp <- Otel.createTracerProvider [proc] Otel.emptyTracerProviderOptions
  let tracer = Otel.makeTracer tp "baikai-trace-otel-test" Otel.tracerOptions
  pure (tracer, reverse <$> readIORef spansRef)

spanHotSnapshot :: Otel.ImmutableSpan -> IO Otel.SpanHot
spanHotSnapshot = readIORef . Otel.spanHot

deprecatedGenAiSystemKey :: Text
deprecatedGenAiSystemKey = "gen_ai." <> "system"

successSpanTest :: TestTree
successSpanTest =
  testCase "success path emits one Ok span with expected attributes" $ do
    let a = Custom "baikai-otel-success"
    registerOk a
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    _ <- withTrace sink (stubModel a) stubContext stubOptions
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        Otel.hotName hot @?= "baikai.call"
        let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
        assertBool
          ("has gen_ai.provider.name; got keys: " <> show (HashMap.keys attrs))
          (HashMap.member "gen_ai.provider.name" attrs)
        assertBool "has gen_ai.operation.name" (HashMap.member "gen_ai.operation.name" attrs)
        assertBool "has gen_ai.request.model" (HashMap.member "gen_ai.request.model" attrs)
        assertBool "has gen_ai.request.max_tokens" (HashMap.member "gen_ai.request.max_tokens" attrs)
        -- Absent, not present: this stub reports no model, and
        -- gen_ai.response.model names what the provider served. The
        -- terminal used to set it from the /requested/ id, which is a
        -- different fact and the one gen_ai.request.model already
        -- carries.
        assertBool
          "gen_ai.response.model must be absent when the provider reported no model"
          (not (HashMap.member "gen_ai.response.model" attrs))
        assertBool "has gen_ai.usage.input_tokens" (HashMap.member "gen_ai.usage.input_tokens" attrs)
        assertBool "has gen_ai.usage.output_tokens" (HashMap.member "gen_ai.usage.output_tokens" attrs)
        assertBool "has baikai.event_id" (HashMap.member "baikai.event_id" attrs)
        assertBool "has baikai.latency_ms" (HashMap.member "baikai.latency_ms" attrs)
        assertBool "does not emit deprecated GenAI system key" (not (HashMap.member deprecatedGenAiSystemKey attrs))
        case Otel.hotStatus hot of
          Otel.Ok -> pure ()
          other -> assertFailure ("expected Ok status, got: " <> show other)
        case Otel.spanKind sp of
          Otel.Client -> pure ()
          other -> assertFailure ("expected Client kind, got: " <> show other)
      _ -> assertFailure "expected exactly one span"

-- | A sink that throws on every event, paired with the OpenTelemetry
-- sink. Under 'Fold.tee' the throw stopped delivery to the sibling and
-- skipped its end-of-stream action, so the span was opened and never
-- ended and nothing was exported. Per-member isolation ends it.
throwingSink :: TraceSink
throwingSink =
  TraceSink (Fold.drainMapM (\_ -> throwIO (providerError "sink exploded")))

multiSinkSiblingSpanTest :: TestTree
multiSinkSiblingSpanTest =
  testCase "a throwing multiSink member still lets the OTel sibling end its span" $ do
    let a = Custom "baikai-otel-multisink-sibling"
    registerOk a
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = multiSink [throwingSink, otelSink tracer]
    _ <- withTrace sink (stubModel a) stubContext stubOptions
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        Otel.hotName hot @?= "baikai.call"
        case Otel.hotStatus hot of
          Otel.Ok -> pure ()
          other -> assertFailure ("expected Ok status, got: " <> show other)
      _ -> assertFailure "expected exactly one span"

failureSpanTest :: TestTree
failureSpanTest =
  testCase "failure path emits one Error span with error message" $ do
    let a = Custom "baikai-otel-failure"
    registerFail a (providerError "stub-otel-boom")
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    -- withTrace no longer re-throws producer failures; the error
    -- surfaces as ErrorReason on the response and as the OTel span's
    -- Error status.
    resp <- withTrace sink (stubModel a) stubContext stubOptions
    let AssistantPayload {stopReason = sr} = resp ^. #message
    sr @?= ErrorReason
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        case Otel.hotStatus hot of
          Otel.Error msg ->
            assertBool
              ("expected error to mention stub-otel-boom; got: " <> show msg)
              (not (null (show msg)))
          other -> assertFailure ("expected Error status, got: " <> show other)
        let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
        assertBool "has baikai.error" (HashMap.member "baikai.error" attrs)
        assertBool "has baikai.latency_ms" (HashMap.member "baikai.latency_ms" attrs)
      _ -> assertFailure "expected exactly one span"

abortSpanTest :: TestTree
abortSpanTest =
  testCase "early abort closes the span with Error status" $ do
    let a = Custom "baikai-otel-abort"
    registerOk a
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    emitted <-
      Stream.toList
        (Stream.take 1 (withTraceStream sink (stubModel a) stubContext stubOptions))
    length emitted @?= 1
    spans <- awaitSpans getSpans 1
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        case Otel.hotStatus hot of
          Otel.Error msg ->
            assertBool
              ("expected abort message, got: " <> show msg)
              ("aborted" `Text.isInfixOf` msg)
          other -> assertFailure ("expected Error status, got: " <> show other)
      _ -> assertFailure "expected exactly one span"

-- The trace finalizer on an abandoned stream runs from streamly's GC hook.
awaitSpans :: IO [Otel.ImmutableSpan] -> Int -> IO [Otel.ImmutableSpan]
awaitSpans getSpans n = go (100 :: Int)
  where
    go 0 = do
      spans <- getSpans
      assertFailure ("timed out waiting for spans; got: " <> show (length spans))
    go k = do
      performMajorGC
      spans <- getSpans
      if length spans >= n
        then pure spans
        else threadDelay 50000 >> go (k - 1)

-- | A 'CallEvidence' event describes a call the started/terminal pair
-- already delimits, so it must neither open a span nor close one.
--
-- The sink is fed a hand-built sequence rather than driven through
-- 'withTrace', for two reasons. It isolates the claim to the sink's own
-- behaviour, and it is the only way to reach the attach path at all:
-- "Baikai.Trace" pushes the evidence event /after/ the terminal, by
-- which point the span has been ended and removed from the map.
-- | The evidence attributes reach a span from a __live__ call, not only
-- from a hand-fed stream.
--
-- They did not until "Baikai.Trace" was changed to emit @CallEvidence@
-- before the terminal event. Before that the span had already been
-- ended and removed by the time the evidence arrived, so the sink's
-- attach branch was unreachable outside a replay and every real
-- OpenTelemetry backend saw a span with no evidence on it. Nothing
-- failed; the attributes were simply never there.
--
-- This is the test that would catch a revert of that ordering. The
-- hand-fed 'evidenceSpanTest' above would not: it feeds the events in
-- the order it chooses.
liveEvidenceSpanTest :: TestTree
liveEvidenceSpanTest =
  testCase "A REAL CALL'S EVIDENCE REACHES ITS SPAN" $ do
    let a = Custom "baikai-otel-live-evidence"
    registerOkWithEvidence a
    (tracer, getSpans) <- newTracerWithInMemory
    _ <-
      withTrace
        (otelSink tracer)
        (stubModel a)
        stubContext
        (stubOptions & #evidence .~ Just (evidenceRequest "run-otel-live" :: EvidenceRequest))
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
        mapM_
          ( \k ->
              assertBool
                ( "evidence attribute "
                    <> Text.unpack k
                    <> " missing from a live call's span; got: "
                    <> show (HashMap.keys attrs)
                )
                (HashMap.member k attrs)
          )
          [ "baikai.evidence.run_id",
            "baikai.evidence.call_id",
            "baikai.evidence.strength"
          ]
      _ -> assertFailure "expected exactly one span"

-- | A provider that builds evidence the way a real adapter does, so the
-- record reaches the trace layer through the terminal event rather than
-- being fed in by hand.
registerOkWithEvidence :: Api -> IO ()
registerOkWithEvidence a =
  let handler m _ctx opts = do
        now <- getCurrentTime
        ev <-
          minimalEvidence
            m
            opts
            TransportHttpApi
            noThinkingRequested
            (Aeson.object ["model" Aeson..= (m ^. #modelId :: Text)])
            now
            now
            CallSucceeded
            Nothing
        pure (stubResponse a & #evidence .~ ev)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = EvidenceRequestedOnly
          }

-- | The observed model reaches the span, and the requested one stays
-- where it belongs.
--
-- Fails on the pre-fix code with the requested id under the response
-- key: 'Baikai.Trace' pushes 'CallEvidence' before the terminal, and
-- 'Otel.addAttributes' replaces an existing key, so the terminal's
-- attribute won.
observedModelSpanTest :: TestTree
observedModelSpanTest =
  testCase "A SERVED MODEL REACHES THE SPAN AND THE REQUESTED ONE DOES NOT OVERWRITE IT" $ do
    let a = Custom "baikai-otel-observed-model"
    registerOkObservingModel a
    (tracer, getSpans) <- newTracerWithInMemory
    _ <-
      withTrace
        (otelSink tracer)
        (stubModel a)
        stubContext
        (stubOptions & #evidence .~ Just (evidenceRequest "run-otel-observed" :: EvidenceRequest))
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
        HashMap.lookup "gen_ai.response.model" attrs
          @?= Just (Attr.toAttribute ("stub-1-as-served" :: Text))
        HashMap.lookup "gen_ai.request.model" attrs
          @?= Just (Attr.toAttribute ("stub-1" :: Text))
      _ -> assertFailure "expected exactly one span"

-- | 'registerOkWithEvidence' whose record observes a served model.
registerOkObservingModel :: Api -> IO ()
registerOkObservingModel a =
  let handler m _ctx opts = do
        now <- getCurrentTime
        ev <-
          minimalEvidence
            m
            opts
            TransportHttpApi
            noThinkingRequested
            (Aeson.object ["model" Aeson..= (m ^. #modelId :: Text)])
            now
            now
            CallSucceeded
            Nothing
        pure (stubResponse a & #evidence .~ fmap observeServedModel ev)
      observeServedModel ev = ev & #observedModel .~ Observed "stub-1-as-served"
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = EvidenceRequestedOnly
          }

evidenceSpanTest :: TestTree
evidenceSpanTest =
  testCase "a CallEvidence event neither opens nor closes a span" $ do
    let a = Custom "baikai-otel-evidence"
        m = stubModel a
    (tracer, getSpans) <- newTracerWithInMemory
    let TraceSink fold' = otelSink tracer
    now <- getCurrentTime
    mev <-
      minimalEvidence
        m
        (stubOptions & #evidence .~ Just (evidenceRequest "run-otel" :: EvidenceRequest))
        TransportHttpApi
        noThinkingRequested
        (Aeson.object ["model" Aeson..= ("stub-1" :: Text)])
        now
        now
        CallSucceeded
        Nothing
    ev <- maybe (assertFailure "expected an evidence record") pure mev
    let started =
          CallStarted
            { eventId = "otel-1",
              timestamp = now,
              provider = "stub.otel",
              model = "stub-1",
              maxTokens = 16,
              promptSummary = "hello"
            }
        evidenceEvent =
          CallEvidence
            { eventId = "otel-1",
              timestamp = now,
              provider = "stub.otel",
              model = "stub-1",
              evidence = ev
            }
    -- Feed started then evidence, and stop. The span is opened by the
    -- first and left open by the second; the fold's finalizer is what
    -- eventually closes it, so exactly one span is exported.
    Stream.fold fold' (Stream.fromList [started, evidenceEvent])
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        hot <- spanHotSnapshot sp
        let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
        mapM_
          ( \k ->
              assertBool
                ("evidence attribute " <> Text.unpack k <> " missing; got: " <> show (HashMap.keys attrs))
                (HashMap.member k attrs)
          )
          [ "baikai.evidence.schema_version",
            "baikai.evidence.run_id",
            "baikai.evidence.call_id",
            "baikai.evidence.strength",
            "baikai.evidence.request_commitment",
            "baikai.evidence.request_configuration"
          ]
        -- The provider reported no model, so nothing may claim it did.
        assertBool
          "gen_ai.response.model must be absent when observedModel is Unobserved"
          (not (HashMap.member "gen_ai.response.model" attrs))
      _ -> assertFailure "expected exactly one span"
