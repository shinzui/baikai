-- | Unit tests for the pure core of @baikai-fetch-models@
-- ('FetchModelsCore'): filtering, curation, modality mapping, cost
-- defaulting, and rendering, exercised against a checked-in
-- models.dev-shaped fixture. No network is involved.
module FetchModelsSpec (tests) where

import Baikai.Compat (AnthropicThinkingStyle (..))
import Baikai.Model (InputModality (..))
import Baikai.Prelude
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Scientific (Scientific)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V
import FetchModelsCore
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
              maxOutputTokens = 128000,
              compat = Nothing
            },
          CatalogModel
            { modelId = "gpt-5.4",
              name = "GPT-5.4",
              reasoning = True,
              input = [InputText, InputImage],
              cost = CatalogCost 2.5 15 0.25 0,
              contextWindow = 1050000,
              maxOutputTokens = 128000,
              compat = Nothing
            }
        ]
    }

-- | Expected Anthropic catalog after normalization. The one fixture
-- model carries the generation facts curated in 'anthropicInclude':
-- the budget thinking shape, sampling parameters accepted.
expectedAnthropic :: Catalog
expectedAnthropic =
  Catalog
    { provider = "anthropic",
      baseUrl = "https://api.anthropic.com",
      api = "anthropic-messages",
      models =
        [ CatalogModel
            { modelId = "claude-opus-4-5",
              name = "Claude Opus 4.5",
              reasoning = True,
              input = [InputText, InputImage],
              cost = CatalogCost 5 25 1.5 6.25,
              contextWindow = 200000,
              maxOutputTokens = 64000,
              compat =
                Just
                  ( CatalogAnthropicCompat
                      ( AnthropicGenerationFacts
                          { thinkingStyle = AnthropicThinkingBudget,
                            supportsSamplingParameters = True
                          }
                      )
                  )
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
      testCase "renderCatalog escapes control characters as valid JSON strings" $ do
        let modelIdWithControls = "model-\n-tab\t-quote\"-slash\\"
            nameWithControls = "Name with \r carriage return"
            catalog =
              Catalog
                { provider = "openai",
                  baseUrl = "https://api.openai.com",
                  api = "openai-chat-completions",
                  models =
                    [ CatalogModel
                        { modelId = modelIdWithControls,
                          name = nameWithControls,
                          reasoning = False,
                          input = [InputText],
                          cost = CatalogCost 0 0 0 0,
                          contextWindow = 1,
                          maxOutputTokens = 1,
                          compat = Nothing
                        }
                    ]
                }
            rendered = renderText catalog
            raw = BSL.fromStrict (renderCatalog catalog)
            decoded = Aeson.eitherDecode raw :: Either String Aeson.Value
        case decoded of
          Left err -> assertFailure ("decode failed: " <> err)
          Right (Aeson.Object root) ->
            case KeyMap.lookup "models" root of
              Just (Aeson.Array models)
                | Just (Aeson.Object model) <- models V.!? 0 -> do
                    KeyMap.lookup "id" model @?= Just (Aeson.String modelIdWithControls)
                    KeyMap.lookup "name" model @?= Just (Aeson.String nameWithControls)
              _ -> assertFailure "decoded catalog did not contain a model object"
          Right other -> assertFailure ("decoded catalog was not an object: " <> show other)
        assertBool "newline escaped" ("\\n" `Text.isInfixOf` rendered)
        assertBool "tab escaped" ("\\t" `Text.isInfixOf` rendered),
      testCase "Anthropic curation keeps exactly the one fixture model" $ do
        upstream <- loadUpstream
        let ids = map (^. #modelId) (catalogFor upstream anthropicSpec ^. #models)
        ids @?= ["claude-opus-4-5"],
      testCase "Anthropic normalization carries the curated generation facts" $ do
        upstream <- loadUpstream
        catalogFor upstream anthropicSpec @?= expectedAnthropic,
      testCase "the generation facts render as a per-model compat block" $ do
        upstream <- loadUpstream
        let rendered = renderText (catalogFor upstream anthropicSpec)
        assertBool
          "compat block rendered"
          ( Text.unlines
              [ "      \"compat\": {",
                "        \"kind\": \"anthropic-messages\",",
                "        \"thinkingStyle\": \"budget\",",
                "        \"supportsSamplingParameters\": true",
                "      },"
              ]
              `Text.isInfixOf` rendered
          ),
      testCase "an OpenAI model renders no compat block" $ do
        upstream <- loadUpstream
        let rendered = renderText (catalogFor upstream openaiSpec)
        assertBool
          "no per-model compat block (the file-level \"compat\": \"auto\" stays)"
          (not ("\"compat\": {" `Text.isInfixOf` rendered)),
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
        opusCacheRead normalized @?= Just 1.5
        opusCacheRead corrected @?= Just 0.5
    ]

-- | The @claude-opus-4-5@ cacheRead cost in an Anthropic catalog.
opusCacheRead :: Catalog -> Maybe Scientific
opusCacheRead cat =
  listToMaybe
    [ m ^. #cost . #cacheReadCost
    | m <- cat ^. #models,
      m ^. #modelId == "claude-opus-4-5"
    ]

renderText :: Catalog -> Text
renderText = decodeUtf8 . renderCatalog
