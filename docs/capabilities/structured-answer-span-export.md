---
title: "Structured answer export through OpenTelemetry"
type: Capability
description: "Export structured answer values and probability evidence as canonical JSON on successful and failed provider spans."
generated:
  by: codex/gpt-6
  at: "2026-10-25T13:31:23Z"
capabilityId: CAP-30
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.4.1.0"
packages: [baikai-trace-otel, baikai]
interface: [Baikai.Trace.Sink.OpenTelemetry]
requires:
  - CAP-10
  - CAP-28
evidence:
  - kind: test
    resource: baikai-trace-otel/test/Main.hs
    proves: "Success and failure spans export canonical structured data and omit the attribute for data-free terminals."
---

# Structured answer export through OpenTelemetry

Builds on [CAP-10 — OpenTelemetry span export](opentelemetry-span-export.md) and [CAP-28 — structured answer content](structured-answer-content.md).

## Shape

```haskell
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)

withTrace (otelSink tracer) model ctx opts
```

## Contract

Use a provider returning `AssistantData`, such as TypeSafe, with the existing
sink. Before `baikai-trace-otel 0.4.1.0`, the adapter cannot export structured
answer evidence. The new `baikai.response.structured_data` attribute contains
canonical JSON for the ordered payloads, including probabilities and confidence,
on both success and failure terminals. Data-free terminals omit the attribute.

The attribute is a JSON string. It contains answer content even when call
evidence is disabled; consumers control their own exporter and retention policy.
The existing span lifecycle and requested-versus-observed model rules apply.
