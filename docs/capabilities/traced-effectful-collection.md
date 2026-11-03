---
title: "Traced effectful collection with abort acknowledgement"
type: Capability
description: "Collect streamed events through Baikai.Effectful and confirm Baikai-owned abort evidence in the caller's exception handler when the sink completes within the bounded cleanup window."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-11-03T14:20:00Z"
capabilityId: CAP-32
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.5.0.0"
timestamp: "2026-11-03T14:20:00Z"
reviews:
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-11-03T14:20:00Z"
    document_timestamp: "2026-11-03T14:20:00Z"
    context: "Implementation self-check against the hermetic cancellation matrix and compiled public API shape; publication is pending."
packages: [baikai-effectful, baikai]
interface: [Baikai.Effectful, Baikai.Trace]
requires:
  - CAP-20
  - CAP-9
  - CAP-19
evidence:
  - kind: test
    resource: baikai-effectful/test/TracedStreamSpec.hs
    proves: "Success and provider failure preserve terminal evidence identity; strict refusal precedes dispatch; opt-out emits no evidence; healthy cancellation acknowledges abort before the caller handles its original exception; blocked and throwing sinks bound cleanup without replacing cancellation."
  - kind: test
    resource: baikai/test/TraceSpec.hs
    proves: "The public fold primitive finalizes before propagation during provider execution and during consumer fold steps, preserves list events, and retains terminal atomicity and existing strict-success sink-failure behavior."
  - kind: module
    resource: baikai-smoke/doc-shapes/Shape/Cap32.hs
    proves: "The documented program imports the public effectful operation and TraceSink vocabulary without stream functions or a registry wrapper."
---

# Traced effectful collection with abort acknowledgement

`streamCollectTraced sink model ctx opts` collects the full event sequence through
[CAP-20 — the effectful binding](effectful-binding.md), adding
[CAP-9 — call tracing](call-tracing.md) and
[CAP-19 — model-call evidence](model-call-evidence.md). Both `runBaikaiWith` and
`runBaikai` delegate to the core collector; the binding never reconstructs
provider facts. `TraceSink` is re-exported for convenient signatures.

## Shape

```haskell
import Baikai.Effectful
import Effectful (Eff, (:>))

program :: (Baikai :> es) => TraceSink -> Eff es [AssistantMessageEvent]
program sink = streamCollectTraced sink model ctx opts
```

## Contract

Opt in with `Options.evidence`. On success or provider terminal failure, the sink
receives one `CallEvidence` equal to the terminal's record, including `callId`.
Strict pre-dispatch refusal emits failed evidence without invoking the provider.
Opt-out emits no evidence. A provider that omits successful evidence still fails
core's strict missing-record check; the collector does not invent its record.

On cancellation, a healthy sink receives Baikai's `CallAborted` record and
completes its fold before the original exception reaches the caller's handler.
The core `withTraceFold` owns the complete fold lifetime, including consumer
steps between stream steps. `withTraceList`, `withTrace`, and their `With`
variants inherit it. Cancellation after a committed terminal preserves that
terminal and adds no abort.

Use a short, nonblocking sink that stores the complete `ModelCallEvidence` in a
caller-owned cell before acknowledging it. Read the cell immediately in the
exception handler, as the hermetic cancellation tests do. With a healthy sink
the record is already present.

## Limits

Cleanup waits at most one second in total. A blocked or throwing sink reports on
stderr and cancellation still unwinds unchanged, even in strict mode. Absence
from the acknowledgement cell means delivery was unconfirmed. An abandoned
worker may deliver later. Exactly-once means Baikai submits one evidence event,
not guaranteed durable external delivery through a failing sink.

General `withTraceStream` abandonment between stream steps remains dependent on
garbage collection. The existing `streamCollect` and `streamEach` operations
retain their behavior. Blocking completion aborts, retries, synthetic streaming
cancellation terminals, and application policy are outside this operation.
