---
id: 15
slug: comprehensive-opentelemetry-and-openinference-observability
title: "Comprehensive OpenTelemetry and OpenInference observability"
kind: master-plan
created_at: 2026-10-12T15:08:31Z
intention: "intention_01m4ra56xme4ftjqypcwytanbm"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T15:08:31Z
---

# Comprehensive OpenTelemetry and OpenInference observability

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


After this initiative, a consumer can inspect a Baikai model call, embedding request, or unattended agent invocation in its existing OpenTelemetry pipeline and see the operation, truthful provider observations, available usage, errors, and parent trace. An explicit OpenInference option makes those same spans recognizable to AI observability backends. Structured conversation and tool data can be captured with bounded, opt-in privacy controls; metrics remain useful even when traces are sampled out. A local export fixture proves the result without API credentials.

“Comprehensive” means every shipped AI execution boundary has either demonstrated telemetry or an explicit applicability decision. The coverage includes Anthropic Messages, OpenAI Chat Completions, native OpenAI Responses, compatible hosts, both batch CLI providers, embeddings, and unattended agent subprocesses. Retrieval/reranking, evaluations, application-owned tool execution, hidden agent internals, and interactive terminal session internals have no observable implementation boundary here. They receive documented exclusions rather than fabricated spans. A full GenAI OTel Logs/event implementation and blob uploads are deliberately outside this initiative; span content attributes are the supported content path. Baikai will not start an exporter, collector, global SDK, upload service, or retry loop for the consumer.

This is creation of implementation plans. No runtime behavior is changed by creating these documents. All documents carry intention `intention_01m4ra56xme4ftjqypcwytanbm`.

The inspected tree is commit `358e1f23163237f39221e32634621d5e5084d863`. `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` presently opens one CLIENT span, names it `baikai.call`, labels every operation `chat`, exports only input/output token counts, explicitly marks success Ok, and closes failures with free-text errors. Parent context is captured per sink because the sink runs on a worker thread. Response model arrives only through optional evidence. `TraceEvent` already carries cache-read/write, reasoning, total counts and usage availability, which the sink ignores. `Usage.inputTokens` is non-cached input; the current mapping therefore understates inclusive prompt counts. Embeddings and unattended agent runs do not pass through this sink.

The standards baseline was checked on 2026-10-12. OpenTelemetry GenAI is Development, not stable: use `mori://open-telemetry/semantic-conventions-genai`, project-relative path `docs/gen-ai/client-inference.md` (artifact-level URI pending), at commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. [The upstream inference specification](https://github.com/open-telemetry/semantic-conventions-genai/blob/6fd0d763a092db245a54104fc1124031eb3c51d2/docs/gen-ai/client-inference.md) defines the current spans and metrics. OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/semantic_conventions.md`, `spec/llm_spans.md`, and `spec/configuration.md` (artifact-level URIs pending), at commit `1198ec9584961640cb8fd78439e643bdb072e01d`; [its specification](https://github.com/Arize-ai/openinference/blob/1198ec9584961640cb8fd78439e643bdb072e01d/spec/semantic_conventions.md) is the attribute authority. Mori search found no registered OpenInference project; locate the user-supplied corpus with Mori first on resume, then use that supplied checkout if still unregistered. Recheck upstream changes before implementation; do not silently change the chosen schema.

The [Hackage API registry](https://hackage.haskell.org/package/hs-opentelemetry-api/preferred.json) and upstream release tags both identify API 1.0.0.0; semantic-conventions 1.40.0.0 is current on Hackage. The released Metrics API exists at that API tag. Current Hackage releases for the bindings are claude 1.5.0 and openai 2.5.4; upstream tag queries returned no tags, so tags do not corroborate those client releases. Do not treat unreleased corpus types as available in those releases or select new bounds without inspecting released sources.


## Decomposition Strategy


The first plan establishes facts and operation lifecycle independent of any backend. The next plans independently deliver schema-correct spans, controlled content capture, and sampling-independent measurements. Embeddings and agent invocations are separate because one instruments HTTP requests and the other owns subprocess outcomes. The last plan supplies actual export evidence and a supported contract, rather than considering in-memory assertions sufficient.

The client boundary matters. The bindings at `mori://MercuryTechnologies/claude/packages/claude` and `mori://MercuryTechnologies/openai/packages/openai` own wire types and reusable low-level request/response hooks. Baikai's provider adapters own the mapping into Baikai facts, including translated parameters and provider-observed usage/identity. `baikai-trace-otel` owns `gen_ai.*`, `llm.*`, privacy-aware encoding, and telemetry backend configuration. Adding OpenInference keys to core or forcing an OTel dependency into each client would duplicate instrumentation and violate the optional adapter boundary. EP-1 audits release availability and records concrete upstream work only where a binding actually loses a needed fact.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

Also consulted [docs/adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md), [docs/adr/0011-core-owns-transport-failure-classification.md](../adr/0011-core-owns-transport-failure-classification.md), [docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), and [docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md). They require producer cancellation, common error categories, compiled capability examples, and truthful partial usage/cost respectively. Mori located and resolved `mori://tan/mls-service-v2/okf/adrs/concepts/ADR-8`: its observed unbalanced HTTP manager hooks argue for explicit, bracketed boundaries rather than wrapping shared managers.

Existing unstarted work in `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md` also extends trace content and the OTel sink. This is an integration dependency, not a hard dependency: implement telemetry against today's content types, then reconcile structured-data fields and privacy behavior whichever initiative lands later. Do not assume its proposed types exist.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 (plan 92) | Truthful provider telemetry | docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md | None | None | Not Started |
| 2 (plan 93) | Versioned GenAI and OpenInference spans | docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md | EP-1 | None | Not Started |
| 3 (plan 94) | Bounded private content capture | docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md | EP-1, EP-2 | None | Not Started |
| 4 (plan 95) | Sampling-independent GenAI metrics | docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md | EP-1 | EP-2 | Not Started |
| 5 (plan 96) | Embedding request tracing | docs/plans/96-trace-embedding-requests-at-the-actual-client-boundary.md | EP-1, EP-2 | EP-3, EP-4 | Not Started |
| 6 (plan 97) | Unattended agent invocation tracing | docs/plans/97-trace-unattended-agent-invocations-without-claiming-internal-calls.md | EP-1, EP-2 | EP-3, EP-4 | Not Started |
| 7 (plan 98) | Export verification and supported contract | docs/plans/98-verify-exported-telemetry-and-document-the-supported-contract.md | EP-1, EP-2, EP-3, EP-4, EP-5, EP-6 | None | Not Started |

EP numbers above identify registry rows; plan numbers identify the actual generated files.


## Dependency Graph


EP-1 provides backend-neutral metadata, new non-inference lifecycle events, and the common event-delivery helper. EP-2 and EP-4 require those types. EP-3 needs EP-2's profiles and options to encode protected content consistently. EP-5 and EP-6 need EP-1's lifecycle and EP-2's non-inference span dispatch. Their content and metrics extensions integrate with EP-3 and EP-4 but can be tested independently; these are soft dependencies. EP-7 needs all six delivered behaviors to test the whole pipeline.

After EP-1, spans and metrics can proceed independently. After EP-2, content, embeddings, and agent tracing can proceed independently within the ownership below. Shared-file edits must be coordinated. There are no cyclic or external hard dependencies.


## Integration Points


EP-1 owns `baikai/src/Baikai/Telemetry.hs` (new neutral types), `Baikai.Stream.Event.TerminalPayload`, `Baikai.Response.Response`, metadata fields/events in `Baikai.Trace.Event`, and the shared operation-delivery helper in `Baikai.Trace`. EP-3 extends its capture seam; EP-5 and EP-6 consume the generic lifecycle without redefining it. Missing observations stay missing. Existing trace JSON remains decodable with absent new fields.

EP-2 owns `OtelSinkOptions`, span state/lifecycle, semantic profiles, common operation dispatch, parent context, safe error mapping, and attribute helpers in `baikai-trace-otel`. EP-3 extends only the content policy/encoder; EP-5 and EP-6 add operation-specific attributes through that dispatch. Never open a second logical span from an observation or content event.

EP-1 owns provider metadata extraction in Claude/OpenAI streaming assemblers, Responses assembler, CLI adapters, and prepared-request code. EP-3 adds bounded content projection at their prepared request/assembled response seam. Actual translated parameters come from real request builders, not another compatibility table. The bindings receive upstream proposals only for release-confirmed deficiencies; such external changes are not assumed by these plans.

EP-3 owns capture permission, sanitization, size limits, and per-request caller-supplied context tags. Core capture permission and sink privacy must both allow content. Other plans consume its helper and never reconstruct full request bodies in the sink. All sensitive forms, including invocation parameters, tools, error text, images, and opaque reasoning payloads, pass through the policy.

EP-4 owns metric construction, instruments, allowlisted dimensions, schema-specific names, and exactly-once measurement logic. EP-5 and EP-6 add embedding/agent applicability through that interface. Neither span sampling nor a disabled tracer may disable metrics. Usage is reported only when available; internal agent calls are not counted.

EP-7 owns `baikai-smoke` cross-package export fixtures, capability/doc examples, the conformance report, release compatibility notes, and final acceptance. Every runtime plan owns its package tests and relevant changelog additions. Coordinate Cabal exposed modules and dependencies with their owning plan; package version changes are prepared once by EP-7.

Durable decisions to promote during implementation are the client/adapter/backend boundary, independent metadata versus evidence, frozen experimental profiles and opt-in migration, content capture/privacy ceilings, metric ownership, and the visibility limit of subprocess invocations. Follow `agents/skills/exec-plan/ADR.md`; this repository currently uses plain ADR files, not a profiled ADR OKF bundle.


## Progress


Planning complete; all seven children are Not Started. EP-1 is implementable immediately. The remaining acceptance gate is a local OTLP export demonstrating spans, parentage, privacy, and metrics across all applicable boundaries, with the conformance report recording every supported or excluded requirement.


## Surprises & Discoveries




## Decision Log


2026-10-12: Keep provider facts in clients/adapters and OpenInference encoding in the optional telemetry package. This preserves a reusable provider boundary and prevents double-counted model spans.

2026-10-12: Preserve the existing span name and successful Ok status in an explicit legacy profile, while offering a pinned current GenAI profile with operation/model names and Unset success status. OpenInference attributes are additive on the same span. Experimental upstream changes must not silently alter existing dashboards.

2026-10-12: Include embeddings and unattended runs as separate work streams. A span-only audit of chat calls would leave existing shipped AI boundaries uncovered. Record hidden tool/model execution and interactive sessions as excluded rather than infer them.

2026-10-12: Keep content capture separate from ordinary metadata/evidence, with explicit request opt-in and restrictive defaults even when OpenInference's own defaults permit content. Capture limits apply before data is queued.


## Outcomes & Retrospective
