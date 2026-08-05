module Main (main) where

import AgentAssetsSpec qualified
import AgentSpec qualified
import Baikai
import Baikai.Models.Generated
import Baikai.Prelude
import CatalogSpec qualified
import CliInternalSpec qualified
import ContextSpec qualified
import CostSpec qualified
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Text qualified as Text
import Data.Vector qualified as V
import EmbeddingSpec qualified
import ErrorInfoSpec qualified
import ErrorSpec qualified
import FetchModelsSpec qualified
import GenModelsSpec qualified
import HelpersSpec qualified
import InteractiveSpec qualified
import StreamSpec qualified
import Streamly.Data.Stream qualified as Stream
import SurfaceSpec qualified
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen)
import Test.Tasty.QuickCheck qualified as QC
import ThinkingLevelSpec qualified
import TraceSpec qualified
import UsageSpec qualified

-- | Ground the test provider on a 'Custom' API tag so it does not
-- clash with the real Anthropic/OpenAI handlers if a future test
-- registers them in the same process.
testApi :: Api
testApi = Custom "baikai-test"

testModel :: Model
testModel =
  emptyModel
    & #modelId
    .~ "test-model"
    & #name
    .~ "Test Model"
    & #api
    .~ testApi
    & #provider
    .~ "test"

-- | Install a handler that returns a fixed assistant message for
-- the 'testApi' tag. Idempotent: re-registering the same tag
-- overwrites.
registerTestHandler :: Text -> IO ()
registerTestHandler canned =
  registerApiProvider (testProvider "test" canned)

testProvider :: Text -> Text -> ApiProvider
testProvider providerName canned =
  let handler m _ctx _opts =
        pure $
          emptyResponse
            & #message
            .~ AssistantPayload
              { content = V.singleton (AssistantText (TextContent canned)),
                usage = zeroUsage,
                stopReason = Stop,
                errorMessage = Nothing,
                timestamp = Just (read "2026-06-05 00:00:00 UTC")
              }
            & #model
            .~ m
            & #api
            .~ testApi
            & #provider
            .~ providerName
   in ApiProvider
        { apiTag = testApi,
          stream = liftCompleteToStream handler,
          complete = handler
        }

main :: IO ()
main = do
  registerTestHandler "hello from the test provider"
  defaultMain $
    testGroup
      "baikai"
      [ tests,
        AgentAssetsSpec.tests,
        AgentSpec.tests,
        CatalogSpec.tests,
        CliInternalSpec.tests,
        ContextSpec.tests,
        CostSpec.tests,
        EmbeddingSpec.tests,
        ErrorInfoSpec.tests,
        ErrorSpec.tests,
        FetchModelsSpec.tests,
        GenModelsSpec.tests,
        HelpersSpec.tests,
        InteractiveSpec.tests,
        StreamSpec.tests,
        SurfaceSpec.tests,
        ThinkingLevelSpec.tests,
        TraceSpec.tests,
        UsageSpec.tests
      ]

tests :: TestTree
tests =
  testGroup
    "baikai EP-2"
    [ testCase "emptyContext defaults are zero-y" $ do
        emptyContext ^. #systemPrompt @?= Nothing
        V.length (emptyContext ^. #messages) @?= 0,
      testCase "emptyOptions defaults are zero-y" $ do
        emptyOptions ^. #maxTokens @?= Nothing
        emptyOptions ^. #temperature @?= Nothing
        emptyOptions ^. #apiKey @?= Nothing
        emptyOptions ^. #responseFormat @?= Nothing,
      testCase "responseFormat round-trips through Options" $ do
        responseFormat (emptyOptions & #responseFormat .~ Just JsonObject)
          @?= Just JsonObject
        let person =
              Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                ]
            schemaFmt = JsonSchema {name = "person", schema = person, strict = True}
        responseFormat (emptyOptions & #responseFormat .~ Just schemaFmt)
          @?= Just schemaFmt,
      testCase "Options Show redacts literal API keys" $ do
        let secret = "sk-baikai-secret-never-print"
            opts = emptyOptions & #apiKey .~ Just (ApiKeyLiteral secret)
        assertBool
          "show opts must not contain the raw API key"
          (not (secret `Text.isInfixOf` Text.pack (show opts))),
      testCase "Options JSON redacts literal API keys" $ do
        let secret = "sk-baikai-secret-never-print"
            opts = emptyOptions & #apiKey .~ Just (ApiKeyLiteral secret)
        assertBool
          "Aeson.encode opts must not contain the raw API key"
          (not (secret `Text.isInfixOf` Text.pack (LBS8.unpack (Aeson.encode opts)))),
      testCase "completeRequest dispatches through the registered handler" $ do
        let ctx = emptyContext & #messages .~ V.fromList [user "ping"]
        resp <- completeRequest testModel ctx emptyOptions
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from the test provider"))
        (resp ^. #model) ^. #modelId @?= "test-model"
        resp ^. #provider @?= "test",
      testCase "explicit registries isolate providers for the same API" $ do
        regA <- newProviderRegistry
        regB <- newProviderRegistry
        registerApiProviderWith regA (testProvider "provider-a" "hello from A")
        registerApiProviderWith regB (testProvider "provider-b" "hello from B")
        let ctx = emptyContext & #messages .~ V.fromList [user "ping"]
        respA <- completeRequestWith regA testModel ctx emptyOptions
        respB <- completeRequestWith regB testModel ctx emptyOptions
        flattenAssistantBlocks respA
          @?= V.singleton (AssistantText (TextContent "hello from A"))
        flattenAssistantBlocks respB
          @?= V.singleton (AssistantText (TextContent "hello from B"))
        respA ^. #provider @?= "provider-a"
        respB ^. #provider @?= "provider-b",
      testCase "streamRequestWith dispatches through an explicit registry" $ do
        reg <- newProviderRegistry
        registerApiProviderWith reg (testProvider "stream-provider" "hello from stream")
        let ctx = emptyContext & #messages .~ V.fromList [user "ping"]
        events <- Stream.toList (streamRequestWith reg testModel ctx emptyOptions)
        resp <- Stream.fold (reassembleResponse testModel) (Stream.fromList events)
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from stream")),
      testCase "OpenAI compat auto-detection drives provider request policy" $ do
        let deepseek =
              emptyModel
                & #api
                .~ OpenAIChatCompletions
                & #baseUrl
                .~ "https://api.deepseek.com"
            compat = openaiCompletionsCompatFor deepseek
        compat ^. #thinkingFormat @?= ThinkingFormatDeepseek
        compat ^. #maxTokensField @?= MaxTokensField
        compat ^. #supportsStrictMode @?= False,
      testCase "host auto-detection is suffix-bounded" $ do
        urlHost "http://user@openrouter.ai:8443/api" @?= Just "openrouter.ai"
        autoDetectOpenAICompletions "https://api.xyz.ai"
          @?= defaultOpenAICompletionsCompat
        autoDetectOpenAICompletions "https://evil-z.ai.example.com"
          @?= defaultOpenAICompletionsCompat
        autoDetectOpenAICompletions "https://api.z.ai/v1"
          ^. #thinkingFormat
          @?= ThinkingFormatZai
        autoDetectOpenAICompletions "https://API.DEEPSEEK.COM"
          ^. #thinkingFormat
          @?= ThinkingFormatDeepseek
        autoDetectOpenAICompletions "http://user@openrouter.ai:8443/api"
          ^. #thinkingFormat
          @?= ThinkingFormatOpenRouter
        autoDetectOpenAICompletions ""
          @?= defaultOpenAICompletionsCompat,
      QC.testProperty "unknown OpenAI host suffixes use defaults" $
        QC.forAll unknownHostGen $ \host ->
          QC.property $
            autoDetectOpenAICompletions ("https://" <> Text.pack host)
              == defaultOpenAICompletionsCompat,
      testCase "default API-key env table matches known hosts" $ do
        defaultApiKeyEnvForBaseUrl "https://api.deepseek.com/v1"
          @?= Just "DEEPSEEK_API_KEY"
        defaultApiKeyEnvForBaseUrl "http://user@openrouter.ai:8443/api"
          @?= Just "OPENROUTER_API_KEY"
        defaultApiKeyEnvForBaseUrl "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
          @?= Just "DASHSCOPE_API_KEY"
        defaultApiKeyEnvForBaseUrl "https://api.xyz.ai"
          @?= Nothing
        defaultApiKeyEnvForBaseUrl ""
          @?= Nothing,
      testCase "explicit OpenAI compat overrides baseUrl auto-detection" $ do
        let explicit =
              defaultOpenAICompletionsCompat
                { supportsStrictMode = False,
                  thinkingFormat = ThinkingFormatNone
                }
            model =
              emptyModel
                & #api
                .~ OpenAIChatCompletions
                & #baseUrl
                .~ "https://api.openai.com"
                & #compat
                .~ CompatOpenAICompletions explicit
            compat = openaiCompletionsCompatFor model
        compat ^. #supportsStrictMode @?= False
        compat ^. #thinkingFormat @?= ThinkingFormatNone,
      testCase "Anthropic compat auto-detection drives cache request policy" $ do
        let fireworks =
              emptyModel
                & #api
                .~ AnthropicMessages
                & #baseUrl
                .~ "https://api.fireworks.ai/inference/v1"
            compat = anthropicMessagesCompatFor fireworks
        compat ^. #supportsCacheControlOnTools @?= False
        compat ^. #sendSessionAffinityHeaders @?= True
        compat ^. #supportsLongCacheRetention @?= False
        compat ^. #thinkingStyle @?= AnthropicThinkingBudget,
      testCase "Anthropic compat defaults thinking style by model generation" $ do
        anthropicMessagesCompatFor anthropic_claude_opus_4_6
          ^. #thinkingStyle
          @?= AnthropicThinkingAdaptive
        anthropicMessagesCompatFor anthropic_claude_opus_4_7
          ^. #thinkingStyle
          @?= AnthropicThinkingAdaptive
        anthropicMessagesCompatFor anthropic_claude_opus_4_8
          ^. #thinkingStyle
          @?= AnthropicThinkingAdaptive
        anthropicMessagesCompatFor anthropic_claude_fable_5
          ^. #thinkingStyle
          @?= AnthropicThinkingAdaptive
        anthropicMessagesCompatFor anthropic_claude_haiku_4_5
          ^. #thinkingStyle
          @?= AnthropicThinkingBudget
        anthropicMessagesCompatFor anthropic_claude_opus_4_5
          ^. #thinkingStyle
          @?= AnthropicThinkingBudget
        anthropicMessagesCompatFor anthropic_claude_sonnet_4_5
          ^. #thinkingStyle
          @?= AnthropicThinkingBudget
        anthropicMessagesCompatFor anthropic_claude_sonnet_4_6
          ^. #thinkingStyle
          @?= AnthropicThinkingBudget,
      testCase "user smart constructor produces a UserMessage" $ do
        let ts = read "2026-06-05 01:02:03 UTC"
        case userAt ts "hello" of
          UserMessage UserPayload {content = uc, timestamp = actualTs} -> do
            uc @?= V.singleton (UserText (TextContent "hello"))
            actualTs @?= Just ts
          _ -> error "expected UserMessage",
      testCase "assistant smart constructor produces an AssistantMessage" $ do
        let ts = read "2026-06-05 01:02:03 UTC"
        case assistantAt ts "world" of
          AssistantMessage AssistantPayload {content = ac, stopReason = sr, timestamp = actualTs} -> do
            ac @?= V.singleton (AssistantText (TextContent "world"))
            sr @?= Stop
            actualTs @?= Just ts
          _ -> error "expected AssistantMessage",
      testCase "effectful user constructor produces a UserMessage in IO" $ do
        msg <- userNow "hello now"
        case msg of
          UserMessage UserPayload {content = uc} ->
            uc @?= V.singleton (UserText (TextContent "hello now"))
          _ -> error "expected UserMessage",
      testCase "appendToolResult carries text, image, and error payloads" $ do
        let textCall =
              emptyToolCall
                { id_ = "call_text",
                  name = "text_tool",
                  arguments = Aeson.object []
                }
            imageCall =
              emptyToolCall
                { id_ = "call_image",
                  name = "image_tool",
                  arguments = Aeson.object []
                }
            errorCall =
              emptyToolCall
                { id_ = "call_error",
                  name = "error_tool",
                  arguments = Aeson.object []
                }
            assistantTurn =
              AssistantMessage
                AssistantPayload
                  { content =
                      V.fromList
                        [ AssistantToolCall textCall,
                          AssistantToolCall imageCall,
                          AssistantToolCall errorCall
                        ],
                    usage = zeroUsage,
                    stopReason = ToolUse,
                    errorMessage = Nothing,
                    timestamp = Just (read "2026-06-05 00:00:00 UTC")
                  }
            resp = emptyResponse & #message .~ assistantPayload
            assistantPayload = case assistantTurn of
              AssistantMessage p -> p
              _ -> error "expected assistant fixture"
            ctx0 = emptyContext & #messages .~ V.singleton (user "use tools")
            image = ImageContent {imageData = BS8.pack "png-bytes", mimeType = "image/png"}
            dispatcher tc = case tc ^. #name of
              "text_tool" -> pure (toolResultText "text result")
              "image_tool" -> pure (toolResultImage image)
              "error_tool" -> pure (toolResultErrorText "tool failed")
              other -> error ("unexpected tool: " <> Text.unpack other)
        ctx1 <- appendToolResult ctx0 resp dispatcher
        case V.toList (ctx1 ^. #messages) of
          [_, assistantMsg, ToolResultMessage textPayload, ToolResultMessage imagePayload, ToolResultMessage errorPayload] -> do
            assistantMsg @?= assistantTurn
            case textPayload of
              ToolResultPayload {toolCallId = callId, content = blocks, isError = err} -> do
                callId @?= "call_text"
                blocks @?= V.singleton (ToolResultText (TextContent "text result"))
                err @?= False
            case imagePayload of
              ToolResultPayload {toolCallId = callId, content = blocks, isError = err} -> do
                callId @?= "call_image"
                blocks @?= V.singleton (ToolResultImage image)
                err @?= False
            case errorPayload of
              ToolResultPayload {toolCallId = callId, content = blocks, isError = err} -> do
                callId @?= "call_error"
                blocks @?= V.singleton (ToolResultText (TextContent "tool failed"))
                err @?= True
          msgs -> error ("unexpected context messages: " <> show msgs)
    ]

unknownHostGen :: Gen String
unknownHostGen = do
  label <- QC.listOf1 (QC.elements (['a' .. 'z'] <> ['0' .. '9']))
  pure (label <> ".example.invalid")
