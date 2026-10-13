---
id: 98
slug: verify-exported-telemetry-and-document-the-supported-contract
title: "Verify exported telemetry and document the supported contract"
kind: exec-plan
created_at: 2026-10-12T15:09:09Z
intention: "intention_01m4ra56xme4ftjqypcwytanbm"
master_plan: "docs/masterplans/15-comprehensive-opentelemetry-and-openinference-observability.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-12T15:09:09Z
---

# Verify exported telemetry and document the supported contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A contributor can run one credential-free integration suite and inspect actual serialized OTLP output for all supported AI boundaries. A dated conformance report states what is supported, opt-in, unavailable or inapplicable, with exact tests and source baselines. This plan's hard dependencies are docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md, docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md, docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md, docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md, docs/plans/96-trace-embedding-requests-at-the-actual-client-boundary.md, docs/plans/97-trace-unattended-agent-invocations-without-claiming-internal-calls.md: all six runtime behaviors must exist before the integrated contract can be accepted.


## Progress


- [ ] Milestone 1: local fixtures drive all supported execution boundaries through real SDK batch processing and OTLP export.
- [ ] Milestone 2: conformance fixtures verify serialized types, parenting, privacy, metrics, failures and bounded lifecycle.
- [ ] Milestone 3: compiled usage examples, release compatibility notes, full offline suites and ADR distillation close the initiative.


## Surprises & Discoveries




## Decision Log


2026-10-12: Prove actual OTLP export in a local receiver; do not require a vendor account, paid call or production collector to accept telemetry.


## Outcomes & Retrospective




## Context and Orientation


`baikai-smoke/baikai-smoke.cabal` can depend on all publishable packages without creating runtime dependency cycles. It hosts `doc-shapes` and the compiled capability example `baikai-smoke/doc-shapes/Shape/Cap10.hs`. The regular live smoke suite can invoke real providers and is not the acceptance command for this plan. Existing OTel unit tests use an in-memory exporter; that proves attributes in process but not OTLP serialization or SDK metric collection.

`docs/capabilities/opentelemetry-span-export.md` (CAP-10) describes spans only and currently asserts legacy Ok success. `docs/capabilities/call-tracing.md` describes the neutral sink. `docs/user` contains provider/streaming/evidence guides; add a user telemetry guide following its established frontmatter/OKF contract. This plan also owns `docs/telemetry/conformance.md` and a new keyless test suite `telemetry-contract` in baikai-smoke.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

`docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md` requires capability Shape examples and their twin modules to compile and match. `docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md` requires usage/cost provenance. Read all implementation decisions and discoveries from the six child plans before final ADR distillation.

The standards baseline was checked on 2026-10-12. OpenTelemetry GenAI is Development, not stable: use `mori://open-telemetry/semantic-conventions-genai`, project-relative path `docs/gen-ai/client-inference.md` (artifact-level URI pending), at commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. [The upstream inference specification](https://github.com/open-telemetry/semantic-conventions-genai/blob/6fd0d763a092db245a54104fc1124031eb3c51d2/docs/gen-ai/client-inference.md) defines the current spans and metrics. OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/semantic_conventions.md`, `spec/llm_spans.md`, and `spec/configuration.md` (artifact-level URIs pending), at commit `1198ec9584961640cb8fd78439e643bdb072e01d`; [its specification](https://github.com/Arize-ai/openinference/blob/1198ec9584961640cb8fd78439e643bdb072e01d/spec/semantic_conventions.md) is the attribute authority. Mori search found no registered OpenInference project; locate the user-supplied corpus with Mori first on resume, then use that supplied checkout if still unregistered. Recheck upstream changes before implementation; do not silently change the chosen schema.


## Plan of Work


Milestone 1 creates `baikai-smoke/test/TelemetryContract/Main.hs` and local fixture/receiver modules. Use the released `mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-exporter-otlp` and SDK with consumer-owned TracerProvider/MeterProvider, a batch span processor and a loopback OTLP receiver capturing request bodies. Prefer OTLP HTTP protobuf through the released exporter if supported; otherwise implement its actual transport or select another released exporter mode after inspecting Mori source. Do not write a fake serializer and call that export acceptance. Parse payloads with the released OTLP generated types located through Mori, and assert structural values rather than byte ordering. Bind loopback on an ephemeral port, use bounded waits and cleanly shut down/flush providers owned by the fixture.

Drive synthetic Claude Messages, OpenAI Chat Completions, Responses, compatible-host and batch CLI fixtures through public Baikai call entry points. Also run traced embeddings and the unattended runner using local HTTP/process fixtures. Include a custom provider with empty telemetry. Real clients/assemblers must participate so raw-message facts cannot disappear between a mocked trace event and export. Where fixture-driver seams are intentionally internal, expose only the package's existing test seams and use test libraries or the established local-server approach; avoid widening production APIs solely for tests.

Milestone 2 adds exact fixture expectations for legacy, pinned current GenAI and additive OpenInference. Check one logical span per operation, correct OTel kind/OpenInference kind, safe sampling attributes at start, requested/observed distinctions, inclusive token arithmetic, omission of missing values, correct attribute types, error categories and success status. Embedding OpenInference mode must follow its required CreateEmbeddings name; document the precedence over the current GenAI recommended operation/model name rather than claim two exact names on one span. Verify metrics from SDK collection and export when spans are sampled out. Flush/shutdown must not cause telemetry-owned provider leaks or mutate consumer globals.

Conformance report maps the pinned source's MUST/required/conditional/recommended/opt-in requirements to actual applicable tests or an explicit limitation. Cover input/output/tool definitions and results, visible reasoning/privacy, media omission, streaming timing, evidence, compatible provider identity, embeddings, agent invocation, sampling and context. Include log/event support assessment: this initiative implements span content attributes and neutral trace events, not a full GenAI OTel Logs implementation. Mark optional chunk events/blob uploading/evaluation/retrieval/reranking/hidden agent calls/interactive terminal internals as unsupported or inapplicable with specific reasons; never label them compliant by silence. Unsupported binding envelope fields are a client gap with canonical upstream references.

Milestone 3 updates CAP-10 and its compiled shape, adds metadata/privacy/metrics/embedding/agent examples to a user guide, and publishes migration notes. Preserve documented legacy behavior while showing explicit current/profile/OpenInference selection, separate capture permission and consumer SDK ownership. Inspect current released dependencies with registry/tag evidence before changing bounds; apply PVP for exported constructors/fields and options. Prepare changelog/version changes once across affected packages, without uploading or tagging a release under this create/implementation scope. Validate modified OKF records with their local profiles/log rules. Distill durable decisions into plain docs/adr, using local instructions rather than inventing a profiled bundle. Record final evidence in each plan and the MasterPlan registry.


## Concrete Steps


Run from the repository root; enter nix develop if needed.

```bash
mori registry search opentelemetry
mori registry show iand675/hs-opentelemetry --full
cabal build all
cabal test baikai-smoke:test:telemetry-contract
cabal test baikai-smoke:test:doc-shapes baikai-smoke:test:smoke-options
cabal test baikai:test:baikai-test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-agent:test:baikai-agent-test baikai-trace-otel:test:baikai-trace-otel-test baikai-effectful:test:baikai-effectful-test baikai-kit:test:baikai-kit-test
git diff --check
```

The telemetry-contract suite is new and must be added before invoking its command. Expected output is a passing local export suite naming provider/protocol/profile scenarios, with no real provider requests. Export readable synthetic fixture summaries to a temporary directory for manual inspection, and document the suite's actual inspect command once implemented. Do not run the live baikai-smoke suite inadvertently.


## Validation and Acceptance


From a clean checkout and without credentials, the offline commands pass. The loopback receiver sees spans for success, failure, cancellation, partial response, missing usage, streamed response, embeddings and agent invocation, with known ids/parentage and proper profile attributes. Metrics remain exported with an always-off trace sampler. Available zero token/cost fields remain zero; missing fields stay absent. No duplicated logical model spans appear in provider/batch paths.

Secret markers embedded in content, tool schemas/args/results, URL queries, custom headers, failure text, reasoning payload and environment never appear in default OTLP requests or debug output. Explicit text capture exports only bounded permitted content. Concurrent parents/policies are isolated. Repeated fixture calls leave no live spans or leaked operation state; errors/stalls honor the bounded bridge. Early abandonment tests force major GC and explicitly document the current eventual-finalization limit, not a guarantee before process exit.

The conformance report contains every supported execution boundary and requirement category, the exact source commits and release evidence, associated tests and known exclusions. Capability shape examples compile and match their Markdown. All seven plans remain Not Started until implemented; at completion update each based on actual evidence, never the existence of these planning documents.


## Idempotence and Recovery


The fixture uses temporary files, ephemeral loopback ports and synthetic secrets; it is safe to repeat. Reset captured request buffers between scenarios and stop all owned servers/providers after failure. A batch flush timeout fails with bounded diagnostics, not an endless wait. Runtime dependencies remain optional; no external collector/plugin installation, production endpoint, credential, vendor account or publishing is required.


## Interfaces and Dependencies


This plan owns cross-package fixture suites, real export proof, final conformance/user docs and release compatibility preparation. Package-level behavior remains owned by the six runtime plans. Inspect actual SDK/exporter/OTLP source using Mori and verify released APIs before choosing transport. Intentional limitations must be explicit even when a feature is popular upstream. Completion requires the complete offline/export evidence and durable ADR pass, not just a visually convincing trace in a backend.
