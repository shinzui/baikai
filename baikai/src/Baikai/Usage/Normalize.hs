-- | Shared billing-category normalization. Adapters extract optional wire
-- counts; this module preserves their availability without inferring writes.
module Baikai.Usage.Normalize (InputAccounting (..), ReportedUsage (..), normalizeUsage) where

import Baikai.Usage qualified as U
import Data.Maybe (fromMaybe, isNothing)
import Data.Set qualified as Set
import Numeric.Natural (Natural)

data InputAccounting = InclusiveInput | ExclusiveInput
  deriving stock (Eq, Show)

data ReportedUsage = ReportedUsage
  { inputTokens :: !(Maybe Natural),
    outputTokens :: !(Maybe Natural),
    cacheReadTokens :: !(Maybe Natural),
    cacheWriteTokens :: !(Maybe Natural),
    reasoningTokens :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

normalizeUsage :: InputAccounting -> ReportedUsage -> U.Usage
normalizeUsage accounting r =
  let input = fromMaybe 0 (inputTokens r)
      output = fromMaybe 0 (outputTokens r)
      cached = fromMaybe 0 (cacheReadTokens r)
      writes = fromMaybe 0 (cacheWriteTokens r)
      fresh = case accounting of
        ExclusiveInput -> input
        InclusiveInput -> if cached + writes > input then 0 else input - cached - writes
      invalidInput = accounting == InclusiveInput && maybe False (cached + writes >) (inputTokens r)
      invalidReasoning = case (reasoningTokens r, outputTokens r) of
        (Just reasoning, Just out) -> reasoning > out
        _ -> False
      missing = Set.fromList [category | (category, count) <- [(U.InputUsage, inputTokens r), (U.OutputUsage, outputTokens r), (U.CacheReadUsage, cacheReadTokens r), (U.CacheWriteUsage, cacheWriteTokens r)], isNothing count]
   in U.zeroUsage
        { U.inputTokens = fresh,
          U.outputTokens = output,
          U.cacheReadTokens = cached,
          U.cacheWriteTokens = writes,
          U.reasoningTokens = reasoningTokens r,
          U.totalTokens = fresh + output + cached + writes,
          U.availability = Just (U.UsageAvailability missing (invalidInput || invalidReasoning) Set.empty)
        }
