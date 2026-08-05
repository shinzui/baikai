---
id: 53
slug: emit-anthropic-messages-api-call-evidence
title: "Emit Anthropic Messages API call evidence"
kind: exec-plan
created_at: 2026-08-05T20:23:57Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Emit Anthropic Messages API call evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai can now carry an evidence record from a provider adapter out to a trace sink — that is
what [docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) built.
But the Anthropic Messages API adapter has nothing interesting to put in one. It reports the
model the caller *configured*, and marks everything the provider might have said back as
unobserved, because it never looks.

It could look. Anthropic's streaming response opens with a `message_start` event carrying a
`MessageResponse` record whose `model` field is the model identifier the provider actually ran,
and Baikai already decodes that record — it reads the `id` field out of it for the response
identifier and discards the rest. Anthropic's HTTP response also carries a `request-id` header
that Anthropic's own support tooling uses to look a call up, and Baikai's SSE transport already
has that header in hand, because it reads `Retry-After` from the same list. And Baikai already
computes an exact description of the thinking configuration it is about to send — a record called
`ThinkingPlan` — and then throws it away.

After this plan, an Anthropic call produces evidence that says all of it: the model the provider
reported running, the correlation identifier Anthropic issued, and an exact statement of what the
caller's reasoning-effort preference became on the wire, including every case where it was
weakened. There are three such cases on the Anthropic path and none of them is currently visible
to a caller: asking for thinking on a model that does not advertise reasoning support silently
drops it; asking for a level whose token budget does not fit under the resolved output-token
ceiling silently drops it; and asking for `high` on an adaptive-thinking model sends no effort
field at all, making the request indistinguishable on the wire from taking Anthropic's default
depth.

You can see the result without a network connection or an API key, because the whole thing is
proved against recorded fixtures:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-claude
```

and against a live account, if you have one, through the existing smoke suite.


## Progress

- [ ] Widen the SSE transport callback so response metadata reaches the adapter.
- [ ] Capture the Anthropic correlation header and the HTTP status in the adapter.
- [ ] Read the provider-reported model out of `message_start`.
- [ ] Turn `ThinkingPlan` into a `ThinkingTranslation` and return it from `mapRequest`.
- [ ] Record the three Anthropic thinking-downgrade cases as `ThinkingAdjustment` values.
- [ ] Populate the evidence record and derive the evidence strength from what was observed.
- [ ] Add the response commitment digest.
- [ ] Write the fourteen-case translation table test.
- [ ] Write the header-capture and observed-model fixture tests.
- [ ] Write the end-to-end evidence test for a successful call and a 429.
- [ ] Add a `CHANGELOG.md` entry under the existing `[Unreleased]` heading.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Widen the SSE transport with a separate once-per-response metadata callback rather
  than changing the per-event callback's type.
  Rationale: The per-event callback runs once per SSE event, potentially thousands of times per
  call. Threading response-level metadata through it would mean either re-sending the same values
  on every event or making every event payload a sum type. A second callback invoked exactly once,
  before the first event, matches what the data actually is and leaves the hot path untouched.
  Date: 2026-08-05

- Decision: `EvidenceFullyObserved` is unreachable on the Anthropic transport, and that is
  recorded rather than worked around.
  Rationale: Anthropic's response does not echo the thinking configuration it applied. The
  strength enumeration's top constructor requires an observed thinking configuration, so this
  transport tops out at `EvidenceModelObserved`. Inferring the applied configuration from
  reasoning-token counts would be exactly the substitution IR-3 forbids: token counts corroborate
  output volume, they do not state what effort setting was in force.
  Date: 2026-08-05


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. This plan
changes `baikai-claude/`, the package implementing Anthropic's Messages API and the `claude -p`
subprocess provider, and touches nothing else except its changelog. From the repository root,
`cabal build baikai-claude` compiles it and `cabal test baikai-claude` runs its test suite, which
lives in `baikai-claude/test/` and uses `tasty` with `tasty-hunit`, assembled in
`baikai-claude/test/Main.hs`.

Record fields in this codebase never carry the record's name as a prefix — a field is `effort`,
not `planEffort` — and `DuplicateRecordFields` is on so unrelated records legitimately share
plain names. Field access goes through `generic-lens` overloaded labels (`opts ^. #thinking`).
The language is GHC2024, every `deriving` clause must name its strategy explicitly, and every
module needs an explicit export list.

### The Anthropic provider, file by file

`baikai-claude/src/Baikai/Provider/Claude/Api.hs` is the streaming adapter. It holds a record
called `Assembler` that carries translation state across one streaming call — the model, the start
time, the response id, buffers for each open content block, the accumulated `Usage`, and the stop
reason — and a `translate` function that folds each incoming SDK event into the `Assembler` and
emits zero or more of Baikai's own `AssistantMessageEvent` values. The `Assembler` is where any
new observed value must be accumulated, because it is the only state that survives from the first
event to the terminal one.

`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` maps Baikai's neutral request onto
the SDK's `CreateMessage` value. Two parts matter here. `mapRequest` is the whole mapping and
currently returns `Either Text Messages.CreateMessage`. And `computeThinking`, near the bottom,
translates the caller's `ThinkingLevel` into Anthropic's thinking configuration and returns a
small record:

```haskell
data ThinkingPlan = ThinkingPlan
  { field :: !(Maybe Messages.Thinking),
    effort :: !(Maybe Text),
    budget :: !(Maybe Natural)
  }
```

This is already almost exactly the translation description the evidence needs. It is computed
inside `mapRequest`, used to populate two fields of the outgoing request, and then discarded.

`baikai-claude/src/Baikai/Provider/Claude/Sse.hs` is Baikai's own SSE transport. It does **not**
use the vendor SDK's HTTP path. It builds an `http-client` request by hand and calls
`HTTP.withResponse`, then hands the response to `sseFromResponse`, which checks the status, reads
the body incrementally, splits it into SSE events, decodes each one, and invokes a callback of
type `Either BaikaiError Messages.MessageStreamEvent -> IO ()`. On a non-2xx status it consumes
the whole body, reads the `Retry-After` header out of `HTTP.responseHeaders response`, and
delivers one `Left`. The consequence that matters for this plan: the complete response header list
is already in scope at that exact point, and nothing but `Retry-After` is read from it.

`baikai-claude/src/Baikai/Provider/Claude/Shape.hs` applies host-compatibility reshaping to the
JSON body after the SDK value is encoded, and `baikai-claude/src/Baikai/Provider/Claude/Transport.hs`
builds the outgoing request headers. Neither needs to change, but the shaped JSON body that
`Shape` produces is what the request digests must be computed over, because it is the last version
of the body before it goes on the wire.

### The upstream SDK, and what it already gives you

The Anthropic SDK is the `claude` package from `MercuryTechnologies/claude`, whose source is on
this machine at `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/`. Read
`claude/src/Claude/V1/Messages.hs` if you need detail beyond what follows. Two facts matter:

`MessageStreamEvent` is a sum whose first constructor is
`Message_Start { message :: MessageResponse }`, and `MessageResponse` is:

```haskell
data MessageResponse = MessageResponse
    { id :: Text
    , type_ :: Text
    , role :: Role
    , content :: Vector ContentBlock
    , model :: Text
    , stop_reason :: Maybe StopReason
    , stop_sequence :: Maybe Text
    , usage :: Usage
    , container :: Maybe ContainerInfo
    }
```

So the provider-reported model arrives on the very first event, in the same record Baikai already
reads `id` from. Confirm this against the source on disk before relying on it — the local corpus
can lag upstream, and if the field has moved, Milestone 2 changes shape.

The SDK's thinking configuration type is `Messages.Thinking`, with a `ThinkingEnabled
{ budget_tokens :: Natural }` constructor and a `ThinkingAdaptive` constructor; the adaptive style
additionally carries an effort string in the request's `output_config.effort` field, which
`mapRequest` merges through its `mergeEffort` helper.

### The three ways an Anthropic thinking request is silently weakened

Every one of these is live in the code today and none is visible to a caller. Making them visible
is this plan's central value, so read each site before writing any code.

**The model does not advertise reasoning.** In `computeThinking`, the guard
`| not (m ^. #reasoning) = emptyThinkingPlan` returns an empty plan. The existing Haddock explains
why — sending a thinking configuration to a non-reasoning model is a 400 error from Anthropic
rather than a no-op — and that reasoning is sound. What is missing is any record that it happened.

**The budget does not fit under the output ceiling.** In `mapRequest`:

```haskell
      plan0 = computeThinking compat m (opts ^. #thinking)
      requested = clamp (baseTokens + fromMaybe 0 (budget plan0))
      plan = case budget plan0 of
        Just b
          | requested <= b -> emptyThinkingPlan
        _ -> plan0
```

If the model's `maxOutputTokens` ceiling clamps the sum of the caller's requested output tokens
and the thinking budget down to at or below the budget itself, the entire thinking plan is
discarded. This is the most surprising of the three, because the caller changed a *max-tokens*
setting and silently lost *thinking*, and nothing in the request they can inspect says so.

**Adaptive `high` sends no effort.** In `adaptiveEffort`:

```haskell
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing
  ThinkingXHigh -> Just "xhigh"
  ThinkingMax -> Just "max"
```

`ThinkingHigh` maps to `Nothing`, so the request carries `{"type":"adaptive"}` with no effort
field. That is very likely correct behavior — `high` is presumably Anthropic's own default depth —
but on the wire it is indistinguishable from a caller who expressed no preference at all, and an
evidence record must say which of the two happened. Note also that `ThinkingMinimal` mapping to
`"low"` is a genuine clamp of a different kind: Anthropic's adaptive effort vocabulary has no
`minimal`.

Which of the two thinking styles applies is decided by `AnthropicThinkingStyle` in
`baikai/src/Baikai/Compat.hs`, whose `defaultAnthropicThinkingStyle` function returns
`AnthropicThinkingAdaptive` for a handful of newer model families and `AnthropicThinkingBudget`
otherwise. Both styles must be covered by this plan's tests.

### Terms used in this plan

The **correlation identifier** is a value the provider issues that lets the provider itself locate
this call in its own records; for Anthropic it arrives in a `request-id` response header. The
**observed model** is the model identifier the provider reports having run, as distinct from the
one the caller configured. A **downgrade** is any case where what went on the wire expresses less
than what the caller asked for. A **fixture** is a recorded response body or event sequence stored
under `baikai-claude/test/` and replayed by a test so no network call is needed.

### What this plan depends on

Hard dependencies:
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) for the
vocabulary and
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) for the
channel. From plan 51 this plan uses `ThinkingTranslation`, `ThinkingMode`, `ThinkingAdjustment`,
`Observed`, `EvidenceStrength`, and `commitmentDigest`; from plan 52 it uses `minimalEvidence` and
the evidence slot on `TerminalPayload`.

Soft dependency:
[docs/plans/54](54-emit-openai-compatible-api-call-evidence.md) populates
the same `ThinkingTranslation` record for the OpenAI-compatible hosts. Whichever of the two lands
first sets the practical convention for how a translation spells its `wireField` and its
adjustments; if plan 54 is already complete when you start, read the values it records and match
their style. Neither plan blocks the other, and neither owns the type — plan 51 does.

### ADR context

This repository has no `docs/adr/` directory and `mori.dhall` declares no ADR bundle, so there is
no local ADR convention to follow and no relevant record to read. Record decisions in this plan's
Decision Log;
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) establishes
`docs/adr/` and promotes the durable ones at the end of the initiative.


## Plan of Work

Three milestones, ordered so each is independently verifiable: first the translation description,
which is pure and needs no network; then the observation, which needs the transport widened; then
the assembly of the two into a complete evidence record.

### Milestone 1: the translation description

At the end of this milestone `mapRequest` returns a `ThinkingTranslation` alongside the request it
built, every Anthropic downgrade is recorded in it, and a table-driven test proves all twelve
combinations of six canonical levels by two thinking styles plus the two conditional downgrades.
Nothing observes anything yet and no evidence record changes.

Change `computeThinking` to return a pair — the existing `ThinkingPlan`, which `mapRequest` still
needs for the SDK fields, and a `ThinkingTranslation` describing it:

```haskell
computeThinking ::
  AnthropicMessagesCompat ->
  Model ->
  Maybe ThinkingLevel ->
  (ThinkingPlan, ThinkingTranslation)
```

Fill the translation as follows. When the caller requested nothing, return `noThinkingRequested`
from `Baikai.Evidence`. When the model does not advertise reasoning, return a translation with
`requested = Just lvl`, `mode = ThinkingModeUnsupported`, no effort text, no budget, no wire
field, and `adjustments = [ThinkingDroppedUnsupportedModel lvl]`. When the style is adaptive, set
`mode = ThinkingModeAdaptive`, `wireField = Just "thinking"`, `effortText` to whatever
`adaptiveEffort` produced, and record an adjustment: `EffortOmitted lvl` when `adaptiveEffort`
returned `Nothing`, or `EffortClamped lvl "low"` for `ThinkingMinimal`, which Anthropic's adaptive
vocabulary cannot express. When the style is a token budget, set `mode = ThinkingModeBudget`,
`wireField = Just "thinking"`, `budgetTokens` to the computed budget, and no adjustment, since a
budget expresses the request exactly.

Then change `mapRequest` to return the translation too:

```haskell
mapRequest ::
  Model -> Context -> Options -> Either Text (Messages.CreateMessage, ThinkingTranslation)
```

and, at the site where the budget-versus-ceiling check discards the plan, append
`ThinkingDroppedBudgetExceeded lvl budget ceiling` to the translation's adjustments and set its
`mode` to `ThinkingModeUnsupported` — because after the discard, nothing about thinking is on the
wire at all. Carry the actual computed budget and the actual resolved ceiling into the
constructor rather than leaving the test to recompute them; the whole value of that field is that
it tells an operator which two numbers collided.

`Baikai.Provider.Claude.Internal.Request` already exports `ThinkingPlan` and `computeThinking` for
provider tests, and the module's own header says it is not covered by PVP compatibility
guarantees, so widening them is not a public-API break. Note it in the changelog anyway, because
`baikai-claude`'s own test suite is not necessarily the only consumer that imports it.

The test for this milestone belongs in `baikai-claude/test/ThinkingSpec.hs`, which already exists
and already tests thinking translation. Add a table:

```haskell
translationTable ::
  [(AnthropicThinkingStyle, ThinkingLevel, Maybe Text, Maybe Natural, [ThinkingAdjustment])]
```

with twelve rows — every `ThinkingLevel` against `AnthropicThinkingBudget` and against
`AnthropicThinkingAdaptive` — and assert the produced translation matches each row exactly: exact
effort text, exact budget, exact adjustment list. Write the expected values by reading the code,
then run the test. A row that fails is either a transcription error or a real bug, and you must
determine which before changing either side; record any real bug in this plan's Surprises &
Discoveries.

Add a thirteenth and fourteenth case for the two conditional downgrades: one where the model has
`reasoning = False`, asserting `ThinkingDroppedUnsupportedModel`; and one where the model's
`maxOutputTokens` is small enough to trigger the budget discard, asserting
`ThinkingDroppedBudgetExceeded` carrying the two specific numbers.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-claude --test-options='--pattern Thinking'
```

### Milestone 2: observation

At the end of this milestone the adapter knows the correlation identifier Anthropic issued and the
model Anthropic reported running. Both are visible in a test that replays a recorded event
sequence; neither reaches the evidence record yet.

Start with the transport. In `baikai-claude/src/Baikai/Provider/Claude/Sse.hs`, add a
once-per-response metadata callback to `sseFromResponse` and to the three functions that wrap it.
Define a small record in the same module for what is captured:

```haskell
-- | Response-level metadata captured once, before the first event.
--
-- Header capture is an allow-list: a response header is recorded only
-- if its name appears in 'capturedHeaderNames'. A denylist would leak
-- whatever header a future gateway decides to add.
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }

-- | The response headers worth recording. Anthropic issues
-- @request-id@; gateways in front of it commonly add @x-request-id@
-- and @cf-ray@. None of these can carry a credential: they are values
-- the server chose, not values baikai sent.
capturedHeaderNames :: [CI ByteString]
```

Widen the callback chain to take a `ResponseMetadata -> IO ()`, invoked exactly once, on both the
success and the non-2xx path. A failed call's correlation identifier is if anything more valuable
than a successful one's, since it is precisely what a provider support request needs. Keep the
existing `Retry-After` parsing where it is and do not reroute it through the new record — the
error-classification path in `baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs`
depends on it and this plan should not touch that.

Then in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, add three fields to the `Assembler`
record: `providerRequestId :: !(Observed Text)`, `observedModel :: !(Observed Text)`, and
`httpStatus :: !(Maybe Int)`. Initialise them in `emptyAssembler` to `Unobserved`, `Unobserved`,
and `Nothing`. Populate the first and third from the new metadata callback, and the second in the
`translate` branch that already handles `Message_Start`: that branch already reads `message.id`
for the response identifier, so read `message.model` in the same place and store it as `Observed`.

Be careful with one thing. Store the *provider's* value, never the caller's. The natural Haskell
reflex is to write something that falls back to the configured model when the field is missing,
and that is exactly the error the `Observed` type exists to prevent. The SDK's `model` field is
not optional, so if a `Message_Start` arrives at all you have a genuine observation; if none
arrives — which happens when a stream fails before the first event — the field must stay
`Unobserved`.

The test for this milestone goes in `baikai-claude/test/SseSpec.hs`, which already exists and
already replays recorded SSE byte sequences. Add a case that feeds a response carrying a
`request-id` header and a `message_start` event whose `model` value **differs from** the
configured model, and assert both values are captured and that the observed model is the one from
the event. Making them differ in the fixture is the whole point: if they were equal, a bug that
reads the wrong one would pass.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-claude --test-options='--pattern Sse'
```

### Milestone 3: assemble the evidence

At the end of this milestone an Anthropic call emits a complete evidence record whose strength
reflects what was actually observed.

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, replace the `minimalEvidence` call that
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) added with
one that passes the real `ThinkingTranslation` from Milestone 1, then overwrite the observed
fields from the `Assembler` and set the strength.

That call returns `Maybe ModelCallEvidence` and is `Nothing` when the caller did not opt into
evidence, so the enrichment in this milestone happens inside a `traverse` or an explicit `case`
and never unconditionally. Keep that shape: the two request digests hash the whole prompt body, and
a caller who never asked for evidence must not pay for them. The observations from Milestone 2 are
different and stay unconditional — reading `message.model` and filtering an allow-list of response
headers costs a lookup each, and the response identifier they feed is useful to every caller. The
rule for deciding is whether the work exists solely to serve evidence: the response commitment
digest below does, so gate it; the header capture does not, so do not.

The strength rule is the judgement this milestone encodes, so make it a named function with its
own Haddock rather than an inline conditional:

```haskell
-- | How much this record proves, derived only from what was actually
-- observed. Anthropic does not echo the thinking configuration it
-- applied, so 'EvidenceFullyObserved' is unreachable on this transport;
-- that is a fact about Anthropic's response shape, not a gap to paper
-- over with an inference from reasoning-token counts.
anthropicStrength :: Observed Text -> Observed Text -> EvidenceStrength
anthropicStrength observedModel providerRequestId
```

It returns `EvidenceModelObserved` when both the model and a correlation identifier were observed,
`EvidenceCorrelated` when only the identifier was, and `EvidenceRequestedOnly` otherwise. Do not
let a successful HTTP status raise the strength: a 200 means the request was accepted, not that
any particular model ran.

Add the response commitment digest, computed only when the caller opted in. The terminal
`Message_Stop` leaves the `Assembler` holding the fully assembled response, so compute
`commitmentDigest` over the JSON encoding of the accumulated content blocks, stop reason, and
usage, and store it in the evidence's `responseCommitment` as `Observed`. On a stream that failed
before any response arrived, leave it `Unobserved`; an empty-string digest there would be a
fabrication. Because this hashes the model's entire output it is the single most expensive thing
this plan adds, so compute it inside the branch that already established the caller wants
evidence — never before it.

Also populate the `EndpointIdentity`'s `implementationVersion` with the `baikai-claude` package
version, read from the generated `Paths_baikai_claude` module. Add `Paths_baikai_claude` to the
library stanza's `other-modules` in `baikai-claude/baikai-claude.cabal` if it is not already
there.

The test for this milestone is an end-to-end one in a new `baikai-claude/test/EvidenceSpec.hs`,
wired into `baikai-claude/test/Main.hs`. Replay a recorded successful call through the adapter,
collect the trace events with a capturing sink, and assert the single `CallEvidence` record has a
`requestedModel` equal to the configured model; an `observedModel` of `Observed` carrying the
fixture's different value; a `providerRequestId` of `Observed`; a `strength` of
`EvidenceModelObserved`; a `thinking.mode` matching the fixture's style; and non-empty
`requestCommitment`, `requestConfiguration`, and `responseCommitment` values each beginning with
`sha256:`. Add a second case replaying a recorded 429 response, asserting the evidence has
`status = CallFailed`, a populated `errorInfo`, an `Observed` `providerRequestId` — the header is
present on errors too — and an `Unobserved` `observedModel` and `responseCommitment`.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm the two prerequisite plans are complete and the tree is green:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai --test-options='--pattern Evidence'
cabal test baikai-claude
```

Read these files completely before editing, in this order:
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` (the translation),
`baikai-claude/src/Baikai/Provider/Claude/Sse.hs` (the transport),
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` (the assembler), and
`baikai-claude/test/ThinkingSpec.hs` together with `baikai-claude/test/SseSpec.hs` (the test
patterns you will extend).

Confirm the SDK still has the field this plan depends on, rather than trusting this document:

```bash
rg -n 'data MessageResponse' -A 12 \
  /Users/shinzui/Keikaku/hub/haskell/claude-project/claude/src/Claude/V1/Messages.hs
```

Expect a record containing `model :: Text`. If it does not, stop and record the discrepancy in
Surprises & Discoveries before proceeding — Milestone 2 depends on it.

Work through the three milestones, committing after each with all three trailers:

```text
Describe the Anthropic thinking translation instead of discarding it

Return a ThinkingTranslation from mapRequest alongside the request, and
record the three cases where an Anthropic request silently expresses
less than the caller asked for.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/53-emit-anthropic-messages-api-call-evidence.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

After Milestone 3, inspect a real evidence record by eye. The fixture path needs no credentials
and is the authority:

```bash
cabal test baikai-claude --test-options='--pattern Evidence'
```

If an Anthropic API key is present in the environment the smoke suite expects, the live path is a
useful additional check, though it spends real money:

```bash
cabal test baikai-smoke
```


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and `cabal test all` passes.

The translation table test covers all twelve level-by-style combinations plus the two conditional
downgrade cases, and every row asserts the exact effort text, exact budget, and exact adjustment
list rather than merely that some translation was produced. This is IR-3's acceptance criterion 2
for the Anthropic transport.

A replayed successful call produces exactly one `CallEvidence` record in which `observedModel` is
`Observed` carrying a value *different from* `requestedModel`, which proves the value came from
the provider's event and not from the caller's configuration. This is IR-3's acceptance
criterion 3.

A replayed 429 produces exactly one `CallEvidence` record with `status = CallFailed`, a populated
`errorInfo`, an `Observed` `providerRequestId`, and an `Unobserved` `observedModel`. Absent
metadata stays absent.

Asking for thinking on a model with `reasoning = False` produces a translation whose `adjustments`
contains `ThinkingDroppedUnsupportedModel` and whose `mode` is `ThinkingModeUnsupported`. Asking
for a budget-style level under an output ceiling too small to fit it produces
`ThinkingDroppedBudgetExceeded` carrying the two colliding numbers. Asking for `ThinkingHigh` on
an adaptive-style model produces `EffortOmitted`. Before this plan, none of these three was
visible anywhere in Baikai's output.

Nothing regressed: the existing `baikai-claude` test suite passes unchanged except for the
assertions this plan deliberately extends, and any change to an existing assertion is recorded in
the Decision Log with its reason.


## Idempotence and Recovery

Every step is safe to repeat; `cabal build` and `cabal test` have no side effects and no test
writes a fixture.

Two changes carry real risk. Widening the SSE callback in
`baikai-claude/src/Baikai/Provider/Claude/Sse.hs` touches the code path every Anthropic call goes
through, including the error-classification path that
`baikai-claude/src/Baikai/Provider/Claude/Internal/ErrorClass.hs` depends on. Run the error tests
after every edit to that file, not just at the end of the milestone:

```bash
cabal test baikai-claude --test-options='--pattern Error'
```

If it goes wrong, `git checkout -- baikai-claude/src/Baikai/Provider/Claude/Sse.hs` restores the
previous transport and only Milestone 2 is lost.

Changing `mapRequest`'s return type touches the request path for every Anthropic call. The
compiler finds every call site, so the risk is not silent breakage but scope creep — resist the
urge to restructure `mapRequest` while you are in there. If the change starts growing, that is a
signal to stop and record why in the Decision Log.

The live smoke suite spends real money when credentials are present. It is optional for this plan;
the fixture tests are the authority. Run it once at the end if at all.


## Interfaces and Dependencies

No new package dependencies. This plan uses `Baikai.Evidence` and `Baikai.Evidence.Build` from the
core, plus the `claude` SDK, `http-client`, and `case-insensitive` dependencies `baikai-claude`
already declares.

The surface that must exist when this plan is complete:

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`:

```haskell
mapRequest ::
  Model -> Context -> Options -> Either Text (Messages.CreateMessage, ThinkingTranslation)

computeThinking ::
  AnthropicMessagesCompat -> Model -> Maybe ThinkingLevel -> (ThinkingPlan, ThinkingTranslation)
```

In `baikai-claude/src/Baikai/Provider/Claude/Sse.hs`:

```haskell
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }

capturedHeaderNames :: [CI ByteString]

sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
```

with `claudeSseStream`, `claudeSseStreamValue`, and `claudeSseStreamValueWithHeaders` widened to
match.

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, the internal `Assembler` gains
`providerRequestId :: !(Observed Text)`, `observedModel :: !(Observed Text)`, and
`httpStatus :: !(Maybe Int)`, and the module gains:

```haskell
anthropicStrength :: Observed Text -> Observed Text -> EvidenceStrength
```

`baikai-claude/baikai-claude.cabal` gains `Paths_baikai_claude` in the library's `other-modules`
and an `EvidenceSpec` module in the test suite's `other-modules`.

The `ThinkingTranslation`, `ThinkingMode`, and `ThinkingAdjustment` types are owned by
`Baikai.Evidence` in the core package and must not be extended here. If the Anthropic transport
turns out to need an adjustment case that does not exist, that is a change to
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) and to
the MasterPlan's Integration Points section, and both must be updated before the code is written.
