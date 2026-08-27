module Baikai.Cost
  ( Cost (..),
    CostBreakdown (..),
    zeroCost,
    zeroCostBreakdown,
    usdAsScientific,
  )
where

import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Scientific (Scientific, fromRationalRepetendUnlimited)
import GHC.Generics (Generic)

data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational,
    outputUsd :: !Rational,
    cachedInputUsd :: !Rational,
    cachedWriteUsd :: !Rational
  }
  deriving stock (Eq, Show, Generic)

data Cost = Cost
  { usd :: !Rational,
    breakdown :: !CostBreakdown
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
zeroCost = Cost {usd = 0, breakdown = zeroCostBreakdown}

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
  a <> b = Cost {usd = usd a + usd b, breakdown = breakdown a <> breakdown b}

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
        "breakdown" .= breakdown c
      ]

usdAsScientific :: Cost -> Scientific
usdAsScientific = ratToSci . usd

ratToSci :: Rational -> Scientific
ratToSci = fst . fromRationalRepetendUnlimited
