{-# LANGUAGE OverloadedRecordDot #-}

module PricingPolicySpec (tests) where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Cost qualified as C
import Baikai.Cost.Pricing (computeCost, computeCostWith, resolveRates)
import Baikai.Model qualified as M
import Baikai.Models.Generated qualified as Models
import Baikai.Usage qualified as U
import Control.Lens ((&), (.~))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Set qualified as Set
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Pricing policy"
    [ testCase "context thresholds are exclusive and price the whole request" $
        forM_ [(271999, base), (272000, base), (272001, high)] $ \(n, expectedRates) -> do
          let u = U.zeroUsage & #inputTokens .~ n & #outputTokens .~ 100
          resolveRates Nothing astra u @?= Right expectedRates
          (computeCost astra u).usd @?= (fromIntegral n * expectedRates.inputCost + 100 * expectedRates.outputCost) / 1000000,
      testCase "272001 input plus 100 output costs exactly 5.44752" $
        (computeCost astra (U.zeroUsage & #inputTokens .~ 272001 & #outputTokens .~ 100)).usd @?= 544752 / 100000,
      testCase "cache reads and writes both contribute to context threshold" $ do
        forM_ [U.zeroUsage & #inputTokens .~ 272000 & #cacheReadTokens .~ 1, U.zeroUsage & #inputTokens .~ 272000 & #cacheWriteTokens .~ 1] $ \u -> resolveRates Nothing astra u @?= Right high
        resolveRates Nothing astra (U.zeroUsage & #cacheReadTokens .~ 136000 & #cacheWriteTokens .~ 136000) @?= Right base,
      testCase "Fable cache reads and shaped write duration use exact rates" $ do
        (computeCost fable (U.zeroUsage & #cacheReadTokens .~ 1000)).usd @?= 1 / 4000
        (computeCostWith (Just CacheRetentionShort) fable (U.zeroUsage & #cacheWriteTokens .~ 1000)).usd @?= 1 / 80
        (computeCostWith (Just CacheRetentionLong) fable (U.zeroUsage & #cacheWriteTokens .~ 1000)).usd @?= 1 / 50,
      testCase "reasoning is a subset of output, not an extra charge" $ do
        let u = U.zeroUsage & #outputTokens .~ 100
        computeCost astra (u & #reasoningTokens .~ Just 75) @?= computeCost astra u,
      testCase "flat policies retain base calculations" $ do
        let flat = astra & #pricingPolicy .~ Nothing
        resolveRates (Just CacheRetentionLong) flat (U.zeroUsage & #inputTokens .~ 900000) @?= Right base,
      testCase "duplicate, unordered and negative policy data are rejected" $ do
        forM_ [M.PricingPolicy [M.InputPriceTier 2 high, M.InputPriceTier 2 base] Nothing, M.PricingPolicy [M.InputPriceTier 2 high, M.InputPriceTier 1 base] Nothing, M.PricingPolicy [] (Just (-1)), M.PricingPolicy [M.InputPriceTier 1 (base & #inputCost .~ (-1))] Nothing] $ \p -> do
          assertBool "pure validation rejects" (case M.validatePricingPolicy p of Left _ -> True; _ -> False)
          case Aeson.fromJSON (Aeson.toJSON p) :: Aeson.Result M.PricingPolicy of Aeson.Error _ -> pure (); _ -> assertFailure "invalid policy decoded"
        let negative = Aeson.object ["inputTiers" Aeson..= [Aeson.object ["inputAbove" Aeson..= (-1 :: Int), "rates" Aeson..= base]]]
        case Aeson.fromJSON negative :: Aeson.Result M.PricingPolicy of Aeson.Error _ -> pure (); _ -> assertFailure "negative threshold decoded",
      testCase "old model JSON without a policy decodes and new policy round trips" $ do
        let old = case Aeson.toJSON M.emptyModel of Aeson.Object o -> Aeson.Object (KM.delete "pricingPolicy" o); v -> v
        case Aeson.fromJSON old of Aeson.Success m -> (m :: M.Model).pricingPolicy @?= Nothing; Aeson.Error err -> assertFailure err
        case Aeson.fromJSON (Aeson.toJSON astra) of Aeson.Success m -> (m :: M.Model) @?= astra; Aeson.Error err -> assertFailure err,
      testCase "estimated components retain reasons and provenance when summed" $ do
        let known = computeCost fable (U.zeroUsage & #cacheReadTokens .~ 1000)
            missing = C.estimateCost [C.CacheWriteUsageNotReported] known
            unknown = C.estimateCost [C.ServiceTierNotReported, C.CacheWriteUsageNotReported] known
            total = known <> missing <> unknown
        total.usd @?= 3 * known.usd
        total.basis.estimateReasons @?= Set.fromList [C.CacheWriteUsageNotReported, C.ServiceTierNotReported]
        total.basis.sources @?= Set.singleton C.StandardTokenRates
        mempty <> total @?= total
        total <> mempty @?= total
        (known <> missing) <> unknown @?= known <> (missing <> unknown)
        case Aeson.fromJSON (Aeson.toJSON total.basis) of Aeson.Success decoded -> decoded @?= total.basis; Aeson.Error err -> assertFailure err,
      testCase "unavailable prices carry an explicit estimate reason" $
        (computeCost M.emptyModel (U.zeroUsage & #inputTokens .~ 50)).basis.estimateReasons @?= Set.singleton C.PricingUnavailable
    ]

base :: M.ModelCost
base = M.ModelCost 10 50 1 (25 / 2)

high :: M.ModelCost
high = M.ModelCost 20 75 2 25

astra :: M.Model
astra = Models.openai_gpt_6_astra

fable :: M.Model
fable = Models.anthropic_claude_fable_5_1
