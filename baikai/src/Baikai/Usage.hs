-- | Token-usage accounting for a single provider call.
--
-- The prompt-side fields are provider-normalized into disjoint token
-- classes. 'inputTokens' counts only non-cached prompt tokens and
-- excludes both cache counters. 'cacheReadTokens' counts prompt tokens
-- served from a provider-side cache; 'cacheWriteTokens' counts prompt
-- tokens stored for future cache reads. Providers whose wire format is
-- inclusive, such as OpenAI Chat Completions where @prompt_tokens@
-- includes @prompt_tokens_details.cached_tokens@, must normalize by
-- subtraction when constructing 'Usage'.
--
-- 'totalTokens' is the sum of the billed token classes:
-- 'inputTokens' + 'outputTokens' + 'cacheReadTokens' +
-- 'cacheWriteTokens'. Provider mappings compute it from the normalized
-- parts rather than trusting a wire total. 'reasoningTokens', when
-- present, is an informational subset of 'outputTokens'; it is already
-- counted in 'outputTokens' and 'totalTokens' and is not billed
-- separately.
--
-- 'cost' is always populated — providers without pricing data fill it
-- with 'zeroCost' (zero across all rates) rather than a 'Nothing' that
-- every cost-reading caller would have to handle. 'Baikai.Cost.Pricing.computeCost'
-- depends on the token classes being disjoint so each class is billed
-- exactly once.
module Baikai.Usage (Usage (..), zeroUsage, sumUsage) where

import Baikai.Cost (Cost, zeroCost)
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

-- | Provider-normalized token usage for one model call.
--
-- The prompt-side classes are disjoint: 'inputTokens' excludes
-- 'cacheReadTokens' and 'cacheWriteTokens'. 'totalTokens' is the sum
-- of all billed token classes, and 'reasoningTokens' is an optional
-- breakdown already included in 'outputTokens'.
data Usage = Usage
  { -- | Non-cached prompt tokens. Excludes 'cacheReadTokens' and
    -- 'cacheWriteTokens'.
    inputTokens :: !Natural,
    -- | Output tokens billed at the model's output rate. Any
    -- 'reasoningTokens' are already included here.
    outputTokens :: !Natural,
    -- | Prompt tokens served from a provider-side cache.
    cacheReadTokens :: !Natural,
    -- | Prompt tokens written into a provider-side cache for future
    -- reads.
    cacheWriteTokens :: !Natural,
    -- | Optional reasoning/thinking-token breakdown. These tokens are
    -- an informational subset of 'outputTokens', not an additional
    -- billed class.
    reasoningTokens :: !(Maybe Natural),
    -- | Sum of the billed token classes:
    -- 'inputTokens' + 'outputTokens' + 'cacheReadTokens' +
    -- 'cacheWriteTokens'.
    totalTokens :: !Natural,
    -- | Computed cost for this usage. Providers without pricing data
    -- use 'zeroCost'.
    cost :: !Cost
  }
  deriving stock (Eq, Show, Generic)

usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance ToJSON Usage where toJSON = genericToJSON usageOptions

-- | Empty usage with every count and cost set to zero.
zeroUsage :: Usage
zeroUsage =
  Usage
    { inputTokens = 0,
      outputTokens = 0,
      cacheReadTokens = 0,
      cacheWriteTokens = 0,
      reasoningTokens = Nothing,
      totalTokens = 0,
      cost = zeroCost
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
  mempty = zeroUsage

-- | Total a collection of per-call usages into one.
sumUsage :: (Foldable f) => f Usage -> Usage
sumUsage = foldl' (<>) mempty
