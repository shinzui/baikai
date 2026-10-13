---
id: 96
slug: trace-embedding-requests-at-the-actual-client-boundary
title: "Trace embedding requests at the actual client boundary"
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

# Trace embedding requests at the actual client boundary

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A consumer can opt into tracing embeddings and see one EMBEDDING/GenAI embeddings span per actual request, including duration, safe endpoint, model intent, dimensions and errors. A list of three inputs currently sends three requests, so it produces three spans, not one fabricated batch request. Hard dependencies are docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md for neutral operation delivery and docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md for common span dispatch. Content and metrics plans are soft dependencies; use their seams when available.


## Progress


- [ ] Milestone 1: an additive traced embeddings entry point preserves vectors, request count and credential-resolution behavior.
- [ ] Milestone 2: local HTTP success/failure fixtures export correct embedding spans and available dimensions/metadata.
- [ ] Milestone 3: privacy/metrics integration, empty input and client-envelope limitations are verified and documented.


## Surprises & Discoveries




## Decision Log


2026-10-12: Instrument each actual embeddings HTTP request. The current SDK discards response-envelope model/usage; do not guess them or block local tracing on an unreleased upstream change.


## Outcomes & Retrospective




## Context and Orientation


`baikai/src/Baikai/Embedding.hs` defines EmbeddingModel, mkEmbeddingRequest, firstEmbedding, embed and embedOne. `embed` validates the URL before resolving the key, obtains the cached HTTP environment, and traverses inputs, calling createEmbeddings separately for each text. Empty input returns no vectors and makes no requests. Existing tests are `baikai/test/EmbeddingSpec.hs`.

Mori locates `mori://MercuryTechnologies/openai/packages/openai`. Its corpus source at project-relative path `src/OpenAI/V1/Embeddings.hs` (artifact-level URI pending) describes a Servant response ListOf EmbeddingObject; `src/OpenAI/V1.hs` exposes createEmbeddings returning only a Vector. Model and usage envelope fields are therefore unavailable through this interface. Hackage reports openai 2.5.4 on 2026-10-12 and upstream tag queries return no tags. The [released Embeddings source](https://hackage.haskell.org/package/openai-2.5.4/src/src/OpenAI/V1/Embeddings.hs) was also checked and has the same envelope omission. Recheck the release before proposing a binding change.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

`mori://tan/mls-service-v2/okf/adrs/concepts/ADR-8` records unbalanced HTTP manager hooks. Use an explicitly bracketed embedding action rather than instrumenting the cached manager. `docs/adr/0008-one-url-host-parser-and-every-consumer-uses-it.md` requires reuse of the existing URL parser for safe endpoint fields.

OpenInference source is `mori://Arize-ai/openinference`, project-relative paths `spec/embedding_spans.md` and `spec/configuration.md` (artifact-level URIs pending), baseline commit `1198ec9584961640cb8fd78439e643bdb072e01d`. Current GenAI embedding conventions are `mori://open-telemetry/semantic-conventions-genai`, path `docs/gen-ai/gen-ai-spans.md`, commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. Recheck the specs through primary upstream sources; these are development contracts.


## Plan of Work


Milestone 1 factors the existing embedText action into a shared implementation parameterized by an optional neutral operation sink. Expose additive `embedWithTrace` and `embedOneWithTrace` taking TraceSink plus source capture options. Keep embed/embedOne as untraced wrappers. Build embeddings OperationInfo and call withTraceOperation around each dispatched request; exceptions and asynchronous cancellation must close the operation and preserve original exception behavior. Preflight validation is distinguished from dispatched-request failure. Never read credentials earlier or expose them to telemetry.

Milestone 2 maps embeddings events through EP-2's common dispatch: operation embeddings, CLIENT, OpenInference EMBEDDING, requested model, safe server host/port, encoding/dimensions when sent and actual returned dimensions where truthful. When OpenInference is selected, its required CreateEmbeddings span name takes precedence over the GenAI recommended operation/model name; this explicit compatibility choice is documented. Use embedding.model_name and embedding.invocation_parameters, not LLM-only system/parameter keys. Report served model/token usage only if the client returned them. Record malformed/empty returned data as classified failure without inventing a model observation. Add a local HTTP fixture using existing test-server patterns or an injectable create action; the fixture must assert both outgoing request count and emitted spans.

Audit the released OpenAI binding's envelope loss in `docs/telemetry/provider-boundaries.md`. Specify an additive upstream method that preserves data, model, usage and optional response-header access while keeping the existing vectors convenience method. No OpenInference-specific SDK dependency is needed for that improvement. Do not modify the third-party corpus or assume an upstream release. If a release verified during implementation already has such a method, consume it after recording bounds/source evidence; otherwise acceptance explicitly records these unavailable attributes.

Milestone 3 consumes the content policy for embedding text/vector attributes. Default hides both; opt-in must stay within shared budgets, with vector capture separate from text. Metrics sink records operation duration and available input-token measurements only under the selected schema. No estimated usage, output-token count or cost is manufactured. Empty input emits zero requests and zero request spans/measurements. Document that a convenience list is not a wire batch and that failed later inputs retain spans for earlier requests.


## Concrete Steps


Run from the repository root.

```bash
mori registry search openai
mori registry show MercuryTechnologies/openai --full
cabal build baikai baikai-trace-otel
cabal test baikai:test:baikai-test baikai-trace-otel:test:baikai-trace-otel-test
```

Extend `EmbeddingSpec.hs`, add `baikai-trace-otel/test/EmbeddingTelemetrySpec.hs`, and register it in Main/Cabal. Expected result: request counts and vectors match the untraced path, and exported embedding spans obey selected profiles.


## Validation and Acceptance


For three input texts, a fixture receives three identical-shape requests with distinct input values and returns vectors unchanged. Exactly three closed embedding spans carry requested model and safe endpoint. A malformed second response produces an error span for that request and no request for the third, matching existing traverse behavior. Empty input produces neither credential access nor spans.

The vector-only SDK path has no observed response-model or usage attributes. Default spans contain neither text nor vectors. Explicit capture and hiding obey shared policy. Timeouts/cancellation close operations once, while shared-manager behavior remains unchanged. After the metrics plan lands, duration measurements survive an always-off trace sampler.


## Idempotence and Recovery


All fixtures are local and safe to repeat. Preserve old functions and key-resolution order. Disable the traced wrapper to recover existing behavior. Missing upstream envelope access is an explicit supported limitation, not permission to parse invented totals or mutate a dependency checkout.


## Interfaces and Dependencies


This plan owns embeddings entry points and embedding event production, and extends common OTel operation attribute dispatch without redefining its lifecycle. It consumes neutral types from docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md, spans from docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md, privacy from docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md and metrics from docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md. Later plans own the real export harness and final documentation. Promote actual request granularity and client-envelope limits into an ADR if they become durable API constraints.
