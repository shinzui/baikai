-- | A live, end-to-end demo proving the binding works against a real provider.
--
-- It is gated at runtime on the environment variable @BAIKAI_EFFECTFUL_LIVE@: with
-- @BAIKAI_EFFECTFUL_LIVE=1@ (and a valid @OPENAI_API_KEY@) it registers the OpenAI
-- provider, runs 'complete' through the global registry via 'runBaikai', and asserts
-- a non-empty reply. Without the variable it prints a skip line and stays green, so
-- the default test run remains hermetic (no network, no key).
module LiveSpec (tests) where

import Baikai hiding (complete)
import Baikai.Effectful (complete, runBaikai)
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Baikai.Prelude
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (runEff)
import StubProvider (flattenAssistantText)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "LiveSpec"
    [ testCase "live provider call returns text" $ do
        live <- lookupEnv "BAIKAI_EFFECTFUL_LIVE"
        case live of
          Just "1" -> do
            OpenAI.register
            let ctx = _Context & #messages .~ V.singleton (user "Reply with a single word.")
                opts = _Options & #maxTokens .~ Just 16
            out <-
              runEff . runBaikai $ do
                r <- complete openai_gpt_4o_mini ctx opts
                pure (flattenAssistantText (flattenAssistantBlocks r))
            putStrLn ("LIVE: " <> T.unpack out)
            assertBool "non-empty reply" (not (T.null out))
          _ ->
            putStrLn "BAIKAI_EFFECTFUL_LIVE not set; skipping live test"
    ]
