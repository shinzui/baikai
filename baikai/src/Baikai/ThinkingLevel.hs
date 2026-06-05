{-# LANGUAGE LambdaCase #-}

-- | Provider-agnostic reasoning-effort preference.
--
-- Each provider maps the value to its own primitive: OpenAI uses
-- @reasoning_effort: "minimal" | "low" | "medium" | "high"@;
-- Anthropic uses a token budget on its @thinking@ field.
-- 'thinkingTokenBudget' provides the recommended budget for the
-- token-based providers.
module Baikai.ThinkingLevel
  ( ThinkingLevel (..),
    renderThinkingLevel,
    thinkingTokenBudget,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | The four buckets pi-mono settled on. Coarse enough that callers
-- do not need to learn each provider's TTL conventions, fine enough
-- to influence behaviour in a meaningful way.
data ThinkingLevel
  = ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The wire string OpenAI's @reasoning_effort@ field expects.
renderThinkingLevel :: ThinkingLevel -> Text
renderThinkingLevel = \case
  ThinkingMinimal -> "minimal"
  ThinkingLow -> "low"
  ThinkingMedium -> "medium"
  ThinkingHigh -> "high"

-- | Recommended token budget for providers that take an explicit
-- count (Anthropic's @thinking.budget_tokens@).
thinkingTokenBudget :: ThinkingLevel -> Natural
thinkingTokenBudget = \case
  ThinkingMinimal -> 1024
  ThinkingLow -> 2048
  ThinkingMedium -> 8192
  ThinkingHigh -> 16384
