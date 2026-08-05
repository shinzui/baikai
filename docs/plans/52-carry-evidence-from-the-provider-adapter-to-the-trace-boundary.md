---
id: 52
slug: carry-evidence-from-the-provider-adapter-to-the-trace-boundary
title: "Carry evidence from the provider adapter to the trace boundary"
kind: exec-plan
created_at: 2026-08-05T20:23:57Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Carry evidence from the provider adapter to the trace boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

The plan before this one,
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md), created
a type called `ModelCallEvidence` that can describe one completed provider call in full. Nothing
produces one yet, and — more importantly — there is nowhere for one to *go*. The code that knows
what Baikai actually put on the wire lives inside each provider adapter, and the code that writes
records out to a file or an observability system lives in `baikai/src/Baikai/Trace.hs`, and there
is no channel between them. Today the trace layer builds its events by reading the caller's own
`Model` and `Options` records — which is exactly why it can only report what was *configured*
rather than what was *sent*.

This plan builds that channel and proves it carries exactly one evidence record per call under
every way a call can end.

After this plan, a provider adapter returns the evidence it built as part of the stream's final
event, the trace layer picks it up and hands it to the caller's trace sink as a new kind of trace
event, and a caller can read a complete evidence record out of a JSON-lines trace file. Every
adapter is wired up, but each one supplies only what the core already knows — provider, requested
model, timestamps, latency, status, usage — with every provider-observed field explicitly marked
unobserved. That is not a placeholder; it is a truthful evidence record for a transport that has
not yet learned to observe anything. The three plans after this one teach each transport to
observe more.

**A caller who wants none of this must pay nothing for it, and proving that is part of this
plan.** Evidence is built only when the caller sets the `evidence` field in `Options`. With that
field absent — which is every caller that exists today — no digest is computed, no call identifier
is generated, no evidence event is emitted, and the bytes a trace sink receives are identical to
what the same call produced before this initiative began. This matters because the two digests
each hash the whole request envelope: making them unconditional would impose two SHA-256 passes
over every prompt on people who only ever wanted token counts. "Every adapter is wired up" is a
statement about the code compiling, not about work happening on every call.

Two existing defects get fixed here because they are in the path and would otherwise poison the
evidence. The trace layer currently drops the cached-token and reasoning-token counts that the
cost log keeps, and it suppresses the cost field entirely when the computed cost is zero, so a
reader cannot tell "this call cost nothing" from "the cost is unknown". Both are acceptable
imprecision in a cost dashboard and both are false statements in evidence.

You can see the result working end to end against a fake provider:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai --test-options='--pattern Evidence'
```

and, in an application, by pointing a trace sink at a file and reading one line out of it:

```bash
jq 'select(.kind == "call_evidence") | .evidence.strength' trace.jsonl
```

which prints `"requested_only"` for every call until the provider plans land. (A trace line has
no `data` wrapper and the evidence record's keys are snake_case — see Surprises & Discoveries.)


## Progress

- [x] Add the evidence slot to `TerminalPayload` in `baikai/src/Baikai/Stream/Event.hs` and
      update the two smart constructors. (2026-08-05)
- [x] Add the evidence slot to `Response` in `baikai/src/Baikai/Response.hs` and carry it through
      `reassembleResponse` and `liftCompleteToStream`. (2026-08-05)
- [x] Add the `CallEvidence` case to `TraceEvent` in `baikai/src/Baikai/Trace/Event.hs`.
      (2026-08-05)
- [x] Stop eliding usage and cost fidelity in `CallFinished` and `CallLogEntry`. (2026-08-05)
- [x] Emit the evidence event from `Baikai.Trace`, exactly once per call. (2026-08-05)
- [x] Handle the three non-success terminations: provider error, early consumer termination, and
      no registered provider. (2026-08-05)
- [x] Add the sink-failure policy hook (best-effort today; strict mode is wired in
      [docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md)).
      (2026-08-05)
- [x] Give every adapter a minimal evidence value: both API providers, both CLI completion
      providers, and the no-provider-registered error path. (2026-08-05)
- [x] Gate all evidence construction on the caller's opt-in, inside the shared builder.
      (2026-08-05)
- [ ] Prove the opt-out path is free: byte-identical trace output and no digest computed.
- [x] Propagate the mechanical updates through `baikai-effectful` and `baikai-trace-otel`.
      (2026-08-05)
- [ ] Extend `baikai/test/TraceSpec.hs` with the five termination cases.
- [ ] Add `CHANGELOG.md` entries under the existing `[Unreleased]` heading for every package
      whose surface changed.


## Surprises & Discoveries

### Found in Milestone 1

**`TraceEvent` has a `FromJSON` instance, and the new constructor cannot have one.** The plan
describes `TraceEvent` as an encoded-only sum, but `baikai/src/Baikai/Trace/Event.hs` derived both
`ToJSON` and `FromJSON` generically. `ModelCallEvidence` deliberately has no `FromJSON` — plan 51
established that `Baikai.Cost.Cost`'s exact `Rational` amounts encode through an approximating
`Scientific`, so a decoder would return a different value than was encoded — so
`genericParseJSON` no longer type-checks once `CallEvidence` exists. Nothing in this repository
uses `FromJSON TraceEvent`, but it is on the public surface, so it is now written out by hand:
the three pre-existing cases decode exactly as before, and a `call_evidence` line fails with a
message telling the reader to decode it as a plain `Aeson.Value`. See the Decision Log.

**The cost elision had a third site the plan did not name.**
`Baikai.Cost.Log.runRequestWithLogWith` computes its own `meaningfulCost` and suppresses a zero
`usd`, exactly as the two sites in `Baikai.Trace` did. Fixing only the two named sites would have
left the same `CallLogEntry` type meaning different things depending on which entry point built
it, so all three are fixed together.

**The OpenTelemetry sink's evidence branch cannot attach anything on the normal path.** The plan
anticipated this and chose to have the sink tolerate a missing span rather than reorder the trace
events, and that is what is implemented — but it is worth stating the consequence plainly:
because `Baikai.Trace` pushes `CallEvidence` after the matching `CallFinished` or `CallFailed`,
and the sink ends and removes the span on those events, the attribute-attaching path is reached
only by hand-fed or replayed event streams. Evidence therefore does not reach an observability
backend through this sink today. That is a live gap for
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md), which owns
the migration story for existing trace consumers including this one; the cheapest fix there is to
emit `CallEvidence` before the terminal event, which no consumer can observe as a change because
no consumer has ever seen a `call_evidence` line.


### Found in Milestone 2

**A trace line has no `data` wrapper, and this plan's own `jq` incantations were wrong about
it.** `traceEventOptions` sets `sumEncoding = TaggedObject {tagFieldName = "kind",
contentsFieldName = "data"}`, which reads as though every event nests its fields under `data`.
Aeson only uses `contentsFieldName` for a constructor with *positional* fields; all four
`TraceEvent` constructors have named fields, so aeson merges them into the tagged object and a
line reads `{"kind":"call_evidence","eventId":…,"evidence":{…}}`. This is pre-existing encoding
behaviour, not something this plan changed — but the Purpose and Concrete Steps sections of this
plan both wrote `.data.evidence.…`, and the hand-written `FromJSON` added in Milestone 1
initially read a nested `data` object and so could not have parsed anything this package emits.
Both are corrected. The right filter is `jq 'select(.kind == "call_evidence") | .evidence'`.

**The evidence record's JSON field names are snake_case, not camelCase.** Two encodings meet
inside one line and they disagree on purpose. `Baikai.Trace.Event` keeps field labels as-is
(camelCase, `eventId`) and drops absent fields; `Baikai.Evidence` snake-cases them
(`requested_model`) and renders absent fields as explicit `null`. Plan 51 documents why the second
does that — a reader must be able to tell "baikai recorded nothing here" from "this record
predates the field" — and says not to harmonise them. So the evidence record's keys are
`requested_model`, `observed_model`, `request_commitment`, and the acceptance filters in this plan
that spell them in camelCase read `null`.

**`Baikai.Trace.Sink.renderHuman` needed a branch, and the build did not say so.** It is a total
`\case` over `TraceEvent` and `-Wincomplete-patterns` flags the new constructor — but the warning
only appeared in a `cabal repl` session, not in `cabal build all`, because cabal does not re-emit
warnings for a module it considers up to date. Worth remembering: after widening a sum, a clean
`cabal build` is not evidence that every match was updated.


## Decision Log

- Decision: The `CallEvidence` event's `eventId` is the __trace__ identifier, not the evidence
  record's own `callId`.
  Rationale: This plan's Milestone 2 said to "reuse the identifier from the evidence as the
  event's `eventId` so a reader can join the evidence to its `call_started` line", and those two
  halves contradict each other. The trace layer mints its `eventId` before dispatch, for
  `call_started`; the adapter mints the evidence's `callId` later, from `newCallId`; they are
  different values, so using the latter as the event id would break exactly the join the sentence
  wants. Using the trace identifier means all four event kinds for one call share one `eventId`
  and the join works. The two identifiers are not redundant — they live in different namespaces,
  the trace one correlating lines within a process and the evidence one correlating calls into a
  run for a separate system — and the `CallEvidence` event is what ties them together, carrying
  the trace id at the top level and the call id inside `evidence`. The alternative that would
  collapse them, injecting the trace id into `Options` before dispatch, is rejected two entries
  below for reasons that still hold.
  Date: 2026-08-05

- Decision: On the paths where no provider adapter ran to completion, digest baikai's dispatch
  parameters rather than omitting the digest or fabricating one over `null`.
  Rationale: `ModelCallEvidence.requestCommitment` is `Text`, not `Observed Text`, so a record
  cannot say "no envelope was available" — and widening it is out of bounds, because plan 51 owns
  the type and this initiative forbids a later plan changing a field. Three paths have no wire
  body to digest: no registered handler, a `complete` handler that threw, and a consumer that
  abandoned the stream. `Baikai.Evidence.Build.dispatchEnvelope` gives them `{"model": …,
  "max_tokens": …}`. On the no-handler paths that is not a reduction at all, because nothing was
  ever sent. On the other two it is, and the failure direction is the safe one: a verifier holding
  the prompt recomputes a different value and concludes the record does not describe their
  request, which is a false negative. A digest that appeared to bind a run to an artifact it never
  saw — the dangerous direction — cannot arise. Emitting no evidence instead was rejected because
  it loses the aborted-call record that IR-3's acceptance criterion 4 exists to preserve.
  Date: 2026-08-05

- Decision: Carry the evidence on `TerminalPayload` rather than adding a new
  `AssistantMessageEvent` constructor or a new `ApiProvider` field.
  Rationale: `baikai/src/Baikai/Stream/Event.hs` documents the event algebra as closed and states
  that adding a variant is a breaking change to the public surface; it also warns that consumers
  may pattern-match exhaustively. Adding a field to the terminal payload breaks strictly less: a
  consumer that constructs a `TerminalPayload` through the existing `doneTerminal` and
  `errorTerminal` smart constructors — which the module's own Haddock tells them to prefer — is
  unaffected entirely, whereas a new constructor would break every exhaustive match in every
  downstream application. Adding a field to `ApiProvider` instead was rejected because it would
  change the type of every registered handler and every registration call site, for no gain: the
  evidence is per-call data, not per-handler configuration.
  Date: 2026-08-05

- Decision: Evidence is built only when the caller opted in, and the gate lives inside the shared
  `minimalEvidence` builder rather than at each adapter's call site.
  Rationale: The two digests each hash the full request envelope, so unconditional evidence would
  cost every caller two SHA-256 passes over every prompt, a `/dev/urandom` read for the call
  identifier, and a trace event several times the size of a `call_finished` line — all for a
  feature they did not ask for. Putting the gate inside the builder rather than at the four call
  sites means an adapter cannot forget it and a fifth adapter added later inherits it. Passing the
  request envelope lazily means an opted-out call never even constructs the value it would have
  hashed; every adapter already has the envelope in hand for its own purposes, so no adapter does
  extra work to supply an argument that goes unused.
  Date: 2026-08-05

- Decision: Keep `FromJSON TraceEvent`, written out by hand, and make a `call_evidence` line fail
  to parse with an explanatory message rather than decode into something approximate.
  Rationale: Three options were available once `CallEvidence` broke the generic derivation. Giving
  `ModelCallEvidence` a `FromJSON` was rejected outright: plan 51 established that it cannot
  round-trip, and a decoder that silently returns a different value than was encoded is the exact
  fidelity loss this initiative exists to eliminate. Dropping the instance entirely was rejected
  because it breaks every consumer that reads a trace file back, including for the three cases
  that decode perfectly well. The hand-written instance keeps those three working unchanged and
  refuses the fourth loudly. A consumer who wants evidence back out should read it as an
  `Aeson.Value` and match on `schemaVersion` — which is the better interface anyway, because the
  JSON is the contract other systems pin against, not a Haskell mirror of it.
  Date: 2026-08-05

- Decision: Fix the zero-cost elision in `Baikai.Cost.Log.runRequestWithLogWith` too, not only at
  the two sites this plan names.
  Rationale: `CallLogEntry` is built at three sites, and the plan's Milestone 2 named two of them.
  Leaving the third would mean a `usd` field absent from a cost-log line meant "unknown" when the
  line came from `Baikai.Trace.runRequestWithRegistry` and "unknown or zero" when it came from
  `runRequestWithLogWith`. One record type with two meanings, discriminated by an entry point the
  reader of the file cannot see, is worse than either meaning consistently applied.
  Date: 2026-08-05

- Decision: The provider adapter generates the call identifier, and the trace layer reads it back
  out of the evidence rather than generating its own and pushing it down.
  Rationale: The alternative requires the trace layer to inject a generated identifier into the
  `Options` record before dispatch, which means adding an internal field to a public record for
  plumbing reasons. Reading it back keeps `Options` unchanged and matches the initiative's rule
  that the adapter is the authority on what it did. The trace layer still generates an identifier
  for the paths where no adapter ran at all — an unregistered provider, or an abort before the
  first event.
  Date: 2026-08-05


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. `baikai/`
is the core package holding every provider-neutral type; `baikai-claude/` and `baikai-openai/`
hold the provider implementations; `baikai-effectful/` and `baikai-trace-otel/` are thin bindings
over the core. From the repository root, `cabal build all` compiles everything, `cabal test
baikai` runs the core test suite, and `cabal test all` runs every package's.

The core package is compiled with a strict warning set declared in `baikai/baikai.cabal`'s
`common-options` stanza. Three warnings will affect this plan directly.
`-Wincomplete-record-updates` and `-Wmissing-export-lists` are routine. `-Wpartial-fields` is the
one to plan around: it flags any record field selector defined across more than one constructor
of a sum type, because such a selector is a partial function. `baikai/src/Baikai/Trace/Event.hs`
already opts out with a file-level `{-# OPTIONS_GHC -Wno-partial-fields #-}` precisely because
`TraceEvent` is a three-constructor sum with shared field names; you will be adding a fourth
constructor to that same sum, so the opt-out already covers you.

Record fields in this codebase never carry the record's name as a prefix — a field is `runId`,
not `evidenceRunId` — and `DuplicateRecordFields` is on by default so unrelated records
legitimately share plain names. Field access goes through `generic-lens` overloaded labels
(`payload ^. #responseId`). The language is GHC2024 and every `deriving` clause must name its
strategy explicitly.

### The five files this plan changes in the core, and how they fit together

A provider call in Baikai is a *stream* at the core, even when the caller wants a single answer.
Understanding that shape is the whole prerequisite for this plan.

`baikai/src/Baikai/Stream/Event.hs` defines `AssistantMessageEvent`, the algebra a provider emits.
Every stream begins with exactly one `EventStart`, interleaves per-content-block lifecycle events
(`TextStart`, `TextDelta`, `TextEnd`, and the thinking and tool-call equivalents), and terminates
with exactly one `EventDone` (success) or `EventError` (failure). Both terminal constructors wrap
the same payload type:

```haskell
data TerminalPayload = TerminalPayload
  { reason :: !StopReason,
    message :: !Message,
    responseId :: !(Maybe Text),
    errorInfo :: !(Maybe BaikaiError)
  }
```

and the module provides two smart constructors, `doneTerminal` and `errorTerminal`, whose Haddock
explicitly says to prefer them over the raw constructor "so a new field can never be left
uninitialised at a construction site". That advice is what makes this plan's change cheap.

`baikai/src/Baikai/Provider/Registry.hs` defines `ApiProvider`, the per-API handler record:

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api,
    stream :: !(Model -> Context -> Options -> Stream IO AssistantMessageEvent),
    complete :: !(Model -> Context -> Options -> IO Response)
  }
```

Handlers are registered into a `ProviderRegistry` keyed by the model's `Api` tag, and
`completeRequestWith` looks one up and dispatches. When no handler is registered it synthesises
an error-shaped `Response` through `errorResponse`. This type does **not** change in this plan.

`baikai/src/Baikai/Stream.hs` holds the glue. `streamRequestWith` looks up the handler and returns
its stream, or a one-event error stream when none is registered. `reassembleResponse` is a
streamly `Fold` that consumes the whole event stream and produces a `Response`; it threads a
`ReassemblyState` record that accumulates content blocks and remembers the terminal event it saw
in a `terminal :: Maybe TerminalSeen` field. `liftCompleteToStream` goes the other way, turning a
batch `IO Response` into a synthetic five-event stream — the two subprocess providers use it,
because a CLI has no intra-response streaming.

`baikai/src/Baikai/Trace.hs` is where events become records. Read this file completely before
starting; it is the most intricate part of the change. `withTraceStreamWith` opens a `Chan` of
`Maybe TraceEvent`, forks a worker that drains the channel through the caller's sink fold, pushes
a `CallStarted` event eagerly, and then wraps the provider stream in two layers: a
`Stream.mapM (traceEvent ...)` that watches for the terminal event and pushes the matching
`CallFinished` or `CallFailed`, and a `Stream.finallyIO (finalizeTrace ...)` that guarantees
cleanup. `finalizeTrace` uses two `IORef`s — `closed` and `terminalSent` — so that a consumer who
abandons the stream early still gets a synthetic `CallFailed` recorded, and so that cleanup
running twice is harmless. Sink exceptions are captured into a third `IORef` and reported once on
stderr during cleanup; they never propagate into the provider call.

`baikai/src/Baikai/Trace/Event.hs` defines `TraceEvent`, a three-constructor sum
(`CallStarted`, `CallFinished`, `CallFailed`) encoded as `{"kind":"call_started","data":{...}}`
with snake-cased constructor tags and `omitNothingFields = True`.

### The two fidelity defects this plan fixes

In `baikai/src/Baikai/Trace.hs`, the `CallFinished` event is built with only `inputTokens` and
`outputTokens`, while `runRequestWithRegistry` a few dozen lines below builds a `CallLogEntry`
from the same `Usage` value and keeps `cachedInputTokens` and `reasoningTokens` as well. So the
cost log is strictly more faithful than the trace, which is backwards. Second, both sites compute
a `meaningfulCost` boolean and set `usd = Nothing` whenever the computed cost is zero. Since
`omitNothingFields` is on for trace events, the field then vanishes from the JSON entirely,
making a genuinely free call indistinguishable from a call whose cost Baikai could not compute —
and the subscription-based CLI providers always compute zero, so this is the common case rather
than a corner.

### Terms used in this plan

A **terminal event** is the single `EventDone` or `EventError` that ends a provider stream. A
**sink** is a caller-supplied `Fold IO TraceEvent ()` that consumes trace events; four are built
in (`silent`, `stdoutSink`, `fileSink`, `multiSink`) in `baikai/src/Baikai/Trace/Sink.hs`.
**Early consumer termination** means the application stopped reading the event stream before the
terminal event arrived, for example by taking only the first ten events. An **adapter** is a
provider implementation — one of the four modules named in Milestone 2. **Evidence** is a
`ModelCallEvidence` value from `Baikai.Evidence`.

### What this plan depends on

This plan hard-depends on
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md), which
must be complete first. From it, this plan uses: the `ModelCallEvidence` record and its
`baseEvidence` smart constructor; `Observed` with its `Unobserved` constructor; `EndpointIdentity`;
`TransportKind`; `CallStatus` with its three constructors `CallSucceeded`, `CallFailed`, and
`CallAborted`; `EvidenceStrength` with `EvidenceRequestedOnly` as its lowest constructor;
`EvidenceRequest`, `EvidenceStrictness`, and the `evidence` field plan 51 added to
`Baikai.Options`; `noThinkingRequested`; `newCallId`; and `commitmentDigest` and
`configurationDigest`. If any of those names differ from what you find in the tree, plan 51's file
and the code are authoritative — read them rather than guessing.

### ADR context

This repository has no `docs/adr/` directory and `mori.dhall` declares no ADR bundle, so there is
no local ADR convention to follow and no relevant record to read. Record decisions in this plan's
Decision Log;
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) establishes
`docs/adr/` and promotes the durable ones at the end of the initiative.


## Plan of Work

Four milestones. The first widens the types so evidence has somewhere to live; the second makes
the trace layer emit it and every adapter produce it; the third proves it is emitted exactly once
under every termination; the fourth propagates the surface change to the two dependent packages.

### Milestone 1: widen the channel

At the end of this milestone the types can carry evidence and the whole repository still
compiles, but nothing populates anything yet. There is no observable behavior change; the
acceptance is that `cabal build all` and `cabal test all` are both green with the wider types in
place.

In `baikai/src/Baikai/Stream/Event.hs`, add a field to `TerminalPayload`:

```haskell
    -- | The evidence the provider adapter built for this call, when the
    -- adapter produced any. A provider that has not been taught to
    -- build evidence leaves this 'Nothing'; that is distinct from
    -- evidence whose observed fields are 'Unobserved', which is a
    -- positive statement that the provider reported nothing back.
    evidence :: !(Maybe ModelCallEvidence)
```

Extend `doneTerminal` and `errorTerminal` to take the evidence as their new first argument, and
update their Haddock. Because both are the recommended construction path and both already exist,
this is where the breakage is contained. Find every site that constructs the record directly and
convert it to the smart constructor rather than adding a field there:

```bash
rg 'TerminalPayload \{' --type haskell
```

`AssistantMessageEvent` derives `ToJSON` anyclass, so `ModelCallEvidence` needs a `ToJSON`
instance, which plan 51 provides. Confirm this rather than assuming it.

In `baikai/src/Baikai/Response.hs`, add the same field to `Response`, set it to `Nothing` in
`emptyResponse` and in `errorResponse`, and document that a caller who wants evidence should
prefer reading it from the trace sink, because the `Response` copy is a convenience for
synchronous callers and is absent on paths that never build a full response.

In `baikai/src/Baikai/Stream.hs`, thread the evidence through `reassembleResponse`: add the
evidence to the internal `TerminalSeen` record that `ReassemblyState` already holds, and copy it
into the `Response` in `finalizeState`. Also update `liftCompleteToStream` so the synthetic
terminal event it builds carries the evidence from the `Response` it wrapped — otherwise the two
subprocess providers, which use it, would drop their own evidence on the floor in Milestone 2.

In `baikai/src/Baikai/Trace/Event.hs`, add a fourth constructor. The file already carries
`{-# OPTIONS_GHC -Wno-partial-fields #-}` and its existing constructors share field names, so
follow the file's shape rather than fighting it:

```haskell
  | -- | The complete evidence record for one terminal provider call.
    -- Emitted exactly once per call, immediately after the matching
    -- 'CallFinished' or 'CallFailed', so a consumer that wants only
    -- evidence can filter on this kind alone and a consumer written
    -- before this constructor existed is unaffected.
    CallEvidence
      { eventId :: !Text,
        timestamp :: !UTCTime,
        provider :: !Text,
        model :: !Text,
        evidence :: !ModelCallEvidence
      }
```

The constructor tag modifier already snake-cases, so this encodes as
`{"kind":"call_evidence","data":{...}}`.

While in this file, fix the first fidelity defect: add `cachedInputTokens`, `cacheWriteTokens`,
`reasoningTokens`, and `totalTokens` to `CallFinished`, all `Maybe Natural` so an absent count
stays absent.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build all
```

Expect failures only in the two provider packages and the two binding packages, all of the form
"constructor `TerminalPayload` should have 5 arguments, but has been given 4", or a missing field
in a record construction. Fix each by routing through the smart constructors and passing
`Nothing` for the evidence. Do not populate any evidence yet.

### Milestone 2: emit the evidence

At the end of this milestone a call through `withTrace` writes a `call_evidence` line to a file
sink, and every adapter supplies a minimal but truthful evidence record. This is the milestone
with the first observable behavior; the Concrete Steps section shows exactly how to see it.

Start with the shared builder, because four adapters need the identical thing and four copies
would drift. `Baikai.Evidence` from plan 51 deliberately does not import `Baikai.Model` or
`Baikai.Options`, so put the builder in a new module `Baikai.Evidence.Build`, add it to
`exposed-modules` in `baikai/baikai.cabal`, and re-export it from the umbrella `baikai/src/Baikai.hs`:

```haskell
-- | Build the evidence every transport can produce without observing
-- anything: identity from the caller's 'EvidenceRequest', endpoint from
-- the 'Model', the requested model id, the supplied translation, the
-- timings, the status, and the two request digests. Every observed
-- field is 'Unobserved' and the strength is 'EvidenceRequestedOnly'.
--
-- Returns 'Nothing' when the caller set no 'evidence' field in
-- 'Options'. That is the opt-out path and it must stay genuinely free:
-- no digest is computed, no call identifier is generated, and the
-- @envelope@ argument is never forced. The gate lives here rather than
-- at each adapter's call site so that an adapter cannot forget it and a
-- transport added later inherits it.
--
-- A transport that learns more overwrites the observed fields and
-- raises the strength; it must never overwrite a requested field with
-- an observed one or the reverse.
minimalEvidence ::
  Model ->
  Options ->
  TransportKind ->
  ThinkingTranslation ->
  -- | The request envelope, used for the two digests. API providers
  -- pass the JSON body they are about to send; subprocess providers
  -- pass their argument vector rendered as a JSON array. Deliberately
  -- lazy and deliberately not strict: on the opt-out path this thunk is
  -- discarded unforced, so an adapter may pass an expression that costs
  -- something to evaluate without penalising callers who opted out.
  Aeson.Value ->
  UTCTime ->
  UTCTime ->
  CallStatus ->
  IO (Maybe ModelCallEvidence)
```

Note the two things that make the opt-out free. The result is `Maybe`, and the function returns
`Nothing` immediately when `opts ^. #evidence` is `Nothing` — before touching the envelope, before
calling `newCallId`, before hashing anything. And the envelope parameter carries **no** strictness
annotation, unlike most fields in this codebase, because it must remain a thunk that the opt-out
path drops. Write both facts into the Haddock, because the missing bang looks like an oversight to
anyone who has read the rest of the package and will eventually be "fixed" by someone tidying up.

Every adapter already has its envelope in hand for its own purposes — the API providers must build
the JSON body to send it, the CLI providers must build the argument vector to spawn the process —
so supplying this argument costs an adapter nothing beyond the `Aeson` conversion, which laziness
then skips.

When the caller *did* opt in, read the `EvidenceRequest` from `Options` and use its run identifier,
attempt, and supersedes fields directly. Derive the `EndpointIdentity`'s `endpoint` field from the
model's base URL with the query string and any userinfo component stripped — some gateways carry
an API key in a query parameter, so drop the whole query rather than filtering it. Read the
`baikaiVersion` from the generated `Paths_baikai` module, adding `Paths_baikai` to the cabal
`other-modules` list if it is not already there.

Now the trace layer, in `baikai/src/Baikai/Trace.hs`. In `traceEvent`, after pushing
`CallFinished` or `CallFailed`, push a `CallEvidence` event built from the terminal payload's
evidence **when the payload carries any**. Reuse the identifier from the evidence as the event's
`eventId` so a reader can join the evidence to its `call_started` line.

An absent evidence value means one of two things and the trace layer must not try to tell them
apart: either the caller opted out, or a provider has not been taught to build evidence yet. In
both cases the correct behaviour is identical — push nothing. Do **not** synthesise a record from
what the trace layer knows: on the opt-out path that would reintroduce exactly the cost this gate
exists to remove, and on the not-yet-taught path it would produce a record attributed to a
transport that did not make it. After this milestone no built-in provider reaches the second case.

Also fix the cost elision, here and in `runRequestWithRegistry`: delete the `meaningfulCost`
computation at both sites and always report the computed cost. A zero cost is a fact; hiding it
is not.

Now give each adapter a minimal evidence value by calling `minimalEvidence` and passing the
result into `doneTerminal` or `errorTerminal`. The four sites are
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`,
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`,
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`, and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. Each already builds a request value you can
hand to the digest functions: the Claude API provider builds one through
`Baikai.Provider.Claude.Internal.Request.mapRequest` and then reshapes it in
`Baikai.Provider.Claude.Shape`; the OpenAI API provider builds one through
`Baikai.Provider.OpenAI.Shape`; the Claude CLI provider builds an argument vector in
`claudeCliCommand`; the Codex CLI provider builds one in `codexCliCommand`. For the two
subprocess providers, render the argument vector as a JSON array of strings — and note that both
providers place the prompt in that vector, so the commitment digest legitimately covers the
prompt while the configuration projection must drop it. Verify that with the redaction test from
plan 51 extended to an argv-shaped input.

Pass `noThinkingRequested` for the thinking translation everywhere in this plan; the three
provider plans replace it with a real translation.

Finally, cover the paths where no adapter runs at all. `Baikai.Stream.streamRequestWith`
synthesises a one-event error stream when no handler is registered for the model's `Api` tag, and
`Baikai.Provider.Registry.completeRequestWith` synthesises an error `Response` for the same
reason. Attach evidence to both with `status = CallFailed`: "no provider was registered" is a fact
about the call, and a run record that silently omits it is worse than one that records the
failure. These go through the same gated `minimalEvidence`, so an opted-out caller who names an
unregistered provider still gets exactly today's behaviour.

### Milestone 3: exactly once, under every ending

At the end of this milestone the emission guarantee is proved rather than assumed. This is IR-3's
acceptance criterion 4 and it is the milestone most likely to reveal a real bug.

A call can end five ways. Each needs a case in `baikai/test/TraceSpec.hs`, which already exists
and already contains fixture providers emitting hand-built event streams — copy that pattern
rather than inventing one. Run every one of the five with the caller opted in, since a call that
emits no evidence cannot prove an exactly-once guarantee about evidence.

Then add the sixth case, which is about the opt-out path and is the one that protects every
existing user of this library. Run the same successful call twice against a capturing sink: once
with `emptyOptions` and once with an evidence request. Assert that the opted-out run produces
**zero** `CallEvidence` events, and that its remaining events are byte-identical to what the
pre-plan code produced for the same call — capture that expected byte sequence as a golden fixture
before you change `Baikai.Trace.hs`, so the comparison is against real prior behaviour rather than
against your own idea of it. The two fidelity fixes below deliberately change `call_finished`, so
record the golden fixture *after* those fixes and before the evidence emission, and say so in the
test's comment.

Prove the cost claim too, not just the output claim. Give a fixture provider an envelope argument
that throws when forced — `error "envelope forced on the opt-out path"` — and run an opted-out
call through it. The call must succeed. That single assertion is what stops someone later adding a
strictness annotation to `minimalEvidence`'s envelope parameter and silently reintroducing the
hashing cost for everyone.

A successful stream ends with `EventDone`. Assert the sink received exactly one `CallEvidence`
and that its `status` is `CallSucceeded`.

A failing stream ends with `EventError`. Assert exactly one `CallEvidence` with
`status = CallFailed` and a populated `errorInfo`.

A consumer that stops early never sees a terminal event. `finalizeTrace` currently synthesises a
`CallFailed` for this case with the message "aborted: stream consumer stopped before the terminal
event". Assert that it also synthesises exactly one `CallEvidence`, and that its status is
`CallAborted` rather than `CallFailed` — the distinct status matters, because an abort is the
consumer's doing and reporting it as a provider failure would misattribute it.

A stream where no provider is registered emits a one-event error stream. Assert one
`CallEvidence` with `status = CallFailed`.

A stream that ends normally but whose sink throws must not produce two records and must not fail
the call. Assert that today's behavior is unchanged for a best-effort caller: the call returns a
`Response`, the exception does not propagate, and a message appears on stderr. Add the hook that
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) will
implement, so that plan changes one function rather than restructuring this one:

```haskell
-- | What to do when the trace sink itself fails. Under
-- 'EvidenceBestEffort' this reports once on stderr and continues, which
-- is baikai's long-standing behaviour. Strict callers need the opposite
-- and get it from docs/plans/57.
onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
```

The double-emission hazard is real and specific, so write the test before the code: `traceEvent`
sets the `terminalSent` `IORef` and then calls `finalizeTrace`, and `finalizeTrace` also runs from
`Stream.finallyIO` when the stream is torn down. The existing `closed` `IORef` makes the second
run a no-op. If you push the evidence event from a place that runs before that `closed` check,
you will emit twice, and the test above is what catches it.

### Milestone 4: propagate to the dependent packages

At the end of this milestone `cabal build all` and `cabal test all` are green across all eight
packages.

`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` pattern-matches on `TraceEvent` in a
function called `step`, keyed by `eventId` in a `Map Text Otel.Span`, opening a span on
`CallStarted` and closing it on `CallFinished` or `CallFailed`. Add a branch for `CallEvidence`.
The right behavior is to attach the evidence's salient fields as span attributes on the still-open
span when one exists — the requested model, the observed model when present, the evidence
strength, and the two digests — and to neither open nor close a span. Do not serialise the whole
evidence record into a single attribute: observability backends handle flat attributes far better
than embedded JSON blobs, and the digests are the only content-adjacent values that belong there.
Note the ordering subtlety: `CallEvidence` is pushed *after* `CallFinished`, which is when the
span is closed and removed from the map, so either move the evidence push before the
finished/failed push or have the OTel sink tolerate a missing span by attaching nothing. Prefer
the latter — reordering the trace events would change the existing contract for a reason
unrelated to this plan.

`baikai-effectful/src/Baikai/Effectful.hs` wraps the core transport in an `effectful` effect.
Check whether it re-exports `TerminalPayload` or constructs one; if it only passes streams
through, it needs no change beyond a changelog note.

Update `CHANGELOG.md` under the existing `[Unreleased]` heading. This plan changes the public
surface of `baikai`, `baikai-claude`, `baikai-openai`, and `baikai-trace-otel`, so each needs an
entry naming what changed and what a caller must do about it. Follow the style already in the
file. Do not create a dated release heading — the release is coordinated by
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md).


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm plan 51 is complete and the tree is green before starting:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai --test-options='--pattern Evidence'
```

If the evidence test group does not exist, plan 51 is not done and this plan cannot start.

Read these four files completely before editing anything, in this order:
`baikai/src/Baikai/Stream/Event.hs` (short, defines the algebra),
`baikai/src/Baikai/Trace.hs` (the intricate one),
`baikai/src/Baikai/Trace/Event.hs` (short), and `baikai/test/TraceSpec.hs` (shows the fixture
provider pattern the new tests will reuse).

Find every construction site before you change the shape of anything:

```bash
rg 'TerminalPayload \{' --type haskell
rg 'doneTerminal|errorTerminal' --type haskell
rg 'meaningfulCost' --type haskell
```

Work through the four milestones. Commit after each, with all three trailers:

```text
Carry model-call evidence on the terminal stream event

Add an evidence slot to TerminalPayload and Response, extend the two
terminal smart constructors, and thread the value through
reassembleResponse and liftCompleteToStream. Nothing populates it yet.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

After Milestone 2, prove the end-to-end path by hand rather than only through tests. Start clean
so a stale file cannot make a broken build look correct:

```bash
rm -f /tmp/baikai-evidence.jsonl
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal repl baikai
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import Baikai
ghci> import Baikai.Trace
ghci> import Baikai.Trace.Sink
ghci> import Baikai.Evidence
ghci> sink <- fileSink "/tmp/baikai-evidence.jsonl"
ghci> let m = mkModel (Custom "nothing-registered") "test-model" "https://example.invalid"
ghci> let o = emptyOptions & #evidence .~ Just (evidenceRequest "run-1")
ghci> _ <- withTrace sink m (contextOf [user "hi"]) o
ghci> _ <- withTrace sink m (contextOf [user "hi"]) emptyOptions
ghci> :q
```

That model's `Api` tag has no registered provider, so it exercises the failure path with no
credentials and no network. The first call opts in; the second does not, and must contribute no
evidence line at all. Read the result:

```bash
jq -c 'select(.kind == "call_evidence") | {status: .evidence.status, strength: .evidence.strength, model: .evidence.requested_model, observed: .evidence.observed_model}' /tmp/baikai-evidence.jsonl
```

Expect exactly one line, from the first call only:

```text
{"status":"failed","strength":"requested_only","model":"test-model","observed":"unobserved"}
```

Exactly one line is the point, and it carries two separate proofs. Two lines from the *first* call
means the double-emission hazard described in Milestone 3 is live. A second line from the *second*
call means the opt-out gate is not working, and every existing user of this library is paying for
a feature they did not ask for.

Confirm the opted-out call still traced normally, so that the gate suppressed only the evidence:

```bash
jq -c 'select(.kind == "call_started") | .model' /tmp/baikai-evidence.jsonl
```

Expect two lines. Both calls traced; only one produced evidence.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings, and `cabal test all` passes. `cabal test all`
includes `baikai-smoke`, which exercises live providers when credentials or CLI binaries are
present and skips them otherwise; a skip is not a failure.

A trace file written from a successful call contains exactly one `call_evidence` line whose
`evidence.status` is `succeeded`. A trace file from a failed call contains exactly one, with
`status` `failed` and a non-null `error_info`. A trace file from a call whose consumer abandoned
the stream contains exactly one, with `status` `aborted`.

For every one of those three cases the file also contains exactly one `call_started` line and
exactly one of `call_finished` or `call_failed` — that is, the existing trace contract is
unchanged and the evidence is purely additive.

Every `call_evidence` record produced by this plan has `strength` equal to `requested_only`,
`observed_model` equal to `"unobserved"`, `response_id` equal to `"unobserved"`, and a non-empty
`request_commitment` and `request_configuration` each beginning with `sha256:`. That exact
combination is the proof that the channel works and that nothing was backfilled from the
request.

**A call whose `Options.evidence` is `Nothing` produces no `call_evidence` line at all**, in every
one of the five termination cases, and its remaining trace events match the golden fixture
recorded before the evidence emission was added. This is the acceptance criterion that protects
every existing user of the library, and it is worth stating as a property: after this plan, an
application that does not mention `Baikai.Evidence` anywhere sees the same trace bytes it saw
before, modulo the two deliberate fidelity fixes below.

The opt-out path does no work, not merely no output. A fixture provider whose request envelope
throws when forced runs an opted-out call to completion without raising. If someone later adds a
strictness annotation to `minimalEvidence`'s envelope parameter, this test fails and tells them
why.

The cost-fidelity fix is visible. A `call_finished` line for a call with zero computed cost now
carries a `usd` field with value `0`, where before the field was absent:

```bash
jq -c 'select(.kind == "call_finished") | has("usd")' /tmp/baikai-evidence.jsonl
```

Expect `true`.

The token-fidelity fix is visible. A `call_finished` line for a call whose provider reported cache
and reasoning tokens carries `cachedInputTokens` and `reasoningTokens`. Prove it by giving the
existing `baikai/test/TraceSpec.hs` fixture provider a `Usage` value with those fields populated
and asserting they survive into the event.

The OpenTelemetry sink still works: `cabal test baikai-trace-otel` passes, and a `CallEvidence`
event neither opens nor closes a span — assert this by feeding the sink a hand-built event
sequence and checking the span map is unchanged across the evidence event.


## Idempotence and Recovery

Every step is safe to repeat; `cabal build` and `cabal test` have no side effects. Delete the
manual verification file between runs:

```bash
rm -f /tmp/baikai-evidence.jsonl
```

The risky change is Milestone 1's widening of `TerminalPayload`, because it breaks compilation
across four packages at once. Do it in a single commit that also fixes every call site, so no
commit in history leaves the tree unbuildable. If it goes wrong, `git checkout --
baikai/src/Baikai/Stream/Event.hs` and rebuild; nothing else in this plan depends on the field
existing until Milestone 2.

Milestone 2's change to the emission path in `baikai/src/Baikai/Trace.hs` is the one that can
silently regress the existing trace contract, because the concurrency there — a forked drain
worker, three `IORef`s, and a `finallyIO` cleanup — will not fail loudly if you get the ordering
wrong. Run the existing trace tests after every edit to that file, not only at the end of the
milestone:

```bash
cabal test baikai --test-options='--pattern Trace'
```


## Interfaces and Dependencies

No new package dependencies. This plan uses `Baikai.Evidence` from
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) and
otherwise moves existing values around. The core package gains one new exposed module,
`Baikai.Evidence.Build`, and may need `Paths_baikai` added to its `other-modules` list to read the
package version.

The surface that must exist when this plan is complete:

In `baikai/src/Baikai/Stream/Event.hs`:

```haskell
data TerminalPayload = TerminalPayload
  { reason :: !StopReason,
    message :: !Message,
    responseId :: !(Maybe Text),
    errorInfo :: !(Maybe BaikaiError),
    evidence :: !(Maybe ModelCallEvidence)
  }

doneTerminal ::
  Maybe ModelCallEvidence -> Maybe Text -> StopReason -> Message -> TerminalPayload

errorTerminal ::
  Maybe ModelCallEvidence -> Maybe Text -> StopReason -> Message -> BaikaiError -> TerminalPayload
```

In `baikai/src/Baikai/Response.hs`, `Response` gains `evidence :: !(Maybe ModelCallEvidence)`.

In `baikai/src/Baikai/Trace/Event.hs`, `TraceEvent` gains the `CallEvidence` constructor, and
`CallFinished` gains `cachedInputTokens`, `cacheWriteTokens`, `reasoningTokens`, and
`totalTokens`, each `Maybe Natural`.

In the new `baikai/src/Baikai/Evidence/Build.hs`:

```haskell
minimalEvidence ::
  Model -> Options -> TransportKind -> ThinkingTranslation ->
  Aeson.Value -> UTCTime -> UTCTime -> CallStatus -> IO (Maybe ModelCallEvidence)

onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
```

The `Maybe` in that result is the opt-out gate and is not negotiable: it returns `Nothing` when
`Options.evidence` is `Nothing`, before forcing the envelope argument or generating a call
identifier. The envelope parameter must stay lazy — no bang — for the same reason. Both facts are
enforced by tests described in Milestone 3, so a later tidy-up that adds strictness will fail
rather than silently cost every caller two SHA-256 passes per call.

`ApiProvider` in `baikai/src/Baikai/Provider/Registry.hs` is deliberately **unchanged**. The
evidence travels on the terminal event rather than through a new handler field, so no registered
provider's type changes and no registration call site needs editing. The three provider plans
that follow —
[53](53-emit-anthropic-messages-api-call-evidence.md),
[54](54-emit-openai-compatible-api-call-evidence.md), and
[55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) — consume this surface
unchanged and only replace the values passed into `minimalEvidence` and the observed fields
overwritten afterwards.
