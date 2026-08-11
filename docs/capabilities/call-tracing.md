---
title: "Call tracing through a pluggable TraceSink"
type: Capability
description: "Wrap any call in withTrace and get a CallStarted/CallFinished/CallFailed event stream fed to a TraceSink — a streamly fold, so sinks compose with tee, filter, and lmap — where a throwing sink cannot hang the call and an abandoned stream still records a terminal."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-9
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai.Trace
  - Baikai.Trace.Event
  - Baikai.Trace.Sink
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/TraceSpec.hs
    proves: "The lifecycle contract end to end: a memory sink records CallStarted then CallFinished on success and CallStarted then CallFailed on a stream error, an early-aborting consumer still gets a synthetic CallFailed, a sink that throws cannot hang withTrace, CallFinished carries the full disjoint token breakdown, a zero cost is reported as zero rather than omitted, and 70000 generated ids are distinct and 32 characters wide."
  - kind: module
    resource: baikai/src/Baikai/Trace/Sink.hs
    proves: "The TraceSink newtype over a streamly Fold and the four built-in sinks — silent, stdoutSink, fileSink, multiSink — plus renderHuman."
  - kind: module
    resource: baikai/src/Baikai/Trace.hs
    proves: "The per-call plumbing: eager CallStarted, terminal-matched CallFinished/CallFailed pushed before the terminal reaches the consumer, and idempotent cleanup through Stream.finallyIO."
---

# Call tracing through a pluggable TraceSink

`withTrace sink model ctx opts` runs a call and feeds a `TraceSink` a small
event stream: `CallStarted` eagerly, then exactly one `CallFinished` or
`CallFailed` carrying latency, the disjoint token breakdown, and the computed
cost. `withTraceStream` is the streaming form and pushes the terminal trace event
*before* yielding the terminal `AssistantMessageEvent`, so a sink sees the
outcome no later than the consumer does.

A `TraceSink` is a newtype over a streamly `Fold IO TraceEvent ()`. That shape is
the point: `Fold.tee` fans one call's events to two sinks, `Fold.filter` drops
events by predicate, and `Fold.lmap` projects before feeding an inner fold — so
redaction, sampling, and fan-out are composition rather than adapters. Four sinks
ship: `silent`, `stdoutSink`, `fileSink`, and `multiSink`.

Tracing is built so it cannot damage the call it observes. Sink exceptions are
caught by the worker thread and reported once on stderr; they never propagate
into the provider call. A consumer who abandons a stream mid-flight still
produces a synthetic `CallFailed` and never leaks the worker.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
resp <- withTrace (fileSink "/tmp/baikai-trace.jsonl") model ctx opts
```

## Limits

- **Tracing is opt-in per call site.** `completeRequest` emits nothing; you get
  events only by going through `withTrace` / `withTraceStream` or the
  `runRequestWith` helpers. There is no ambient instrumentation.
- A `TraceEvent` renders its fields alongside the `kind` discriminator and drops
  absent fields to stay small. The embedded evidence record uses a different
  encoding — snake_case, explicit `null` — on purpose; the two are not
  interchangeable.
- `FromJSON TraceEvent` decodes the three original kinds only. A `call_evidence`
  line fails to parse with a message telling you to read it as a plain
  `Data.Aeson.Value`, because `ModelCallEvidence` deliberately has no `FromJSON`.
- `Baikai.Trace.newEventId` still exists but is deprecated in favour of
  `Baikai.Evidence.newCallId`. Identifiers widened from 16 to 32 characters in
  0.5.0.0; anything that pinned the old width — a log parser, a fixture, a column
  type — must widen.
- Adding a `TraceEvent` constructor is a breaking change for consumers whose
  pattern match is exhaustive. 0.5.0.0 added `CallEvidence`.
