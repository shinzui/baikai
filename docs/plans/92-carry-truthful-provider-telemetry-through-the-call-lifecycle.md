---
id: 92
slug: carry-truthful-provider-telemetry-through-the-call-lifecycle
title: "Carry truthful provider telemetry through the call lifecycle"
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

# Carry truthful provider telemetry through the call lifecycle

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A traced Claude, OpenAI, Responses, or CLI call will report available model/response identity, translated request settings, raw finish reasons, usage availability, transport mode, endpoint and timing even when evidence is off. Backend-neutral metadata means facts that contain no OpenTelemetry keys or SDK types. Verify with local provider fixtures in both streaming and blocking call modes; absent wire observations must never become invented defaults. This plan has no hard dependencies.


## Progress


- [ ] Milestone 1: neutral metadata and operation lifecycle contracts preserve old trace JSON and custom-provider behavior.
- [ ] Milestone 2: Claude, OpenAI Chat, Responses and CLI fixtures carry available wire facts without evidence or duplicated terminals.
- [ ] Milestone 3: timing, failure, replay and sink-cleanup regressions pass; client ownership audit and durable ADR are recorded.


## Surprises & Discoveries




## Decision Log


2026-10-12: Observational telemetry must not require evidence hashing or strict evidence delivery. Providers remain the authority for translated fields and observations.


## Outcomes & Retrospective




## Context and Orientation


`baikai/src/Baikai/Trace.hs` starts a trace worker and translates `AssistantMessageEvent` terminals into `TraceEvent`. `baikai/src/Baikai/Trace/Event.hs` has start, finish, failure and optional evidence events. Only evidence currently exposes the served model. `baikai/src/Baikai/Stream/Event.hs` has `TerminalPayload` with responseId, message, reason, errorInfo and evidence. `baikai/src/Baikai/Response.hs` echoes the requested Model; it is not a source of observed model identity. `baikai/src/Baikai/Usage.hs` separates uncached input, cache-read/write and output; reasoning is included in output. `UsageAvailability` identifies unavailable accounting fields.

Claude observations already exist in `baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`. OpenAI Chat uses `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs`; native Responses uses `baikai-openai/src/Baikai/Provider/OpenAI/Responses/Assembler.hs` and `Responses/Stream.hs`. Their prepared-request modules and `Shape.hs` files determine actual wire parameters. Batch providers are in their respective `Cli.hs` files. Raw finish reasons can differ from normalized `StopReason`; retain both rather than reverse-map them.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

Also retain shared classification from `docs/adr/0011-core-owns-transport-failure-classification.md` and partial accounting from `docs/adr/0020-pricing-policies-and-calculation-bases-are-explicit.md`. Read the ADR files before making durable changes. Existing unstarted `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md` also edits terminal trace content; reconcile fields if it lands during this work, without requiring its unimplemented types.

Mori identifies the bindings as `mori://MercuryTechnologies/claude/packages/claude` and `mori://MercuryTechnologies/openai/packages/openai`. Their source has model/id/usage and stream fields, while Baikai also uses local raw SSE decoders. Hackage reports claude 1.5.0 and openai 2.5.4 on 2026-10-12; upstream tag lookups returned no tags. Inspect released tarball types before asserting that corpus types are available. Wire type omissions or missing reusable response-header hooks belong upstream; translating those facts into Baikai belongs here. OpenInference emission does not belong in either binding by default.


## Plan of Work


Milestone 1 adds `baikai/src/Baikai/Telemetry.hs`. Define `RequestTelemetry` for operation name, actual streaming flag, provider format/vendor, sanitized host/port, optional translated sampling/output settings; define `ResponseTelemetry` for observed model/id/request-id, raw finish reasons, typed failure category, and optional stream timing. Reuse `Observed` where silence needs to be explicit. Define a default empty metadata value, a metadata field on `Response` and `TerminalPayload`, and an optional request metadata field on `CallStarted`. Add a `CallObservation` event emitted before the existing terminal. Keep metadata independent of `Options.evidence`; update every constructor and event consumer, including JSONL, memory, multiSink, OTel's exhaustive match and effectful fixtures. New optional trace fields decode with missing defaults and omit empty additions; adding exported record fields/constructors requires a PVP compatibility note.

Define `OperationInfo` and `OperationStarted`, `OperationFinished`, `OperationFailed` for embeddings and agent invocations. An operation has a generated correlation id, requested optional model, endpoint/transport, start/end times, optional observed metadata/usage, and structured failure; it does not require inference maxTokens or promptSummary. Add a common `withTraceOperation` helper in `Baikai.Trace` that brackets one action and delivers its start/observation/terminal with the same bounded sink-drain behavior. Other operation plans consume this helper instead of copying worker management. Expose an initially empty, bounded content attachment seam for the later content plan; this milestone captures no raw bodies.

Milestone 2 populates metadata from actual request preparation and response assembly. HTTP streaming is true even when a blocking Baikai wrapper folds that stream. Record transport `http` versus `subprocess` separately from semantic provider names. Compatible hosts retain truthful provider flavor and endpoint; do not infer vendor from a model name. Retain raw finish strings at decode time. Serve observed identity and usage on partial failure when received. CLI paths expose only what their documented result/event formats report; Codex's missing served model stays absent. Immediate/preflight failures have request intent but no fabricated wire or response observations. Normal usage events must respect missing-category flags rather than export assembler zeroes.

Milestone 3 measures first received response chunk in the transport decoder using a monotonic clock (elapsed time independent of wall-clock adjustments). Do not call semantic `EventStart`, generated locally before HTTP, the first received chunk. No per-token trace events or retained interval arrays are added. A neutral optional chunk-timing observer hook may deliver subsequent actual transport-chunk intervals directly to a metrics consumer; absent that observer, interval metrics are explicitly unsupported, never approximated from total duration or sampled intervals. The hook must have bounded work and no content retention, and is wired by the metrics plan. Verify one terminal under duplicate/late wire frames, cancellation and early abort, and that blocking and streaming wrappers produce one observation/terminal each. Publish a local client-boundary audit in `docs/telemetry/provider-boundaries.md` distinguishing binding support, adapter extraction, and unavailable data, including precise canonical upstream references for any proposed missing hook. Promote the durable metadata/evidence distinction into a new plain ADR using the local convention.


## Concrete Steps


Run from the repository root; enter the established Nix development environment if Cabal/GHC are unavailable.

```bash
nix develop
mori registry search claude
mori registry search openai
mori registry show MercuryTechnologies/claude --full
mori registry show MercuryTechnologies/openai --full
cabal build all
cabal test baikai:test:baikai-test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-trace-otel:test:baikai-trace-otel-test baikai-effectful:test:baikai-effectful-test
```

Add focused metadata cases to `baikai/test/TraceSpec.hs` and existing provider assembler/transport suites under `baikai-openai/test` and `baikai-claude/test`. Expected result: all offline suites pass, including exhaustive pattern matches and legacy JSON fixtures. Use Mori to locate dependency documentation; never traverse the Nix store.


## Validation and Acceptance


An Anthropic fixture requests model alias A, reports served model B, cache read 5/write 3, uncached input 2, output 4 and request id R. With evidence off, trace output contains requested A, observed B/R, distinct usage components and one terminal. An OpenAI fixture with inclusive prompt 10 and cached 5 preserves the normalized 5 uncached plus 5 cache read. A transport failure before headers has no observed model/id/tokens. A partial failure after headers/chunks retains observations and marks unavailable categories. Raw `length` and Anthropic `max_tokens` remain distinguishable. A custom provider using empty metadata still completes and traces successfully.

A first transport chunk delayed by the fixture produces a nonzero first-chunk interval; the locally emitted EventStart does not end that interval. No metrics/span keys appear in neutral JSON. Replay, sink throw/stall, aborted stream with forced major collection and cancellation retain existing bounded cleanup guarantees.


## Idempotence and Recovery


Tests use local fixtures and repeat safely. No credential or external client checkout mutation is required. Preserve old decoders and update all constructor sites in one compilable change. If released client types lack a field, use Baikai's existing raw decoder seam where available and document the upstream gap; do not widen dependency bounds or pin an unreleased client to hide it. Retain the old provider entry points and default empty telemetry.


## Interfaces and Dependencies


This plan owns the new neutral metadata/events, `withTraceOperation`, and adapters' fact extraction. docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md consumes them for span mappings; docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md implements the empty content attachment seam; docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md consumes timing/usage for metrics; docs/plans/96-trace-embedding-requests-at-the-actual-client-boundary.md and docs/plans/97-trace-unattended-agent-invocations-without-claiming-internal-calls.md emit non-inference events. Dependency changes require current registry and released source evidence, not memory. Use canonical Mori references for all durable cross-repository claims.
