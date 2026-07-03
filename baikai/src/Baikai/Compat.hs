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
    AnthropicThinkingStyle (..),
    defaultAnthropicMessagesCompat,
    defaultAnthropicThinkingStyle,

    -- * Auto-detection from baseUrl
    urlHost,
    hostMatchesSuffix,
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

-- | Which request shape an Anthropic-compatible host/model accepts
-- for extended thinking. Budget-era models take
-- @{"type":"enabled","budget_tokens":N}@; adaptive-era models take
-- @{"type":"adaptive"}@ with depth guided by @output_config.effort@.
data AnthropicThinkingStyle
  = AnthropicThinkingBudget
  | AnthropicThinkingAdaptive
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Feature flags for one OpenAI-compatible host.
--
-- Every flag has a default that reproduces OpenAI's own behaviour —
-- @defaultOpenAICompletionsCompat@. Hosts that diverge from OpenAI
-- override the differing fields only.
data OpenAICompletionsCompat = OpenAICompletionsCompat
  { -- | Where the max-output-tokens cap goes in the request body.
    --   Consumed by @Baikai.Provider.OpenAI.Shape.renameMaxTokens@,
    --   which rewrites @max_completion_tokens@ to @max_tokens@
    --   for hosts that require the legacy key.
    maxTokensField :: !MaxTokensField,
    -- | Whether the host accepts @strict: true@ on function tool
    --   definitions. Consumed by
    --   @Baikai.Provider.OpenAI.Api.mkOpenAIResponseFormat@ and
    --   @Baikai.Provider.OpenAI.Shape.dropUnsupportedStrict@ to
    --   omit JSON-schema @strict@ on hosts that reject it.
    supportsStrictMode :: !Bool,
    -- | Whether the host smuggles thinking into the assistant text as
    --   @\<think\>...\</think\>@ or
    --   @\<thinking\>...\</thinking\>@ markers. Field-based reasoning
    --   extraction (for @reasoning_content@ / @reasoning@ deltas) is
    --   unconditional; this flag enables the incremental tag scanner
    --   in @Baikai.Provider.OpenAI.Api.translateTextLikeDelta@ for
    --   hosts that do not split reasoning into a separate field.
    requiresThinkingAsText :: !Bool,
    -- | The wire shape the host accepts for reasoning-effort
    --   preferences. Consumed by
    --   @Baikai.Provider.OpenAI.Api.applyThinkingFormat@ for the
    --   OpenAI-native field and by
    --   @Baikai.Provider.OpenAI.Shape.injectThinkingShape@ for
    --   OpenAI-compatible host-specific JSON keys.
    thinkingFormat :: !ThinkingFormat,
    -- | Whether the host accepts Anthropic-style @cache_control@
    --   markers (some OpenRouter routes pass them through to an
    --   Anthropic backend). Consumed by
    --   @Baikai.Provider.OpenAI.Shape.injectCacheControl@.
    cacheControlFormat :: !(Maybe CacheControlFormat),
    -- | Whether the host emits a final @usage@ chunk in streaming
    --   responses. Consumed by
    --   @Baikai.Provider.OpenAI.Shape.streamRequestBody@ to include
    --   or omit @stream_options.include_usage@.
    supportsUsageInStreaming :: !Bool,
    -- | Whether the host honours long (1h) cache TTLs through the
    --   Anthropic-style cache_control marker. Consumed by
    --   @Baikai.Provider.OpenAI.Shape.injectCacheControl@ when
    --   'cacheControlFormat' is 'Just CacheControlFormatAnthropic'.
    supportsLongCacheRetention :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | OpenAI's own host: every flag at the OpenAI default.
defaultOpenAICompletionsCompat :: OpenAICompletionsCompat
defaultOpenAICompletionsCompat =
  OpenAICompletionsCompat
    { maxTokensField = MaxCompletionTokensField,
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
    --   Consumed by @Baikai.Provider.Claude.Api.computeCacheControl@
    --   for top-level cache markers and by
    --   @Baikai.Provider.Claude.Shape.injectToolCacheControl@ for
    --   tool cache markers.
    supportsLongCacheRetention :: !Bool,
    -- | Whether tool definitions accept @cache_control@ markers.
    --   Consumed by
    --   @Baikai.Provider.Claude.Shape.injectToolCacheControl@.
    --   Anthropic's own host does; some compatible hosts do not.
    supportsCacheControlOnTools :: !Bool,
    -- | Whether to add session-affinity headers on every request
    --   (Fireworks-style routing). Consumed by
    --   @Baikai.Provider.Claude.Transport.requestHeaders@.
    sendSessionAffinityHeaders :: !Bool,
    -- | Which extended-thinking request shape to send for the
    --   selected model generation. Consumed by
    --   @Baikai.Provider.Claude.Api.computeThinking@.
    thinkingStyle :: !AnthropicThinkingStyle
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Anthropic's own host: every flag at its default.
defaultAnthropicMessagesCompat :: AnthropicMessagesCompat
defaultAnthropicMessagesCompat =
  AnthropicMessagesCompat
    { supportsLongCacheRetention = True,
      supportsCacheControlOnTools = True,
      sendSessionAffinityHeaders = False,
      thinkingStyle = AnthropicThinkingBudget
    }

-- | The thinking style a first-party Anthropic model id defaults to
-- when the model carries no explicit compat record. Unknown ids
-- default to the budget style used by earlier model generations.
defaultAnthropicThinkingStyle :: Text -> AnthropicThinkingStyle
defaultAnthropicThinkingStyle modelId
  | adaptive "claude-opus-4-6" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-7" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-8" = AnthropicThinkingAdaptive
  | adaptive "claude-fable-5" = AnthropicThinkingAdaptive
  | otherwise = AnthropicThinkingBudget
  where
    adaptive prefix = prefix `Text.isPrefixOf` modelId

-- | Pick a sensible compat record for an unknown OpenAI-compatible
-- host based on its @baseUrl@. Falls back to
-- 'defaultOpenAICompletionsCompat' for hosts the table does not
-- recognise.
autoDetectOpenAICompletions :: Text -> OpenAICompletionsCompat
autoDetectOpenAICompletions url
  | matches "api.openai.com" = defaultOpenAICompletionsCompat
  | matches "api.deepseek.com" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatDeepseek,
          requiresThinkingAsText = True,
          maxTokensField = MaxTokensField,
          supportsStrictMode = False
        }
  | matches "openrouter.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatOpenRouter,
          supportsStrictMode = False,
          cacheControlFormat = Just CacheControlFormatAnthropic
        }
  | matches "together.xyz" || matches "together.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatTogether,
          supportsStrictMode = False
        }
  | matches "z.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatZai,
          supportsStrictMode = False
        }
  | matches "dashscope.aliyuncs.com"
      || matches "dashscope-intl.aliyuncs.com"
      || matches "qwen.ai" =
      defaultOpenAICompletionsCompat
        { thinkingFormat = ThinkingFormatQwen,
          supportsStrictMode = False
        }
  | otherwise = defaultOpenAICompletionsCompat
  where
    host = urlHost url
    matches suffix = maybe False (`hostMatchesSuffix` suffix) host

-- | Pick a sensible compat record for an unknown
-- Anthropic-compatible host based on its @baseUrl@. Falls back to
-- 'defaultAnthropicMessagesCompat' for hosts the table does not
-- recognise.
autoDetectAnthropicMessages :: Text -> AnthropicMessagesCompat
autoDetectAnthropicMessages url
  | matches "api.anthropic.com" = defaultAnthropicMessagesCompat
  | matches "fireworks.ai" =
      defaultAnthropicMessagesCompat
        { supportsCacheControlOnTools = False,
          sendSessionAffinityHeaders = True,
          supportsLongCacheRetention = False
        }
  | otherwise = defaultAnthropicMessagesCompat
  where
    host = urlHost url
    matches suffix = maybe False (`hostMatchesSuffix` suffix) host

-- | Extract a hostname from a URL-ish value. This is intentionally
-- small and total rather than a validating URI parser: it drops an
-- optional scheme, optional userinfo, then stops at '/', ':', '?', or
-- '#'. Empty results return 'Nothing'.
urlHost :: Text -> Maybe Text
urlHost raw =
  let noScheme = case Text.breakOn "://" raw of
        (_, rest) | not (Text.null rest) -> Text.drop 3 rest
        _ -> raw
      noUser = last (Text.splitOn "@" noScheme)
      host = Text.toLower (Text.strip (Text.takeWhile hostChar noUser))
   in if Text.null host then Nothing else Just host
  where
    hostChar c = c /= '/' && c /= ':' && c /= '?' && c /= '#'

-- | Match a hostname against a suffix at a label boundary.
hostMatchesSuffix :: Text -> Text -> Bool
hostMatchesSuffix host suffix =
  let h = Text.toLower (Text.strip host)
      s = Text.toLower (Text.strip suffix)
   in not (Text.null h)
        && not (Text.null s)
        && (h == s || ("." <> s) `Text.isSuffixOf` h)
