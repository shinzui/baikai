module Main (main) where

import AgentAssetsSpec qualified
import Baikai
import Baikai.Prelude
import CatalogSpec qualified
import CostSpec qualified
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Text qualified as Text
import Data.Vector qualified as V
import InteractiveSpec qualified
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import TraceSpec qualified

-- | Ground the test provider on a 'Custom' API tag so it does not
-- clash with the real Anthropic/OpenAI handlers if a future test
-- registers them in the same process.
testApi :: Api
testApi = Custom "baikai-test"

testModel :: Model
testModel =
  _Model
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
          _Response
            & #message
            .~ AssistantPayload
              { content = V.singleton (AssistantText (TextContent canned)),
                usage = _Usage,
                stopReason = Stop,
                errorMessage = Nothing,
                timestamp = read "2026-06-05 00:00:00 UTC"
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
        CatalogSpec.tests,
        CostSpec.tests,
        InteractiveSpec.tests,
        TraceSpec.tests
      ]

tests :: TestTree
tests =
  testGroup
    "baikai EP-2"
    [ testCase "_Context defaults are zero-y" $ do
        _Context ^. #systemPrompt @?= Nothing
        V.length (_Context ^. #messages) @?= 0,
      testCase "_Options defaults are zero-y" $ do
        _Options ^. #maxTokens @?= Nothing
        _Options ^. #temperature @?= Nothing
        _Options ^. #apiKey @?= Nothing
        _Options ^. #responseFormat @?= Nothing,
      testCase "responseFormat round-trips through Options" $ do
        responseFormat (_Options & #responseFormat .~ Just JsonObject)
          @?= Just JsonObject
        let person =
              Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                ]
            schemaFmt = JsonSchema {name = "person", schema = person, strict = True}
        responseFormat (_Options & #responseFormat .~ Just schemaFmt)
          @?= Just schemaFmt,
      testCase "Options Show redacts literal API keys" $ do
        let secret = "sk-baikai-secret-never-print"
            opts = _Options & #apiKey .~ Just (ApiKeyLiteral secret)
        assertBool
          "show opts must not contain the raw API key"
          (not (secret `Text.isInfixOf` Text.pack (show opts))),
      testCase "Options JSON redacts literal API keys" $ do
        let secret = "sk-baikai-secret-never-print"
            opts = _Options & #apiKey .~ Just (ApiKeyLiteral secret)
        assertBool
          "Aeson.encode opts must not contain the raw API key"
          (not (secret `Text.isInfixOf` Text.pack (LBS8.unpack (Aeson.encode opts)))),
      testCase "completeRequest dispatches through the registered handler" $ do
        let ctx = _Context & #messages .~ V.fromList [user "ping"]
        resp <- completeRequest testModel ctx _Options
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from the test provider"))
        (resp ^. #model) ^. #modelId @?= "test-model"
        resp ^. #provider @?= "test",
      testCase "explicit registries isolate providers for the same API" $ do
        regA <- newProviderRegistry
        regB <- newProviderRegistry
        registerApiProviderWith regA (testProvider "provider-a" "hello from A")
        registerApiProviderWith regB (testProvider "provider-b" "hello from B")
        let ctx = _Context & #messages .~ V.fromList [user "ping"]
        respA <- completeRequestWith regA testModel ctx _Options
        respB <- completeRequestWith regB testModel ctx _Options
        flattenAssistantBlocks respA
          @?= V.singleton (AssistantText (TextContent "hello from A"))
        flattenAssistantBlocks respB
          @?= V.singleton (AssistantText (TextContent "hello from B"))
        respA ^. #provider @?= "provider-a"
        respB ^. #provider @?= "provider-b",
      testCase "streamRequestWith dispatches through an explicit registry" $ do
        reg <- newProviderRegistry
        registerApiProviderWith reg (testProvider "stream-provider" "hello from stream")
        let ctx = _Context & #messages .~ V.fromList [user "ping"]
        events <- Stream.toList (streamRequestWith reg testModel ctx _Options)
        resp <- Stream.fold (reassembleResponse testModel) (Stream.fromList events)
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from stream")),
      testCase "OpenAI compat auto-detection drives provider request policy" $ do
        let deepseek =
              _Model
                & #api
                .~ OpenAIChatCompletions
                & #baseUrl
                .~ "https://api.deepseek.com"
            compat = openaiCompletionsCompatFor deepseek
        compat ^. #thinkingFormat @?= ThinkingFormatDeepseek
        compat ^. #maxTokensField @?= MaxTokensField
        compat ^. #supportsStrictMode @?= False
        compat ^. #supportsDeveloperRole @?= False,
      testCase "explicit OpenAI compat overrides baseUrl auto-detection" $ do
        let explicit =
              defaultOpenAICompletionsCompat
                { supportsStrictMode = False,
                  thinkingFormat = ThinkingFormatNone
                }
            model =
              _Model
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
              _Model
                & #api
                .~ AnthropicMessages
                & #baseUrl
                .~ "https://api.fireworks.ai/inference/v1"
            compat = anthropicMessagesCompatFor fireworks
        compat ^. #supportsCacheControlOnTools @?= False
        compat ^. #sendSessionAffinityHeaders @?= True
        compat ^. #supportsLongCacheRetention @?= False,
      testCase "user smart constructor produces a UserMessage" $ do
        let ts = read "2026-06-05 01:02:03 UTC"
        case userAt ts "hello" of
          UserMessage UserPayload {content = uc, timestamp = actualTs} -> do
            uc @?= V.singleton (UserText (TextContent "hello"))
            actualTs @?= ts
          _ -> error "expected UserMessage",
      testCase "assistant smart constructor produces an AssistantMessage" $ do
        let ts = read "2026-06-05 01:02:03 UTC"
        case assistantAt ts "world" of
          AssistantMessage AssistantPayload {content = ac, stopReason = sr, timestamp = actualTs} -> do
            ac @?= V.singleton (AssistantText (TextContent "world"))
            sr @?= Stop
            actualTs @?= ts
          _ -> error "expected AssistantMessage",
      testCase "effectful user constructor produces a UserMessage in IO" $ do
        msg <- userNow "hello now"
        case msg of
          UserMessage UserPayload {content = uc} ->
            uc @?= V.singleton (UserText (TextContent "hello now"))
          _ -> error "expected UserMessage",
      testCase "appendToolResult carries text, image, and error payloads" $ do
        let textCall =
              _ToolCall
                { id_ = "call_text",
                  name = "text_tool",
                  arguments = Aeson.object []
                }
            imageCall =
              _ToolCall
                { id_ = "call_image",
                  name = "image_tool",
                  arguments = Aeson.object []
                }
            errorCall =
              _ToolCall
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
                    usage = _Usage,
                    stopReason = ToolUse,
                    errorMessage = Nothing,
                    timestamp = read "2026-06-05 00:00:00 UTC"
                  }
            resp = _Response & #message .~ assistantPayload
            assistantPayload = case assistantTurn of
              AssistantMessage p -> p
              _ -> error "expected assistant fixture"
            ctx0 = _Context & #messages .~ V.singleton (user "use tools")
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
