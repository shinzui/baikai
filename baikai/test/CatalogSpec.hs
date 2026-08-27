-- | Regression test that locks down the contract between the JSON
-- catalog files under @baikai\/data\/models\/@ and the auto-generated
-- @baikai\/src\/Baikai\/Models\/Generated.hs@ module.
--
-- The test invokes the @baikai-gen-models@ executable (made available
-- on @PATH@ by the @build-tool-depends@ entry in @baikai.cabal@) with
-- @--out@ pointing at a fresh temp file, then asserts the regenerated
-- output is byte-identical to the committed module. If the test fails
-- the remediation is always:
--
-- @
-- cabal run baikai-gen-models
-- git add baikai\/src\/Baikai\/Models\/Generated.hs
-- @
--
-- A failure means either someone edited @Baikai.Models.Generated@ by
-- hand (the file says \"do not edit\" at the top) or a @data\/models@
-- JSON file changed without a paired regeneration.
module CatalogSpec (tests) where

import Baikai.Api (Api (AnthropicMessages))
import Baikai.Compat
  ( AnthropicMessagesCompat,
    AnthropicThinkingStyle (..),
    supportsSamplingParameters,
    thinkingStyle,
  )
import Baikai.Model
  ( Compat (CompatAnthropicMessages),
    Model,
    api,
    compat,
    modelId,
  )
import Baikai.Models.Generated (allModels)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Models.Generated"
    [ testCase "regenerating from data/models produces no diff" $
        withSystemTempDirectory "baikai-catalog-spec" $ \tmpDir -> do
          let regenPath = tmpDir <> "/Generated.hs"
              committedPath = "src/Baikai/Models/Generated.hs"
          callProcess "baikai-gen-models" ["--out", regenPath]
          committed <- BS.readFile committedPath
          regenerated <- BS.readFile regenPath
          assertEqual
            "Generated.hs is out of sync with data/models/*.json.\n\
            \Run `cabal run baikai-gen-models` and commit the result."
            committed
            regenerated,
      -- Which extended-thinking wire shape a generation accepts, and
      -- whether it accepts sampling parameters, cannot be recovered
      -- from the model id or the base URL. Every Anthropic catalog
      -- entry must therefore carry an explicit compat record stating
      -- both, and this table is where the shipped values are pinned:
      -- a catalog refresh that changes one has to change this row too.
      testCase "every Anthropic catalog entry carries an explicit thinking style and sampling flag" $ do
        assertEqual
          "the pinned table must cover exactly the catalog's Anthropic ids"
          (sort (map fst expectedAnthropicFacts))
          (sort (map modelId anthropicCatalogModels))
        mapM_ assertFacts anthropicCatalogModels
    ]

-- | Every Anthropic model in the generated catalog.
anthropicCatalogModels :: [Model]
anthropicCatalogModels = [m | m <- allModels, api m == AnthropicMessages]

-- | The shipped thinking style and sampling support of each Anthropic
-- catalog id, written out by hand from
-- @baikai\/data\/models\/anthropic.json@.
expectedAnthropicFacts :: [(Text, (AnthropicThinkingStyle, Bool))]
expectedAnthropicFacts =
  [ ("claude-fable-5", (AnthropicThinkingAdaptive, False)),
    ("claude-haiku-4-5", (AnthropicThinkingBudget, True)),
    ("claude-opus-4-5", (AnthropicThinkingBudget, True)),
    ("claude-opus-4-6", (AnthropicThinkingAdaptive, True)),
    ("claude-opus-4-7", (AnthropicThinkingAdaptive, False)),
    ("claude-opus-4-8", (AnthropicThinkingAdaptive, False)),
    ("claude-sonnet-4-5", (AnthropicThinkingBudget, True)),
    ("claude-sonnet-4-6", (AnthropicThinkingAdaptive, True)),
    ("claude-sonnet-5", (AnthropicThinkingAdaptive, False))
  ]

assertFacts :: Model -> IO ()
assertFacts m = case compat m of
  CompatAnthropicMessages c -> case lookup (modelId m) expectedAnthropicFacts of
    Just expected -> facts c @?= expected
    Nothing ->
      assertFailure
        ("no pinned facts for Anthropic catalog model " <> show (modelId m))
  other ->
    assertFailure
      ( "Anthropic catalog model "
          <> show (modelId m)
          <> " must carry an explicit CompatAnthropicMessages record, not "
          <> show other
      )
  where
    facts :: AnthropicMessagesCompat -> (AnthropicThinkingStyle, Bool)
    facts c = (thinkingStyle c, supportsSamplingParameters c)
