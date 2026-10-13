---
id: 93
slug: align-call-spans-with-versioned-genai-and-openinference-profiles
title: "Align call spans with versioned GenAI and OpenInference profiles"
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

# Align call spans with versioned GenAI and OpenInference profiles

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Consumers can explicitly select the existing Baikai span contract or a pinned current GenAI contract, and add OpenInference attributes to the same spans. Served identity, inclusive prompt usage, classified errors and operation names become queryable. Verify exported in-memory spans from real fixture calls with evidence off. The hard dependency is docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md, which provides neutral metadata and non-inference lifecycle events.


## Progress


- [ ] Milestone 1: explicit legacy/current profiles and additive OpenInference mapping pass attribute/type fixtures.
- [ ] Milestone 2: actual provider calls export truthful identity, usage, errors and distinct operation kinds with evidence off.
- [ ] Milestone 3: parenting, concurrent isolation, sampling, replay and unfinished-operation cleanup are verified and documented.


## Surprises & Discoveries




## Decision Log


2026-10-12: Keep a legacy default for span names/status while correcting accounting errors. The current experimental schema and OpenInference are explicit choices; both namespaces share one span.


## Outcomes & Retrospective




## Context and Orientation


`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` is the current single-module adapter. `otelSink` wraps `otelSinkWith`; `OtelSinkOptions` exposes fields with a hidden constructor. The fold keeps a Map from eventId to span. It currently uses CLIENT kind, name `baikai.call`, operation `chat`, Ok success status, input/output counts and evidence attributes. Tests live in `baikai-trace-otel/test/Main.hs`, with a real in-memory exporter created by `newTracerWithInMemory`. Preserve the hidden options constructor and record-update usage.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

`docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md` requires cost basis/availability to remain visible; OpenInference cost is Baikai's estimate, not provider billing corroboration. Parent context is fixed per sink because a worker cannot discover the caller's thread-local context. `mori://tan/mls-service-v2/okf/adrs/concepts/ADR-8` records a leak from unbalanced HTTP manager instrumentation; this plan instruments explicit operations and does not wrap shared managers.

The standards baseline was checked on 2026-10-12. OpenTelemetry GenAI is Development, not stable: use `mori://open-telemetry/semantic-conventions-genai`, project-relative path `docs/gen-ai/client-inference.md` (artifact-level URI pending), at commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. [The upstream inference specification](https://github.com/open-telemetry/semantic-conventions-genai/blob/6fd0d763a092db245a54104fc1124031eb3c51d2/docs/gen-ai/client-inference.md) defines the current spans and metrics. OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/semantic_conventions.md`, `spec/llm_spans.md`, and `spec/configuration.md` (artifact-level URIs pending), at commit `1198ec9584961640cb8fd78439e643bdb072e01d`; [its specification](https://github.com/Arize-ai/openinference/blob/1198ec9584961640cb8fd78439e643bdb072e01d/spec/semantic_conventions.md) is the attribute authority. Mori search found no registered OpenInference project; locate the user-supplied corpus with Mori first on resume, then use that supplied checkout if still unregistered. Recheck upstream changes before implementation; do not silently change the chosen schema.

Hackage and upstream tags verify `mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-api` 1.0.0.0 and semantic-conventions 1.40.0.0 on 2026-10-12. Their typed constants do not exactly match the newer draft: cache-creation is now cache-write. Define missing current keys centrally with explicit types, rather than falsely describe the installed generated constants as current.


## Plan of Work


Milestone 1 adds a public `SemanticProfile` with `LegacyBaikai` and `GenAiExperimental20261012`, plus `openInference :: Bool` on default options. Legacy remains default, with existing `spanName` override and Ok success; current defaults to operation plus requested model and leaves successful status Unset. Distinguish an explicit span-name override from the legacy default so operation naming works predictably. Both correct inclusive token semantics and missing observations. Add internal `Baikai.Trace.Sink.OpenTelemetry.Attributes` for centralized typed keys/mappings and an explicit profile-version marker; do not invent a standards schema URL where upstream says TODO. Additive OpenInference includes `openinference.span.kind=LLM` and `llm.system` for inference, provider identity, requested/observed model fields, prompt/completion/total/cache/reasoning counts when known, and available computed cost. `llm.model_name` uses observed model when available, otherwise requested; the separate request/response attributes and provenance make that distinction explicit.

Milestone 2 consumes start metadata and `CallObservation` without opening or closing extra spans. Standard sampling dimensions (operation, provider, requested model, server address/port) belong at creation. Include translated temperature/top-p/max tokens/output type when applicable, response id/raw finish reasons/first-chunk timing when reported, and low-cardinality `error.type` from structured Baikai classification. Endpoint has host/port only, with no key, userinfo, query or headers. A single known partial component can be reported; inclusive prompt count is emitted only if all required disjoint components are available. Sum uncached+cache-read+cache-write once. Reasoning is a subset of output. Convert Naturals to signed Int64 with a checked bound; omit out-of-range counts with a diagnostic rather than wrap them.

Retain Baikai evidence and cost basis attributes; evidence must not overwrite an observation with requested identity. Success under current GenAI does not set Ok. Error status carries a safe category by default, while raw error text uses the later explicit content policy. User cancellation is marked as cancellation and follows the pinned recording-errors rule rather than automatically treated as provider failure; genuine incomplete/failing streams are Error. Implement common dispatch for `OperationStarted/Finished/Failed`: embeddings use CLIENT and EMBEDDING, agent subprocess invocation uses CLIENT and AGENT, with truthful operation names and optional fields. Operation-specific later plans add facts without changing this lifecycle.

Milestone 3 expands the state from span only to span plus operation/request summary and completion guard. End unfinished entries once at finalization with an explicit incomplete diagnostic; never quietly export an unfinished call as successful. Define duplicate-start handling that closes/rejects the older entry rather than losing a live span; late or duplicate terminals are harmless. Keep explicit parentContext, verify remote parents and sampled-out parents, and document sink-per-request construction. Caller context tags must be passed explicitly, never inferred from eventId or evidence runId.


## Concrete Steps


Run from the repository root, in the Nix development environment if needed.

```bash
mori registry search opentelemetry
mori registry docs iand675/hs-opentelemetry
cabal build baikai-trace-otel
cabal test baikai-trace-otel:test:baikai-trace-otel-test
cabal test baikai:test:baikai-test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test
```

Add profile and lifecycle cases to `baikai-trace-otel/test/Main.hs` and public options checks to `PublicSurfaceSpec.hs`. Expect one closed span per actual operation and exact key/value/type assertions for each selected profile. Record the chosen draft and compatibility contract in `docs/telemetry/span-contract.md`.


## Validation and Acceptance


For uncached input 2, cache read 5/write 3 and output 4, both profiles emit inclusive input 10/output 4; OpenInference prompt 10, completion 4, total 14 and cache subsets 5/3. Missing usage emits no synthetic zero; reported zero remains zero. Requested A and served B occupy distinct keys even with evidence disabled. OpenAI-compatible provider flavor and actual endpoint remain distinct facts. Claude raw max_tokens stays a raw finish reason; no guessed reversal of StopReason is allowed.

Current-profile success has Unset status and operation/model name; legacy retains existing name/status. Classified failure has Error and bounded safe error.type. OpenInference adds attributes to the same span id. Two simultaneous sinks with different parents/tags cannot leak trace context. Remote-parent trace id and parent id match. Sampled-out/noop spans skip optional backend content encoding; explicitly authorized source capture may still serve another sink and remains bounded by its own policy. Duplicate starts, duplicate terminals, evidence replay, dropped terminal and early abort end spans according to documented lifecycle; force GC when verifying the existing abandonment behavior.


## Idempotence and Recovery


Tests require no external backend or credentials. Retain legacy options and constructors' hidden surface. Do not mutate global providers or managers. If the pinned draft changes, update the opt-in profile and its fixtures deliberately; preserve the existing profile or document a versioned migration. Backend failure stays within the existing bounded sink worker.


## Interfaces and Dependencies


This plan owns semantic profiles, options, common span dispatch and typed attribute helpers. docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md extends privacy and content encoders through those options; docs/plans/96-trace-embedding-requests-at-the-actual-client-boundary.md and docs/plans/97-trace-unattended-agent-invocations-without-claiming-internal-calls.md consume common operation dispatch. docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md shares profile identifiers but owns instruments independently. Consult Mori source and released tags before changing hs-opentelemetry bounds. Promote the optional-backend boundary and version policy into plain ADRs when implemented.
