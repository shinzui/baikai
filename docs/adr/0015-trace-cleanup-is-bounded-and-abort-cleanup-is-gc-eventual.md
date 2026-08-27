---
title: Trace cleanup is bounded, and abort cleanup is garbage-collection-eventual
status: accepted
date: 2026-08-27
---

# Trace cleanup is bounded, and abort cleanup is garbage-collection-eventual

## Context

`Baikai.Trace` bridges a provider call and a `TraceSink`. Each traced
call opens a channel, forks a worker that drains it through the sink's
streamly fold, and cleans up through `Stream.finallyIO`: write the
shutdown sentinel, wait for the worker, report whatever the sink threw.

Two properties of streamly's `finallyIO` shape everything here, and both
were re-verified in the checkout for baikai's `>=0.3 && <0.5` bound
(`Streamly/Internal/Data/Stream/Exception.hs` and `…/IOFinalizer.hs`).

First, `finallyIO` is `bracketIO3` over `gbracket`, which wraps every
stream step in a handler. Cleanup runs **synchronously** when the stream
stops of its own accord, and when an exception — asynchronous ones
included — is thrown at the consumer while it is *inside* a step. But
when the consumer stops pulling *between* steps — `Stream.take`, a fold
that finishes early — no step ever sees `Stop`, and cleanup runs instead
from an `IOFinalizer` attached with `mkWeakIORef`: at some major garbage
collection after the stream state becomes unreachable. Second, that
garbage-collection run happens under `mask_`.

Plan 34 (`docs/plans/34-harden-trace-and-call-log-workers.md`) found the
first consequence: before the hook fires, the worker blocked in
`readChan` on a channel nothing else can reach is reaped with
`BlockedIndefinitelyOnMVar`. Each `TraceState` has been rooted by a
`StablePtr` until finalisation completes ever since. That plan also made
a sink that *throws* harmless to the call it observes.

The 2026-08 review found what a throwing sink's fix did not cover. A sink
that **blocks** was worse than one that throws: `finalizeTrace` waited on
the worker with an unbounded `takeMVar`, on the calling thread at every
terminal and inside the garbage-collection hook's `mask_` on the abort
path — so the call hung forever and the first attempt to cancel it was
swallowed. And nothing anywhere said, to a caller or to a later plan,
that the abort terminal is delivered by the garbage collector rather than
at the moment of abandonment; the fact lived only in plan 34's Decision
Log and masterplan 7's Surprises.

## Decision

**The trace bridge waits for a sink for a bounded time and never
unboundedly.** `finalizeTrace` writes the sentinel and then waits at most
`sinkDrainBoundMicros` — one second, a module constant, not a public
option. On expiry the worker is **abandoned, not killed**: killing it
would abort the sink's fold mid-step and lose its end-of-stream action,
while an abandoned worker finishes when the sink unblocks, or is reaped
with `BlockedIndefinitelyOnMVar`, which its `try` catches and records. A
`TraceSinkStalled` goes into `sinkError` if nothing is there yet, one
line goes to stderr, and the `StablePtr` root is released as on the
normal path.

The claim-through-sentinel region runs under `mask`; only the wait is
`restore`d, so a caller's cancellation reaches the wait and cannot land
between the claim and the sentinel.

**Strict evidence means delivery was confirmed, not merely attempted.** A
`TraceSinkStalled` is an ordinary exception in `sinkError`, so
[0014](0014-strict-evidence-means-a-record-exists.md)'s machinery applies
to it unchanged: a caller under `EvidenceRequired` gets a failed call.
`sinkFailureError` says the record was "not confirmed written" rather
than "not written", which is the honest claim for an abandoned worker
whose events are still queued.

**Abort cleanup is garbage-collection-eventual, and that is documented
rather than fixed.** The synthetic `CallFailed` and its `aborted`
evidence record are delivered at the next major collection after the
abandoned stream becomes unreachable, and are not guaranteed before
process exit. Each active `TraceState` stays rooted by a `StablePtr`
until finalisation completes, so the worker blocked in `readChan` is not
reaped before the hook fires.

**No plan may rely on `finallyIO` for prompt cleanup on early stop.** A
test that asserts an abort's effects forces collection and polls; a
caller who needs the record before exiting drains the stream to its
terminal, where the record is pushed synchronously before the terminal
event reaches them.

## Consequences

The one-second bound is a policy, and a sink whose per-call latency
approaches it is mis-configured for per-call tracing — an OpenTelemetry
exporter belongs behind the non-blocking batch processor, not in the
call's critical path. If the bound ever proves tight the escape hatch is
an `Options` field, `traceDrainTimeoutMs`, not a longer constant; making
it configurable is a surface decision and belongs with the freeze.

The contract every existing caller relies on survives: when `withTrace`
returns, a healthy sink has processed this call's events — the file line
is on disk, the memory sink's `TVar` is populated. Only a pathological
sink turns that into a one-second cost plus a report.

`multiSink` waits for its members unboundedly on purpose. The drain bound
above covers the whole fan-out, so a member that blocks forever costs the
call the bound and no more; a second bound inside the fan-out would only
decide which of two timers fires first. The accepted cost is that while
one member is blocked the aggregate failure is never thrown, so a
*throwing* sibling's message does not reach stderr in that combination —
the stall line names the actionable fact, and the sibling's events were
delivered regardless.

`Baikai.Cost.Log`'s close is deliberately **not** bounded the same way.
Its purpose is durability, it runs once per process rather than once per
call, and its writer is a local file the operator chose rather than a
third-party fold. It was made idempotent instead, which removes the hang
a second caller used to hit.

The garbage-collection caveat was re-checked against
[0010](0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md),
which made a stopping consumer cancel the provider's worker, in case that
had incidentally made the trace finaliser synchronous on the abort path.
It has not. With the forced collection removed from `awaitEvents` and
`awaitSpans`, `earlyAbortTest`, `abortEvidenceTest` and `abortSpanTest`
fail on every one of twenty runs, each timing out after five seconds with
`CallStarted` alone recorded and no span exported. Cancelling the
producer and running the consumer's own finaliser are different things,
and only the first is synchronous. The caveat stands as written; the way
to re-check it after any future change to the abort path is to remove the
forced collection again and see whether the tests still pass, not to
reason about it.
