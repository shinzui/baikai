module CliInternalSpec (tests) where

import Baikai
import Baikai.Provider.Cli.Internal
import Control.Lens ((&), (.~))
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "CLI internal helpers"
    [ testCase "renderPrompt returns a single user text message verbatim" $ do
        let ctx = _Context & #messages .~ Vector.singleton (user "hello")
        renderPrompt ctx @?= "hello",
      testCase "renderPrompt tags multi-message contexts" $ do
        let ctx =
              _Context
                & #messages
                  .~ Vector.fromList
                    [ user "hello",
                      assistant "hi"
                    ]
        renderPrompt ctx @?= "[user]: hello\n[assistant]: hi",
      testCase "wrapSystemPrompt leaves missing and blank prompts alone" $ do
        wrapSystemPrompt Nothing "hello" @?= "hello"
        wrapSystemPrompt (Just "  ") "hello" @?= "hello",
      testCase "wrapSystemPrompt prefixes nonblank system instructions" $
        wrapSystemPrompt (Just "Be terse.") "hi"
          @?= "System instructions:\nBe terse.\n\nUser request:\nhi"
    ]
