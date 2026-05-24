module Main (main) where

import Baikai
import Baikai.Prelude
import AgentAssetsSpec qualified
import CatalogSpec qualified
import CostSpec qualified
import Data.Vector qualified as V
import InteractiveSpec qualified
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import TraceSpec qualified

-- | Ground the test provider on a 'Custom' API tag so it does not
-- clash with the real Anthropic/OpenAI handlers if a future test
-- registers them in the same process.
testApi :: Api
testApi = Custom "baikai-test"

testModel :: Model
testModel =
  _Model
    { modelId = "test-model"
    , name = "Test Model"
    , api = testApi
    , provider = "test"
    }

-- | Install a handler that returns a fixed assistant message for
-- the 'testApi' tag. Idempotent: re-registering the same tag
-- overwrites.
registerTestHandler :: Text -> IO ()
registerTestHandler canned =
  let handler m _ctx _opts =
        pure
          _Response
            { message = assistant canned
            , model = m
            , api = testApi
            , provider = "test"
            }
   in registerApiProvider
        ApiProvider
          { apiTag = testApi
          , stream = liftCompleteToStream handler
          , complete = handler
          }

main :: IO ()
main = do
  registerTestHandler "hello from the test provider"
  defaultMain $
    testGroup
      "baikai"
      [ tests
      , AgentAssetsSpec.tests
      , CatalogSpec.tests
      , CostSpec.tests
      , InteractiveSpec.tests
      , TraceSpec.tests
      ]

tests :: TestTree
tests =
  testGroup
    "baikai EP-2"
    [ testCase "_Context defaults are zero-y" $ do
        _Context ^. #systemPrompt @?= Nothing
        V.length (_Context ^. #messages) @?= 0
    , testCase "_Options defaults are zero-y" $ do
        _Options ^. #maxTokens @?= Nothing
        _Options ^. #temperature @?= Nothing
        _Options ^. #apiKey @?= Nothing
    , testCase "completeRequest dispatches through the registered handler" $ do
        let ctx = _Context {messages = V.fromList [user "ping"]}
        resp <- completeRequest testModel ctx _Options
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hello from the test provider"))
        (resp ^. #model) ^. #modelId @?= "test-model"
        resp ^. #provider @?= "test"
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
