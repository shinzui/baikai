{-# LANGUAGE LambdaCase #-}

-- | Per-API compatibility records — feature flags that capture how a
-- specific host implements an OpenAI- or Anthropic-style endpoint.
-- The shape mirrors pi-mono's @OpenAICompletionsCompat@ and
-- @AnthropicMessagesCompat@ records.
--
-- The driving observation is that two hosts can share an API tag
-- (both DeepSeek and OpenAI implement the Chat Completions wire
-- protocol) yet differ in small details: where to put the max-output
-- token cap, whether @strict: true@ is accepted on tool definitions,
-- which JSON key carries reasoning effort, whether thinking is
-- delivered in-band as @\<thinking\>@ tags, etc. Carrying those flags
-- on a per-'Baikai.Model.Model' record means the same provider
-- handler can serve both hosts without any per-host code branching.
--
-- These record constructors are intentionally public in baikai 0.1.
-- They are the supported escape hatch for hand-rolled models and
-- generated catalog overrides when a host speaks a familiar protocol
-- but rejects or requires a small request-shaping difference. New
-- fields or enum constructors may be added in later minor versions as
-- new provider quirks are discovered; callers that want fewer upgrade
-- edits should start from the @default*@ values and use record updates
-- rather than constructing every field from scratch.
--
-- Auto-detection from a 'Baikai.Model.Model' @baseUrl@ provides
-- reasonable defaults so callers rarely need to spell out a full
-- compat record.
module Baikai.Compat
  ( -- * OpenAI Chat Completions compat
    OpenAICompletionsCompat (..),
    defaultOpenAICompletionsCompat,
    MaxTokensField (..),
    ThinkingFormat (..),
    CacheControlFormat (..),

    -- * Anthropic Messages compat
    AnthropicMessagesCompat (..),
    defaultAnthropicMessagesCompat,

    -- * Auto-detection from baseUrl
    autoDetectOpenAICompletions,
    autoDetectAnthropicMessages,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | Where the OpenAI-compatible host expects the max-output-tokens
-- cap. OpenAI's o-series models require @max_completion_tokens@; many
-- compatible hosts (DeepSeek, some OpenRouter routes) keep the
-- pre-o-series @max_tokens@ name.
data MaxTokensField
  = MaxCompletionTokensField
  | MaxTokensField
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How the OpenAI-compatible host receives reasoning-effort
-- preferences. Each constructor names a wire shape we know about; new
-- shapes land as new constructors.
data ThinkingFormat
  = -- | OpenAI-native: top-level @reasoning_effort: "minimal" | "low"
    --   | "medium" | "high"@.
    ThinkingFormatOpenAI
  | -- | OpenRouter: nested @reasoning: { effort: "..." }@.
    ThinkingFormatOpenRouter
  | -- | DeepSeek: top-level @thinking: { type: "enabled" }@ plus
    --   @reasoning_effort@.
    ThinkingFormatDeepseek
  | -- | Together AI: nested @reasoning: { enabled: true }@ plus
    --   @reasoning_effort@.
    ThinkingFormatTogether
  | -- | Z.ai / Qwen: top-level @enable_thinking: true@.
    ThinkingFormatZai
  | -- | Qwen chat-template: top-level @enable_thinking: true@.
    ThinkingFormatQwen
  | -- | Host does not expose reasoning controls; the option is
    --   silently dropped.
    ThinkingFormatNone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The wire shape an OpenAI-compatible host accepts for prompt-cache
-- markers. Only Anthropic's @cache_control@ markers are known; the
-- field is 'Nothing' on hosts that do not advertise prompt caching.
data CacheControlFormat = CacheControlFormatAnthropic
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Feature flags for one OpenAI-compatible host.
--
-- Every flag has a default that reproduces OpenAI's own behaviour —
-- @defaultOpenAICompletionsCompat@. Hosts that diverge from OpenAI
-- override the differing fields only.
data OpenAICompletionsCompat = OpenAICompletionsCompat
  { -- | Where the max-output-tokens cap goes in the request body.
    maxTokensField :: !MaxTokensField,
    -- | Whether the host accepts the @developer@ message role
    --   (OpenAI's o-series) or only @system@.
    supportsDeveloperRole :: !Bool,
    -- | Whether the host accepts @strict: true@ on function tool
    --   definitions. Set 'False' to drop the field on hosts that
    --   reject it.
    supportsStrictMode :: !Bool,
    -- | Whether the host smuggles thinking into the assistant text as
    --   @\<thinking\>...\</thinking\>@ markers. When 'True', the
    --   provider's stream transformer extracts those markers into
    --   typed thinking deltas on the way out. (The transformer itself
    --   is wired in by EP-3; EP-5 only flips the switch.)
    requiresThinkingAsText :: !Bool,
    -- | The wire shape the host accepts for reasoning-effort
    --   preferences.
    thinkingFormat :: !ThinkingFormat,
    -- | Whether the host accepts Anthropic-style @cache_control@
    --   markers (some OpenRouter routes pass them through to an
    --   Anthropic backend).
    cacheControlFormat :: !(Maybe CacheControlFormat),
    -- | Whether the host emits a final @usage@ chunk in streaming
    --   responses. OpenAI does; older OpenAI-compatible servers may
    --   not. Currently advisory.
    supportsUsageInStreaming :: !Bool,
    -- | Whether the host honours long (1h) cache TTLs through the
    --   Anthropic-style cache_control marker. Currently only relevant
    --   when 'cacheControlFormat' is 'Just CacheControlFormatAnthropic'.
    supportsLongCacheRetention :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | OpenAI's own host: every flag at the OpenAI default.
defaultOpenAICompletionsCompat :: OpenAICompletionsCompat
defaultOpenAICompletionsCompat =
  OpenAICompletionsCompat
    { maxTokensField = MaxCompletionTokensField,
      supportsDeveloperRole = True,
      supportsStrictMode = True,
      requiresThinkingAsText = False,
      thinkingFormat = ThinkingFormatOpenAI,
      cacheControlFormat = Nothing,
      supportsUsageInStreaming = True,
      supportsLongCacheRetention = True
    }

-- | Feature flags for one Anthropic Messages-compatible host.
data AnthropicMessagesCompat = AnthropicMessagesCompat
  { -- | Whether the host honours Anthropic's
    --   @cache_control.ttl: "1h"@ long-retention marker. When 'False',
    --   long-retention preferences silently downgrade to ephemeral.
    supportsLongCacheRetention :: !Bool,
    -- | Whether tool definitions accept @cache_control@ markers.
    --   Anthropic's own host does; some compatible hosts do not.
    supportsCacheControlOnTools :: !Bool,
    -- | Whether the host supports per-tool eager input streaming
    --   (Anthropic's @fine-grained-tool-streaming@ beta). Currently
    --   advisory; the SDK does not expose the field directly.
    supportsEagerToolInputStreaming :: !Bool,
    -- | Whether to add session-affinity headers on every request
    --   (Fireworks-style routing).
    sendSessionAffinityHeaders :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Anthropic's own host: every flag at its default.
defaultAnthropicMessagesCompat :: AnthropicMessagesCompat
defaultAnthropicMessagesCompat =
  AnthropicMessagesCompat
    { supportsLongCacheRetention = True,
      supportsCacheControlOnTools = True,
      supportsEagerToolInputStreaming = True,
      sendSessionAffinityHeaders = False
    }

-- | Pick a sensible compat record for an unknown OpenAI-compatible
-- host based on its @baseUrl@. Falls back to
-- 'defaultOpenAICompletionsCompat' for hosts the table does not
-- recognise.
autoDetectOpenAICompletions :: Text -> OpenAICompletionsCompat
autoDetectOpenAICompletions url
  | hasInfix "api.openai.com" = defaultOpenAICompletionsCompat
  | hasInfix "api.deepseek.com" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatDeepseek,
          requiresThinkingAsText = True,
          maxTokensField = MaxTokensField,
          supportsStrictMode = False,
          supportsDeveloperRole = False
        }
  | hasInfix "openrouter.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatOpenRouter,
          supportsStrictMode = False,
          supportsDeveloperRole = False,
          cacheControlFormat = Just CacheControlFormatAnthropic
        }
  | hasInfix "together.xyz" || hasInfix "api.together.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatTogether,
          supportsStrictMode = False,
          supportsDeveloperRole = False
        }
  | hasInfix "z.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatZai,
          supportsStrictMode = False
        }
  | hasInfix "dashscope" || hasInfix "qwen" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatQwen,
          supportsStrictMode = False
        }
  | otherwise = defaultOpenAICompletionsCompat
  where
    hasInfix :: Text -> Bool
    hasInfix needle = needle `Text.isInfixOf` url

-- | Pick a sensible compat record for an unknown
-- Anthropic-compatible host based on its @baseUrl@. Falls back to
-- 'defaultAnthropicMessagesCompat' for hosts the table does not
-- recognise.
autoDetectAnthropicMessages :: Text -> AnthropicMessagesCompat
autoDetectAnthropicMessages url
  | hasInfix "api.anthropic.com" = defaultAnthropicMessagesCompat
  | hasInfix "fireworks.ai" =
      defaultAnthropicMessagesCompat
        { supportsCacheControlOnTools = False,
          sendSessionAffinityHeaders = True,
          supportsLongCacheRetention = False
        }
  | otherwise = defaultAnthropicMessagesCompat
  where
    hasInfix :: Text -> Bool
    hasInfix needle = needle `Text.isInfixOf` url
