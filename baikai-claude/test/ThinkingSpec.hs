{-# LANGUAGE LambdaCase #-}

module ThinkingSpec (tests) where

import Baikai
import Baikai.Models.Generated
import Baikai.Provider.Claude.Api (mapRequest)
import Claude.V1.Messages qualified as Messages
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ThinkingSpec"
    [ testGroup "mapRequest max_tokens" (neverExceedsCapTests <> styleTests),
      explicitMaxTokensTest,
      handRolledUnclampedTest,
      tooSmallCapDropsThinkingTest,
      mergedOutputConfigTest,
      explicitCompatOverridesDefaultTest
    ]

anthropicModels :: [(String, Model, AnthropicThinkingStyle)]
anthropicModels =
  [ ("claude-fable-5", anthropic_claude_fable_5, AnthropicThinkingAdaptive),
    ("claude-haiku-4-5", anthropic_claude_haiku_4_5, AnthropicThinkingBudget),
    ("claude-opus-4-5", anthropic_claude_opus_4_5, AnthropicThinkingBudget),
    ("claude-opus-4-6", anthropic_claude_opus_4_6, AnthropicThinkingAdaptive),
    ("claude-opus-4-7", anthropic_claude_opus_4_7, AnthropicThinkingAdaptive),
    ("claude-opus-4-8", anthropic_claude_opus_4_8, AnthropicThinkingAdaptive),
    ("claude-sonnet-4-5", anthropic_claude_sonnet_4_5, AnthropicThinkingBudget),
    ("claude-sonnet-4-6", anthropic_claude_sonnet_4_6, AnthropicThinkingBudget)
  ]

thinkingLevels :: [(String, ThinkingLevel)]
thinkingLevels =
  [ ("minimal", ThinkingMinimal),
    ("low", ThinkingLow),
    ("medium", ThinkingMedium),
    ("high", ThinkingHigh)
  ]

neverExceedsCapTests :: [TestTree]
neverExceedsCapTests =
  [ testCase (name <> " " <> levelName <> " stays within catalog cap") $ do
      req <- requestFor model (_Options & #thinking .~ Just level)
      Messages.max_tokens req <= model ^. #maxOutputTokens
        @?= True
  | (name, model, _) <- anthropicModels,
    (levelName, level) <- thinkingLevels
  ]

styleTests :: [TestTree]
styleTests =
  [ testCase (name <> " " <> levelName <> " selects expected thinking style") $ do
      req <- requestFor model (_Options & #thinking .~ Just level)
      case style of
        AnthropicThinkingBudget -> do
          let expectedBudget = thinkingTokenBudget level
          requestThinking req
            @?= Just Messages.ThinkingEnabled {Messages.budget_tokens = expectedBudget}
          assertBool
            "max_tokens leaves visible-output room beyond budget"
            (Messages.max_tokens req > expectedBudget)
        AnthropicThinkingAdaptive -> do
          requestThinking req @?= Just Messages.ThinkingAdaptive
          Messages.max_tokens req @?= model ^. #maxOutputTokens
          (Messages.output_config req >>= Messages.effort)
            @?= adaptiveEffort level
  | (name, model, style) <- anthropicModels,
    (levelName, level) <- thinkingLevels
  ]

explicitMaxTokensTest :: TestTree
explicitMaxTokensTest =
  testCase "explicit maxTokens participates as visible output plus budget, then clamps" $ do
    let opts =
          _Options
            & #thinking .~ Just ThinkingHigh
            & #maxTokens .~ Just 60000
        budget = thinkingTokenBudget ThinkingHigh
    req <- requestFor anthropic_claude_haiku_4_5 opts
    requestThinking req
      @?= Just Messages.ThinkingEnabled {Messages.budget_tokens = budget}
    Messages.max_tokens req @?= anthropic_claude_haiku_4_5 ^. #maxOutputTokens

handRolledUnclampedTest :: TestTree
handRolledUnclampedTest =
  testCase "hand-rolled model with unknown cap is not clamped" $ do
    let model =
          _Model
            & #modelId .~ "custom-claude"
            & #api .~ AnthropicMessages
            & #reasoning .~ True
            & #maxOutputTokens .~ 0
            & #compat .~ CompatAnthropicMessages defaultAnthropicMessagesCompat
        opts =
          _Options
            & #thinking .~ Just ThinkingLow
            & #maxTokens .~ Just 100
        expected = 100 + thinkingTokenBudget ThinkingLow
    req <- requestFor model opts
    Messages.max_tokens req @?= expected

tooSmallCapDropsThinkingTest :: TestTree
tooSmallCapDropsThinkingTest =
  testCase "cap at or below the budget drops the thinking field" $ do
    let model =
          anthropic_claude_haiku_4_5
            & #maxOutputTokens .~ 1000
        opts = _Options & #thinking .~ Just ThinkingMinimal
    req <- requestFor model opts
    requestThinking req @?= Nothing
    Messages.max_tokens req @?= 1000

mergedOutputConfigTest :: TestTree
mergedOutputConfigTest =
  testCase "adaptive effort merges with responseFormat output_config" $ do
    let schema = Aeson.object ["type" Aeson..= ("object" :: Text.Text)]
        opts =
          _Options
            & #thinking .~ Just ThinkingMedium
            & #responseFormat
              .~ Just (JsonSchema {name = "answer", schema = schema, strict = True})
        expected = (Messages.jsonSchemaConfig schema) {Messages.effort = Just "medium"}
    req <- requestFor anthropic_claude_opus_4_6 opts
    requestThinking req @?= Just Messages.ThinkingAdaptive
    Messages.output_config req @?= Just expected

explicitCompatOverridesDefaultTest :: TestTree
explicitCompatOverridesDefaultTest =
  testCase "explicit CompatAnthropicMessages thinkingStyle overrides model generation default" $ do
    let compat =
          defaultAnthropicMessagesCompat
            { thinkingStyle = AnthropicThinkingAdaptive
            }
        model =
          anthropic_claude_haiku_4_5
            & #compat .~ CompatAnthropicMessages compat
        opts = _Options & #thinking .~ Just ThinkingLow
    req <- requestFor model opts
    requestThinking req @?= Just Messages.ThinkingAdaptive
    (Messages.output_config req >>= Messages.effort) @?= Just "low"

requestFor :: Model -> Options -> IO Messages.CreateMessage
requestFor model opts = case mapRequest model _Context opts of
  Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
  Right req -> pure req

requestThinking :: Messages.CreateMessage -> Maybe Messages.Thinking
requestThinking Messages.CreateMessage {Messages.thinking = t} = t

adaptiveEffort :: ThinkingLevel -> Maybe Text.Text
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing
