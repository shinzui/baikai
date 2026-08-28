---
id: 70
slug: upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means
title: "Upgrade the claude SDK to 1.5 and decide what a paused turn means"
kind: exec-plan
created_at: 2026-08-28T04:52:33Z
intention: "intention_01m13ba2w5enrrbdvg022b1mrn"
master_plan: "docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md"
---

# Upgrade the claude SDK to 1.5 and decide what a paused turn means

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

baikai's Anthropic backend talks to the provider through a third-party
Haskell package called `claude`, published on Hackage. The package
`baikai-claude` currently depends on version 1.4, and that version cannot
express three things Anthropic's API now offers: asking for a readable
summary of the model's reasoning, reading the category of a refusal, and
requesting the provider's server-side fallback behaviour. Version 1.5,
which is released, adds all three.

This plan does one thing: move the dependency to 1.5 and leave the tree
building, tested, and unchanged in behaviour. It deliberately adopts none
of the new capabilities. Two sibling plans do that, and both are blocked
until this one lands.

The bump is not a one-line edit, which is why it has a plan of its own.
Version 1.5 adds a new constructor, `Pause_Turn`, to the type
`Claude.V1.Messages.StopReason`. baikai has a function that matches on
that type with no catch-all branch, and the package is compiled with
`-Werror=incomplete-patterns`, which turns a missing branch from a
warning into a build failure. So the bump cannot compile until somebody
decides what a paused turn means to a baikai caller — and that is a real
question with more than one defensible answer, not a formality.

After this plan, `cabal build all` and `cabal test all` both pass against
`claude` 1.5, no caller-visible behaviour has changed, and the repository
carries a written decision about how baikai represents a provider stop
reason that has no baikai equivalent.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `claude` bound raised to `^>=1.5` and the resolver picks 1.5.0
- [ ] M1: every compile error from the bump catalogued before any is fixed
- [ ] M2: the paused-turn decision made and recorded in the Decision Log
- [ ] M2: `mapStopReason` handles `Pause_Turn` and the package compiles
- [ ] M2: a test proves a paused-turn stream produces the decided outcome
- [ ] M3: full suite green; no behaviour change on any existing test
- [ ] M3: `CHANGELOG.md` updated and an ADR written for the stop-reason rule


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

One thing found during planning is worth stating up front, because it
changes how you should read the `Pause_Turn` problem.

Anthropic emits `stop_reason: "pause_turn"` when a *server-side* tool —
one that Anthropic runs on its own infrastructure, such as web search —
needs the turn suspended and resumed. baikai does not send server-side
tools. It forwards the caller's own tool definitions, which produce
`tool_use`, not `pause_turn`. Searching the repository for the concept
finds nothing:

```bash
grep -rn "Pause_Turn\|pause_turn" --include='*.hs' baikai baikai-claude baikai-openai
```

returns no matches. So in practice a paused turn should never arrive at
baikai's assembler today. The compiler nonetheless demands a branch, and
what that branch does when the impossible happens is the decision this
plan makes.


## Decision Log

- Decision: this plan adopts no new capability from `claude` 1.5. It
  moves the dependency and stops.
  Rationale: a dependency bump that also adds features cannot be reverted
  cleanly if the bump turns out to be the problem, and it makes the
  review of both harder. The two sibling plans that consume 1.5 —
  `docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md`
  and `docs/plans/72-carry-the-refusal-category-into-the-error-and-settle-server-side-fallbacks.md`
  — each stand alone once this lands.
  Date: 2026-08-28

- Decision: (to be recorded during Milestone 2) what a paused turn maps
  to. The Plan of Work below lays out the options and states a
  recommendation; the implementer must record the decision actually taken
  here, with its rationale and date, before the milestone is complete.
  Date: (pending)


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you have never seen this repository.

**The repository.** baikai is a Haskell library giving callers one way to
talk to several large-language-model providers. It is a multi-package
Cabal project; `cabal.project` at the root lists the packages. The
package this plan edits is `baikai-claude`, the backend that talks to
Anthropic's Messages API.

**The dependency.** `baikai-claude/baikai-claude.cabal` declares
`claude ^>=1.4` in its `build-depends`. The `^>=` operator is Cabal's
caret bound: `^>=1.4` accepts 1.4 and any later 1.4.x, but not 1.5. The
resolver currently picks 1.4.0. You can confirm which version is in use
at any time from the repository root:

```bash
find dist-newstyle -name plan.json | head -1 | xargs grep -o '"pkg-name":"claude","pkg-version":"[^"]*"'
```

**What 1.5 adds.** From the package's own changelog: support for the
Claude 5 generation of models, including `thinking.display` with
summarized and omitted output modes and an explicit disabled thinking
mode; refusal `stop_details` and the `pause_turn` stop reason; beta
server-side fallback request and response types; and beta
mid-conversation tool changes. The changelog lists no breaking change for
1.5, unlike 1.4, whose entry explicitly flagged one. The break this plan
must handle is therefore not a rename but an added constructor.

**Where the break lands.** The file
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs` contains a
function that translates the provider's stop reason into baikai's own:

```haskell
mapStopReason :: Maybe Messages.StopReason -> Stop.StopReason
mapStopReason = \case
  Just Messages.End_Turn -> Stop.Stop
  Just Messages.Max_Tokens -> Stop.Length
  Just Messages.Stop_Sequence -> Stop.Stop
  Just Messages.Tool_Use -> Stop.ToolUse
  Just Messages.Refusal -> Stop.ErrorReason
  Just Messages.Model_Context_Window_Exceeded -> Stop.Length
  Nothing -> Stop.Stop
```

There is no wildcard branch. `baikai-claude/baikai-claude.cabal` sets
`-Werror=incomplete-patterns` in a shared options block, with a comment
above it explaining exactly why: "Exhaustiveness is an error, not a
warning. A non-exhaustive match is a crash the compiler already found."
So adding a constructor upstream turns this function into a build
failure, by design.

**baikai's own stop reasons.** `baikai/src/Baikai/StopReason.hs` defines:

```haskell
data StopReason
  = Stop
  | Length
  | ToolUse
  | ErrorReason
```

These are the four outcomes baikai reports to a caller, across every
provider — not just Anthropic. They serialize to snake case (`error` for
`ErrorReason`). Adding a constructor to this type is a change to
baikai's public API: any downstream consumer that pattern-matches
exhaustively on it stops compiling.

**How a finished stream ends.** In the same `Stream.hs`, the branch
handling `Messages.Message_Stop` decides whether the call ends in a
success event or an error event:

```haskell
Messages.Message_Stop ->
  let reason = ass ^. #stopReason
      refusal = contentFiltered "Anthropic refused to generate a response (stop_reason=refusal)"
      msg =
        if reason == Stop.ErrorReason
          then finalMessageOnError ass now (refusal ^. #message)
          else finalMessage ass now
      terminalEvent =
        if reason == Stop.ErrorReason
          then EventError (errorTerminal Nothing (ass ^. #responseId) reason msg refusal)
          else EventDone (doneTerminal Nothing (ass ^. #responseId) reason msg)
   in ([terminalEvent], ass)
```

Read this carefully, because it constrains the options below: today,
every path that resolves to `Stop.ErrorReason` produces a
`contentFiltered` error whose message says the model refused. If you map
a paused turn onto `ErrorReason` without touching this branch, a paused
turn would be reported to the caller as a refusal, which is false.

**Relevant ADRs.**
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
records that baikai keeps requested, translated and observed as three
separate facts and never merges them. A stop reason is an *observed*
fact, and the ADR's spirit is that baikai should not report an
observation it did not make.

`docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md` governs
public-API churn. It is about removals rather than additions, but its
underlying principle — that a change to a public name carries a named
version commitment — applies to adding a constructor to a public sum
type, which breaks exhaustive matches downstream.

`docs/adr/0013-library-code-never-calls-exitfailure.md` is relevant in
spirit: library code must fail by returning a value the caller can act
on, never by killing the process. A pattern-match failure at runtime is
precisely the kind of process-killing failure that ADR is against, which
is why the `-Werror` flag exists.

**Sibling plans.** This plan is the second of four under
`docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md`.
It blocks
`docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md`
and
`docs/plans/72-carry-the-refusal-category-into-the-error-and-settle-server-side-fallbacks.md`,
both of which need types that only exist in 1.5. It does not block
`docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md`,
which needs nothing from 1.5. If plan 69 has already landed, expect a
conflict in `CHANGELOG.md` only, resolved by keeping both entries.


## Plan of Work

Three milestones: move the bound and see what breaks, decide and fix the
paused turn, then prove nothing else changed.

### Milestone 1 — move the bound and catalogue the damage

At the end of this milestone the dependency bound names 1.5, the resolver
picks 1.5.0, and you have a written list of every compile error the bump
produced. You will not have fixed any of them yet.

Edit `baikai-claude/baikai-claude.cabal` and change the `claude ^>=1.4`
entry in the library's `build-depends` to `claude ^>=1.5`. The test suite
in the same file also lists `claude` without a bound, inheriting the
library's; check whether it needs the same treatment.

Then build and capture the errors in full rather than fixing the first
one you see:

```bash
cabal build all 2>&1 | tee /tmp/claude15-errors.txt
```

Write the list into the Progress section of this plan before continuing.
The expected list is short — the `Pause_Turn` branch in `mapStopReason`
— but the point of capturing it first is that if the bump breaks anything
else, you find out now and can decide whether this plan should still be
one plan.

If the resolver refuses to pick 1.5.0, the cause is almost always another
package's bound rather than this one; read the resolver's message, which
names the conflicting constraint.

### Milestone 2 — decide what a paused turn means, then implement it

This is the milestone that matters. At the end of it the package
compiles, a test exercises a paused-turn stream, and the Decision Log
above records what was decided and why.

The question: Anthropic can end a turn with `stop_reason: "pause_turn"`,
meaning the turn is suspended and the caller is expected to send the
response content back to resume it. baikai's own `StopReason` has no
value meaning that. What should baikai report?

Four options, with what is right and wrong about each.

*Map it to `Stop.Stop`.* One line, no API change. It is also a lie: the
caller is told the model finished its turn when it did not, and a caller
that trusts the stop reason will treat a truncated answer as complete.
Reject this.

*Map it to `Stop.ToolUse`.* Superficially attractive, because in both
cases the caller must do something and send data back. But `ToolUse`
means "the model called your tool and wants the result", and a caller
acting on that will look for tool-call blocks that are not there. It
substitutes one specific false claim for another. Reject this.

*Add a `Paused` constructor to `Baikai.StopReason.StopReason`.* This is
the most truthful representation, and it is what a reader who values
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
reaches for first. The costs are real: `StopReason` is public API shared
by every provider, not just Anthropic, so adding a constructor breaks
every downstream exhaustive match; it also adds a value that, as the
Surprises section above establishes, baikai cannot currently produce,
because baikai never sends the server-side tools that cause a pause. A
public constructor for an unreachable state invites callers to write
handling that will never run.

*Map it to `Stop.ErrorReason` with a distinct, accurate error.* baikai
reports that the call did not complete, and the caller receives a
`BaikaiError` whose message says the provider paused the turn and that
baikai does not support resuming one. This is honest — the call genuinely
did not produce a finished answer — and it is not silent. It requires
touching the `Messages.Message_Stop` branch quoted in the Context
section, because that branch currently assumes every `ErrorReason` is a
refusal and would otherwise mislabel a pause as a content refusal. It
adds no public API and breaks no consumer.

The recommendation is the fourth option, and the reasoning is worth
stating because a future reader will want to challenge it: baikai should
not grow public vocabulary for a provider state it cannot reach. When
baikai later gains server-side tool support, the plan that adds it will
make paused turns reachable, and that is the plan that should add
`Paused` to the public type, together with the resume path that makes the
constructor useful. Adding it now would ship a public name with nothing
behind it.

The implementer is free to reach a different conclusion — that is why
this is written as options rather than instructions — but must record
whichever conclusion in the Decision Log above with its rationale, and
must not leave the decision implicit in the diff.

Implementing the recommendation means three edits in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`. First, add
the `Just Messages.Pause_Turn -> Stop.ErrorReason` branch to
`mapStopReason`. Second — and this is the part that is easy to miss —
change the `Messages.Message_Stop` branch so that the error it builds
depends on which condition produced the `ErrorReason`, rather than
assuming a refusal. The assembler state carries the SDK's own stop reason
long enough to distinguish them, or you thread the distinction alongside
it; either way, a paused turn must not produce the string "Anthropic
refused to generate a response". Third, pick the right
`Baikai.Error.ErrorCategory` for it. `ContentFiltered` is wrong — nothing
was filtered. `InvalidRequest` is defensible, since the request asked for
something baikai cannot see through to completion. Read the constructor
Haddocks in `baikai/src/Baikai/Error.hs` and choose deliberately; record
the choice.

Do not add a wildcard branch to `mapStopReason` as a shortcut. The
`-Werror` flag and its comment exist so that the next added constructor
also stops the build; a wildcard silently disarms that for every future
version of the dependency.

### Milestone 3 — prove nothing else changed, and write it down

At the end of this milestone the full suite is green and the repository
records the rule.

Run everything and compare against the pre-bump baseline. Because this
plan changes no behaviour, every test that passed before must still pass,
with no test edited except the one added in Milestone 2. If a test needed
editing, that is a behaviour change hiding in a dependency bump — stop
and record it in Surprises & Discoveries before proceeding.

Add a `### Changed` entry to `CHANGELOG.md` under `## [Unreleased]`
naming the new dependency bound and the paused-turn behaviour.

Write an ADR in `docs/adr/` capturing the durable rule, not the specific
case. The corpus follows a plain-filesystem convention rather than a
profiled bundle: files are named `NNNN-slug.md`, numbered sequentially
from the highest existing number, and carry YAML frontmatter with
exactly `title`, `status` and `date`. The highest number at the time of
writing is `0017`. The rule to record is how baikai represents a provider
stop reason it has no equivalent for — the question will recur every time
any provider adds one, and the answer reached here should not have to be
re-derived. Follow the workflow in `agents/skills/exec-plan/ADR.md`.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/baikai`.

Record the baseline before touching anything:

```bash
cabal build all
cabal test all 2>&1 | tee /tmp/baseline-tests.txt
```

Every suite should report `PASS`. The `baikai-agent` suite has two
process-timing tests that occasionally fail under parallel load; if only
that suite fails, re-run it alone with `cabal test baikai-agent` before
treating it as real.

Make the bound change, then:

```bash
cabal build all 2>&1 | tee /tmp/claude15-errors.txt
grep -n "error:" /tmp/claude15-errors.txt
```

The expected output names `Stream.hs` and a non-exhaustive pattern in
`mapStopReason`, in this shape:

```text
Stream.hs:949:1: error: [GHC-94210] [-Wincomplete-patterns, Werror=incomplete-patterns]
    Pattern match(es) are non-exhaustive
    In a case alternative: Patterns of type ... not matched: Just Pause_Turn
```

After the Milestone 2 edits:

```bash
cabal build all
cabal test all
```

Finally, confirm the resolver really moved:

```bash
find dist-newstyle -name plan.json | head -1 \
  | xargs grep -o '"pkg-name":"claude","pkg-version":"[^"]*"'
```

Expect `1.5.0`.


## Validation and Acceptance

Acceptance is three observable things.

First, the dependency moved and the tree builds. `cabal build all`
succeeds and the `plan.json` check above reports `claude` at 1.5.0.

Second, a paused turn behaves as decided. Add a test to
`baikai-claude/test/SseSpec.hs`, the suite that replays recorded
server-sent-event streams through the assembler and asserts on the events
that come out. That file already contains a directly analogous test — "a
refusal stop is ContentFiltered, not an unclassified provider error" —
which builds a `refusalBody` fixture, replays it, and asserts on the
terminal event's error category and retryability. Copy its shape: build a
`pauseTurnBody` fixture whose `message_delta` frame carries
`"stop_reason":"pause_turn"`, replay it, and assert the outcome you
decided in Milestone 2. If you took the recommendation, assert that the
terminal event is an `EventError`, that its error message names a paused
turn and does *not* contain the word "refused", and that its category is
the one you chose. Name the test so it states the decision, for example
"a paused turn is reported as an error naming the pause, not as a
refusal".

Third, nothing else changed. Diff the test output against the baseline:

```bash
cabal test all 2>&1 | tee /tmp/after-tests.txt
diff <(grep -c OK /tmp/baseline-tests.txt) <(grep -c OK /tmp/after-tests.txt)
```

The after-count should exceed the baseline by exactly the number of tests
you added, and no previously passing test should have been modified.


## Idempotence and Recovery

Every step is repeatable. The bound change is a one-line edit to a
`.cabal` file and is reverted with `git checkout
baikai-claude/baikai-claude.cabal`. No data is migrated, no generated
file is rewritten, and nothing is deleted.

If the bump turns out to break more than the single expected pattern
match, do not push through it. Record the full error list in Surprises &
Discoveries, revert the bound, and update this plan — a larger break
means the decomposition in the parent MasterPlan was wrong, and the
MasterPlan should be updated first, per its Living Document Requirements.

If the resolver picks 1.5.0 but a transitive dependency conflict appears,
note that `cabal.project` deliberately carries no `constraints` block and
resolves everything from Hackage; a conflict is therefore real and not a
local pin to be edited around.


## Interfaces and Dependencies

The single dependency change is in
`baikai-claude/baikai-claude.cabal`: `claude ^>=1.4` becomes
`claude ^>=1.5`.

The types this plan touches, all in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`:

```haskell
mapStopReason :: Maybe Messages.StopReason -> Stop.StopReason
```

must remain total against `claude` 1.5's `StopReason`, which after the
bump has seven constructors: `End_Turn`, `Max_Tokens`, `Stop_Sequence`,
`Tool_Use`, `Pause_Turn`, `Refusal`, and
`Model_Context_Window_Exceeded`.

`Baikai.StopReason.StopReason` in `baikai/src/Baikai/StopReason.hs` is
expected to keep its four constructors unless the implementer records a
decision to the contrary. If it does gain one, that is a breaking change
to `baikai`'s public API and must be announced under a `### Changed`
heading in `CHANGELOG.md` naming the release that carries it, in the
spirit of `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md`.

No new capability from `claude` 1.5 is consumed by this plan. The types
`ThinkingAdaptiveWithDisplay`, `StopDetails` and `Fallbacks` become
available on completion and are used by the two sibling plans named in
Context and Orientation.
