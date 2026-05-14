---
id: 11
slug: compat-shims-cache-retention-and-multi-host-providers
title: "Compat shims, cache retention, and multi-host providers"
kind: exec-plan
created_at: 2026-05-14T15:09:30Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Compat shims, cache retention, and multi-host providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, baikai supports multiple hosts behind the same API tag without
per-host code duplication. The `Model.compat` field — initially populated by EP-2
as `CompatNone` — gains two real constructors carrying per-API feature flags:
`CompatOpenAICompletions OpenAICompletionsCompat` and `CompatAnthropicMessages
AnthropicMessagesCompat`. Each provider implementation reads the matching compat
record when building the upstream request and adjusts behaviour: which token-cap
field to use, whether the `developer` role is supported, whether tool definitions
accept `strict: true`, whether reasoning content is smuggled as `<thinking>` tags,
how prompt cache retention is encoded, and so on.

Two user-visible cross-cutting options are added: `Options.cacheRetention ::
Maybe CacheRetention` (a provider-agnostic preference for short / long / none
prompt cache TTLs) and `Options.thinking :: Maybe ThinkingLevel` (a provider-
agnostic preference for reasoning effort: minimal, low, medium, high). Each
provider maps these to its own primitives — Anthropic's `cache_control.ttl: "1h"`
vs. ephemeral, OpenAI's `reasoning_effort: "medium"`, DeepSeek's
`thinking: { type: "enabled" }`, etc.

The user-visible payoff is a multi-host smoke test in `baikai-smoke` that runs
the same simple prompt against the **same provider implementation**
(`Baikai.Provider.OpenAI.Api`) but two different `Model` records: the canonical
OpenAI host and a second OpenAI-compatible host (DeepSeek or OpenRouter — the
plan picks whichever the test environment has a key for). Both succeed with
non-empty `AssistantText` content.

A consumer can write, after this plan:

```haskell
let openaiModel = _Model
      { modelId = "gpt-4o-mini"
      , api = OpenAIChatCompletions
      , baseUrl = "https://api.openai.com"
      , compat = CompatOpenAICompletions defaultOpenAICompletionsCompat
      , ...
      }
    deepseekModel = openaiModel
      { modelId = "deepseek-chat"
      , baseUrl = "https://api.deepseek.com"
      , compat = CompatOpenAICompletions (defaultOpenAICompletionsCompat
          { thinkingFormat = ThinkingFormatDeepseek
          , requiresThinkingAsText = True
          , maxTokensField = MaxTokensField
          })
      , ...
      }
    opts = _Options { cacheRetention = Just CacheRetentionLong, thinking = Just ThinkingMedium }

resp1 <- completeRequest openaiModel ctx opts
resp2 <- completeRequest deepseekModel ctx opts
```

Both calls go through the same `Baikai.Provider.OpenAI.Api` handler; the only
difference is the compat record.


## Progress

- [x] Milestone 1: introduce the compat record types — `OpenAICompletionsCompat`,
      `AnthropicMessagesCompat` — and extend the `Compat` sum from EP-2 with the
      two new constructors. Default values
      `defaultOpenAICompletionsCompat`, `defaultAnthropicMessagesCompat` are
      exposed. Auto-detection from `Model.baseUrl` is implemented via a small
      lookup table. **(2026-05-14)**
- [x] Milestone 2: introduce `Baikai.CacheRetention` (the
      `CacheRetentionNone | CacheRetentionShort | CacheRetentionLong` enum) and
      `Baikai.ThinkingLevel` (the `ThinkingMinimal | ThinkingLow | ThinkingMedium
      | ThinkingHigh` enum). Add `Baikai.Options.cacheRetention :: Maybe
      CacheRetention` and `Baikai.Options.thinking :: Maybe ThinkingLevel`.
      EP-3 had not actually added an `Options.cacheRetention` placeholder
      (only a comment to that effect), so this milestone introduces the
      field outright. **(2026-05-14)**
- [x] Milestone 3: wire compat record fields into
      `Baikai.Provider.OpenAI.Api`. Implemented:
      `supportsStrictMode` (gates the `strict` field on tools),
      `thinkingFormat = ThinkingFormatOpenAI` (sets the SDK's
      `reasoning_effort` field). Deferred (see Decision Log):
      `maxTokensField`, `supportsDeveloperRole`,
      `requiresThinkingAsText`, `cacheControlFormat`, and the
      non-OpenAI `thinkingFormat` constructors — each requires SDK
      surgery beyond the EP-5 scope. **(2026-05-14)**
- [ ] Milestone 4: wire compat record fields into
      `Baikai.Provider.Claude.Api`. Honour `supportsLongCacheRetention`
      (whether `cache_control.ttl: "1h"` is sent),
      `supportsEagerToolInputStreaming` (whether per-tool
      `eager_input_streaming` is sent),
      `supportsCacheControlOnTools` (whether `cache_control` markers are
      applied to tool definitions).
- [ ] Milestone 5: add a multi-host smoke test
      `baikai-smoke/test/MultiHostSmoke.hs`. The test registers
      `Baikai.Provider.OpenAI.Api`, constructs two `Model` records for two
      different OpenAI-compatible hosts, sends the same `Context` to each, and
      asserts both return non-empty `AssistantText`. The second host is
      selected from `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, or
      `TOGETHER_API_KEY` — whichever is set; the test is skipped if none.


## Surprises & Discoveries

- M2: EP-3 did not actually land the `Options.cacheRetention`
  placeholder field — only a comment in `Baikai.Options` documenting
  the eventual addition. The field is therefore introduced fresh in
  M2 rather than swapped from a placeholder. No call sites had to be
  updated because the field defaults to `Nothing` and `_Options`
  populates the new defaults.
- M1: The plan's `defaultOpenAICompletionsCompat` is OpenAI-shaped
  (e.g. `supportsDeveloperRole = True`). The DeepSeek auto-detect
  override flips that off in addition to the plan-listed flags;
  `developer` role is not accepted by DeepSeek either.
- M3: The Mercury `openai` Haskell SDK
  (`OpenAI.V1.Chat.Completions.CreateChatCompletion`) only exposes
  `max_completion_tokens`, not `max_tokens`. It also has no
  free-form `extra :: Maybe Aeson.Value` escape hatch. The
  non-OpenAI `thinkingFormat` constructors all require additional
  top-level JSON keys (`thinking`, `reasoning`, `enable_thinking`)
  that the SDK has no field for. This forces M3 to ship the
  smaller subset documented in the Decision Log; M5's smoke test
  uses OpenRouter (which accepts `max_completion_tokens`) so that
  the multi-host coverage can land without the SDK patch. EP-6 or
  a follow-up EP can revisit when generated catalog entries start
  needing the missing fields.


## Decision Log

- Decision: Compat fields live on `Model.compat` (a sum of per-API records), not
  on `Options` or a separate `Host` type.
  Rationale: Compat varies per (Api, host) pair — DeepSeek's
  `openai-chat-completions` differs from OpenAI's. Tying compat to `Model` means
  every API call carries the right compat data through the registry without
  callers having to thread it manually. The masterplan's Integration Points
  section endorses this shape.
  Date: 2026-05-14

- Decision: Compat records are open data records (extensible by adding new
  fields), not closed sums.
  Rationale: Pi-mono adds compat fields ad-hoc as new hosts surface
  incompatibilities; baikai will face the same churn. A record with sensible
  defaults lets a new field land as a one-line cabal-package change without
  forcing every existing `Model` record to be updated.
  Date: 2026-05-14

- Decision: Auto-detection of compat from `baseUrl` is implemented but
  overridable.
  Rationale: pi-mono auto-detects compat from URL patterns
  (`api.openai.com → defaultOpenAICompletionsCompat`, `api.deepseek.com →
  defaultOpenAICompletionsCompat { thinkingFormat = "deepseek", ... }`). This
  saves a power user writing a long compat record by hand. The user always
  wins: an explicit `Model.compat = CompatOpenAICompletions custom` is used
  verbatim. The auto-detection table lives in
  `baikai/src/Baikai/Compat.hs` as a `Map Text` keyed by URL prefix.
  Date: 2026-05-14

- Decision: `CacheRetention` and `ThinkingLevel` are provider-agnostic
  user-facing options that providers map to their own primitives. The mapping
  table is opinionated.
  Rationale: pi-mono's `StreamOptions.cacheRetention :: "none" | "short" |
  "long"` is the right granularity — fine enough to influence behaviour, coarse
  enough that a caller does not need to learn each provider's TTL conventions.
  Likewise its `reasoning :: ThinkingLevel` with four buckets. Each provider's
  mapping is documented in this plan and in the compat record's haddock; if a
  caller needs finer control they fall back to `Options.metadata` or set
  fields directly on the upstream request via a future `Options.onPayload`
  callback (out of scope).
  Date: 2026-05-14

- Decision: Adding `Custom` constructors to `Compat` is rejected; the
  open-world property comes from baseUrl-based auto-detection plus
  caller-provided override of any compat field.
  Rationale: A third-party adding a brand new API tag is already in
  `Api = Custom !Text` territory; they implement their own handler and pick
  their own compat representation. baikai's compat sum is concerned with
  the two API tags it ships handlers for (`OpenAIChatCompletions` and
  `AnthropicMessages`).
  Date: 2026-05-14

- Decision: M3 wires only the OpenAI-native compat-driven behaviours
  through the upstream `openai` Haskell SDK. Specifically:
  `supportsStrictMode` is honoured by gating the `strict` field on
  tools; `thinking` requests are translated to the SDK's
  `reasoning_effort` field when `thinkingFormat ==
  ThinkingFormatOpenAI`. The other thinking formats
  (DeepSeek/OpenRouter/Together/Z.ai/Qwen), the `maxTokensField`
  override (max_tokens vs max_completion_tokens), the
  `cacheControlFormat` injection of Anthropic-style markers, and the
  `requiresThinkingAsText` stream transformer are intentionally
  no-ops in this revision. The `Options.thinking` request silently
  drops on hosts whose `thinkingFormat` is anything other than
  `ThinkingFormatOpenAI` or `ThinkingFormatNone`.
  Rationale: The Mercury `openai` SDK does not expose a
  `max_tokens` field on `CreateChatCompletion` (only
  `max_completion_tokens`), nor an `extra :: Maybe Aeson.Value`
  escape hatch to inject the host-specific reasoning shapes. Wiring
  those would require either (a) forking/patching the upstream SDK
  or (b) bypassing the SDK's typed Servant call and POSTing the
  body via `http-client` directly. Both are substantial enough to
  warrant their own follow-up plan, and the multi-host smoke test
  in M5 can satisfy the masterplan's "two hosts, one handler"
  acceptance criterion using OpenRouter (which accepts
  `max_completion_tokens`) without any of those workarounds. The
  `requiresThinkingAsText` flag exists on the compat record so the
  follow-up wiring can flip it without further structural change.
  Date: 2026-05-14


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is the fifth in the `Streaming, Content Blocks, and Tool Calls`
initiative defined in `docs/masterplans/2-streaming-content-blocks-and-tool-calls.md`.
It depends hard on:

- EP-2 (`docs/plans/8-api-tag-model-record-and-provider-registry.md`) for the
  `Compat` sum and the `Model.compat` field. EP-2 ships only the placeholder
  `CompatNone` constructor; this plan adds `CompatOpenAICompletions
  OpenAICompletionsCompat` and `CompatAnthropicMessages AnthropicMessagesCompat`.
- EP-3 (`docs/plans/9-streaming-event-protocol-with-streamly.md`) for the
  `Options.cacheRetention` placeholder and the stream transformer
  `stripThinkingTags` (a no-op until this plan wires it on/off via compat).

This plan is soft-dependent on EP-4
(`docs/plans/10-tools-and-context-overhaul.md`) because tool encoding has
compat-relevant fields (`supportsStrictMode`, `supportsCacheControlOnTools`).
If EP-4 has not landed when this plan starts, those fields exist on the
compat record but are not consumed; the plan still ships meaningful
multi-host coverage via the non-tool path.

The pi-mono compat records, copied here for reference (TypeScript), define
the field set we mirror:

```typescript
export interface OpenAICompletionsCompat {
  supportsStore?: boolean;
  supportsDeveloperRole?: boolean;
  supportsReasoningEffort?: boolean;
  supportsUsageInStreaming?: boolean;
  maxTokensField?: "max_completion_tokens" | "max_tokens";
  requiresToolResultName?: boolean;
  requiresAssistantAfterToolResult?: boolean;
  requiresThinkingAsText?: boolean;
  requiresReasoningContentOnAssistantMessages?: boolean;
  thinkingFormat?: "openai" | "openrouter" | "deepseek" | "together" | "zai" | "qwen" | "qwen-chat-template";
  supportsStrictMode?: boolean;
  cacheControlFormat?: "anthropic";
  sendSessionAffinityHeaders?: boolean;
  supportsLongCacheRetention?: boolean;
}

export interface AnthropicMessagesCompat {
  supportsEagerToolInputStreaming?: boolean;
  supportsLongCacheRetention?: boolean;
  sendSessionAffinityHeaders?: boolean;
  supportsCacheControlOnTools?: boolean;
}
```

Not every field is consumed by the providers baikai ships handlers for. The
Haskell mirror trims to fields that are exercised by the smoke tests or
called out by the masterplan's Decision Log. Pi-mono's
`packages/ai/src/providers/openai-completions.ts` and `anthropic.ts` are the
reference implementations for the mappings.

The OpenAI provider's request builder after EP-3 looks roughly like:

```haskell
mapContextToCreateChatCompletion :: Model -> Context -> Options -> Chat.CreateChatCompletion
mapContextToCreateChatCompletion m ctx opts = Chat._CreateChatCompletion
  { Chat.model = OpenAIModels.Model (modelId m)
  , Chat.messages = ...
  , Chat.max_completion_tokens = maxTokens opts          -- hard-coded after EP-2/EP-3
  , Chat.temperature = temperature opts
  , Chat.stream = Just True
  , Chat.stream_options = ...
  }
```

This plan rewrites the field selection to consult `compatFor m :: OpenAICompletionsCompat`:

```haskell
let c = openaiCompletionsCompatFor m
in case maxTokensField c of
     MaxTokensField -> Chat._CreateChatCompletion { Chat.max_tokens = maxTokens opts, ... }
     MaxCompletionTokensField -> Chat._CreateChatCompletion { Chat.max_completion_tokens = maxTokens opts, ... }
```

The Claude provider's request builder after EP-3 looks like:

```haskell
mapContextToCreateMessage :: Model -> Context -> Options -> Messages.CreateMessage
mapContextToCreateMessage m ctx opts = Messages._CreateMessage
  { Messages.model = modelId m
  , Messages.messages = ...
  , Messages.system = ...
  , Messages.tools = ...
  , Messages.max_tokens = ...
  , Messages.cache_control = ...  -- always Nothing today
  }
```

This plan adds `cache_control` markers when `Options.cacheRetention` and the
Anthropic compat record agree the host supports them.


## Plan of Work

### Milestone 1: introduce compat record types

**New file:** `baikai/src/Baikai/Compat.hs`:

```haskell
-- OpenAI Chat Completions compat record (per-host feature flags).
data OpenAICompletionsCompat = OpenAICompletionsCompat
  { maxTokensField :: !MaxTokensField                      -- where to put max-output tokens
  , supportsDeveloperRole :: !Bool                         -- whether to use "developer" vs "system"
  , supportsStrictMode :: !Bool                            -- whether tools accept strict: true
  , requiresThinkingAsText :: !Bool                        -- decode <thinking> tags into ThinkingDelta
  , thinkingFormat :: !ThinkingFormat                      -- where reasoning effort goes in the body
  , cacheControlFormat :: !(Maybe CacheControlFormat)      -- Anthropic-style markers when not Nothing
  , supportsUsageInStreaming :: !Bool
  , supportsLongCacheRetention :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MaxTokensField = MaxTokensField | MaxCompletionTokensField
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ThinkingFormat
  = ThinkingFormatOpenAI       -- top-level reasoning_effort
  | ThinkingFormatOpenRouter   -- nested reasoning: { effort }
  | ThinkingFormatDeepseek     -- thinking: { type } + reasoning_effort
  | ThinkingFormatTogether     -- reasoning: { enabled } + reasoning_effort
  | ThinkingFormatZai          -- top-level enable_thinking: bool
  | ThinkingFormatQwen         -- top-level enable_thinking: bool
  | ThinkingFormatNone         -- host does not expose reasoning controls
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CacheControlFormat = CacheControlFormatAnthropic
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

defaultOpenAICompletionsCompat :: OpenAICompletionsCompat
defaultOpenAICompletionsCompat = OpenAICompletionsCompat
  { maxTokensField = MaxCompletionTokensField
  , supportsDeveloperRole = True
  , supportsStrictMode = True
  , requiresThinkingAsText = False
  , thinkingFormat = ThinkingFormatOpenAI
  , cacheControlFormat = Nothing
  , supportsUsageInStreaming = True
  , supportsLongCacheRetention = True
  }

-- Anthropic Messages compat record.
data AnthropicMessagesCompat = AnthropicMessagesCompat
  { supportsEagerToolInputStreaming :: !Bool
  , supportsLongCacheRetention :: !Bool
  , supportsCacheControlOnTools :: !Bool
  , sendSessionAffinityHeaders :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

defaultAnthropicMessagesCompat :: AnthropicMessagesCompat
defaultAnthropicMessagesCompat = AnthropicMessagesCompat
  { supportsEagerToolInputStreaming = True
  , supportsLongCacheRetention = True
  , supportsCacheControlOnTools = True
  , sendSessionAffinityHeaders = False
  }
```

**Modified file:** `baikai/src/Baikai/Model.hs`. Extend the `Compat` sum:

```haskell
data Compat
  = CompatNone
  | CompatOpenAICompletions !OpenAICompletionsCompat
  | CompatAnthropicMessages !AnthropicMessagesCompat
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Add helpers to project a compat record by API:

```haskell
openaiCompletionsCompatFor :: Model -> OpenAICompletionsCompat
openaiCompletionsCompatFor m = case compat m of
  CompatOpenAICompletions c -> c
  _ -> autoDetectOpenAICompletions (baseUrl m)

anthropicMessagesCompatFor :: Model -> AnthropicMessagesCompat
anthropicMessagesCompatFor m = case compat m of
  CompatAnthropicMessages c -> c
  _ -> autoDetectAnthropicMessages (baseUrl m)

autoDetectOpenAICompletions :: Text -> OpenAICompletionsCompat
autoDetectOpenAICompletions url
  | "api.openai.com" `Text.isInfixOf` url     = defaultOpenAICompletionsCompat
  | "api.deepseek.com" `Text.isInfixOf` url   = defaultOpenAICompletionsCompat
      { thinkingFormat = ThinkingFormatDeepseek
      , requiresThinkingAsText = True
      , maxTokensField = MaxTokensField
      , supportsStrictMode = False
      }
  | "openrouter.ai" `Text.isInfixOf` url      = defaultOpenAICompletionsCompat
      { thinkingFormat = ThinkingFormatOpenRouter
      , supportsStrictMode = False
      }
  | "together.xyz" `Text.isInfixOf` url       = defaultOpenAICompletionsCompat
      { thinkingFormat = ThinkingFormatTogether
      , supportsStrictMode = False
      }
  | otherwise = defaultOpenAICompletionsCompat

autoDetectAnthropicMessages :: Text -> AnthropicMessagesCompat
autoDetectAnthropicMessages url
  | "api.anthropic.com" `Text.isInfixOf` url   = defaultAnthropicMessagesCompat
  | "fireworks.ai" `Text.isInfixOf` url        = defaultAnthropicMessagesCompat
      { supportsCacheControlOnTools = False
      , sendSessionAffinityHeaders = True
      }
  | otherwise = defaultAnthropicMessagesCompat
```

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.Compat` to
`exposed-modules`.

**Acceptance.** `cabal build baikai` is green. `cabal repl baikai`:

```haskell
ghci> :t openaiCompletionsCompatFor _Model
openaiCompletionsCompatFor _Model :: OpenAICompletionsCompat
```

### Milestone 2: introduce `CacheRetention` and `ThinkingLevel`

**New file:** `baikai/src/Baikai/CacheRetention.hs`:

```haskell
data CacheRetention
  = CacheRetentionNone
  | CacheRetentionShort      -- provider-default ephemeral
  | CacheRetentionLong       -- 1h on Anthropic, 24h on OpenAI Responses
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

**New file:** `baikai/src/Baikai/ThinkingLevel.hs`:

```haskell
data ThinkingLevel
  = ThinkingMinimal     -- 1k token budget on budget-based providers
  | ThinkingLow         -- 2k
  | ThinkingMedium      -- 8k
  | ThinkingHigh        -- 16k
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

renderThinkingLevel :: ThinkingLevel -> Text
renderThinkingLevel = \case
  ThinkingMinimal -> "minimal"
  ThinkingLow     -> "low"
  ThinkingMedium  -> "medium"
  ThinkingHigh    -> "high"

-- Budget mapping for providers that take token counts (Anthropic budget mode).
thinkingTokenBudget :: ThinkingLevel -> Natural
thinkingTokenBudget = \case
  ThinkingMinimal -> 1024
  ThinkingLow     -> 2048
  ThinkingMedium  -> 8192
  ThinkingHigh    -> 16384
```

**Modified file:** `baikai/src/Baikai/Options.hs`. Replace the placeholder
`cacheRetention :: Maybe CacheRetention` (from EP-3) with the real type.
Add `thinking :: Maybe ThinkingLevel`:

```haskell
data Options = Options
  { ...
  , cacheRetention :: !(Maybe CacheRetention)
  , sessionId :: !(Maybe Text)
  , thinking :: !(Maybe ThinkingLevel)
  , ...
  }
```

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.CacheRetention`,
`Baikai.ThinkingLevel`.

**Acceptance.** `cabal build all` is green. The OpenAI / Anthropic providers
do not yet consume the options — Milestones 3 and 4 wire them in.

### Milestone 3: wire compat into the OpenAI provider

**Modified file:** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. Update
`mapContextToCreateChatCompletion`:

```haskell
mapContextToCreateChatCompletion :: Model -> Context -> Options -> Chat.CreateChatCompletion
mapContextToCreateChatCompletion m ctx opts =
  let c = openaiCompletionsCompatFor m
      baseReq = ... existing field assignments ...
      withMaxTokens r = case maxTokensField c of
        MaxTokensField -> r { Chat.max_tokens = maxTokens opts, Chat.max_completion_tokens = Nothing }
        MaxCompletionTokensField -> r { Chat.max_completion_tokens = maxTokens opts, Chat.max_tokens = Nothing }
      withThinking r = case thinking opts of
        Nothing -> r
        Just lvl -> insertThinking c lvl r
      withTools r = case Chat.tools r of
        Nothing -> r
        Just ts ->
          if supportsStrictMode c
            then r
            else r { Chat.tools = Just (V.map dropStrict ts) }
      withSessionAffinityHeaders = ... compat.sendSessionAffinityHeaders ...
  in baseReq & withMaxTokens & withThinking & withTools

insertThinking :: OpenAICompletionsCompat -> ThinkingLevel -> Chat.CreateChatCompletion -> Chat.CreateChatCompletion
insertThinking c lvl req = case thinkingFormat c of
  ThinkingFormatOpenAI -> req { Chat.reasoning_effort = Just (renderThinkingLevel lvl) }
  ThinkingFormatOpenRouter -> req
    { Chat.extra = Aeson.object
        [ "reasoning" .= Aeson.object [ "effort" .= renderThinkingLevel lvl ] ]
    }
  ThinkingFormatDeepseek -> req
    { Chat.extra = Aeson.object
        [ "thinking" .= Aeson.object [ "type" .= ("enabled" :: Text) ]
        , "reasoning_effort" .= renderThinkingLevel lvl
        ]
    }
  ThinkingFormatTogether -> req
    { Chat.extra = Aeson.object
        [ "reasoning" .= Aeson.object [ "enabled" .= True ]
        , "reasoning_effort" .= renderThinkingLevel lvl
        ]
    }
  ThinkingFormatZai -> req { Chat.extra = Aeson.object [ "enable_thinking" .= True ] }
  ThinkingFormatQwen -> req { Chat.extra = Aeson.object [ "enable_thinking" .= True ] }
  ThinkingFormatNone -> req
```

The Mercury `openai` SDK's `Chat.CreateChatCompletion` does not expose every
field listed above (e.g. `reasoning_effort`); the plan adds the missing
fields as `extra :: !(Maybe Aeson.Value)` merged at JSON encoding time, or
patches the SDK if the field is consumed by a smoke test. The exact
mechanism is decided during implementation and recorded in the Decision
Log.

The streaming producer's `stripThinkingTags` transformer (from EP-3) is
enabled when `requiresThinkingAsText c == True`:

```haskell
openaiChatStream m ctx opts =
  let c = openaiCompletionsCompatFor m
      raw = ... existing chunk producer ...
      transformed = if requiresThinkingAsText c
                      then stripThinkingTags raw
                      else raw
  in mapChunksToEvents transformed
```

The `cacheRetention` option is honoured when `cacheControlFormat c ==
Just CacheControlFormatAnthropic`: the request builder applies
Anthropic-style `cache_control` markers to the system prompt and the last
user message, as pi-mono does for OpenRouter when it routes to Anthropic.
This is a small addition; the plan implements it as a post-build pass over
`Chat.CreateChatCompletion`.

**Acceptance.** `cabal build all` is green.

### Milestone 4: wire compat into the Anthropic provider

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Update
`mapContextToCreateMessage`:

```haskell
mapContextToCreateMessage :: Model -> Context -> Options -> Messages.CreateMessage
mapContextToCreateMessage m ctx opts =
  let c = anthropicMessagesCompatFor m
      baseReq = ... existing field assignments ...
      withCacheControl = case cacheRetention opts of
        Nothing -> id
        Just CacheRetentionNone -> id
        Just CacheRetentionShort -> applyShortCacheControl c
        Just CacheRetentionLong -> applyLongCacheControl c
      withThinking = case thinking opts of
        Nothing -> id
        Just lvl -> applyThinking m lvl
      withTools = case Messages.tools baseReq of
        Nothing -> id
        Just ts ->
          if supportsCacheControlOnTools c
            then id
            else r -> r { Messages.tools = Just (V.map dropToolCacheControl ts) }
  in baseReq & withCacheControl & withThinking & withTools

applyShortCacheControl :: AnthropicMessagesCompat -> Messages.CreateMessage -> Messages.CreateMessage
applyShortCacheControl _ req = req
  { Messages.cache_control = Just Messages.CacheControl_Ephemeral { Messages.ttl = Nothing } }

applyLongCacheControl :: AnthropicMessagesCompat -> Messages.CreateMessage -> Messages.CreateMessage
applyLongCacheControl c req
  | supportsLongCacheRetention c = req
      { Messages.cache_control = Just Messages.CacheControl_Ephemeral { Messages.ttl = Just "1h" } }
  | otherwise = applyShortCacheControl c req

applyThinking :: Model -> ThinkingLevel -> Messages.CreateMessage -> Messages.CreateMessage
applyThinking m lvl req
  | reasoning m = req
      { Messages.thinking = Just Messages.ThinkingEnabled
          { Messages.budget_tokens = thinkingTokenBudget lvl
          , Messages.display = Messages.ThinkingDisplaySummarized
          }
      , Messages.max_tokens = Messages.max_tokens req + thinkingTokenBudget lvl
      }
  | otherwise = req
```

The `eager_input_streaming` field on tool definitions is enabled when
`supportsEagerToolInputStreaming c == True` (the default). Otherwise the
field is dropped and the `anthropic-beta:
fine-grained-tool-streaming-2025-05-14` header is added to the request
headers (matching pi-mono's logic).

**Acceptance.** `cabal build all` is green. `cabal test baikai-trace-otel` is
green (the OTel test was previously asserting fixed token counts; the
assertions are updated if needed).

### Milestone 5: multi-host smoke test

**New file:** `baikai-smoke/test/MultiHostSmoke.hs`:

```haskell
testMultiHost :: TestTree
testMultiHost = testCase "Multi-host: openai + deepseek share a handler" $ do
  envHas key = isJust <$> lookupEnv (Text.unpack key)
  hasOpenai <- envHas "OPENAI_API_KEY"
  hasDeepseek <- envHas "DEEPSEEK_API_KEY"
  hasOpenRouter <- envHas "OPENROUTER_API_KEY"
  unless (hasOpenai && (hasDeepseek || hasOpenRouter)) $ do
    -- Skip when we don't have both
    pure ()
  OpenAI.register
  let ctx = _Context { messages = V.singleton (user "Say the word 'hello' and nothing else.") }
      opts = _Options { maxTokens = Just 32 }
      openaiModel = _Model
        { modelId = "gpt-4o-mini"
        , api = OpenAIChatCompletions
        , provider = "openai"
        , baseUrl = "https://api.openai.com"
        , cost = ModelCost 0.15 0.6 0.075 0
        , contextWindow = 128_000
        , maxOutputTokens = 16_384
        , compat = CompatOpenAICompletions defaultOpenAICompletionsCompat
        , ...
        }
      secondModel = if hasDeepseek
        then deepseekModel
        else openrouterModel
  resp1 <- completeRequest openaiModel ctx opts
  resp2 <- completeRequest secondModel ctx opts
  let texts = map (\r -> V.toList (content (message r))) [resp1, resp2]
  forM_ texts $ \blocks ->
    assertBool "non-empty AssistantText" (any isAssistantText blocks)
```

`deepseekModel` and `openrouterModel` are constructed inline with the right
`compat = CompatOpenAICompletions (...)` and `baseUrl`. The test uses
`Options.apiKey` to override the key per call so the same env is not
required for both hosts.

**Modified file:** `baikai-smoke/baikai-smoke.cabal`. Add the new module.

**Acceptance.** With `OPENAI_API_KEY` and `DEEPSEEK_API_KEY` (or
`OPENROUTER_API_KEY`) set,
`cabal test baikai-smoke --test-options=-p '/Multi-host/'` passes. Both
hosts return non-empty text, proving the single OpenAI handler serves both
hosts through compat-driven request shaping.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/baikai` in the Nix devshell:

```bash
nix develop

# Milestone 1: compat records
cabal build baikai

# Milestone 2: cache retention + thinking level
cabal build baikai

# Milestone 3: openai compat
cabal build baikai-openai

# Milestone 4: anthropic compat
cabal build baikai-claude

# Milestone 5: smoke
OPENAI_API_KEY=... DEEPSEEK_API_KEY=... cabal test baikai-smoke
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green.
- `cabal test all` is green with no API keys set.
- With `OPENAI_API_KEY` plus one of `DEEPSEEK_API_KEY` / `OPENROUTER_API_KEY`
  set, the multi-host smoke test passes: both hosts route through
  `Baikai.Provider.OpenAI.Api` and each returns non-empty
  `AssistantText` content.
- `cabal repl baikai` shows the new types:

  ```haskell
  ghci> :i Compat
  data Compat = CompatNone | CompatOpenAICompletions OpenAICompletionsCompat | CompatAnthropicMessages AnthropicMessagesCompat
  ghci> :t defaultOpenAICompletionsCompat
  defaultOpenAICompletionsCompat :: OpenAICompletionsCompat
  ghci> :t CacheRetentionLong
  CacheRetentionLong :: CacheRetention
  ghci> :t ThinkingMedium
  ThinkingMedium :: ThinkingLevel
  ```


## Idempotence and Recovery

The compat records are pure data; their introduction has no runtime side
effects. Auto-detection from `baseUrl` is a pure function and produces the
same result every call.

If a multi-host smoke test reveals an unexpected incompatibility (e.g. a
host rejects `cache_control` markers it claimed to support), record the
discovery in `Surprises & Discoveries` and adjust the auto-detection table
or the compat record's defaults.

Rollback is by reverting commits. The compat fields default to
`defaultOpenAICompletionsCompat` / `defaultAnthropicMessagesCompat` shapes
that match OpenAI / Anthropic exactly, so a `Model` with `compat =
CompatOpenAICompletions defaultOpenAICompletionsCompat` is indistinguishable
from `compat = CompatNone` post-rollback (the provider would auto-detect
the same defaults).


## Interfaces and Dependencies

**External dependencies.** No new Hackage / vendored dependencies. The
optional `Chat.extra` field on the OpenAI SDK side may require a small
upstream patch if the field is not already present; the plan records the
patch in Surprises if it ends up being needed.

**Module surface at end of plan.**

From `Baikai`:

```haskell
data Compat = CompatNone | CompatOpenAICompletions !OpenAICompletionsCompat | CompatAnthropicMessages !AnthropicMessagesCompat
data OpenAICompletionsCompat = OpenAICompletionsCompat { ... }
data AnthropicMessagesCompat = AnthropicMessagesCompat { ... }
data MaxTokensField = MaxTokensField | MaxCompletionTokensField
data ThinkingFormat = ThinkingFormatOpenAI | ThinkingFormatOpenRouter | ThinkingFormatDeepseek | ThinkingFormatTogether | ThinkingFormatZai | ThinkingFormatQwen | ThinkingFormatNone
data CacheControlFormat = CacheControlFormatAnthropic

defaultOpenAICompletionsCompat :: OpenAICompletionsCompat
defaultAnthropicMessagesCompat :: AnthropicMessagesCompat
openaiCompletionsCompatFor :: Model -> OpenAICompletionsCompat
anthropicMessagesCompatFor :: Model -> AnthropicMessagesCompat

data CacheRetention = CacheRetentionNone | CacheRetentionShort | CacheRetentionLong
data ThinkingLevel = ThinkingMinimal | ThinkingLow | ThinkingMedium | ThinkingHigh
thinkingTokenBudget :: ThinkingLevel -> Natural

data Options = Options { ..., cacheRetention :: !(Maybe CacheRetention), thinking :: !(Maybe ThinkingLevel), ... }
```

EP-6 (`docs/plans/12-generated-model-catalog.md`) generates `Model` records
with the appropriate compat constructor populated per host. The generator's
input JSON includes per-host compat overrides where the auto-detection
defaults are wrong.
