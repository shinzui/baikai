module GenModelsSpec (tests) where

import Baikai.Api (Api (OpenAIChatCompletions))
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
            assertBool "mentions second origin" ("openai/a_b" `Text.isInfixOf` err)
    ]

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
