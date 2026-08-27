---
id: 60
slug: make-anthropic-thinking-style-and-sampling-support-catalog-driven
title: "Make Anthropic thinking style and sampling support catalog-driven"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Make Anthropic thinking style and sampling support catalog-driven

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

"Extended thinking" is Anthropic's name for the mode in which a Claude model writes an
internal reasoning trace before its visible answer. baikai exposes it through one knob,
`Options.thinking :: Maybe ThinkingLevel`, and the Anthropic adapter in `baikai-claude`
turns that level into one of two wire shapes: the older *budget* shape,
`{"type":"enabled","budget_tokens":N}`, where the caller fixes how many tokens the model
may think with, and the newer *adaptive* shape, `{"type":"adaptive"}`, where the model
decides and the caller only hints at depth through `output_config.effort`. Which shape a
model accepts is a fact about its generation. The current Anthropic API reference (cached
2026-06-24, as consulted by the review recorded as REV-2 in
`docs/reviews/correctness-and-api-review-follow-up.md`) says the budget shape is rejected
with an HTTP 400 on `claude-sonnet-5`, `claude-opus-4-7`, `claude-opus-4-8`,
`claude-opus-5` and `claude-fable-5`, and that those generations also reject the
*sampling parameters* `temperature`, `top_p` and `top_k` with a 400.

Today baikai chooses the shape from a hand-written prefix table,
`defaultAnthropicThinkingStyle` in `baikai/src/Baikai/Compat.hs`, which does not know
`claude-sonnet-5` and therefore sends it the budget shape, and it forwards
`Options.temperature` and `Options.topP` to every Anthropic model unconditionally. A user
who picks the newest Sonnet from the generated catalog and asks for thinking gets a 400;
a user who sets `temperature` on any adaptive-era model gets a 400. The catalog
(`baikai/src/Baikai/Models/Generated.hs`) carries no field for either fact, so the table
drifts every time the catalog is refreshed.

After this plan, both facts are fields of the generated catalog record: every Anthropic
entry carries an explicit compatibility record naming its thinking style and whether it
accepts sampling parameters, produced from `baikai/data/models/anthropic.json` by the
same generator that produces everything else and pinned by tests that fail the moment an
entry lacks them. The adapter honours the record: a thinking request on
`anthropic_claude_sonnet_5` sends `"thinking":{"type":"adaptive"}` and no
`budget_tokens`; `temperature = Just 0.2` on the same model puts no `temperature` on the
wire and records an adjustment in the call's evidence, so the drop is visible. The adapter
also stops sending `max_tokens: 0` for a hand-rolled model, stops replaying empty content
Anthropic rejects, stops producing colliding tool-call ids, and the OpenAI-compatible
adapter stops sending reasoning controls to models the catalog says cannot reason. The
proof is unit tests that fail on today's code and pass after, a request body a novice can
inspect in `cabal repl`, and two live smoke cases against `claude-sonnet-5` that run with
an Anthropic key and skip loudly without one.

This plan is EP-3 of `docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`.
It continues `docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md`,
which introduced the two styles, the cap-safe `max_tokens` arithmetic and the prefix
table this plan retires; that plan is incorporated by reference and everything a novice
needs from it is repeated below. The findings closed are REV-2 items C.1 through C.8,
Theme I items 3 and 4, and the REV-1 residuals under Theme 2 (2.2 partial) and Theme 5
(the Claude `max_tokens: 0` case).


## Progress

- [x] M1: `supportsSamplingParameters` on `AnthropicMessagesCompat`; prefix table
      disconnected from `anthropicMessagesCompatFor` and deprecated. (2026-08-27)
- [x] M1: generation facts in `FetchModelsCore.hs` rendered into `anthropic.json`;
      generator parses, renders, refuses an Anthropic entry without a compat block, and
      imports the selectors its rendering needs; `Generated.hs` regenerated. (2026-08-27)
- [x] M1: `FetchModelsSpec`, `GenModelsSpec`, `CatalogSpec` and `baikai/test/Main.hs`
      updated; the ADR and its README row written. (2026-08-27)
- [ ] M2: the two sampling adjustments, `weakensThinking`, the strict-gate filter and
      schema version `1.1`.
- [ ] M2: `planRequest` (sampling plan, zero-cap floor, adjustments visible through
      `describeThinkingFor`), replay sanitation, hash-suffixed tool-call ids.
- [ ] M2: cache-write pricing limitation documented; `ThinkingSpec`, `Main.hs` and
      `EvidenceSpec` cases in `baikai-claude/test/`, including the usage-mapping pin.
- [ ] M3: OpenAI-compatible reasoning controls gated on `Model.reasoning`; the two pinned
      tests re-based; gate tests added; `model-call-evidence.md` table corrected.
- [ ] M4: every Anthropic catalog id pinned in `ThinkingSpec` and `CatalogSpec`, both
      guarded against `allModels`.
- [ ] M4: `ThinkingSmoke` cases for `claude-sonnet-5`; `apiCases` gains DeepSeek and
      OpenRouter; `CompatSmoke` asserts `maxTokens`; `CacheSmoke` asserts cost.
- [ ] M4: guides, capability records and `CHANGELOG.md` updated; keyless gate green;
      MasterPlan Progress rows for EP-3 ticked.


## Surprises & Discoveries

- __The generator's compat-rendering path needed two import fixes, not one.__ The
  plan's Context predicted the rendered module header would lack the
  `AnthropicMessagesCompat (…)` selectors its record update needs. It also lacked the
  `OpenAICompletionsCompat (…)` selectors, for the same reason and with the same
  consequence — no shipped entry had ever been rendered with either branch. Both
  import blocks are now emitted, so the first catalog to carry an OpenAI-compatible
  per-model override will build too. (2026-08-27, M1)
- __The file-level `"compat": "auto"` line makes a naive "no compat block" assertion
  fail.__ The first version of `FetchModelsSpec`'s "an OpenAI model renders no compat
  block" case searched the rendered catalog for `"compat"` and failed on the
  file-level directive four lines from the top. It asserts on `"compat": {` — the
  per-model block's opening — instead. (2026-08-27, M1)
- __The repository formatter and `CatalogSpec` can contradict each other.__ The
  generator's first compat rendering laid the record update out as
  `compat = CompatAnthropicMessages` with the record on following lines; `ormolu`
  (through the `treefmt` pre-commit hook) rewrites that to `compat =` with the
  constructor on its own line and the braces two columns deeper. Since `CatalogSpec`
  demands the generator's output be byte-identical to the committed file, the two
  checks could never both pass. `renderCompat` now returns source lines in exactly
  the layout the formatter produces, and `nix fmt` leaves `Generated.hs` unchanged.
  Any future change to the rendered layout has to be checked against `nix fmt`, not
  only against the compiler. (2026-08-27, M1)
- __M1 alone leaves `baikai-claude`'s `ThinkingSpec` red, as the plan predicted, and
  the fix is one line rather than a milestone boundary.__ The plan's M1 acceptance
  says the `claude-sonnet-4-6` rows fail until M2. Rather than commit a red suite,
  the pinned style in `anthropicModels` was flipped to `AnthropicThinkingAdaptive`
  in the M1 commit: it is the assertion the catalog decision made true, and M2
  restructures that table into four columns regardless. Every suite is green at
  every commit. (2026-08-27, M1)


## Decision Log

- Decision: Both facts live on `Baikai.Compat.AnthropicMessagesCompat`: the existing
  `thinkingStyle` and a new `supportsSamplingParameters :: Bool` (default `True`). The
  catalog emits an explicit `CompatAnthropicMessages` record for every Anthropic model, so
  `compat = CompatNone` never reaches the adapter for a catalog model.
  Rationale: the compat record exists to carry per-host and per-generation wire quirks,
  `thinkingStyle` is already there, and the generator already renders per-model compat
  overrides (`entryCompatOverride`, `baikai/gen/GenModelsCore.hs`). A field on `Model`
  would duplicate the record's purpose. The name follows the record's `supports*`
  convention rather than the MasterPlan's placeholder `samplingSupported`.
  Date: 2026-08-27
- Decision: The source of the facts is the fetcher's curation map: `anthropicInclude` in
  `baikai/fetch/FetchModelsCore.hs` becomes a `Map Text AnthropicGenerationFacts`, each
  entry with a dated comment naming its source, rendered by the fetcher into
  `anthropic.json` as a per-model `"compat"` block; the generator refuses an
  `anthropic-messages` entry without one.
  Rationale: `baikai-fetch-models` rewrites `anthropic.json` wholesale, so a field kept
  by hand inside the JSON would be wiped at the next refresh; a generator-side table would
  make `Generated.hs` depend on data the JSON does not show, breaking the doctrine that the
  JSON is the source of truth (`docs/user/models-and-providers.md`). The include set is
  already the one place a human vets an Anthropic id, so no id can be curated without its
  facts, a refresh cannot lose them, and the generator's refusal stops a hand edit from
  reintroducing `CompatNone`. `git diff` on the JSON stays the review surface.
  Date: 2026-08-27
- Decision: `defaultAnthropicThinkingStyle` is disconnected from
  `anthropicMessagesCompatFor` and marked `{-# DEPRECATED #-}`, not deleted.
  `anthropicMessagesCompatFor` for `CompatNone` returns host auto-detection only (budget
  style, sampling supported). EP-10 (`docs/plans/67-freeze-the-public-surface.md`)
  removes the export at the next major and must add it to its removal list.
  Rationale: a prefix table is what drifted, and keeping it live "for hand-rolled ids"
  keeps two sources of truth; removing an export is a version bump, which the MasterPlan
  assigns to EP-10. The default is the shape every generation before 4.7 and every known
  compatible host accepts; a hand-rolled model naming an adaptive-era id must now set its
  compat record or start from the catalog value, recorded in `CHANGELOG.md`.
  Date: 2026-08-27
- Decision: A dropped sampling parameter extends `Baikai.Evidence.ThinkingAdjustment`
  with `SamplingDroppedUnsupportedModel ![Text]` (JSON
  `{"kind":"sampling_dropped_unsupported_model","fields":["temperature","top_p"]}`) for
  parameters the model generation rejects, and `SamplingDroppedUnsupportedApi ![Text]`
  (`"sampling_dropped_unsupported_api"`) for `seed`, `frequency_penalty` and
  `presence_penalty`, which the Anthropic Messages API has no field for. Neither carries a
  `requested` level. `evidenceSchemaVersion` moves to `baikai.model-call-evidence/1.1`.
  Rationale: the MasterPlan assigns the vocabulary to EP-8 and directs EP-3 to extend the
  existing sum; ADR 0002 requires the drop to be recorded as a translation and ADR 0003
  requires the adapter that built the request to record it, which `planRequest` does. A
  new `kind` is a compatible addition, hence a minor bump. If EP-8 has already bumped the
  version, do not bump again; note it in both Decision Logs.
  Date: 2026-08-27
- Decision: The strict-evidence gate refuses only adjustments that weaken the thinking
  request: `Baikai.Evidence.weakensThinking :: ThinkingAdjustment -> Bool` is true for the
  six existing constructors and false for the two sampling ones, and
  `checkEvidenceRequirements` in `baikai/src/Baikai/Evidence/Build.hs` filters through it.
  Rationale: the documented contract is "refuse a call that would weaken the requested
  thinking level"; a caller who set `seed` on a Claude model must not have every strict
  call refused for a field the API never had. This is one line in a function EP-8 owns and
  must be recorded in EP-8's Decision Log.
  Date: 2026-08-27
- Decision: For a model whose `maxOutputTokens` is 0 and no `Options.maxTokens`, the
  Anthropic adapter sends `max_tokens = uncappedMaxTokensFloor` (1024) plus the budget
  when the budget style applies; no adjustment is recorded.
  Rationale: Anthropic requires `max_tokens` and rejects 0, so the OpenAI adapter's
  omission rule is unavailable. 1024 is the SDK's own `_CreateMessage` default, accepted by
  every generation and compatible host. It is a default, not a downgrade of anything the
  caller asked for, so it belongs in the request body (already digested) and in the
  Haddock of `Model.maxOutputTokens`, not in the adjustment list. An explicit
  `maxTokens = Just 0` is forwarded as written.
  Date: 2026-08-27
- Decision: Replay sanitation: text blocks with empty text are dropped in both roles; an
  assistant turn left with no blocks is dropped from the message list; a user turn left
  with no blocks makes `mapRequest` return `Left` (already an `InvalidRequest` in
  `prepareCall`).
  Rationale: Anthropic rejects empty text blocks and empty content arrays. An empty
  assistant turn is baikai's own artifact (a text block that closed with no deltas, or
  only unsigned thinking that replay already omits), so dropping it loses nothing the
  model said, and Anthropic merges the adjacent user turns itself; a placeholder would
  fabricate content. An empty user turn is a caller error refused locally with a better
  message and the same category.
  Date: 2026-08-27
- Decision: Tool-call ids that already satisfy `[a-zA-Z0-9_-]{1,64}` pass through
  unchanged; any other id is sanitised, truncated to 51 characters and suffixed with `_`
  plus twelve lowercase hex characters of the SHA-256 of the original. `mapRequest`
  returns `Left` if two `tool_use` blocks in one assistant turn normalise to the same id.
  Rationale: Anthropic-originated (`toolu_…`) and OpenAI-originated (`call_…`) ids are
  valid and must never change, because the tool-result side normalises with the same
  function. Only exotic ids get the suffix; forty-eight bits of hash make a collision among
  one conversation's calls negligible and the duplicate check turns it into a clear error.
  Refusing every non-conforming id was rejected because it would break replay of any
  conversation started on a provider with a different id alphabet.
  Date: 2026-08-27
- Decision: C.6 (one cache-write rate for both TTLs) is a documented limitation with a
  pin, not a fix: the Haddock of `finalUsage` and `anthroUsageToBaikai` and the "Notes and
  limits" section of `docs/user/prompt-caching.md` state that a `CacheRetentionLong` write
  is priced at the catalog's single `cacheWriteCost` (the five-minute rate) and so
  under-states a one-hour write.
  Rationale: the SDK's `Usage` (`claude/src/Claude/V1/Messages.hs` lines 622–628 in the
  checkout) has `cache_creation_input_tokens` only; the raw frame is decoded into that
  type in `Claude/Sse.hs` and discarded. Carrying the split needs a second value on the
  worker channel (EP-4), a new `Usage` field inside the evidence record (EP-8) and a second
  `ModelCost` rate models.dev does not publish — three owners for a minor finding.
  Date: 2026-08-27
- Decision: C.4 is fixed by gating: `injectThinkingShape`, `describeThinkingShape`,
  `shapeRequestBody` and `streamRequestBody` in `Provider/OpenAI/Shape.hs` take the
  model's `reasoning` flag, and `mapRequest` in `Provider/OpenAI/Internal/Request.hs`
  consults it before `applyThinkingFormat`. A level on a `reasoning = False` model sends
  no reasoning control and records `ThinkingDroppedUnsupportedModel lvl`; the model check
  precedes the host-format check. `ShapeSpec.deepseekShapeTest` and
  `EvidenceSpec.toggleHostIndistinguishabilityTest` are re-based on reasoning models so
  they keep proving their point, and new tests pin the gate.
  Rationale: `openai_gpt_4o_mini` plus any level is a 400 today; the catalog's `reasoning`
  flag is the authoritative capability fact; `docs/user/model-call-evidence.md` line 101
  already promises `thinking_dropped_unsupported_model` baikai-wide, and gating makes the
  promise true. Hand-rolled models default to `reasoning = False`, which is already the
  Claude adapter's rule.
  Date: 2026-08-27
- Decision: C.5: `seed`, `frequencyPenalty` and `presencePenalty` are recorded through
  `SamplingDroppedUnsupportedApi` on every Anthropic call that sets them.
  `Options.metadata` is not forwarded by either API adapter; its Haddock says so.
  Rationale: the three are sampling controls with no Anthropic field. Anthropic's
  `metadata` accepts only `user_id` and rejects other keys, so forwarding an arbitrary map
  would trade a silent drop for a 400, and forwarding `user_id` alone is a feature no
  finding asks for.
  Date: 2026-08-27
- Decision: The per-model facts (Anthropic API reference cached 2026-06-24 via REV-2; the
  repository's tests are authoritative where they conflict): `claude-fable-5`,
  `claude-opus-4-8`, `claude-opus-4-7` and `claude-sonnet-5` are adaptive and reject
  sampling parameters; `claude-opus-4-6` and `claude-sonnet-4-6` are adaptive (budget is
  deprecated but functional there; this plan prefers the non-deprecated shape) and accept
  them; `claude-opus-4-5`, `claude-sonnet-4-5` and `claude-haiku-4-5` are budget and
  accept them. `claude-opus-5` is not in the curated include set; adding it is a catalog
  refresh, and the facts map will force whoever adds it to state adaptive / no sampling.
  Rationale: `claude-sonnet-4-6` flips from budget to adaptive relative to plan 40, whose
  Decision Log deferred that membership to a live check that never happened; the M4 keyed
  run is where this table meets reality, and any discrepancy is one map entry.
  Date: 2026-08-27
- Decision: The catalog JSON spells `thinkingStyle` as `"budget"` / `"adaptive"` and
  `supportsSamplingParameters` as a JSON boolean, through explicit parsers in
  `GenModelsCore`; the derived JSON instances on the compat types are untouched.
  Rationale: the derived instances are part of `Model`'s pinned JSON round-trip; the
  catalog dialect is human-edited and uses words, as every other catalog enum does.
  Date: 2026-08-27
- Decision: The keyed proof is two `ThinkingSmoke` cases on
  `Models.anthropic_claude_sonnet_5`: `claude-sonnet-5-thinking-adaptive`
  (`ThinkingMedium`, the helper's `temperature = 0.0`, signed replay) and
  `claude-sonnet-5-sampling-dropped` (no level, `temperature = Just 0.2`). Theme I item 4
  is closed by adding `deepseek-chat` and `openrouter/openai/gpt-4o-mini` to `apiCases`,
  asserting `outputTokens <= maxTokens` in `CompatSmoke`'s DeepSeek case, and asserting
  the cost split in `CacheSmoke`.
  Rationale: the MasterPlan makes live verification a statement, not a gate; a keyed
  failure in the new rows is a finding to record, not a case to silence.
  Date: 2026-08-27
- Decision: One ADR, slug `provider-capability-facts-live-in-the-generated-catalog-record`,
  titled "Provider capability facts such as thinking style and sampling support live in
  the generated catalog record and never in a hand table", at the next free number in
  `docs/adr/` at implementation time (`0006` if neither plan 58 nor 59 has landed its ADR,
  otherwise the next), with a row in `docs/adr/README.md`.
  Rationale: the MasterPlan assigns this decision to EP-3; `docs/adr/` is the plain-file
  convention of ADR 0001, so no OKF handle is allocated.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

baikai is a multi-package Haskell library built with `cabal` (GHC2024, lenses through
`Data.Generics.Labels`, so `m ^. #maxOutputTokens` reads a field and `opts & #thinking .~
Just ThinkingHigh` sets one). Line numbers are as of commit `5411947`, whose code is
identical to the reviewed `c3753c5`. The packages touched:

- `baikai/` — the core. `baikai/src/Baikai/Compat.hs` (compat records),
  `baikai/src/Baikai/Model.hs` (`Model`, the `Compat` sum
  `CompatNone | CompatOpenAICompletions … | CompatAnthropicMessages …`, and the
  projections `openaiCompletionsCompatFor` / `anthropicMessagesCompatFor`),
  `baikai/src/Baikai/Evidence.hs` (evidence vocabulary), `baikai/src/Baikai/Evidence/Build.hs`
  (the strict gate), `baikai/src/Baikai/Models/Generated.hs` (the catalog), `baikai/gen/`
  (generator), `baikai/fetch/` (fetcher), `baikai/data/models/*.json` (catalog data), and
  `baikai/test/` (`CatalogSpec.hs`, `GenModelsSpec.hs`, `FetchModelsSpec.hs`,
  `StrictEvidenceSpec.hs`, `EvidenceSpec.hs`, `Main.hs`).
- `baikai-claude/` — the Anthropic Messages provider.
  `src/Baikai/Provider/Claude/Internal/Request.hs` maps a request onto the SDK's
  `CreateMessage` and produces the thinking translation; `src/Baikai/Provider/Claude/Api.hs`
  holds the worker, assembler and usage mapping; tests in `test/ThinkingSpec.hs`,
  `test/Main.hs`, `test/EvidenceSpec.hs`.
- `baikai-openai/` — the OpenAI Chat Completions provider, also serving DeepSeek,
  OpenRouter and Together. `src/Baikai/Provider/OpenAI/Shape.hs` reshapes the raw JSON
  body per host; `Internal/Request.hs` builds the SDK request; tests in
  `test/ShapeSpec.hs` and `test/EvidenceSpec.hs`.
- `baikai-smoke/` — live tests (`test/Smoke.hs`, `ThinkingSmoke.hs`, `CompatSmoke.hs`,
  `CacheSmoke.hs`) that skip per case when the relevant key is unset.

Terms of art, defined once:

- *Extended thinking*: the model emits a reasoning trace before its answer; asked for
  with `Options.thinking`, whose six levels are `ThinkingMinimal | ThinkingLow |
  ThinkingMedium | ThinkingHigh | ThinkingXHigh | ThinkingMax`
  (`baikai/src/Baikai/ThinkingLevel.hs`).
- *Budget style*: `{"type":"enabled","budget_tokens":N}` with N from
  `thinkingTokenBudget` (1024, 2048, 8192, 16384, 24576, 32768), added to `max_tokens`
  because Anthropic counts thinking inside the output cap.
- *Adaptive style*: `{"type":"adaptive"}`; depth is hinted through `output_config.effort`
  (`low`, `medium`, `high` omitted as the default, `xhigh`, `max`) per `adaptiveEffort`,
  `Request.hs` lines 274–281.
- *Sampling parameters*: the knobs shaping how the next token is drawn. `Options`
  (`baikai/src/Baikai/Options.hs` lines 80–96) carries `temperature`, `topP`, `seed`,
  `frequencyPenalty`, `presencePenalty` and no `topK`; Anthropic Messages has
  `temperature`, `top_p`, `top_k` and none of the other three.
- *Compat record*: `AnthropicMessagesCompat` / `OpenAICompletionsCompat`, flags describing
  how one host or generation deviates from the reference protocol; carried on
  `Model.compat`, or `CompatNone`, which means "guess from `baseUrl`".
- *Catalog*: `Baikai.Models.Generated`, one exported `Model` per curated model plus
  `allModels`; generated, never hand-edited.
- *Fetcher and generator*: `baikai-fetch-models` (`baikai/fetch/FetchModels.hs`, pure
  core `FetchModelsCore.hs`) does network → JSON, curating models.dev through
  `anthropicInclude` / `openaiInclude` and a dated `overrides` table; `baikai-gen-models`
  (`baikai/gen/GenModels.hs`, core `GenModelsCore.hs`) does JSON → `Generated.hs`;
  `baikai/test/CatalogSpec.hs` re-runs the generator and demands byte-identity.
- *Evidence record, translation, adjustment*: `ModelCallEvidence.thinking ::
  ThinkingTranslation` says what `Options.thinking` became and lists every change in
  `adjustments :: [ThinkingAdjustment]`, whose six constructors (`Evidence.hs` lines
  230–251) encode as `{"kind":"…","requested":"<level>",…}`. *Strict evidence mode*
  (`Options.evidence = Just (… EvidenceRequired s)`) makes `checkEvidenceRequirements`
  (`Build.hs` lines 366–373) refuse before dispatch when the transport cannot reach `s`
  or `adjustments` is non-empty.
- *Replay*: sending a prior assistant turn back as part of the next request
  (`mapMessage` / `assistantContentToBlock` in `Request.hs`). *Tool-call id*: the id tying
  a `tool_use` block to its `tool_result`; Anthropic enforces `[a-zA-Z0-9_-]{1,64}`.

The defects as the code stands:

*C.1.* `baikai/src/Baikai/Compat.hs` lines 232–240:

```haskell
defaultAnthropicThinkingStyle :: Text -> AnthropicThinkingStyle
defaultAnthropicThinkingStyle modelId
  | adaptive "claude-opus-4-6" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-7" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-8" = AnthropicThinkingAdaptive
  | adaptive "claude-fable-5" = AnthropicThinkingAdaptive
  | otherwise = AnthropicThinkingBudget
  where
    adaptive prefix = prefix `Text.isPrefixOf` modelId
```

`Model.hs` lines 105–111 overlay it on every `CompatNone` model; every Anthropic entry in
`Generated.hs` (lines 40–245) is `CompatNone`, so `claude-sonnet-5` (line 224) and
`claude-sonnet-4-6` (line 201) get the budget shape. `Request.hs` lines 93–94 send
`Messages.temperature = opts ^. #temperature` and `Messages.top_p = opts ^. #topP` for
every model. The SDK encodes `CreateMessage` with `omitNothingFields = True`
(`claude/src/Claude/Prelude.hs` line 83), so a `Nothing` is genuinely absent from the
wire, which the fix relies on.

*C.2.* `Request.hs` lines 69–75 and 125–129 compute `baseTokens = fromMaybe cap
(opts ^. #maxTokens)` with `cap = 0` for `emptyModel`; `max_tokens :: Natural` is not
optional, so the wire carries `"max_tokens":0`, and with thinking set
`resolvedCeiling <= b` drops the plan as `ThinkingDroppedBudgetExceeded lvl b 0`.

*C.3.* Lines 414–416 map `AssistantText ""` to `Content_Text {text = ""}`; lines 368–374
map a turn whose only blocks were omitted (unsigned thinking, plan 40's rule at lines
417–427) to `content = []`.

*C.4.* `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` lines 121–167
(`injectThinkingShape`) and `Internal/Request.hs` lines 115–122 (`applyThinkingFormat`)
never consult the model. `openai_gpt_4o_mini` and `deepseek_deepseek_chat` have
`reasoning = False`. `ShapeSpec.deepseekShapeTest` (lines 45–57) and
`EvidenceSpec.toggleHostIndistinguishabilityTest` (lines 158–201, built on `testModel =
openai_gpt_4o_mini`, line 296) pin the current behaviour as a decision.

*C.5.* `Request.hs` lines 88–101 never read `seed`, `frequencyPenalty`,
`presencePenalty` or `metadata`; `optionsMappingTest` (`baikai-claude/test/Main.hs`
lines 114–133) sets them and asserts only `top_p` and `stop_sequences`.

*C.6.* `Api.hs` lines 800–803 price `cacheWriteTokens` at one rate;
`anthroUsageToBaikai` (lines 888–902) reads `cache_creation_input_tokens` only.

*C.7.* `Request.hs` lines 350–357, `normalizeToolCallId = Text.take 64 . Text.map
sanitise`: `a.b` and `a_b` collide, as do ids differing after character 64.

*C.8.* `Api.hs` lines 851–856 pass `Ev.noThinkingRequested` to `immediateError`. The
core twin D.2 belongs to EP-8, which threads `describeThinkingFor m opts` through that
path; this plan's half is that `describeThinkingFor` (`Request.hs` line 142, `snd
(planThinking m opts)`) reports the sampling drops too.

*Theme I items 3 and 4.* `ThinkingSpec.anthropicModels` (lines 39–49) omits
`claude-sonnet-5`; `CatalogSpec` asserts only byte-identity; `apiCases`
(`baikai-smoke/test/Smoke.hs` lines 91–106) are Claude Haiku and `gpt-4o-mini` only;
`CompatSmoke.runDeepSeekMaxTokensCase` asserts non-empty text; `CacheSmoke` never asserts
cost.

Two hazards. First, the generator's compat rendering has never been compiled: every
shipped entry is `CompatNone`, and the rendered header (`GenModelsCore.hs` lines
343–351) imports `Baikai.Compat (AnthropicThinkingStyle (..), …,
defaultAnthropicMessagesCompat, …)` without the selectors the rendered
`defaultAnthropicMessagesCompat { supportsLongCacheRetention = …, … }` update needs. The
first build after regeneration fails with "Not in scope: supportsLongCacheRetention" until
the header also imports `AnthropicMessagesCompat (sendSessionAffinityHeaders,
supportsCacheControlOnTools, supportsLongCacheRetention, supportsSamplingParameters,
thinkingStyle)` and the `OpenAICompletionsCompat (…)` selectors likewise. Second,
`-Werror=incomplete-patterns` is on (`baikai/baikai.cabal` lines 39–41), so adding
constructors to `ThinkingAdjustment` fails the build at `describeAdjustment` in
`Build.hs` and at the JSON instances in `Evidence.hs` until every case is written — the
intended forcing function.

ADRs. `docs/adr/0002-requested-translated-observed-are-never-collapsed.md`: the request,
the translation and the observation are three facts; a dropped `temperature` is a
translation and must be recorded, never lost or backfilled.
`docs/adr/0003-the-adapter-owns-the-translation-description.md`: the adapter building the
request builds its description from the same function that builds the wire value, which
is why the sampling plan lives inside `planRequest` beside the thinking plan and
`describeThinkingFor` is a projection of it.
`docs/adr/0004-two-digests-commitment-and-configuration.md` matters only in that
`temperature` and `top_p` are in `configurationKeys` (`Evidence.hs` lines 1010–1031), so
a dropped parameter changes the configuration digest, correctly. ADR 0005 does not apply.
No cross-repository ADR applies; the MasterPlan's registry search returned nothing.

Ownership, from the MasterPlan's Integration Points: EP-2 owns the URL parser at the
bottom of `Compat.hs` (this plan edits the thinking-style region only and never reads
`baseUrl` for the style); EP-4 owns the worker, assembler and terminal paths in both
`Api.hs` modules (this plan edits only usage and cache-pricing Haddock there and two
argument sites in the OpenAI `Api.hs`); EP-8 owns the evidence vocabulary and
`immediateError` (this plan extends the sum and the gate filter and records both in EP-8's
Decision Log); EP-10 owns exports and removals; EP-11 owns the documentation sweep, so this
plan updates only the Haddock, guides and capability records describing behaviour it
changes.


## Plan of Work

Four milestones, fixed by the MasterPlan: the catalog record, the Anthropic adapter, the
OpenAI-compatible gate, and the pins and smoke cases. Each is independently buildable,
testable and committable.

### Milestone 1 — catalog record carries Anthropic thinking style and sampling support, generated from data

Scope: every Anthropic entry in `Baikai.Models.Generated` carries an explicit
`CompatAnthropicMessages` record with both facts, produced from `anthropic.json` by
`baikai-gen-models`, which is produced from the fetcher's curation map by
`baikai-fetch-models`. The prefix table influences no catalog model. Because the adapter
already consumes `thinkingStyle`, `anthropic_claude_sonnet_5` sends the adaptive shape at
the end of this milestone — the first user-visible effect.

In `baikai/src/Baikai/Compat.hs`, add to `AnthropicMessagesCompat` after
`thinkingStyle`:

```haskell
    -- | Whether the model generation accepts the sampling parameters
    --   @temperature@, @top_p@ and @top_k@. Adaptive-era generations
    --   from Opus 4.7 and Sonnet 5 onward reject them with a 400, so
    --   the Anthropic adapter drops them and records
    --   'Baikai.Evidence.SamplingDroppedUnsupportedModel'. Which
    --   generations accept them is a fact of the generated catalog
    --   record, not of this type. Consumed by
    --   @Baikai.Provider.Claude.Internal.Request.planRequest@.
    supportsSamplingParameters :: !Bool
```

with `supportsSamplingParameters = True` in `defaultAnthropicMessagesCompat`, exported
beside the other selectors. Rewrite the `thinkingStyle` Haddock to point at
`Baikai.Provider.Claude.Internal.Request.computeThinking` (it names a function that moved)
and to carry the same "fact of the catalog record" sentence. Deprecate the table:

```haskell
{-# DEPRECATED defaultAnthropicThinkingStyle "The thinking style of a first-party Anthropic model is a field of its generated catalog record (Baikai.Models.Generated); start from that value or set CompatAnthropicMessages explicitly." #-}
```

In `baikai/src/Baikai/Model.hs`, make the `CompatNone` branch of
`anthropicMessagesCompatFor` return `autoDetectAnthropicMessages (baseUrl m)` only, drop
the `defaultAnthropicThinkingStyle` import, and rewrite its Haddock and the module header
(which still calls `Compat` "a placeholder until EP-5"): an explicit record wins;
`CompatNone` means host auto-detection with budget style and sampling supported; a
catalog model always carries an explicit record. Add to the `maxOutputTokens` Haddock
that 0 means unknown, the OpenAI adapter then omits the cap, and the Anthropic adapter
sends `uncappedMaxTokensFloor` (M2).

In `baikai/fetch/FetchModelsCore.hs`, add

```haskell
-- | The two request-shaping facts every curated Anthropic model must
-- state before it can enter the catalog.
data AnthropicGenerationFacts = AnthropicGenerationFacts
  { thinkingStyle :: !AnthropicThinkingStyle,
    supportsSamplingParameters :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | A per-model compat block in the catalog JSON.
data CatalogModelCompat = CatalogAnthropicCompat !AnthropicGenerationFacts
  deriving stock (Eq, Show, Generic)
```

turn `anthropicInclude` into a `Map Text AnthropicGenerationFacts` with the nine entries
from the Decision Log, each preceded by a dated comment in the style of `overrides` (for
example `-- 2026-08-27: adaptive-only, sampling parameters rejected with 400 — Anthropic
API reference cached 2026-06-24, as consulted by REV-2 C.1`), and keep
`anthropicSpec.include = (`Map.member` anthropicInclude)`. Add `compat :: !(Maybe
CatalogModelCompat)` to `CatalogModel` and `compatFor :: !(Text -> Maybe
CatalogModelCompat)` to `ProviderSpec` (`const Nothing` for OpenAI, a lookup wrapped in
`CatalogAnthropicCompat` for Anthropic), fill it in `toCatalogModel`, and extend
`renderModel` to emit, between `"maxOutputTokens"` and `"enabled"`,

```json
      "compat": {
        "kind": "anthropic-messages",
        "thinkingStyle": "adaptive",
        "supportsSamplingParameters": false
      },
```

when `compat` is `Just`. The file-level `"compat": "auto"` line stays; the generator
already prefers a per-model block (`flattenEntries`, `GenModelsCore.hs` lines 272–275).
Export the new types and the map.

In `baikai/gen/GenModelsCore.hs`, add `parseAnthropicThinkingStyle :: Text -> Parser
AnthropicThinkingStyle` for `"budget"` and `"adaptive"`, use it through `optionalField`
in `parseAnthropicCompat`, read `supportsSamplingParameters` with `.:?` and `.!=`, add the
field to `renderCompat`'s Anthropic branch, fix the header per the hazard, and add and
export

```haskell
-- | Every anthropic-messages entry must state its thinking style and
-- sampling support explicitly; an entry left at "auto" would fall to
-- host auto-detection, which cannot know the model generation.
checkAnthropicCompat :: [(Text, GeneratedEntry)] -> Either Text ()
```

returning `Left "anthropic-messages entry <provider>/<id> has no compat block; add
{\"kind\":\"anthropic-messages\",\"thinkingStyle\":…,\"supportsSamplingParameters\":…}"`
for any `api == AnthropicMessages` entry whose compat is not `CatalogCompatAnthropic`;
`baikai/gen/GenModels.hs` calls it after `checkIdentifierCollisions` and dies on `Left`.

Then rewrite `anthropic.json` by hand with the nine blocks (the fetch fixture has only
`claude-opus-4-5`; a live fetch is not required), regenerate, and update the tests. In
`baikai/test/FetchModelsSpec.hs`: `expectedOpenAI` models get `compat = Nothing`;
`expectedAnthropic`'s `claude-opus-4-5` gets `compat = Just (CatalogAnthropicCompat
(AnthropicGenerationFacts AnthropicThinkingBudget True))`; add a test that `renderCatalog`
on the Anthropic fixture contains the block above with `"budget"` and `true`. In
`baikai/test/GenModelsSpec.hs`: `checkAnthropicCompat` rejects an `anthropic-messages`
catalog whose entry has `entryCompatOverride = Nothing` under `CatalogCompatAuto`, and
accepts one with a block. In `baikai/test/CatalogSpec.hs`: add "every Anthropic catalog
entry carries an explicit thinking style and sampling flag", walking `allModels`, keeping
`api == AnthropicMessages`, and asserting each `compat` is `CompatAnthropicMessages c`
with `(modelId, thinkingStyle c, supportsSamplingParameters c)` equal to a nine-row list
written out by hand. In `baikai/test/Main.hs`, the test "Anthropic compat defaults thinking
style by model generation" (line 253) asserts, among its rows,

```haskell
        anthropicMessagesCompatFor anthropic_claude_sonnet_4_6
          ^. #thinkingStyle
          @?= AnthropicThinkingBudget,
```

Change that row to `AnthropicThinkingAdaptive`, add `anthropic_claude_sonnet_5`
(`AnthropicThinkingAdaptive`, `supportsSamplingParameters` `False`) and a
`supportsSamplingParameters` assertion on every model, rename the test to "Anthropic
catalog compat records carry thinking style and sampling support", and add "a hand-rolled
Anthropic model with CompatNone gets budget style and sampling supported" on `mkModel
AnthropicMessages "claude-sonnet-5" ""`. The neighbouring "Anthropic compat auto-detection
drives cache request policy" (line 240) gains `compat ^. #supportsSamplingParameters @?=
True`.

Create `docs/adr/NNNN-provider-capability-facts-live-in-the-generated-catalog-record.md`
in ADR 0001's format (`title`, `status: accepted`, `date`; Context, Decision,
Consequences). Context: the prefix table, its drift, REV-2 C.1. Decision: a fact about
what a provider or generation accepts on the wire is a field of the compat record carried
by the generated catalog entry, sourced from the catalog data and the fetcher's curation;
the generator refuses an entry that leaves it implicit; adapters read the record and never
a table keyed by id. Consequences: a hand-rolled model states its facts or borrows a
catalog value; a new generation is a JSON-reviewed catalog change;
`defaultAnthropicThinkingStyle` is deprecated for EP-10 to remove. Add the row to
`docs/adr/README.md`.

Acceptance: `cabal run baikai-gen-models` prints `Wrote …/Generated.hs (35 enabled
models)` and `git diff` shows only the nine Anthropic entries gaining records; `cabal test
baikai` passes including the new `CatalogSpec` table. `ThinkingSpec` now fails on its
`claude-sonnet-4-6` rows (pinned as budget), which M2 fixes.

### Milestone 2 — request shaping honours the record (sonnet-5 adaptive, sampling dropped and recorded, zero-cap, replay sanitation, tool-id normalisation)

Scope: the Anthropic adapter drops sampling parameters the record says the model rejects
and records the drop; sends a documented floor instead of `max_tokens: 0`; never replays
an empty text block or an empty assistant turn; never produces colliding tool-call ids;
and `describeThinkingFor` reports every drop.

Vocabulary, in `baikai/src/Baikai/Evidence.hs`. Extend the sum:

```haskell
  | -- | Sampling parameters the caller set were removed because the
    -- chosen model generation rejects them. Carries the wire names
    -- removed, in wire order, e.g. @["temperature","top_p"]@.
    SamplingDroppedUnsupportedModel ![Text]
  | -- | Sampling parameters the caller set were removed because this
    -- API has no field for them on any generation (Anthropic Messages
    -- has no @seed@, @frequency_penalty@ or @presence_penalty@).
    SamplingDroppedUnsupportedApi ![Text]
```

Encode them as `{"kind":"sampling_dropped_unsupported_model","fields":[…]}` and
`{"kind":"sampling_dropped_unsupported_api","fields":[…]}`; restructure `FromJSON` to read
`kind` first and `requested` only for the six level-carrying kinds. Add and export
`weakensThinking :: ThinkingAdjustment -> Bool` (true for the six, false for the two).
Update the Haddock on `ThinkingAdjustment`, on `adjustments` (reasoning *and* sampling
changes; `mode` still describes thinking only) and on `noThinkingRequested` (`mode =
absent` with a non-empty list now means nothing about thinking was asked and something
about sampling was dropped). Bump `evidenceSchemaVersion` to
`"baikai.model-call-evidence/1.1"` with the reason in its Haddock. In
`baikai/src/Baikai/Evidence/Build.hs`, add the two `describeAdjustment` cases
("temperature, top_p would be dropped, because this model generation rejects sampling
parameters" / "… because the Anthropic Messages API has no such field") and change
`downgrades = adjustments translation` to `downgrades = filter weakensThinking (adjustments
translation)`, amending the paragraph that says every non-empty list refuses. In
`baikai/test/StrictEvidenceSpec.hs`, add "a dropped sampling parameter is not a thinking
downgrade": a translation whose only adjustment is `SamplingDroppedUnsupportedModel
["temperature"]` under `EvidenceRequired EvidenceRequestedOnly` on `AnthropicMessages`
yields `[]`. In `baikai/test/EvidenceSpec.hs`, add JSON round-trip rows for both kinds.

The plan, in `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`:

```haskell
-- | The sampling parameters that will reach the wire, after the
-- record's gate. 'Nothing' means the field is omitted.
data SamplingPlan = SamplingPlan
  { temperature :: !(Maybe Double),
    topP :: !(Maybe Double)
  }
  deriving stock (Eq, Show, Generic)

-- | @max_tokens@ sent for a model whose cap is unknown (0) when the
-- caller set no 'Baikai.Options.maxTokens'. Anthropic requires the
-- field and rejects 0; 1024 is the SDK's own default and is accepted
-- by every generation and every known compatible host.
uncappedMaxTokensFloor :: Natural
uncappedMaxTokensFloor = 1024

-- | Everything 'mapRequest' decides about thinking, sampling and the
-- output ceiling, and the one description of all of it.
planRequest :: Model -> Options -> (ThinkingPlan, SamplingPlan, ThinkingTranslation)
```

`planRequest` computes `compat = anthropicMessagesCompatFor m`, `cap`, and `base = case
opts ^. #maxTokens of Just n -> n; Nothing | cap == 0 -> uncappedMaxTokensFloor |
otherwise -> cap`; runs `computeThinking` and the budget-fit rule on `base` exactly as
`planThinking` does today (lines 122–136); builds the `SamplingPlan` from
`opts.temperature` / `opts.topP` when `supportsSamplingParameters compat`, else both
`Nothing`; and appends to `adjustments`, in order, `SamplingDroppedUnsupportedModel names`
when the record gates and at least one of the two is set (wire order, only those set), then
`SamplingDroppedUnsupportedApi names` for whichever of `seed`, `frequencyPenalty`,
`presencePenalty` are set (`seed`, `frequency_penalty`, `presence_penalty`). Redefine
`planThinking m opts = let (t, _, tr) = planRequest m opts in (t, tr)` and keep
`describeThinkingFor = snd . planThinking`, so the builder and the strict gate see one
description (ADR 0003). In `mapRequest`, take all three from `planRequest`, set
`Messages.temperature` and `Messages.top_p` from the sampling plan, and compute
`max_tokens` from the same `base`. Export `SamplingPlan`, `planRequest`,
`uncappedMaxTokensFloor` and `normalizeToolCallId` as test seams.

Replay sanitation, same file: `userContentToBlock` and `assistantContentToBlock` return
`Nothing` for an empty text block. `mapMessage` becomes `Message -> Either Text (Maybe
Messages.Message)`: an assistant message whose mapped content is empty yields `Right
Nothing`; a user message whose mapped content is empty yields `Left "Anthropic Messages
rejects a user turn with no content blocks"`; otherwise `Right (Just msg)`. `mapRequest`
uses `catMaybes <$> traverse mapMessage …`. State the three outcomes and their reasons in
the Haddock.

Tool-call ids:

```haskell
normalizeToolCallId :: Text -> Text
normalizeToolCallId original
  | isValid original = original
  | otherwise = Text.take 51 (Text.map sanitise original) <> "_" <> suffix
  where
    isValid t = not (Text.null t) && Text.length t <= 64 && Text.all allowed t
    allowed c = (isAscii c && isAlphaNum c) || c == '_' || c == '-'
    sanitise c = if allowed c then c else '_'
    suffix =
      Text.take 12
        (Text.decodeLatin1 (Base16.encode (SHA256.hash (Text.encodeUtf8 original))))
```

Add `cryptohash-sha256` and `base16-bytestring` to `baikai-claude.cabal`'s library
`build-depends` (already in the build plan through `baikai`). In `mapMessage`'s assistant
branch, collect the normalised `tool_use` ids and return `Left "duplicate tool_use id
after normalisation: <id>"` on a repeat.

Cache pricing: extend the Haddock of `finalUsage` (`Api.hs` line 800) and
`anthroUsageToBaikai` (line 888) with the limitation from the Decision Log and touch
nothing else in that file; add the bullet to `docs/user/prompt-caching.md` "Notes and
limits".

Tests in `baikai-claude/test/`. In `ThinkingSpec.hs`, make `anthropicModels` four columns
`(String, Model, AnthropicThinkingStyle, Bool)`, flipping the row

```haskell
    ("claude-sonnet-4-6", anthropic_claude_sonnet_4_6, AnthropicThinkingBudget)
```

to `AnthropicThinkingAdaptive` with `True`, adding `("claude-sonnet-5",
anthropic_claude_sonnet_5, AnthropicThinkingAdaptive, False)` and the sampling column for
every row per the Decision Log. Add a `samplingTests` group over the table that sets
`temperature = Just 0.2` and `topP = Just 0.9`: `False` rows yield `Messages.temperature
req == Nothing`, `Messages.top_p req == Nothing` and adjustments ending in
`SamplingDroppedUnsupportedModel ["temperature","top_p"]`; `True` rows forward both and
record no sampling adjustment. Add "sampling is dropped and recorded even when no
thinking level is set" (sonnet-5, `thinking = Nothing`, `temperature = Just 0.2`: `mode
== ThinkingModeAbsent`, `requested == Nothing`, `adjustments ==
[SamplingDroppedUnsupportedModel ["temperature"]]`); "seed and penalties are recorded as
API-level drops" (haiku-4-5, `seed = Just 7`, `presencePenalty = Just 0.3`: `adjustments
== [SamplingDroppedUnsupportedApi ["seed","presence_penalty"]]`); `zeroCapFloorTests`
(`emptyModel & #api .~ AnthropicMessages & #reasoning .~ True`, no `maxTokens`: without
thinking `max_tokens == 1024`; with `ThinkingLow` `max_tokens == 3072` and `ThinkingEnabled
2048` kept — today the budget is dropped and `max_tokens` is 0; `handRolledUnclampedTest`
stays); `replaySanitationTests` (an assistant turn `[AssistantText ""]` then a user turn
maps to one message; `[AssistantText "", AssistantText "visible"]` maps to one block; a
turn of only unsigned thinking is dropped; `[AssistantToolCall tc, AssistantText ""]` keeps
the tool call; a user turn `[UserText ""]` yields `Left` containing "user turn"); and
`toolIdTests` (`toolu_01ABC` and `call_abc-123_x` unchanged; `a.b` and `a_b` distinct and
both within the alphabet and length; a 70-character id normalises to at most 64 with `_`
at position 52; a `tool_use` id `a.b` and the tool result answering it map to the same
id; two tool calls with id `dup` in one turn yield `Left` containing "duplicate"). In
`Main.hs`, extend `optionsMappingTest` to assert the translation's adjustments equal
`[SamplingDroppedUnsupportedApi ["seed","frequency_penalty","presence_penalty"]]`. In
`EvidenceSpec.hs`, add "a dropped sampling parameter appears in the evidence record" using
the module's `replay` helper (line 184) with `testModel` pinned to
`CompatAnthropicMessages (defaultAnthropicMessagesCompat {supportsSamplingParameters =
False})` and `baseOptions & #temperature .~ Just 0.2`, asserting `field "thinking" ev` has
`mode == "absent"` and one adjustment with `kind == "sampling_dropped_unsupported_model"`
and `fields == ["temperature"]`; and add a usage-mapping case whose `message_start`
fixture carries `cache_creation_input_tokens: 40` and `cache_read_input_tokens: 60`,
asserting `usage.observed` has `cache_write_tokens == 40`, `cache_read_tokens == 60`,
`input_tokens` as in the fixture and `total_tokens` equal to their sum plus output — the
Theme I residual on the Claude mapping, pinned here because this plan documents the
pricing of exactly those counts.

Acceptance: `cabal test baikai baikai-claude` passes; the encoded body for
`anthropic_claude_sonnet_5` with `ThinkingHigh` contains `"thinking":{"type":"adaptive"}`
and no `budget_tokens`; with `temperature = Just 0.2` it has no `temperature` key and the
translation lists the adjustment (Validation, item 2).

### Milestone 3 — OpenAI-compatible reasoning controls gated on `Model.reasoning` with a recorded adjustment

Scope: a request with `thinking = Just lvl` against an OpenAI-compatible model whose
catalog entry says `reasoning = False` sends no `reasoning_effort`, `reasoning`,
`thinking` or `enable_thinking` key and records `ThinkingDroppedUnsupportedModel lvl`, so
`openai_gpt_4o_mini` plus a level no longer 400s and `docs/user/model-call-evidence.md`
line 101 becomes true on both API adapters.

In `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`, give `injectThinkingShape`,
`describeThinkingShape`, `shapeRequestBody` and `streamRequestBody` a `Bool` argument
immediately after the compat record, documented as "whether the model advertises
reasoning support (`Baikai.Model.reasoning`)". When `thinking opts` is `Just lvl` and the
flag is `False`, `injectThinkingShape` returns the body unchanged with `ThinkingTranslation
{requested = Just lvl, mode = ThinkingModeUnsupported, effortText = Nothing, budgetTokens
= Nothing, wireField = Nothing, adjustments = [ThinkingDroppedUnsupportedModel lvl]}`
before consulting `thinkingFormat`; update its Haddock. In `Internal/Request.hs`, change
`reasoningEffortField` to `if m ^. #reasoning then applyThinkingFormat compat
(opts ^. #thinking) else Nothing` and rewrite the stale Haddock on `applyThinkingFormat` (lines
110–114 claim the non-OpenAI formats are "silently dropped"; `Shape.injectThinkingShape`
injects them). In `Provider/OpenAI/Api.hs`, pass `(m ^. #reasoning)` at line 143
(`describeThinkingShape`) and at line 267 (`streamRequestBody` in `prepareCall`); those
two lines are the only edits there and lie outside EP-4's and EP-5's regions.

Tests. `ShapeSpec.deepseekShapeTest` (lines 45–57) asserts, on
`Models.deepseek_deepseek_chat` (`reasoning = False`),

```haskell
    lookupTop "thinking" value
      @?= Just (Aeson.object ["type" .= ("enabled" :: Text.Text)])
    lookupTop "reasoning_effort" value @?= Just (String "high")
```

Change its model to `Models.deepseek_deepseek_reasoner` (`reasoning = True`, same host
and compat) and its `max_tokens` expectation to that model's cap, so it keeps proving the
DeepSeek shape; add `nonReasoningModelGateTest`: the same call on
`deepseek_deepseek_chat` yields no `thinking` and no `reasoning_effort` key and a
translation with `mode == ThinkingModeUnsupported` and `adjustments ==
[ThinkingDroppedUnsupportedModel ThinkingHigh]`, plus a row on `Models.openai_gpt_4o_mini`
asserting no `reasoning_effort` key. Update `shapedCall` to pass `(model ^. #reasoning)`;
`hostWith` builds on `openai_gpt_5_6_terra` (`reasoning = True`), so the forty-two-row
table is unaffected. In `EvidenceSpec.hs`, add `& #reasoning .~ True` to `toggleModel`
(line 304) so `toggleHostIndistinguishabilityTest` keeps proving the toggle collapse, and
add `nonReasoningModelEvidenceTest`: `testModel` with `#thinking .~ Just ThinkingMax`
yields a body without `reasoning_effort` and an evidence record with `thinking.mode ==
"unsupported"` and one adjustment `kind == "thinking_dropped_unsupported_model"`,
`requested == "max"`.

Documentation. In `docs/user/model-call-evidence.md`, the adjustments table (lines
96–103) gains the two sampling rows and the sentence "There are six places … only four of
them are effort mappings at all" becomes "eight places … two of which are not about
reasoning at all"; the `thinking_dropped_unsupported_model` row is unchanged because it is
now true. In `docs/user/models-and-providers.md` "Hand-rolled models", state that a
hand-rolled model must set `reasoning = True` for `Options.thinking` to reach the wire on
either API provider, and that a hand-rolled Anthropic model naming an adaptive-era id must
carry `CompatAnthropicMessages (defaultAnthropicMessagesCompat {thinkingStyle =
AnthropicThinkingAdaptive, supportsSamplingParameters = False})` or start from the catalog
value; add a "Sampling parameters" subsection under "Reasoning effort" saying which
`Options` fields reach which API and what is recorded when they do not.

Acceptance: `cabal test baikai-openai` passes with the renamed and added tests listed, and
`shapedBody Models.openai_gpt_4o_mini (emptyOptions & #thinking .~ Just ThinkingHigh)
emptyContext` contains no `reasoning_effort` key.

### Milestone 4 — every catalog entry pinned in `ThinkingSpec`/`CatalogSpec`; keyed smoke cases written

Scope: every Anthropic catalog id appears in `ThinkingSpec.anthropicModels` with all four
columns and in the `CatalogSpec` table, a guard ties both to `allModels` so a future
refresh cannot add an unpinned model, the smoke suite carries what a keyed run must show,
the guides and capability records describe shipped behaviour, and the keyless gate is
green.

Pins: add "anthropicModels covers exactly the catalog's Anthropic ids" to `ThinkingSpec`
— the sorted `modelId`s of the table equal the sorted `modelId`s of `[m | m <- allModels,
m ^. #api == AnthropicMessages]` — and the same guard for the `CatalogSpec` table. Both
must list `claude-sonnet-5`.

Smoke. In `baikai-smoke/test/ThinkingSmoke.hs`, add to `runThinkingCases`
`runAnthropicCase "claude-sonnet-5-thinking-adaptive" Models.anthropic_claude_sonnet_5
ThinkingMedium` (the helper already sets `temperature = Just 0.0`, so one call exercises
the adaptive shape, the sampling drop and signed replay; before this plan it is a 400) and
a new `runAnthropicSamplingCase "claude-sonnet-5-sampling-dropped"
Models.anthropic_claude_sonnet_5` sending no level, `temperature = Just 0.2`, `maxTokens =
Just 32`, asserting `responseError resp == Nothing` and non-empty text; both print
`[baikai-smoke] none of ["ANTHROPIC_KEY","ANTHROPIC_API_KEY"] set; skipping <label>.`
without a key. In `baikai-smoke/test/Smoke.hs`, add to `apiCases` `ApiCase {caseLabel =
"deepseek-chat", caseEnvVars = ["DEEPSEEK_KEY","DEEPSEEK_API_KEY"], caseModel =
Models.deepseek_deepseek_chat & #maxOutputTokens .~ 1024}` and `ApiCase {caseLabel =
"openrouter-gpt-4o-mini", caseEnvVars = ["OPENROUTER_API_KEY"], caseModel =
Models.openrouter_openai_gpt_4o_mini & #maxOutputTokens .~ 1024}`, so the tool and
structured-output smokes run against them; a keyed failure there (for example DeepSeek
rejecting `json_schema`) is a finding to record and hand to the owning plan, not a case to
remove. In `CompatSmoke.runDeepSeekMaxTokensCase`, after `assertNonEmptyText`, assert
`(resp ^. #message) ^. #usage ^. #outputTokens <= 16` and print the count. In
`CacheSmoke`, extend `assertCachePositive` with the two `Cost` values and assert
`cachedWriteUsd > 0` on the first call and `cachedInputUsd > 0` on the second.

Documentation and changelog. `docs/user/models-and-providers.md` "The generated catalog"
and "Adding a model to the catalog": every Anthropic entry carries an explicit compat
block (show it), replacing "Per-model `compat` overrides are supported but rarely needed:
EP-5's `baseUrl` auto-detection covers every shipped host".
`docs/capabilities/generated-model-catalog.md`: mention the two facts and the generator's
refusal. `docs/capabilities/reasoning-effort-control.md` Limits: the sampling drop and
the `Model.reasoning` gate. `docs/capabilities/anthropic-messages-backend.md` Limits: the
sampling and cache-pricing bullets. `docs/capabilities/model-call-evidence.md`: wherever
kinds are enumerated (grep `thinking_dropped_unsupported_host`), add the two sampling
kinds. `CHANGELOG.md` under `[Unreleased]`: `baikai` Added (`supportsSamplingParameters`,
the two adjustments, `weakensThinking`, schema `1.1`, explicit Anthropic catalog records,
generator refusal), Deprecated (`defaultAnthropicThinkingStyle`), Changed (`CompatNone` no
longer applies a generation default); `baikai-claude` Fixed (sonnet-5 adaptive, sampling
drop, zero-cap floor, replay sanitation, tool-id suffix) and Changed (sonnet-4-6
adaptive); `baikai-openai` Changed (reasoning controls gated on `Model.reasoning`, `Shape`
signatures). Tick the four EP-3 rows in the MasterPlan's Progress as each milestone lands.

Acceptance: the keyless gate passes every suite; with a key, `cabal test baikai-smoke`
prints `[baikai-smoke] claude-sonnet-5-thinking-adaptive ok via ANTHROPIC_API_KEY;
thinking signature replay accepted` and `[baikai-smoke] claude-sonnet-5-sampling-dropped
ok via ANTHROPIC_API_KEY`.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Confirm the SDK facts first (path from `mori registry show MercuryTechnologies/claude
--full`):

```bash
grep -n "data Thinking\|ThinkingAdaptive\|budget_tokens\|^data Usage\|cache_creation\|omitNothingFields" \
  /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1/Messages.hs \
  /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/Prelude.hs
```

Expect `data Thinking = ThinkingAdaptive | ThinkingEnabled { budget_tokens :: Natural }`, a
`Usage` with `cache_creation_input_tokens :: Maybe Natural` and no `cache_creation`
object, and `omitNothingFields = True`.

Milestone 1. Preview the rendered block without the network, then edit the JSON,
regenerate, build and test:

```bash
cabal run baikai-fetch-models -- --from-file baikai/test/fixtures/models-dev-sample.json --provider anthropic --stdout
cabal run baikai-gen-models
git --no-pager diff --stat baikai/src/Baikai/Models/Generated.hs
cabal test baikai --test-show-details=direct
```

Expected, in order: the fixture's `claude-opus-4-5` rendered with a
`"compat": {"kind": "anthropic-messages", "thinkingStyle": "budget",
"supportsSamplingParameters": true}` block between `"maxOutputTokens"` and `"enabled"`;
then

```text
Wrote /Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/Models/Generated.hs (35 enabled models)
 baikai/src/Baikai/Models/Generated.hs | 81 ++++++++++++++++++++++++++++++++---
Baikai.Models.Generated
  regenerating from data/models produces no diff:                                      OK
  every Anthropic catalog entry carries an explicit thinking style and sampling flag:  OK
All N tests passed
```

A build failure `Not in scope: 'supportsLongCacheRetention'` inside `Generated.hs` is the
header hazard from Context: fix the imports in `renderModule` and regenerate.

Milestones 2 and 3:

```bash
cabal build baikai baikai-claude baikai-openai --enable-tests
cabal test baikai baikai-claude baikai-openai --test-show-details=direct
```

Expected shape (tasty prints one line per case; counts differ):

```text
ThinkingSpec
  mapRequest max_tokens
    claude-sonnet-5 high selects expected thinking style:                 OK
  sampling parameters
    claude-sonnet-5 drops temperature and top_p and records it:           OK
    claude-sonnet-4-6 forwards temperature and top_p:                     OK
  zero-cap floor
    hand-rolled model with unknown cap sends the 1024 floor:              OK
All N tests passed
```

Milestone 4, the keyless gate quoted from `agents/skills/release/SKILL.md` (run in
`zsh`; adjust the two filtered `PATH` entries to wherever the coding agents live):

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

Every suite must pass, not merely skip, and `baikai-smoke` must print:

```text
[baikai-smoke] none of ["ANTHROPIC_KEY","ANTHROPIC_API_KEY"] set; skipping claude-sonnet-5-thinking-adaptive.
[baikai-smoke] none of ["ANTHROPIC_KEY","ANTHROPIC_API_KEY"] set; skipping claude-sonnet-5-sampling-dropped.
```

With a key (not assumed by this initiative): `ANTHROPIC_API_KEY=… cabal test baikai-smoke
--test-show-details=direct`.

Commit per milestone with conventional commits; every commit carries the three trailers.
The M1 commit includes the ADR and its README row; changelog lines go in the commit with
the code they describe. Examples:

```text
feat(catalog): carry Anthropic thinking style and sampling support on every catalog record

The prefix table in Baikai.Compat routed claude-sonnet-5 to budget_tokens,
which the current generation rejects. Every anthropic-messages entry now
carries an explicit compat block, produced from the fetcher's curation
map and refused by the generator when missing. defaultAnthropicThinkingStyle
is deprecated and no longer consulted.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/60-make-anthropic-thinking-style-and-sampling-support-catalog-driven.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(claude): honour the catalog record when shaping thinking, sampling, max_tokens and replay

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/60-make-anthropic-thinking-style-and-sampling-support-catalog-driven.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

The M3 and M4 commits are `fix(openai): gate reasoning controls on Model.reasoning and
record the drop` and `test(smoke): pin every Anthropic catalog id and add the sonnet-5
keyed cases`, with the same three trailers. Update the Progress checklist at every
stopping point.


## Validation and Acceptance

Each item names the exact observation; "before" means at `5411947`.

1. Catalog record (M1). In `cabal repl baikai`, `compat anthropic_claude_sonnet_5` (after
   `import Baikai` and `import Baikai.Models.Generated`) prints `CompatAnthropicMessages
   (AnthropicMessagesCompat {supportsLongCacheRetention = True, supportsCacheControlOnTools
   = True, sendSessionAffinityHeaders = False, thinkingStyle = AnthropicThinkingAdaptive,
   supportsSamplingParameters = False})`; before, `CompatNone`.
   `anthropicMessagesCompatFor anthropic_claude_sonnet_4_6 ^. #thinkingStyle` is
   `AnthropicThinkingAdaptive`; before, `AnthropicThinkingBudget`. Removing one `compat`
   block from `anthropic.json` makes `cabal run baikai-gen-models` exit non-zero with
   `anthropic-messages entry anthropic/<id> has no compat block`.

2. Encoded request (M2). In `cabal repl baikai-claude`:

   ```haskell
   import Baikai
   import Baikai.Models.Generated
   import Baikai.Provider.Claude.Internal.Request (mapRequest)
   import Baikai.Provider.Claude.Shape (streamRequestBody)
   import Data.Aeson (encode, toJSON)
   let Right (req, tr) = mapRequest anthropic_claude_sonnet_5 emptyContext (emptyOptions & #thinking .~ Just ThinkingHigh & #temperature .~ Just 0.2)
   encode (streamRequestBody (anthropicMessagesCompatFor anthropic_claude_sonnet_5) emptyContext emptyOptions req)
   tr
   encode (toJSON tr)
   ```

   The body contains `"thinking":{"type":"adaptive"}` and `"max_tokens":128000` and no
   `budget_tokens`, `temperature` or `top_p` key; `tr` shows `mode = ThinkingModeAdaptive`,
   `effortText = Nothing`, `adjustments = [EffortOmitted ThinkingHigh,
   SamplingDroppedUnsupportedModel ["temperature"]]`; the JSON contains
   `{"kind":"sampling_dropped_unsupported_model","fields":["temperature"]}`. Before: the
   body has `"thinking":{"type":"enabled","budget_tokens":16384}` and `"temperature":0.2`.
   The same call on `anthropic_claude_sonnet_4_5` keeps `"temperature":0.2` and records
   only the thinking side.

3. Zero-cap floor (M2). `mapRequest (mkModel AnthropicMessages "custom-claude" "" &
   #reasoning .~ True) emptyContext (emptyOptions & #thinking .~ Just ThinkingLow)` yields
   `max_tokens = 3072` and `thinking = Just (ThinkingEnabled 2048)`; before, `max_tokens =
   0` and `thinking = Nothing`.

4. Replay and ids (M2). `[assistant [AssistantText ""], user "x"]` maps to a single user
   message; `[user [UserText ""]]` maps to `Left`; `normalizeToolCallId "a.b" /=
   normalizeToolCallId "a_b"` and both match `[A-Za-z0-9_-]{1,64}`.

5. OpenAI gate (M3). `mapRequest openai_gpt_4o_mini emptyContext opts` with `thinking =
   Just ThinkingHigh`, then `streamRequestBody (openaiCompletionsCompatFor
   openai_gpt_4o_mini) False opts req`, yields a body without `reasoning_effort` and a
   translation with `adjustments = [ThinkingDroppedUnsupportedModel ThinkingHigh]`; before,
   `"reasoning_effort":"high"`.

6. Strict mode (M2). `checkEvidenceRequirements (EvidenceRequired EvidenceRequestedOnly)
   AnthropicMessages tr` for item 2's `tr` returns `[ThinkingWouldDowngrade [EffortOmitted
   ThinkingHigh]]`: the sampling drop is in the evidence but does not refuse the call.

7. Suites. `cabal test baikai baikai-claude baikai-openai --test-show-details=direct`
   passes; these fail before and pass after: `ThinkingSpec` "claude-sonnet-5 … selects
   expected thinking style", "claude-sonnet-5 drops temperature and top_p and records
   it", "hand-rolled model with unknown cap sends the 1024 floor", the replay and tool-id
   groups; `CatalogSpec` "every Anthropic catalog entry carries an explicit thinking style
   and sampling flag"; `ShapeSpec.nonReasoningModelGateTest`;
   `EvidenceSpec.nonReasoningModelEvidenceTest`.

8. Keyless gate (M4). The `env -u … cabal test all` command passes every suite and prints
   the two `claude-sonnet-5` skip lines.

9. Keyed smoke (M4, when a key exists). `ANTHROPIC_API_KEY=… cabal test baikai-smoke`
   prints `[baikai-smoke] claude-sonnet-5-thinking-adaptive ok via ANTHROPIC_API_KEY;
   thinking signature replay accepted` and `[baikai-smoke] claude-sonnet-5-sampling-dropped
   ok via ANTHROPIC_API_KEY`. If Anthropic rejects a shape the facts table chose (for
   example if `claude-sonnet-4-6` rejects adaptive), the fix is one `anthropicInclude`
   entry, a regeneration and a Decision Log entry; record the response body in Surprises
   & Discoveries. With `DEEPSEEK_API_KEY` and `OPENROUTER_API_KEY`, the tool and
   structured cases run against the two new `apiCases` rows and `CompatSmoke` prints the
   DeepSeek output-token count.


## Idempotence and Recovery

Every step is a source edit plus `cabal build`/`cabal test`, safe to repeat. `cabal run
baikai-gen-models` is deterministic; running it twice produces byte-identical output,
which `CatalogSpec` proves. `baikai-fetch-models` is only run here with `--from-file …
--stdout`, so nothing on disk changes unless you edit `anthropic.json`; a later live
refresh regenerates the blocks from `anthropicInclude`, so they cannot be lost. The
milestones are independently committable: M1 alone fixes the `claude-sonnet-5` thinking
400, M2 stands without M3, M3 without M4.

If the build fails after adding the two constructors, the cause is a non-exhaustive match
wherever the sum is consumed (`Evidence.hs` instances, `Build.hs` `describeAdjustment`,
possibly a sink); add the cases, never loosen `-Werror=incomplete-patterns`. If EP-8 lands
first and has reshaped the vocabulary, add the two constructors to whatever sum it defines
and keep the JSON spellings from the Decision Log, recording the divergence in both plans.
If EP-2 lands first, `Compat.hs` rebases cleanly because the regions are disjoint; do not
touch `urlHost` or its replacement. A failed keyed smoke case affects no offline suite:
correct the facts map or the adapter, regenerate, rerun; the calls are read-only requests
billed at a few cents. Reverting a milestone is `git revert` of its commit followed by
`cabal run baikai-gen-models` if catalog data was part of it.


## Interfaces and Dependencies

External: the MercuryTechnologies `claude` SDK 1.4.0 (checkout at
`/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/`) supplies
`Claude.V1.Messages.Thinking` (`ThinkingAdaptive | ThinkingEnabled {budget_tokens ::
Natural}`), `CreateMessage` with `max_tokens :: Natural`, `temperature`, `top_p` and
`top_k` as `Maybe`, and `Usage` without a per-TTL cache breakdown; its `omitNothingFields
= True` encoding is what makes a `Nothing` sampling field absent on the wire. No SDK
change is required. `cryptohash-sha256` and `base16-bytestring` become direct
dependencies of `baikai-claude` (already in the build plan through `baikai`).

At the end of Milestone 1: `Baikai.Compat.AnthropicMessagesCompat.supportsSamplingParameters
:: Bool` (exported selector, default `True`); `defaultAnthropicThinkingStyle` deprecated
and unused; `Baikai.Model.anthropicMessagesCompatFor` returning the explicit record or host
auto-detection only; `FetchModelsCore.AnthropicGenerationFacts {thinkingStyle,
supportsSamplingParameters}`, `CatalogModelCompat`, `anthropicInclude :: Map Text
AnthropicGenerationFacts`, `CatalogModel.compat`, `ProviderSpec.compatFor`;
`GenModelsCore.parseAnthropicThinkingStyle` and `checkAnthropicCompat :: [(Text,
GeneratedEntry)] -> Either Text ()`; nine `compat` blocks in `anthropic.json` and nine
explicit records in `Generated.hs`; the ADR file.

At the end of Milestone 2: `Baikai.Evidence.ThinkingAdjustment` with
`SamplingDroppedUnsupportedModel ![Text]` and `SamplingDroppedUnsupportedApi ![Text]`;
`Baikai.Evidence.weakensThinking :: ThinkingAdjustment -> Bool`; `evidenceSchemaVersion =
"baikai.model-call-evidence/1.1"`; `checkEvidenceRequirements` filtering through
`weakensThinking`; `Baikai.Provider.Claude.Internal.Request.planRequest :: Model ->
Options -> (ThinkingPlan, SamplingPlan, ThinkingTranslation)`, `SamplingPlan {temperature,
topP}`, `uncappedMaxTokensFloor :: Natural`, `planThinking` and `describeThinkingFor`
defined through `planRequest`, `mapMessage :: Message -> Either Text (Maybe
Messages.Message)`, the hash-suffixed `normalizeToolCallId` (exported).

At the end of Milestone 3: `Baikai.Provider.OpenAI.Shape.injectThinkingShape ::
OpenAICompletionsCompat -> Bool -> Options -> Value -> (Value, ThinkingTranslation)` and
the same added `Bool` on `describeThinkingShape`, `shapeRequestBody` and
`streamRequestBody`; `Baikai.Provider.OpenAI.Internal.Request.mapRequest` consulting
`Model.reasoning`.

At the end of Milestone 4: the four-column `ThinkingSpec.anthropicModels` and the
`CatalogSpec` table, each guarded against `allModels`;
`ThinkingSmoke.runAnthropicSamplingCase`; the two new `apiCases` rows; the `CompatSmoke`
and `CacheSmoke` assertions; the guide, capability and changelog text named in M4.

Cross-plan contract: EP-8 threads `describeThinkingFor` through `immediateError` (C.8's
other half and D.2) and records the two constructors, `weakensThinking` and the `1.1`
bump without re-bumping; EP-10 keeps `AnthropicMessagesCompat`'s constructor unexported,
removes `defaultAnthropicThinkingStyle` at the next major with a changelog line naming the
version, and may relocate the new `Request.hs` names behind `.Internal`; EP-11 documents
the catalog fields beyond what M4 writes; EP-2 owns `urlHost`, which this plan never
needs because the style now comes from the record.
