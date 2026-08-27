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
-- The records export their field selectors but not their data
-- constructors. They are expected to grow as provider quirks are
-- discovered, so callers should start from the @default*@ values and
-- use record updates for the fields they need to override.
--
-- Auto-detection from a 'Baikai.Model.Model' @baseUrl@ provides
-- reasonable defaults so callers rarely need to spell out a full
-- compat record. The host it detects on comes from "Baikai.Url", the
-- only place in baikai that turns a URL into a host name; 'urlHost' and
-- 'hostMatchesSuffix' are re-exported from here so a caller reasoning
-- about auto-detection has them to hand.
module Baikai.Compat
  ( -- * OpenAI Chat Completions compat
    OpenAICompletionsCompat
      ( maxTokensField,
        supportsStrictMode,
        requiresThinkingAsText,
        thinkingFormat,
        cacheControlFormat,
        supportsUsageInStreaming,
        supportsLongCacheRetention
      ),
    defaultOpenAICompletionsCompat,
    MaxTokensField (..),
    ThinkingFormat (..),
    CacheControlFormat (..),

    -- * Anthropic Messages compat
    AnthropicMessagesCompat
      ( supportsLongCacheRetention,
        supportsCacheControlOnTools,
        sendSessionAffinityHeaders,
        thinkingStyle,
        supportsSamplingParameters
      ),
    AnthropicThinkingStyle (..),
    defaultAnthropicMessagesCompat,

    -- * Auto-detection from baseUrl
    urlHost,
    hostMatchesSuffix,
    autoDetectOpenAICompletions,
    autoDetectAnthropicMessages,
  )
where

import Baikai.Url (hostMatchesSuffix, urlHost)
import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
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
    --   | "medium" | "high" | "xhigh" | "max"@.
    --
    --   This shape sends the canonical baikai level verbatim. The other
    --   six route through @Baikai.Provider.OpenAI.Shape.compatibleEffort@,
    --   which clamps @minimal@ to @low@ and both @xhigh@ and @max@ to
    --   @high@ — a lowest-common-denominator vocabulary for hosts that
    --   do not accept the full one. The exclusion is deliberate and
    --   guarded by @nativeHigherEffortTests@ in
    --   @baikai-openai/test/ShapeSpec.hs@: clamping here would silently
    --   weaken every high-effort request against a current OpenAI model.
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
  | -- | Host does not expose reasoning controls, so the option is
    --   dropped from the request. Nothing about the wire says so — the
    --   drop is recorded in the call's evidence as
    --   @thinking_dropped_unsupported_host@ rather than left invisible.
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
    --   selected model generation. Which shape a generation accepts
    --   is a fact of the generated catalog record
    --   ("Baikai.Models.Generated"), not something to be guessed from
    --   the model id. Consumed by
    --   @Baikai.Provider.Claude.Internal.Request.computeThinking@.
    thinkingStyle :: !AnthropicThinkingStyle,
    -- | Whether the model generation accepts the sampling parameters
    --   @temperature@, @top_p@ and @top_k@. Adaptive-era generations
    --   from Opus 4.7 and Sonnet 5 onward reject them with a 400, so
    --   the Anthropic adapter drops them and records
    --   'Baikai.Evidence.SamplingDroppedUnsupportedModel'. Which
    --   generations accept them is a fact of the generated catalog
    --   record, not of this type. Consumed by
    --   @Baikai.Provider.Claude.Internal.Request.planRequest@.
    supportsSamplingParameters :: !Bool
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
      thinkingStyle = AnthropicThinkingBudget,
      supportsSamplingParameters = True
    }

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
