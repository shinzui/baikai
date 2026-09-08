module Baikai.Cost
  ( Cost (..),
    CostBreakdown (..),
    CostBasis (..),
    CostSource (..),
    CostEstimateReason (..),
    standardCostBasis,
    providerReportedBasis,
    estimateCost,
    nonEmptyBasis,
    zeroCost,
    zeroCostBreakdown,
    usdAsScientific,
  )
where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Scientific (Scientific, fromRationalRepetendUnlimited)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

-- | What the number represents; a standard token calculation is not an invoice.
data CostSource = StandardTokenRates | ProviderReportedTotal
  deriving stock (Eq, Ord, Show, Generic)

data CostEstimateReason
  = UsageNotReported
  | InputUsageNotReported
  | OutputUsageNotReported
  | CacheReadUsageNotReported
  | CacheWriteUsageNotReported
  | InconsistentUsage
  | ServiceTierNotReported
  | UnsupportedServiceTier Text
  | ServiceTierMismatch Text Text
  | PricingUnavailable
  | InvalidPricingPolicy
  | CacheDurationNotReported
  | AdditionalChargesExcluded
  deriving stock (Eq, Ord, Show, Generic)

-- | Sources and estimation reasons survive aggregation by set union.
-- An empty basis belongs to the additive zero, not to an observed free call.
data CostBasis = CostBasis
  { sources :: !(Set CostSource),
    estimateReasons :: !(Set CostEstimateReason)
  }
  deriving stock (Eq, Show, Generic)

basisOptions :: Aeson.Options
basisOptions = Aeson.defaultOptions {Aeson.fieldLabelModifier = Aeson.camelTo2 '_', Aeson.constructorTagModifier = Aeson.camelTo2 '_'}

instance ToJSON CostSource where toJSON = Aeson.genericToJSON basisOptions

instance FromJSON CostSource where parseJSON = Aeson.genericParseJSON basisOptions

instance ToJSON CostEstimateReason where toJSON = Aeson.genericToJSON basisOptions

instance FromJSON CostEstimateReason where parseJSON = Aeson.genericParseJSON basisOptions

instance ToJSON CostBasis where toJSON = Aeson.genericToJSON basisOptions

instance FromJSON CostBasis where parseJSON = Aeson.genericParseJSON basisOptions

instance Semigroup CostBasis where
  a <> b = CostBasis (sources a <> sources b) (estimateReasons a <> estimateReasons b)

instance Monoid CostBasis where mempty = CostBasis Set.empty Set.empty

standardCostBasis :: CostBasis
standardCostBasis = CostBasis (Set.singleton StandardTokenRates) Set.empty

providerReportedBasis :: CostBasis
providerReportedBasis = CostBasis (Set.singleton ProviderReportedTotal) Set.empty

estimateCost :: [CostEstimateReason] -> Cost -> Cost
estimateCost reasons c = c {basis = basis c <> CostBasis Set.empty (Set.fromList reasons)}

-- | The additive zero carries no calculation facts. Omit that empty basis
-- when adding optional metadata to existing trace and log formats.
nonEmptyBasis :: Cost -> Maybe CostBasis
nonEmptyBasis c = if basis c == mempty then Nothing else Just (basis c)

data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational,
    outputUsd :: !Rational,
    cachedInputUsd :: !Rational,
    cachedWriteUsd :: !Rational
  }
  deriving stock (Eq, Show, Generic)

data Cost = Cost
  { usd :: !Rational,
    breakdown :: !CostBreakdown,
    basis :: !CostBasis
  }
  deriving stock (Eq, Show, Generic)

zeroCostBreakdown :: CostBreakdown
zeroCostBreakdown =
  CostBreakdown
    { inputUsd = 0,
      outputUsd = 0,
      cachedInputUsd = 0,
      cachedWriteUsd = 0
    }

zeroCost :: Cost
zeroCost = Cost {usd = 0, breakdown = zeroCostBreakdown, basis = mempty}

-- Field-wise combination so callers can total per-call costs with
-- '(<>)'/'mconcat'. 'mempty' reuses the existing zero value, so the
-- identity laws hold by construction (adding zero rationals).

instance Semigroup CostBreakdown where
  a <> b =
    CostBreakdown
      { inputUsd = inputUsd a + inputUsd b,
        outputUsd = outputUsd a + outputUsd b,
        cachedInputUsd = cachedInputUsd a + cachedInputUsd b,
        cachedWriteUsd = cachedWriteUsd a + cachedWriteUsd b
      }

instance Monoid CostBreakdown where
  mempty = zeroCostBreakdown

instance Semigroup Cost where
  a <> b = Cost {usd = usd a + usd b, breakdown = breakdown a <> breakdown b, basis = basis a <> basis b}

instance Monoid Cost where
  mempty = zeroCost

instance ToJSON CostBreakdown where
  toJSON cb =
    object
      [ "input_usd" .= ratToSci (inputUsd cb),
        "output_usd" .= ratToSci (outputUsd cb),
        "cached_input_usd" .= ratToSci (cachedInputUsd cb),
        "cached_write_usd" .= ratToSci (cachedWriteUsd cb)
      ]

instance ToJSON Cost where
  toJSON c =
    object
      [ "usd" .= ratToSci (usd c),
        "breakdown" .= breakdown c,
        "basis" .= basis c
      ]

usdAsScientific :: Cost -> Scientific
usdAsScientific = ratToSci . usd

ratToSci :: Rational -> Scientific
ratToSci = fst . fromRationalRepetendUnlimited
