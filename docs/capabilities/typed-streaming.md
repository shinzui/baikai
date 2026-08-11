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
  - kind: guide
    resource: docs/user/streaming.md
    proves: "The event algebra, the event-stability policy, the standard fold patterns, and how to recover partial output from a failed stream."
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
Stream.fold (Fold.foldl' step initial) (streamRequest model ctx opts)
-- or, without importing streamly:
events <- streamRequestListWith registry model ctx opts
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
- Consuming the stream is the consumer's responsibility. Abandoning it mid-flight
  is legal and is reported honestly downstream (evidence records it as `aborted`,
  not `failed`), but the underlying HTTP connection is released only when the
  stream is drained or the bracket exits.
