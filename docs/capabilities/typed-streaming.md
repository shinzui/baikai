---
title: "Typed incremental streaming"
type: Capability
description: "Fold a provider's response as a stream of typed AssistantMessageEvent values — start, text and thinking deltas, tool-call assembly, and exactly one terminal — so a consumer renders tokens as they arrive and still recovers structured partial output when a stream fails midway."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai.Stream
  - Baikai.Stream.Event
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/StreamSpec.hs
    proves: "The event algebra's load-bearing invariants: an error-only stream still begins with EventStart, terminal message content is authoritative over accumulated deltas, thinking signatures and redaction survive lift and reassembly, dangling buffers keep contentIndex order, responseId flows from events into the Response, and async exceptions pass through liftCompleteToStream rather than being swallowed."
  - kind: test
    resource: baikai-claude/test/LifecycleSpec.hs
    proves: "The three cleanup strengths of a stopped consumer: a consumer that stops after three events stops the body reader within the queue bound, an abandoned stream releases its connection after a major GC, cancelling the consumer releases it without one, and a worker that dies by asynchronous exception still ends the stream in an EventError."
  - kind: guide
    resource: docs/user/streaming.md
    proves: "The event algebra, the event-stability policy, the standard fold patterns, how to recover partial output from a failed stream, and what stopping early does to the connection."
  - kind: module
    resource: baikai/src/Baikai/Stream/Event.hs
    proves: "The AssistantMessageEvent constructors and the doneTerminal / errorTerminal smart constructors every provider terminates through."
---

# Typed incremental streaming

`streamRequest` returns a [`streamly`](https://hackage.haskell.org/package/streamly)
stream of `AssistantMessageEvent` instead of a single `Response`: `EventStart`,
`TextStart` / `TextDelta` / `TextEnd`, the thinking and tool-call equivalents,
and exactly one `EventDone` or `EventError` at the end. Every provider — API or
subprocess — terminates the same way, so a fold written once works against all
of them.

The terminal is not merely a marker. It carries the authoritative assembled
message, so a consumer that accumulated deltas for display can discard its own
accumulation and take the provider's. A stream that fails partway still emits a
terminal, and that terminal carries whatever content did arrive plus the
structured `BaikaiError`, which is how partial output is recovered.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md): streaming resolves its handler through the
same registry and the same `Api` tag.

## Shape

```haskell
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

total <- Stream.fold (Fold.foldl' step initial) (streamRequest model ctx opts)
-- or, without importing streamly:
events <- streamRequestListWith registry model ctx opts
print (total, length events)
```

`streamRequestEachWith` and `streamRequestListWith` expose the same stream to
callers who would rather not depend on `streamly` directly.

## Limits

- Only the two HTTP API transports stream incrementally. The subprocess CLI
  providers produce a *synthetic* one-shot stream: start, one text block, done,
  all emitted after the subprocess has already finished. The types are identical,
  the latency behaviour is not.
- Exactly one terminal is guaranteed; the number and granularity of the deltas
  before it are not, and depend on how the host chunks its SSE frames.
- `latencyMs` is clamped at zero rather than reported negative if a clock moves
  backwards.
- Consuming the stream is the consumer's responsibility, and stopping early has
  three different strengths. Abandoning the stream mid-flight is legal: the
  worker stops reading the socket within a bounded number of further frames, and
  the connection is released at the next major garbage collection. Cancelling the
  draining thread — `Ctrl-C`, `timeout`, `cancel` — releases it immediately, as
  does draining the stream to its terminal. Callers who need the connection back
  at a known moment take one of the latter two.
  [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md)
  says why they differ.
