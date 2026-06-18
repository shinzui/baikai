{-# LANGUAGE OverloadedStrings #-}

-- | Unit tests for the pure core of @baikai-fetch-models@
-- ('FetchModelsCore'): filtering, curation, modality mapping, cost
-- defaulting, and rendering, exercised against a checked-in
-- models.dev-shaped fixture. No network is involved.
module FetchModelsSpec (tests) where

import Baikai.Model (InputModality (..))
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import FetchModelsCore
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | Path to the fixture, relative to the @baikai@ package directory
-- (tests run with that as the working directory, as 'CatalogSpec'
-- relies on for its @src/...@ path).
fixturePath :: FilePath
fixturePath = "test/fixtures/models-dev-sample.json"

loadUpstream :: IO (Map Text (Map Text UpstreamModel))
loadUpstream = do
  raw <- BSL.readFile fixturePath
  case parseUpstream raw of
    Left err -> error ("fixture parse failed: " <> err)
    Right u -> pure u

-- | Build a provider catalog from the fixture.
catalogFor :: Map Text (Map Text UpstreamModel) -> ProviderSpec -> Catalog
catalogFor upstream spec =
  normalizeProvider spec (Map.findWithDefault Map.empty (psProvider spec) upstream)

-- | Expected OpenAI catalog after normalization. @gpt-5-pro@ is
-- excluded by curation (Responses-API-only) and @gpt-legacy-nontool@
-- by the @tool_call@ filter; models sort by id, so @gpt-5-nano@
-- precedes @gpt-5.4@.
expectedOpenAI :: Catalog
expectedOpenAI =
  Catalog
    { cProvider = "openai",
      cBaseUrl = "https://api.openai.com",
      cApi = "openai-chat-completions",
      cModels =
        [ CatalogModel
            { cmId = "gpt-5-nano",
              cmName = "GPT-5 Nano",
              cmReasoning = True,
              cmInput = [InputText, InputImage],
              cmCost = CatalogCost 0.05 0.4 0 0,
              cmContextWindow = 400000,
              cmMaxOutputTokens = 128000
            },
          CatalogModel
            { cmId = "gpt-5.4",
              cmName = "GPT-5.4",
              cmReasoning = True,
              cmInput = [InputText, InputImage],
              cmCost = CatalogCost 2.5 15 0.25 0,
              cmContextWindow = 1050000,
              cmMaxOutputTokens = 128000
            }
        ]
    }

tests :: TestTree
tests =
  testGroup
    "Baikai.FetchModels"
    [ testCase "OpenAI normalization filters, curates, and maps fields" $ do
        upstream <- loadUpstream
        catalogFor upstream openaiSpec @?= expectedOpenAI,
      testCase "tool_call: false model is excluded" $ do
        upstream <- loadUpstream
        let ids = map cmId (cModels (catalogFor upstream openaiSpec))
        assertBool "gpt-legacy-nontool must be filtered" ("gpt-legacy-nontool" `notElem` ids),
      testCase "Responses-API-only id is excluded by curation" $ do
        upstream <- loadUpstream
        let ids = map cmId (cModels (catalogFor upstream openaiSpec))
        assertBool "gpt-5-pro must be excluded" ("gpt-5-pro" `notElem` ids),
      testCase "pdf modality is dropped" $ do
        upstream <- loadUpstream
        let rendered = renderText (catalogFor upstream openaiSpec)
        assertBool
          "input renders as [\"text\", \"image\"] with no pdf"
          ("\"input\": [\"text\", \"image\"]" `Text.isInfixOf` rendered)
        assertBool "no pdf in rendered output" (not ("pdf" `Text.isInfixOf` rendered)),
      testCase "missing cache costs default to 0.0 in rendered output" $ do
        upstream <- loadUpstream
        let rendered = renderText (catalogFor upstream openaiSpec)
        assertBool
          "cacheRead 0.0 present (gpt-5-nano default)"
          ("\"cacheRead\": 0.0" `Text.isInfixOf` rendered)
        assertBool
          "cacheWrite 0.0 present"
          ("\"cacheWrite\": 0.0" `Text.isInfixOf` rendered),
      testCase "whole-number costs render with a trailing .0" $ do
        upstream <- loadUpstream
        let rendered = renderText (catalogFor upstream openaiSpec)
        assertBool
          "output 15 renders as 15.0"
          ("\"output\": 15.0" `Text.isInfixOf` rendered),
      testCase "Anthropic curation keeps exactly the one fixture model" $ do
        upstream <- loadUpstream
        let ids = map cmId (cModels (catalogFor upstream anthropicSpec))
        ids @?= ["claude-opus-4-5"]
    ]

renderText :: Catalog -> Text
renderText = decodeUtf8 . renderCatalog
