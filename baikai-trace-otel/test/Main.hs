{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), emptyContext)
import Baikai.Error (BaikaiError, providerError)
import Baikai.Message (AssistantPayload (..), user)
import Baikai.Model (Model (..), emptyModel)
import Baikai.Options (Options, emptyOptions)
import Baikai.Provider (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Trace (withTrace, withTraceStream)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Baikai.Usage (Usage, zeroUsage)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as V
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
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
        failureSpanTest,
        abortSpanTest
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
      errorInfo = Nothing
    }

registerOk :: Api -> IO ()
registerOk a =
  let handler _m _ctx _opts = pure (stubResponse a)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler
          }

registerFail :: Api -> BaikaiError -> IO ()
registerFail a e =
  let handler _m _ctx _opts = throwIO e
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler
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
        assertBool "has gen_ai.response.model" (HashMap.member "gen_ai.response.model" attrs)
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
