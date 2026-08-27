{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE UndecidableInstances #-}

module Main (main) where

import AgentAssetsSpec qualified
import AgentSpec qualified
import Baikai
import Baikai.Models.Generated
import Baikai.Prelude
import CatalogSpec qualified
import CliInternalSpec qualified
import ContextSpec qualified
import Control.Monad (forM_)
import CostSpec qualified
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Kind (Type)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text qualified as Text
import Data.Vector qualified as V
import EmbeddingSpec qualified
import ErrorInfoSpec qualified
import ErrorSpec qualified
import EvidenceSpec qualified
import FetchModelsSpec qualified
import GHC.Generics (C1, D1, Rep, S1, Selector (selName), (:*:))
import GenModelsSpec qualified
import HelpersSpec qualified
import InteractiveSpec qualified
import StreamSpec qualified
import Streamly.Data.Stream qualified as Stream
import StrictEvidenceSpec qualified
import SurfaceSpec qualified
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Gen)
import Test.Tasty.QuickCheck qualified as QC
import ThinkingLevelSpec qualified
import TraceSpec qualified
import UrlSpec qualified
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
          complete = handler,
          describeThinking = \_ _ -> noThinkingRequested
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
        EvidenceSpec.tests,
        FetchModelsSpec.tests,
        GenModelsSpec.tests,
        HelpersSpec.tests,
        InteractiveSpec.tests,
        StreamSpec.tests,
        StrictEvidenceSpec.tests,
        SurfaceSpec.tests,
        ThinkingLevelSpec.tests,
        TraceSpec.tests,
        UrlSpec.urlTests,
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
      testCase "Options Show and JSON redact credential headers" $ do
        -- Options.headers is documented as the place to put a gateway's
        -- own Authorization header, and the guides tell people to print
        -- a response. Both of those are fine; printing the credential
        -- is not.
        let opts = emptyOptions & #headers .~ credentialHeaders
            shown = Text.pack (show opts)
            encoded = Text.pack (LBS8.unpack (Aeson.encode opts))
        forM_ [shown, encoded] $ \rendered -> do
          assertBool
            ("the bearer token must not appear: " <> Text.unpack rendered)
            (not ("sk-live-secret" `Text.isInfixOf` rendered))
          assertBool
            ("the subscription key must not appear: " <> Text.unpack rendered)
            (not ("azure-secret" `Text.isInfixOf` rendered))
          assertBool
            ("an ordinary header still appears: " <> Text.unpack rendered)
            ("my app" `Text.isInfixOf` rendered)
          Text.count redactedMarker rendered @?= 2
        -- Redaction is about rendering, never about the value.
        Map.lookup "Authorization" (opts ^. #headers)
          @?= Just "Bearer sk-live-secret",
      testCase "Model and Response Show redact credential headers" $ do
        -- A Model is embedded in every Response, so `print resp` is the
        -- likeliest way a credential reaches a log.
        let m = emptyModel & #headers .~ credentialHeaders
            resp = emptyResponse & #model .~ m
        forM_ [Text.pack (show m), Text.pack (show resp)] $ \rendered -> do
          assertBool
            ("the bearer token must not appear: " <> Text.unpack rendered)
            (not ("sk-live-secret" `Text.isInfixOf` rendered))
          assertBool
            ("the redaction marker appears: " <> Text.unpack rendered)
            (redactedMarker `Text.isInfixOf` rendered),
      testCase "a Model round-tripped through JSON carries the marker, not the key" $ do
        -- Deliberately lossy: a serialised Model is exactly the thing
        -- that should not carry a key.
        let m = emptyModel & #headers .~ credentialHeaders
        case Aeson.decode (Aeson.encode m) :: Maybe Model of
          Nothing -> assertFailure "a redacted Model must still parse"
          Just decoded -> do
            Map.lookup "Authorization" (decoded ^. #headers) @?= Just redactedMarker
            Map.lookup "X-Title" (decoded ^. #headers) @?= Just "my app",
      testCase "Options and Model Show list every field" $ do
        -- The drift guard for the two hand-written Show instances: a
        -- field added later must fail here rather than quietly vanish
        -- from `show`.
        let shownOptions = show emptyOptions
            shownModel = show emptyModel
        forM_ (fieldNames @Options) $ \name ->
          assertBool
            ("Options Show omits the field " <> name)
            ((name <> " = ") `isInfixOf` shownOptions)
        forM_ (fieldNames @Model) $ \name ->
          assertBool
            ("Model Show omits the field " <> name)
            ((name <> " = ") `isInfixOf` shownModel),
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
          @?= defaultOpenAICompletionsCompat
        -- An "@" after the authority names nothing. A parser that took
        -- the text after the last "@" anywhere would hand a proxy the
        -- vendor's own compatibility record, and then its key.
        autoDetectOpenAICompletions "https://proxy.example.com/v1?u=@api.deepseek.com"
          @?= defaultOpenAICompletionsCompat
        urlHost "https://proxy.example.com/v1?u=@api.deepseek.com"
          @?= Just "proxy.example.com",
      QC.testProperty "unknown OpenAI host suffixes use defaults" $
        QC.forAll unknownHostGen $ \host ->
          QC.property $
            autoDetectOpenAICompletions ("https://" <> Text.pack host)
              == defaultOpenAICompletionsCompat,
      QC.testProperty "no trailing @-suffix can rename a host" $
        QC.forAll ((,) <$> unknownHostGen <*> QC.elements atSuffixes) $ \(host, suffix) ->
          QC.property $
            urlHost ("https://" <> Text.pack host <> suffix)
              == Just (Text.pack host),
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
          @?= Nothing
        -- The credential-misdirection case. Every one of these named a
        -- known vendor host before the authority was bounded properly,
        -- so each resolved that vendor's key and sent it to the proxy.
        defaultApiKeyEnvForBaseUrl "https://proxy.example.com/v1?u=@api.openai.com"
          @?= Nothing
        defaultApiKeyEnvForBaseUrl "https://proxy.example.com?u=@api.anthropic.com"
          @?= Nothing
        defaultApiKeyEnvForBaseUrl "https://proxy.example.com#@api.deepseek.com"
          @?= Nothing
        -- And the benign case the same defect broke in the other
        -- direction: an "@" in the path is part of the path.
        defaultApiKeyEnvForBaseUrl "https://api.openai.com/v1/@x"
          @?= Just "OPENAI_API_KEY",
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

-- | A header map with two credential-carrying names, spelled the way a
-- gateway would, and one ordinary header that must survive redaction.
credentialHeaders :: Map.Map Text Text
credentialHeaders =
  Map.fromList
    [ ("Authorization", "Bearer sk-live-secret"),
      ("X-Title", "my app"),
      ("Ocp-Apim-Subscription-Key", "azure-secret")
    ]

-- | The record field names of a type, read off its 'Generic'
-- representation.
--
-- This exists to guard the two hand-written 'Show' instances on
-- 'Options' and 'Model': they list their fields by hand, so a field
-- added later would silently stop being printed. Asking the compiler
-- what the fields actually are turns that into a test failure that names
-- the missing one.
class GFieldNames (f :: Type -> Type) where
  gFieldNames :: Proxy f -> [String]

instance (GFieldNames f) => GFieldNames (D1 m f) where
  gFieldNames _ = gFieldNames (Proxy @f)

instance (GFieldNames f) => GFieldNames (C1 m f) where
  gFieldNames _ = gFieldNames (Proxy @f)

instance (GFieldNames f, GFieldNames g) => GFieldNames (f :*: g) where
  gFieldNames _ = gFieldNames (Proxy @f) <> gFieldNames (Proxy @g)

instance (Selector m) => GFieldNames (S1 m f) where
  gFieldNames _ = [selName (undefined :: S1 m f ())]

fieldNames :: forall a. (GFieldNames (Rep a)) => [String]
fieldNames = gFieldNames (Proxy @(Rep a))

-- | Ways of writing another provider's host after the authority ends.
-- None of them may change which host a URL names, because which host a
-- URL names is which key baikai sends.
atSuffixes :: [Text]
atSuffixes =
  [ "/v1?u=@api.openai.com",
    "/@api.anthropic.com",
    "?x=@api.deepseek.com",
    "#@openrouter.ai"
  ]
