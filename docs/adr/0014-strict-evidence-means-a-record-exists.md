---
title: Strict evidence means a record exists, not merely that the sink did not throw
status: accepted
date: 2026-08-27
---

# Strict evidence means a record exists, not merely that the sink did not throw

## Context

`Options.evidence` can carry an `EvidenceRequest` whose `strictness` is
`EvidenceRequired s`. The promise a caller reads into that is simple:
this call produces an evidence record of at least strength `s`, or it
fails.

Strict mode enforced that promise at two points, and between them was a
hole.

The **pre-dispatch gate** (`checkEvidenceRequirements`) refuses a call
whose transport cannot reach `s`, or whose thinking request would be
downgraded, before anything is sent. It answers "can this transport
produce what you need?".

The **sink-failure rule** (`onSinkFailure`, `sinkFailureIsFatal`,
`sinkFailureError`) fails a call whose record was built and then lost
because a trace sink threw. It answers "did the record you were promised
survive?".

Neither answers "was a record built at all". A `Custom` provider that
attaches nothing to its terminal passed the gate at `requested_only` —
correctly, because `requested_only` is what a provider declaring nothing
can reach — returned a successful `Response`, and wrote zero
`call_evidence` lines. No sink threw, so the sink rule stayed quiet. A
caller who wrote `EvidenceRequired EvidenceRequestedOnly` got a
successful answer, no record, and no error anywhere.

That is the failure mode the sink rule exists to prevent, arriving
through a different door. Evidence that can vanish without the caller
noticing is not evidence.

## Decision

**Under `EvidenceRequired`, a successful terminal that carries no
evidence record is rewritten into a failure** carrying
`Baikai.Evidence.Build.missingEvidenceError`, whose message begins
`this call required evidence, but the provider attached no evidence
record`.

The rule is applied at **both dispatch points** —
`Baikai.Stream.requireEvidenceOnTerminal` inside `streamRequestWith`, and
`Baikai.Provider.Registry.requireEvidenceOnResponse` inside
`completeRequestWith` — rather than inside the trace layer. The built-in
providers' `complete` is `streamingComplete . stream`, which reassembles
the provider's own stream and never passes through `streamRequestWith`,
so one site would have covered only half the callers. Enforcing at
dispatch also means a `completeRequest` caller with no sink at all gets
the same guarantee as a streaming one, and the trace layer then records
`call_failed` with no special case of its own.

**The error path keeps the provider's error.** A terminal that already
failed satisfies the contract — the call failed — and the provider's own
error is the more useful of the two.

**The gate does not refuse a provider whose ceiling is
`requested_only`** when the caller requires exactly that. A custom
provider that builds a minimal record is doing the right thing, and
refusing every such provider would make strict mode unusable with all of
them. The record-less case is caught at the terminal instead, which is
where the fact is actually known.

`missingEvidenceError` is built with `providerError`, category
`OtherError`, for the reason `sinkFailureError` is: nothing about the
request was invalid, the provider did its job, and `ErrorCategory` is a
closed sum whose widening belongs to the surface freeze. The message
prefix is the contract until then, and the two helpers sit side by side
so both can be re-categorised in one edit.

## Consequences

Only a provider knows what its evidence can reach, which is why
`ApiProvider` carries `strengthCeiling` rather than the gate consulting a
tag-keyed table. A provider that attaches no record must declare
`EvidenceRequestedOnly` and will still fail a strict caller at the
terminal; declaring more than the transport delivers is the one way left
to make strict mode lie, so a declaration above `EvidenceRequestedOnly`
needs a test that drives the provider to it.

A call can now fail *after* reaching the provider for a second reason.
Both reasons are baikai's own rather than the provider's, both are
reported through `providerError`, and the failed response keeps the
provider's content, so a caller investigating one can still read what
came back.

A test that means to exercise the sink rule must use a provider that
builds a record; otherwise the record rule fires first and the test
asserts the wrong thing. That is not hypothetical — it happened to
`TraceSpec`'s own sink-failure case the moment this rule landed.

This record extends [0002](0002-requested-translated-observed-are-never-collapsed.md),
which makes each of the three facts separate, with the prior question of
whether any of them was written down at all.
