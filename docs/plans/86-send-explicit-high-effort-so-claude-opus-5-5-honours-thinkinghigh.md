---
id: 86
slug: send-explicit-high-effort-so-claude-opus-5-5-honours-thinkinghigh
title: "Send explicit high effort so Claude Opus 5.5 honours ThinkingHigh"
kind: exec-plan
created_at: 2026-09-30T04:37:11Z
intention: "intention_01m3r9m80dep1rcxhd7mh23xns"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-30T04:37:11Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-30T13:56:02Z
      mode: "implement"
      note: "Milestones 1 and 2 implemented"
---

# Send explicit high effort so Claude Opus 5.5 honours ThinkingHigh

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A Baikai caller chooses reasoning depth with `Options.thinking`. On Anthropic models that use
*adaptive* thinking, where the model decides how much to think under an effort setting, Baikai
maps each level to the request field `output_config.effort`. For `ThinkingHigh`, Baikai
currently sends no effort field. That behavior assumes `high` is Anthropic's default. The
assumption stopped being true with Claude Opus 5.5, which Baikai 0.7.1.0 shipped as
`anthropic_claude_opus_5_5`. Anthropic's effort documentation, checked 2026-09-29 at
https://platform.claude.com/docs/en/build-with-claude/effort, says: "Most Claude models default
to high effort ...; Claude Opus 5.5 defaults to medium." It also says: "Setting `effort` to the
model's default (`"medium"` on Claude Opus 5.5, `"high"` on other models) produces exactly the
same behavior as omitting the `effort` parameter entirely."

So a caller who asks Opus 5.5 for `ThinkingHigh` gets medium effort today. The only signal is
an `effort_omitted` entry in the call's evidence, which describes the wire, not the effect.
After this plan, every adaptive-thinking request sends the effort word it means, including
`"high"`. `ThinkingHigh` on Opus 5.5 runs at high effort. Its evidence records `effortText =
Just "high"` with no adjustment, and strict evidence mode no longer refuses that request. On
every other adaptive model, the behavior is unchanged, because explicit `high` equals their
default.


## Progress

- [x] The adaptive mapper sends `"high"` for `ThinkingHigh` and produces no adjustment. The
  pinned translation table and a new Opus 5.5 wire test pass. The Claude, core, and
  doc-shapes suites pass. (2026-09-30: `baikai-claude-test` 408 passed, including
  "Opus 5.5 high sends explicit high effort" and the new `high` case of the merged
  `output_config` group; `baikai-test` 794 passed; `doc-shapes` PASS; fourmolu and
  `git diff --check` clean.)
- [x] User documentation, the Unreleased changelog, and ADR 0003 describe the explicit
  mapping. The Opus 5.5 caveat is replaced with a fixed-in entry. (2026-09-30: caveat
  paragraph and table row rewritten in `docs/user/models-and-providers.md`;
  `effort_omitted` row, count sentence, and strict-mode paragraph updated in
  `docs/user/model-call-evidence.md`; `docs/capabilities/reasoning-effort-control.md`
  corrected; Unreleased `### Known issues` replaced by `### Fixed`; ADR 0003 revision
  appended; `doc-shapes` PASS.)


## Surprises & Discoveries

- `docs/capabilities/reasoning-effort-control.md` also stated the old mapping ("`high` on
  an adaptive-thinking Anthropic model sends no effort field at all"), though the plan did
  not list it. Its example of a lossy translation now names `minimal` being sent as `low`.
- `mergedOutputConfigTest` used `ThinkingMedium`, so it became a two-case group that also
  checks `ThinkingHigh` on Opus 5.5 merging `"effort": "high"` with a JSON-schema format.
- No live probe was run; the plan does not require one.


## Decision Log

- Decision: Always send the explicit effort word on adaptive requests, including `"high"`.
  Do not add a per-model "default effort" catalog fact.
  Rationale: Anthropic documents explicit default effort as behaviorally identical to
  omission. Every adaptive catalog generation already accepts explicit `low`, `medium`,
  `xhigh`, or `max` through the same field, so it accepts `high`. A catalog fact would
  preserve a wire ambiguity that serves no caller. It would also have to be curated for every
  future generation, and a missed entry would silently weaken the request again.
  [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md)
  asks for catalog facts where wire behavior differs by generation. Here, the explicit shape
  removes the difference.
  Date: 2026-09-29

- Decision: Keep the public `Baikai.Evidence.EffortOmitted` constructor and its
  `effort_omitted` JSON encoding. Stop producing it only in the Claude adaptive mapper.
  Rationale: Older evidence records contain it and must still decode. Custom providers may
  legitimately use it. Removing a public constructor is a breaking change governed by
  [ADR 0016](../adr/0016-deprecated-names-are-removed-at-the-next-major.md), and this plan
  does not need that change.
  Date: 2026-09-29


## Outcomes & Retrospective

Completed 2026-09-30. Every adaptive-thinking request now sends its effort word;
`ThinkingHigh` on `anthropic_claude_opus_5_5` sends `output_config.effort: "high"`, its
translation reports `effortText = Just "high"` with no adjustments, and the strict
pre-dispatch check no longer refuses it. `adaptiveEffort` became total over `Text`,
which removed the `Nothing` branch from `adaptiveAdjustments`; only `minimal` is still
adjusted (`effort_clamped` to `low`). `EffortOmitted` stays in the public vocabulary,
with no shipped producer. The durable context — that omitting a default is unsafe because
Anthropic's defaults differ per model — is recorded as a revision to ADR 0003; no new ADR
was needed, since the decision itself is unchanged.


## Context and Orientation

Baikai is a Haskell library for calling model providers. The Anthropic Messages adapter builds
its request in `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`. There,
`computeThinking` turns the caller's `Maybe ThinkingLevel` into a `ThinkingPlan`, containing
the SDK thinking field, the optional effort word, and an optional token budget. It also returns
a `ThinkingTranslation`, the evidence description of what the request became. For models whose
catalog compatibility record has `thinkingStyle = AnthropicThinkingAdaptive`, it sends
`thinking: {"type": "adaptive", "display": "summarized"}` and calls these functions:

```haskell
adaptiveEffort :: ThinkingLevel -> Maybe Text
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing
  ThinkingXHigh -> Just "xhigh"
  ThinkingMax -> Just "max"
```

`adaptiveAdjustments` then derives the adjustment list from what `adaptiveEffort` produced:
`Nothing` becomes `[EffortOmitted lvl]`, and a word other than the level's own name becomes
`EffortClamped`. `mergeEffort` places the word into `output_config.effort`, alongside any
structured-output format. The same `computeThinking` result feeds both the wire request and the
pre-dispatch strict-evidence gate (`describeThinking`). Changing `adaptiveEffort` therefore
changes both consistently.
[ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) requires this:
the adapter that builds the wire value owns its description. ADR 0003's context section
lists "Anthropic's adaptive style sends no effort field for `high`" as one of the adjustment
sites that motivated the decision.

The adaptive catalog models are Opus 5.5, Opus 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 5.5,
Sonnet 5, Sonnet 4.6, Fable 5.1, and Fable 5. The effort page cited above lists all of them as
supporting the effort parameter with `high`. Budget-style models, including Opus 4.5, Sonnet
4.5, and Haiku 4.5, send `budget_tokens` instead and are unaffected.

`Baikai.Evidence.weakensThinking` in `baikai/src/Baikai/Evidence.hs` treats `EffortOmitted` as
weakening. `Baikai.Evidence.Build.checkEvidenceRequirements` in
`baikai/src/Baikai/Evidence/Build.hs` refuses a strict call whose translation carries any
weakening adjustment. Today, a strict caller asking an adaptive model for `ThinkingHigh` is
therefore refused before dispatch. After this plan, that call proceeds.

The tests that pin the current behavior follow. The implementation must change these exact
assertions, not look for others. `baikai-claude/test/ThinkingSpec.hs`, in the translation table
used by `translationTableTests`, has this row:

```haskell
    -- "high" sends no effort field at all, which on the wire is
    -- indistinguishable from expressing no preference.
    ( AnthropicThinkingAdaptive,
      ThinkingHigh,
      Nothing,
      Nothing,
      [EffortOmitted ThinkingHigh]
    ),
```

It must become `(AnthropicThinkingAdaptive, ThinkingHigh, Just "high", Nothing, [])`, with the
comment removed. The same file's test-local expectation table, used by `styleTests`, has:

```haskell
adaptiveEffort :: ThinkingLevel -> Maybe Text.Text
adaptiveEffort = \case
  ...
  ThinkingHigh -> Nothing
```

Its `ThinkingHigh` line must become `ThinkingHigh -> Just "high"`.

`baikai/test/StrictEvidenceSpec.hs` contains `refusesDowngrade "an adaptive high sends no effort
field at all" (EffortOmitted ThinkingHigh) "indistinguishable on the wire"`. That test checks the
gate's handling of a synthetic adjustment, not the adapter, so its assertion stays. Rename only
its label to "an omitted effort field is indistinguishable from the provider default", because
the old label names adapter behavior that will no longer exist. `baikai/test/EvidenceSpec.hs`
uses `EffortOmitted ThinkingHigh` in a JSON round trip and stays unchanged.

The documentation that states the old mapping follows. In `docs/user/models-and-providers.md`,
the reasoning-effort table row "Anthropic adaptive thinking" says Baikai omits `high`. The same
file's "Opus 5.5 effort caveat" paragraph, added on 2026-09-29, describes the bug. In
`docs/user/model-call-evidence.md`, the adjustment table has an `effort_omitted` row, and the
strict-mode paragraph explains `effort_omitted`. `CHANGELOG.md` has an Unreleased `### Known
issues` entry for this bug.

This plan is independent of
`docs/plans/85-prove-gpt-6-1-sol-and-claude-sonnet-5-5-live-compatibility.md`, whose smoke cases
send `ThinkingLow`.


## Plan of Work

Milestone 1 changes behavior. In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`,
change `adaptiveEffort`'s type to `ThinkingLevel -> Text`, since every level now has a word. Map
`ThinkingHigh` to `"high"` and keep the other mappings. Make `ThinkingPlan.effort` `Just` that
word for adaptive requests. Simplify `adaptiveAdjustments` to produce `EffortClamped` only when
the word differs from the level's canonical name. Only `minimal` then becomes `low`. Update the
Haddock comments on both functions: they must no longer claim that `high` is the provider
default, and should cite the effort page and its per-model defaults. Update the ThinkingSpec
rows quoted above. Add one binding test to `baikai-claude/test/ThinkingSpec.hs`, for example in
`adaptiveHigherEffortTests`, that maps `anthropic_claude_opus_5_5` with `Options.thinking =
Just ThinkingHigh`. It must assert that the request's `output_config.effort` is `Just "high"`
and that the translation has `effortText = Just "high"` and no adjustments. It must also assert
that a strict pre-dispatch check (`checkEvidenceRequirements (EvidenceRequired
EvidenceRequestedOnly)`) over that translation returns no `ThinkingWouldDowngrade`. Combining
`responseFormat` with `ThinkingHigh` must still place both the format and `"effort": "high"` in
one `output_config`; the existing `mergedOutputConfigTest` covers this merge. Extend it with a
`ThinkingHigh` case if it uses another level. Rename the StrictEvidenceSpec label as described.

Milestone 2 updates documentation. In `docs/user/models-and-providers.md`, rewrite the table
row to say that adaptive thinking sends `low`, `medium`, `high`, `xhigh`, and `max` explicitly
and maps `minimal` to `low`. Replace the Opus 5.5 caveat paragraph with one sentence saying
`ThinkingHigh` now sends explicit `high`, so Opus 5.5, whose default is `medium`, honours it.
In `docs/user/model-call-evidence.md`, change the `effort_omitted` row to say that no shipped
adapter currently emits it, and that it remains for older records and custom providers. Adjust
the adjustment count sentence above the table to match. Adjust the strict-mode paragraph so it
no longer names Anthropic `high` as its example. In `CHANGELOG.md`, replace the Unreleased
`### Known issues` entry with a `### Fixed` entry. It must state that adaptive `ThinkingHigh`
now sends `output_config.effort: "high"`, fixing Opus 5.5 running at medium effort. It must
also say that evidence for such calls no longer carries `effort_omitted`, and that strict mode
no longer refuses them. Append a dated note to
[ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) recording that the
Anthropic adaptive `high` site was removed on this date, and why.


## Concrete Steps

Run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Before the change, confirm the failing premise offline by checking the pinned row:

```bash
grep -n 'EffortOmitted ThinkingHigh' baikai-claude/test/ThinkingSpec.hs
```

After the edits, run the affected suites:

```bash
cabal test baikai:baikai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes
```

Each suite should end with a line like the following:

```text
All N tests passed
```

Check formatting of the handwritten Haskell and whitespace:

```bash
fourmolu --mode check baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs baikai-claude/test/ThinkingSpec.hs baikai/test/StrictEvidenceSpec.hs
git diff --check
```


## Validation and Acceptance

With `anthropic_claude_opus_5_5` and `Options.thinking = Just ThinkingHigh`, the mapped request
body contains `"output_config": {"effort": "high"}` and `"thinking": {"type": "adaptive",
"display": "summarized"}`. The translation reports `mode = ThinkingModeAdaptive`, `effortText =
Just "high"`, and `adjustments = []`. The strict pre-dispatch check returns no downgrade. The
pinned ThinkingSpec row fails before the change and passes after it. For every other adaptive
catalog model, the same request differs only by gaining `"effort": "high"`. Anthropic documents
that as identical to the prior behavior. `ThinkingMinimal` still sends `"low"` with
`effort_clamped`. Budget-style models still send `budget_tokens` with no effort field.

No live check is required. The wire change is observable offline, and the accepted value is
documented. A live probe could prove only that the API accepts `high`, which the existing
`low`, `medium`, `xhigh`, and `max` cases on the same field already establish. It could not
measure effort. If an implementer runs one anyway, record the result in Surprises &
Discoveries.


## Idempotence and Recovery

The change is local to one mapper and its tests, and can be reapplied or reverted with git. If a
downstream consumer depended on `effort_omitted` appearing for `high`, the Fixed changelog entry
names the change. Old evidence records still decode.


## Interfaces and Dependencies

`Baikai.Provider.Claude.Internal.Request.adaptiveEffort` changes from `ThinkingLevel -> Maybe
Text` to `ThinkingLevel -> Text`. It is an internal module, so no public signature changes.
`Baikai.Evidence.EffortOmitted` remains exported. The request is still built with the
`claude` SDK's `Messages.OutputConfig` and its `effort` field, which already carries the
other levels.
