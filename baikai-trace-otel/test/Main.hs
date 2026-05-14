{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Baikai.Error (BaikaiError (..))
import Baikai.Message (user)
import Baikai.Model (Model (..))
import Baikai.Provider (Provider (..))
import Baikai.Request (Request (..))
import Baikai.Response (Response (..))
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Control.Exception (throwIO, try)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, readIORef)
import Data.HashMap.Strict qualified as HashMap
import Data.Vector qualified as V
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as Otel
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-trace-otel"
      [ successSpanTest
      , failureSpanTest
      ]

-- | Stub provider that either returns a canned 'Response' or throws a
-- 'BaikaiError'. Same shape as the stub used in the EP-5 TraceSpec tests.
data Stub
  = StubOk Response
  | StubFail BaikaiError

instance Provider Stub where
  providerName _ = "stub.otel"
  runRequest (StubOk r) _ = pure r
  runRequest (StubFail e) _ = liftIO (throwIO e)

stubResponse :: Response
stubResponse =
  Response
    { content = "hi"
    , model = Model "stub-1"
    , usage = Nothing
    , cost = Nothing
    , provider = "stub.otel"
    , latencyMs = 0
    }

stubRequest :: Request
stubRequest =
  Request
    { model = Model "stub-1"
    , messages = V.fromList [user "hello"]
    , maxTokens = 16
    , temperature = Nothing
    , systemPrompt = Nothing
    }

-- | Build a 'Tracer' backed by the in-memory list exporter and return an
-- accessor that reads the recorded spans. The list is prepended-to by
-- 'inMemoryListExporter', so we reverse on read.
newTracerWithInMemory :: IO (Otel.Tracer, IO [Otel.ImmutableSpan])
newTracerWithInMemory = do
  (proc, spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
  tp <- Otel.createTracerProvider [proc] Otel.emptyTracerProviderOptions
  let tracer = Otel.makeTracer tp "baikai-trace-otel-test" Otel.tracerOptions
  pure (tracer, reverse <$> readIORef spansRef)

successSpanTest :: TestTree
successSpanTest =
  testCase "success path emits one Ok span with expected attributes" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    _ <- withTrace sink (StubOk stubResponse) stubRequest
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        Otel.spanName sp @?= "baikai.call"
        let attrs = Attr.getAttributeMap (Otel.spanAttributes sp)
        assertBool
          ("has gen_ai.system; got keys: " <> show (HashMap.keys attrs))
          (HashMap.member "gen_ai.system" attrs)
        assertBool "has gen_ai.request.model" (HashMap.member "gen_ai.request.model" attrs)
        assertBool "has gen_ai.request.max_tokens" (HashMap.member "gen_ai.request.max_tokens" attrs)
        assertBool "has gen_ai.response.model" (HashMap.member "gen_ai.response.model" attrs)
        assertBool "has baikai.event_id" (HashMap.member "baikai.event_id" attrs)
        assertBool "has baikai.latency_ms" (HashMap.member "baikai.latency_ms" attrs)
        case Otel.spanStatus sp of
          Otel.Ok -> pure ()
          other -> assertFailure ("expected Ok status, got: " <> show other)
        case Otel.spanKind sp of
          Otel.Client -> pure ()
          other -> assertFailure ("expected Client kind, got: " <> show other)
      _ -> assertFailure "expected exactly one span"

failureSpanTest :: TestTree
failureSpanTest =
  testCase "failure path emits one Error span with error message" $ do
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    r <- try (withTrace sink (StubFail (ProviderError "stub-otel-boom")) stubRequest)
    case r of
      Left (e :: BaikaiError) -> e @?= ProviderError "stub-otel-boom"
      Right (_ :: Response) -> assertFailure "expected exception, got response"
    spans <- getSpans
    assertEqual "exactly one span recorded" 1 (length spans)
    case spans of
      [sp] -> do
        case Otel.spanStatus sp of
          Otel.Error msg ->
            assertBool
              ("expected error to mention stub-otel-boom; got: " <> show msg)
              (not (null (show msg)))
          other -> assertFailure ("expected Error status, got: " <> show other)
        let attrs = Attr.getAttributeMap (Otel.spanAttributes sp)
        assertBool "has baikai.error" (HashMap.member "baikai.error" attrs)
        assertBool "has baikai.latency_ms" (HashMap.member "baikai.latency_ms" attrs)
      _ -> assertFailure "expected exactly one span"
