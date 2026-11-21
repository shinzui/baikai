{-# LANGUAGE OverloadedRecordDot #-}

module ResponsesStreamSpec (tests) where

import Baikai hiding (delta, model)
import Baikai.Models.Generated (openai_gpt_6_astra)
import Baikai.Provider.OpenAI.Internal.Stream (SseDriver)
import Baikai.Provider.OpenAI.Responses.Stream (openaiResponsesStreamWith)
import Baikai.Provider.OpenAI.Sse (ResponseMetadata (..))
import Contract (assertErrorContract)
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses stream"
    [ testCase "terminal usage merges earlier categories and evidence matches its cost" $ do
        let finished = object ["type" .= ("response.completed" :: Text), "response" .= object ["id" .= ("resp_usage" :: Text), "service_tier" .= ("default" :: Text), "output" .= [item "hello"], "usage" .= object ["output_tokens" .= (100 :: Int), "input_tokens_details" .= object ["cache_write_tokens" .= (3000 :: Int)]]]]
        events <- Stream.toList (openaiResponsesStreamWith (driver [usageStarted, finished, finished]) model emptyContext (options & #evidence .~ Just (evidenceRequest "billing")))
        case last events of
          EventDone p -> case p.message of
            AssistantMessage msg -> do
              let u = msg.usage
              (u.inputTokens, u.cacheReadTokens, u.cacheWriteTokens, u.totalTokens) @?= (0, 12000, 3000, 15100)
              u.cost.usd @?= 109 / 2000
              u.cost.basis.estimateReasons @?= Set.empty
              case p.evidence of
                Just ev -> ev.usage @?= Observed u
                Nothing -> assertFailure "missing evidence"
            _ -> assertFailure "expected assistant"
          _ -> assertFailure "expected completion",
      testCase "partial usage survives a failed stream with missing categories explicit" $ do
        events <- run [usageStarted, added, delta]
        assertErrorContract events
        case last events of
          EventError p -> case p.message of
            AssistantMessage msg -> do
              msg.usage.cacheReadTokens @?= 12000
              msg.usage.inputTokens @?= 3000
              msg.usage.cost.basis.estimateReasons @?= Set.fromList [OutputUsageNotReported, CacheWriteUsageNotReported, ServiceTierNotReported]
            _ -> assertFailure "expected assistant"
          _ -> assertFailure "expected failure",
      testCase "complete folds the same stream, including final-only content" $ do
        response <- streamingComplete (openaiResponsesStreamWith (driver [completed])) model emptyContext options
        response.message.content @?= V.singleton (AssistantText (TextContent "hello"))
        response.message.stopReason @?= Stop
        response.responseId @?= Just "resp_actual",
      testCase "EOF after a text delta closes partial content and fails" $ do
        events <- run [added, delta]
        assertErrorContract events
        case last events of
          EventError p -> case p.message of
            AssistantMessage msg -> msg.content @?= V.singleton (AssistantText (TextContent "hel"))
            _ -> assertFailure "wrong message role"
          _ -> assertFailure "expected error",
      testCase "in-band rate limit preserves classification" $ do
        events <- run [object ["type" .= ("error" :: Text), "code" .= ("rate_limit_exceeded" :: Text), "message" .= ("slow down" :: Text)]]
        assertErrorContract events
        case last events of
          EventError p -> fmap (^. #category) p.errorInfo @?= Just RateLimited
          _ -> assertFailure "expected error",
      testCase "failed response preserves its nested error" $ do
        events <- run [object ["type" .= ("response.failed" :: Text), "response" .= object ["id" .= ("failed_id" :: Text), "error" .= object ["code" .= ("rate_limit_exceeded" :: Text), "message" .= ("busy" :: Text)]]]]
        assertErrorContract events
        case last events of
          EventError p -> do
            p.responseId @?= Just "failed_id"
            fmap (^. #category) p.errorInfo @?= Just RateLimited
          _ -> assertFailure "expected error",
      testCase "malformed event becomes a terminal error with partial text" $ do
        events <- run [added, delta, object []]
        assertErrorContract events,
      testCase "completed terminal cancels a driver waiting for more bytes" $ do
        closed <- newEmptyMVar
        let waiting _ _ _ _ emit = (emit (Right completed) >> threadDelay 10000000) `finally` putMVar closed ()
        result <- timeout 2000000 (Stream.toList (openaiResponsesStreamWith waiting model emptyContext options))
        assertBool "stream completed promptly" (maybe False (not . null) result)
        timeout 1000000 (takeMVar closed) >>= (@?= Just ()),
      testCase "consumer timeout releases a driver blocked mid-response" $ do
        closed <- newEmptyMVar
        let waiting _ _ _ _ emit = (emit (Right added) >> emit (Right delta) >> threadDelay 10000000) `finally` putMVar closed ()
        result <- timeout 100000 (Stream.toList (openaiResponsesStreamWith waiting model emptyContext options))
        assertBool "consumer was cancelled" (case result of Nothing -> True; _ -> False)
        timeout 1000000 (takeMVar closed) >>= (@?= Just ()),
      testCase "slow active consumer can drain the complete response" $ do
        result <- timeout 2000000 $ Stream.toList $ Stream.mapM (\e -> threadDelay 20000 >> pure e) (openaiResponsesStreamWith (driver [added, delta, completed]) model emptyContext options)
        case result of
          Just events -> length [() | EventDone _ <- events] @?= 1
          Nothing -> assertFailure "slow consumer did not finish",
      testCase "validation fails before the driver starts" $ do
        called <- newIORef False
        let forbidden _ _ _ _ _ = writeIORef called True
        events <- Stream.toList (openaiResponsesStreamWith forbidden model emptyContext (options & #seed .~ Just 1))
        assertErrorContract events
        readIORef called >>= (@?= False),
      testCase "public two-turn tool loop preserves encrypted reasoning and call identity" $ do
        requests <- newIORef ([] :: [Value])
        let reasoning = object ["type" .= ("reasoning" :: Text), "id" .= ("rs_1" :: Text), "summary" .= ([] :: [Value]), "encrypted_content" .= ("encrypted" :: Text), "unknown" .= True]
            call = object ["type" .= ("function_call" :: Text), "id" .= ("item_1" :: Text), "call_id" .= ("call_1" :: Text), "name" .= ("lookup" :: Text), "arguments" .= ("{}" :: Text), "status" .= ("completed" :: Text)]
            first = object ["type" .= ("response.completed" :: Text), "response" .= object ["output" .= [reasoning, call]]]
            scripted _ _ body _ emit = do
              previous <- readIORef requests
              writeIORef requests (previous <> [body])
              emit (Right (if null previous then first else completed))
            provider = apiProvider OpenAIResponses (openaiResponsesStreamWith scripted)
            ctx = systemUser "system" "find it" & #tools .~ V.singleton (mkTool "lookup" "lookup" (object ["type" .= ("object" :: Text)]))
        reg <- newProviderRegistryFrom [provider]
        executed <- newIORef ([] :: [Text])
        (_, result) <- runToolLoopWith reg 3 (\tc -> writeIORef executed [tc.id_] >> pure (toolResultText "found")) model ctx options
        result.message.content @?= V.singleton (AssistantText (TextContent "hello"))
        readIORef executed >>= (@?= ["call_1"])
        bodies <- readIORef requests
        length bodies @?= 2
        case bodies of
          [_, Object second] -> case KM.lookup "input" second of
            Just (Array items) -> do
              items V.! 1 @?= reasoning
              case items V.! 3 of
                Object reply -> do
                  KM.lookup "call_id" reply @?= Just (String "call_1")
                  KM.lookup "output" reply @?= Just (String "found")
                _ -> assertFailure "missing function output"
            _ -> assertFailure "missing input"
          _ -> assertFailure "expected two requests",
      testCase "persisted history retains the entire input prefix over two tool rounds" $ do
        sent <- newIORef []
        let m = model & #compat .~ CompatOpenAIResponses (defaultOpenAIResponsesCompat & #systemPromptInInput .~ True)
            firstCall = toolItem "fc_1" "call_1" "{ \"key\" : 1 }"
            secondCall = toolItem "fc_2" "call_2" "{ \"key\" : 2 }"
            progress = object ["type" .= String "message", "id" .= String "msg_progress", "role" .= String "assistant", "status" .= String "completed", "phase" .= String "commentary", "content" .= [part "working", part " on it"]]
            reasoning = object ["type" .= String "reasoning", "id" .= String "rs_2", "summary" .= ([] :: [Value]), "encrypted_content" .= String "opaque"]
            initial = systemUser "stable" "find it" & #tools .~ V.singleton (mkTool "lookup" "lookup" (object ["type" .= String "object"]))
            step output context = do
              let stream = openaiResponsesStreamWith $ \_ _ body _ emit -> do
                    previous <- readIORef sent
                    writeIORef sent (previous <> [body])
                    emit (Right (terminalOutput output))
              response <- streamingComplete stream m context options
              either assertFailure pure (parseEither responseFromJSON (responseToJSON response))
            append expected ctx response =
              appendToolResult ctx response $ \tc -> do
                tc.id_ @?= expected
                pure (toolResultText ("result-" <> expected))
        first <- step [progress, firstCall] initial
        progressBlock <- case V.toList first.message.content of
          [block@(AssistantText (TextContent "working on it")), AssistantToolCall _] -> pure block
          _ -> assertFailure "missing text and function call"
        fmap (.outputReplayItem) (outputItemReplay progressBlock) @?= Just progress
        ctx2 <- append "call_1" initial first
        second <- step [reasoning, secondCall] ctx2
        ctx3 <- append "call_2" ctx2 second
        final <- step [item "hello"] ctx3
        final.message.stopReason @?= Stop
        requests <- readIORef sent
        case map requestInput requests of
          [a, b, c] -> do
            b @?= a <> [progress, firstCall, toolOutput "call_1"]
            c @?= b <> [reasoning, secondCall, toolOutput "call_2"]
          _ -> assertFailure "expected three requests",
      testCase "inconsistent or foreign output replay is refused before transport" $ do
        let raw = toolItem "item" "call" "{ \"key\": 1 }"
            scope = OutputItemReplay OpenAIResponses model.modelId raw
            tool = AssistantToolCall (ToolCall "call" "lookup" (object ["key" .= Number 1]))
            edited = AssistantToolCall (ToolCall "call" "lookup" (object ["key" .= Number 2]))
            forbidden _ _ _ _ _ = assertFailure "driver must not run"
        forM_ [(scope, edited), (scope {outputReplayApi = AnthropicMessages}, tool), (scope {outputReplayModel = "foreign"}, tool), (scope {outputReplayItem = Null}, tool)] $ \(state, block) -> do
          let ctx = addResponse (emptyResponse & #message . #content .~ V.singleton (withOutputItemReplay state block)) emptyContext
          assertBool "Show must omit the provider item" (show (withOutputItemReplay state block) == show block)
          failed <- streamingComplete (openaiResponsesStreamWith forbidden) model ctx options
          fmap (^. #category) (responseError failed) @?= Just InvalidRequest,
      testCase "legacy assistant blocks decode without output replay and keep their wire shapes" $ do
        let text = object ["type" .= String "assistant_text", "data" .= object ["text" .= String "legacy"]]
            call = object ["type" .= String "assistant_tool_call", "data" .= object ["id" .= String "old_call", "name" .= String "lookup", "arguments" .= object []]]
        blocks <- either assertFailure pure (Aeson.eitherDecode (Aeson.encode [text, call]))
        map outputItemReplay blocks @?= [Nothing, Nothing]
        Aeson.toJSON blocks @?= Aeson.toJSON [text, call],
      testCase "refusal, incomplete response and provider failure keep their terminal classifications" $ do
        let partial = object ["type" .= String "function_call", "id" .= String "fc_partial", "call_id" .= String "call_partial", "name" .= String "lookup", "arguments" .= String "{}", "status" .= String "incomplete"]
            started = object ["type" .= String "response.output_item.added", "output_index" .= Number 0, "item" .= partial]
            incomplete = object ["type" .= String "response.incomplete", "response" .= object ["output" .= [partial], "incomplete_details" .= object ["reason" .= String "max_output_tokens"]]]
            failed = object ["type" .= String "response.failed", "response" .= object ["error" .= object ["code" .= String "rate_limit_exceeded", "message" .= String "busy"]]]
            refusal = terminalOutput [object ["type" .= String "message", "id" .= String "msg_refusal", "role" .= String "assistant", "status" .= String "completed", "content" .= [object ["type" .= String "refusal", "refusal" .= String "declined"]]]]
        forM_ [([refusal], Stop, Nothing), ([started, incomplete], Length, Nothing), ([started, failed], ErrorReason, Just RateLimited)] $ \(frames, reason, category) -> do
          dispatched <- newIORef False
          reg <- newProviderRegistryFrom [apiProvider OpenAIResponses (openaiResponsesStreamWith (driver frames))]
          (_, response) <- runToolLoopWith reg 3 (const (writeIORef dispatched True >> pure (toolResultText "unexpected"))) model emptyContext options
          readIORef dispatched >>= (@?= False)
          response.message.stopReason @?= reason
          fmap (^. #category) (responseError response) @?= category,
      testCase "evidence commits to the exact outgoing request and observed header" $ do
        sent <- newIORef Null
        let capturing _ _ body meta emit = do
              writeIORef sent body
              meta (ResponseMetadata 200 [("x-request-id", "req_observed")])
              emit (Right completed)
        events <- Stream.toList (openaiResponsesStreamWith capturing model emptyContext (options & #evidence .~ Just (evidenceRequest "wire-test")))
        body <- readIORef sent
        case last events of
          EventDone p -> case p.evidence of
            Just ev -> do
              ev.requestCommitment @?= commitmentDigest body
              (ev ^. #endpoint ^. #endpoint) @?= Just "https://api.openai.com/v1/responses"
              ev.providerRequestId @?= Observed "req_observed"
              ev.strength @?= declaredStrength OpenAIResponses
            Nothing -> assertFailure "missing evidence"
          _ -> assertFailure "missing success",
      testCase "evidence uses observed model and exact response content" $ do
        events <- Stream.toList (openaiResponsesStreamWith (driver [completed]) model emptyContext (options & #evidence .~ Just (evidenceRequest "responses-test")))
        case last events of
          EventDone p -> case p.evidence of
            Just ev -> do
              ev.observedModel @?= Observed "server-model"
              ev.responseId @?= Observed "resp_actual"
              ev.usage @?= Unobserved
              assertBool "response commitment exists" (case ev.responseCommitment of Observed _ -> True; _ -> False)
            Nothing -> assertFailure "missing evidence"
          _ -> assertFailure "missing success"
    ]

run :: [Value] -> IO [AssistantMessageEvent]
run frames = Stream.toList (openaiResponsesStreamWith (driver frames) model emptyContext options)

driver :: [Value] -> SseDriver
driver frames _ _ _ _ emit = mapM_ (emit . Right) frames

model :: Model
model = openai_gpt_6_astra & #modelId .~ "configured-model"

options :: Options
options = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "offline-test-key")

item :: Text -> Value
item t = object ["type" .= ("message" :: Text), "id" .= ("msg" :: Text), "content" .= [object ["type" .= ("output_text" :: Text), "text" .= t]]]

added :: Value
added = object ["type" .= ("response.output_item.added" :: Text), "output_index" .= (0 :: Int), "item" .= item ""]

delta :: Value
delta = object ["type" .= ("response.output_text.delta" :: Text), "output_index" .= (0 :: Int), "content_index" .= (0 :: Int), "item_id" .= ("msg" :: Text), "delta" .= ("hel" :: Text)]

completed :: Value
completed = object ["type" .= ("response.completed" :: Text), "response" .= object ["id" .= ("resp_actual" :: Text), "model" .= ("server-model" :: Text), "output" .= [item "hello"]]]

usageStarted :: Value
usageStarted = object ["type" .= ("response.created" :: Text), "response" .= object ["id" .= ("resp_usage" :: Text), "usage" .= object ["input_tokens" .= (15000 :: Int), "input_tokens_details" .= object ["cached_tokens" .= (12000 :: Int)]]]]

part :: Text -> Value
part t = object ["type" .= String "output_text", "text" .= t, "annotations" .= ([] :: [Value])]

toolItem :: Text -> Text -> Text -> Value
toolItem ident call args =
  object ["type" .= String "function_call", "id" .= ident, "call_id" .= call, "name" .= String "lookup", "arguments" .= args, "status" .= String "completed"]

toolOutput :: Text -> Value
toolOutput call = object ["type" .= String "function_call_output", "call_id" .= call, "output" .= ("result-" <> call)]

terminalOutput :: [Value] -> Value
terminalOutput items = object ["type" .= String "response.completed", "response" .= object ["output" .= items]]

requestInput :: Value -> [Value]
requestInput (Object obj) = case KM.lookup "input" obj of
  Just (Array xs) -> V.toList xs
  _ -> []
requestInput _ = []
