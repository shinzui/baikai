---
title: "OpenTelemetry span export"
type: Capability
description: "Wire otelSink into withTrace and every provider call becomes one OpenTelemetry span carrying GenAI semantic-convention attributes plus baikai's own cost, latency, and evidence attributes, exported through whatever OTel pipeline the consumer already operates."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-10
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai-trace-otel
interface:
  - Baikai.Trace.Sink.OpenTelemetry
requires:
  - CAP-9
evidence:
  - kind: test
    resource: baikai-trace-otel/test/Main.hs
    proves: "Against an in-memory exporter: the success path emits exactly one Ok span with the expected attribute set and no gen_ai.response.model when the provider reported no model, a served model reaches the span under gen_ai.response.model while the requested id stays under gen_ai.request.model, the failure path emits one Error span carrying the error message, an early abort still closes the span with Error status, a real call's evidence reaches its span as flat attributes, and a CallEvidence event neither opens nor closes a span."
  - kind: module
    resource: baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs
    proves: "The otelSink adapter and the attribute mapping from TraceEvent onto GenAI semantic conventions."
---

# OpenTelemetry span export

`baikai-trace-otel` is one module holding one adapter: `otelSink`, a `TraceSink`
that turns baikai's call lifecycle into OpenTelemetry spans. A `CallStarted`
opens a span; the matching `CallFinished` or `CallFailed` sets its status and
ends it. Attributes follow the GenAI semantic conventions where they exist, and
add baikai's own cost and latency where they do not.

Since 0.5.0.0 an evidence record's salient fields ride along as flat attributes —
`baikai.evidence.run_id`, `baikai.evidence.call_id`,
`baikai.evidence.strength`, the two digests, and `gen_ai.response.model` only
when the provider actually reported one — rather than one serialised blob, so
they are queryable in a backend without string parsing.

This is a separate package precisely so the core carries no OpenTelemetry
dependency. It builds on [CAP-9 — call tracing through a pluggable
TraceSink](call-tracing.md), which defines the events it consumes.

## Shape

```haskell
import Baikai.Trace.Sink.OpenTelemetry (otelSink)

resp <- withTrace (otelSink tracer) model ctx opts
```

## Limits

- baikai produces spans; it ships **no exporter and no collector**. The consumer
  supplies and operates the OTel pipeline. What is guaranteed is the span and
  attribute surface, not delivery to any particular backend.
- Coverage is one span per provider call. Work the consumer does around the call
  — its own tool execution, its own retries — is traced only if the consumer
  opens its own child spans.
- `gen_ai.response.model` is set **only when the provider actually reported a
  model**, and only by the evidence branch. It is deliberately not backfilled
  from the request, so its absence on a span is information rather than a gap.
  The terminal branch used to set it from the requested id, which both labelled
  a request as an observation and — because evidence is pushed before the
  terminal and `addAttributes` replaces a key — overwrote the value a provider
  really did report.
- Like all tracing here, it is opt-in per call site: a call that does not go
  through `withTrace` produces no span.
- The package's release history is mostly dependency-bound widening; its own API
  is a single sink and has not changed since 0.1.0.0.
