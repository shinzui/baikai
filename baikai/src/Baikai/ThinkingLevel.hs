{-# LANGUAGE LambdaCase #-}

-- | Provider-agnostic reasoning-effort preference.
--
-- Each provider maps the value to its own primitive. The canonical
-- rendering spans @none@ through @max@, while provider boundaries
-- may preserve, translate, or clamp values according to their APIs.
-- 'thinkingTokenBudget' provides the recommended budget for
-- token-based providers.
module Baikai.ThinkingLevel
  ( ThinkingLevel (..),
    renderThinkingLevel,
    parseThinkingLevel,
    thinkingTokenBudget,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | Provider-neutral reasoning-effort buckets, ordered from least to
-- most effort. Coarse enough that callers do not need to learn each
-- provider's vocabulary, fine enough to influence behaviour in a
-- meaningful way.
data ThinkingLevel
  = -- | Ask for no reasoning at all. This is not the same as leaving
    -- 'Baikai.Options.thinking' at 'Nothing': that sends nothing and
    -- leaves the model's own default in force, which on an adaptive
    -- Anthropic generation such as Claude Haiku 5.5 is to think. This
    -- level asks for thinking to be turned off: Anthropic Messages
    -- sends @thinking: {"type": "disabled"}@ to a model whose catalog
    -- record says it accepts that ('Baikai.Compat.supportsThinkingDisabled')
    -- and otherwise clamps to the lowest effort the model has; native
    -- OpenAI sends the effort word @none@.
    ThinkingNone
  | ThinkingMinimal
  | ThinkingLow
  | ThinkingMedium
  | ThinkingHigh
  | ThinkingXHigh
  | ThinkingMax
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Render the canonical Baikai name for a reasoning-effort level.
renderThinkingLevel :: ThinkingLevel -> Text
renderThinkingLevel = \case
  ThinkingNone -> "none"
  ThinkingMinimal -> "minimal"
  ThinkingLow -> "low"
  ThinkingMedium -> "medium"
  ThinkingHigh -> "high"
  ThinkingXHigh -> "xhigh"
  ThinkingMax -> "max"

-- | The inverse of 'renderThinkingLevel': parse a canonical level name.
--
-- Beside its renderer so the two cannot drift, which three hand-copied
-- tables — in 'Baikai.Evidence', @Baikai.Agent.Config@ and
-- @Baikai.Agent.Cli@ — did the first time a level was added.
parseThinkingLevel :: Text -> Maybe ThinkingLevel
parseThinkingLevel = \case
  "none" -> Just ThinkingNone
  "minimal" -> Just ThinkingMinimal
  "low" -> Just ThinkingLow
  "medium" -> Just ThinkingMedium
  "high" -> Just ThinkingHigh
  "xhigh" -> Just ThinkingXHigh
  "max" -> Just ThinkingMax
  _ -> Nothing

-- | Recommended token budget for providers that take an explicit
-- count (Anthropic's @thinking.budget_tokens@). 'ThinkingNone' asks
-- for no budget, so it is @0@; no provider sends a budget for it.
thinkingTokenBudget :: ThinkingLevel -> Natural
thinkingTokenBudget = \case
  ThinkingNone -> 0
  ThinkingMinimal -> 1024
  ThinkingLow -> 2048
  ThinkingMedium -> 8192
  ThinkingHigh -> 16384
  ThinkingXHigh -> 24576
  ThinkingMax -> 32768
