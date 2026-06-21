-- | Token-usage accounting for a single provider call.
--
-- The shape splits cache-read tokens (the prompt fragment served from a
-- prior cache write) from cache-write tokens (the prompt fragment the
-- provider stored for future calls), so callers can reason about both
-- billing dimensions. 'cost' is always populated — providers without
-- pricing data fill it with '_Cost' (zero across all rates) rather than
-- a 'Nothing' that every cost-reading caller would have to handle.
module Baikai.Usage (Usage (..), _Usage, sumUsage) where

import Baikai.Cost (Cost, _Cost)
import Data.Aeson
  ( Options (fieldLabelModifier),
    ToJSON (toJSON),
    camelTo2,
    defaultOptions,
    genericToJSON,
  )
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Usage = Usage
  { inputTokens :: !Natural,
    outputTokens :: !Natural,
    cacheReadTokens :: !Natural,
    cacheWriteTokens :: !Natural,
    reasoningTokens :: !(Maybe Natural),
    totalTokens :: !Natural,
    cost :: !Cost
  }
  deriving stock (Eq, Show, Generic)

usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance ToJSON Usage where toJSON = genericToJSON usageOptions

_Usage :: Usage
_Usage =
  Usage
    { inputTokens = 0,
      outputTokens = 0,
      cacheReadTokens = 0,
      cacheWriteTokens = 0,
      reasoningTokens = Nothing,
      totalTokens = 0,
      cost = _Cost
    }

-- | Combine two optional reasoning-token counts. Presence wins: an
-- absent side counts as zero, but the result is only 'Nothing' when
-- both sides are 'Nothing', so a non-reasoning call summed with a
-- reasoning call keeps the reasoning total.
combineReasoning :: Maybe Natural -> Maybe Natural -> Maybe Natural
combineReasoning Nothing Nothing = Nothing
combineReasoning a b = Just (fromMaybe 0 a + fromMaybe 0 b)

instance Semigroup Usage where
  a <> b =
    Usage
      { inputTokens = inputTokens a + inputTokens b,
        outputTokens = outputTokens a + outputTokens b,
        cacheReadTokens = cacheReadTokens a + cacheReadTokens b,
        cacheWriteTokens = cacheWriteTokens a + cacheWriteTokens b,
        reasoningTokens = combineReasoning (reasoningTokens a) (reasoningTokens b),
        totalTokens = totalTokens a + totalTokens b,
        cost = cost a <> cost b
      }

instance Monoid Usage where
  mempty = _Usage

-- | Total a collection of per-call usages into one.
sumUsage :: (Foldable f) => f Usage -> Usage
sumUsage = foldl' (<>) mempty
