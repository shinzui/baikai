---
id: 95
slug: record-genai-metrics-independently-of-trace-sampling
title: "Record GenAI metrics independently of trace sampling"
kind: exec-plan
created_at: 2026-10-12T15:09:08Z
intention: "intention_01m4ra56xme4ftjqypcwytanbm"
master_plan: "docs/masterplans/15-comprehensive-opentelemetry-and-openinference-observability.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T15:09:08Z
---

# Record GenAI metrics independently of trace sampling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Consumers obtain duration, token usage and streaming response measurements even when every trace is sampled out. A metric is an aggregated measurement; a histogram records the distribution of values. This plan creates an optional metrics sink using the consumer's Meter, independently of its Tracer. Its only hard dependency is docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md, which supplies operation/usage/timing facts. docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md is an integration dependency for shared semantic-profile identifiers, so temporary local profile tests are possible until those identifiers land.


## Progress


- [ ] Milestone 1: consumer-owned Meter instruments use pinned names, units and bounded attribute dimensions.
- [ ] Milestone 2: real traced operations produce exactly-once duration/available usage/timing measurements with spans disabled.
- [ ] Milestone 3: partial failures, zero/absent usage, replay, empty operations and metric cardinality checks pass.


## Surprises & Discoveries




## Decision Log


2026-10-12: Record client measurements from neutral events, independently of exported spans. Do not derive client time-per-token by dividing duration by token count.


## Outcomes & Retrospective




## Context and Orientation


`baikai-trace-otel` currently emits spans only. `baikai/src/Baikai/Trace/Sink.hs` defines a streamly Fold-backed TraceSink and `multiSink`; metric delivery can share this event stream without creating another provider call. EP-1's observations carry usage availability and monotonic first/subsequent chunk timing. Raw chunk timing differs from model token generation time and must be named accurately.

`mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-api` exposes `OpenTelemetry.Metric.Core`; the released API 1.0.0.0 tag was checked, not just local main. The module has Meter, meterCreateHistogram, histogramRecord, advisory parameters and no-op behavior. Locate current source with Mori and verify the installed release's exact signatures. Consumer supplies/owns SDK aggregation/export/shutdown.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

`docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md` requires missing token categories and pricing availability to stay explicit. Never aggregate guessed zeroes as observed usage.

The standards baseline was checked on 2026-10-12. OpenTelemetry GenAI is Development, not stable: use `mori://open-telemetry/semantic-conventions-genai`, project-relative path `docs/gen-ai/client-inference.md` (artifact-level URI pending), at commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. [The upstream inference specification](https://github.com/open-telemetry/semantic-conventions-genai/blob/6fd0d763a092db245a54104fc1124031eb3c51d2/docs/gen-ai/client-inference.md) defines the current spans and metrics. OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/semantic_conventions.md`, `spec/llm_spans.md`, and `spec/configuration.md` (artifact-level URIs pending), at commit `1198ec9584961640cb8fd78439e643bdb072e01d`; [its specification](https://github.com/Arize-ai/openinference/blob/1198ec9584961640cb8fd78439e643bdb072e01d/spec/semantic_conventions.md) is the attribute authority. Mori search found no registered OpenInference project; locate the user-supplied corpus with Mori first on resume, then use that supplied checkout if still unregistered. Recheck upstream changes before implementation; do not silently change the chosen schema.

The current pinned inference draft uses gen_ai.client.inference.duration and separate inference usage instruments, while the older draft used operation.duration and token.usage. Names are experimental; a profile must select one coherent contract rather than emit both names for the same observation by default.


## Plan of Work


Milestone 1 adds `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry/Metrics.hs` with an IO constructor `otelMetricsSinkWith` taking a consumer Meter and explicit metrics options. Create instruments once per sink construction, not per event. Own a separate MetricProfile selector with legacy/current choices aligned with EP-2's source baselines, so this module compiles independently of EP-2; the profile alignment is an integration dependency. Implement legacy GenAI 1.40 operation.duration in seconds and token.usage in tokens. For the pinned current contract, implement inference duration/first-chunk histograms from client-inference.md, usage input/output/cache-read/cache-write/reasoning Counters with unit {token}, and per-operation input/output Histograms from project-relative path `docs/gen-ai/gen-ai-token-metrics.md` in `mori://open-telemetry/semantic-conventions-genai` at the pinned commit (artifact-level URI pending). Copy exact names, types, units and advisory buckets into tests. Embeddings use generic client operation.duration; hosted subprocess invocation is a client operation, not an in-process agent-duration measurement. Do not implement server token-generation metrics.

Allowlist only operation, provider, requested/served model when known, server address/port where applicable, and bounded error.type/token-type dimensions required by the chosen profile. Never include call/run/session/user ids, request ids, content, digests or raw error strings. User-defined model/host labels can still have high cardinality; expose a bounded normalization/drop policy and document it without changing span truth.

Milestone 2 maintains operation state keyed by correlation id in the fold. On each terminal record one duration from producer timing, then available token classes/timing only as permitted by their availability flags. Inclusive input sums disjoint uncached/cache-read/cache-write counts only when all are known; subsets remain independent observations. Output includes reasoning once. Zero is a valid measurement; absence is no measurement. Cache/usage observations arriving before terminal update state rather than generate duplicate measurements. No separate cost total is inferred from incomplete pricing. Expose optional Baikai-specific cost only when computed and labelled as estimate/basis; this is not mandatory GenAI compliance.

Current first-chunk measurements consume actual received-chunk timing from EP-1. Add an optional metrics timing observer through its neutral hook for gen_ai.client.inference.time_per_output_chunk, recording each actual output-chunk interval directly with no retained interval array or per-token TraceEvent. Expose construction returning the sink and the observer wiring needed by the new traced entry point, while sink-only construction supports first-chunk metrics. Observer failure must be isolated from provider behavior, and callbacks perform only SDK recording, never synchronous export. Document that interval telemetry requires this opt-in hook; do not infer it from lifecycle events. These measurements are not “time to first token” or server time-per-output-token. Record no first-chunk measurement before a chunk actually arrives. Preserve partial-failure applicability defined by the pinned instrument specification.

Milestone 3 validates metric delivery with a fake recording Meter implementing the released API instrument callbacks and at least one real SDK collection/export case in the later integration plan. Compose metrics and spans through multiSink; a sampler dropping all spans still records metrics. Noop Meter produces no errors. A duplicate terminal is ignored; a standalone replay terminal has no live operation to close. Keep bounded state and close unfinished operations with their truthful incomplete diagnostic, not success. Update a metrics contract and relevant ADRs.


## Concrete Steps


Run from the repository root.

```bash
mori registry docs iand675/hs-opentelemetry
cabal build baikai-trace-otel
cabal test baikai-trace-otel:test:baikai-trace-otel-test
cabal test baikai:test:baikai-test
```

Add `baikai-trace-otel/test/MetricsSpec.hs` and register it in Main/Cabal. Expected result: callbacks receive exact names, units, values and permitted dimensions; no-span fixtures still produce measurements.


## Validation and Acceptance


For a 250 ms operation and input components 2/5/3, output 4/reasoning 1, record duration 0.25 seconds, inclusive input 10, output 4 and known subsets once. No total counts double-add cache or reasoning. For missing cache-write, do not report inclusive input as 7; report known subsets and omit the unknown total. A reported free/zero-token call records zero; a preflight failure records no usage. First chunk at 50 ms becomes 0.05 seconds; a local start event is excluded.

Run each scenario with Tracer noop, always-off sampling and normal spans: measurements agree. Repeat terminals and evidence without duplicate observations. Thousands of unique event ids do not appear in exported metric labels. Agent/embedding operations get only metrics applicable to their actual boundaries; no hidden model/tool counts are fabricated.


## Idempotence and Recovery


Tests are local and repeatable. Construct instruments once and pass explicit options. Do not mutate a global MeterProvider or shut down a provider the caller owns. Disabling the metric sink restores span-only behavior. Dependency changes require authoritative registry/tag/released-source verification; the API already has metrics, so no upgrade is assumed.


## Interfaces and Dependencies


This plan owns metric constructors, names, units, dimensions and operation completion rules. Span profile identifiers from docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md must agree at integration; they are not a hard blocker. docs/plans/96-trace-embedding-requests-at-the-actual-client-boundary.md and docs/plans/97-trace-unattended-agent-invocations-without-claiming-internal-calls.md emit neutral operation facts and add tests consuming this sink. docs/plans/98-verify-exported-telemetry-and-document-the-supported-contract.md proves real SDK aggregation/export, beyond recording callbacks.
