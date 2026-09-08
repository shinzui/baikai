-- | Provider-independent inference speed preference. Anthropic sends fast mode
-- only for catalog entries advertising it (currently Opus 5 and Opus 4.8).
-- Their published fast rates are twice standard rates. Unsupported fast
-- requests are dropped with an evidence adjustment. Other providers omit it.
-- A request is a preference; only provider usage reports which speed ran.
module Baikai.Speed (Speed (..)) where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

data Speed = SpeedStandard | SpeedFast
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
