-- | Token-usage accounting for a single provider call.
--
-- The shape splits cache-read tokens (the prompt fragment served from a
-- prior cache write) from cache-write tokens (the prompt fragment the
-- provider stored for future calls), so callers can reason about both
-- billing dimensions. 'cost' is always populated — providers without
-- pricing data fill it with '_Cost' (zero across all rates) rather than
-- a 'Nothing' that every cost-reading caller would have to handle.
module Baikai.Usage (Usage (..), _Usage) where

import Baikai.Cost (Cost, _Cost)
import Data.Aeson
  ( Options (fieldLabelModifier)
  , ToJSON (toJSON)
  , camelTo2
  , defaultOptions
  , genericToJSON
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cacheReadTokens :: !Natural
  , cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural)
  , totalTokens :: !Natural
  , cost :: !Cost
  }
  deriving stock (Eq, Show, Generic)

usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance ToJSON Usage where toJSON = genericToJSON usageOptions

_Usage :: Usage
_Usage =
  Usage
    { inputTokens = 0
    , outputTokens = 0
    , cacheReadTokens = 0
    , cacheWriteTokens = 0
    , reasoningTokens = Nothing
    , totalTokens = 0
    , cost = _Cost
    }
