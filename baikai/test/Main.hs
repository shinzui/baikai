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
      ( _Response
          { message =
              assistant cannedContent
          , model = Model "test"
          , api = "test"
          , provider = "test"
          }
      )

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
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from the test provider"))
        unModel (resp ^. #model) @?= "test"
        resp ^. #provider @?= "test"
    , testCase "SomeProvider wraps and dispatches" $ do
        let tp = TestProvider {cannedContent = "hello from the test provider"}
        resp <- runSome (SomeProvider tp) _Request :: IO Response
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from the test provider"))
    , testCase "user smart constructor produces a UserMessage" $ do
        case user "hello" of
          UserMessage {userContent = uc} ->
            uc @?= V.singleton (UserText (TextContent "hello"))
          _ -> error "expected UserMessage"
    , testCase "assistant smart constructor produces an AssistantMessage" $ do
        case assistant "world" of
          AssistantMessage {assistantContent = ac, stopReason = sr} -> do
            ac @?= V.singleton (AssistantText (TextContent "world"))
            sr @?= Stop
          _ -> error "expected AssistantMessage"
    ]
