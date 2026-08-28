---
id: 72
slug: carry-the-refusal-category-into-the-error-and-settle-server-side-fallbacks
title: "Carry the refusal category into the error and settle server-side fallbacks"
kind: exec-plan
created_at: 2026-08-28T04:52:37Z
intention: "intention_01m13ba2w5enrrbdvg022b1mrn"
master_plan: "docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md"
---

# Carry the refusal category into the error and settle server-side fallbacks

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Anthropic can decline a request on safety grounds. When it does, the
response arrives as a normal successful HTTP 200 whose stop reason is
`refusal`, accompanied by a small object naming *which kind* of refusal
it was and, sometimes, a sentence of explanation.

baikai already handles the refusal itself, and handles it well — the
caller receives a terminal error whose category says the content was
filtered and which is correctly marked not retryable. What the caller
does not receive is the *why*. baikai replaces the provider's structured
detail with one fixed sentence, identical for every refusal, so a caller
cannot distinguish a request declined for one reason from a request
declined for a completely different one. Two callers with entirely
different problems get the same string.

This plan does two things. The first is small and concrete: carry the
provider's refusal category and explanation through to the caller, so a
refusal says what it was.

The second is a decision rather than a feature. Anthropic also offers
*server-side fallbacks*: the caller marks a request as eligible, and when
the model refuses, Anthropic itself re-runs the request against a
different model and returns that result instead. baikai has no position
on this, and it needs one, because
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` states plainly
that "baikai does not own retries. It has no retry or fallback loop."
Whether forwarding a provider's own fallback parameter falls inside or
outside that line is a genuine question. This plan answers it and records
the answer in the ADR — and "we decline to adopt it" is a legitimate,
complete outcome, because the decision is the deliverable.

The observable outcome for the first half: a test replays a refusal
stream carrying a category and asserts the resulting error names that
category, where today it names only the fact of refusal. For the second
half: `docs/adr/0005-what-baikai-deliberately-does-not-do.md` gains a
paragraph settling the question, and if the answer is yes, a caller can
set the option and see the field on the wire.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: the assembler reads `stop_details` off the message delta
- [ ] M1: the refusal category and explanation reach the caller's error
- [ ] M1: the existing refusal test still passes unchanged in intent
- [ ] M1: a new test asserts a categorised refusal names its category
- [ ] M2: the fallbacks question researched against ADR 0005 and answered
- [ ] M2: `docs/adr/0005-what-baikai-deliberately-does-not-do.md` amended either way
- [ ] M2: if adopted — option, wire field, beta header, and evidence handling
- [ ] M2: if declined — the exclusion recorded with its reasoning
- [ ] M3: `CHANGELOG.md` and `docs/user/models-and-providers.md` updated


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

One finding from planning is recorded here because it shrank this plan
substantially and a later reader should not re-derive it.

This work was originally scoped as "baikai does not handle refusals". It
does. `baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`
constructs a `contentFiltered` error on a refusal stop, and
`baikai/src/Baikai/Error.hs` carries a `ContentFiltered` category whose
Haddock names "Anthropic's `refusal` stop" explicitly. A named test
asserts the whole contract:

```haskell
testCase "a refusal stop is ContentFiltered, not an unclassified provider error" $ do
  events <- replayStream 200 [] refusalBody
  assertErrorContract events
  case reverse events of
    (EventError TerminalPayload {errorInfo = Just be} : _) -> do
      be ^. #category @?= ContentFiltered
      isRetryable be @?= False
```

That is a decision somebody made and pinned, not an oversight. This plan
therefore does not touch the classification, the retryability, or the
choice of terminal event. It adds detail to an error that is already
correct.


## Decision Log

- Decision: this plan does not change how a refusal is classified,
  whether it is retryable, or which terminal event it produces.
  Rationale: `baikai-claude/test/SseSpec.hs` contains a named test
  asserting all three, so the current behaviour is a deliberate decision
  rather than an accident. Changing it would need its own justification,
  and none of the work here supplies one.
  Date: 2026-08-28

- Decision: (to be recorded during Milestone 2) whether baikai forwards
  Anthropic's server-side `fallbacks` request field. The Plan of Work
  below sets out the arguments on both sides. The implementer must record
  the conclusion here with its rationale and date, and must amend
  `docs/adr/0005-what-baikai-deliberately-does-not-do.md` to match,
  whichever way it goes.
  Date: (pending)


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

**What a refusal is.** Anthropic's safety classifiers can decline a
request. This is not an HTTP error — the call returns 200 with a normal
response envelope whose `stop_reason` is `"refusal"`, and (on the newer
model generations) a sibling object `stop_details` of the shape
`{"type": "refusal", "category": "...", "explanation": "..."}`. The
category is an open set — values seen so far include `cyber`, `bio`,
`reasoning_extraction` and `frontier_llm` — and both fields can be
absent. `stop_details` is populated *only* for a refusal; it is null for
every other stop reason.

**How baikai reports errors.** `baikai/src/Baikai/Error.hs` defines:

```haskell
data BaikaiError = BaikaiError
  { category :: !ErrorCategory
  , message :: !Text
  , httpStatus :: !(Maybe Int)
  , retryAfterSeconds :: !(Maybe Int)
  , exitCode :: !(Maybe Int)
  }
```

`ErrorCategory` is a sum of ten constructors describing what kind of
failure it was. One of them is `ContentFiltered`, whose Haddock reads:
"The provider refused or filtered the content — OpenAI's
`finish_reason: \"content_filter\"`, Anthropic's `refusal` stop. The
content, not the transport, is the problem, so it is not retryable as-is:
the caller must change what it sent."

Note the JSON encoding: `BaikaiError` derives `ToJSON` and `FromJSON`
with `fieldLabelModifier = camelTo2 '_'`, so field names serialize as
snake case (`http_status`, `retry_after_seconds`). Any field you add
appears on that wire, which consumers may already parse.

**Where the refusal is turned into an error.** In
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`, the
assembler consumes the provider's server-sent events. Two branches
matter. The `Messages.Message_Delta` branch is where the stop reason
arrives and is mapped through `mapStopReason` onto baikai's own
`Baikai.StopReason.StopReason`; a provider `Refusal` becomes
`Stop.ErrorReason`. The `Messages.Message_Stop` branch then decides the
terminal event:

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

The fixed string in that `refusal` binding is the whole of what a caller
learns about why. Note also that the assembler is a state machine: the
stop reason arrives in one event and is consumed in a later one, held in
between on the assembler state record. Anything you read off
`stop_details` must be carried the same way.

**Why this plan is blocked.** The `claude` package version 1.4.0, which
this repository builds against before its sibling plan lands, has no
`stop_details` field anywhere and no fallback types. Confirm for yourself
by extracting the tarball Cabal already downloaded and grepping the
source:

```bash
cd "$(mktemp -d)"
tar xzf ~/.cabal/packages/hackage.haskell.org/claude/1.4.0/claude-1.4.0.tar.gz
grep -c "stop_details" claude-1.4.0/src/Claude/V1/Messages.hs
```

That prints `0`. Version 1.5.0 adds both:

```haskell
data StopDetails = StopDetails
    { category :: Maybe Text
    , explanation :: Maybe Text
    }

data Fallbacks
    = FallbacksDefault
    | FallbacksModels (Vector Fallback)
```

This plan therefore has a hard dependency on
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`.
Do not begin until that has landed.

**What server-side fallbacks are.** The caller adds a `fallbacks` field
to the request and a beta header. When the model refuses, Anthropic
itself re-runs the request against a different model and returns that
model's answer, reporting the transition in the response. In the
`default` mode Anthropic chooses the substitute by refusal category; in
the explicit mode the caller supplies an ordered list of models to try.
The key property for this plan: the loop runs entirely on Anthropic's
side. baikai would send one request and receive one response, as always.

**Relevant ADRs.** Read the first one in full; it is the crux.

`docs/adr/0005-what-baikai-deliberately-does-not-do.md` draws four
boundaries. The fourth is the one at issue: "Baikai does not own retries.
It has no retry or fallback loop: `Baikai.Error` classifies whether an
error is retryable and nothing acts on it. The evidence therefore models
a retry relationship as caller-supplied provenance — an `attempt` ordinal
and an optional `supersedes` call id — not as something baikai observes."
Read its Consequences section too, which stresses that the exclusions
"have teeth in the code rather than only in prose".

`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
requires that what baikai *observed* stay distinct from what it requested
or translated. A refusal category is a pure observation and must be
reported as such. It bears directly on fallbacks too: if Anthropic
substitutes a model, then the model baikai requested and the model that
actually ran differ, and ADR 0005 already says baikai "reports the model
it requested and, separately, the model the provider said it ran".

`docs/adr/0011-core-owns-transport-failure-classification.md` governs
where a failure gets its category. Read it before moving any
classification logic.

`docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md` governs
public-API churn, which matters if Milestone 1 adds a field to
`BaikaiError`.

**Sibling plans.** This is the fourth of four under
`docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md`.
Hard dependency on plan 70. It shares the `Messages.Message_Stop` branch
quoted above with plan 70, which changes that branch first — read plan
70's diff before editing, and extend what it left rather than what is
quoted here. It has a soft ordering relationship with
`docs/plans/71-ask-anthropic-for-summarized-thinking-instead-of-silently-empty-blocks.md`:
both touch `Stream.hs`, so do them in sequence rather than in parallel
working trees.


## Plan of Work

Three milestones: carry the category, settle the fallbacks question, then
write both down.

### Milestone 1 — a refusal says what kind of refusal it was

At the end of this milestone, a caller whose request is refused receives
an error naming the provider's refusal category and, when present, its
explanation. Classification, retryability and the terminal event shape
are unchanged.

Read `stop_details` where the stop reason is read. In
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`, the
`Messages.Message_Delta` branch destructures the message delta to get
`stop_reason`. In `claude` 1.5 the same delta carries
`stop_details :: Maybe StopDetails`. Capture it onto the assembler state
record beside the stop reason it already holds, so the later
`Messages.Message_Stop` branch can use it. Do not try to read it in
`Message_Stop`; it is not there.

Then decide where the detail surfaces, and this is a real choice.

*Fold it into the message text.* The `refusal` binding becomes a string
built from the category and explanation when they are present, falling
back to today's fixed sentence when they are not. Costs nothing, breaks
no consumer, and is immediately useful to anyone reading a log. But it
buries a structured fact in prose, which is exactly what
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
discourages: a caller wanting to branch on the category has to parse
English.

*Add a field to `BaikaiError`.* A `Maybe Text` holding the provider's
category, `Nothing` for every non-refusal and for refusals that carried
none. Structured, branchable, and it matches how `httpStatus`,
`retryAfterSeconds` and `exitCode` already work — each is a provider or
process detail present only for the failure kinds that have one. The cost
is that `BaikaiError` is public API shared by every provider: adding a
field breaks explicit record construction downstream and changes the JSON
encoding, where the new key appears in snake case alongside the existing
ones.

The recommendation is to do both: a structured field for branching and a
message that still reads well on its own, because an error message that
requires a second field to be intelligible is a bad error message. If you
take the recommendation, follow the existing precedent exactly — the new
field is a `Maybe`, defaults to `Nothing` in the `baseError` helper that
all the other constructors go through, and is set only on the refusal
path. Record the JSON key it produces in the Decision Log, since that key
becomes part of baikai's wire contract.

Keep the existing test passing. `baikai-claude/test/SseSpec.hs` contains
"a refusal stop is ContentFiltered, not an unclassified provider error",
whose fixture is a refusal body with no `stop_details`. It must continue
to pass with its assertions unchanged — that is the regression guard
proving you added detail rather than replaced behaviour. If its fixture
needs editing, you have changed something you should not have.

### Milestone 2 — settle server-side fallbacks

At the end of this milestone the repository holds a decision, in
`docs/adr/0005-what-baikai-deliberately-does-not-do.md`, about whether
baikai forwards Anthropic's `fallbacks` field. If the answer is yes, the
option exists and works. If no, the exclusion is recorded with its
reasoning. Either is a complete milestone.

The question, stated fairly. ADR 0005 says baikai does not own retries
and has no fallback loop, and that the exclusions have teeth in the code
rather than only in prose.

The case *for* forwarding it: baikai would own no loop. It sends one
request and receives one response, exactly as now. The retrying happens
on Anthropic's infrastructure, and forwarding a request field is what
baikai does with every other request field. Refusing to forward it does
not prevent a caller from having fallbacks — they can already set an
arbitrary header and, if baikai ever exposes raw body passthrough, an
arbitrary field — it only prevents baikai from describing what happened
when they do. Worse, ADR 0005's own text says baikai "reports the model
it requested and, separately, the model the provider said it ran", which
is precisely the situation a server-side fallback creates; the ADR
already anticipates the divergence it would produce.

The case *against*: ADR 0005's exclusion is about who is responsible when
a call is retried, not about who executes the loop. A caller who sets
`fallbacks` gets a response from a model they did not choose, priced at
that model's rates, with reasoning blocks from that model's generation —
and baikai's cost calculation, its catalog-driven compat decisions, and
its evidence record are all keyed to the model the caller named. Adopting
the field without following it through every one of those places would
produce records that are quietly wrong, which is a worse failure than not
having the feature. Following it through is a much larger piece of work
than "forward a field", and it may belong in its own plan.

There is a defensible third answer: adopt it, but only after the cost and
evidence consequences are enumerated, and record that enumeration as the
scope of a follow-on plan rather than doing it here.

Whichever conclusion you reach, amend
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` in the same
change. The corpus follows a plain-filesystem convention — files named
`NNNN-slug.md` with YAML frontmatter carrying exactly `title`, `status`
and `date` — so amending means editing that file's Decision and
Consequences sections and advancing its `date`, not creating a new
record. Follow `agents/skills/exec-plan/ADR.md`. If the amendment
substantially reverses the ADR rather than clarifying it, prefer a new
ADR that supersedes it and mark the old one's status accordingly.

If the decision is to adopt, the implementation follows the shape plan 69
established for fast mode: a baikai-owned option type rather than the
SDK's, a compat-record gate if support is per-model, the beta header sent
by baikai rather than left to the caller, and an evidence entry when the
request is dropped. Read
`docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md`
and copy its structure. Additionally, and non-negotiably, the response
path must record when a fallback actually fired, so that the model
reported as having run is the model that ran.

### Milestone 3 — write it down

Add a `### Added` entry to `CHANGELOG.md` under `## [Unreleased]` for the
refusal category, and a `### Changed` entry if the error message text
changed shape. Update `docs/user/models-and-providers.md` where it
describes what a caller sees when a request is refused. If Milestone 2
adopted fallbacks, document the option there too. Any code example must
compile in the test suite, per
`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md`; the
`baikai-smoke:doc-shapes` suite is where documented shapes are compiled.


## Concrete Steps

All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/baikai`.

Confirm the blocking plan has landed:

```bash
grep -n "claude" baikai-claude/baikai-claude.cabal | grep '\^>='
```

Expect `claude ^>=1.5`. If it says `^>=1.4`, stop — nothing here will
compile.

Establish the baseline:

```bash
cabal build all
cabal test all
```

Every suite should report `PASS`. The `baikai-agent` suite has two
process-timing tests that occasionally fail under parallel load; if only
that suite fails, re-run it alone with `cabal test baikai-agent`.

Find the existing refusal fixture before editing anything near it:

```bash
grep -n "refusalBody" -A 20 baikai-claude/test/SseSpec.hs
```

After the Milestone 1 edits:

```bash
cabal test baikai-claude
cabal test all
```


## Validation and Acceptance

Acceptance is three things.

First, a categorised refusal names its category. Add a test to
`baikai-claude/test/SseSpec.hs` alongside the existing refusal test.
Build a fixture — call it `categorisedRefusalBody` — whose
`message_delta` frame carries both a refusal stop reason and a
`stop_details` object with a category and an explanation, for example:

```json
{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"..."}},"usage":{"output_tokens":7}}
```

Replay it and assert that the terminal `EventError` carries an error
whose category is still `ContentFiltered`, whose retryability is still
`False`, and which now names `cyber` — in the structured field if you
added one, and in the message text. Name the test so it states the
outcome, for example "a categorised refusal names its category, not just
the fact of refusal".

Second, an uncategorised refusal is unchanged. The existing test "a
refusal stop is ContentFiltered, not an unclassified provider error" must
pass with its assertions untouched. That is the proof this plan added
detail rather than altering behaviour. If you had to edit it, stop and
record why in Surprises & Discoveries.

Third, the fallbacks question is answered. Open
`docs/adr/0005-what-baikai-deliberately-does-not-do.md` and read it. It
must contain an unambiguous statement about server-side fallbacks that a
reader who has never seen this plan can act on, with the reasoning behind
it. A reader must be able to tell whether the answer was "yes", "no", or
"yes, after the following work", and why. If the answer was yes and the
option was implemented, a request built with it must show the field in
the encoded body, asserted in `baikai-claude/test/ShapeSpec.hs`.

The whole suite must pass:

```bash
cabal test all
```


## Idempotence and Recovery

Milestone 1 is additive and safe to repeat; recovery is `git checkout`.
The one change with reach beyond this repository is the JSON encoding of
`BaikaiError` if you add a field: consumers parsing that object will see
a new key. Adding a key is backward compatible for any decoder that
ignores unknown fields, which `aeson`'s generic decoder does by default,
but note it in the changelog regardless.

Milestone 2 has no code to roll back if the decision is to decline. If
the decision is to adopt and the implementation turns out larger than
expected — which the arguments above suggest is likely — stop, record the
finding in Surprises & Discoveries, and update the parent MasterPlan at
`docs/masterplans/11-adopt-the-anthropic-messages-capabilities-baikai-does-not-yet-send.md`
to add a fifth child plan rather than letting this one grow. Its Living
Document Requirements say to update the MasterPlan first and then cascade.

Do not leave Milestone 2 half-done. A `fallbacks` option that reaches the
wire without the cost and evidence consequences followed through would
produce records that are quietly wrong, which is worse than the feature
being absent.


## Interfaces and Dependencies

This plan requires `claude ^>=1.5`, delivered by
`docs/plans/70-upgrade-the-claude-sdk-to-1-5-and-decide-what-a-paused-turn-means.md`.
The types it consumes are `Claude.V1.Messages.StopDetails`, with fields
`category :: Maybe Text` and `explanation :: Maybe Text`, reachable from
the message delta; and, only if Milestone 2 adopts it,
`Claude.V1.Messages.Fallbacks` with constructors `FallbacksDefault` and
`FallbacksModels`, plus the `fallbacks` field on
`Claude.V1.Messages.CreateMessage`. None of these exists in 1.4.0.

At the end of Milestone 1, the assembler state record in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs` carries the
refusal detail from the delta that supplies it to the stop that consumes
it, and — if the recommendation is taken — `Baikai.Error.BaikaiError` has
one new `Maybe Text` field holding the provider's refusal category,
defaulted to `Nothing` in the shared `baseError` helper and set only on
the refusal path.

At the end of Milestone 2, `docs/adr/0005-what-baikai-deliberately-does-not-do.md`
states baikai's position on server-side fallbacks. If that position is to
adopt, then additionally: a baikai-owned option type in `baikai/src/Baikai/`
mirroring the shape of `Baikai.CacheRetention`, a field on
`Baikai.Options.Options` defaulting to `Nothing`, the `fallbacks` field
set in `mapRequest`, the beta header sent from
`baikai-claude/src/Baikai/Provider/Claude/Transport.hs`, and a response
path that reports the model that actually ran rather than the model that
was requested.
