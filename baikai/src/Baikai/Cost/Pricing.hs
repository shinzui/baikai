-- | Cost computation from a 'Baikai.Model.Model' and a 'Usage'.
--
-- Base prices and optional context/duration policies live on the model.
-- Arithmetic stays exact, and unavailable pricing carries an estimate reason.
module Baikai.Cost.Pricing
  ( computeCost,
    computeCostAtSpeed,
    attachCost,
    resolveRates,
    computeCostWith,
    computeCostForService,
    computeCostAtRates,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Cost (Cost (..), CostBreakdown (..), CostEstimateReason (..), CostSource (..), estimateCost, standardCostBasis)
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (InputPriceTier (..), Model, ModelCost (..), PricingPolicy (..), validatePricingPolicy, zeroModelCost)
import Baikai.Prelude
import Baikai.Response (Response (..))
import Baikai.Speed (Speed (..))
import Baikai.Usage (BillingFact (..), Usage (..), UsageAvailability (..), UsageCategory (..))
import Data.Set qualified as Set

-- | Compute a 'Cost' from a model's per-million-token rates and a
-- 'Usage'. Zero rates retain the old numeric total and now mark pricing
-- unavailable. This entry point assumes the standard cache duration.
-- Use 'computeCostAtSpeed' to select premium speed rates explicitly.
computeCost :: Model -> Usage -> Cost
computeCost = computeCostWith Nothing

-- | Duration must be the value selected by request shaping, not merely
-- requested by the caller. Service-tier and usage availability are supplied
-- by adapters as estimation reasons on the resulting cost.
computeCostWith :: Maybe CacheRetention -> Model -> Usage -> Cost
computeCostWith duration m u = priceUsage (resolveRates duration m u) u

-- | Shared terminal pricing entry point. Observed tiers and speed come from
-- Usage availability, never from the caller's preference. Uncurated products
-- retain a standard-rate estimate with a specific reason.
computeCostForService :: Maybe CacheRetention -> Maybe Text -> Model -> Usage -> Cost
computeCostForService duration requested m u =
  let facts = maybe [] (Set.toList . billingFacts) (u ^. #availability)
      tiers = [t | BillingServiceTier t <- facts]
      speeds = [s | BillingSpeed s <- facts]
      reasons =
        [ServiceTierNotReported | null tiers]
          <> [AdditionalChargesExcluded | BillingServerToolUse `elem` facts]
          <> [UnsupportedServiceTier t | t <- tiers, t `notElem` ["default", "standard"]]
          <> [UnsupportedSpeed s | s <- speeds, s /= "standard", s /= "fast" || m ^. #fastModeCost == Nothing]
          <> [InconsistentUsage | length speeds > 1]
          <> [ServiceTierMismatch wanted actual | Just wanted <- [requested], wanted /= "auto", actual <- tiers, not (matches wanted actual)]
   in estimateCost reasons (if speeds == ["fast"] then priceAtSpeed duration m SpeedFast u else computeCostWith duration m u)
  where
    matches wanted actual = wanted == actual || (wanted == "standard_only" && actual == "standard") || (wanted == "fast" && actual == "priority")

-- | Price an explicitly selected speed with the standard cache duration.
-- Standard agrees exactly with 'computeCost'. Missing fast rates retain a
-- standard-rate estimate with 'UnsupportedSpeed', never a fabricated zero.
-- This helper does not claim the provider observed the selected speed.
computeCostAtSpeed :: Model -> Speed -> Usage -> Cost
computeCostAtSpeed = priceAtSpeed Nothing

priceAtSpeed :: Maybe CacheRetention -> Model -> Speed -> Usage -> Cost
priceAtSpeed duration m SpeedStandard u = computeCostWith duration m u
priceAtSpeed duration m SpeedFast u = case m ^. #fastModeCost of
  Nothing -> estimateCost [UnsupportedSpeed "fast"] (computeCostWith duration m u)
  Just fast ->
    let resolved = do
          validatePricingPolicy (PricingPolicy [InputPriceTier 0 fast] Nothing)
          standard <- resolveRates duration m u
          let base = m ^. #cost
              -- Apply each premium rate's ratio to the resolved policy once.
              -- A zero base cannot define a ratio for a nonzero policy rate.
              scale b f r
                | b > 0 = Right (r * f / b)
                | r == 0 = Right f
                | otherwise = Left "Cannot apply fast rates to a zero-base pricing policy"
          ModelCost
            <$> scale (inputCost base) (inputCost fast) (inputCost standard)
            <*> scale (outputCost base) (outputCost fast) (outputCost standard)
            <*> scale (cacheReadCost base) (cacheReadCost fast) (cacheReadCost standard)
            <*> scale (cacheWriteCost base) (cacheWriteCost fast) (cacheWriteCost standard)
        computed = priceUsage resolved u
     in computed & #basis . #sources .~ Set.singleton ResolvedTokenRates

-- | Price one resolved rate record exactly once.
computeCostAtRates :: ModelCost -> Usage -> Cost
computeCostAtRates rates u =
  let resolved = validatePricingPolicy (PricingPolicy [InputPriceTier 0 rates] Nothing) >> pure rates
      computed = priceUsage resolved u
   in computed & #basis . #sources .~ Set.singleton ResolvedTokenRates

priceUsage :: Either Text ModelCost -> Usage -> Cost
priceUsage resolved u =
  let selected = either (const zeroModelCost) id resolved
      problems = [InvalidPricingPolicy | Left _ <- [resolved]] <> [PricingUnavailable | selected == ModelCost 0 0 0 0]
      rates = selected
      inRate = inputCost rates
      outRate = outputCost rates
      crRate = cacheReadCost rates
      cwRate = cacheWriteCost rates
      inUsd = toRational (u ^. #inputTokens) * inRate / 1_000_000
      outUsd = toRational (u ^. #outputTokens) * outRate / 1_000_000
      cachedUsd = toRational (u ^. #cacheReadTokens) * crRate / 1_000_000
      cacheWriteUsd = toRational (u ^. #cacheWriteTokens) * cwRate / 1_000_000
      total = inUsd + outUsd + cachedUsd + cacheWriteUsd
   in estimateCost
        (problems <> usageProblems u)
        Cost
          { usd = total,
            basis = standardCostBasis,
            breakdown =
              CostBreakdown
                { inputUsd = inUsd,
                  outputUsd = outUsd,
                  cachedInputUsd = cachedUsd,
                  cachedWriteUsd = cacheWriteUsd
                }
          }

-- | Legacy, manually constructed usages have no availability annotation.
-- Normalized provider usages always carry one, even for an entirely absent body.
usageProblems :: Usage -> [CostEstimateReason]
usageProblems u = case u ^. #availability of
  Nothing -> []
  Just facts ->
    [InconsistentUsage | inconsistent facts]
      <> if Set.size (missingCategories facts) == 4
        then [UsageNotReported]
        else map reason (Set.toList (missingCategories facts))
  where
    reason InputUsage = InputUsageNotReported
    reason OutputUsage = OutputUsageNotReported
    reason CacheReadUsage = CacheReadUsageNotReported
    reason CacheWriteUsage = CacheWriteUsageNotReported

-- | Choose one complete rate record. Thresholds are exclusive and use
-- disjoint normalized input categories, including both cache counters.
resolveRates :: Maybe CacheRetention -> Model -> Usage -> Either Text ModelCost
resolveRates duration m u = do
  validatePricingPolicy (PricingPolicy [InputPriceTier 0 (m ^. #cost)] Nothing)
  case m ^. #pricingPolicy of
    Nothing -> pure (m ^. #cost)
    Just policy -> do
      validatePricingPolicy policy
      let totalInput = (u ^. #inputTokens) + (u ^. #cacheReadTokens) + (u ^. #cacheWriteTokens)
          selected = foldl' (\current tier -> if totalInput > inputAbove tier then rates tier else current) (m ^. #cost) (inputTiers policy)
      pure $ case (duration, longCacheWriteCost policy) of
        (Just CacheRetentionLong, Just price) -> selected {cacheWriteCost = price}
        _ -> selected

-- | Replace the assistant response payload's embedded 'Cost' with one
-- computed from the supplied model.
attachCost :: Model -> Response -> Response
attachCost m r =
  let AssistantPayload
        { usage = u,
          content = c,
          stopReason = sr,
          errorMessage = em,
          timestamp = ts
        } = r ^. #message
      computed = computeCost m u
      u' = u & #cost .~ computed
      msg' =
        AssistantPayload
          { content = c,
            usage = u',
            stopReason = sr,
            errorMessage = em,
            timestamp = ts
          }
   in r & #message .~ msg'
