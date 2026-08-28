---
id: 11
slug: adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send
title: "Adopt the Anthropic Messages capabilities baikai does not yet send"
kind: master-plan
created_at: 2026-08-28T04:52:20Z
intention: "intention_01m13ba2w5enrrbdvg022b1mrn"
---

# Adopt the Anthropic Messages capabilities baikai does not yet send

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

baikai is a Haskell library that gives callers one way to talk to several
model providers. Its Anthropic backend lives in the `baikai-claude`
package and speaks Anthropic's Messages API — the HTTP endpoint at
`https://api.anthropic.com/v1/messages` — through the `claude` package
from Hackage.

Anthropic's Messages API has grown four capabilities that baikai does not
use. A caller of baikai today cannot ask for fast mode, which runs the
same model at higher output speed for a higher price. A caller who asks
for reasoning on a current model gets reasoning blocks whose text is
empty, because Anthropic stopped returning reasoning summaries by default
and baikai never asks for them. A caller whose request is refused on
safety grounds is told that it was refused but not which category of
refusal it was. And baikai has no position at all on Anthropic's
server-side fallback feature, where the provider retries a refused
request against a different model on the caller's behalf.

After this initiative, three of those four are closed and the fourth has
a recorded, deliberate answer. A caller will be able to write
`emptyOptions & #speed ?~ SpeedFast` and have baikai send fast mode to a
model whose catalog entry says fast mode exists there, refuse it clearly
on a model where it does not, and report the doubled price rather than
quietly under-reporting the bill. A caller who asks for reasoning will
receive reasoning text again, and where the provider still returns
nothing, the evidence record will say so instead of leaving the caller to
guess. A caller whose request is refused will be able to read the
provider's own refusal category off the error. And the repository will
carry a decision, in an ADR rather than in someone's head, about whether
baikai forwards Anthropic's server-side fallback parameter at all.

Explicitly in scope: the `speed` request field, the `thinking.display`
request field, the `stop_details` response field, a decision about the
`fallbacks` request field, and the upgrade of the `claude` dependency
from 1.4 to 1.5 that three of those four require.

Explicitly out of scope, and named here so a later reader does not have
to rediscover the boundary: Anthropic's task budgets, mid-conversation
system messages, compaction, context editing, the Files API, and the
Managed Agents surface. Each is a separate capability with its own
design questions, and none of them is blocked by this work. Also out of
scope is any retry loop of baikai's own — see the Decomposition Strategy
below, where ADR 0005 governs that boundary.


## Decomposition Strategy

The initiative splits into four work streams. The split is driven by one
hard technical fact and one architectural question, not by which files
each change touches.

The hard technical fact is the dependency version. `baikai-claude`
declares `claude ^>=1.4` in `baikai-claude/baikai-claude.cabal` and
currently resolves to `claude` 1.4.0. Reading the 1.4.0 source confirms
what is and is not available: the request record `Claude.V1.Messages.CreateMessage`
already carries a `speed :: Maybe Speed` field, so fast mode needs no
dependency change at all. But the `Thinking` type in 1.4.0 is only
`ThinkingAdaptive | ThinkingEnabled { budget_tokens :: Natural }` with no
way to express `display`, there is no `stop_details` field anywhere, and
there is no `fallbacks` field. Those three arrived in `claude` 1.5.0,
which is released on Hackage. So one work stream — fast mode — can be
delivered against the dependency baikai already has, and two others
cannot begin until the dependency moves.

That bump is not a one-line edit, which is why it is its own plan rather
than a preamble to another. `claude` 1.5.0 adds a `Pause_Turn`
constructor to `Claude.V1.Messages.StopReason`. The function
`mapStopReason` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs` matches on
that type with no wildcard branch, and `baikai-claude/baikai-claude.cabal`
compiles the package with `-Werror=incomplete-patterns`. The bump is
therefore a guaranteed build failure until somebody decides what a paused
turn means to a baikai caller, and that decision is a genuine one with
more than one defensible answer. Bundling it inside a feature plan would
hide a real design choice inside a diff about something else.

The architectural question governs the fourth stream. ADR 0005
(`docs/adr/0005-what-baikai-deliberately-does-not-do.md`) states that
"baikai does not own retries. It has no retry or fallback loop:
`Baikai.Error` classifies whether an error is retryable and nothing acts
on it." Anthropic's server-side fallbacks are a fallback loop, but the
loop runs on Anthropic's side; baikai would only forward a request field
and report what came back. Whether that is inside or outside the line
ADR 0005 draws is exactly the sort of question an ADR exists to answer,
and the honest possible outcomes include "we adopt it" and "we decline it
and record why". Either way the answer belongs in `docs/adr/`, so the
plan that asks the question also owns amending the ADR.

Alternatives considered and rejected. Folding the dependency bump into
whichever feature plan ran first was rejected because it buries the
`Pause_Turn` decision. Merging the display and refusal streams into a
single "adopt claude 1.5" plan was rejected because the two have nothing
in common beyond the dependency: one is about a request field and the
evidence vocabulary, the other about a response field and the error
vocabulary, and each is independently verifiable. Making fast mode wait
for the bump was rejected because it needs nothing from it and would
serialize deliverable work behind a breaking change for no benefit.

The ADRs relevant to this initiative, read during planning and carried
into the child plans that depend on them:

`docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
is the governing record for two of the four streams. It says that a fact
about what a provider or model generation accepts on the wire is a field
of the compatibility record carried by the model's generated catalog
entry, sourced from the catalog data, and that no adapter may consult a
table keyed by model id. Fast mode availability is exactly such a fact —
it exists on Claude Opus 5 and Claude Opus 4.8 and nowhere else, and it
was removed from Claude Opus 4.7 after having existed there — so it
belongs in the catalog and not in a prefix match on the model id. The
same applies to whether a generation returns reasoning summaries by
default.

`docs/adr/0002-requested-translated-observed-are-never-collapsed.md` and
`docs/adr/0003-the-adapter-owns-the-translation-description.md` govern how
each stream reports what it did. baikai keeps three separate facts about
every call: what the caller asked for, what baikai translated that into
on the wire, and what the provider reported back. A capability that is
requested but cannot be observed must be recorded as such rather than
assumed to have taken effect. This matters concretely for fast mode:
`Claude.V1.Messages.Usage` in `claude` 1.4.0 has no field reporting which
speed actually ran, so fast mode is requestable and translatable but not
observable, and the plan must say so rather than imply the request
succeeded.

`docs/adr/0005-what-baikai-deliberately-does-not-do.md` is discussed
above and governs the fallbacks decision.

`docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md` governs
any public-API removal or rename these plans introduce, and matters most
to the refusal stream, where adding a constructor to a public sum type is
a breaking change for consumers who pattern-match on it.

`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md`
requires that any example added to Haddock or to the user guides compile
as part of the test suite, which each child plan must honour when it
documents its new option.

No cross-repository ADR was found to apply. The Mori registry was
consulted for the `claude` package
(`mori://MercuryTechnologies/claude`), which is a dependency source
rather than a decision record.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Send Anthropic fast mode as a catalog-gated request option | docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md | None | None | Not Started |
| EP-2 | Upgrade the claude SDK to 1.5 and decide what a paused turn means | docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md | None | EP-1 | Not Started |
| EP-3 | Ask Anthropic for summarized thinking instead of silently empty blocks | docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md | EP-2 | EP-1 | Not Started |
| EP-4 | Carry the refusal category into the error and settle server-side fallbacks | docs/plans/72-carry-the-refusal-category-into-the-error-and-settle-server-side-fallbacks.md | EP-2 | EP-3 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 depends on nothing and can start immediately. Everything it needs —
the `speed` field on `Claude.V1.Messages.CreateMessage` and the
`Speed` type with its `SpeedStandard` and `SpeedFast` constructors —
exists in `claude` 1.4.0, the version the repository already builds
against.

EP-2 depends on nothing either, and could in principle run first or in
parallel with EP-1. It is listed with EP-1 as a soft dependency for a
sequencing reason rather than a technical one: EP-1 adds a per-model
capability flag to the compatibility record and to the catalog fetcher,
and EP-2's changes to `mapStopReason` are easier to review against a tree
where that pattern is already established. If the two are worked
concurrently, expect a merge conflict only in `CHANGELOG.md`, and
resolve it by keeping both entries.

EP-3 has a hard dependency on EP-2. The constructor it needs,
`Claude.V1.Messages.ThinkingAdaptiveWithDisplay`, does not exist in
`claude` 1.4.0; the `Thinking` type there has exactly two constructors
and neither carries a display setting. EP-3's code will not compile until
the dependency has moved. Its soft dependency on EP-1 is again about
review order: both plans add a field to
`Baikai.Compat.AnthropicMessagesCompat` and a corresponding fact to the
catalog fetcher, and doing the second one is much easier with the first
one to copy.

EP-4 has a hard dependency on EP-2 for the same reason: `stop_details`
and `fallbacks` do not exist in `claude` 1.4.0. Its soft dependency on
EP-3 exists because both plans touch the terminal-event construction in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`, and doing
them in either order is fine but doing them simultaneously in two working
trees is not.

EP-3 and EP-4 can proceed in parallel once EP-2 is complete, provided the
integration point named below is respected.


## Integration Points

There are three shared artifacts that more than one child plan touches.
Each is named here so that two plans cannot make incompatible assumptions
about it.

The first is `Baikai.Compat.AnthropicMessagesCompat`, the record in
`baikai/src/Baikai/Compat.hs` that carries per-model facts about what the
Anthropic Messages API accepts for that model. It has five fields today:
`supportsLongCacheRetention`, `supportsCacheControlOnTools`,
`sendSessionAffinityHeaders`, `thinkingStyle` and
`supportsSamplingParameters`. EP-1 adds a sixth field describing whether
fast mode exists on the model, and EP-3 adds a seventh describing whether
the model returns reasoning summaries by default. EP-1 owns establishing
the pattern; EP-3 follows it. Both must extend the same four places that
`supportsSamplingParameters` already occupies: the record and its
`default…` value in `baikai/src/Baikai/Compat.hs`, the curated facts
table `anthropicInclude` in `baikai/fetch/FetchModelsCore.hs`, the JSON
`compat` block emitted into `baikai/data/models/anthropic.json`, and the
generator in `baikai/gen/GenModelsCore.hs` that renders that JSON into
`baikai/src/Baikai/Models/Generated.hs`. Whichever plan runs second must
read the first plan's diff before starting, because the fetcher's
`AnthropicGenerationFacts` record and its three helper values
(`adaptiveNoSampling`, `adaptiveWithSampling`, `budgetWithSampling`) will
have changed shape.

The second is the pair of hand-written test tables that pin every
Anthropic catalog entry's facts:
`expectedAnthropicFacts` in `baikai/test/CatalogSpec.hs` and
`anthropicModels` in `baikai-claude/test/ThinkingSpec.hs`. Both tables
exist precisely so that a catalog refresh cannot change a per-model fact
without a human editing a row. EP-1 and EP-3 each widen the tuple those
tables hold. Whichever runs second must widen the tuple the first one
left behind rather than the one described in this MasterPlan.

The third is the `Messages.Message_Stop` branch of the `translate`
function in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`, which
decides whether a completed stream ends in an `EventDone` or an
`EventError`. EP-2 changes it to account for a paused turn, and EP-4
changes it to carry the refusal category. EP-2 owns the shape of that
branch after its change; EP-4 extends whatever EP-2 leaves.

Two cross-plan decisions are expected to become ADRs. The first is the
outcome of EP-4's fallbacks question, which either amends
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` to say that
forwarding a provider's own server-side fallback parameter is inside the
line, or records the refusal to adopt it as a further deliberate
exclusion. The second is EP-2's answer to what a paused turn means, which
adds a durable statement about how baikai represents a provider stop
reason that has no baikai equivalent — a question that will recur every
time Anthropic adds a stop reason.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-1: Fast mode support is a catalog fact carried by the compat record
- [ ] EP-1: `Options.speed` reaches the wire, is refused on unsupporting models, and is recorded in evidence
- [ ] EP-1: Fast-mode pricing is reported truthfully rather than at the standard rate
- [ ] EP-2: `claude` moves to `^>=1.5` and the package builds
- [ ] EP-2: A paused turn has a decided, tested representation
- [ ] EP-3: Reasoning summaries are requested and arrive non-empty
- [ ] EP-3: A model that returns no summary says so in the evidence record
- [ ] EP-4: A refusal carries the provider's category and explanation
- [ ] EP-4: The server-side fallbacks question is answered in an ADR


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

Two discoveries during planning changed the shape of this MasterPlan and
are recorded here so a later reader does not repeat the mistakes.

The first is that the initiative was scoped from reading the wrong copy
of the dependency. A local checkout of the `claude` package at
`/Users/shinzui/Keikaku/hub/haskell/claude-project` is at version 1.5.0,
while `baikai-claude` builds against 1.4.0 from Hackage. Three of the
four capabilities appeared to be available when they were not. The
correction was made by reading the 1.4.0 tarball directly:

```bash
tar xzf ~/.cabal/packages/hackage.haskell.org/claude/1.4.0/claude-1.4.0.tar.gz
grep -c "ThinkingAdaptiveWithDisplay" claude-1.4.0/src/Claude/V1/Messages.hs
```

which prints `0`. The lesson generalizes: check the resolved version, not
the checkout that happens to be on disk.

The second is that one of the four capabilities was not missing at all.
The refusal path already classifies an Anthropic refusal as
`Baikai.Error.ContentFiltered` rather than as an unclassified provider
error — `baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs:654`
constructs it, and a named test at `baikai-claude/test/SseSpec.hs:184`,
"a refusal stop is ContentFiltered, not an unclassified provider error",
asserts both the category and that the error is not retryable. EP-4 was
rescoped from "handle refusals" to "carry the refusal's category", which
is a much smaller change, because the surrounding behaviour is a decision
somebody already made and tested.


## Decision Log

- Decision: Decompose into four ExecPlans — fast mode, the dependency
  bump, thinking display, and refusal plus fallbacks — rather than three
  plans with the bump folded in, or two plans grouping the post-bump work.
  Rationale: the `claude` 1.5.0 bump forces a decision about the new
  `Pause_Turn` stop reason under `-Werror=incomplete-patterns`, and a
  decision with more than one defensible answer deserves to be visible
  rather than buried in a feature diff. Fast mode needs no bump at all,
  so serializing it behind one would delay deliverable work for nothing.
  Date: 2026-08-28

- Decision: EP-4 owns the question of whether baikai forwards Anthropic's
  server-side `fallbacks` parameter, and owns amending
  `docs/adr/0005-what-baikai-deliberately-does-not-do.md` with whichever
  answer it reaches, including the answer "no".
  Rationale: ADR 0005 says baikai owns no fallback loop. Anthropic's
  server-side fallbacks put the loop on the provider's side, which is
  arguably outside what that ADR excludes, but the argument has to be
  made and recorded rather than assumed. A plan that may legitimately end
  in "we decided not to" is still a plan worth having, because the
  decision is the deliverable.
  Date: 2026-08-28

- Decision: Fast mode availability and reasoning-summary behaviour are
  modelled as fields of `Baikai.Compat.AnthropicMessagesCompat`, sourced
  from the curated catalog, rather than as a check against the model id
  in the adapter.
  Rationale: `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`
  requires it, and the history it records is directly on point — a prefix
  table keyed by model id shipped the wrong thinking shape for
  `claude-sonnet-5` because nobody refreshed the table when the catalog
  gained the model. Fast mode has exactly the same failure mode
  available to it: it exists on Opus 5 and Opus 4.8, never existed on
  Opus 4.6, and was removed from Opus 4.7 after existing there, so no
  ordering of model ids predicts it.
  Date: 2026-08-28

- Decision: Task budgets, mid-conversation system messages, compaction,
  context editing, the Files API, and Managed Agents are out of scope.
  Rationale: none is blocked by this work and each carries its own design
  questions. Naming the exclusion here prevents scope creep into any of
  the four child plans.
  Date: 2026-08-28


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision. Before marking the MasterPlan complete,
distill durable project context from this MasterPlan and its child ExecPlans into
docs/adr/. Keep task-local execution and coordination details here.

(To be filled during and after implementation.)
