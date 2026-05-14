{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), _Context)
import Baikai.Error (BaikaiError (..))
import Baikai.Message (Message (..), user)
import Baikai.Model (Model (..), _Model)
import Baikai.Options (Options, _Options)
import Baikai.Provider (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..), _Response)
import Baikai.StopReason (StopReason (..))
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import Baikai.Usage (_Usage)
import Control.Exception (throwIO, try)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, readIORef)
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

-- | Build a stub 'Model' under a private 'Api' tag. Each test uses
-- a distinct tag so tasty's parallel test scheduler cannot race the
-- registry between tests.
stubModel :: Api -> Model
stubModel a =
  _Model
    { modelId = "stub-1"
    , api = a
    , provider = "stub.otel"
    , maxOutputTokens = 16
    }

stubContext :: Context
stubContext = _Context {messages = V.fromList [user "hello"]}

stubOptions :: Options
stubOptions = _Options & #maxTokens .~ Just 16

stubResponse :: Api -> Response
stubResponse a =
  _Response
    { message =
        AssistantMessage
          { assistantContent = V.singleton (AssistantText (TextContent "hi"))
          , usage = _Usage
          , stopReason = Stop
          , errorMessage = Nothing
          , timestamp = read "2026-05-14 00:00:00 UTC"
          }
    , model = stubModel a
    , api = a
    , provider = "stub.otel"
    , responseId = Nothing
    , latencyMs = 0
    }

registerOk :: Api -> IO ()
registerOk a =
  registerApiProvider
    ApiProvider
      { apiTag = a
      , complete = \_m _ctx _opts -> pure (stubResponse a)
      }

registerFail :: Api -> BaikaiError -> IO ()
registerFail a e =
  registerApiProvider
    ApiProvider
      { apiTag = a
      , complete = \_m _ctx _opts -> throwIO e
      }

newTracerWithInMemory :: IO (Otel.Tracer, IO [Otel.ImmutableSpan])
newTracerWithInMemory = do
  (proc, spansRef :: IORef [Otel.ImmutableSpan]) <- inMemoryListExporter
  tp <- Otel.createTracerProvider [proc] Otel.emptyTracerProviderOptions
  let tracer = Otel.makeTracer tp "baikai-trace-otel-test" Otel.tracerOptions
  pure (tracer, reverse <$> readIORef spansRef)

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
    let a = Custom "baikai-otel-failure"
    registerFail a (ProviderError "stub-otel-boom")
    (tracer, getSpans) <- newTracerWithInMemory
    let sink = otelSink tracer
    r <- try (withTrace sink (stubModel a) stubContext stubOptions)
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
