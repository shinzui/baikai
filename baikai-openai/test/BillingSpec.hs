{-# LANGUAGE OverloadedRecordDot #-}

module BillingSpec (tests) where

import Baikai.Cost qualified as C
import Baikai.Cost.Pricing (computeCost)
import Baikai.Evidence (commitmentDigest, usageEnvelope)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Internal.Usage
import Baikai.Usage qualified as U
import Baikai.Usage.Normalize qualified as N
import Control.Monad (forM_)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.Types qualified
import Data.Set qualified as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Billing normalization"
    [ testCase "both endpoints subtract reported reads and writes exactly once" $
        forM_ [ChatUsage, ResponsesUsage] $ \endpoint -> do
          u <- parsed endpoint (wire endpoint 15000 ["cached_tokens" .= (12000 :: Int), "cache_write_tokens" .= (3000 :: Int)])
          (u.inputTokens, u.cacheReadTokens, u.cacheWriteTokens, u.outputTokens, u.totalTokens) @?= (0, 12000, 3000, 100, 15100)
          u.availability @?= Just (U.UsageAvailability Set.empty False)
          (computeCost Models.openai_gpt_6_astra u).usd @?= 109 / 2000,
      testCase "missing writes retain counts but make cost an explicit estimate" $ do
        missing <- parsed ResponsesUsage (wire ResponsesUsage 15000 ["cached_tokens" .= (12000 :: Int)])
        zero <- parsed ResponsesUsage (wire ResponsesUsage 15000 ["cached_tokens" .= (12000 :: Int), "cache_write_tokens" .= (0 :: Int)])
        missing.inputTokens @?= 3000
        missing.totalTokens @?= zero.totalTokens
        (computeCost Models.openai_gpt_6_astra missing).basis.estimateReasons @?= Set.singleton C.CacheWriteUsageNotReported
        (computeCost Models.openai_gpt_6_astra zero).basis.estimateReasons @?= Set.empty
        assertBool "provider commitments distinguish omitted and zero counters" (commitmentDigest (usageEnvelope missing) /= commitmentDigest (usageEnvelope zero)),
      testCase "empty usage is unreported but explicit zero is reported" $ do
        readUsage ResponsesUsage (object []) @?= Nothing
        (computeCost Models.openai_gpt_6_astra unreportedUsage).basis.estimateReasons @?= Set.singleton C.UsageNotReported
        zero <- parsed ResponsesUsage (object ["input_tokens" .= (0 :: Int), "output_tokens" .= (0 :: Int), "input_tokens_details" .= object ["cached_tokens" .= (0 :: Int), "cache_write_tokens" .= (0 :: Int)]])
        zero.totalTokens @?= 0
        (computeCost Models.openai_gpt_6_astra zero).basis.estimateReasons @?= Set.empty,
      testCase "partial usage retains its reported categories" $ do
        u <- parsed ChatUsage (object ["completion_tokens" .= (50 :: Int)])
        u.outputTokens @?= 50
        u.availability @?= Just (U.UsageAvailability (Set.fromList [U.InputUsage, U.CacheReadUsage, U.CacheWriteUsage]) False),
      testCase "invalid and inconsistent counters are never exact" $
        forM_ [wire ResponsesUsage 100 ["cached_tokens" .= (120 :: Int)], wire ResponsesUsage 100 ["cache_write_tokens" .= (-1 :: Int)], wire ResponsesUsage 100 ["cached_tokens" .= (1.5 :: Double)]] $ \raw -> do
          u <- parsed ResponsesUsage raw
          assertBool "inconsistency survives into calculation basis" (C.InconsistentUsage `Set.member` (computeCost Models.openai_gpt_6_astra u).basis.estimateReasons),
      testCase "exclusive input sums cache categories and reasoning stays a subset" $ do
        let u = N.normalizeUsage N.ExclusiveInput (N.ReportedUsage (Just 10) (Just 100) (Just 20) (Just 30) (Just 80))
        (u.inputTokens, u.totalTokens) @?= (10, 160)
        u.availability @?= Just (U.UsageAvailability Set.empty False),
      testCase "cumulative snapshots retain missing fields and never double counts" $ do
        let initial = wire ResponsesUsage 15000 ["cached_tokens" .= (12000 :: Int)]
            final = object ["output_tokens" .= (200 :: Int), "input_tokens_details" .= object ["cache_write_tokens" .= (3000 :: Int)]]
            snapshot = mergeUsage (Just initial) (Just final)
        mergeUsage snapshot (Just final) @?= snapshot
        u <- maybe (assertFailure "missing merged usage") (parsed ResponsesUsage) snapshot
        (u.inputTokens, u.outputTokens, u.cacheReadTokens, u.cacheWriteTokens, u.totalTokens) @?= (0, 200, 12000, 3000, 15200)
        u.availability @?= Just (U.UsageAvailability Set.empty False),
      testCase "availability aggregation retains unknown categories and monoid identity" $ do
        a <- parsed ResponsesUsage (wire ResponsesUsage 100 [])
        b <- parsed ResponsesUsage (wire ResponsesUsage 100 ["cached_tokens" .= (120 :: Int)])
        mempty <> a @?= a
        a <> mempty @?= a
        (a <> b) <> a @?= a <> (b <> a)
        U.inconsistent <$> (a <> b).availability @?= Just True
    ]

wire :: UsageEndpoint -> Int -> [Data.Aeson.Types.Pair] -> Value
wire endpoint input details =
  let (i, o, d) = case endpoint of ChatUsage -> ("prompt_tokens", "completion_tokens", "prompt_tokens_details"); ResponsesUsage -> ("input_tokens", "output_tokens", "input_tokens_details")
   in object [(i :: Key) .= input, o .= (100 :: Int), d .= object details]

parsed :: UsageEndpoint -> Value -> IO U.Usage
parsed endpoint raw = maybe (assertFailure "expected usage") pure (readUsage endpoint raw)
