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

import Data.ByteString qualified as BS
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

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
            regenerated
    ]
