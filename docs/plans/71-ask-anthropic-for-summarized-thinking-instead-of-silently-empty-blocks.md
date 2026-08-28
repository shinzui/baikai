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

The observable outcome: a test replays a recorded stream in which the
provider returns summarized reasoning, and the assembled response
contains non-empty thinking text; a second test asserts the request body
baikai builds for `claude-opus-5` now contains `"display":"summarized"`
where it previously contained a bare `{"type":"adaptive"}`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `thinkingDisplay` (or equivalent) added to `Baikai.Compat.AnthropicMessagesCompat`
- [ ] M1: catalog fetcher carries the fact per curated Anthropic id, with dated sources
- [ ] M1: `baikai/data/models/anthropic.json` and `Baikai/Models/Generated.hs` regenerated
- [ ] M1: the two pinned fact tables widened and passing
- [ ] M2: `computeThinking` emits the display setting for generations that honour it
- [ ] M2: request-shape tests assert the new body for an adaptive model and an older one
- [ ] M3: a response carrying summarized reasoning assembles with non-empty text
- [ ] M3: a generation that returns no summary is recorded in the evidence
- [ ] M4: Haddock, `docs/user/models-and-providers.md`, and `CHANGELOG.md` updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. One item found during planning is recorded in the Context and
Orientation section instead, because it is background rather than a
discovery made while implementing: the display default changed silently
between model generations, so the same baikai code produces readable
reasoning on Claude Opus 4.6 and empty reasoning on Claude Opus 5,
without any error or warning at any layer.)


## Decision Log

- Decision: which display setting a generation honours is a per-model
  fact carried by the compatibility record in the generated catalog, not
  a constant applied to every Anthropic request.
  Rationale: `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
  requires that a fact about what the wire accepts live in the compat
  record. The `display` key belongs inside the adaptive thinking object,
  and the older budget-shaped generations do not take that object at all,
  so sending it unconditionally would put an unknown key into a request
  shape that has already earned this repository an HTTP 400 once. The
  compat record already carries `thinkingStyle`, which is the exact fact
  that decides which of the two shapes is built, so the new fact sits
  beside its natural neighbour.
  Date: 2026-08-28

- Decision: baikai asks for `summarized` rather than leaving the provider
  default in place, on every generation that honours the field.
  Rationale: a caller who set `Options.thinking` has asked to reason, and
  the only reason to ask is to have the reasoning available. The default
  produces blocks that are present but empty, which is the worst of both
  outcomes — the caller pays for the reasoning tokens either way, since
  display controls visibility only and not whether thinking happens or
  what it costs. Making the visible choice the default matches what
  `Options.thinking` already means everywhere else in baikai.
  Date: 2026-08-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


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

**The display setting.** Independently of which shape a model takes, the
adaptive object accepts a `display` key controlling whether the reasoning
comes back readable. `"summarized"` returns a human-readable summary of
the reasoning; `"omitted"` returns thinking blocks whose text is empty.
The raw chain of thought is never returned under any setting. Critically,
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

**Why this plan is blocked.** In `claude` 1.4.0 — the version this
repository builds against before its sibling plan lands — the type is:

```haskell
data Thinking
    = ThinkingAdaptive
    | ThinkingEnabled { budget_tokens :: Natural }
```

There is no way to express a display setting. Version 1.5.0 adds
`ThinkingAdaptiveWithDisplay` taking a display value, whose `ThinkingSummarized`
constructor encodes as `{"type":"adaptive","display":"summarized"}`. This
plan therefore has a hard dependency on
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`,
which moves the dependency. Do not begin until that plan is complete; the
code here will not compile before it.

**The compatibility record.** `Baikai.Compat.AnthropicMessagesCompat` in
`baikai/src/Baikai/Compat.hs` holds per-model facts about what the
Anthropic Messages API accepts for one model. Today it has five fields:
`supportsLongCacheRetention`, `supportsCacheControlOnTools`,
`sendSessionAffinityHeaders`, `thinkingStyle`, and
`supportsSamplingParameters`. `thinkingStyle` is a two-constructor sum,
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
It shares two artifacts with
`docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md`:
both add a field to `AnthropicMessagesCompat` and a fact to the fetcher's
`AnthropicGenerationFacts` record, and both widen the same two pinned
test tables. If plan 69 has already landed, read its diff first — the
record and its helper values will have a different shape than the one
quoted in this plan, and you should extend what is there rather than what
is described here.


## Plan of Work

Four milestones: teach the catalog the fact, send the field, prove the
reasoning arrives and that its absence is recorded, then document it.

### Milestone 1 — the catalog knows which generations honour display

At the end of this milestone nothing user-visible has changed, but each
Anthropic catalog entry states whether its generation honours the display
setting. Nothing reads the new fact yet.

Add a field to `AnthropicMessagesCompat` in `baikai/src/Baikai/Compat.hs`
recording it, and export its selector alongside the existing five. Prefer
a named sum type over a bare `Bool` if you can name more than two states
— but resist inventing states you cannot source. As of Anthropic's API
reference cached 2026-06-24 there are exactly two behaviours worth
modelling: generations that accept `display` inside the adaptive object,
and generations whose thinking shape has no place to put it. Since the
second set is exactly the budget-shaped generations that `thinkingStyle`
already identifies, consider carefully whether the new field earns its
place or whether `thinkingStyle` already answers the question. Record
your conclusion in the Decision Log either way; a field that duplicates
an existing one is worse than no field.

If you keep the field, give it a default in
`defaultAnthropicMessagesCompat` that matches Anthropic's own current
behaviour, and thread it through the catalog exactly as
`supportsSamplingParameters` is threaded: the `AnthropicGenerationFacts`
record and the `anthropicInclude` table in
`baikai/fetch/FetchModelsCore.hs`, the `compat` block emitted into
`baikai/data/models/anthropic.json`, and the renderer in
`baikai/gen/GenModelsCore.hs`. Every row you add or change in
`anthropicInclude` must carry a dated comment naming its source, as every
existing row does.

Then widen the two hand-written tables that pin every Anthropic model's
facts: `expectedAnthropicFacts` in `baikai/test/CatalogSpec.hs` and
`anthropicModels` in `baikai-claude/test/ThinkingSpec.hs`. Their comments
explain why they are written by hand — so that a catalog refresh cannot
change a per-model fact without a human editing a row. Widen them; do not
make them read the values off the record.

### Milestone 2 — the request asks for a summary

At the end of this milestone the request body baikai builds for an
adaptive-generation model contains `"display":"summarized"`, and the body
for a budget-generation model is byte-for-byte what it was before.

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, change
the adaptive branch of `computeThinking` to build
`Messages.ThinkingAdaptiveWithDisplay Messages.ThinkingSummarized` in
place of the bare `Messages.ThinkingAdaptive`, gated on the fact from
Milestone 1. Leave the budget branch untouched.

Extend the `ThinkingTranslation` this branch returns so the evidence
record states what was asked for. The record already carries
`wireField`, `mode`, `effortText` and `budgetTokens`; the display choice
is a fifth thing the adapter decided and, per
`docs/adr/0003-the-adapter-owns-the-translation-description.md`, it is
this function's job to say so. Whether that is a new field on
`ThinkingTranslation` or an entry in its `adjustments` list is your call
— note that `adjustments` is documented as recording *weakenings*, and
asking for a summary is a strengthening, so a new field is the better
fit. Record the choice.

The tests to write here are request-shape tests. `baikai-claude/test/ShapeSpec.hs`
is the suite that asserts on the JSON body baikai produces. Assert the
adaptive body now carries the display key, and assert a budget-shaped
model's body is unchanged.

### Milestone 3 — the reasoning arrives, and its absence is recorded

At the end of this milestone a replayed stream carrying summarized
reasoning assembles into a response with non-empty thinking text, and a
call whose reasoning came back empty says so in its evidence.

The first half is a stream-replay test. `baikai-claude/test/SseSpec.hs`
replays recorded server-sent-event bodies through the assembler and
asserts on the events. Build a fixture whose content blocks include a
thinking block with `thinking_delta` frames carrying real text, replay
it, and assert the assembled `Baikai.Content.ThinkingContent` has
non-empty `thinking`. This is the test that proves the feature end to
end rather than proving that a field was set.

The second half closes the loop the Purpose section opens. When a call
requested reasoning and every thinking block came back with empty text,
that is a gap between what baikai translated and what the provider
returned, and
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md` says
it must not be collapsed into silence. Add a constructor to
`ThinkingAdjustment` in `baikai/src/Baikai/Evidence.hs` recording it,
with a wire spelling in the renderer and its parser beside the existing
ones, and decide whether `weakensThinking` should return `True` for it.
Argument for `True`: the caller asked to see reasoning and cannot. Argument
for `False`: the reasoning happened and was billed, so the model's answer
is not weaker, only less inspectable. Both are defensible — pick one,
record the rationale, and note that `True` means strict evidence mode
will refuse such a call, which is a strong consequence to choose
deliberately.

Note the ordering constraint: this adjustment is discovered when the
response is assembled, not when the request is built, so it is recorded
in `Stream.hs` rather than in `Request.hs`. That is a departure from
where the other adjustments originate; make sure the evidence record
reaches the place that can set it, and if it cannot, say so in Surprises
& Discoveries rather than dropping the requirement.

### Milestone 4 — write it down

Update the Haddock on `computeThinking` and on the new compat field.
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

After the Milestone 1 edits, regenerate and inspect:

```bash
cabal run baikai-gen-models
git diff --stat baikai/src/Baikai/Models/Generated.hs
```

Run only the generator, not the fetcher: `baikai-fetch-models`
re-downloads models.dev and would mix an unrelated upstream refresh into
this plan's diff. Hand-edit `baikai/data/models/anthropic.json` to add
the new `compat` key, keeping `anthropicInclude` in
`baikai/fetch/FetchModelsCore.hs` in step, then confirm the two agree by
running the fetcher last and checking it produces no diff:

```bash
cabal run baikai-fetch-models
git diff --stat baikai/data/models/anthropic.json
```

An empty diff means the hand edit and the curated table agree.

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

Second, the reasoning arrives. The stream-replay test added in Milestone 3
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
both hold the pinned fact tables Milestone 1 widens.


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

At the end of Milestone 1, a new selector on
`Baikai.Compat.AnthropicMessagesCompat` recording whether the model's
generation honours the display setting — unless Milestone 1's analysis
concludes that `thinkingStyle` already answers the question, in which
case record that conclusion and skip the field.

At the end of Milestone 2, the adaptive branch of `computeThinking` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` produces a
`ThinkingPlan` whose `field` carries the display setting, and the
`ThinkingTranslation` it returns states the display choice.

At the end of Milestone 3, one new constructor on
`Baikai.Evidence.ThinkingAdjustment` recording reasoning that was
requested but returned unreadable, with its wire spelling in
`renderThinkingAdjustment` and its parser, and a deliberate answer for
`weakensThinking`.
