-- | Shared Chat/Responses usage extraction. Input totals are inclusive of
-- cache reads and writes; missing categories stay explicit after normalization.
-- Wire semantics: https://developers.openai.com/api/docs/guides/prompt-caching
-- Chat's prompt_tokens_details.cache_write_tokens is documented at
-- https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create
-- (verified 2026-09-07).
module Baikai.Provider.OpenAI.Internal.Usage (UsageEndpoint (..), readUsage, unreportedUsage, mergeUsage) where

import Baikai.Usage qualified as U
import Baikai.Usage.Normalize qualified as N
import Data.Aeson (Value (..))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (isJust, isNothing)
import Numeric.Natural (Natural)

data UsageEndpoint = ChatUsage | ResponsesUsage

unreportedUsage :: U.Usage
unreportedUsage = N.normalizeUsage N.InclusiveInput (N.ReportedUsage Nothing Nothing Nothing Nothing Nothing)

readUsage :: UsageEndpoint -> Value -> Maybe U.Usage
readUsage endpoint value =
  let (inputKey, outputKey, inputDetails, outputDetails) = case endpoint of
        ChatUsage -> ("prompt_tokens", "completion_tokens", "prompt_tokens_details", "completion_tokens_details")
        ResponsesUsage -> ("input_tokens", "output_tokens", "input_tokens_details", "output_tokens_details")
      input = field inputKey value
      output = field outputKey value
      cached = field inputDetails value >>= field "cached_tokens"
      writes = field inputDetails value >>= field "cache_write_tokens"
      reasoning = field outputDetails value >>= field "reasoning_tokens"
      raw = [input, output, cached, writes, reasoning]
      count v = v >>= natural
      normalized = N.normalizeUsage N.InclusiveInput (N.ReportedUsage (count input) (count output) (count cached) (count writes) (count reasoning))
      malformed = any (\v -> isJust v && isNothing (count v)) raw
      mark facts = facts {U.inconsistent = U.inconsistent facts || malformed}
   in if any isJust raw then Just normalized {U.availability = mark <$> U.availability normalized} else Nothing
  where
    field :: Key -> Value -> Maybe Value
    field key (Object o) = case KM.lookup key o of Just Null -> Nothing; found -> found
    field _ _ = Nothing
    natural :: Value -> Maybe Natural
    natural (Number n) | n >= 0, fromInteger (floor n) == n = Just (fromInteger (floor n))
    natural _ = Nothing

-- | Usage events are cumulative snapshots, never increments. Omitted fields
-- preserve earlier observations; explicit zero replaces the previous value.
mergeUsage :: Maybe Value -> Maybe Value -> Maybe Value
mergeUsage old Nothing = old
mergeUsage Nothing new = new
mergeUsage (Just old) (Just new) = Just (merge new old)
  where
    merge Null previous = previous
    merge (Object newer) (Object previous) = Object (KM.unionWith merge newer previous)
    merge newer _ = newer
