-- | Hermetic end-to-end test of the blocking 'complete' operation: a value flows
-- @call site → send → interpret → baikai (isolated registry) → Response → Eff@.
module CompleteSpec (tests) where

import Baikai (flattenAssistantBlocks)
import Baikai.Effectful (complete, runBaikaiWith)
import Effectful (runEff)
import StubProvider (flattenAssistantText, stubContext, stubModel, stubOptions, stubRegistry)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "CompleteSpec"
    [ testCase "complete returns stub text" $ do
        reg <- stubRegistry "hello from stub"
        out <-
          runEff . runBaikaiWith reg $ do
            r <- complete stubModel stubContext stubOptions
            pure (flattenAssistantText (flattenAssistantBlocks r))
        out @?= "hello from stub"
    ]
