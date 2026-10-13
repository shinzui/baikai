---
id: 94
slug: capture-structured-ai-content-with-bounded-privacy-controls
title: "Capture structured AI content with bounded privacy controls"
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

# Capture structured AI content with bounded privacy controls

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A consumer can opt into useful structured messages and tool data for AI debugging, while ordinary tracing captures no user content. Privacy decisions are applied before data enters the trace queue, and equivalent restrictions cover both GenAI and OpenInference. Hard dependencies are docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md for the capture seam and docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md for profiles/encoders. Verify using recognizable secret markers and very large fixture content.


## Progress


- [ ] Milestone 1: explicit bounded capture and sanitization keep default traces and queues free of content.
- [ ] Milestone 2: authorized structured text/tool/multimodal output matches each selected schema and privacy controls.
- [ ] Milestone 3: large/partial/failing streams and concurrent policies retain bounded memory and never bypass masking.


## Surprises & Discoveries




## Decision Log


2026-10-12: Require an explicit source-side capture permission as well as backend-side privacy permission. OpenInference attribute mode alone must not enable content capture.


## Outcomes & Retrospective




## Context and Orientation


`baikai/src/Baikai/Trace.hs` currently observes stream events but does not publish each token. `TraceEvent.CallStarted.promptSummary` is a redacted summary, not a raw prompt. `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` can emit that summary through `includePromptSummary`; its `gen_ai.prompt_summary` key is a Baikai extension, not a standard content schema. Structured content originates in `baikai/src/Baikai/Context.hs`, `Message.hs`, `Content.hs` and `Tool.hs`. Prepared provider requests can differ from caller intent, so only adapter-prepared projections can claim to describe messages actually sent.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

The parent metadata plan provides backend-neutral request/response attachment seams; use them without adding SDK dependencies to core or clients. Existing unstarted `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md` proposes AssistantData and telemetry payloads. Those types are absent today. Handle the actual current content algebra exhaustively, then reconcile any later structured-data extension without leaking it by default.

The standards baseline was checked on 2026-10-12. OpenTelemetry GenAI is Development, not stable: use `mori://open-telemetry/semantic-conventions-genai`, project-relative path `docs/gen-ai/client-inference.md` (artifact-level URI pending), at commit `6fd0d763a092db245a54104fc1124031eb3c51d2`. [The upstream inference specification](https://github.com/open-telemetry/semantic-conventions-genai/blob/6fd0d763a092db245a54104fc1124031eb3c51d2/docs/gen-ai/client-inference.md) defines the current spans and metrics. OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/semantic_conventions.md`, `spec/llm_spans.md`, and `spec/configuration.md` (artifact-level URIs pending), at commit `1198ec9584961640cb8fd78439e643bdb072e01d`; [its specification](https://github.com/Arize-ai/openinference/blob/1198ec9584961640cb8fd78439e643bdb072e01d/spec/semantic_conventions.md) is the attribute authority. Mori search found no registered OpenInference project; locate the user-supplied corpus with Mori first on resume, then use that supplied checkout if still unregistered. Recheck upstream changes before implementation; do not silently change the chosen schema.


## Plan of Work


Milestone 1 adds `TraceCaptureOptions` and `defaultTraceCaptureOptions` in the neutral telemetry module. Add new tracing entry points taking this option while existing entry points use disabled capture. It controls input/output text and messages, tool definitions/arguments/results, invocation parameters, optional visible reasoning summaries, image references, maximum message count, maximum attributes and total UTF-8 bytes. Start with a total 64 KiB budget, 32 messages, 128 attributes and a 4 KiB per-text limit; boundaries and configurable lower ceilings must be tested. Apply redaction/truncation to neutral projections before queueing and stop accumulating when limits are reached. Default capture is off. Never capture credentials, authorization/custom headers, encrypted reasoning, signatures or redacted-thinking payloads. Caller-provided conversation/session/user/tags are explicitly supplied; do not invent them from run ids.

Milestone 2 adds `Baikai.Trace.Sink.OpenTelemetry.Content` and privacy options to the hidden sink options surface. Runtime capture permission is the maximum allowed at source; sink options may further restrict it. Add an explicit IO constructor for environment-aware options rather than making pure defaults read environment. Honor applicable OPENINFERENCE_HIDE_INPUTS/OUTPUTS, input/output messages/text/images, tools and invocation-parameter restrictions, with explicit configuration over environment over restrictive Baikai defaults; a source denial always wins. Unsupported environment settings are documented rather than silently advertised. Use `__REDACTED__` for intentionally hidden OpenInference content where applicable. Ensure input.value/output.value and llm.invocation_parameters cannot bypass granular masking by embedding raw data inside JSON.

Project actual prepared message/tool structure in Claude/OpenAI builders and final assembled output, using already sanitized bounded attachments. GenAI uses its pinned JSON message/tool schemas, emitted as canonical JSON strings when this SDK lacks structured attributes. OpenInference uses indexed dot attributes such as llm.input_messages.0.message.role and nested tool calls. Include roles, tool-call/result linkage and multipart text/image types. Visible reasoning is separately opt-in; do not equate its existence with applied effort. Oversized/binary image bodies are omitted/redacted without uploads. Error text is separately opt-in, sanitized and bounded; defaults export safe error categories only. Privacy applies equally to failure partial output, summary fields and both namespaces.

Milestone 3 tests streamed partial output without retaining unbounded deltas; no per-token span events are introduced. Capture-disabled paths allocate no full request copies or reconstructed response solely for tracing. Add a bounded output accumulator only when authorized. Tools suggested by a model are content, not executed TOOL spans; Baikai does not own their execution. Update the content contract and promote privacy ceilings into a plain ADR.


## Concrete Steps


Run from the repository root in the established development environment.

```bash
cabal build all
cabal test baikai:test:baikai-test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-trace-otel:test:baikai-trace-otel-test
```

Add source capture cases to `baikai/test/TraceSpec.hs` and profile/secret fixtures to `baikai-trace-otel/test/ContentSpec.hs` (new, registered in its Cabal file). Add real prepared-request projection tests to provider test suites. Expected result: secret searches over serialized events and exported spans find no markers under default/hidden policies; authorized bounded fields match fixtures.


## Validation and Acceptance


Use distinct markers in system/user/assistant text, tool schema description, tool arguments/result, signed image URL, invocation parameters, failure text and reasoning payload. Default tracing, including OpenInference mode, exposes none. Explicit text-only permission exports bounded text while hiding tools/images/reasoning; hide-inputs suppresses all redundant input forms. Suppressing invocation parameters hides them even when inputs are visible. Source denial cannot be reversed by sink/environment options. Two concurrent calls with opposite policies cannot contaminate each other.

A tool request/result round trip preserves ids and roles in both schema shapes without an executed TOOL span. A failure emits only actual partial output. A ten-megabyte response and thousands of tools/messages remain within the declared trace attachment/attribute budgets, with deterministic truncation indicators and no malformed UTF-8/JSON. Original model input/output values are untouched by telemetry truncation.


## Idempotence and Recovery


All validation is synthetic and repeatable. Do not write captured secrets to persistent fixture artifacts; use generated markers in tests. Disable capture to recover existing metadata-only behavior. Parser/config failures must select safe defaults or return a clear construction error. Avoid global environment mutation in concurrent tests; inject parsed options instead.


## Interfaces and Dependencies


This plan owns `TraceCaptureOptions`, source sanitization, bounded attachments, content encoder and context-tag options. It extends EP-1's empty seam and EP-2's options; other plans call these helpers. No blob uploader, embedding-vector capture by default, evaluation service or exporter is added. Missing future content variants require explicit reconciliation with the checked-in structured-data plan.
