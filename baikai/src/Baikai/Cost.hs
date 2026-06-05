module Baikai.Cost
  ( Cost (..),
    CostBreakdown (..),
    _Cost,
    _CostBreakdown,
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

_CostBreakdown :: CostBreakdown
_CostBreakdown =
  CostBreakdown
    { inputUsd = 0,
      outputUsd = 0,
      cachedInputUsd = 0,
      cachedWriteUsd = 0
    }

_Cost :: Cost
_Cost = Cost {usd = 0, breakdown = _CostBreakdown}

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
