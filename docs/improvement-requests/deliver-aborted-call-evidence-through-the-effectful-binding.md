---
type: Improvement Request
title: Deliver aborted-call evidence through the effectful binding
description: >-
  Expose Baikai's traced stream path through baikai-effectful so an effectful retry owner can
  collect a stream and still receive the aborted evidence record when the collection is cancelled.
timestamp: "2026-11-03T14:51:52Z"
generated:
  by: agent:anthropic/claude-opus-5-5
  at: "2026-11-03T04:20:02Z"
requestId: IR-13
status: completed
origin: mori://shinzui/shikumi
---

# Improvement Request: Deliver Aborted-Call Evidence Through the Effectful Binding

## Status

Delivered on 2026-11-03 by
[plan 102](../plans/102-deliver-aborted-call-evidence-through-the-effectful-binding.md),
published as [baikai 0.10.1.0](https://hackage.haskell.org/package/baikai-0.10.1.0)
and [baikai-effectful 0.5.0.0](https://hackage.haskell.org/package/baikai-effectful-0.5.0.0).
Both annotated package tags identify commit `cdb79e5805613ab60074bb2c9279d779af610c05`.

The public `streamCollectTraced` operation delegates to core's fold-owning
collector. Healthy cancellation delivers Baikai's abort evidence before the
original exception reaches the caller, including between stream steps. A
committed terminal keeps its evidence; blocked and throwing sinks preserve
cancellation and bounded cleanup. [CAP-32](../capabilities/traced-effectful-collection.md)
and [ADR-15](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md)
describe acknowledgement and unconfirmed delivery.

The complete offline gate passed all 12 suites. Outside the workspace, the core
archive passed 847 tests and the binding archive passed 16 against released core.
Hackage downloads match those tested archives byte for byte, both packages have
published Haddock, and a separate consumer compiled the public operation with
both exact package versions resolved from Hackage.

This completes only the Baikai-owned part of
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-3`. Downstream adoption
remains separate under
`mori://shinzui/shikumi/plans/68-support-streamed-judgment-programs-with-typed-result-parity`;
this completion does not close or change Shikumi's request or dependency bounds.
The remaining sections preserve the original request baseline.



## Context

Shikumi owns retries, and it is written against the `Baikai` effect in `baikai-effectful` rather
than against Baikai's `IO` functions. Its `Stream` operation calls `streamCollect`, whose
interpreter is `Stream.toList (streamRequestWith reg m c o)`.

That path has no abort record. When a collection is cancelled, the exception leaves
`Stream.toList` and no `ModelCallEvidence` exists for the attempt. Baikai does build the correct
record, with status `CallAborted`, but only in `finalizeTrace` in
[Baikai.Trace](../../baikai/src/Baikai/Trace.hs), which `baikai-effectful` does not reach.

Shikumi cannot close this gap by itself:

- Building the record in Shikumi would reconstruct endpoint, translation, and commitment fields
  that belong to Baikai. IR-3 forbids this, and Shikumi's ADR-13 prohibits fabricated cancellation
  terminals.
- Calling `withTraceStreamWith` directly from Shikumi's interpreter would bypass the effect that
  its transport is deliberately written against.

The underlying behavior already works. `baikai-openai/test/ResponsesEvidenceSpec.hs` cancels
`Stream.toList (withTraceStreamWith ...)` with `timeout` while the provider is blocked, and it
observes exactly one `CallAborted` record and a released worker.

[ADR-15](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) defines the
limits this request must work within. Cleanup runs synchronously when an exception reaches the
consumer inside a stream step, but runs from a garbage-collection hook when the consumer stops
between steps. The wait for a sink is bounded at one second, after which the worker is abandoned.


## Requested Change

Add an operation to `baikai-effectful` that collects a stream through the traced path with a
caller-supplied `TraceSink`, for example:

```haskell
StreamCollectTraced ::
  TraceSink -> Model -> Context -> Options -> Baikai m [AssistantMessageEvent]

streamCollectTraced ::
  (Baikai :> es) =>
  TraceSink -> Model -> Context -> Options -> Eff es [AssistantMessageEvent]
```

The name and exact shape are Baikai's to decide, provided the semantics below hold. `streamCollect`
keeps its current type and behavior, and callers that do not use the new operation pay nothing for
it.

Adding a constructor to the exported `Baikai` effect is a PVP major change for `baikai-effectful`,
because a third-party interpreter's match becomes incomplete. Release it as a coherent cohort so
that Shikumi can raise its `baikai-effectful >=0.4.0.5 && <0.5` bound without a source override.


## Semantics

1. **One record per call.** A traced collection delivers exactly one `CallEvidence` event to the
   sink for each way the call can end: success, provider failure, strict pre-dispatch refusal, and
   abort. On success and failure, the record equals the one on the terminal event, with the same
   `callId`, so a caller can tell they are one record and not two.
2. **Prompt delivery on cancellation.** The collecting loop owns its consumer and does no work
   between steps, so the record should reach the sink before the cancellation exception leaves the
   operation. ADR-15's between-steps window must be either closed for this operation or documented
   precisely. If it stays open, a caller must be able to distinguish "no record yet" from "no record
   will arrive", because Shikumi otherwise cannot honor its exactly-once requirement.
3. **Cancellation is not converted.** The asynchronous exception propagates unchanged. The
   operation never returns a synthetic terminal in its place, and it does not retry.
4. **Bounded cleanup.** A sink that blocks costs the caller at most the existing one-second bound
   and cannot make cancellation hang. A sink failure on the abort path cannot change the outcome,
   because the call is already ending. Document how a caller observes that the record was not
   confirmed delivered.
5. **Evidence opt-out.** A call with no evidence request delivers no `CallEvidence` event, as on the
   existing traced path.


## Required Tests

Add hermetic tests through the public `baikai-effectful` interpreters, using the stub provider in
`baikai-effectful/test/StubProvider.hs`:

1. Success and terminal failure each deliver one record, equal to the record on the terminal event.
2. Strict pre-dispatch refusal delivers one record and does not invoke the provider.
3. Cancelling a collection blocked inside the provider delivers one `CallAborted` record, releases
   the worker, and rethrows the original exception. A barrier establishes that the provider was
   entered, rather than a timing guess.
4. The record is present in the sink when the exception reaches the caller, or the documented
   alternative from semantic 2 is exercised.
5. A blocked sink and a throwing sink each leave cancellation bounded.
6. A call with no evidence request delivers no record, and `streamCollect` is unchanged.


## Acceptance

An effectful caller can run `runBaikaiWith`, collect a stream with a sink, cancel it, and hold the
exact `CallAborted` record Baikai built, without importing `Baikai.Trace`'s stream functions or
writing a registry wrapper. The operation, its cancellation semantics, and any remaining ADR-15
limit are documented in the Haddock and the capability docs, and they ship in a tagged Hackage
release of `mori://shinzui/baikai/packages/baikai-effectful`.

Shikumi's consumption is separate work. There, a cancelled attempt would deliver its record to the
evidence observer while the exception unwinds, under a mask and within a bound.


## Non-goals

This request does not add retries, budgets, or persistence to Baikai, and it does not change
`streamCollect` or `streamEach`.

It does not cover a cancelled blocking `complete`. IR-3 lists abort only under streaming, while
`mori://shinzui/kioku/plans/16-add-distillation-replay-metadata`, the plan that IR-3 serves, calls
only blocking operations through Shikumi today and describes abort for both. If that consumer needs
blocking abort evidence, request it separately, because a traced blocking call reaches the
provider's stream handler rather than its complete handler.
