module GenModelsSpec (tests) where

import Baikai.Api (Api (AnthropicMessages, OpenAIChatCompletions, OpenAIResponses))
import Baikai.Compat
  ( AnthropicThinkingStyle (AnthropicThinkingAdaptive),
    defaultAnthropicMessagesCompat,
    supportsSamplingParameters,
    thinkingStyle,
  )
import Baikai.Model (InputModality (InputText))
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
    [ testCase "per-model API override changes only the selected binding" $ do
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
      entryContextWindow = 1,
      entryMaxOutputTokens = 1,
      entryEnabled = True,
      entryApiOverride = Nothing,
      entryCompatOverride = Nothing
    }
