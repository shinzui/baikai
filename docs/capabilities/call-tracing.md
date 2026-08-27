---
title: "Call tracing through a pluggable TraceSink"
type: Capability
description: "Wrap any call in withTrace and get a CallStarted/CallFinished/CallFailed event stream fed to a TraceSink — a streamly fold, so sinks compose with tee, filter, and lmap — where a throwing or blocking sink cannot hang the call and an abandoned stream still records a terminal."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
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
    proves: "The lifecycle contract end to end: a memory sink records CallStarted then CallFinished on success and CallStarted then CallFailed on a stream error, an early-aborting consumer still gets a synthetic CallFailed, a sink that throws cannot hang withTrace, CallFinished carries the full disjoint token breakdown, a zero cost is reported as zero rather than omitted, and 70000 generated ids are distinct and 32 characters wide. Since 0.6.0.0 it also pins the hardening: blockingSinkTest and blockingSinkStrictTest hold a sink open forever and show the call returning inside the drain bound (failed, under EvidenceRequired), multiSinkThrowingMemberTest and multiSinkBlockingMemberTest show a sibling receiving every event, multiSinkStrictNamesMemberTest shows the failure naming the member by index, and terminalPathAtomicityTest and throwToAroundTerminalTest show one terminal and one evidence record under asynchronous exceptions."
  - kind: module
    resource: baikai/src/Baikai/Trace/Sink.hs
    proves: "The TraceSink newtype over a streamly Fold and the four built-in sinks — silent, stdoutSink, fileSink, multiSink — plus renderHuman."
  - kind: module
    resource: baikai/src/Baikai/Trace.hs
    proves: "The per-call plumbing: eager CallStarted, terminal-matched CallFinished/CallFailed pushed before the terminal reaches the consumer, commitTerminal committing the flag and both pushes as one unit against asynchronous exceptions, and cleanup through Stream.finallyIO that runs once and waits at most sinkDrainBoundMicros for the sink."
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
into the provider call. A sink that *blocks* holds the call for at most one
second, after which the worker is abandoned, the call proceeds, and the stall is
reported on stderr in the same way. Under `EvidenceRequired` either failure
fails the call — a record whose delivery was never confirmed is not one the
caller can account for. `multiSink` isolates its members on separate drain
threads, so a member that throws or blocks cannot stop delivery to the others or
skip their end-of-stream action, and a failure names each failed member by
zero-based index.

A consumer who abandons a stream mid-flight still produces a synthetic
`CallFailed` and an `aborted` evidence record, and never leaks the worker — but
they are **delivered from a garbage-collection hook**, at the next major
collection after the abandoned stream becomes unreachable, not at the moment of
abandonment. A short-lived process that abandons a stream and exits may never
record them.

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
- `Baikai.Trace.newEventId` was removed in baikai 0.6.0.0; use
  `Baikai.Evidence.newCallId`, which it had delegated to since 0.5.0.0.
  Identifiers widened from 16 to 32 characters in 0.5.0.0; anything that pinned
  the old width — a log parser, a fixture, a column type — must widen.
- Adding a `TraceEvent` constructor is a breaking change for consumers whose
  pattern match is exhaustive. 0.5.0.0 added `CallEvidence`.
- **To have the abort record before you exit, drain to the terminal.** Use
  `withTrace`, or `Stream.fold` with a fold that keeps consuming after you have
  what you need, rather than `Stream.take`: on that path the terminal trace event
  and its evidence record are pushed synchronously, before the terminal
  `AssistantMessageEvent` reaches you. Calling `System.Mem.performMajorGC` after
  abandoning a stream is a last resort, not a guarantee.
- **The sink wait is one second and is not configurable.** It is a module
  constant, `sinkDrainBoundMicros`. A sink whose per-call latency approaches a
  second is mis-configured for per-call tracing: an OpenTelemetry exporter
  belongs behind the non-blocking batch processor.
