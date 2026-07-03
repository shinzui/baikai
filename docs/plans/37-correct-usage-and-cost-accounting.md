---
id: 37
slug: correct-usage-and-cost-accounting
title: "Correct usage and cost accounting"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Correct usage and cost accounting

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, a caller who runs a prompt-cached request through the OpenAI provider is billed
twice for every cached token: the reported `Cost` charges the cached fraction of the
prompt at the full input rate *and again* at the cache-read rate, and the reported
`totalTokens` is inflated by the same amount. Worse, the two API providers disagree
about what `Usage.inputTokens` means — on the Claude provider it excludes cached
tokens, on the OpenAI provider it includes them — so no downstream consumer (cost
logs, budget guards, dashboards) can interpret a `Usage` value without knowing which
provider produced it.

After this change, `Baikai.Usage.Usage` has one documented, provider-independent
meaning: `inputTokens`, `cacheReadTokens`, and `cacheWriteTokens` are *disjoint* token
classes; `totalTokens` is their sum plus `outputTokens`; `reasoningTokens` is an
informational subset of `outputTokens`. The OpenAI provider mapping is normalized to
that convention, `computeCost` produces the amount the provider actually bills, and
regression tests pin the behavior so it cannot silently regress. You can see it working
by running the two test suites named in Validation and Acceptance: the new OpenAI usage
test feeds a realistic cached-usage wire payload through the real parsing and mapping
code and asserts both the disjoint fields and the exact `Cost`.

This is EP-4 of the MasterPlan at
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`, fixing
Theme 3 of the review at `docs/reviews/2026-07-01-correctness-and-api-review.md`. The
MasterPlan's Integration Points section names this plan as the owner of the `Usage`
field semantics that EP-7 and EP-8 later consume, so the documentation part of this
work is load-bearing, not cosmetic.


## Progress

- [x] Milestone 1: `Usage` invariant written on the record haddock in
      `baikai/src/Baikai/Usage.hs` (disjoint input/cache classes, `totalTokens` sum,
      `reasoningTokens` subset rule). (2026-07-03)
- [x] Milestone 1: cross-provider invariant test group added to
      `baikai/test/UsageSpec.hs` and passing.
      (2026-07-03)
- [x] Milestone 2: pure `rawUsageToUsage` normalizer added to
      `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`; `applyUsage` rewritten to use
      it; `RawUsage (..)`, `parseUsage`, `rawUsageToUsage` exported.
      (2026-07-03)
- [x] Milestone 2: OpenAI usage regression tests (wire payload → disjoint fields →
      exact `computeCost`) added to `baikai-openai/test/Main.hs` and passing.
      (2026-07-03)
- [x] Milestone 2: Claude provider mapping re-verified against the documented
      invariant (read-only check; no edit expected).
      (2026-07-03)
- [x] Final: `cabal build all --enable-tests` clean; `cabal test baikai baikai-openai`
      green; living sections of this plan updated.
      (2026-07-03)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Adopt the Anthropic "disjoint" convention for `Usage` (`inputTokens`
  excludes cache tokens) rather than the OpenAI "inclusive" convention
  (`prompt_tokens` includes `cached_tokens`).
  Rationale: the disjoint form is strictly more informative — the inclusive form is
  recoverable by addition, but the disjoint form cannot be recovered from the
  inclusive one without the details object. `computeCost` in
  `baikai/src/Baikai/Cost/Pricing.hs` already bills each class at its own rate, which
  only makes sense with disjoint classes. The Claude provider already conforms, so
  only the OpenAI mapping changes. The MasterPlan's Integration Points section fixed
  this direction; recorded here for self-containment.
  Date: 2026-07-01
- Decision: Clamp the subtraction `prompt_tokens - cached_tokens` at zero instead of
  letting it underflow.
  Rationale: the fields are `Natural`, and `(-)` on `Natural` throws an `Underflow`
  arithmetic exception at runtime. OpenAI itself always reports
  `cached_tokens <= prompt_tokens`, but this provider is also used against
  OpenAI-compatible hosts (DeepSeek, OpenRouter, Together, …) whose usage counters
  are not trustworthy; a malformed counter must degrade to a slightly-off `Usage`,
  never to a crashed stream worker.
  Date: 2026-07-01
- Decision: Recompute `totalTokens` from the normalized parts
  (`input + output + cacheRead + cacheWrite`) instead of trusting the wire
  `total_tokens` field.
  Rationale: the invariant "totalTokens is the sum of all billed token classes" must
  hold by construction for every host, including compatible hosts that omit or
  mis-report `total_tokens`. For a well-behaved OpenAI response the recomputed value
  equals the wire value: `(prompt - cached) + cached + completion =
  prompt + completion = total_tokens`.
  Date: 2026-07-01
- Decision: `reasoningTokens` is documented as an informational subset of
  `outputTokens` — already counted inside `outputTokens` and `totalTokens`, never
  billed separately — and `Maybe` because some providers do not break it out.
  Rationale: this is what both providers already do, verified against the source.
  OpenAI's `completion_tokens` includes `completion_tokens_details.reasoning_tokens`
  (confirmed in the OpenAI API semantics and mirrored by the SDK types in
  `OpenAI.V1.Usage` of the MercuryTechnologies/openai package, where
  `CompletionTokensDetails.reasoning_tokens` is a detail breakdown of
  `completion_tokens`), and the mapping at
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` never adds `reasoningTokens` into
  `totalTokens`. Anthropic includes thinking tokens in `output_tokens` and reports no
  separate count, so `anthroUsageToBaikai` in
  `baikai-claude/src/Baikai/Provider/Claude/Api.hs` sets `reasoningTokens = Nothing`.
  The two providers therefore already agree with the subset rule; only the
  documentation is missing. No code change is needed for reasoning accounting.
  Date: 2026-07-01
- Decision: Export `RawUsage (..)`, `parseUsage`, and the new `rawUsageToUsage` from
  `Baikai.Provider.OpenAI.Api` so the test suite can exercise the real wire-to-`Usage`
  path without a network call.
  Rationale: the alternative — testing through `openaiChatStream` — requires a live
  endpoint, and duplicating the parser in the test would test a copy, not the code.
  EP-10 (`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`) owns the
  final export surface and may move these behind an `.Internal` namespace; the export
  here carries a haddock note saying so.
  Date: 2026-07-01
- Decision: Request-shaping fixes in the same file (`max_completion_tokens: 0`,
  compat quirks, `timeoutMs`) are explicitly out of scope.
  Rationale: they belong to
  `docs/plans/41-implement-compat-quirks-and-transport-options.md` (EP-8) per the
  MasterPlan decomposition; touching `mapRequest` here would create the parallel-edit
  conflict the wave structure exists to avoid.
  Date: 2026-07-01


## Outcomes & Retrospective

Implemented on 2026-07-03. `Baikai.Usage.Usage` now documents the provider-independent
disjoint token-class invariant on the record and fields, including the rule that
`reasoningTokens` is an informational subset of `outputTokens` and not an additional
billed class. The core usage spec has an executable arithmetic witness for that
invariant.

The OpenAI provider now normalizes inclusive `prompt_tokens` through
`rawUsageToUsage`: cached prompt tokens are subtracted from full-rate input tokens,
the subtraction clamps at zero for malformed compatible-host counters, cache writes
stay zero, and `totalTokens` is recomputed from normalized parts. The OpenAI test
suite feeds wire-shaped JSON through `parseUsage` and `rawUsageToUsage`, then checks
the normalized fields and exact `computeCost` result. The Claude mapping was
re-checked read-only and already satisfies the invariant.

Validation completed:

- `cabal test baikai baikai-openai --test-show-details=direct` — passed; `baikai`
  reported `All 100 tests passed`, `baikai-openai` reported `All 23 tests passed`.
- `cabal build all --enable-tests` — passed.
- `cabal haddock baikai` — passed and generated
  `dist-newstyle/build/aarch64-osx/ghc-9.12.4/baikai-0.2.0.0/doc/html/baikai`;
  `Baikai.Usage` reports 100% Haddock coverage. The command still emits unrelated
  existing documentation/link warnings in other modules.


## Context and Orientation

baikai is a multi-package Haskell library that gives one vocabulary (`Model`,
`Context`, `Options`, `Response`, `Usage`, `Cost`) over several LLM providers. The
packages relevant here:

- `baikai/` — the core package. `baikai/src/Baikai/Usage.hs` defines the `Usage`
  record (token counts for one provider call: `inputTokens`, `outputTokens`,
  `cacheReadTokens`, `cacheWriteTokens`, `reasoningTokens :: Maybe Natural`,
  `totalTokens`, and an embedded `cost`). `baikai/src/Baikai/Cost.hs` defines `Cost`
  (a `Rational` USD total plus a per-class `CostBreakdown`).
  `baikai/src/Baikai/Cost/Pricing.hs` defines
  `computeCost :: Model -> Usage -> Cost`, which multiplies each token class by the
  model's per-million-token rate: `inputTokens` at the input rate, `outputTokens` at
  the output rate, `cacheReadTokens` at the cache-read rate, `cacheWriteTokens` at
  the cache-write rate. Note what `computeCost` assumes: the four token classes are
  *disjoint* — no token is counted in two classes.
- `baikai-openai/` — wraps the MercuryTechnologies `openai` SDK's Chat Completions
  API as a baikai provider. `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` streams
  raw SSE chunks, parses each into a `RawChunk` (deliberately bypassing the SDK's
  typed chunk, which cannot parse partial tool-call deltas), and folds them through
  an `Assembler` record into the final `Response`. Usage arrives on the last chunk:
  `parseUsage` (around line 320) reads `prompt_tokens`, `completion_tokens`,
  `prompt_tokens_details.cached_tokens`, and
  `completion_tokens_details.reasoning_tokens` into a `RawUsage` record (defined
  around line 222), and `applyUsage` (around line 588) converts that `RawUsage` into
  a `Baikai.Usage.Usage` stored on the assembler. `finalMessage` (around line 680)
  later calls `Pricing.computeCost` on that `Usage` and embeds the result. The
  module's export list is currently minimal: `register`, `registerWithRegistry`,
  `openaiChatStream`, `mapRequest`.
- `baikai-claude/` — the same shape for Anthropic's Messages API.
  `anthroUsageToBaikai` in `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (around
  line 534) is the reference convention: Anthropic's wire `input_tokens` *excludes*
  `cache_read_input_tokens` and `cache_creation_input_tokens`, so the mapping copies
  the four counters field-for-field and sets
  `totalTokens = input + output + cacheRead + cacheWrite`. This plan does not modify
  the Claude provider; it documents its convention as *the* convention and makes
  OpenAI match it.

Definitions used below. "Prompt caching" is a provider feature where the prefix of a
repeated prompt is served from a provider-side cache at a discounted rate; the
discounted fraction is reported as "cached" or "cache read" tokens. A "cache write"
is the (Anthropic-only, surcharged) act of storing a prefix for future reads; OpenAI
does not bill cache writes, which is why the OpenAI mapping fixes
`cacheWriteTokens = 0`. "Reasoning tokens" (OpenAI) / "thinking tokens" (Anthropic)
are output-side tokens the model spends deliberating before its visible answer.

The defect (review Theme 3, item 1, verified against the source at
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` lines 588–601). OpenAI's wire
semantics are *inclusive*: `usage.prompt_tokens` already contains
`usage.prompt_tokens_details.cached_tokens`. (The SDK mirrors the wire verbatim — see
`OpenAI.V1.Usage` in the MercuryTechnologies `openai` package, where
`PromptTokensDetails.cached_tokens` is documented as a "breakdown of tokens used in
the prompt", i.e. a detail view of `prompt_tokens`, not an addition to it. baikai's
own `parseUsage` reads the same raw JSON fields directly.) But `applyUsage` maps:

```haskell
Usage.inputTokens = u ^. #inputTokens,          -- prompt_tokens, cached INCLUDED
Usage.cacheReadTokens = u ^. #cacheReadTokens,  -- cached_tokens, the SAME tokens again
Usage.totalTokens = (u ^. #inputTokens) + (u ^. #outputTokens) + (u ^. #cacheReadTokens),
```

Failure scenario, concretely. A caller sends a 100-token prompt of which 80 tokens
hit the provider cache, and receives 50 completion tokens of which 20 were reasoning.
OpenAI reports `prompt_tokens = 100`, `cached_tokens = 80`, `completion_tokens = 50`,
`reasoning_tokens = 20`, `total_tokens = 150`. The current mapping produces
`inputTokens = 100`, `cacheReadTokens = 80`, `totalTokens = 230` — an 80-token
phantom. `computeCost` then bills 100 tokens at the full input rate *plus* 80 tokens
at the cache-read rate: the 80 cached tokens are billed twice, once at each rate,
when the provider actually billed 20 at the input rate and 80 at the cache-read
rate. At the illustrative rates used in the tests below (input $1/M, output $5/M,
cache-read $0.10/M) the reported cost is 358 micro-dollars against a true bill of
278 — a systematic ~29% overstatement that grows with cache hit rate, exactly on the
workloads (agents with long stable prefixes) where cost tracking matters most.
Meanwhile the Claude provider reports disjoint fields, so the same `Usage` consumer
reads `inputTokens` as cache-exclusive for one provider and cache-inclusive for the
other.

The fix has two halves, and both matter: normalize the OpenAI mapping to the disjoint
convention (subtract, clamped at zero), and write the invariant into the `Usage`
record's haddock so every current and future provider mapping — and the EP-7/EP-8
tests the MasterPlan says must assert these semantics — has one place that defines
what the fields mean.


## Plan of Work

### Milestone 1 — Define and document the `Usage` invariant in core

Scope: `baikai/src/Baikai/Usage.hs` and `baikai/test/UsageSpec.hs` only. At the end
of this milestone the `Usage` record carries a normative haddock stating the
provider-independent field semantics, and the core test suite contains an executable
statement of the arithmetic invariant. This milestone is pure documentation plus an
additive test; it cannot break any caller. Run
`cabal test baikai --test-show-details=direct` and observe the new
"documented field semantics" group pass. It lands first because it *defines* the
convention Milestone 2 implements, and because EP-7/EP-8 consume the documented
semantics per the MasterPlan's Integration Points.

Work. In `baikai/src/Baikai/Usage.hs`, replace the current module header comment
(lines 1–8, the "Token-usage accounting…" paragraph) and add per-field haddocks on
the `Usage` record so the following invariant is stated verbatim on the type users
see in generated documentation:

- `inputTokens`, `cacheReadTokens`, and `cacheWriteTokens` are disjoint classes of
  prompt tokens: `inputTokens` counts only the non-cached prompt tokens and
  *excludes* both cache counters. This is Anthropic's wire convention; providers
  whose wire format is inclusive (OpenAI Chat Completions reports `prompt_tokens`
  including `prompt_tokens_details.cached_tokens`) must normalize by subtraction
  when mapping into `Usage`.
- `totalTokens` is the sum of all billed token classes:
  `inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens`. It is computed
  by the provider mapping from the normalized parts, not copied from the wire.
- `reasoningTokens`, when present, is an informational breakdown: those tokens are
  already counted inside `outputTokens` (and hence inside `totalTokens`) and are
  billed at the output rate. It is `Nothing` for providers that do not report a
  separate reasoning count (Anthropic includes thinking tokens in `output_tokens`
  without a breakdown; OpenAI reports
  `completion_tokens_details.reasoning_tokens` as a subset of `completion_tokens`).
- Every provider mapping must satisfy this invariant; `computeCost` in
  `Baikai.Cost.Pricing` depends on the disjointness to bill each class exactly once.

Keep the existing note that `cost` is always populated (zero via `_Cost` for
providers without pricing). Do not change any type, field, or instance in this file —
the record shape is correct; only its meaning was undocumented.

In `baikai/test/UsageSpec.hs`, add a new `testGroup "documented field semantics"`
(wire it into the `tests` list) with two cases. First, an arithmetic witness of the
invariant: build a `Usage` with distinct values in every class (for example input 20,
output 50, cacheRead 80, cacheWrite 7, reasoning `Just 20`) and assert
`totalTokens == inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens` —
i.e. 157, with the reasoning subset *not* added on top. Second, a cost witness that
disjointness is what `computeCost` assumes: this lives more naturally next to the
pricing tests, so instead put it in Milestone 2's provider test and keep UsageSpec
core-only; in UsageSpec, add a comment block above the group naming the two provider
mappings that must uphold the invariant (`anthroUsageToBaikai` in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` and `rawUsageToUsage` in
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`) so a reader of the core spec
knows where conformance is tested. This is the "cross-provider invariant note" the
review asked for, in executable-plus-comment form.

Acceptance: `cabal test baikai` passes with the new group listed in the output.

### Milestone 2 — Normalize the OpenAI mapping and pin it with regression tests

Scope: `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and
`baikai-openai/test/Main.hs`. At the end of this milestone the OpenAI provider
produces disjoint `Usage` fields and a correct `Cost` for cached requests, and a test
feeds a real wire-shaped payload through the real parser and mapping and asserts the
exact numbers. Run `cabal test baikai-openai --test-show-details=direct`.

Work, in order. In `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`:

1. Add a pure function `rawUsageToUsage :: RawUsage -> Usage.Usage` directly above
   `applyUsage`. It implements the normalization:

   ```haskell
   -- | Normalize OpenAI's inclusive usage counters into baikai's
   -- disjoint 'Usage.Usage' convention (see the 'Usage.Usage'
   -- haddock): OpenAI's @prompt_tokens@ INCLUDES
   -- @prompt_tokens_details.cached_tokens@, so the cached count is
   -- subtracted out of 'Usage.inputTokens'. The subtraction is
   -- clamped at zero because the counters are 'Natural' (whose
   -- subtraction throws 'Control.Exception.Underflow') and because
   -- OpenAI-compatible hosts sometimes report inconsistent
   -- counters. 'Usage.totalTokens' is recomputed from the
   -- normalized parts; for a well-behaved host it equals the wire
   -- @total_tokens@. 'Usage.reasoningTokens' is a subset of
   -- 'Usage.outputTokens' and is deliberately NOT added to the
   -- total. OpenAI does not bill cache writes, so
   -- 'Usage.cacheWriteTokens' is always 0.
   rawUsageToUsage :: RawUsage -> Usage.Usage
   rawUsageToUsage u =
     let prompt = u ^. #inputTokens
         cached = u ^. #cacheReadTokens
         out = u ^. #outputTokens
         nonCached = if cached >= prompt then 0 else prompt - cached
      in Usage.Usage
           { Usage.inputTokens = nonCached,
             Usage.outputTokens = out,
             Usage.cacheReadTokens = cached,
             Usage.cacheWriteTokens = 0,
             Usage.reasoningTokens = u ^. #reasoningTokens,
             Usage.totalTokens = nonCached + out + cached,
             Usage.cost = _Cost
           }
   ```

   (Field names on `RawUsage` are unchanged; note that `RawUsage.inputTokens` still
   holds the raw inclusive `prompt_tokens` — the *record* is a faithful wire image,
   and normalization happens in exactly one place, this function. Do not rename
   `RawUsage` fields in this plan; if the raw-vs-normalized naming bothers a future
   reader, that is an EP-10 hygiene question.)

2. Rewrite `applyUsage` (currently lines 588–601) to delegate:

   ```haskell
   applyUsage :: Maybe RawUsage -> Assembler -> Assembler
   applyUsage Nothing ass = ass
   applyUsage (Just u) ass = ass & #usage .~ rawUsageToUsage u
   ```

3. Extend the module export list from
   `(register, registerWithRegistry, openaiChatStream, mapRequest)` to also export
   `RawUsage (..)`, `parseUsage`, and `rawUsageToUsage`, grouped under a short
   haddock section comment such as `-- * Usage mapping (exposed for tests; may move
   behind an .Internal namespace in a later plan)`. Nothing else in the module
   changes; in particular do not touch `mapRequest`, `parseChunk`, or any
   request-shaping code (EP-8's territory).

In `baikai-openai/test/Main.hs`, add a `usageMappingTests :: TestTree` group (and add
it to the `testGroup` list in `main`) with four cases. Build the raw payload as an
`Aeson.Object` shaped exactly like the wire `usage` object so the test goes through
`parseUsage` — the real parser — rather than hand-constructing a `RawUsage`:

```haskell
cachedUsagePayload :: Aeson.Object
cachedUsagePayload =
  case Aeson.object
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int),
      "prompt_tokens_details" Aeson..= Aeson.object ["cached_tokens" Aeson..= (80 :: Int)],
      "completion_tokens_details" Aeson..= Aeson.object ["reasoning_tokens" Aeson..= (20 :: Int)]
    ] of
    Aeson.Object o -> o
    _ -> error "unreachable: Aeson.object builds an Object"
```

Case 1, "cached prompt tokens map to disjoint fields": run
`parseUsage cachedUsagePayload`, require `Just raw`, let
`u = rawUsageToUsage raw`, and assert `inputTokens u @?= 20`,
`cacheReadTokens u @?= 80`, `outputTokens u @?= 50`,
`reasoningTokens u @?= Just 20`, `cacheWriteTokens u @?= 0`, and
`totalTokens u @?= 150` (matching the wire `total_tokens`, and *not* 230 as the
pre-fix code produced).

Case 2, "computeCost bills each token class exactly once": build a model with known
rates using `_Model` and `ModelCost { inputCost = 1, outputCost = 5,
cacheReadCost = 1/10, cacheWriteCost = 5/4 }` (the same illustrative rates as
`baikai/test/CostSpec.hs` uses), feed it the normalized `u` from case 1 through
`Baikai.Cost.Pricing.computeCost`, and assert the exact `Rational`:
`Cost.usd == (20*1 + 50*5 + 80*(1/10)) / 1_000_000`, i.e. `278 / 1_000_000` reduced
— write it as `139 / 500000 :: Rational` in the assertion, with a comment that the
double-billing bug produced `358 / 1_000_000`. Also assert the breakdown:
`inputUsd == 20 / 1_000_000` and `cachedInputUsd == 8 / 1_000_000`, which is the
direct observable of "cached tokens are not billed at the input rate".

Case 3, "clamped when a compatible host over-reports cached tokens": payload with
`prompt_tokens = 100` and `cached_tokens = 120` (no details for completion). Assert
`inputTokens == 0`, `cacheReadTokens == 120`, `totalTokens == 170` — and, implicitly,
that the mapping does not throw `Underflow`.

Case 4, "no cache details means no cache tokens": payload with only `prompt_tokens =
100` and `completion_tokens = 50`. Assert `inputTokens == 100`,
`cacheReadTokens == 0`, `reasoningTokens == Nothing`, `totalTokens == 150` —
guarding against a regression where the subtraction path mangles the common
uncached case.

The test module needs `Baikai.Cost qualified as Cost`, `Baikai.Cost.Pricing
(computeCost)`, and `Baikai.Model (ModelCost (..))` imports (check what the umbrella
`Baikai` module already re-exports before adding qualified imports; `_Model` is
already in scope via `import Baikai`). All needed packages (`aeson`, `baikai`,
`lens`, `generic-lens`) are already in the test-suite's `build-depends` in
`baikai-openai/baikai-openai.cabal`, so no cabal edit is expected; if an import
resolves to a module not re-exported by `Baikai`, add the explicit import rather
than touching the cabal file.

Finally, re-verify (read-only) that `anthroUsageToBaikai` in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` satisfies the Milestone 1 haddock:
disjoint copy of Anthropic's already-disjoint counters, `totalTokens` as the
four-class sum, `reasoningTokens = Nothing`. It does at the time of writing; if it
has drifted when this plan is executed, record the drift in Surprises & Discoveries
and align it in the same way (normalize in the mapping, never in `computeCost`).

Acceptance: `cabal test baikai-openai` passes with the four new cases listed. As a
fail-before/pass-after check, case 1 and case 2 must fail against the unmodified
`applyUsage` logic (expected failures: `inputTokens` 100 vs 20, `totalTokens` 230 vs
150, `usd` 179/500000 vs 139/500000) — you can demonstrate this by writing the tests
first and running them once before applying the source change.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Milestone 1:

```bash
cabal build baikai --enable-tests
cabal test baikai --test-show-details=direct
```

Expected: the suite prints the `Baikai.Usage` group including the new
`documented field semantics` subgroup, all `OK`, exit code 0.

Milestone 2 (test-first, to capture the fail-before evidence):

```bash
# 1. Add usageMappingTests to baikai-openai/test/Main.hs and the exports to Api.hs
#    (the exports are needed for the test to compile), but leave applyUsage's old
#    arithmetic in place inside rawUsageToUsage temporarily — or simply run once
#    with the normalizer implementing the OLD mapping to observe the failure:
cabal test baikai-openai --test-show-details=direct
```

Expected while the old arithmetic is in effect — the double-billing regression made
visible:

```text
    cached prompt tokens map to disjoint fields:  FAIL
      expected: 20
       but got: 100
```

```bash
# 2. Apply the normalization in rawUsageToUsage, then:
cabal test baikai-openai --test-show-details=direct
```

Expected: all cases `OK`, exit code 0.

Final sweep:

```bash
cabal build all --enable-tests
cabal test baikai baikai-openai
```

Expected: both suites report `All N tests passed`; no other package is touched, so
nothing else needs rebuilding beyond what cabal decides.

If you prefer not to stage the old arithmetic inside the new function, an equivalent
fail-before demonstration is: `git stash` the `Api.hs` source change (keeping the
test change), run the suite to record the failure transcript, then `git stash pop`.


## Validation and Acceptance

Acceptance is behavioral, with specific inputs and outputs. Given the wire usage
object `{"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150,
"prompt_tokens_details": {"cached_tokens": 80}, "completion_tokens_details":
{"reasoning_tokens": 20}}` fed through `parseUsage` and `rawUsageToUsage` in
`Baikai.Provider.OpenAI.Api`, the resulting `Usage` is exactly
`inputTokens = 20, outputTokens = 50, cacheReadTokens = 80, cacheWriteTokens = 0,
reasoningTokens = Just 20, totalTokens = 150`, and `computeCost` against a model
with rates input $1/M, output $5/M, cache-read $0.10/M yields
`usd = 139/500000` with `breakdown.inputUsd = 20/1000000` and
`breakdown.cachedInputUsd = 8/1000000`. Over-reported cache counters
(`cached_tokens > prompt_tokens`) clamp `inputTokens` to 0 without throwing. The
uncached shape maps unchanged. All of this is pinned by
`cabal test baikai-openai --test-show-details=direct` printing `OK` for the
`usageMappingTests` cases; `cabal test baikai --test-show-details=direct` printing
`OK` for the `documented field semantics` group; and
`cabal build all --enable-tests` succeeding (proving no other package consumed the
old export list or semantics in a way this change breaks).

Beyond the suites, the change is observable on any live cached call: a repeated
long-prefix request through the OpenAI provider now reports a `totalTokens` equal to
the provider's own `total_tokens` and a `Cost.usd` matching the provider's billing
formula, where before both were inflated. The regression tests are the acceptance
gate, though — live-call verification is optional corroboration, not required (it
needs an `OPENAI_API_KEY` and a prompt long enough to trigger caching, ≥1024
tokens).

Generated haddock is part of the deliverable: `cabal haddock baikai` must succeed
and the `Baikai.Usage.Usage` page must show the invariant on the record and fields.


## Idempotence and Recovery

Every step is an ordinary source edit plus a test run; all steps are safe to repeat.
The source change is small and confined to three files
(`baikai/src/Baikai/Usage.hs` — comments and one test file aside, no code;
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` — one new pure function, one
simplified function, three exports; `baikai-openai/test/Main.hs` and
`baikai/test/UsageSpec.hs` — additive tests). If a step goes wrong, `git diff` the
three files and revert with `git checkout -- <path>`; there are no migrations,
generated files, or state. Milestone 1 can land (and be committed) independently of
Milestone 2; committing them separately with conventional-commit messages
(`docs(usage): …` then `fix(openai): …`) keeps each revertable on its own. The one
ordering constraint is that the test additions in Milestone 2 reference exports that
must exist first in `Api.hs` for compilation — if the build fails with an
out-of-scope `rawUsageToUsage`, apply the export-list edit before rerunning.


## Interfaces and Dependencies

No new libraries and no cabal-file changes. Everything uses dependencies already
declared: `aeson` (payload construction in tests), `lens`/`generic-lens` (field
access), `tasty`/`tasty-hunit` (tests), and the in-repo `baikai` core.

At the end of Milestone 1, `baikai/src/Baikai/Usage.hs` exports exactly what it does
today — `Usage (..)`, `_Usage`, `sumUsage` — with the record and field haddocks
carrying the normative invariant; no signatures change.

At the end of Milestone 2, `Baikai.Provider.OpenAI.Api` (in
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`) exports, in addition to the
current `register`, `registerWithRegistry`, `openaiChatStream`, `mapRequest`:

- `RawUsage (..)` — the faithful wire image of one chunk's `usage` object, fields
  `inputTokens :: Natural` (raw inclusive `prompt_tokens`),
  `outputTokens :: Natural`, `cacheReadTokens :: Natural`,
  `reasoningTokens :: Maybe Natural` (unchanged shape).
- `parseUsage :: Data.Aeson.Object -> Maybe RawUsage` (unchanged code, newly
  exported).
- `rawUsageToUsage :: RawUsage -> Baikai.Usage.Usage` — the single normalization
  point implementing the disjoint convention; `applyUsage` (internal) is its only
  in-module caller.

Cross-plan interfaces this plan owns, per the MasterPlan
(`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`,
Integration Points): the documented `Usage` field semantics. EP-7
(`docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md`) and EP-8
(`docs/plans/41-implement-compat-quirks-and-transport-options.md`) must write any
usage-touching assertions against these semantics; in particular, EP-7's
OpenAI-compatible reasoning extraction must keep `reasoningTokens` a subset of
`outputTokens` (never added to `totalTokens`), and EP-8 must not reinterpret
`inputTokens` when it reworks request shaping. EP-10
(`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`) may relocate the
newly exported test seams behind an `.Internal` namespace; the export haddock added
here says so explicitly so that move is unsurprising.
