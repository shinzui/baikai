-- | Unit tests for the pure core of @baikai-fetch-models@
-- ('FetchModelsCore'): filtering, curation, modality mapping, cost
-- defaulting, and rendering, exercised against a checked-in
-- models.dev-shaped fixture. No network is involved.
module FetchModelsSpec (tests) where

import Baikai.Model (InputModality (..))
import Baikai.Prelude
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
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
  normalizeProvider spec (Map.findWithDefault Map.empty (spec ^. #provider) upstream)

-- | Expected OpenAI catalog after normalization. @gpt-5-pro@ is
-- excluded by curation (Responses-API-only) and @gpt-legacy-nontool@
-- by the @tool_call@ filter; models sort by id, so @gpt-5-nano@
-- precedes @gpt-5.4@.
expectedOpenAI :: Catalog
expectedOpenAI =
  Catalog
    { provider = "openai",
      baseUrl = "https://api.openai.com",
      api = "openai-chat-completions",
      models =
        [ CatalogModel
            { modelId = "gpt-5-nano",
              name = "GPT-5 Nano",
              reasoning = True,
              input = [InputText, InputImage],
              cost = CatalogCost 0.05 0.4 0 0,
              contextWindow = 400000,
              maxOutputTokens = 128000
            },
          CatalogModel
            { modelId = "gpt-5.4",
              name = "GPT-5.4",
              reasoning = True,
              input = [InputText, InputImage],
              cost = CatalogCost 2.5 15 0.25 0,
              contextWindow = 1050000,
              maxOutputTokens = 128000
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
        let ids = map (^. #modelId) (catalogFor upstream openaiSpec ^. #models)
        assertBool "gpt-legacy-nontool must be filtered" ("gpt-legacy-nontool" `notElem` ids),
      testCase "Responses-API-only id is excluded by curation" $ do
        upstream <- loadUpstream
        let ids = map (^. #modelId) (catalogFor upstream openaiSpec ^. #models)
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
        let ids = map (^. #modelId) (catalogFor upstream anthropicSpec ^. #models)
        ids @?= ["claude-opus-4-5"],
      testCase "\" (latest)\" suffix is stripped from display names" $ do
        upstream <- loadUpstream
        let cat = catalogFor upstream anthropicSpec
        map (^. #name) (cat ^. #models) @?= ["Claude Opus 4.5"],
      testCase "override corrects a deliberately-wrong upstream cache price" $ do
        upstream <- loadUpstream
        -- Fixture upstream reports cache_read 1.5 for claude-opus-4-5
        -- (the 3x wart); normalization alone preserves it, the override
        -- pins it to the published 0.5.
        let normalized = catalogFor upstream anthropicSpec
            corrected = applyOverrides overrides normalized
        opusCacheRead normalized @?= 1.5
        opusCacheRead corrected @?= 0.5
    ]

-- | The @claude-opus-4-5@ cacheRead cost in an Anthropic catalog.
opusCacheRead :: Catalog -> Scientific
opusCacheRead cat =
  head
    [ m ^. #cost . #cacheReadCost
    | m <- cat ^. #models,
      m ^. #modelId == "claude-opus-4-5"
    ]

renderText :: Catalog -> Text
renderText = decodeUtf8 . renderCatalog
