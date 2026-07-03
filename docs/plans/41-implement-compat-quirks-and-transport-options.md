---
id: 41
slug: implement-compat-quirks-and-transport-options
title: "Implement compat quirks and transport options"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Implement compat quirks and transport options

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

baikai advertises a "compat quirk" system: per-host feature flags (in
`baikai/src/Baikai/Compat.hs`) that are supposed to reshape requests so one provider
handler can serve OpenAI, DeepSeek, OpenRouter, Together, Z.ai/Qwen (all speaking the
OpenAI Chat Completions protocol) and Anthropic plus Fireworks (speaking the Anthropic
Messages protocol). The 2026-07 review (`docs/reviews/2026-07-01-correctness-and-api-review.md`,
Theme 4) verified that most of these flags are decorative — defined, generated,
auto-detected, asserted in tests, and consumed by no provider code. The same review
found that per-call transport options are silently ignored (`Options.timeoutMs`,
`Options.headers`, `Model.headers` — Theme 5), that the Claude provider mangles tool
JSON Schemas and 400s on `ToolChoiceNone` after tool use (Themes 5 and 9), that the
OpenAI provider leaks the `OPENAI_API_KEY` secret to third-party hosts, churns a fresh
TLS connection manager on every request, and corrupts parallel tool calls from hosts
that omit the `index` field (Theme 10).

After this plan, every remaining flag in `Baikai.Compat` visibly changes the bytes that
go over the wire (or has been deleted end-to-end), a request against DeepSeek carries
`max_tokens` instead of the rejected `max_completion_tokens`, a stalled host terminates
the stream with an in-band classified error after `Options.timeoutMs` milliseconds
instead of hanging forever, caller headers reach the wire, a tool schema with `$defs`
or `additionalProperties` arrives at Anthropic byte-for-byte intact, "now answer
without tools" works at the end of a tool loop, and a model pointed at
`api.deepseek.com` never silently sends your OpenAI secret there. You can see it
working by running the request-shaping unit tests (they assert the emitted JSON), the
stalling-socket timeout test, and — with real keys — the new smoke cases in
`baikai-smoke`.

This is EP-8 (wave 3) of the master plan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`. Two
integration constraints from that master plan bind this document:

- `docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md` (EP-7) owns
  the thinking/`max_tokens` region of the Claude `mapRequest` (the `baseTokens` /
  `thinkingField` / `maxTokensField_` computation at
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs:559-567` and `computeThinking`) and
  wires the `requiresThinkingAsText` compat flag. This plan must not touch those
  regions and must not delete `requiresThinkingAsText`. Every OTHER compat flag is this
  plan's responsibility.
- `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (EP-6)
  defines what a failure raises: an in-band terminal — `stopReason = ErrorReason` with
  `errorInfo = Just be` on the blocking path, a single terminal `EventError` carrying
  the same `BaikaiError` on the streaming path. The timeout this plan wires reports
  through that contract; it never throws to the caller.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [x] M1: hostname-suffix matching in `Baikai.Compat` (`urlHost`, `hostMatchesSuffix`) replaces bare substring detection; property/table tests added. (2026-07-03)
- [x] M1: `supportsDeveloperRole` and `supportsEagerToolInputStreaming` deleted end-to-end (Compat.hs, GenModels.hs, regenerated catalog, tests). (2026-07-03)
- [x] M1: per-host API-key env table `defaultApiKeyEnvForBaseUrl` added to `Baikai.Auth` with tests. (2026-07-03)
- [x] M2: `shapeRequestBody` post-processor added to baikai-openai (maxTokensField rename, non-OpenAI thinkingFormat shapes, cacheControlFormat markers honoring supportsLongCacheRetention). (2026-07-03)
- [x] M2: `supportsStrictMode` gates `response_format` strict; `supportsUsageInStreaming` gates `stream_options`; `max_completion_tokens` omitted when resolved cap is 0. (2026-07-03)
- [x] M2: tool-call delta keying survives missing `index` (id-based and sequential fallback). (2026-07-03)
- [ ] M3: local SSE raw-value send path (`Baikai.Provider.Claude.Sse`) in baikai-claude
- [ ] M3: verbatim tool `input_schema` patch (including no-`properties` schemas) with round-trip tests
- [ ] M3: `ToolChoiceNone` keeps `tools` and sends `tool_choice {"type":"none"}`
- [ ] M3: `supportsCacheControlOnTools` attaches cache marker to the last tool definition
- [ ] M4: process-global per-baseUrl `Manager` caches in both providers
- [ ] M4: `Options.headers` + `Model.headers` + `sendSessionAffinityHeaders` reach the wire in both providers
- [ ] M4: `Options.timeoutMs` bounds both providers' calls; stalling-socket tests pass
- [ ] M4: `resolveKey` uses the per-host env table; no silent cross-host `OPENAI_API_KEY` fallback
- [ ] M5: Compat.hs haddocks state where each surviving flag takes effect
- [ ] M5: baikai-smoke gains skipped-without-keys cases (DeepSeek max_tokens, verbatim tool schema, tool_choice none, custom headers)
- [ ] M5: full `cabal build all --enable-tests` and `cabal test baikai baikai-claude baikai-openai` pass; master plan Progress updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- One pre-implementation discovery from plan research is recorded here so it is not
  lost: the claude SDK's typed `Tool`/`InputSchema` records physically cannot carry a
  verbatim JSON Schema — `Claude.V1.Tool.InputSchema` serializes only `type`,
  `properties`, `required`, and `additionalProperties`, so `$defs`, `$ref`, and
  top-level `enum` are unrepresentable in the typed path. "Build the SDK Tool value
  directly" is therefore not enough; the fix requires sending a patched raw
  `Aeson.Value` request body. See Decision Log and Milestone 3.

- Regenerating `baikai/src/Baikai/Models/Generated.hs` after deleting the two compat
  fields produced no generated diff, confirming the current catalog only uses
  `"compat": "auto"` and no structured compat record literals had to be migrated. A
  code-only grep also returned no `supportsDeveloperRole` or
  `supportsEagerToolInputStreaming` references after the deletion. (2026-07-03, M1
  implementation)
- EP-6 had already moved OpenAI streaming to the local
  `Baikai.Provider.OpenAI.Sse` transport, so M2 did not use the drafted SDK middleware
  seam. Instead, `Baikai.Provider.OpenAI.Shape.streamRequestBody` builds the exact
  `Aeson.Value` sent by `openaiSseStreamValue`, immediately before the local transport
  encodes the request. This preserves EP-6's classified SSE error path while making the
  compat shaper testable as pure JSON. (2026-07-03, M2 implementation)
- The upstream OpenAI SDK's nested `ResponseFormat.JSONSchema` encoder serializes
  `strict = Nothing` as `"strict": null`, not as an omitted key. Because the compat
  contract for `supportsStrictMode = False` is "do not send strict", the M2 shaper
  deletes `response_format.json_schema.strict` on those hosts after typed request
  encoding. (2026-07-03, M2 implementation)


## Decision Log

Record every decision made while working on the plan.

- Decision: `maxTokensField` — IMPLEMENT. The upstream `openai` Haskell SDK exposes
  only `max_completion_tokens` on `CreateChatCompletion` (verified:
  `OpenAI/V1/Chat/Completions.hs:317` in the SDK source at
  `/Users/shinzui/Keikaku/hub/haskell/openai-project`; no `max_tokens` field exists).
  Rather than forking the SDK, baikai-openai applies a pure request-body post-processor
  (`shapeRequestBody`) via a servant-client middleware on a baikai-owned `ClientEnv`;
  when the flag is `MaxTokensField` it renames the JSON key
  `max_completion_tokens` → `max_tokens`.
  Rationale: the SDK's SSE path applies `Client.middleware clientEnv` to every
  streaming request (verified at `OpenAI/V1.hs:555-558`), so a middleware that rewrites
  the encoded body is a supported injection point; the master plan permits wrapping the
  SDK but not forking it.
  Date: 2026-07-01
- Decision: `supportsDeveloperRole` — DELETE end-to-end.
  Rationale: baikai always emits the `system` role (`mapRequest` at
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:726-733`) and every known host —
  including OpenAI's o-series, which server-side aliases `system` to `developer` —
  accepts it. The flag guards a request shape baikai never produces; implementing it
  would change the wire for zero benefit. It can be reintroduced when baikai actually
  emits `developer`.
  Date: 2026-07-01
- Decision: `supportsStrictMode` — IMPLEMENT by gating the `strict` field inside
  `response_format.json_schema` (currently sent unconditionally by
  `mkOpenAIResponseFormat`, `Api.hs:760-772`). Tool-level `strict` remains unsent, as
  today (`mkOpenAITool` passes `strict = Nothing`; baikai's `Tool` record has no strict
  preference to forward).
  Rationale: this is the one place baikai already emits a strict marker that
  flag-`False` hosts (DeepSeek, OpenRouter, Together per auto-detection) can reject;
  gating it makes the flag wire-effective without inventing a new per-tool option.
  Date: 2026-07-01
- Decision: `requiresThinkingAsText` — NOT TOUCHED. Owned by
  `docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md` per the
  master plan's integration points. This plan must not delete or wire it.
  Date: 2026-07-01
- Decision: `thinkingFormat` non-OpenAI constructors — IMPLEMENT via the same
  `shapeRequestBody` post-processor. `ThinkingFormatOpenAI` already reaches the wire
  through the typed `reasoning_effort` field; the DeepSeek / OpenRouter / Together /
  Z.ai / Qwen shapes are currently silently dropped
  (`applyThinkingFormat`, `Api.hs:785-792`). The post-processor injects the documented
  per-host keys (see Milestone 2). `ThinkingMinimal` maps to `"low"` on hosts without a
  minimal tier; only OpenAI receives `"minimal"`.
  Rationale: request-side reasoning shaping is a compat quirk (this plan's charge);
  response-side reasoning extraction stays with EP-7. The mechanism exists anyway for
  `maxTokensField`, so the marginal cost is a small pure function per shape.
  Date: 2026-07-01
- Decision: `cacheControlFormat` (+ the OpenAI record's `supportsLongCacheRetention`)
  — IMPLEMENT. When `cacheControlFormat = Just CacheControlFormatAnthropic` and
  `Options.cacheRetention` is `CacheRetentionShort`/`CacheRetentionLong`, the
  post-processor attaches an Anthropic-style
  `"cache_control": {"type": "ephemeral"[, "ttl": "1h"]}` object to the last content
  part of the system message (falling back to the last content part of the final user
  message when there is no system prompt). The `ttl` is emitted only when the
  retention is Long and `supportsLongCacheRetention` is `True`. Hosts without the flag
  get no marker.
  Rationale: this is exactly the OpenRouter passthrough-caching shape the flag
  documents, it makes both flags wire-effective, and prompt caching is a real cost
  lever. Marker placement mirrors what the Claude provider does (a single breakpoint
  covering the prefix).
  Date: 2026-07-01
- Decision: `supportsUsageInStreaming` — IMPLEMENT. `prepareCall`
  (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:185-193`) currently always sends
  `stream_options: {"include_usage": true}`; older OpenAI-compatible servers reject
  the unknown `stream_options` key with a 400. When the flag is `False`, omit
  `stream_options` entirely (the assembler already tolerates absent usage — it keeps
  `Usage._Usage`).
  Date: 2026-07-01
- Decision: `supportsCacheControlOnTools` — IMPLEMENT. When `True`, tools are present,
  and `Options.cacheRetention` is active, `mkAnthropicTool` marks the LAST tool
  definition with the computed `cache_control` via the SDK's `withToolCacheControl`
  (verified to exist at `Claude/V1/Tool.hs:411-415` in the SDK source at
  `/Users/shinzui/Keikaku/hub/haskell/claude-project`). When `False` (Fireworks per
  auto-detection), no tool ever carries a marker.
  Rationale: marking the last tool is Anthropic's documented pattern for caching the
  tool-definition prefix; the flag becomes wire-effective in both states.
  Date: 2026-07-01
- Decision: `supportsEagerToolInputStreaming` — DELETE end-to-end.
  Rationale: it is documented as "advisory; the SDK does not expose the field". The
  underlying feature is the `fine-grained-tool-streaming` beta header, and enabling it
  changes streaming semantics (tool-argument deltas may be non-JSON fragments) that
  baikai's assembler does not handle. A flag with no consumer and a dangerous
  implementation is exactly what the review says to remove; reintroduce it together
  with a consumer.
  Date: 2026-07-01
- Decision: `sendSessionAffinityHeaders` — IMPLEMENT. When `True` (Fireworks per
  auto-detection), each request carries `x-session-affinity: <hex sha256 of
  (systemPrompt <> first user message text)>`, computed by a pure function so it is
  unit-testable and stable across the turns of one conversation.
  Rationale: Fireworks-style routing needs a per-conversation-stable opaque value;
  deriving it from the conversation prefix gives that without adding a session-id
  field to `Context`. Uses `crypton`'s SHA256 (already in the dependency closure via
  `http-client-tls` → `tls`).
  Date: 2026-07-01
- Decision: Anthropic `supportsLongCacheRetention` — KEEP (already implemented by
  `computeCacheControl`, `baikai-claude/src/Baikai/Provider/Claude/Api.hs:623-639`).
  No change beyond haddock confirmation.
  Date: 2026-07-01
- Decision: verbatim Claude tool schemas require a raw-value send path. The SDK's
  `functionTool` provably mangles schemas (`Claude/V1/Tool.hs:146-173`): it keeps only
  `properties`/`required`, drops `additionalProperties`/`$defs`/`$ref`/`enum`, and for
  a schema with no `"properties"` key stuffs the whole schema under `properties`
  (turning `{"type":"object"}` into a phantom parameter named `type`). Building the
  typed `Tool` directly does not fix this because `InputSchema` serializes only four
  fixed keys. Therefore baikai-claude gains a local SSE module that POSTs an
  `Aeson.Value` body (a copy of the SDK's `ssePostJSON`, generalized over headers,
  body, and timeout — the master plan explicitly permits bypassing the SDK locally),
  and the request `Value` is `toJSON` of the typed `CreateMessage` with each
  `tools[i].input_schema` replaced by the caller's verbatim `Tool.parameters`.
  Date: 2026-07-01
- Decision: `ToolChoiceNone` on Claude keeps `tools` and sends
  `tool_choice {"type": "none"}` via the same request-value patch. Anthropic's API
  documents `none` as a first-class `tool_choice` value; the SDK's `ToolChoice` type
  simply lacks the constructor (`Claude/V1/Tool.hs:193-218` has only Auto/Any/Tool).
  Fallback if a non-Anthropic Messages host rejects `"none"`: callers can set an
  explicit compat record and choose `ToolChoiceAuto`; no automatic downgrade is
  performed, and any such host discovery must be recorded here.
  Date: 2026-07-01
- Decision: `Options.timeoutMs` is a wall-clock bound on the entire call (connection,
  headers, and full stream drain), implemented with `System.Timeout.timeout` around
  the worker's streaming invocation in both providers. It is NOT an inactivity
  timeout. On expiry the worker stores a `BaikaiError` (category `TransientError`,
  message naming the configured bound; retryable) in `errInfoRef`, closes the channel,
  and the existing end-of-stream recovery emits the single terminal `EventError` —
  the in-band contract owned by
  `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`.
  Rationale: `http-client`'s `responseTimeout` only bounds time-to-headers (and both
  SDKs hard-set `responseTimeoutNone` on their streaming requests anyway:
  `OpenAI/V1.hs:469-473`, `Claude/V1.hs:229`), so a whole-call bound around the worker
  is the only mechanism that actually stops a stalled stream.
  Date: 2026-07-01
- Decision: per-host API-key env mapping lives in `Baikai.Auth` as a pure
  `defaultApiKeyEnvForBaseUrl :: Text -> Maybe String`, keyed by hostname-suffix match
  (reusing `Baikai.Compat.hostMatchesSuffix`), and both providers' `resolveKey` use it.
  Unknown hosts with no explicit `Options.apiKey` produce an `AuthError` naming the
  host — never a silent fallback to `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`.
  Rationale: a table in core keeps the two providers consistent, is trivially
  testable, and is where EP-9's planned `ApiKeyEnvChain` will slot in later. A
  catalog/`Model` field was rejected because hand-rolled `_Model` values would silently
  lose the protection.
  Date: 2026-07-01
- Decision: custom headers (`Model.headers` then `Options.headers`, options winning on
  duplicate names) are appended after SDK/provider-set headers and replace duplicates
  by case-insensitive name, including auth headers. A caller who overrides
  `Authorization`/`x-api-key` is assumed to be fronting a gateway and owns the
  consequences.
  Date: 2026-07-01
- Decision: the process-global `Manager` cache is duplicated as a ~25-line internal
  module in each provider package rather than added to core.
  Rationale: core `baikai` does not depend on `http-client` and should not grow the
  dependency for a cache the providers own; both provider packages already depend on
  `http-client`/`http-client-tls`.
  Date: 2026-07-01
- Decision: this plan extends — never re-creates — the `Baikai.Provider.Claude.Sse`
  and `Baikai.Provider.OpenAI.Sse` transport modules that
  `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (EP-6)
  introduces, and `ssePostValue`'s callback keeps EP-6's classified
  `Either BaikaiError …` error side.
  Rationale: EP-6 lands first (wave 2) and its non-2xx classification (status,
  `Retry-After`, body) is the initiative's highest-priority fix; a parallel transport
  with `Either Text` errors would silently undo it. Consequence for Milestone 2: after
  EP-6, OpenAI streaming no longer goes through the SDK's `ClientEnv.middleware` seam,
  so `shapeRequestBody` applies as a pure `Value -> Value` transform on the request
  body immediately before the Sse transport call; the middleware route in this plan's
  first Decision Log entry remains valid only for any call that still uses the SDK
  path — the implementer must check EP-6's landed code and record which seam was used.
  Date: 2026-07-01 (cross-plan reconciliation after parallel drafting)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 completed on 2026-07-03. Host detection now extracts and suffix-matches the
URL hostname at label boundaries, so unrelated hosts such as `api.xyz.ai` and
`evil-z.ai.example.com` keep the default compat records. The dead
`supportsDeveloperRole` and `supportsEagerToolInputStreaming` fields were removed from
core records, the generator, and tests; catalog regeneration produced no generated
diff. `Baikai.Auth.defaultApiKeyEnvForBaseUrl` now maps known host suffixes to the
provider-specific key env var and returns `Nothing` for unknown hosts. Validation:

```text
cabal run baikai-gen-models
Generated.hs unchanged

grep -rn "supportsDeveloperRole\|supportsEagerToolInputStreaming" --include="*.hs" .
no matches

cabal test baikai baikai-claude baikai-openai --test-show-details=direct
baikai: 119 tests passed
baikai-claude: 102 tests passed
baikai-openai: 41 tests passed
```

Milestone 2 completed on 2026-07-03. OpenAI-compatible requests now pass through a pure
JSON shaper before the local SSE transport sends them: DeepSeek receives `max_tokens`
plus its thinking keys, OpenRouter cache-control markers land on the cache breakpoint
with the long-retention TTL when supported, unsupported JSON-schema `strict` is omitted
from the wire, usage streaming can be disabled, and hand-rolled zero-cap models omit
the max-token field. Tool-call deltas with no `index` now resolve by explicit index,
then id, then sequential fallback, so id-bearing parallel calls no longer merge into
content index 0. Validation:

```text
cabal test baikai-openai --test-show-details=direct
baikai-openai: 47 tests passed
```


## Context and Orientation

baikai is a multi-package Haskell workspace (`cabal.project` at the repo root). The
packages relevant here:

- `baikai/` — the core library. `baikai/src/Baikai/Compat.hs` defines the two compat
  records (`OpenAICompletionsCompat`, `AnthropicMessagesCompat`) and the baseUrl
  auto-detection (`autoDetectOpenAICompletions`, `autoDetectAnthropicMessages`).
  `baikai/src/Baikai/Options.hs` defines the per-call `Options` record — note
  `timeoutMs :: Maybe Int` and `headers :: Map Text Text`, both currently ignored by
  every API provider. `baikai/src/Baikai/Model.hs` defines `Model` with
  `headers :: Map Text Text` (also ignored), `maxOutputTokens :: Natural`, and the
  `compat :: Compat` field whose `CompatNone` value defers to auto-detection.
  `baikai/src/Baikai/Auth.hs` resolves `ApiKeySource` values.
  `baikai/gen/GenModels.hs` is a generator executable that reads
  `baikai/data/models/*.json` and writes `baikai/src/Baikai/Models/Generated.hs`; it
  parses and renders every compat field by name, so any field deletion must be made in
  three places (record, parser at `GenModels.hs:181-217`, renderer at
  `GenModels.hs:476-505`) and the catalog regenerated. All four current catalog files
  say `"compat": "auto"`, so the generated models all carry `CompatNone` and no data
  file changes are needed for flag deletions.
- `baikai-openai/` — the OpenAI Chat Completions API provider,
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. `mapRequest` (lines 721-754)
  builds the typed SDK request; `prepareCall` (175-194) resolves the key, builds a
  `ClientEnv` via the SDK, and forces `stream_options`; `resolveKey` (196-199) falls
  back to `OPENAI_API_KEY` for every host; the worker (230-247) drives the SDK's SSE
  callback; `parseChunk`/`parseToolCallDeltas` (260-318) pre-parse chunks (the
  tool-delta `index` defaults to `0` at line 313); the `Assembler` (450-495) keys
  tool calls by that index in `toolIndexMap`.
- `baikai-claude/` — the Anthropic Messages API provider,
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. `mapRequest` (555-598) builds the
  typed `Messages.CreateMessage`; `prepareCall` (154-166) builds the SDK env;
  `mkAnthropicTool` (667-674) goes through the SDK's lossy `functionTool`;
  `ToolChoiceNone` suppresses the `tools` field entirely (569-584).
- `baikai-smoke/` — an executable-style test package that runs live cases and prints
  "skipping" lines when the relevant env keys or binaries are absent (see
  `baikai-smoke/test/Smoke.hs`, pattern `firstSetEnv`).

The two vendor SDKs are MercuryTechnologies' `openai` and `claude` Haskell packages.
Their sources are on disk (via `mori registry show MercuryTechnologies/openai --full`
and `.../claude --full`) at `/Users/shinzui/Keikaku/hub/haskell/openai-project` and
`/Users/shinzui/Keikaku/hub/haskell/claude-project`. Facts verified from those sources
that this plan depends on:

- `OpenAI.V1.getClientEnv` (`OpenAI/V1.hs:166-180`) builds a NEW TLS `Manager` per
  invocation with `responseTimeoutNone`; `baikai-openai`'s `prepareCall` calls it per
  request (`Api.hs:183`), so every call pays a TLS-manager setup and no connection is
  ever reused. `makeMethods` accepts any `ClientEnv`, so baikai can construct its own
  from a cached `Manager` with `Servant.Client.mkClientEnv`.
- The openai SDK's streaming path `ssePostJSON` (`OpenAI/V1.hs:432-560`) runs the
  request through `Client.middleware clientEnv` (line 557) — a
  `ClientMiddleware` on a baikai-owned `ClientEnv` can therefore add headers and
  rewrite the `RequestBodyLBS` JSON body of streaming requests. It also hard-sets
  `responseTimeout = responseTimeoutNone` on the final http-client request (469-473),
  which is why the timeout must be enforced around the call, not in the manager.
- `CreateChatCompletion` has `max_completion_tokens :: Maybe Natural` and no
  `max_tokens` field (`OpenAI/V1/Chat/Completions.hs:317`), confirming the review's
  claim that the DeepSeek `MaxTokensField` quirk cannot be expressed typed.
- The claude SDK's streaming path `ssePostJSON` (`Claude/V1.hs:194-292`) builds a raw
  `http-client` request directly from the `ClientEnv`'s manager and base URL — it does
  NOT go through servant middleware, and its header list is fixed to
  `x-api-key`/`anthropic-version`/`anthropic-beta`. Per-request custom headers and
  body rewriting are impossible through the claude SDK; hence the local SSE module in
  Milestone 3. The claude SDK's `MessageStreamEvent` `FromJSON` instance remains
  usable for decoding the values our local module yields (mirroring the SDK's own
  `createMessageStreamTyped`).
- `Claude.V1.Tool.functionTool` mangles schemas exactly as the review describes
  (`Tool.hs:146-173`), and the typed `InputSchema` cannot carry arbitrary keys.
  `withToolCacheControl` (`Tool.hs:411-415`) exists for per-tool cache markers.
  `Claude.V1.makeMethodsWith` accepts an `anthropicBeta` header but no arbitrary
  headers.

The findings this plan fixes, with failure scenarios:

1. Decorative flags (review Theme 4.1, major). `maxTokensField`,
   `supportsDeveloperRole`, `cacheControlFormat`, `supportsUsageInStreaming`,
   `sendSessionAffinityHeaders` are defined in `baikai/src/Baikai/Compat.hs`, parsed
   and rendered by `baikai/gen/GenModels.hs`, asserted by `compatDetectionTest` in
   `baikai-claude/test/Main.hs:99-109` and `baikai-openai/test/Main.hs:111-122` and by
   `baikai/test/Main.hs:156-195` — and consumed by no provider code. Failure scenario:
   a user selects `deepseek-chat` from the catalog; auto-detection dutifully sets
   `maxTokensField = MaxTokensField`; the provider sends `max_completion_tokens`
   anyway and DeepSeek rejects or ignores the cap. Also decorative but unnamed by the
   review: `supportsStrictMode` (threaded into `mkOpenAITool` but never read) and
   `supportsCacheControlOnTools`/`supportsEagerToolInputStreaming` (threaded into
   `mkAnthropicTool` but never read). The master plan's acceptance ("every flag either
   changes the request that goes over the wire or no longer exists") covers these too;
   per-flag decisions are in the Decision Log.
2. Substring host detection (Theme 4.2, minor). `baikai/src/Baikai/Compat.hs:206`
   matches ``"z.ai" `Text.isInfixOf` url``, so `https://api.xyz.ai` — an unrelated
   host — inherits Z.ai quirks, and (line 211) any URL containing the letters
   `qwen` anywhere inherits Qwen quirks. Failure scenario: a custom gateway at
   `https://proxy.xyz.ai` silently gets `enable_thinking: true` injected and 400s.
3. Ignored transport options (Theme 5.1, major). Both API providers ignore
   `Options.timeoutMs`, `Options.headers`, and `Model.headers`
   (`baikai-claude/.../Api.hs:154-171` and `:555-598`;
   `baikai-openai/.../Api.hs:175-199` and `:721-754`), and both SDKs set
   `responseTimeoutNone`. Failure scenario: a host accepts the connection and then
   stalls mid-stream; the worker blocks in `brRead` forever, the consumer blocks in
   `readChan` forever, and the caller's thread hangs with no recourse. Gateway
   attribution headers (`Helicone-*`, `X-Title`, etc.) configured on `Model.headers`
   never reach the wire.
4. `ToolChoiceNone` 400 (Theme 5.2, major). `baikai-claude/.../Api.hs:573-584` omits
   `tools` when the caller asks for `ToolChoiceNone`, but Anthropic returns HTTP 400
   when the conversation already contains `tool_use`/`tool_result` blocks and `tools`
   is absent. Failure scenario: the natural last call of a tool loop — "you have the
   results, now answer without calling more tools" — always fails.
5. Tool-schema mangling (Theme 9.1, major). `baikai-claude/.../Api.hs:667-674` routes
   every tool through the SDK's `functionTool`. Failure scenarios: a no-argument tool
   declared as `{"type":"object"}` becomes
   `{"type":"object","properties":{"type":"object"}}` — Claude sees a phantom
   required-free parameter named `type` and may try to supply it; a schema using
   `$defs`/`$ref` loses the definitions and Claude receives dangling references; a
   strict schema's `additionalProperties: false` and top-level `enum` vanish.
6. `max_completion_tokens: 0` (Theme 5.3, minor). `baikai-openai/.../Api.hs:734,748`:
   with a hand-rolled `_Model` (`maxOutputTokens = 0`) and no `opts.maxTokens`, the
   request carries `max_completion_tokens: 0` and OpenAI 400s.
7. Credential leak (Theme 10.8, minor, security-adjacent).
   `baikai-openai/.../Api.hs:196-199` falls back to `OPENAI_API_KEY` for EVERY host.
   Failure scenario: a user runs the catalog's `deepseek-chat` with only
   `OPENAI_API_KEY` set; their OpenAI secret is transmitted as a Bearer token to
   `api.deepseek.com` and they get a confusing 401 from DeepSeek.
8. Manager churn (Theme 10.6, minor). `baikai-openai/.../Api.hs:183` builds a fresh
   TLS `Manager` per request: no connection reuse, file-descriptor churn under load.
   The claude provider has the same pattern at `baikai-claude/.../Api.hs:164`.
9. Tool-delta index default (Theme 10.7, minor). `baikai-openai/.../Api.hs:313`
   defaults a missing `"index"` to `0`. Failure scenario: a host that omits `index`
   (several OpenAI-compatible servers do) streams two parallel tool calls; both merge
   into content-index 0 with interleaved concatenated argument JSON — one corrupt
   call, one lost call.


## Plan of Work

The work is five milestones. M1 lands core groundwork that everything else references.
M2 and M3 make the two providers' request shaping honest (they are independent of each
other). M4 wires transport (shared mechanics, both providers). M5 is the truth-and-
evidence sweep. Because this plan and
`docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md` both edit the
Claude `mapRequest`, this plan starts only after EP-7 lands (soft dependency resolved
by ordering); if any edit here would touch the thinking/`max_tokens` computation or
`computeThinking`, stop and record a Decision Log entry in both plans instead.

### Milestone 1 — Core groundwork: honest host detection, flag deletions, key-env table

Scope: `baikai/src/Baikai/Compat.hs`, `baikai/src/Baikai/Auth.hs`,
`baikai/gen/GenModels.hs`, the regenerated `baikai/src/Baikai/Models/Generated.hs`,
and the three test suites' compat assertions. At the end, host detection cannot be
fooled by substrings, the two dead-by-decision flags no longer exist anywhere, and a
pure table answers "which env var holds the key for this host".

Host detection. In `baikai/src/Baikai/Compat.hs`, add two pure helpers (exported, so
`Baikai.Auth` and tests can reuse them):

```haskell
-- | Extract the hostname from a URL-ish Text: drop an optional
-- "scheme://" prefix, an optional "user@" userinfo, then take
-- characters up to the first of '/', ':', '?', '#'. Lowercased.
-- Returns Nothing for empty results.
urlHost :: Text -> Maybe Text

-- | True when the hostname equals the suffix or ends with
-- "." <> suffix (label-boundary match, case-insensitive).
hostMatchesSuffix :: Text -> Text -> Bool  -- hostname -> suffix -> Bool
```

No new dependency: this is `Text` splitting, not a full URI parser, and it must be
total. Rewrite `autoDetectOpenAICompletions` and `autoDetectAnthropicMessages` to
compute `urlHost url` once and match each rule with `hostMatchesSuffix` against
explicit domain lists: `api.openai.com`; `api.deepseek.com`; `openrouter.ai`;
`together.xyz` and `together.ai`; `z.ai`; `dashscope.aliyuncs.com`,
`dashscope-intl.aliyuncs.com`, and `qwen.ai`; `api.anthropic.com`; `fireworks.ai`.
A URL with no extractable host, or a host matching nothing, yields the default record
exactly as today. Note the behavior change is deliberate: `https://api.xyz.ai` and
`https://evil-z.ai.example.com` now get defaults.

Flag deletions. Remove `supportsDeveloperRole` from `OpenAICompletionsCompat` (field,
default, and the DeepSeek/OpenRouter/Together overrides) and
`supportsEagerToolInputStreaming` from `AnthropicMessagesCompat` (field and default).
In `baikai/gen/GenModels.hs` remove the corresponding lines in `parseOpenAICompat`
(`:185`), `parseAnthropicCompat` (`:204-217`), and the two render functions
(`renderCompat`, `:476-505`). Regenerate the catalog (command in Concrete Steps); the
diff to `baikai/src/Baikai/Models/Generated.hs` should be empty apart from
possibly-removed import names, because every catalog entry is `"compat": "auto"` —
if any generated record literal changes beyond that, stop and investigate. Update the
compat assertions in `baikai/test/Main.hs:156-195`,
`baikai-openai/test/Main.hs:111-122`, and `baikai-claude/test/Main.hs:99-109` to drop
the deleted fields. Also update `baikai-claude/.../Api.hs`'s and
`baikai-openai/.../Api.hs`'s field references if any exist (there are none today —
that is the finding — but `mkAnthropicTool`'s ignored `_compat` parameter docs
mention eager streaming; fix the haddock).

Key-env table. In `baikai/src/Baikai/Auth.hs` add:

```haskell
-- | The conventional API-key environment variable for a known host,
-- matched by hostname suffix. Nothing for unknown hosts: callers must
-- then supply Options.apiKey explicitly; providers never fall back to
-- another host's variable.
defaultApiKeyEnvForBaseUrl :: Text -> Maybe String
```

Table (hostname suffix → env var): `api.openai.com` → `OPENAI_API_KEY`;
`api.deepseek.com` → `DEEPSEEK_API_KEY`; `openrouter.ai` → `OPENROUTER_API_KEY`;
`together.xyz`/`together.ai` → `TOGETHER_API_KEY`; `z.ai` → `ZAI_API_KEY`;
`dashscope.aliyuncs.com`/`dashscope-intl.aliyuncs.com` → `DASHSCOPE_API_KEY`;
`qwen.ai` → `DASHSCOPE_API_KEY`; `api.anthropic.com` → `ANTHROPIC_API_KEY`;
`fireworks.ai` → `FIREWORKS_API_KEY`. The empty base URL maps to the provider default
at the call site (Milestone 4), because each provider substitutes its own default host
before resolving. This function is pure; wiring into `resolveKey` happens in M4 so
this milestone stays test-green without touching providers.

Tests: add a `tasty-quickcheck` (new test dependency of `baikai:baikai-test`) property
— for any hostname `h` not ending in a known suffix at a label boundary, detection
returns the default record — plus table-driven cases: `https://api.xyz.ai` → default;
`https://api.z.ai/v1` → Zai; `https://API.DEEPSEEK.COM` → DeepSeek;
`http://user@openrouter.ai:8443/api` → OpenRouter; `""` → default. Mirror a couple of
cases onto `defaultApiKeyEnvForBaseUrl`.

Acceptance: `cabal test baikai baikai-claude baikai-openai` passes; `grep -rn
supportsDeveloperRole\|supportsEagerToolInputStreaming` over the repo returns nothing;
the new detection tests demonstrate the `api.xyz.ai` fix.

### Milestone 2 — OpenAI request shaping: every flag on the wire, zero-cap fix, delta keying

Scope: `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` plus a new internal module
`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` and tests in
`baikai-openai/test/Main.hs` (new module `ShapeSpec` if `Main.hs` grows unwieldy). At
the end, the emitted JSON for each compat flag is assertable in a pure unit test.

The shaper. Create `Baikai.Provider.OpenAI.Shape` exporting one pure function and its
pieces:

```haskell
shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
```

applied to the `toJSON`-encoding of the SDK request. Its clauses, each an
independently testable `Value -> Value` step:

- `renameMaxTokens`: when `maxTokensField == MaxTokensField` and the object has
  `max_completion_tokens`, move the value to `max_tokens`.
- `injectThinkingShape`: when `opts.thinking = Just lvl` and `thinkingFormat` is a
  non-OpenAI shape, add the documented keys — OpenRouter:
  `"reasoning": {"effort": <lvl>}`; DeepSeek: `"thinking": {"type": "enabled"}` and
  `"reasoning_effort": <lvl>`; Together: `"reasoning": {"enabled": true}` and
  `"reasoning_effort": <lvl>`; Z.ai/Qwen: `"enable_thinking": true`.
  `ThinkingFormatNone` adds nothing. `<lvl>` renders minimal/low/medium/high with
  minimal downgraded to `"low"` on these hosts. (`ThinkingFormatOpenAI` is already
  handled by the typed `reasoning_effort` field and must not be double-emitted.)
- `injectCacheControl`: per the Decision Log — when
  `cacheControlFormat == Just CacheControlFormatAnthropic` and `opts.cacheRetention`
  is Short/Long, attach `"cache_control"` to the last element of the system message's
  `"content"` array (else the final user message's), with `"ttl": "1h"` only when
  Long and `supportsLongCacheRetention`.

How it reaches the wire: `prepareCall` stops calling `OpenAI.getClientEnv`. It obtains
a cached `Manager` (Milestone 4 module; in this milestone, create the module with the
cache so M2 compiles standalone), builds
`env0 = Servant.Client.mkClientEnv manager baseUrl`, and sets
`env = env0 { middleware = shapeMiddleware compat opts model }` where the middleware
transforms each servant `Request` by (a) rewriting a `RequestBodyLBS` body through
`Aeson.decode`/`shapeRequestBody`/`Aeson.encode` (pass through unchanged if the body
is not decodable JSON), and (b) header edits (Milestone 4 fills these in). The SDK's
`ssePostJSON` applies this middleware to streaming requests (verified,
`OpenAI/V1.hs:557`), so no SDK change is needed. Build the env per call from the
cached manager — the middleware closes over per-call `Options`.

Typed-side flag gating in `mapRequest`/`prepareCall`:

- `supportsStrictMode`: pass the compat record into `mkOpenAIResponseFormat`; when
  `False`, emit `RF.strict = Nothing` instead of `Just st`.
- `supportsUsageInStreaming`: in `prepareCall`, set `Chat.stream_options` to the
  current value only when the flag is `True`; otherwise `Nothing`.
- Zero-cap omission: in `mapRequest` replace
  `mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)` usage with
  `max_completion_tokens = if mt == 0 then Nothing else Just mt`.

Tool-delta keying. In `parseToolCallDeltas` change `RawToolDelta.index` to
`Maybe Int` (line 313: `lookupField "index"` maps through `fromInt` only when
present). Extend `Assembler` with `toolIdMap :: Map Text Int` and
`lastToolIdx :: Maybe Int`. `applyOneToolDelta` resolves the baikai content index in
this order: explicit `index` via `toolIndexMap` (unchanged behavior for conforming
hosts); else `id` via `toolIdMap` (open a new block when unseen); else — no index, no
id — continue `lastToolIdx` when a tool block is open, else open a new block. Every
opened block records itself in both maps and `lastToolIdx`. This keeps single-call
streams from index-less hosts working and keeps parallel calls separate whenever the
host provides ids (all known ones do on the first fragment of each call).

Tests (pure, no network): encode `mapRequest` output for a DeepSeek-detected model and
assert after `shapeRequestBody`: the JSON has `max_tokens` and lacks
`max_completion_tokens`; with `thinking = Just ThinkingHigh` it carries
`{"thinking":{"type":"enabled"},"reasoning_effort":"high"}`; an OpenRouter-detected
model with `cacheRetention = Just CacheRetentionLong` carries the marker with ttl on
the system message's last part; `supportsUsageInStreaming = False` yields no
`stream_options` key; a `_Model` with `maxOutputTokens = 0` yields no
max-tokens key at all; a chunk sequence with two id-bearing, index-less tool deltas
produces two distinct `ToolCallEnd` events with unmixed argument JSON (this test fails
before the fix — capture that in Surprises & Discoveries with the corrupt merged
output).

Acceptance: `cabal test baikai-openai` green; each flag has at least one test whose
assertion is on emitted JSON bytes/structure, not on the compat record.

### Milestone 3 — Claude raw streaming path: verbatim tool schemas, tool_choice none, tool cache markers

Scope: extend `baikai-claude/src/Baikai/Provider/Claude/Sse.hs` — the module is
created by `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`
(EP-6), which lands before this plan — plus edits to
`prepareCall`, `mkAnthropicTool`, and the tools/tool_choice region of `mapRequest` in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`, and tests in
`baikai-claude/test/Main.hs`. The thinking/`max_tokens` region (lines 559-567 as of
this writing, whatever EP-7 turned it into) and `computeThinking` are off-limits.

The raw send path. After EP-6, `Baikai.Provider.Claude.Sse` already exists with
`claudeSseStream` (typed `Messages.CreateMessage` body, `Servant.ClientEnv` transport)
and `sseFromResponse` (the SSE line-buffering half, exposed for tests). This milestone
generalizes that module rather than duplicating it: add `ssePostValue` as the general
entry point and rebuild `claudeSseStream` as a thin typed wrapper over it. Reuse
`sseFromResponse` as-is — do not re-copy the SDK's line-buffering logic
(`Claude/V1.hs:194-292` remains useful reference only if EP-6's landed shape differs).
The callback keeps EP-6's classified error side (`Either BaikaiError …`, carrying
status, `Retry-After`, and body on non-2xx); reverting to plain `Text` errors would
undo EP-6's central fix. Consult EP-6's landed code for the exact names before
starting this milestone and record any divergence in both plans' Decision Logs.

```haskell
ssePostValue ::
  Manager ->
  SseTarget ->            -- scheme/host/port/path parsed once from Model.baseUrl
  [(HeaderName, ByteString)] ->  -- full header list, caller-assembled
  Aeson.Value ->          -- request body, "stream": true already set
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
```

The worker keeps decoding values into `Messages.MessageStreamEvent` with
`Aeson.fromJSON`, exactly as the SDK's `createMessageStreamTyped` does, so the entire
translation/assembler pipeline downstream is untouched. `ClaudeCall` changes from
holding SDK `Methods` to holding the manager, target, headers, and body `Value`.

Request-value construction. `prepareCall` builds the typed `Messages.CreateMessage`
via `mapRequest` (unchanged responsibility split), sets `Messages.stream = Just True`,
takes `toJSON`, and applies a pure patch:

```haskell
patchRequestValue :: Context -> Options -> Aeson.Value -> Aeson.Value
```

- Verbatim tool schemas: for each element of the encoded `"tools"` array, replace its
  `"input_schema"` with the corresponding `Tool.parameters` from `ctx ^. #tools`
  (index-wise zip; `mapRequest` maps tools with `Vector.map`, so order is preserved).
  This fixes finding 5 for every shape including the no-`properties`
  `{"type":"object"}` case, because the caller's `Value` is inserted untouched.
  `mkAnthropicTool` keeps using `functionTool` for name/description scaffolding — its
  broken `input_schema` is overwritten wholesale.
- `tool_choice` none: `mapRequest` drops the `suppressTools` logic — `toolsVec` is
  always `ctx ^. #tools` — and keeps `toolChoiceField = Nothing` for `ToolChoiceNone`
  (the SDK type cannot express it); the patch then inserts
  `"tool_choice": {"type": "none"}` when `opts ^. #toolChoice == Just ToolChoiceNone`
  and the context has tools. Delete the now-false "Unreachable" comment branch in
  `mkAnthropicToolChoice` or make it total honestly.

Tool cache markers. `mkAnthropicTool` gains real compat consumption: in `mapRequest`,
after building the tools vector, when `supportsCacheControlOnTools compat` and
`computeCacheControl compat (opts ^. #cacheRetention)` is `Just cc`, apply the SDK's
`withToolCacheControl` (translating the `Messages.CacheControl` to the Tool module's
`CacheControl` shape — both are `{"type":"ephemeral","ttl":...}`; check the two types
in `Claude/V1/CacheControl.hs`, they are the same type re-exported) to the LAST
element only.

Tests (pure): `patchRequestValue` round-trips a schema with `$defs`, `$ref`,
top-level `enum`, and `additionalProperties: false` byte-identically into
`tools[0].input_schema`; the `{"type":"object"}` no-arg tool arrives as exactly
`{"type":"object"}` (assert the phantom `properties.type` regression is gone — write
the failing assertion against the OLD `functionTool` output first and keep it as a
negative-shape check); a context with tools plus `ToolChoiceNone` yields JSON with a
non-empty `"tools"` array AND `"tool_choice":{"type":"none"}`; a Fireworks-detected
model (`supportsCacheControlOnTools = False`) with `cacheRetention = Just
CacheRetentionShort` yields tools without any `cache_control` key while an
Anthropic-default model yields a marker on the last tool only.

Acceptance: `cabal test baikai-claude` green; the streaming path still passes the
package's existing stream-translation tests (the worker change is transport-only).

### Milestone 4 — Transport options: manager cache, headers, timeout, per-host keys

Scope: both provider `Api.hs` files, a small `ManagerCache` internal module per
provider package, `resolveKey` in both, and stalling-socket tests. At the end,
`Options.timeoutMs`, `Options.headers`, `Model.headers`, and
`sendSessionAffinityHeaders` all observably work, and connections are reused.

Manager cache. Each provider package gets an internal module (e.g.
`Baikai.Provider.OpenAI.ManagerCache`, `Baikai.Provider.Claude.ManagerCache`) with:

```haskell
-- | Process-global cache of TLS Managers keyed by (secure, host, port).
-- Managers are created with responseTimeoutNone (streams are unbounded
-- at the transport layer; Options.timeoutMs bounds the whole call).
getManagerFor :: Text -> IO Manager   -- takes the resolved base URL
```

implemented as a `NOINLINE` `unsafePerformIO`'d `MVar (Map (Bool, Text, Int) Manager)`
with double-checked insert (racing creators may build two managers; the loser is
dropped — harmless). The openai provider feeds it into `mkClientEnv` (Milestone 2);
the claude provider feeds it into `ssePostValue`.

Headers. Add a pure assembler shared in spirit (one per package, same semantics):

```haskell
requestHeaders ::
  Model -> Context -> Options ->
  [(HeaderName, ByteString)] ->   -- provider/SDK base headers (auth, accept, ...)
  [(HeaderName, ByteString)]
```

Merge order: base headers, then `Model.headers`, then `Options.headers`, then — claude
provider only, when `sendSessionAffinityHeaders (anthropicMessagesCompatFor m)` —
`x-session-affinity` computed by a pure
`sessionAffinityKey :: Context -> Text` (hex SHA-256 via `crypton`'s
`Crypto.Hash.SHA256` over UTF-8 of `fromMaybe "" systemPrompt <> firstUserText`; add
`crypton` and `memory` to `baikai-claude`'s build-depends — both are already in the
install plan via `tls`). Later entries replace earlier ones by case-insensitive name
(headers are `CI ByteString`; both packages already depend on `case-insensitive`).
On the claude side the full list feeds `ssePostValue`. On the openai side the
middleware from Milestone 2 appends/replaces onto `requestHeaders` of the servant
request (the SDK already set `Authorization`; replacement-by-name applies).

Timeout. In both workers, when `opts ^. #timeoutMs = Just ms` with `ms > 0`, wrap the
streaming invocation:

```haskell
r <- timeout (ms * 1000) (try @SomeException (stream' ...))
```

(`System.Timeout.timeout` takes microseconds.) On `Nothing`, write
`Just (baseError TransientError ("request timed out after " <> tshow ms <> "ms"))` —
use the existing `Baikai.Error` constructors; `TransientError` is retryable per
`isRetryable` — into `errInfoRef` and fall through to `writeChan ch Nothing`. The
existing end-of-stream recovery (`closeOpenStream` / `unexpectedEoS`) then emits the
single terminal `EventError` carrying partial content plus the classified error. This
is precisely the in-band error terminal defined by
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`; if EP-6
renamed the category or added a dedicated timeout constructor by the time this runs,
use that and record it in this Decision Log. `Nothing`/`Just 0`-or-negative means no
bound (document on `Options.timeoutMs`' haddock... the haddock lives in core; update
`baikai/src/Baikai/Options.hs` to state the wall-clock semantics).

Per-host keys. Rewrite both `resolveKey`s:

```haskell
resolveKey :: Model -> Options -> IO Text
resolveKey m opts = case opts ^. #apiKey of
  Just source -> Auth.resolveApiKey source
  Nothing -> case Auth.defaultApiKeyEnvForBaseUrl (effectiveBaseUrl m) of
    Just envVar -> Auth.resolveApiKey (Auth.ApiKeyEnv envVar)
    Nothing -> throwIO (authError ("no API key configured for host " <> host <> "; set Options.apiKey"))
```

where `effectiveBaseUrl` substitutes the provider default (`https://api.openai.com` /
`https://api.anthropic.com`) for the empty string, matching the URL defaulting already
in `prepareCall`. Note `resolveApiKey` currently throws `BaikaiError`; EP-6 owns
converting `prepareCall` exceptions into in-band terminals (master plan wave 2, item
"prepareCall exceptions"), so this plan changes WHICH error is produced, not the
channel it travels on. Do not restructure `prepareCall`'s `Either Text` here.

Tests: a header-assembly unit test (model header overridden by options header;
affinity header present for a Fireworks-detected model and stable across two contexts
sharing a prefix, absent for Anthropic default). An env-fallback test using
`setEnv`/`unsetEnv`: with `OPENAI_API_KEY` set and `DEEPSEEK_API_KEY` unset, streaming
against a DeepSeek-baseUrl model yields a terminal error mentioning
`DEEPSEEK_API_KEY` — and never issues a network call (the error path precedes the
transport). Timeout: in each provider test suite, bind a localhost TCP socket
(`network` package, new test dependency) whose accept-loop reads the request and then
sleeps without responding; point a hand-rolled `_Model` at
`http://127.0.0.1:<port>`, set `timeoutMs = Just 300` and a literal `apiKey`, drain
the stream, and assert: exactly one terminal `EventError`, its error retryable with a
message containing `timed out`, and wall-clock under ~5 seconds. Also assert the
no-timeout default is untouched elsewhere (existing tests).

Acceptance: `cabal test baikai-openai baikai-claude` green including the socket tests;
running the smoke suite twice in one process reuses managers (observable via a debug
counter in the cache module test, or simply the cache unit test asserting pointer
equality of two `getManagerFor` results for the same URL).

### Milestone 5 — Truth pass and live evidence

Scope: haddocks, smoke coverage, full validation, master plan bookkeeping.

Update `baikai/src/Baikai/Compat.hs` haddocks so every surviving flag names the exact
consumption point ("consumed by `shapeRequestBody` in
`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`; renames the max-token key", etc.)
and delete the "Currently advisory" phrases — after this plan nothing is advisory.
Update the module docs of both provider `Api.hs` files to describe the shaper /
raw-send architecture, and `baikai/src/Baikai/Options.hs` for `timeoutMs` and
`headers` semantics.

Some behaviors can only be proven against real hosts: that DeepSeek actually accepts
the renamed `max_tokens`, that Anthropic accepts a verbatim `$defs` schema and
`tool_choice none` after tool use, that OpenRouter accepts injected `cache_control`.
Add smoke cases to `baikai-smoke/test/` following the existing skip pattern
(`firstSetEnv`, "[baikai-smoke] ... skipping" on stderr when keys are absent): a
DeepSeek case (needs `DEEPSEEK_API_KEY`) sending a small capped request; a Claude
tool case (needs `ANTHROPIC_API_KEY`) with a `$defs`-bearing schema and a follow-up
`ToolChoiceNone` turn; a headers case that sets a harmless custom header (e.g.
`X-Title`) against OpenRouter (needs `OPENROUTER_API_KEY`). The OpenRouter
cache-control case may be asserted loosely (request succeeds) since cache hits are
timing-dependent. Timeout and manager reuse are NOT smoke-verifiable against live
hosts; the M4 unit tests are their evidence — say so in the smoke file comments.

Run the full validation (Concrete Steps), fill Outcomes & Retrospective, and tick the
two EP-8 lines in the master plan's Progress section
(`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`).


## Concrete Steps

All commands run from the repo root `/Users/shinzui/Keikaku/bokuno/baikai`.

Regenerate the model catalog after the M1 flag deletions:

```bash
cabal run baikai:baikai-gen-models
```

Expected output (count may drift with the catalog):

```text
Wrote /Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Models/Generated.hs (30 enabled models)
```

Verify the deletions left no references:

```bash
grep -rn "supportsDeveloperRole\|supportsEagerToolInputStreaming" --include="*.hs" .
```

Expected: no output (exit code 1).

Build and test after every milestone:

```bash
cabal build all --enable-tests
cabal test baikai baikai-claude baikai-openai
```

Expected: each suite prints a tasty summary ending in `All N tests passed`. The M4
socket tests take a few seconds each (bounded by the configured 300ms timeout plus
teardown); anything over ~30s for a suite indicates a hang — kill it and inspect the
worker's timeout wrapping.

Formatting (the repo uses fourmolu, config at `fourmolu.yaml`):

```bash
fourmolu -i baikai/src baikai/gen baikai-openai/src baikai-claude/src baikai-openai/test baikai-claude/test baikai/test baikai-smoke/test
```

Live smoke (optional; needs keys; skips cleanly without them):

```bash
cabal test baikai-smoke
```

Expected with no keys: stderr lines of the form
`[baikai-smoke] no DEEPSEEK_API_KEY set; skipping deepseek max_tokens case.` and a
passing suite. With keys: the new cases print one success line each.

Commit per milestone with conventional-commit messages, e.g.:

```text
feat(compat): match hosts by hostname suffix and delete dead flags
feat(openai): shape requests per compat flags; fix zero cap and tool-delta keying
feat(claude): raw SSE path with verbatim tool schemas and tool_choice none
feat(providers): wire timeoutMs, headers, manager cache, per-host key envs
docs(compat): document consumption points; add smoke coverage
```


## Validation and Acceptance

Acceptance is behavioral, per finding:

- Compat flags: for each surviving flag there is a unit test asserting the emitted
  request JSON changes when the flag flips (Milestones 2-3 name them). `grep -rn` for
  the deleted flags finds nothing. Reading `baikai/src/Baikai/Compat.hs`, every field's
  haddock names its consumption site.
- Host detection: the test asserting `autoDetectOpenAICompletions
  "https://api.xyz.ai"` equals `defaultOpenAICompletionsCompat` fails on the pre-plan
  code (it detects Zai) and passes after; the property test holds for arbitrary
  unrelated hosts.
- Timeout: the stalling-socket test — pre-plan it hangs (do not merge un-timeboxed;
  wrap the assertion itself in a generous outer `timeout` so the failing mode is a
  clean test failure, not a hung CI job); post-plan it completes in well under 5s with
  one terminal `EventError`, retryable, message containing `timed out`, matching the
  in-band contract of docs/plans/39-unify-the-error-contract-and-revive-error-classification.md.
- Headers: unit assertions on the assembled header list, plus the OpenRouter smoke
  case live.
- `ToolChoiceNone`: unit assertion that tools stay present and
  `tool_choice {"type":"none"}` is emitted; live proof via the Claude smoke case whose
  final turn contains tool_result blocks and succeeds (pre-plan this exact call 400s).
- Tool schemas: byte-identical round-trip assertions including `{"type":"object"}`;
  live proof via the `$defs` smoke case.
- Zero cap: unit test that a `_Model`-based request has no max-token key.
- Credential leak: the env-fallback test proves a DeepSeek-host call with only
  `OPENAI_API_KEY` set produces an error naming `DEEPSEEK_API_KEY` instead of sending
  anything.
- Manager churn: cache unit test observes reuse for a repeated base URL.
- Tool-delta keying: the two-parallel-calls-without-index test produces two well-formed
  `ToolCall`s (pre-plan: one corrupt merged call — keep the old output in Surprises &
  Discoveries as evidence).

Final gate: `cabal build all --enable-tests` and
`cabal test baikai baikai-claude baikai-openai` pass, and `cabal test baikai-smoke`
passes both keyless (all skips) and, where keys are available, live.


## Idempotence and Recovery

Every step is an ordinary source edit guarded by tests; re-running any milestone is
safe. The catalog generator is deterministic (sorted entries, fixed formatting), so
`cabal run baikai:baikai-gen-models` can be re-run at any time; `CatalogSpec` in
`baikai/test/` enforces that the checked-in `Generated.hs` matches the generator, so
if the two drift the test names it and regeneration fixes it. The manager cache is
process-global but additive — a bug there degrades to the old one-manager-per-call
behavior if you bypass the cache, which is a safe intermediate state. If the claude
raw SSE path misbehaves, the SDK path can be restored per call site by reverting the
`prepareCall`/worker hunk while keeping `patchRequestValue` tests red as a reminder;
milestones are sliced so each commit compiles and tests green independently. Nothing
here migrates data or touches the network at build time; the socket tests bind
ephemeral ports (`bind` to port 0 and read the assigned port) so parallel runs do not
collide.


## Interfaces and Dependencies

New/changed public surface in core `baikai`:

- `Baikai.Compat`: add `urlHost :: Text -> Maybe Text` and
  `hostMatchesSuffix :: Text -> Text -> Bool`; remove `supportsDeveloperRole` (from
  `OpenAICompletionsCompat`) and `supportsEagerToolInputStreaming` (from
  `AnthropicMessagesCompat`). Record constructors stay exported (they are the
  documented escape hatch); field removal is a breaking change absorbed by the 0.2
  pre-freeze window per the master plan.
- `Baikai.Auth`: add `defaultApiKeyEnvForBaseUrl :: Text -> Maybe String`.
- `Baikai.Options`: haddock-only (timeout and header semantics).

Provider internals (not re-exported; EP-10 owns namespace hygiene):

- `Baikai.Provider.OpenAI.Shape` (new): `shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Value -> Value` plus its per-quirk steps.
- `Baikai.Provider.OpenAI.ManagerCache` / `Baikai.Provider.Claude.ManagerCache`
  (new): `getManagerFor :: Text -> IO Manager`.
- `Baikai.Provider.Claude.Sse` (created by
  `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`,
  extended here): `ssePostValue :: Manager -> SseTarget ->
  [(HeaderName, ByteString)] -> Value -> (Either BaikaiError Value -> IO ()) -> IO ()`
  and `data SseTarget = SseTarget { secure :: Bool, host :: ByteString, port :: Int,
  path :: ByteString }`; EP-6's `claudeSseStream` becomes a thin typed wrapper and its
  `sseFromResponse` is reused unchanged.
- `Baikai.Provider.Claude.Api`: `patchRequestValue :: Context -> Options -> Value ->
  Value`, `sessionAffinityKey :: Context -> Text`, `requestHeaders` as described in
  Milestone 4; `resolveKey :: Model -> Options -> IO Text` (signature gains `Model`)
  in both providers.

Dependencies: `baikai:baikai-test` adds `tasty-quickcheck`; `baikai-claude` adds
`crypton` and `memory` (library) and `network` (test suite); `baikai-openai` adds
`network` (test suite). No SDK forks: the openai SDK is driven through its supported
`ClientEnv`/middleware seam (`servant-client`'s `ClientEnv.middleware`, already a
baikai-openai dependency), and the claude SDK is bypassed only for the streaming POST
while its request/response types (`Messages.CreateMessage`,
`Messages.MessageStreamEvent`, `Claude.V1.Tool.*`) remain the vocabulary. SDK sources
for reference during implementation:
`/Users/shinzui/Keikaku/hub/haskell/openai-project` and
`/Users/shinzui/Keikaku/hub/haskell/claude-project` (locate via
`mori registry show MercuryTechnologies/openai --full` and
`mori registry show MercuryTechnologies/claude --full`).

Cross-plan interfaces: this plan consumes the in-band error terminal defined by
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (timeout
and key-resolution failures) and must rebase onto whatever
`docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md` made of the
Claude `mapRequest` thinking/`max_tokens` region — this plan's `mapRequest` edits are
confined to `toolsVec`/`toolsField`/`toolChoiceField` and the surrounding tool
plumbing, and its request-value patch never writes the `thinking` or `max_tokens`
keys. `requiresThinkingAsText` is EP-7 property and survives this plan untouched.


---

Revision note (2026-07-01): reconciled with
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` after the
two plans were drafted in parallel. Milestone 3 now extends EP-6's
`Baikai.Provider.Claude.Sse` module instead of creating it, `ssePostValue`'s callback
carries `Either BaikaiError` (preserving EP-6's non-2xx classification), the Interfaces
entry is marked "extended", and a Decision Log entry records the consequence for
Milestone 2's `shapeRequestBody` seam (pure pre-transport transform rather than servant
middleware once EP-6's transport is in place).
