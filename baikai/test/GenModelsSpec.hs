module GenModelsSpec (tests) where

import Baikai.Api (Api (AnthropicMessages, OpenAIChatCompletions, OpenAIResponses))
import Baikai.Compat
  ( AnthropicThinkingStyle (AnthropicThinkingAdaptive),
    defaultAnthropicMessagesCompat,
    supportsSamplingParameters,
    thinkingStyle,
  )
import Baikai.Model (InputModality (InputText))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import GenModelsCore
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Baikai.GenModels"
    [ testCase "catalog rejects invalid policy thresholds and negative rates" $ do
        let cost n = Aeson.object ["input" Aeson..= (n :: Int), "output" Aeson..= (1 :: Int), "cacheRead" Aeson..= (0 :: Int), "cacheWrite" Aeson..= (0 :: Int)]
            tier n rate = Aeson.object ["inputAbove" Aeson..= (n :: Int), "rates" Aeson..= cost rate]
            policy tiers = Aeson.object ["inputTiers" Aeson..= tiers]
            entry p = Aeson.object ["id" Aeson..= ("test" :: Text), "name" Aeson..= ("Test" :: Text), "input" Aeson..= (["text"] :: [Text]), "cost" Aeson..= cost 1, "contextWindow" Aeson..= (1 :: Int), "maxOutputTokens" Aeson..= (1 :: Int), "pricingPolicy" Aeson..= p]
        forM_ [policy [Aeson.object ["inputAbove" Aeson..= (1 :: Int), "rates" Aeson..= Aeson.object ["input" Aeson..= (1 :: Int), "output" Aeson..= (1 :: Int)]]], policy [tier (-1) 1], policy [tier 1 1, tier 1 1], policy [tier 2 1, tier 1 1], policy [tier 1 (-1)], Aeson.object ["longCacheWriteCost" Aeson..= (-1 :: Int)]] $ \p ->
          case Aeson.fromJSON (entry p) :: Aeson.Result ModelEntry of
            Aeson.Error _ -> pure ()
            Aeson.Success _ -> assertFailure "invalid policy accepted",
      testCase "per-model API override changes only the selected binding" $ do
        let catalog = collisionCatalog {models = [model "legacy", (model "native") {entryApiOverride = Just OpenAIResponses}]}
            rendered = renderModule (flattenEntries catalog)
        assertBool "legacy inherits file API" ("api = OpenAIChatCompletions" `Text.isInfixOf` rendered)
        assertBool "native overrides API" ("api = OpenAIResponses" `Text.isInfixOf` rendered),
      testCase "Responses catalog compat parses and renders all endpoint facts" $ do
        let raw = Aeson.object ["kind" Aeson..= ("openai-responses" :: Text), "supportsSamplingParameters" Aeson..= False, "supportsLongCacheRetention" Aeson..= False, "supportsPromptCacheOptions" Aeson..= True, "supportedReasoningEfforts" Aeson..= (["low", "max"] :: [Text])]
        case Aeson.fromJSON raw of
          Aeson.Error err -> assertFailure err
          Aeson.Success block -> do
            let rendered = renderModule (flattenEntries collisionCatalog {models = [(model "native") {entryApiOverride = Just OpenAIResponses, entryCompatOverride = Just block}]})
            mapM_ (\expected -> assertBool (Text.unpack expected) (expected `Text.isInfixOf` rendered)) ["CompatOpenAIResponses", "supportsPromptCacheOptions = True", "supportsLongCacheRetention = False", "supportsSamplingParameters = False", "Just [ThinkingLow, ThinkingMax]"],
      testCase "OpenAI effort policy rejects empty, duplicate, unordered and unknown levels" $
        mapM_
          ( \levels ->
              case Aeson.fromJSON (Aeson.object ["kind" Aeson..= ("openai-completions" :: Text), "supportedReasoningEfforts" Aeson..= levels]) :: Aeson.Result CatalogCompat of
                Aeson.Error _ -> pure ()
                Aeson.Success _ -> assertFailure "invalid effort policy accepted"
          )
          ([[], ["low", "low"], ["high", "low"], ["unknown"]] :: [[Text]]),
      testCase "checkIdentifierCollisions rejects sanitized binding duplicates" $ do
        let entries = flattenEntries collisionCatalog
        case checkIdentifierCollisions entries of
          Right () -> assertFailure "expected duplicate generated identifier to be rejected"
          Left err -> do
            assertBool "mentions duplicate identifier" ("openai_a_b" `Text.isInfixOf` err)
            assertBool "mentions first origin" ("openai/a-b" `Text.isInfixOf` err)
            assertBool "mentions second origin" ("openai/a_b" `Text.isInfixOf` err),
      testCase "checkAnthropicCompat rejects an entry left at compat auto" $ do
        let entries = flattenEntries (anthropicCatalog CatalogCompatAuto Nothing)
        case checkAnthropicCompat entries of
          Right () ->
            assertFailure
              "expected an anthropic-messages entry with no compat block to be rejected"
          Left err -> do
            assertBool "names the entry" ("anthropic/claude-x" `Text.isInfixOf` err)
            assertBool "names the fix" ("thinkingStyle" `Text.isInfixOf` err)
            assertBool
              "names the sampling field"
              ("supportsSamplingParameters" `Text.isInfixOf` err),
      testCase "checkAnthropicCompat accepts an entry that states its facts" $ do
        let block =
              CatalogCompatAnthropic
                defaultAnthropicMessagesCompat
                  { thinkingStyle = AnthropicThinkingAdaptive,
                    supportsSamplingParameters = False
                  }
            entries = flattenEntries (anthropicCatalog CatalogCompatAuto (Just block))
        case checkAnthropicCompat entries of
          Right () -> pure ()
          Left err -> assertFailure ("unexpected rejection: " <> Text.unpack err),
      testCase "checkAnthropicCompat ignores an OpenAI catalog" $ do
        case checkAnthropicCompat (flattenEntries collisionCatalog) of
          Right () -> pure ()
          Left err -> assertFailure ("unexpected rejection: " <> Text.unpack err)
    ]

-- | A one-model @anthropic-messages@ catalog, with the file-level
-- compat directive and the per-model override both under the caller's
-- control.
anthropicCatalog :: CatalogCompat -> Maybe CatalogCompat -> CatalogFile
anthropicCatalog fileCompat override =
  CatalogFile
    { provider = "anthropic",
      baseUrl = "https://api.anthropic.com",
      api = AnthropicMessages,
      compat = fileCompat,
      models = [(model "claude-x") {entryCompatOverride = override}]
    }

collisionCatalog :: CatalogFile
collisionCatalog =
  CatalogFile
    { provider = "openai",
      baseUrl = "https://api.openai.com",
      api = OpenAIChatCompletions,
      compat = CatalogCompatAuto,
      models =
        [ model "a-b",
          model "a_b"
        ]
    }

model :: Text -> ModelEntry
model mid =
  ModelEntry
    { entryId = mid,
      entryName = mid,
      entryReasoning = False,
      entryInput = [InputText],
      entryCost =
        CostEntry
          { costInput = 0,
            costOutput = 0,
            costCacheRead = 0,
            costCacheWrite = 0
          },
      entryPricingPolicy = Nothing,
      entryContextWindow = 1,
      entryMaxOutputTokens = 1,
      entryEnabled = True,
      entryApiOverride = Nothing,
      entryCompatOverride = Nothing
    }
