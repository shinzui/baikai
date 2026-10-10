---
id: 91
slug: price-claude-haiku-5-5-s-prompt-length-tiers-and-add-it-to-the-catalog
title: "Price Claude Haiku 5.5's prompt-length tiers and add it to the catalog"
kind: exec-plan
created_at: 2026-10-10T15:39:28Z
intention: "intention_01m4k7g4c7ehhawmysmbe83ykx"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-10T15:39:28Z
---

# Price Claude Haiku 5.5's prompt-length tiers and add it to the catalog

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Anthropic released Claude Haiku 5.5 (`claude-haiku-5-5`) on 2026-10-07. It is the cheapest
current Claude model, with a 1,000,000-token context window and a 128,000-token output limit.
Its price depends on the prompt's length, unlike any Claude model in baikai's catalog. A request
whose prompt exceeds 100,000 tokens pays a higher rate on every token category, including its
one-hour cache writes. The 2026-10-10 catalog refresh did not add Haiku 5.5. Baikai could shape
its requests correctly, but it would report the wrong cost for one reachable configuration, with
nothing marking the figure as an estimate.

After this plan, a caller can import `Baikai.Models.Generated.anthropic_claude_haiku_5_5`, register
`Baikai.Provider.Claude.Api`, and send text and function-tool conversations. Each response's
`Usage.cost` is exact at both prompt-length tiers and both cache durations. To see it working, run
the offline pricing tests and the two new live smoke cases, `haiku55-text` and `haiku55-tools`.
Both show the observed model `claude-haiku-5-5`, a standard cost basis, and a completed tool
round trip.


## Progress


- [ ] Milestone 1: a pricing policy can state a one-hour cache-write rate for each prompt-length
  tier, and `Baikai.Cost.Pricing.resolveRates` applies the selected tier's rate. A new
  `PricingPolicySpec` case fails before the change and passes after it. One million long cache
  writes in a prompt over 100,000 tokens cost exactly $1.00; today they cost $0.20. Every
  existing pricing test and the byte-for-byte catalog regeneration check still pass.
- [ ] Milestone 2: `claude-haiku-5-5` is curated into `anthropicInclude` with dated facts and a
  pricing policy. The regenerated catalog exports `anthropic_claude_haiku_5_5`. Offline Claude
  request-shaping tests pin its thinking, sampling, effort and forced-tool-choice wire shapes.
  Documentation and changelogs describe it.
- [ ] Milestone 3: live acceptance. `haiku55-text` and `haiku55-tools` pass against the real
  Messages API, and their redacted summary is saved under `docs/validation/plan-91/`. One bounded
  request settles whether baikai's exact forced-tool-choice body is accepted. The catalog fact
  stays or changes according to the decision rule in the Plan of Work.


## Surprises & Discoveries


(None yet.)


## Decision Log


- Decision: Haiku 5.5 was left out of the 2026-10-10 refresh rather than shipped with a known
  misprice.
  Rationale: models.dev already carries the ID with correct base rates, so the fetcher could emit
  it. However, `resolveRates` replaces the selected tier's cache-write rate with the single
  policy-level `longCacheWriteCost`. A one-hour write in a prompt over 100,000 tokens would
  therefore be billed at $0.20/M instead of $1/M, five times too low. The figure would carry no
  estimate reason. ADR 0020 requires missing billing knowledge to be explicit, so the binding
  waits for Milestone 1.
  Date: 2026-10-10

- Decision: represent the tier-specific long rate as an optional absolute price on each
  `InputPriceTier`, not as a multiplier of the input rate.
  Rationale: Anthropic does state that a one-hour write costs twice the base input price, and every
  curated rate fits that rule ($0.20 = 2 × $0.10 and $1 = 2 × $0.50 for Haiku 5.5). However, ADR
  0020 settled on exact absolute decimal prices in the catalog, and a ratio would make an
  Anthropic billing rule part of the provider-neutral pricing record. An absolute per-tier price
  keeps the catalog record a direct transcription of the published price table.
  Date: 2026-10-10

- Decision: a policy that sets a policy-level `longCacheWriteCost` and also has tiers must give
  every tier its own long rate; validation rejects it otherwise.
  Rationale: a tier without its own rate would otherwise fall back silently to the base tier's
  rate. That fallback is the misprice this plan removes. No shipped catalog policy has both
  tiers and a long rate today, so no catalog entry is affected. Decoding hand-written `Model` JSON
  that combines them becomes an error, which is acceptable because the record change already
  requires a major version (see Interfaces and Dependencies).
  Date: 2026-10-10


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


Baikai is a Haskell library for calling large language model APIs. The repository root holds
several Cabal packages. `baikai/` is the core: model records, pricing, the generated catalog, and
the catalog tooling. `baikai-claude/` holds the Anthropic Messages API provider, and
`baikai-smoke/` holds live tests that call real APIs.

The *catalog* is the set of ready-made `Baikai.Model.Model` values exported from
`baikai/src/Baikai/Models/Generated.hs`. That file is generated; never edit it by hand. Its sources
are `baikai/data/models/openai.json` and `baikai/data/models/anthropic.json`. Running `cabal run
baikai-gen-models` from the repository root regenerates it through `baikai/gen/GenModelsCore.hs`.
The JSON in turn is produced by `cabal run baikai-fetch-models`, which reads the public
models.dev database and keeps only curated IDs. Curation lives in
`baikai/fetch/FetchModelsCore.hs`: `anthropicInclude` maps each Anthropic model ID to its
request-shaping facts, and `pricingPolicies` holds pricing rules beyond the four flat rates. The
procedure for a refresh is in `.claude/skills/update-models/SKILL.md`, and the user-facing
reference is `docs/user/models-and-providers.md`.

A *pricing policy* (`Baikai.Model.PricingPolicy` in `baikai/src/Baikai/Model.hs`) is optional on
a model and layers two rules over its flat `cost` record. The first is `inputTiers`, an ordered
list of `InputPriceTier { inputAbove, rates }`. When a request's total input exceeds `inputAbove`,
the complete `rates` record prices every token in that request. Total input is fresh input plus
cache reads plus cache writes. The second is `longCacheWriteCost`, an absolute
per-million-token price for cache writes made with the one-hour duration. Anthropic's prompt
cache has two durations: the default five-minute cache and a one-hour cache whose writes cost
more. Baikai's `CacheRetentionLong` preference asks for the one-hour duration. The Claude
provider reads the duration actually present in the shaped request body
(`shapedCacheDuration` in `baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`) and
passes it to `Baikai.Cost.Pricing.computeCostForService`. That function calls `resolveRates` in
`baikai/src/Baikai/Cost/Pricing.hs`, which currently does this:

```haskell
          selected = foldl' (\current tier -> if totalInput > inputAbove tier then rates tier else current) (m ^. #cost) (inputTiers policy)
      pure $ case (duration, longCacheWriteCost policy) of
        (Just CacheRetentionLong, Just price) -> selected {cacheWriteCost = price}
        _ -> selected
```

The long price overrides whichever tier was selected. For every model shipped today this is
correct: tiered models (the GPT-6 family) have no long price, and models with a long price
(Fable 5.1, Opus 5.5, Opus 5, Opus 4.8, Sonnet 5.5) have no tiers. Haiku 5.5 is the first model
with both.

Claude Haiku 5.5's facts, verified on 2026-10-10 against
https://platform.claude.com/docs/en/models/haiku-5-5/overview,
https://platform.claude.com/docs/en/about-claude/pricing (Model pricing and Long context pricing),
https://platform.claude.com/docs/en/models/haiku-5-5/migration-guide,
https://platform.claude.com/docs/en/models/haiku-5-5/whats-new-haiku-5-5,
https://platform.claude.com/docs/en/build-with-claude/effort and the 2026-10-07 entry of
https://platform.claude.com/docs/en/release-notes/overview, are as follows. The API ID is
`claude-haiku-5-5`, a fixed ID with no date suffix and no separate alias. Input is text and
images, and output is text. The context window is 1,000,000 tokens and the synchronous output
limit is 128,000 tokens. Prices per million tokens for prompts up to 100,000 tokens are $0.10
input, $0.50 output, $0.01 cache read, $0.125 five-minute cache write and $0.20 one-hour cache
write. For prompts over 100,000 tokens they are $0.50, $2.50, $0.05, $0.625 and $1. The pricing
page states that "A request's prompt length counts all of its input tokens, including cache reads
and cache writes", and that each request is priced on its own. Batch is 50% off, and US-only
inference through `inference_geo` multiplies prices by 1.1. Baikai sends neither, so both are
out of scope. Thinking is adaptive and on by default; manual `budget_tokens` thinking returns a
400. The default effort is `medium`, and all five levels are accepted (`low`, `medium`, `high`,
`xhigh`, `max`). Thinking text is omitted unless `thinking.display` is `"summarized"`. A
`temperature` other than 1, a `top_p` other than 0.99, any `top_k`, or both `temperature` and
`top_p` together return a 400. Assistant prefill returns a 400. Forced `tool_choice` (`any` or a
named tool) is accepted, but the response then starts with the tool call and has no thinking
block. Fast mode is not offered: the pricing page lists only Opus 5.5, Opus 5 and Opus 4.8. A
thinking block is valid only in the producing account and only while earlier turns are
unchanged, so conversations must stay append-only. The minimum cacheable prompt is 512 tokens.
models.dev agreed with all base values on 2026-10-10. Its `tiers` list (threshold 100000,
`input` 0.5, `output` 2.5, `cache_read` 0.05, `cache_write` 0.625) is not read by the fetcher.

The Claude provider already supports this model's request shape without new code.
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` reads
`AnthropicMessagesCompat` from the catalog record. With `thinkingStyle =
AnthropicThinkingAdaptive` it sends `thinking: {"type":"adaptive","display":"summarized"}` and
an explicit `output_config.effort` for every requested level; `ThinkingMinimal` becomes `low`,
recorded as an `EffortClamped` adjustment. When `Options.thinking` is unset it sends no thinking
field at all, and it never sends `thinking: {"type":"disabled"}`. With
`supportsSamplingParameters = False` it omits `temperature` and `top_p` and records
`sampling_dropped_unsupported_model`. With `supportsForcedToolChoice = True` it forwards
`ToolChoiceRequired` as `{"type":"any"}` and `ToolChoiceSpecific` as a named tool. With
`supportsFastMode = False` it drops `SpeedFast` and records `fast_mode_dropped_unsupported_model`.
Usage extraction and refusal handling are shared with every other Claude model.

Two ADRs govern this work. [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md)
says what a model accepts on the wire is a field of the compatibility record in its generated
catalog entry, curated in `anthropicInclude` with a dated source comment. No adapter may consult
a table keyed by model ID. [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md)
defines pricing policies. Thresholds are ordered and exclusive; the context measure includes
cache reads and writes; the selected tier prices the whole request; catalog JSON carries exact
decimals; and missing billing knowledge must appear as an estimate reason, never as a silently
wrong number. This plan extends ADR 0020 and must add a dated section to it. [ADR
0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) is relevant to Milestone 3: a
requested forced tool choice and what the API observably did must be recorded separately.

Related plans: `docs/plans/76-account-for-cache-writes-and-context-tier-model-pricing.md`
(complete) introduced pricing policies and is the design this plan extends.
`docs/plans/85-prove-gpt-6-1-sol-and-claude-sonnet-5-5-live-compatibility.md` (complete)
established the live smoke cases this plan copies.
`docs/plans/89-carry-the-claude-sonnet-4-5-binding-through-its-retirement-without-silent-catalog-removal.md`
(open) schedules a breaking release, 0.8.0.0; Milestone 1's record change belongs to that release
too. Neither plan blocks the other, and they touch different parts of `FetchModelsCore.hs`.


## Plan of Work


### Milestone 1: tier-aware long cache-write pricing


Begin with a failing test. In `baikai/test/PricingPolicySpec.hs`, add a case that builds a
Haiku-shaped model by record update from `Baikai.Model.emptyModel`, since the catalog entry does
not exist yet. Give it `cost = ModelCost (1/10) (1/2) (1/100) (1/8)` and a policy with one tier
above 100000 at `ModelCost (1/2) (5/2) (1/20) (5/8)`, a policy-level long price of 1/5, and the
tier's own long price of 1. Assert all of the following:

- Usage with `cacheWriteTokens = 1000000` costs exactly 1 under `computeCostWith (Just
  CacheRetentionLong)` and 5/8 under `computeCostWith (Just CacheRetentionShort)`.
- Usage with `cacheWriteTokens = 50000` costs 1/100 under the long duration and 1/160 under the
  short one.
- Usage of 90000 input, 20000 cache-read and 1000 output tokens costs exactly 97/2000 (0.0485).
- Usage of 80000 input, 20000 cache-read and 1000 output tokens, totalling exactly 100,000 and
  therefore not over the threshold, costs exactly 87/10000 (0.0087).

Before the change, the first long-duration assertion yields 1/5, the misprice.

Then change `Baikai.Model.InputPriceTier` in `baikai/src/Baikai/Model.hs` to carry
`longCacheWriteCost :: !(Maybe Rational)` after `rates`. `DuplicateRecordFields` is enabled in
`baikai/baikai.cabal`, so the name may repeat `PricingPolicy`'s field. Keep JSON backward
compatible: a tier object without the key must decode with `Nothing`. Write an explicit
`FromJSON` instance using `.:?` rather than relying on the generic default, and test decoding of
the old shape. Extend `validatePricingPolicy` so the tier rate must be nonnegative. It must also
reject a policy whose `longCacheWriteCost` is `Just` while any tier's is `Nothing`, with the
message "Every input tier must state its long cache-write rate when the policy has one" (see
the Decision Log). In `resolveRates`, select the long price from the same tier that supplied the
rates: the policy-level price when no tier was crossed, the tier's own price otherwise. Update
the Haddock on `PricingPolicy`, which currently says the long price "overrides the selected
tier's write rate", to describe the new rule.

Follow the type through the tooling. `baikai/gen/GenModelsCore.hs` parses tiers in `parseTier`
and renders them in its policy renderer as `InputPriceTier <n> (<rates>)`. Make it parse the
optional `longCacheWriteCost` key and render the third constructor argument. Every existing
generated tier then renders with `Nothing`, so `Generated.hs` changes for the four GPT-6 tier
lines and nothing else. In `baikai/fetch/FetchModelsCore.hs`, update the positional
`Model.InputPriceTier` constructions in `pricingPolicies` to pass `Nothing`. Make
`renderPricingPolicy`'s inner `tier` emit `, "longCacheWriteCost": <n>` only when the value is
`Just`, so the committed OpenAI JSON stays byte-identical. Update any other positional
construction the compiler reports, such as test helpers in `baikai/test/GenModelsSpec.hs`,
`baikai/test/FetchModelsSpec.hs` and `baikai/test/CostSpec.hs`.

Accept the milestone when `cabal test baikai:baikai-test` passes, including the new case, the
existing GPT-6 threshold tests, the Opus 5.5, Sonnet 5.5 and Fable long-write tests, and
`CatalogSpec`'s byte-for-byte regeneration check. `git diff baikai/data/models/` must be empty.
Add a dated section to ADR 0020 recording that the long rate belongs to the tier, together with
the new validation rule.


### Milestone 2: curate Claude Haiku 5.5


In `baikai/fetch/FetchModelsCore.hs`, add `("claude-haiku-5-5", adaptiveNoSampling)` to
`anthropicInclude`. Its comment must be dated and cite the overview, migration guide and effort
URLs above. It must state adaptive thinking on by default, sampling rejected, forced tool choice
accepted (with no thinking block in that response), and no fast mode. `adaptiveNoSampling` is
`AnthropicGenerationFacts AnthropicThinkingAdaptive False True Nothing`: adaptive style,
sampling unsupported, forced tool choice supported, and no fast rates. Remove the 2026-10-10
comment that says the ID is deliberately absent pending this plan.

Add `(("anthropic", "claude-haiku-5-5"), Model.PricingPolicy [Model.InputPriceTier 100000
(Model.ModelCost 0.5 2.5 0.05 0.625) (Just 1)] (Just 0.2))` to `pricingPolicies`, and add the
pricing URL to the comment above it. In `baikai/test/CatalogSpec.hs`, add `("claude-haiku-5-5",
(AnthropicThinkingAdaptive, False, True, False))` to `expectedAnthropicFacts`. The tuple is
thinking style, sampling support, forced-tool-choice support and fast-mode support.

Fetch a candidate into a temporary directory, as the update-models skill describes. The only
expected difference from the committed `anthropic.json` is the new Haiku entry: base cost
0.1/0.5/0.01/0.125, context 1000000, output 128000, `reasoning: true`, input text and image, the
compat block, and the pricing policy. Check every value against the facts listed in Context and
Orientation. If upstream has drifted elsewhere, verify that drift separately before keeping it.
Copy the candidate, run `cabal run baikai-gen-models`, and confirm that `Generated.hs` gains
`anthropic_claude_haiku_5_5` and nothing else changes.

Add offline request-shaping coverage in `baikai-claude`. Add a Haiku row to the table in
`baikai-claude/test/ThinkingSpec.hs`:
`("claude-haiku-5-5", anthropic_claude_haiku_5_5, AnthropicThinkingAdaptive, False, True,
False)`. Its existing per-level checks then prove that each level sends adaptive thinking with
summarized display and the matching effort word. Add a case to
`baikai-claude/test/FableContractsSpec.hs` or a neighbouring spec. It must show that
`ToolChoiceRequired` on Haiku 5.5 is not rejected locally: the body carries
`"tool_choice":{"type":"any"}` together with the adaptive `thinking` field and
`output_config.effort` `"low"` when `Options.thinking = Just ThinkingLow`. That case also writes
or pins the exact request body Milestone 3 sends live. A further case must show that
`temperature = Just 0.2` is absent from the body and recorded as
`sampling_dropped_unsupported_model`.

Update the stale effort-default statements. One is the Haddock on `adaptiveEffort` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` ("Claude Opus 5.5 defaults to
`medium`, other adaptive models to `high`"). The other is the "Anthropic adaptive thinking" row
of the reasoning-effort table in `docs/user/models-and-providers.md`. Both should name Opus 5.5
and Haiku 5.5 as defaulting to `medium`.

In `docs/user/models-and-providers.md`, add `Models.anthropic_claude_haiku_5_5` to the sample
list and a dated Haiku 5.5 section. It must give the limits, both price tiers, the one-hour
rates, the whole-request rule including cache tokens, the forced-tool-choice behaviour, and the
append-only history requirement. Add `claude-haiku-5-5` to the list of adaptive-era generations
that reject sampling. Remove the note that Haiku 5.5 awaits this plan. Add an Unreleased entry to
`CHANGELOG.md` (`baikai/CHANGELOG.md` is a symbolic link to it) covering the new binding and the breaking
`InputPriceTier` change. Accept the milestone when the offline gate below passes.


### Milestone 3: live acceptance and the forced-tool-choice question


Extend the focused live runner. Add `Models.anthropic_claude_haiku_5_5` to `cases` in
`baikai-smoke/test/NewModelsSmoke.hs`. Add `"haiku55-text"` and `"haiku55-tools"` to `caseNames`
and to the Anthropic branch of `caseProvider` in `baikai-smoke/test/SmokeOptions.hs`. In
`baikai-smoke/test/SmokeOptionsSpec.hs`, change the asserted case count from fourteen to sixteen
and add the two names to its Anthropic list. Both cases use low effort, 4096 output tokens and
automatic tool choice, like every other case. Update the case list in
`docs/user/models-and-providers.md` under "Focused compatibility checks".

Run the two cases with an Anthropic key, as shown in Concrete Steps. Acceptance requires both to
report `passed`, with the observed model `claude-haiku-5-5`, endpoint Messages, and a standard
cost basis with no estimate reasons. The tool case must report two calls and one tool dispatch.
Save the `baikai.new-model-smoke/1` JSON line as
`docs/validation/plan-91/<date>-haiku55.json`; the runner already omits conversations and
signatures. A missing key, a skip, an HTTP 401, or a workspace-selection HTTP 400 leaves this
milestone open. None of them executes the model.

The forced-tool-choice question is the one point the official pages leave open. The migration
guide says Haiku 5.5 "accepts a forced `tool_choice`". It does not say whether that holds when
the request also carries baikai's explicit `thinking: {"type":"adaptive","display":"summarized"}`.
The `anthropicInclude` comments note that older models accept forced choice only subject to a
separate constraint on manual (budget) thinking. No official page describes the
adaptive-plus-forced combination for this model. Settle it
with one request: send the body pinned in Milestone 2 with `curl` to
`https://api.anthropic.com/v1/messages`. Record only the HTTP status, `stop_reason`, the ordered
list of content block `type`s, and the usage counts, in
`docs/validation/plan-91/<date>-forced-tool-choice.json`.

Apply this decision rule. If the status is 200 and the first content block is `tool_use`, keep
`supportsForcedToolChoice = True` and record the observation in Surprises & Discoveries. If the
status is 400 and the error names `tool_choice` or thinking, change the curated fact to `False`
(the `& #supportsForcedToolChoice .~ False` used for Sonnet 5.5). Then regenerate and update
`expectedAnthropicFacts`, the `ThinkingSpec` row and the documentation. Baikai will then reject
forced choice locally with `InvalidRequest` instead of letting the API return a 400. Any other
outcome, such as an authentication failure, is not evidence; retry it rather than acting on it.


## Concrete Steps


All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai` on the
author's machine.

Milestone 1 and 2 offline gate:

```bash
cabal test baikai:baikai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
fourmolu --mode check baikai/fetch/FetchModelsCore.hs baikai/test/CatalogSpec.hs baikai/test/PricingPolicySpec.hs baikai/src/Baikai/Model.hs baikai/src/Baikai/Cost/Pricing.hs baikai/gen/GenModelsCore.hs
git diff --check
```

Expect every suite to report `All N tests passed`. If `fourmolu` reports a file, run it with
`--mode inplace` on that file only; never format `baikai/src/Baikai/Models/Generated.hs`.

Milestone 2 candidate fetch:

```bash
candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/baikai-models.XXXXXX")
cabal run baikai-fetch-models -- --out-dir "$candidate_dir"
diff -u baikai/data/models/anthropic.json "$candidate_dir/anthropic.json"
diff -u baikai/data/models/openai.json "$candidate_dir/openai.json"
```

`diff` exits 1 when the files differ, which is expected for `anthropic.json`. The expected Haiku
entry looks like this:

```json
      "contextWindow": 1000000,
      "maxOutputTokens": 128000,
      "pricingPolicy": {"inputTiers": [{"inputAbove": 100000, "rates": {"input": 0.5, "output": 2.5, "cacheRead": 0.05, "cacheWrite": 0.625}, "longCacheWriteCost": 1.0}], "longCacheWriteCost": 0.2},
```

Milestone 3 live cases (charges a small amount to the Anthropic account):

```bash
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case haiku55-text'
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case haiku55-tools'
```

The variables are `ANTHROPIC_KEY` or `ANTHROPIC_API_KEY`. Also set `ANTHROPIC_WORKSPACE_ID` to the
`wrkspc_...` ID when the key is not scoped to a single workspace. Run each case once and keep its
output; rerunning repeats the charge.

The forced-tool-choice request, with the body file produced in Milestone 2:

```bash
curl -sS https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  ${ANTHROPIC_WORKSPACE_ID:+-H "anthropic-workspace-id: $ANTHROPIC_WORKSPACE_ID"} \
  --data @"$body_file" -w '\n%{http_code}\n'
```


## Validation and Acceptance


Accounting: the new `PricingPolicySpec` case proves exact costs at both tiers and both
durations. It fails before Milestone 1 (1/5 where 1 is expected) and passes after. Existing cases
prove that the GPT-6 thresholds and the Fable, Opus and Sonnet long-write prices are unchanged.
A `Model` JSON round trip with the old tier shape, which has no `longCacheWriteCost` key, decodes
to `Nothing`. A policy with a policy-level long price and a tier without one is rejected with the
validation message.

Catalog: `CatalogSpec` checks byte-for-byte regeneration and the curated facts tuple for
`claude-haiku-5-5`. The generated diff adds exactly one binding beyond the tier-argument change
from Milestone 1.

Request translation: `ThinkingSpec` proves the adaptive shape, summarized display and effort
words for all six levels on Haiku 5.5. The forced-choice case proves that `{"type":"any"}`
reaches the body instead of a local `InvalidRequest`, and the sampling case proves
`temperature` is dropped with its evidence adjustment.

Streaming and tool replay: `haiku55-tools` proves a real two-call conversation in which the
assistant's signed thinking blocks and `tool_use` block are replayed unchanged with the
`tool_result`. Acceptance uses the summary's observed facts, not the requested ones.

Live status: Milestone 3 is accepted only by passing live cases. Until then the documentation
must say Haiku 5.5 is offline-verified only.


## Idempotence and Recovery


All edits are additive except the `InputPriceTier` constructor change, which the compiler
enforces at every construction site. Regeneration is deterministic and can be rerun at any time.
If a candidate fetch shows unexpected upstream drift, do not copy it; edit only the Haiku entry
by applying the curated changes and rerunning the fetch. Live cases are safe to retry, but each
retry is billed. Use `--case` to rerun only a failed case. If the forced-tool-choice decision
flips the fact to `False`, revert the flip by restoring `adaptiveNoSampling` should a later
official source or rerun contradict the first observation, and record both in Surprises &
Discoveries.


## Interfaces and Dependencies


`Baikai.Model.InputPriceTier` becomes:

```haskell
data InputPriceTier = InputPriceTier
  { inputAbove :: !Natural,
    rates :: !ModelCost,
    longCacheWriteCost :: !(Maybe Rational)
  }
```

`Baikai.Model` exports the constructor, so adding a field is a breaking change under the Haskell
Package Versioning Policy. It must ship in a major release, the planned 0.8.0.0 that plan 89 also
targets. Publishing is separate work. `PricingPolicy` keeps its shape and meaning: its
`longCacheWriteCost` is the long rate for prompts below the first threshold.
`Baikai.Cost.Pricing.resolveRates` keeps its signature. The Anthropic Haskell SDK
(`Messages.CreateMessage`) already has every field these requests use (`thinking` with display,
`output_config.effort`, `tool_choice`, `cache_control` with TTL), so no dependency bound
changes. Run `mori registry show` for the SDK project and read its source before assuming
otherwise. No OpenAI module is touched.
