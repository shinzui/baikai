{-# LANGUAGE OverloadedRecordDot #-}

module ResponsesSpec (tests) where

import Baikai hiding (model, schema)
import Baikai.Models.Generated (openai_gpt_6_astra)
import Baikai.Provider.OpenAI.Responses.Request qualified as R
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses request mapping"
    [ testCase "stateless request carries text, image, system, cap and metadata" $ do
        let ctx =
              (systemUser "system instruction" "hello")
                & #messages .~ V.singleton (UserMessage UserPayload {content = V.fromList [UserText (TextContent "hello"), UserImage (ImageContent "abc" "image/png")], timestamp = Nothing})
            opts = emptyOptions & #maxTokens .~ Just 321 & #metadata .~ Map.singleton "test" (String "value")
        req <- mapped model ctx opts
        field "model" req.requestBody @?= Just (String "renamed-responses-model")
        field "instructions" req.requestBody @?= Just (String "system instruction")
        field "store" req.requestBody @?= Just (Bool False)
        field "stream" req.requestBody @?= Just (Bool True)
        field "max_output_tokens" req.requestBody @?= Just (Number 321)
        field "include" req.requestBody @?= Just (Aeson.toJSON (["reasoning.encrypted_content"] :: [Text]))
        let rendered = Text.pack (show (field "input" req.requestBody))
        assertBool "image encoded inline" ("data:image/png;base64,YWJj" `Text.isInfixOf` rendered)
        assertBool "text is present" ("hello" `Text.isInfixOf` rendered)
        field "metadata" req.requestBody @?= Just (object ["test" .= ("value" :: Text)]),
      testCase "assistant plain text has a valid easy-message input shape" $ do
        req <- mapped model (contextOf [assistant "previous answer"]) emptyOptions
        inputItems req @?= [object ["role" .= ("assistant" :: Text), "content" .= ("previous answer" :: Text)]],
      testCase "empty summary and encrypted items persist into the next tool request" $ do
        let decoded = Aeson.eitherDecode (Aeson.encode thought)
        persisted <- either assertFailure pure decoded
        let response =
              emptyResponse
                & #message . #content .~ V.fromList [AssistantThinking persisted, AssistantToolCall (ToolCall "call_7" "lookup" (object ["x" .= (1 :: Int)]))]
                & #message . #stopReason .~ ToolUse
            ctx = contextOf [user "go"] & #tools .~ V.singleton tool
        next <- appendToolResult ctx response (\_ -> pure (toolResultText "found"))
        req <- mapped model next emptyOptions
        let items = inputItems req
        take 1 (drop 1 items) @?= [reasoningItem]
        field "call_id" (items !! 2) @?= Just (String "call_7")
        field "type" (items !! 2) @?= Just (String "function_call")
        field "call_id" (items !! 3) @?= Just (String "call_7")
        field "output" (items !! 3) @?= Just (String "found")
        field "previous_response_id" req.requestBody @?= Nothing
        req.translation @?= R.describeThinking model emptyOptions,
      testCase "every accepted effort survives; minimal adjusts with evidence" $ do
        forM_ [ThinkingMinimal, ThinkingLow, ThinkingMedium, ThinkingHigh, ThinkingXHigh, ThinkingMax] $ \level -> do
          let opts = emptyOptions & #thinking .~ Just level
              expected = if level == ThinkingMinimal then "low" else renderThinkingLevel level
          req <- mapped model emptyContext opts
          field "reasoning" req.requestBody @?= Just (object ["effort" .= expected])
          req.translation @?= R.describeThinking model opts
          req.translation.adjustments @?= [EffortClamped ThinkingMinimal "low" | level == ThinkingMinimal],
      testCase "sampling restriction is visible even without thinking" $ do
        let opts = emptyOptions & #temperature .~ Just 0.5 & #topP .~ Just 0.8
        req <- mapped model emptyContext opts
        field "temperature" req.requestBody @?= Nothing
        field "top_p" req.requestBody @?= Nothing
        req.translation.adjustments @?= [SamplingDroppedUnsupportedModel ["temperature", "top_p"]]
        supported <- mapped (model & #compat .~ CompatOpenAIResponses defaultOpenAIResponsesCompat) emptyContext opts
        field "temperature" supported.requestBody @?= Just (Number 0.5),
      testCase "function tools keep permissive schemas and supported choices" $ do
        let ctx = emptyContext & #tools .~ V.singleton tool
        forM_ [ToolChoiceAuto, ToolChoiceNone, ToolChoiceRequired, ToolChoiceSpecific "lookup"] $ \choice -> do
          req <- mapped model ctx (emptyOptions & #toolChoice .~ Just choice)
          field "tool_choice" req.requestBody @?= case choice of
            ToolChoiceAuto -> Nothing
            ToolChoiceNone -> Just (String "none")
            ToolChoiceRequired -> Just (String "required")
            ToolChoiceSpecific name -> Just (object ["type" .= ("function" :: Text), "name" .= name])
          case field "tools" req.requestBody of
            Just (Array tools) -> do
              field "type" (V.head tools) @?= Just (String "function")
              field "strict" (V.head tools) @?= Just (Bool False)
              field "parameters" (V.head tools) @?= Just schema
            _ -> assertFailure "missing tools"
        rejected emptyContext (emptyOptions & #toolChoice .~ Just ToolChoiceRequired)
        rejected ctx (emptyOptions & #toolChoice .~ Just (ToolChoiceSpecific "missing")),
      testCase "JSON schema and JSON object use Responses text.format" $ do
        strict <- mapped model emptyContext (emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "answer" schema & #strict .~ True)))
        field "text" strict.requestBody @?= Just (object ["format" .= object ["type" .= ("json_schema" :: Text), "name" .= ("answer" :: Text), "schema" .= schema, "strict" .= True]])
        plain <- mapped model emptyContext (emptyOptions & #responseFormat .~ Just JsonObject)
        field "text" plain.requestBody @?= Just (object ["format" .= object ["type" .= ("json_object" :: Text)]]),
      testCase "cache requests follow endpoint TTL contract" $ do
        req <- mapped model emptyContext (emptyOptions & #cacheRetention .~ Just CacheRetentionShort)
        field "prompt_cache_options" req.requestBody @?= Just (object ["ttl" .= ("30m" :: Text)])
        rejected emptyContext (emptyOptions & #cacheRetention .~ Just CacheRetentionLong),
      testCase "unsupported options fail instead of disappearing" $
        forM_ [emptyOptions & #seed .~ Just 1, emptyOptions & #stopSequences .~ ["stop"], emptyOptions & #frequencyPenalty .~ Just 1, emptyOptions & #presencePenalty .~ Just 1, emptyOptions & #metadata .~ Map.singleton "bad" (Number 1)] (rejected emptyContext),
      testCase "foreign, malformed and duplicate replay fails without exposing payload" $ do
        forM_ [replay & #replayApi .~ AnthropicMessages, replay & #replayModel .~ "other", replay & #replayItems .~ V.empty, replay & #replayItems .~ V.singleton (object []), replay & #replayItems .~ V.fromList [reasoningItem, reasoningItem]] $ \bad -> do
          let ctx = addResponse (emptyResponse & #message . #content .~ V.singleton (AssistantThinking (thought & #replayState .~ Just bad))) emptyContext
          case R.mapRequest model ctx emptyOptions of
            Left err -> assertBool "error contains no opaque data" (not ("SECRET" `Text.isInfixOf` err))
            Right _ -> assertFailure "invalid replay accepted",
      testCase "Anthropic state and incomplete calls cannot be replayed" $ do
        forM_ [AssistantThinking (emptyThinkingContent & #signature .~ Just "sig"), AssistantThinking emptyThinkingContent, AssistantToolCall (ToolCall "call_1" "lookup" (String "{"))] $ \block ->
          rejected (addResponse (emptyResponse & #message . #content .~ V.singleton block) emptyContext) emptyOptions
    ]
  where
    rejected ctx opts = case R.mapRequest model ctx opts of
      Left _ -> pure ()
      Right _ -> assertFailure "expected local rejection"

model :: Model
model =
  openai_gpt_6_astra
    & #api .~ OpenAIResponses
    & #modelId .~ "renamed-responses-model"
    & #compat
      .~ CompatOpenAIResponses
        ( defaultOpenAIResponsesCompat
            & #supportedReasoningEfforts .~ Just [ThinkingLow, ThinkingMedium, ThinkingHigh, ThinkingXHigh, ThinkingMax]
            & #supportsSamplingParameters .~ False
            & #supportsPromptCacheOptions .~ True
        )

schema :: Value
schema = object ["type" .= ("object" :: Text), "properties" .= object ["x" .= object ["type" .= ("integer" :: Text)]]]

tool :: Tool
tool = mkTool "lookup" "Look up x" schema

reasoningItem :: Value
reasoningItem = object ["type" .= ("reasoning" :: Text), "id" .= ("rs_7" :: Text), "summary" .= ([] :: [Value]), "encrypted_content" .= ("SECRET" :: Text), "status" .= ("completed" :: Text)]

replay :: ThinkingReplay
replay = ThinkingReplay OpenAIResponses "renamed-responses-model" (V.singleton reasoningItem)

thought :: ThinkingContent
thought = emptyThinkingContent & #replayState .~ Just replay

mapped :: Model -> Context -> Options -> IO R.PreparedRequest
mapped m ctx opts = either (assertFailure . Text.unpack) pure (R.mapRequest m ctx opts)

field :: Aeson.Key -> Value -> Maybe Value
field k (Object o) = KM.lookup k o
field _ _ = Nothing

inputItems :: R.PreparedRequest -> [Value]
inputItems req = case field "input" req.requestBody of
  Just (Array xs) -> V.toList xs
  _ -> []
