---
id: 71
slug: ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks
title: "Ask Anthropic for summarized thinking instead of silently empty blocks"
kind: exec-plan
created_at: 2026-08-28T04:52:35Z
intention: "intention_01m13ba2w5enrrbdvg022b1mrn"
master_plan: "docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md"
---

# Ask Anthropic for summarized thinking instead of silently empty blocks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

When a caller asks baikai for reasoning on a current Anthropic model,
baikai builds a request that turns reasoning on and then never asks to
see any of it. Anthropic's newer model generations default to returning
reasoning blocks whose text is empty — the reasoning happens, and is
billed, but the readable summary is withheld unless the request asks for
it with a field baikai does not send.

The result a caller sees is a response containing thinking blocks that
are structurally present and textually empty. Nothing in the response
says why. Nothing in the call's evidence record says why either, even
though that record exists specifically to make this class of silent
downgrade visible.

After this plan, a caller who asks for reasoning gets reasoning text
back. baikai sends `"thinking": {"type": "adaptive", "display":
"summarized"}` to model generations that honour it, and where a
generation returns nothing readable regardless, the evidence record says
so in its own vocabulary rather than leaving the caller to infer it from
an empty string.

The observable outcome: a test replays a representative stream in which the
provider returns summarized reasoning, and the assembled response
contains non-empty thinking text; a second test asserts the request body
baikai builds for `claude-opus-5` now contains `"display":"summarized"`
where it previously contained a bare `{"type":"adaptive"}`.


## Progress

- [x] (2026-09-07) M1: verified display support in current provider docs and SDK 1.5; reused catalog `thinkingStyle` instead of adding a duplicate fact
- [x] (2026-09-07) M1: retained the catalog and pinned fact tables; adaptive request tests now require summarized display for every pinned model and level
- [x] (2026-09-07) M2: `computeThinking` emits summarized display and records `ThinkingTranslation.displayText`
- [x] (2026-09-07) M2: request-shape tests cover adaptive, budget, absent and renamed models
- [x] (2026-09-07) M3: response diagnostic and replay tests implemented, including preserved signed and redacted history
- [x] (2026-09-07) M4: Haddock, user guides, schema version, changelog and ADRs updated
- [x] (2026-09-07) Final: all package builds/tests and formatting pass; outcomes recorded in this implementation commit


## Surprises & Discoveries

Current documentation and the SDK correct a planning premise: `display`
works in both adaptive and budget objects, and SDK 1.5 supplies
`ThinkingEnabledWithDisplay` too. Budget requests remain unchanged because
this plan targets the adaptive default regression, not because the provider
rejects display there. Current reference checked 2026-09-07:
https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display.
The dependency source was located via Mori at
`mori://MercuryTechnologies/claude/packages/claude`; no dependency change is needed.

The catalog already carries forced-choice and fast-mode facts. This plan adds
no new catalog field and preserves the pinned tuples from EP-1. Existing style
tests cover every curated model at every reasoning level; their adaptive
expectation now includes the summary display value.

The summary replay fixture must send text and signatures in their own delta
frames. Initial test fixtures put them on `content_block_start`, which the
stream assembler initializes empty, so the fixture did not model the documented
wire sequence. Corrected fixtures use `thinking_delta` and `signature_delta`,
like the existing two-round tool replay. No assembler or signature behavior was
changed to accommodate that malformed fixture.

The clean baseline is commit `5f4fb2a`, validated by all ten suites at the end
of EP-1. Final validation passes all ten Cabal suites, including 780 core tests and
357 Claude tests. cabal build all and nix fmt pass. The initial live Anthropic checks skipped because the process had not loaded
the existing ANTHROPIC_KEY from .envrc; the keyed follow-up below closes this gap.


## Decision Log

- Decision (2026-09-07): use the existing catalog `thinkingStyle` to select
  explicit summarized display for adaptive requests. No extra compatibility
  field, fetch edit, catalog regeneration or tuple widening is needed. A second
  flag would duplicate the selected request policy. Budget requests preserve
  their existing shape and provider summary default. ADR 0009 records this
  distinction between request policy and actual field support.
- Decision (2026-09-07): add optional `displayText` to `ThinkingTranslation`,
  encoded as `display_text` only when present. This is a positive description
  of the wire, not a weakening. Other adapters explicitly set Nothing, and
  legacy translation JSON decodes with Nothing. Schema 2.4 adds the field and
  summary diagnostic without changing digest algorithms or old golden values.
- Decision (2026-09-07): append `ThinkingSummaryUnavailable` only after a
  successful response with requested, enabled reasoning and at least one
  thinking block, all unreadable. Empty text and redacted ciphertext are
  unreadable; any visible block suppresses the diagnostic. No-block adaptive
  responses are legitimate, and incomplete/failed streams cannot establish
  a missing completed summary. The diagnostic never fills observed effort or
  changes translated display, call status, signatures or billing.
- Decision (2026-09-07): `weakensThinking ThinkingSummaryUnavailable` is False.
  Visibility does not establish model reasoning depth; strict preflight must
  not reject a call because a completed response might lack a summary. The
  diagnostic is response-only and is absent from the preflight describer.
  ADRs 0002 and 0003 record this explicit exception to the otherwise
  request-originated adjustment list.

- Decision: baikai asks for `summarized` rather than leaving the provider
  default in place, on adaptive generations selected by thinkingStyle.
  Rationale: a caller who set `Options.thinking` has asked to reason, and
  the library should preserve the earlier availability of readable summaries. The default
  produces blocks that are present but empty, even though the caller pays for the reasoning tokens either way, since
  display controls visibility only and not whether thinking happens or
  what it costs. Making the visible choice the default matches what
  `Options.thinking` already means everywhere else in baikai.
  Date: 2026-08-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Completed 2026-09-07. Adaptive requests send summarized display and their
translation evidence records it. Empty signed or redacted-only completed
thinking produces a response-only diagnostic; no-block and failed streams
do not. Replay tests verify readable text, signatures and consecutive tool
history. All ten test suites pass (780 core, 357 Claude); the full build and
formatting pass. The 2026-09-08 keyed follow-up below verifies live summary
text and signed replay.

No catalog fact was added because the existing thinkingStyle already selects
this request policy. ADRs 0002, 0003 and 0009 now hold the durable distinction
between translated display, response diagnostics and model capabilities.
The optional translation field and new public constructor require package
API version review at release; wire schema 2.4 accepts older translation JSON.


## Context and Orientation

This section assumes you have never seen this repository.

**What baikai is.** A Haskell library giving callers one way to talk to
several large-language-model providers. Multi-package Cabal project;
`cabal.project` at the root lists the packages. The two that matter are
`baikai`, the core, and `baikai-claude`, the Anthropic backend.

**Extended thinking, in plain terms.** Some models can spend tokens
reasoning before they answer. Anthropic exposes two request shapes for
this, and which one a model accepts is a property of its generation, not
of anything derivable from its name. The older *budget* shape is
`{"type": "enabled", "budget_tokens": 12000}`: the caller names a token
allowance. The newer *adaptive* shape is `{"type": "adaptive"}`: the
model decides how much to think, and the caller only hints at depth
through a separate `output_config.effort` field. Sending the budget shape
to an adaptive-only generation is an HTTP 400, not a degraded call.

**The display setting.** Both adaptive and enabled
objects accept a `display` key controlling whether the reasoning
comes back readable. `"summarized"` returns a human-readable summary of
the reasoning; `"omitted"` returns thinking blocks whose text is empty.
The returned text is a provider summary. Critically,
`display` controls visibility only — the model thinks and is billed
identically either way.

The background fact that motivates this plan: `"omitted"` is the default
on the current generations (Claude Fable 5, Claude Opus 5, Opus 4.8, Opus
4.7, Sonnet 5), and it was *not* the default on the generation before
them (Opus 4.6, Sonnet 4.6), where `"summarized"` was. The default
changed underneath unchanged client code. That is why baikai produces
readable reasoning on some models and empty blocks on others while doing
exactly the same thing.

**Where baikai builds the thinking request.** The file is
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`. The
function `mapRequest` builds the whole `Claude.V1.Messages.CreateMessage`
record. The thinking decision is made by a helper called
`computeThinking`, which returns a pair: a `ThinkingPlan` holding the
fields that will reach the wire, and a `ThinkingTranslation` describing
what happened, for the evidence record. Its adaptive branch reads, in
essence:

```haskell
| thinkingStyle compat == AnthropicThinkingAdaptive =
    let e = adaptiveEffort lvl
     in ( ThinkingPlan
            { field = Just Messages.ThinkingAdaptive
            , effort = e
            , budget = Nothing
            }
        , ThinkingTranslation
            { requested = Just lvl
            , mode = ThinkingModeAdaptive
            , effortText = e
            , budgetTokens = Nothing
            , wireField = Just "thinking"
            , adjustments = adaptiveAdjustments lvl e
            }
        )
```

`Messages.ThinkingAdaptive` is the bare constructor with no display
setting. That single value is the whole of the gap this plan closes.

**The completed dependency prerequisite.** In `claude` 1.4.0 — the version this
repository builds against before its sibling plan lands — the type is:

```haskell
data Thinking
    = ThinkingAdaptive
    | ThinkingEnabled { budget_tokens :: Natural }
```

Version 1.4.0 could not express a display setting. The now-integrated 1.5.0 adds
`ThinkingAdaptiveWithDisplay` taking a display value, whose `ThinkingSummarized`
constructor encodes as `{"type":"adaptive","display":"summarized"}`. This
plan therefore has a hard dependency on
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`,
which moves the dependency. Do not begin until that plan is complete; the
code here will not compile before it.

**The compatibility record.** `Baikai.Compat.AnthropicMessagesCompat` in
`baikai/src/Baikai/Compat.hs` holds per-model facts about what the
Anthropic Messages API accepts for one model. It has seven fields:
`supportsLongCacheRetention`, `supportsCacheControlOnTools`,
`sendSessionAffinityHeaders`, `thinkingStyle`, `supportsSamplingParameters`,
`supportsForcedToolChoice`, and `supportsFastMode`. `thinkingStyle` is a two-constructor sum,
`AnthropicThinkingBudget` or `AnthropicThinkingAdaptive`, and it is the
value `computeThinking` branches on above.

**The catalog pipeline.** baikai's model list is generated, not hand
written. `baikai/data/models/anthropic.json` is hand-reviewable JSON, one
entry per model, each Anthropic entry carrying a `compat` block.
`baikai/src/Baikai/Models/Generated.hs` is produced mechanically from it
and must never be edited directly. Two executables maintain them, both
run from the repository root:

```bash
cabal run baikai-fetch-models   # download models.dev, rewrite the JSON
cabal run baikai-gen-models     # render the JSON into Generated.hs
```

Their logic lives in `baikai/fetch/FetchModelsCore.hs` and
`baikai/gen/GenModelsCore.hs`. The fetcher emits only ids listed in a
curated include set; for Anthropic that is
`anthropicInclude :: Map Text AnthropicGenerationFacts`, whose values
carry the facts a human had to vet, each row required by the file's
convention to carry a dated comment naming its source. The generator
refuses an `anthropic-messages` entry that reaches it without a `compat`
block, so a hand edit cannot quietly drop a model back to guesswork.

**Where thinking arrives in a response.** In
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`, the
assembler turns the provider's server-sent events into baikai events.
`Messages.ContentBlock_Thinking` opens a thinking block,
`Messages.Delta_Thinking_Delta` appends text to it, and the block-stop
handler builds a `Baikai.Content.ThinkingContent`:

```haskell
data ThinkingContent = ThinkingContent
  { thinking :: !Text
  , signature :: !(Maybe Text)
  , redacted :: !Bool
  , replayState :: !(Maybe ThinkingReplay)
  }
```

When the provider omits the summary, the deltas simply never arrive and
`thinking` ends up as the empty string. No error, no flag, nothing to
distinguish it from a model that genuinely thought about nothing.

**The evidence vocabulary.** `baikai/src/Baikai/Evidence.hs` defines
`ThinkingAdjustment`, a sum type whose Haddock states its purpose:
"This is the type that makes an otherwise silent downgrade visible.
Every constructor corresponds to a real site in this repository where a
request is weakened, dropped, or made indistinguishable from the
provider's own default." Its existing constructors include
`EffortClamped`, `EffortCollapsedToToggle`, `EffortOmitted`,
`ThinkingDroppedUnsupportedModel`, `ThinkingDroppedUnsupportedHost` and
`ThinkingDroppedBudgetExceeded`. Reasoning requested but returned
unreadable is precisely such a site and does not yet have a constructor.

**Relevant ADRs.** Read these three.

`docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
requires that a fact about what a model generation accepts on the wire be
a field of the compat record in the generated catalog entry, never a
table keyed by model id. It exists because such a table did ship and did
not know about `claude-sonnet-5`, earning an HTTP 400 on every reasoning
request to that model.

`docs/adr/0003-the-adapter-owns-the-translation-description.md` requires
that the provider adapter describe what it translated, because only the
adapter knows every input to the decision. The display decision must
therefore be described inside `computeThinking`, alongside the effort and
style decisions it already describes, and not reconstructed later.

`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
requires keeping requested, translated and observed separate. Asking for
a summary and receiving nothing is a gap between translated and observed,
and Milestone 3 exists to make that gap visible rather than silent.

**Sibling plans.** This is the third of four under
`docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md`.
It has a hard dependency on
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`.
Its soft dependency on plan 69 established the current catalog facts.
The original plan anticipated sharing catalog edits, but implementation
reuses thinkingStyle and preserves EP-1's record and pinned table shapes.


## Plan of Work

Four milestones: verify the catalog selection rule, send the field, prove the
reasoning arrives and that its absence is recorded, then document it.

### Milestone 1 — the catalog knows which generations honour display

At the end of this milestone the existing catalog fact is confirmed as the
right selection rule. Current provider documentation accepts display in both
modes. This initiative explicitly requests summaries on adaptive models and
leaves budget requests at their previous summary default. `thinkingStyle`
already selects those branches, so no independent display flag is introduced.

Keep `AnthropicMessagesCompat`, `AnthropicGenerationFacts`, the JSON and the
generated catalog unchanged. The pinned model facts in `CatalogSpec` and
`ThinkingSpec` remain the authority; extend their request expectations rather
than widening tuples with a duplicate property. In `ThinkingSpec`, every
adaptive model at every level must encode `ThinkingAdaptiveWithDisplay
ThinkingSummarized`, while every budget model keeps `ThinkingEnabled`.
Run the core and Claude suites; the existing generation round-trip proves
that the unmodified catalog remains reproducible.

### Milestone 2 — the request asks for a summary

At the end of this milestone the request body baikai builds for an
adaptive-generation model contains `"display":"summarized"`, and the body
for a budget-generation model is byte-for-byte what it was before.

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, change
the adaptive branch of `computeThinking` to build
`Messages.ThinkingAdaptiveWithDisplay Messages.ThinkingSummarized` in
place of the bare `Messages.ThinkingAdaptive`, gated on the fact from
Milestone 1. Leave the budget branch untouched.

Extend `ThinkingTranslation` in `baikai/src/Baikai/Evidence.hs` with
`displayText :: Maybe Text`, placed before adjustments. Set it to
`Just "summarized"` beside the adaptive SDK field and to Nothing on budget,
dropped and absent requests. `dropThinking` clears it. Update the core defaults,
OpenAI Chat/Responses builders and both CLI/agent adapters with Nothing;
all public construction sites must compile with the added field. JSON emits
`display_text` only when present and accepts older JSON without it. The
positive display choice is not an adjustment or a claim of observed effort.

In `baikai-claude/test/ShapeSpec.hs`, test complete thinking objects for adaptive
and budget requests, absence when no preference was set, and a renamed catalog
model. Assert the describer's display value matches the body. Existing
`ThinkingSpec` tests cover all catalog models and reasoning levels. Add core
JSON compatibility/round-trip tests and advance `evidenceSchemaVersion` to 2.4;
canonical encoding and projection algorithms do not change.

### Milestone 3 — the reasoning arrives, and its absence is recorded

At the end of this milestone a replayed stream carrying summarized
reasoning assembles into a response with non-empty thinking text, and a
call whose reasoning came back empty says so in its evidence.

The replay tests live in `baikai-claude/test/FableContractsSpec.hs`, which
already supplies JSON event fixtures decoded through the SDK and delivered
through the real streaming adapter. Emit thinking text in `thinking_delta`
frames and signatures in `signature_delta` frames. A visible summary must
assemble exactly, including its signature, and the response evidence must
retain `display_text: summarized` while leaving observed effort Unobserved.

Add `ThinkingSummaryUnavailable` to `ThinkingAdjustment`, with JSON kind
`thinking_summary_unavailable`, a decoder branch, and `weakensThinking = False`.
Document that it is a response-only diagnostic, unlike the other adjustments.
In `Stream.hs`, have `observeAnthropic` append it via `summaryDiagnostics` when
the call succeeded, the translated reasoning was enabled and requested, and
at least one completed thinking block exists with no readable block. Redacted
ciphertext never counts as summary text. No blocks, no preference, dropped
reasoning, or a failed/incomplete stream must not invent this diagnosis.
Preserve every existing translation field and leave `observedThinking` alone.

Test empty signed blocks, redacted-only blocks, mixed unreadable blocks,
a mixture with a visible summary, no thinking blocks, no preference and a
failed stream. Read the real response evidence and verify call status stays
successful for unreadable summaries. Rebuild the response as request history
and assert the exact signed/redacted payload survives. Run the existing
consecutive-tool-round fixture with summary requests on all three calls and
assert history order, encrypted payloads and signatures remain intact. Core
JSON tests and the exhaustive strict-evidence matrix cover the new constructor.

### Milestone 4 — write it down

Update the Haddock on `computeThinking` and on the reused compatibility policy.
Update `docs/user/models-and-providers.md`, which already carries a
section on what each provider does with `Options.thinking` and which
generations reject which shapes — the display behaviour belongs in the
same passage, in the same voice. Add a `### Changed` entry to
`CHANGELOG.md` under `## [Unreleased]`, noting that reasoning text now
comes back on adaptive generations where it previously came back empty;
this is a behaviour change callers will notice, so it belongs under
Changed rather than Added. Any code example you add must compile in the
test suite, per
`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md`; the
`baikai-smoke:doc-shapes` suite is where documented shapes are compiled.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/baikai`.

First confirm the blocking plan has landed:

```bash
grep -n "claude" baikai-claude/baikai-claude.cabal | grep '\^>='
```

Expect `claude ^>=1.5`. If it says `^>=1.4`, stop:
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`
has not been implemented and nothing in this plan will compile.

Establish the baseline:

```bash
cabal build all
cabal test all
```

Every suite should report `PASS`. The `baikai-agent` suite has two
process-timing tests that occasionally fail under parallel load; if only
that suite fails, re-run it alone with `cabal test baikai-agent` before
treating it as real.

Milestone 1 changes no catalog artifacts, so no fetch or generation edits are
needed. `cabal test baikai` runs the existing byte-identical generation check.
Do not fetch upstream catalogs into the working tree for this request-only
policy change.

After Milestones 2 and 3:

```bash
cabal test all
```


## Validation and Acceptance

Acceptance is three behaviours a person can check.

First, the request asks. In a `cabal repl baikai-claude` session, or in a
test in `baikai-claude/test/ShapeSpec.hs`, build a request against
`Baikai.Models.Generated.anthropic_claude_opus_5` with
`emptyOptions & #thinking ?~ ThinkingHigh` and inspect the encoded body.
It must contain:

```json
"thinking":{"type":"adaptive","display":"summarized"}
```

where before this plan it contained `"thinking":{"type":"adaptive"}`.
Build the same options against a budget-generation model such as
`anthropic_claude_haiku_4_5` and confirm its body still contains
`"thinking":{"type":"enabled","budget_tokens":...}` with no display key.

Second, the reasoning arrives. The replay test in `baikai-claude/test/FableContractsSpec.hs` added in Milestone 3
must show a `ThinkingContent` whose `thinking` field is non-empty after
replaying a body containing `thinking_delta` frames. Name it so it states
the outcome, for example "summarized reasoning assembles into non-empty
thinking content".

Third, an empty summary is recorded rather than silent. Replay a body in
which a thinking block opens and closes with no deltas, and assert the
call's evidence carries the new adjustment. Name it "reasoning requested
but returned empty is recorded in the evidence".

The whole suite must pass:

```bash
cabal test all
```

In particular `baikai-test` and `baikai-claude-test` must pass, since
both hold the existing pinned facts that select the request shapes.


## Idempotence and Recovery

Every step is repeatable. `cabal run baikai-gen-models` is a pure
function of the JSON files and rewrites `Generated.hs` from scratch;
a test in `baikai/test/CatalogSpec.hs` asserts that re-running it
reproduces the committed module byte for byte. `cabal run
baikai-fetch-models` also reaches the network and may pull in an
unrelated upstream price change — if that happens mid-plan, either commit
it separately or `git checkout` the JSON and re-apply only your curated
edits.

Nothing here is destructive: no migration, no data format anyone else has
written, no removal of an existing name. Recovery is `git checkout`.

The one change with a blast radius beyond this plan is the behaviour
change itself: callers who currently receive empty thinking text will
start receiving real text, and any downstream code that treats empty
thinking as "the model did not think" will now see the opposite. That is
the intended outcome, but it is why Milestone 4 puts the entry under
`### Changed` rather than `### Added`.


## Interfaces and Dependencies

This plan requires `claude ^>=1.5`, delivered by
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`.
The specific constructor it consumes is
`Claude.V1.Messages.ThinkingAdaptiveWithDisplay` applied to
`Claude.V1.Messages.ThinkingSummarized`, which encodes as
`{"type":"adaptive","display":"summarized"}`. Neither exists in 1.4.0,
where `Thinking` has exactly two constructors.

At the end of Milestone 1, the existing `thinkingStyle` selector remains the
selection rule. No new compat field or curated fact is needed.

At the end of Milestone 2, the adaptive branch of `computeThinking` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` produces a
`ThinkingPlan` whose `field` carries the display setting, and the
`ThinkingTranslation` it returns states the display choice.

At the end of Milestone 3, one new constructor on
`Baikai.Evidence.ThinkingAdjustment` recording reasoning that was
requested but returned unreadable, with its wire spelling in
the JSON encoder and decoder, and a deliberate answer for
`weakensThinking`.

2026-09-07 integration constraint from [plan 75](75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md):
summary display must preserve signed thinking when its visible text is empty,
redacted payloads and prior-message order. The two-round replay fixture in
`baikai-claude/test/FableContractsSpec.hs` is an acceptance gate for summary
changes. Display text is never a replacement for the provider signature.

Revision 2026-09-07: rebased on completed SDK/fast-mode work, corrected display
support in budget mode, reused thinkingStyle, and specified translated display
separately from the response-only availability diagnostic and replay guarantees.


Revision 2026-09-08: the user identified ANTHROPIC_KEY in .envrc. The earlier
claim that credentials were absent was incorrect: the test process had not
loaded them. Loaded the key without printing it and supplied both Anthropic
environment aliases to the live suite. The first run found a smoke-fixture
HTTP 400: budget thinking rejects temperature 0. The next run showed that
Opus 4.6 can correctly skip thinking for a trivial prompt. Updated the fixture
to temperature 1, a modular-exponentiation task, and high adaptive effort;
kept the assertions requiring non-empty signed thinking and accepted replay.
This changes test inputs, not provider behavior.

The final cabal test baikai-smoke:baikai-smoke --test-show-details=direct passes.
Sonnet 4.5 budget, Opus 4.6 adaptive and Sonnet 5 adaptive each returned readable
signed thinking and accepted the replay turn. Anthropic text, streaming, image,
tool, structured-output, sampling-drop, verbatim-schema and cache checks also
pass. Fast entitlement and live refusal-category behavior were not exercised.
