module UsageSpec (tests) where

import Baikai.Cost (Cost (..), CostBreakdown (..), zeroCost, zeroCostBreakdown)
import Baikai.Usage (Usage (..), sumUsage, zeroUsage)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Usage"
    [ identityTests,
      additionTests,
      reasoningTests,
      documentedSemanticsTests,
      costTests,
      sumUsageTests
    ]

-- | A non-trivial usage value for identity checks.
u0 :: Usage
u0 =
  zeroUsage
    { inputTokens = 10,
      outputTokens = 5,
      cacheReadTokens = 2,
      cacheWriteTokens = 1,
      reasoningTokens = Just 3,
      totalTokens = 18,
      cost = costOf 1 2 3 4
    }

-- | Build a 'Cost' whose breakdown carries the four given USD/100 rates
-- and whose 'usd' is their sum (so the totals stay self-consistent).
costOf :: Rational -> Rational -> Rational -> Rational -> Cost
costOf i o ci cw =
  Cost
    { usd = (i + o + ci + cw) / 100,
      breakdown =
        CostBreakdown
          { inputUsd = i / 100,
            outputUsd = o / 100,
            cachedInputUsd = ci / 100,
            cachedWriteUsd = cw / 100
          }
    }

identityTests :: TestTree
identityTests =
  testGroup
    "monoid identity"
    [ testCase "mempty <> u == u" $ (mempty <> u0) @?= u0,
      testCase "u <> mempty == u" $ (u0 <> mempty) @?= u0,
      testCase "mempty == zeroUsage" $ (mempty :: Usage) @?= zeroUsage
    ]

additionTests :: TestTree
additionTests =
  testGroup
    "field-wise addition"
    [ testCase "numeric fields add" $ do
        let a = zeroUsage {inputTokens = 10, outputTokens = 5, cacheReadTokens = 2, cacheWriteTokens = 1, totalTokens = 15}
            b = zeroUsage {inputTokens = 3, outputTokens = 1, cacheReadTokens = 4, cacheWriteTokens = 5, totalTokens = 4}
            s = a <> b
        inputTokens s @?= 13
        outputTokens s @?= 6
        cacheReadTokens s @?= 6
        cacheWriteTokens s @?= 6
        totalTokens s @?= 19
    ]

reasoningTests :: TestTree
reasoningTests =
  testGroup
    "reasoningTokens presence rule"
    [ testCase "Just <> Nothing == Just" $
        reasoningTokens (rJust 5 <> rNothing) @?= Just 5,
      testCase "Nothing <> Just == Just" $
        reasoningTokens (rNothing <> rJust 5) @?= Just 5,
      testCase "Nothing <> Nothing == Nothing" $
        reasoningTokens (rNothing <> rNothing) @?= Nothing,
      testCase "Just <> Just sums" $
        reasoningTokens (rJust 2 <> rJust 3) @?= Just 5
    ]
  where
    rJust n = zeroUsage {reasoningTokens = Just n}
    rNothing = zeroUsage {reasoningTokens = Nothing}

-- Provider mappings must uphold the documented field semantics:
-- 'anthroUsageToBaikai' in baikai-claude/src/Baikai/Provider/Claude/Api.hs
-- and 'rawUsageToUsage' in baikai-openai/src/Baikai/Provider/OpenAI/Api.hs.
documentedSemanticsTests :: TestTree
documentedSemanticsTests =
  testGroup
    "documented field semantics"
    [ testCase "totalTokens sums disjoint billed classes and excludes reasoning double-count" $ do
        let u =
              zeroUsage
                { inputTokens = 20,
                  outputTokens = 50,
                  cacheReadTokens = 80,
                  cacheWriteTokens = 7,
                  reasoningTokens = Just 20,
                  totalTokens = 157
                }
        totalTokens u
          @?= inputTokens u + outputTokens u + cacheReadTokens u + cacheWriteTokens u
    ]

costTests :: TestTree
costTests =
  testGroup
    "cost totals add"
    [ testCase "usd and breakdown add" $ do
        let a = zeroUsage {cost = costOf 1 0 0 0}
            b = zeroUsage {cost = costOf 2 0 0 0}
            c = cost (a <> b)
        usd c @?= 3 / 100
        inputUsd (breakdown c) @?= 3 / 100,
      testCase "breakdown is a monoid" $ do
        let s = breakdown (costOf 1 2 3 4) <> breakdown (costOf 5 6 7 8)
        inputUsd s @?= 6 / 100
        outputUsd s @?= 8 / 100
        cachedInputUsd s @?= 10 / 100
        cachedWriteUsd s @?= 12 / 100,
      testCase "mempty cost is zero" $ do
        (mempty :: Cost) @?= zeroCost
        (mempty :: CostBreakdown) @?= zeroCostBreakdown
    ]

sumUsageTests :: TestTree
sumUsageTests =
  testGroup
    "sumUsage"
    [ testCase "sumUsage equals chained <>" $ do
        let u1 = zeroUsage {inputTokens = 1, totalTokens = 1}
            u2 = zeroUsage {inputTokens = 2, totalTokens = 2}
            u3 = zeroUsage {inputTokens = 3, totalTokens = 3}
        sumUsage [u1, u2, u3] @?= (u1 <> u2 <> u3),
      testCase "sumUsage [] == mempty" $
        sumUsage [] @?= (mempty :: Usage)
    ]
