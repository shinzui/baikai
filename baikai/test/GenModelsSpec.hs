module GenModelsSpec (tests) where

import Baikai.Api (Api (AnthropicMessages, OpenAIChatCompletions))
import Baikai.Compat
  ( AnthropicThinkingStyle (AnthropicThinkingAdaptive),
    defaultAnthropicMessagesCompat,
    supportsSamplingParameters,
    thinkingStyle,
  )
import Baikai.Model (InputModality (InputText))
import Data.Text (Text)
import Data.Text qualified as Text
import GenModelsCore
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Baikai.GenModels"
    [ testCase "checkIdentifierCollisions rejects sanitized binding duplicates" $ do
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
      entryCompatOverride = Nothing
    }
