---
id: 40
slug: fix-extended-thinking-and-reasoning-across-providers
title: "Fix extended thinking and reasoning across providers"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Fix extended thinking and reasoning across providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

"Extended thinking" (Anthropic's name) or "reasoning" (the OpenAI-compatible ecosystem's
name) is the mode where a model emits an internal reasoning trace before its visible
answer. baikai exposes it through one knob — `Options.thinking :: Maybe ThinkingLevel` —
and one content type — `Baikai.Content.ThinkingContent`. Today that surface is broken
end-to-end, as documented in `docs/reviews/2026-07-01-correctness-and-api-review.md`
(Theme 2):

1. A thinking-enabled Anthropic request with default `maxTokens` computes a `max_tokens`
   *above* the model's hard cap and gets an HTTP 400 back — thinking never works out of
   the box (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:559-567`).
2. The request always uses the fixed-budget thinking shape (`budget_tokens`), which
   current-generation Anthropic models (Opus 4.6 and later) deprecate or reject in
   favor of adaptive thinking (`Api.hs:650-655`).
3. Redacted thinking blocks (Anthropic's safety system replacing a trace with an opaque
   encrypted payload) are destroyed on receipt, so replaying the conversation corrupts
   multi-turn exchanges (`Api.hs:369-371,419-433,759-767`).
4. Thinking signatures (the opaque token Anthropic requires back on replay) are
   accumulated but replayed as `""` when absent, which Anthropic rejects.
5. On the OpenAI-compatible side, DeepSeek's `delta.reasoning_content` and OpenRouter's
   `delta.reasoning` are never parsed — `deepseek-reasoner` streams silently discard all
   reasoning output — and the `requiresThinkingAsText` compat flag documented in
   `baikai/src/Baikai/Compat.hs:114` drives no code (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:260-295`).

After this plan, a user can set `#thinking .~ Just ThinkingMedium` on any
reasoning-capable catalog model — `anthropic_claude_sonnet_4_5` (budget-era),
`anthropic_claude_opus_4_6` (adaptive-era), or `deepseek_deepseek_reasoner` — run a
request with otherwise-default options, receive typed `ThinkingStart`/`ThinkingDelta`/
`ThinkingEnd` events plus an `AssistantThinking` block in the terminal message, and
replay that assistant turn (signatures and redacted blocks verbatim) in a follow-up
request that the provider accepts. The proof is a live smoke case (Milestone 4) plus
unit and round-trip tests that fail on today's code.

This plan is EP-7 of the MasterPlan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`. It
hard-depends on `docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`
(EP-5), which reshapes the core event algebra so it can carry signatures, redacted
payloads, and the provider response id. See "Context and Orientation" for the exact
assumptions made about EP-5's shapes and how to reconcile them.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Verify EP-5 (`docs/plans/38-...md`) has landed; reconcile the payload-type names
      assumed in this plan against its Decision Log and update this plan if they differ.
      (2026-07-03)
- [x] M1: add `AnthropicThinkingStyle` and the `thinkingStyle` field to
      `AnthropicMessagesCompat` in `baikai/src/Baikai/Compat.hs`, with the
      model-generation default table `defaultAnthropicThinkingStyle`. (2026-07-03)
- [x] M1: apply the model-generation default in `anthropicMessagesCompatFor`
      (`baikai/src/Baikai/Model.hs`). (2026-07-03)
- [x] M1: rewrite the `max_tokens`/thinking region of `mapRequest` and `computeThinking`
      in `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (cap clamp, style selection,
      adaptive effort merged into `output_config`). (2026-07-03)
- [x] M1: request-mapping unit tests in `baikai-claude/test/ThinkingSpec.hs` covering
      every Anthropic catalog model. (2026-07-03)
- [x] M2: capture redacted `data_` at block start, close thinking blocks with full
      fidelity, add opened-index tracking to the Claude block state machine. (2026-07-03)
- [x] M2: replay signatures and redacted payloads verbatim in
      `assistantContentToBlock`; omit signature-less thinking blocks. (2026-07-03)
- [x] M2: round-trip tests (stream events → assembled message → `mapRequest` output).
      (2026-07-03)
- [ ] M3: parse `reasoning_content`/`reasoning` deltas and the message-object shape in
      `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`; thinking-block lifecycle in the
      OpenAI assembler.
- [ ] M3: implement the `<think>`-tag extraction transformer gated by
      `requiresThinkingAsText`; update the flag's haddock in `baikai/src/Baikai/Compat.hs`.
- [ ] M3: stream-assembly unit tests in `baikai-openai/test/ReasoningSpec.hs`.
- [ ] M4: live smoke cases (Anthropic budget model, Anthropic adaptive model,
      deepseek-reasoner) in `baikai-smoke/test/`, skipped without keys.
- [ ] M4: full validation sweep (`cabal build all --enable-tests`, all test suites,
      smoke with keys); record evidence here and in Outcomes & Retrospective.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Adding `AnthropicMessagesCompat.thinkingStyle` also required updating
  `baikai/gen/GenModels.hs`; `baikai`'s catalog regression test compiles and runs the
  generator and failed until the generator's parser/rendered import list learned the new
  field. Validation evidence after the fix: `cabal test baikai baikai-claude
  --test-show-details=direct` passed with `baikai` 116 tests and `baikai-claude` 98
  tests. (2026-07-03, M1 implementation)
- The Claude assembler already emitted EP-5's full `ThinkingEndPayload` for non-redacted
  thinking, so the signature fix was mostly preserving the existing closed
  `ThinkingContent` through replay. The missing piece was redacted block state: a
  separate `redactedBuf` lets redacted payloads close without pretending to be readable
  thinking text. Validation evidence: `cabal test baikai-claude --test-show-details=direct`
  passed with 102 tests. (2026-07-03, M2 implementation)


## Decision Log

- Decision: `max_tokens` never exceeds the catalog cap. The formula is: let
  `cap = model.maxOutputTokens`, `base = fromMaybe cap opts.maxTokens`; for budget-style
  thinking with budget `b`, send `max_tokens = min (base + b) cap`; without thinking (or
  with adaptive thinking, which has no budget) send `min base cap`. A `cap` of 0 (a
  hand-rolled `_Model`) means "unknown" and disables the clamp (send `base + b` / `base`
  unclamped). If after clamping `max_tokens <= b` (no room for any visible output — only
  possible when `cap <= b`), drop the thinking field entirely rather than send an
  invalid request.
  Rationale: the cap in `Baikai.Models.Generated` is the provider's hard maximum, so
  exceeding it is always a 400 (review Theme 2.1). Reserving the budget *inside* the cap
  when defaulting keeps default-options requests valid; adding the budget on top of an
  explicit caller `maxTokens` (then clamping) preserves the existing documented
  intent that callers state visible-output size and baikai does the thinking math.
  Anthropic requires `max_tokens > budget_tokens` strictly, hence the degrade-to-no-
  thinking guard, which mirrors the existing "non-reasoning model shapes the request
  without thinking" behavior in `computeThinking`.
  Date: 2026-07-01
- Decision: the knob selecting budget-style vs adaptive thinking is a new compat field,
  `thinkingStyle :: AnthropicThinkingStyle` on `Baikai.Compat.AnthropicMessagesCompat`,
  with constructors `AnthropicThinkingBudget | AnthropicThinkingAdaptive` and default
  `AnthropicThinkingBudget`. Because the style varies by model generation (not by host),
  the `CompatNone` projection `anthropicMessagesCompatFor` in `baikai/src/Baikai/Model.hs`
  overlays a model-id-keyed default (`defaultAnthropicThinkingStyle` in `Baikai.Compat`)
  on top of the host-level `autoDetectAnthropicMessages` result. An explicit
  `CompatAnthropicMessages` record on a model always wins.
  Rationale: the SDK offers exactly two shapes (`ThinkingAdaptive` and
  `ThinkingEnabled {budget_tokens}` in
  `Claude/V1/Messages.hs` of the MercuryTechnologies/claude package, verified at source);
  which one a model accepts is a property of the model generation, so a host-URL-only
  auto-detect cannot decide it, and a `Model` field would duplicate what the compat
  record already exists for. Keeping the table in `Baikai.Compat` next to the existing
  auto-detection keeps one home for quirk knowledge; naming follows the existing
  `ThinkingFormat*` style on the OpenAI side.
  Date: 2026-07-01
- Decision: model-generation default table: `AnthropicThinkingAdaptive` for model ids
  `claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8`, and `claude-fable-5`;
  `AnthropicThinkingBudget` for everything else (including `claude-opus-4-5`,
  `claude-sonnet-4-5`, `claude-sonnet-4-6`, `claude-haiku-4-5`). Whether
  `claude-sonnet-4-6` and `claude-fable-5` belong on the adaptive side must be verified
  against Anthropic's live API during Milestone 4 (the SDK haddock says adaptive is
  "Opus 4.6+" and budget is "deprecated on Opus 4.6"; the review says budget is
  *rejected* on the 4-7/4-8 era). Update the table and this entry with the verified
  answer.
  Date: 2026-07-01
- Decision: `ThinkingLevel` maps onto the two styles as follows. Budget style: the
  existing `thinkingTokenBudget` (1024/2048/8192/16384 for
  Minimal/Low/Medium/High, `baikai/src/Baikai/ThinkingLevel.hs:43-48`) is kept
  unchanged. Adaptive style: the request sends `thinking = ThinkingAdaptive` plus an
  effort hint through `output_config.effort` — `ThinkingMinimal` and `ThinkingLow` map
  to `"low"`, `ThinkingMedium` to `"medium"`, and `ThinkingHigh` omits the effort field
  (the SDK documents `"high"` as equivalent to omission). The effort hint merges into
  the same `Messages.OutputConfig` that `responseFormat` uses; when both are present one
  merged record is sent.
  Rationale: adaptive thinking has no budget parameter; the SDK's `effortConfig` /
  `OutputConfig.effort` is the documented depth control for adaptive models. There is no
  `"minimal"` effort value, so Minimal collapses into `"low"`.
  Date: 2026-07-01
- Decision: the opaque payload of a redacted thinking block is carried in the *existing*
  `thinking` field of `Baikai.Content.ThinkingContent`, with `redacted = True` and
  `signature = Nothing`; no new field is added. The haddock on `ThinkingContent`
  (`baikai/src/Baikai/Content.hs:68-78`) is updated to document this: when `redacted`
  is `True`, `thinking` holds the provider's encrypted payload verbatim and must not be
  displayed or edited.
  Rationale: a redacted block never has readable text, so the field is otherwise dead;
  reusing it keeps the JSON wire shape of `ThinkingContent` stable and avoids a second
  core-record change on top of EP-5's event-algebra reshaping (EP-5 owns
  `baikai/src/Baikai/Stream.hs` and the event payloads; minimizing this plan's core
  footprint reduces cross-plan churn). The alternative — a `redactedData :: Maybe Text`
  field — was rejected as a breaking core change buying only documentation clarity.
  Date: 2026-07-01
- Decision: on replay, `assistantContentToBlock` emits `Content_Redacted_Thinking
  {data_}` for redacted blocks, `Content_Thinking {thinking, signature}` for blocks with
  `signature = Just s` (verbatim, never `""`), and *omits* a non-redacted thinking block
  whose signature is `Nothing` (returns `Nothing`).
  Rationale: Anthropic validates signatures; sending `signature = ""` is a guaranteed
  400 (review Theme 2.3). After this plan the provider always populates signatures on
  blocks it produces, so omission only affects hand-constructed content, where dropping
  the un-replayable block is strictly better than failing the whole request.
  Date: 2026-07-01
- Decision: `delta.reasoning_content` (DeepSeek) and `delta.reasoning` (OpenRouter,
  string-valued only) are parsed *unconditionally* — presence of the field is
  self-describing and harmless on hosts that never send it. The same two keys are also
  read off `choices[0].message` (the non-delta "whole message" shape some compatible
  hosts emit as a single chunk). The `requiresThinkingAsText` compat flag gates the
  *other* extraction mechanism: scanning assistant text deltas for in-band
  `<think>...</think>` / `<thinking>...</thinking>` markers (the shape its haddock
  describes), which R1-style models emit through hosts that do not split reasoning into
  a separate field. DeepSeek keeps `requiresThinkingAsText = True` (harmless when the
  field-based path already fired; text from `api.deepseek.com` contains no such tags).
  The flag's haddock in `baikai/src/Baikai/Compat.hs:109-114` is updated to describe the
  now-real transformer, and the MasterPlan's Decision Log entry ("`requiresThinkingAsText`
  is wired by EP-7") is thereby satisfied — EP-8
  (`docs/plans/41-implement-compat-quirks-and-transport-options.md`) must not delete it.
  Date: 2026-07-01
- Decision: while rewriting the Claude block state machine, add opened-index tracking:
  a `content_block_delta` or `content_block_stop` for an index that never received a
  `content_block_start` is dropped (no event, no state change), instead of today's
  behavior where `IntMap.insertWith` fabricates a buffer and `handleBlockStop` closes it
  as a phantom tool call with empty id/name (`Api.hs:383-407,434-457`).
  Rationale: review Theme 2-adjacent finding; the fix is one membership check per
  branch and the state machine is being rewritten anyway.
  Date: 2026-07-01
- Decision: this plan is written against EP-5 shapes that do not exist yet
  (`docs/plans/38-...` was a skeleton at authoring time). Assumed, per the MasterPlan's
  Integration Points section: (a) `ThinkingEnd` carries the full
  `Baikai.Content.ThinkingContent` (signature and redacted flag) rather than bare text;
  (b) a carriage mechanism for the provider message id exists on `StartPayload` or the
  terminal payload; (c) the reassembler in `baikai/src/Baikai/Stream.hs` treats the
  terminal event's message as authoritative for block content. The first Progress item
  is to reconcile these assumptions against EP-5's landed code; any divergence is
  recorded here and in EP-5's Decision Log.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 completed on 2026-07-03. Claude request shaping now selects
budget-style or adaptive thinking from `AnthropicMessagesCompat.thinkingStyle`, applies
model-generation defaults for first-party Anthropic models, clamps `max_tokens` to the
catalog cap, drops invalid budget requests when no visible-output room remains, and
merges adaptive effort into an existing `output_config`. The focused validation was:

```text
cabal test baikai baikai-claude --test-show-details=direct
baikai: 116 tests passed
baikai-claude: 98 tests passed
```

Milestone 2 completed on 2026-07-03. Claude streaming now preserves signed thinking and
redacted thinking as full `ThinkingContent` values, replay emits signed thinking and
redacted payloads verbatim while omitting unsigned hand-built thinking, and unopened
deltas no longer fabricate phantom tool calls. Focused validation:

```text
cabal test baikai-claude --test-show-details=direct
baikai-claude: 102 tests passed
```


## Context and Orientation

baikai is a multi-package Haskell library (built with `cabal`, GHC2021-era style, lens
via `Data.Generics.Labels` `#field` labels) that gives one vocabulary — `Model`,
`Context`, `Options`, `Response`, a streaming event algebra — over multiple LLM
providers. The packages touched here:

- `baikai/` — the core. `baikai/src/Baikai/Content.hs` defines the typed content
  blocks, including `ThinkingContent {thinking, signature, redacted}`.
  `baikai/src/Baikai/ThinkingLevel.hs` defines the provider-agnostic
  `ThinkingLevel = ThinkingMinimal | ThinkingLow | ThinkingMedium | ThinkingHigh` and
  `thinkingTokenBudget`. `baikai/src/Baikai/Compat.hs` defines per-API compat records
  (`OpenAICompletionsCompat`, `AnthropicMessagesCompat`) plus baseUrl auto-detection;
  `baikai/src/Baikai/Model.hs` holds the `Compat` sum (`CompatNone | ...`) and the
  projections `openaiCompletionsCompatFor` / `anthropicMessagesCompatFor` (CompatNone →
  auto-detect from `baseUrl`). `baikai/src/Baikai/Models/Generated.hs` is the generated
  model catalog; every Anthropic model there has `reasoning = True`, `compat =
  CompatNone`, and a hard `maxOutputTokens` cap (e.g. `claude-haiku-4-5` → 64000,
  `claude-opus-4-6` → 128000). `baikai/src/Baikai/Stream/Event.hs` is the event algebra
  (`EventStart`, `ThinkingStart/Delta/End`, `EventDone`/`EventError`, ...);
  `baikai/src/Baikai/Stream.hs` reassembles events into a `Response` and derives every
  provider's blocking `complete` from its stream (`streamingComplete`) — so any fidelity
  lost in stream assembly is lost on the blocking path too.
- `baikai-claude/` — the Anthropic Messages provider.
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs` contains `mapRequest` (baikai →
  SDK request), a per-call `Assembler` state machine translating the SDK's typed
  streaming events into baikai events (`handleBlockStart`/`handleBlockDelta`/
  `handleBlockStop`, `translate`), and the replay direction
  (`mapMessage`/`assistantContentToBlock`). It builds on the MercuryTechnologies
  `claude` SDK (source at `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/`,
  discoverable via `mori registry show MercuryTechnologies/claude --full`).
- `baikai-openai/` — the OpenAI Chat Completions provider.
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` deliberately parses raw JSON chunks
  (`parseChunk`, `RawChunk`) instead of the SDK's typed chunk, feeding its own
  `Assembler`. The same handler serves DeepSeek, OpenRouter, Together, etc. — per-host
  differences are meant to be expressed through `OpenAICompletionsCompat`.
- `baikai-smoke/` — live end-to-end tests (`test-suite baikai-smoke`, main
  `baikai-smoke/test/Smoke.hs`) that skip per-case when the relevant API-key env vars
  are unset (`firstSetEnv` over candidates like `["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]`).

Terms of art used below:

- *Extended thinking / reasoning*: the model emits an internal reasoning trace before
  its answer. Anthropic delivers it as `thinking` content blocks in the stream; DeepSeek
  and OpenRouter deliver it as an extra string field on the streamed delta
  (`reasoning_content` / `reasoning`); some hosts inline it into the assistant text
  between `<think>`/`<thinking>` tags.
- *Budget vs adaptive*: Anthropic's request field `thinking` takes either
  `{"type":"enabled","budget_tokens":N}` (a fixed token budget; the classic shape) or
  `{"type":"adaptive"}` (the model decides; Opus 4.6+; depth guided by
  `output_config.effort`). The SDK models this as
  `data Thinking = ThinkingAdaptive | ThinkingEnabled {budget_tokens :: Natural}`
  (`claude/src/Claude/V1/Messages.hs:865-886` in the SDK checkout) and provides
  `effortConfig :: Text -> OutputConfig` (`:745`).
- *Signature*: an opaque token streamed at the tail of a thinking block via
  `signature_delta` events. Anthropic validates it when a thinking block is replayed in
  a later request; a wrong or empty signature is a 400.
- *Redacted thinking*: Anthropic's safety system sometimes replaces a thinking block
  with `{"type":"redacted_thinking","data":"<ciphertext>"}`. The SDK's shapes are
  `ContentBlock_Redacted_Thinking {data_ :: Text}` (response direction,
  `Messages.hs:494`) and `Content_Redacted_Thinking {data_ :: Text}` (request/replay
  direction, `Messages.hs:271`). The payload arrives complete on `content_block_start`
  — redacted blocks stream no deltas — and must be replayed verbatim.

The concrete defects, with current code:

*Defect 1 — over-cap `max_tokens`* (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:559-567`):

```haskell
baseTokens = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
...
maxTokensField_ = case thinkingField of
  Just (Messages.ThinkingEnabled budget) -> baseTokens + budget
  _ -> baseTokens
```

`m ^. #maxOutputTokens` is the *hard cap* from the catalog, so with default options and
`ThinkingHigh` on `claude-haiku-4-5` the request sends `max_tokens = 64000 + 16384 =
80384 > 64000` → HTTP 400 on every default-options thinking request.

*Defect 2 — always budget-style* (`Api.hs:650-655`): `computeThinking` unconditionally
produces `ThinkingEnabled {budget_tokens = thinkingTokenBudget lvl}`. `budget_tokens`
is deprecated on Opus 4.6 and rejected by the 4.7/4.8-era models, yet the catalog
registers all of them `reasoning = True`, so a user picking `anthropic_claude_opus_4_7`
gets a 400 (or deprecation behavior) instead of thinking. `ThinkingAdaptive` exists in
the SDK and is never used.

*Defect 3 — redacted thinking destroyed* (`Api.hs:369-371,419-433,759-767`): at block
start the `data_` payload is discarded (the redacted branch is identical to the plain
thinking branch and just opens an empty text buffer); at block stop it closes as
`ThinkingContent {thinking = "", signature = Nothing, redacted = False}`; and on replay
`assistantContentToBlock` has no `Content_Redacted_Thinking` case at all. A multi-turn
conversation containing a redacted block replays as an empty fake thinking block with
an empty signature — corrupt, and rejected.

*Defect 4 — signature fidelity*: `handleBlockDelta` does accumulate `signature_delta`
into `thinkSig` (`Api.hs:397-403`) and `handleBlockStop` attaches it to the closed
block, but (a) the `ThinkingEnd` event today carries only bare text
(`BlockEndPayload {contentIndex, content :: Text}`), so the core reassembler used by
the blocking path rebuilds thinking blocks with `signature = Nothing` — that carriage
gap is EP-5's to fix, and this plan's job is to *emit* the full `ThinkingContent`
through EP-5's reshaped `ThinkingEnd`; and (b) on replay `assistantContentToBlock`
sends `signature = fromMaybe "" (Content.signature th)` (`Api.hs:766`) — an empty
signature Anthropic rejects.

*Defect 5 — OpenAI-compatible reasoning never extracted*
(`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:260-295`): `parseChunk` reads only
`delta.content`, `delta.tool_calls`, `finish_reason`, and `usage`. DeepSeek streams the
trace as `delta.reasoning_content` and OpenRouter as `delta.reasoning`; both are
dropped on the floor, so a `deepseek-reasoner` stream yields no `Thinking*` events and
the final message contains no `AssistantThinking` block. The compat flag
`requiresThinkingAsText` (`baikai/src/Baikai/Compat.hs:114`, set `True` for DeepSeek at
`:188`) promises a transformer that "extracts those markers into typed thinking deltas"
— grep confirms no provider code consumes the flag.

*Adjacent defect — phantom blocks* (`Api.hs:383-407,434-457`): `handleBlockDelta` uses
`IntMap.insertWith` so a delta for a never-opened index silently creates a buffer, and
`handleBlockStop`'s tool branch falls back to `("", "")` metadata — a stray delta
fabricates a tool call with empty id and name.

Dependency status and assumptions. This plan hard-depends on EP-5
(`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`). At the
time this plan was authored, that file was a skeleton, so the exact payload type names
below are assumptions taken from the MasterPlan's Integration Points section and MUST
be reconciled against EP-5's landed code before starting (first Progress item):
`ThinkingEnd` carries the full `ThinkingContent`; the provider message id has a
carriage field (this plan fills it from Anthropic's `message_start.message.id`, which
the assembler already stores in `Assembler.responseId`, `Api.hs:327`); the reassembler
treats the terminal message as authoritative. Where this plan says "EP-5's
`ThinkingEnd` payload", substitute the real constructor/field names from that file.
This plan also soft-depends on EP-6 (`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`):
if EP-6 has landed, acceptance tests may assert typed `BaikaiError` categories; if not,
string assertions on `errorMessage` are acceptable and noted as such in the tests.

Integration boundary with EP-8: this plan owns the thinking/`max_tokens` region of
`mapRequest` in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`;
`docs/plans/41-implement-compat-quirks-and-transport-options.md` owns tools,
`tool_choice`, `cache_control`, and header shaping in the same function and runs after
this plan. Do not modify those regions here; EP-8 must not modify this plan's regions
(or delete the `requiresThinkingAsText` flag) without Decision Log entries in both
plans.


## Plan of Work

The work is four milestones: (1) the Anthropic request side, (2) the Anthropic
stream/replay side, (3) the OpenAI-compatible extraction side, (4) live proof. Each is
independently buildable and testable.

### Milestone 1 — Claude request shaping: cap-safe `max_tokens` and per-generation thinking style

Scope: after this milestone, `mapRequest` in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` produces a `max_tokens` that never
exceeds the model's catalog cap, selects `ThinkingAdaptive` vs `ThinkingEnabled` per
model generation, and expresses adaptive depth through `output_config.effort`. Unit
tests pin the arithmetic for every Anthropic model in the catalog.

Work, in order:

First, in `baikai/src/Baikai/Compat.hs`, add the style type and field:

```haskell
-- | Which request shape the Anthropic-compatible host/model accepts
-- for extended thinking. Budget-era models (Sonnet/Haiku 4.5-era and
-- earlier) take @{"type":"enabled","budget_tokens":N}@; adaptive-era
-- models (Opus 4.6 and later) take @{"type":"adaptive"}@ with depth
-- guided by @output_config.effort@ and reject a budget.
data AnthropicThinkingStyle
  = AnthropicThinkingBudget
  | AnthropicThinkingAdaptive
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Add `thinkingStyle :: !AnthropicThinkingStyle` to `AnthropicMessagesCompat`, defaulting
to `AnthropicThinkingBudget` in `defaultAnthropicMessagesCompat`, and export the type,
its constructors, and a new function:

```haskell
-- | The thinking style a first-party Anthropic model id defaults to
-- when the model carries no explicit compat record. Keyed on the bare
-- model id; unknown ids default to the budget style (universally
-- accepted before the 4.6 generation, still accepted with a
-- deprecation on 4.6).
defaultAnthropicThinkingStyle :: Text -> AnthropicThinkingStyle
```

implemented as a case over the adaptive-era ids (`claude-opus-4-6`, `claude-opus-4-7`,
`claude-opus-4-8`, `claude-fable-5`, plus any date-suffixed variants — match on the
prefix, e.g. `"claude-opus-4-6" isPrefixOf modelId`), everything else budget. Per the
Decision Log, the exact membership of `claude-sonnet-4-6` and `claude-fable-5` is
verified in Milestone 4. Update the existing compat tests (search
`baikai/test/` for the spec asserting `defaultAnthropicMessagesCompat` fields) so the
new field is covered.

Second, in `baikai/src/Baikai/Model.hs`, change `anthropicMessagesCompatFor` so the
`CompatNone` branch overlays the model-generation default:

```haskell
anthropicMessagesCompatFor :: Model -> AnthropicMessagesCompat
anthropicMessagesCompatFor m = case compat m of
  CompatAnthropicMessages c -> c
  _ ->
    (autoDetectAnthropicMessages (baseUrl m))
      { thinkingStyle = defaultAnthropicThinkingStyle (modelId m) }
```

(keeping whatever the current fall-through branch structure is; the point is only that
an explicit record wins and `CompatNone` gets both host- and generation-aware
defaults).

Third, in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, replace `computeThinking`
with a function returning both the thinking field and the effort hint, and rewrite the
`max_tokens` computation in `mapRequest` (`:559-567`) per the Decision Log formula:

```haskell
-- | The resolved thinking configuration for one request: the SDK
-- thinking field, the effort hint for output_config (adaptive style
-- only), and the budget that participates in max_tokens arithmetic
-- (budget style only).
data ThinkingPlan = ThinkingPlan
  { field :: !(Maybe Messages.Thinking),
    effort :: !(Maybe Text),
    budget :: !(Maybe Natural)
  }

computeThinking ::
  AnthropicMessagesCompat -> Model -> Maybe ThinkingLevel -> ThinkingPlan
```

Behavior: `Nothing` level, or `reasoning = False` on the model, yields the empty plan
(all `Nothing` — unchanged degrade semantics). Budget style yields
`field = Just (Messages.ThinkingEnabled (thinkingTokenBudget lvl))`,
`budget = Just (thinkingTokenBudget lvl)`, `effort = Nothing`. Adaptive style yields
`field = Just Messages.ThinkingAdaptive`, `budget = Nothing`, and
`effort = Just "low"` / `Just "medium"` / `Nothing` per the Decision Log mapping. In
`mapRequest`:

```haskell
let cap = m ^. #maxOutputTokens
    base = fromMaybe cap (opts ^. #maxTokens)
    clamp n = if cap == 0 then n else min n cap
    plan0 = computeThinking compat m (opts ^. #thinking)
    requested = clamp (base + fromMaybe 0 (plan0 ^. #budget))
    -- No room for visible output beside the budget: drop thinking.
    plan
      | Just b <- plan0 ^. #budget, requested <= b = emptyThinkingPlan
      | otherwise = plan0
    maxTokensField_ = case plan ^. #budget of
      Just b -> clamp (base + b)
      Nothing -> clamp base
```

and merge `plan ^. #effort` into `outputConfigField`: when `responseFormat` produced an
`OutputConfig`, set its `effort` field; when it did not and `effort` is `Just e`, send
`Messages.effortConfig e`; when both are absent, send `Nothing`. Do not touch the
tools/cache_control/tool_choice lines (EP-8's region).

Fourth, tests. Create `baikai-claude/test/ThinkingSpec.hs`, register it in
`baikai-claude/baikai-claude.cabal`'s `test-suite baikai-claude-test` `other-modules`
and in `baikai-claude/test/Main.hs` beside `ErrorClassSpec`. `mapRequest` is already
exported. Cover, for *every* Anthropic model exported from
`Baikai.Models.Generated` (enumerate them in the spec — `anthropic_claude_fable_5`,
`anthropic_claude_haiku_4_5`, `anthropic_claude_opus_4_5`, `anthropic_claude_opus_4_6`,
`anthropic_claude_opus_4_7`, `anthropic_claude_opus_4_8`,
`anthropic_claude_sonnet_4_5`, `anthropic_claude_sonnet_4_6`) and every
`ThinkingLevel`: (a) `Messages.max_tokens` of the mapped request never exceeds
`maxOutputTokens`; (b) budget-era models get `ThinkingEnabled` with the
`thinkingTokenBudget` value and `max_tokens > budget_tokens`; (c) adaptive-era models
get `ThinkingAdaptive`, no budget added to `max_tokens`, and the expected
`output_config.effort`; (d) explicit `opts.maxTokens` participates as
`min (maxTokens + budget) cap`; (e) a hand-rolled model with `maxOutputTokens = 0` is
not clamped; (f) a cap at-or-below the budget drops the thinking field; (g)
`responseFormat = Just (JsonSchema ...)` combined with adaptive thinking produces one
merged `output_config` carrying both the schema and the effort; (h) an explicit
`CompatAnthropicMessages` record with `thinkingStyle = AnthropicThinkingAdaptive`
overrides a budget-era default. Test (a) fails against today's code (that is the
point); write it first and watch it fail.

Acceptance: `cabal build baikai baikai-claude` succeeds;
`cabal test baikai baikai-claude` passes with the new spec listed in the output; the
pre-fix failure of test (a) is recorded in Surprises & Discoveries or the commit
message.

### Milestone 2 — Claude stream fidelity and verbatim replay

Scope: after this milestone the Claude assembler carries redacted payloads and
signatures into the closed blocks and the EP-5 event shapes, replay reproduces both
verbatim, and stray deltas can no longer fabricate blocks. A round-trip test proves
"streamed events → assembled message → `mapRequest` on a follow-up context" preserves
signature and redacted payload byte-for-byte.

Work, in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:

Redacted capture. In `handleBlockStart` (`:369-371`), the
`Messages.ContentBlock_Redacted_Thinking` case must bind the payload
(`Messages.ContentBlock_Redacted_Thinking {Messages.data_ = payload}` — field verified
in the SDK at `claude/src/Claude/V1/Messages.hs:494`) and store it in a new assembler
map `redactedBuf :: !(IntMap Text)` (add to `Assembler` and `emptyAssembler`), still
emitting `ThinkingStart`. In `handleBlockStop`, add a branch (checked before the plain
`thinkBuf` branch) that closes a redacted index as
`Content.AssistantThinking Content.ThinkingContent {thinking = payload, signature =
Nothing, redacted = True}` and emits `ThinkingEnd` with EP-5's payload carrying that
full `ThinkingContent`. Redacted blocks stream no thinking deltas, so no delta-branch
change is needed beyond the opened-index tracking below.

Signature emission. In `handleBlockStop`'s thinking branch (`:419-433`), the closed
block already gets the accumulated signature; change the emitted `ThinkingEnd` to carry
the same full `ThinkingContent` through EP-5's payload (today it carries only the bare
text). Keep the existing "empty accumulated signature becomes `Nothing`" rule.

Opened-index tracking. Make `handleBlockDelta` (`:383-407`) drop any delta whose index
has no live buffer of the matching kind: text deltas require `IntMap.member i textBuf`,
thinking and signature deltas require membership in `thinkBuf`, input-JSON deltas
require membership in `toolArgsBuf`. Replace every `IntMap.insertWith` with
`IntMap.adjust` (which is a no-op on absent keys) and return `([], ass)` when the key
is absent, so an unopened index produces neither an event nor state.
`handleBlockStop`'s tool branch keeps its `toolMeta` lookup, but the `("", "")`
fallback becomes unreachable for fabricated indices (a tool buffer now only exists if
`Content_Block_Start` created it together with its metadata); leave the fallback in
place as defensive code with a comment saying why it is believed unreachable.

Response id. Fill EP-5's provider-message-id carriage field from
`Assembler.responseId` (already populated from `message_start` at `:327`) at whichever
emission point EP-5 defined (the `EventStart` payload or the terminal payload) —
reconcile with the landed EP-5 code.

Replay. Rewrite `assistantContentToBlock` (`:758-775`) per the Decision Log:

```haskell
Content.AssistantThinking th
  | Content.redacted th ->
      Just Messages.Content_Redacted_Thinking {Messages.data_ = Content.thinking th}
  | Just sig <- Content.signature th ->
      Just Messages.Content_Thinking
        { Messages.thinking = Content.thinking th, Messages.signature = sig }
  | otherwise -> Nothing
```

Also update the `ThinkingContent` haddock in `baikai/src/Baikai/Content.hs:68-78` to
document the redacted-payload reuse of the `thinking` field (core change; one comment
edit, no field change).

Tests, in `baikai-claude/test/ThinkingSpec.hs` (same module as Milestone 1, new
`describe` groups). Drive the exported pieces directly — if `translate`,
`handleBlockStart`/`Delta`/`Stop`, `emptyAssembler`, or `finalMessage` are not
exported, add them to the export list of `Baikai.Provider.Claude.Api` with a haddock
note that they are test seams (EP-10, `docs/plans/43-...md`, will namespace internals
later). Cover: (a) a synthetic event sequence `message_start → content_block_start
(thinking) → thinking_delta* → signature_delta* → content_block_stop → message_delta →
message_stop` closes an `AssistantThinking` block whose `signature` is the
concatenated signature deltas and whose `ThinkingEnd` event carries the full
`ThinkingContent`; (b) the same with `content_block_start (redacted_thinking, data_ =
"ENCRYPTED==")` and no deltas closes `ThinkingContent {thinking = "ENCRYPTED==",
signature = Nothing, redacted = True}`; (c) round-trip: take the assembled
`AssistantMessage` from (a)+(b), place it in a `Context` as a prior turn, run
`mapRequest`, and assert the produced `Messages.Content_Thinking` carries the exact
signature and the `Messages.Content_Redacted_Thinking` carries the exact payload —
compare on the rendered `Aeson.encode` of the message vector to catch any silent
field-dropping; (d) a hand-built `AssistantThinking` with `signature = Nothing,
redacted = False` is omitted from the mapped request (and the request still succeeds
in mapping); (e) a `thinking_delta` and an `input_json_delta` for an index that was
never opened produce no events and no closed blocks (this fails today by fabricating
a phantom tool call with empty id).

Acceptance: `cabal test baikai-claude` passes; test (e) demonstrably fails before the
opened-index change and passes after.

### Milestone 3 — OpenAI-compatible reasoning extraction

Scope: after this milestone a `deepseek-reasoner` or OpenRouter reasoning stream
produces `ThinkingStart`/`ThinkingDelta`/`ThinkingEnd` events and an
`AssistantThinking` block in the terminal message, and the `requiresThinkingAsText`
flag gates a real in-band `<think>`-tag extractor.

Work, in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`:

Chunk parsing. Extend `RawChunk` with `reasoningDelta :: !(Maybe Text)`. In
`parseChunk` (`:260-295`), inside the `firstChoice` handling: from the `delta` object
read, in priority order, `reasoning_content` then `reasoning`, accepting only JSON
string values (a non-string `reasoning` — OpenRouter can emit structured
`reasoning_details` — is ignored on this revision; record in the Decision Log if that
ever needs parsing). Additionally, when the choice has no usable `delta`, read the same
two keys plus `content` off a `message` object if present (`ch .:? "message"`), so
hosts that answer a streaming request with a single whole-message chunk still yield
both the reasoning and the text. Exactly these JSON paths are read, no others:
`choices[0].delta.reasoning_content`, `choices[0].delta.reasoning`,
`choices[0].message.reasoning_content`, `choices[0].message.reasoning`.

Assembly. Extend the OpenAI `Assembler` (around `:447-475`) with `reasoningOpen ::
!(Maybe Int)` and `reasoningAccum :: !Text`. Add an `applyReasoningDelta` step to
`translate`, ordered *before* `applyContentDelta`: a first reasoning delta opens a
thinking block at `nextContentIndex` (emitting `ThinkingStart`), subsequent ones emit
`ThinkingDelta` and accumulate; the first regular content delta (or tool delta, or
`finish_reason`) after an open reasoning block closes it — emitting `ThinkingEnd` with
EP-5's full-`ThinkingContent` payload, `signature = Nothing`, `redacted = False` — and
inserts `Content.AssistantThinking` into `closed`. This matches the wire order DeepSeek
uses (all reasoning first, then content). `closeOnFinish` and `closeOpenStream` must
also close a dangling open reasoning block so an early-terminated stream still
surfaces the partial trace.

Thinking-as-text transformer. Add a pure incremental scanner:

```haskell
-- | Incremental scanner splitting assistant text into visible text
-- and in-band reasoning delimited by <think>/<thinking> tags, safe
-- across chunk boundaries (a tag may arrive split over deltas).
data TagScanState
scanThinkTags :: TagScanState -> Text -> (TagScanState, [Either Text Text])
```

(`Left` = reasoning fragment, `Right` = visible-text fragment; hold back a trailing
prefix of a potential opening/closing tag until disambiguated; a stream ending inside
an unclosed tag flushes what it has as reasoning). Wire it into `applyContentDelta`
only when `requiresThinkingAsText (openaiCompletionsCompatFor m)` is `True` (the
compat record is already computed in `mapRequest`; thread it, or recompute it, into
the assembler state at construction in `openaiChatStream`). Reasoning fragments route
through the same open/close logic as field-based reasoning deltas; visible fragments
continue into the text block. Update the flag's haddock in
`baikai/src/Baikai/Compat.hs:109-114`: field-based extraction is unconditional; the
flag enables tag scanning; the "(The transformer itself is wired in by EP-3; EP-5 only
flips the switch.)" sentence is replaced with a pointer to this plan.

Replay note: do not replay `AssistantThinking` blocks to OpenAI-compatible hosts —
DeepSeek documents that `reasoning_content` must not be sent back. Inspect the OpenAI
`mapMessage`/assistant-content path in the same file; if it currently drops thinking
blocks on replay, add a test pinning that; if it errors or sends them, make it drop
them silently and record the behavior in the Decision Log.

Tests. Create `baikai-openai/test/ReasoningSpec.hs` (register in
`baikai-openai/baikai-openai.cabal` and `test/Main.hs`; export `parseChunk`,
`translate`, `emptyAssembler`, and the scanner from `Baikai.Provider.OpenAI.Api` as
test seams if needed). Cover: (a) `parseChunk` on a verbatim DeepSeek-shaped chunk
(`{"choices":[{"delta":{"reasoning_content":"because..."}}]}`) and an
OpenRouter-shaped one (`"reasoning"`) yields `reasoningDelta = Just ...`; (b) a chunk
sequence of two reasoning deltas, two content deltas, and a `finish_reason` assembles
to events `EventStart?, ThinkingStart(0), ThinkingDelta×2, ThinkingEnd(0),
TextStart(1), TextDelta×2, TextEnd(1), EventDone` with the terminal message containing
`AssistantThinking` then `AssistantText` in that order; (c) the message-object
(non-delta) shape yields the same terminal blocks; (d) `scanThinkTags` unit tests
including a `<think>` tag split across three deltas (`"<th"`, `"ink>reasoning</thi"`,
`"nk>answer"`) and text containing a literal `<` that is not a tag; (e) with a compat
record where `requiresThinkingAsText = False`, tagged text passes through as plain
text unchanged.

Acceptance: `cabal test baikai-openai` passes; test (b) fails before the change
(no `Thinking*` events at all) and passes after.

### Milestone 4 — Live proof and validation sweep

Scope: a smoke module exercising thinking against real providers, plus the full-repo
validation commands. This is where the adaptive/budget model table (Decision Log) is
verified against reality.

Work: add `baikai-smoke/test/ThinkingSmoke.hs`, register it in
`baikai-smoke/baikai-smoke.cabal` `other-modules`, and call it from
`baikai-smoke/test/Smoke.hs` following the existing `ApiCase` pattern (`caseLabel`,
`caseEnvVars`, `caseModel`, skip with a stderr note when no env var from the candidate
list is set). Three cases:

1. `claude-sonnet-4-5` (budget style) with env candidates
   `["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]`, `#thinking .~ Just ThinkingLow`,
   default `maxTokens`. Assert: the response's stop reason is not `ErrorReason`; the
   content contains at least one `AssistantThinking` block with non-empty `thinking`,
   `redacted = False`, and `signature = Just _`; then build a second `Context`
   appending the returned assistant message and a follow-up user message, call again,
   and assert the second response also succeeds — this is the "replay accepted" proof.
2. `claude-opus-4-6` (adaptive style), same key candidates, `Just ThinkingMedium`,
   same assertions. If Anthropic rejects the shape chosen for this model (or for
   `claude-sonnet-4-6` / `claude-fable-5` if spot-checked), fix
   `defaultAnthropicThinkingStyle` and update the Decision Log entry — that
   verification is this case's purpose.
3. `deepseek-reasoner` with env candidates `["DEEPSEEK_KEY", "DEEPSEEK_API_KEY"]`
   (match the env-name convention used elsewhere in `Smoke.hs`; add the model via
   `Models.deepseek_deepseek_reasoner`), `Just ThinkingMedium`. Assert at least one
   `AssistantThinking` block with non-empty text arrives, and that the visible answer
   text is also non-empty (proving reasoning was separated from, not confused with,
   content).

Acceptance: the commands in "Validation and Acceptance" all pass; smoke output shows
the three cases running (or explicitly skipping) with their labels.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Before starting, reconcile the EP-5 assumption:

```bash
sed -n '1,120p' docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md
grep -n "ThinkingEnd\|responseId" baikai/src/Baikai/Stream/Event.hs
```

If `ThinkingEnd`'s payload does not carry a `ThinkingContent`, stop and resolve with
EP-5 first (Decision Log entries in both plans).

Read the SDK's thinking and redacted types before editing (the checkout lives at the
path `mori registry show MercuryTechnologies/claude --full` reports; currently
`/Users/shinzui/Keikaku/hub/haskell/claude-project`):

```bash
grep -n "data Thinking\|ThinkingAdaptive\|Content_Redacted_Thinking\|ContentBlock_Redacted_Thinking\|effortConfig" \
  /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1/Messages.hs
```

Per-milestone loop (edit, then):

```bash
cabal build baikai baikai-claude baikai-openai --enable-tests
cabal test baikai baikai-claude baikai-openai
```

Expected test transcript shape (exact counts will differ):

```text
Running 1 test suites...
Test suite baikai-claude-test: RUNNING...
ThinkingSpec
  mapRequest max_tokens
    never exceeds the catalog cap for any Anthropic model [✔]
...
All N tests passed
```

Final sweep (Milestone 4), with keys exported in the environment:

```bash
cabal build all --enable-tests
cabal test baikai baikai-claude baikai-openai
ANTHROPIC_API_KEY=... DEEPSEEK_API_KEY=... cabal test baikai-smoke
```

Without keys, `cabal test baikai-smoke` must still pass, printing per-case skip lines
such as:

```text
[baikai-smoke] none of ["DEEPSEEK_KEY","DEEPSEEK_API_KEY"] set; skipping deepseek-reasoner-thinking.
```

Commit per milestone with conventional-commit messages, e.g.:

```text
fix(claude): clamp thinking max_tokens at the model cap and select adaptive style per generation
```

Update the Progress checklist at every stopping point.


## Validation and Acceptance

Behavioral acceptance, in order of increasing integration:

1. Unit (fails before, passes after): in `baikai-claude/test/ThinkingSpec.hs`,
   `mapRequest anthropic_claude_haiku_4_5 ctx (opts & #thinking ?~ ThinkingHigh)` with
   default `maxTokens` yields `Messages.max_tokens = 64000` (the cap), not `80384`; the
   same call on `anthropic_claude_opus_4_6` yields `thinking = Just ThinkingAdaptive`
   with `output_config.effort` unset-or-merged per level, and `max_tokens = 128000`.
2. Round-trip (fails before, passes after): assembling a synthetic stream containing a
   signed thinking block and a redacted block, then mapping a follow-up request,
   reproduces `"signature":"<exact>"` and `{"type":"redacted_thinking","data":"<exact>"}`
   in the encoded request JSON. Before the fix the signature is lost on the blocking
   path and the redacted block degrades to an empty non-redacted one.
3. Stream assembly (fails before, passes after): feeding DeepSeek-shaped
   `reasoning_content` chunks through the OpenAI translator yields `Thinking*` events
   and an `AssistantThinking` terminal block; before the fix it yields nothing.
4. Phantom-block regression: a delta for an unopened index yields no events and no
   closed content; before the fix it closes a tool call with empty id/name.
5. Live (requires keys, otherwise skipped): the three `ThinkingSmoke` cases pass —
   thinking blocks with signatures on Anthropic (both styles), a successful replay
   turn, and extracted reasoning on deepseek-reasoner.

Exact commands: `cabal test baikai` (compat field + defaults), `cabal test
baikai-claude`, `cabal test baikai-openai`, and `cabal test baikai-smoke` (with
`ANTHROPIC_API_KEY` and `DEEPSEEK_API_KEY` exported for the live pass). "Pass" means
the suite prints `All N tests passed` (hspec) / exits zero; smoke additionally prints
each case label with a success or an explicit skip line. If EP-6 has landed, tests
that provoke request failures should assert on `responseError`/`BaikaiError`
categories; otherwise assert on `errorMessage` text and leave a `-- EP-6:` comment.


## Idempotence and Recovery

Every step is an ordinary source edit plus `cabal build`/`cabal test`; all are safe to
re-run. No migrations, no destructive commands. The milestones are independently
committable — if Milestone 2 stalls, Milestone 1's cap fix already stands alone (any
default-options thinking request stops 400ing). If the EP-5 shapes turn out to differ
from this plan's assumptions mid-implementation, stop, record the divergence in both
Decision Logs, adjust the emission sites (the only EP-5-coupled code is the
`ThinkingEnd` construction in both providers and the response-id fill), and continue;
nothing else in this plan depends on those shapes. Smoke cases are read-only API calls
billed at a few cents; re-running them is harmless. If a live smoke case reveals the
adaptive/budget table is wrong, the recovery is a one-line change in
`defaultAnthropicThinkingStyle` plus a Decision Log update — no other code encodes the
generation split.


## Interfaces and Dependencies

External: the MercuryTechnologies `claude` SDK (Haskell package `claude`, checkout via
`mori registry show MercuryTechnologies/claude --full`) supplies
`Claude.V1.Messages.Thinking` (`ThinkingAdaptive | ThinkingEnabled {budget_tokens ::
Natural}`), `Messages.OutputConfig {effort :: Maybe Text, ...}` / `effortConfig`,
`Messages.Content_Thinking {thinking, signature}`, `Messages.Content_Redacted_Thinking
{data_}`, and `Messages.ContentBlock_Redacted_Thinking {data_}` — all verified present
at authoring time; no SDK changes are required. The `openai` SDK is untouched (the
OpenAI provider parses raw `Aeson.Value` chunks already). The hard dependency is EP-5's
landed event-payload shapes (see Decision Log); the soft dependency is EP-6's error
contract (test assertions only).

At the end of Milestone 1 these exist:

- `Baikai.Compat.AnthropicThinkingStyle` (exported, with both constructors),
  `Baikai.Compat.AnthropicMessagesCompat.thinkingStyle`,
  `Baikai.Compat.defaultAnthropicThinkingStyle :: Text -> AnthropicThinkingStyle`
  (`baikai/src/Baikai/Compat.hs`), and the generation-aware `CompatNone` projection in
  `Baikai.Model.anthropicMessagesCompatFor` (`baikai/src/Baikai/Model.hs`).
- `Baikai.Provider.Claude.Api.computeThinking :: AnthropicMessagesCompat -> Model ->
  Maybe ThinkingLevel -> ThinkingPlan` with
  `ThinkingPlan {field :: Maybe Messages.Thinking, effort :: Maybe Text, budget ::
  Maybe Natural}`, and the clamped `max_tokens` arithmetic inside `mapRequest`
  (`baikai-claude/src/Baikai/Provider/Claude/Api.hs`).

At the end of Milestone 2: `Assembler.redactedBuf :: IntMap Text`, opened-index-safe
`handleBlockDelta`/`handleBlockStop`, `ThinkingEnd` emission carrying full
`ThinkingContent` (EP-5 payload), and the three-way `assistantContentToBlock` replay
(redacted / signed / omitted) — all in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`,
plus the updated `ThinkingContent` haddock in `baikai/src/Baikai/Content.hs`.

At the end of Milestone 3: `RawChunk.reasoningDelta :: Maybe Text`, the four documented
JSON read paths in `parseChunk`, `Assembler.reasoningOpen`/`reasoningAccum` with the
open/close lifecycle, and `scanThinkTags :: TagScanState -> Text -> (TagScanState,
[Either Text Text])` gated by `requiresThinkingAsText` — all in
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, with the flag's haddock updated in
`baikai/src/Baikai/Compat.hs`.

At the end of Milestone 4: `baikai-smoke/test/ThinkingSmoke.hs` with the three cases
wired into `baikai-smoke/test/Smoke.hs`.

Cross-plan contract (restated so no reader misses it): this plan owns the
thinking/`max_tokens` region of the Claude `mapRequest` and the
`requiresThinkingAsText` flag; EP-8
(`docs/plans/41-implement-compat-quirks-and-transport-options.md`) owns
tools/`cache_control`/headers in the same function, runs after this plan, and must not
delete `requiresThinkingAsText` or `thinkingStyle` as "unused" — both are consumed by
code this plan adds. Any change either plan needs in the other's region requires
Decision Log entries in both plans and in the MasterPlan.


---

Revision note (2026-07-03): Milestone 1 implementation updated the Progress,
Surprises & Discoveries, and Outcomes & Retrospective sections with the cap-safe Claude
thinking request-shaping work, the generator coupling discovered during validation, and
the focused `baikai`/`baikai-claude` test evidence. Milestone 2 then updated the same
living sections with Claude stream/replay fidelity, redacted payload preservation, the
phantom-block regression, and the focused `baikai-claude` test evidence.
