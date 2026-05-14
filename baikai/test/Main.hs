module Main (main) where

import Baikai
import Baikai.Prelude
import CostSpec qualified
import Data.Vector qualified as V
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import TraceSpec qualified

data TestProvider = TestProvider {cannedContent :: !Text}

instance Provider TestProvider where
  providerName _ = "test"
  runRequest TestProvider {cannedContent} _ =
    pure
      Response
        { content = cannedContent
        , model = Model "test"
        , usage = Nothing
        , cost = Nothing
        , provider = "test"
        , latencyMs = 0
        }

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai"
      [ tests
      , CostSpec.tests
      , TraceSpec.tests
      ]

tests :: TestTree
tests =
  testGroup
    "baikai EP-1"
    [ testCase "_Request defaults are zero-y" $ do
        unModel (_Request ^. #model) @?= ""
        V.length (_Request ^. #messages) @?= 0
        _Request ^. #maxTokens @?= 1024
        _Request ^. #temperature @?= Nothing
        _Request ^. #systemPrompt @?= Nothing
    , testCase "TestProvider returns the canned content" $ do
        let req =
              _Request
                & #model .~ Model "test-model"
                & #messages .~ V.fromList [user "ping"]
            tp = TestProvider {cannedContent = "hello from the test provider"}
        resp <- runRequest tp req :: IO Response
        resp ^. #content @?= "hello from the test provider"
        unModel (resp ^. #model) @?= "test"
        resp ^. #provider @?= "test"
    , testCase "SomeProvider wraps and dispatches" $ do
        let tp = TestProvider {cannedContent = "hello from the test provider"}
        resp <- runSome (SomeProvider tp) _Request :: IO Response
        resp ^. #content @?= "hello from the test provider"
    ]
