module ThinkingLevelSpec (tests) where

import Baikai.ThinkingLevel
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ThinkingLevel"
    [ testGroup "canonical rendering" renderTests,
      testGroup "token budgets" budgetTests
    ]

levels :: [(String, ThinkingLevel, Text, Integer)]
levels =
  [ ("minimal", ThinkingMinimal, "minimal", 1024),
    ("low", ThinkingLow, "low", 2048),
    ("medium", ThinkingMedium, "medium", 8192),
    ("high", ThinkingHigh, "high", 16384),
    ("xhigh", ThinkingXHigh, "xhigh", 24576),
    ("max", ThinkingMax, "max", 32768)
  ]

renderTests :: [TestTree]
renderTests =
  [ testCase name $ renderThinkingLevel level @?= expected
  | (name, level, expected, _) <- levels
  ]

budgetTests :: [TestTree]
budgetTests =
  [ testCase name $ thinkingTokenBudget level @?= fromInteger expected
  | (name, level, _, expected) <- levels
  ]
