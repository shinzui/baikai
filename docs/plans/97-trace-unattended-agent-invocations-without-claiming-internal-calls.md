---
id: 97
slug: trace-unattended-agent-invocations-without-claiming-internal-calls
title: "Trace unattended agent invocations without claiming internal calls"
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

# Trace unattended agent invocations without claiming internal calls

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A consumer can trace an unattended Claude Code or Codex subprocess invocation, including time, tool/provider identity, requested configuration, process exit/failure and parent context. The span reports the invocation Baikai observes; it does not claim to know the subprocess's internal model/tool calls. Hard dependencies are docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md for operation lifecycle and docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md for AGENT dispatch. Content and metrics plans are soft integrations.


## Progress


- [ ] Milestone 1: an additive sink-aware run entry point preserves process outcomes, evidence and operator policy.
- [ ] Milestone 2: fixture success/nonzero exit/spawn failure/timeout/cancellation produce exactly one truthful invocation span.
- [ ] Milestone 3: parenting, bounded cleanup, privacy and invocation metric applicability pass integration tests.


## Surprises & Discoveries




## Decision Log


2026-10-12: Treat external agent execution as a client invocation with process evidence, without inferring internal LLM calls or tool execution counts.


## Outcomes & Retrospective




## Context and Orientation


`baikai-agent/src/Baikai/Agent/Run.hs` defines runAgentCommand, validates evidence/working directory/environment, then spawns a process, captures or streams output and optionally builds evidence. It does not call withTrace. `baikai/src/Baikai/Agent.hs` defines AgentRunRequest, AgentCommand, AgentRunResult, AgentRunOutcome and classified AgentRunFailure. A nonzero process exit is a completed result with ExitFailure; spawn/timeout/preflight failures use the failure sum. Trace telemetry must distinguish these states without changing the application's outcome representation.

Tests and subprocess fixtures are in `baikai-agent/test/Main.hs`, `EvidenceTests.hs`, `BinaryTests.hs` and `CliProcessFixture.hs`. `baikai-agent/src/Baikai/Agent/Cli.hs` owns CLI behavior. This initiative exposes a library sink seam; it does not silently initialize an OTel pipeline inside the executable.

[docs/adr/0002-requested-translated-observed-are-never-collapsed.md](../adr/0002-requested-translated-observed-are-never-collapsed.md) requires requested, translated, and observed values to remain separate. [docs/adr/0003-the-adapter-owns-the-translation-description.md](../adr/0003-the-adapter-owns-the-translation-description.md) puts translated facts with the adapter that builds the request. [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md) prohibits claims about provider internals and leaves retries to callers. [docs/adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md](../adr/0015-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md) sets a one-second trace-drain bound and documents that abandonment between stream steps is cleaned up at a later major garbage collection. Preserve these contracts.

Also preserve `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md`, `docs/adr/0012-the-unattended-policy-ceiling-gates-every-repository-settable-field.md` and `docs/adr/0013-library-code-never-calls-exitfailure.md`: threaded runtime, operator ceiling and library failure values remain requirements. Read these ADRs before changing process code. Scope is the unattended runner and batch provider invocation; interactive terminal sessions remain explicitly excluded.

OpenInference is `mori://Arize-ai/openinference`, project-relative paths `spec/traces.md` and `spec/semantic_conventions.md` (artifact-level URIs pending), commit `1198ec9584961640cb8fd78439e643bdb072e01d`. AGENT is a semantic attribute, separate from OTel span kind. Current GenAI agent/client conventions at `mori://open-telemetry/semantic-conventions-genai`, project-relative paths `docs/gen-ai/gen-ai-agent-spans.md` and `docs/gen-ai/gen-ai-metrics.md`, commit `6fd0d763a092db245a54104fc1124031eb3c51d2`, distinguish remote invocation from in-process orchestration. Verify the actual source paths/specification before implementation rather than inventing a hosted HTTP agent.


## Plan of Work


Milestone 1 exposes `runAgentCommandWithTrace` taking a TraceSink and source capture options alongside the existing run arguments; old runAgentCommand uses the unchanged untraced implementation. Use EP-1's common helper around the invocation so every exit path is covered. Record preflight refusal as a failed attempted invocation with dispatched=false; it has no process/model observation. Once spawning starts, distinguish spawn failure, timeout, cancellation and returned exit code. Emit one terminal before returning a normal outcome, and bracket exception cleanup without swallowing caller cancellation.

Milestone 2 sets neutral operation invoke_agent and transport subprocess. EP-2's dispatcher emits CLIENT plus OpenInference AGENT, truthful provider/tool and optional requested model; CLI executable basename is sufficient by default. Evidence may add observed facts only if it exists, but tracing itself does not require evidence. Never claim a served model from a --model argument, process success or requested catalog. Stdout/stderr content, full argument arrays, prompt, filesystem paths and environment values are not default attributes. Safe outcome fields include dispatched flag, exit code and classified failure category. Avoid calling this process run an LLM span in addition to the invocation span.

Attach caller-provided parent/context tags through the sink. Do not read worker-thread ambient context or infer sessions from generated call ids. Existing batch CLI providers already have logical provider-call spans; verify their metadata can identify subprocess transport without wrapping the same call in two agent spans. The new runner path is separately invoked, so duplicate suppression follows the actual API boundary rather than a global guess.

Milestone 3 integrates content only under the shared source/backend privacy policy and keeps stdout/stderr capture bounded. Metrics describe the client invocation duration; no token/inference/tool counts are inferred from process output unless an existing documented protocol and adapter observes them. Do not use in-process invoke_agent duration semantics for an external client call. Preserve timeout/process cleanup and one-second sink-drain guarantees. Promote the visible-process boundary into a plain ADR.


## Concrete Steps


Run from the repository root in the established development environment.

```bash
cabal build baikai-agent baikai-trace-otel
cabal test baikai-agent:test:baikai-agent-test
cabal test baikai-trace-otel:test:baikai-trace-otel-test
```

Extend the agent fixture suite for event production. Add `baikai-trace-otel/test/AgentTelemetrySpec.hs` or cross-package cases in `baikai-smoke` if importing baikai-agent in the OTel suite would violate package dependency order; decide in favor of the existing smoke-package integration boundary. Verify event production in agent tests and spans using synthetic operation events independently. Expected result: all process/evidence outcomes agree with the untraced path.


## Validation and Acceptance


Fixture exit 0 emits one closed CLIENT/AGENT invocation span with dispatched=true and exit code 0. Exit 7 emits one error-status span, preserves ExitFailure 7 in the returned result and does not call exitFailure. Missing executable, timeout and external cancellation end once with distinct safe categories. Missing working directory and evidence refusal never spawn a process and export no response/model/token observations.

Trace parenting matches the caller. Without capture, secret markers in prompt/args/env/stdout/stderr never reach events or spans. Default sink failure cannot hang process cleanup; strict evidence delivery retains its existing semantics. A run with no evidence still traces. No internal LLM/TOOL child spans or call counts are invented. With metrics integration, invocation duration remains available with trace sampling off.


## Idempotence and Recovery


Run fixture binaries only, using temporary working directories. Do not launch real paid agents for acceptance. Preserve existing operator policy and process cancellation, and keep old entry points. Disable the tracing wrapper to recover prior behavior. No global SDK or process environment changes are needed.


## Interfaces and Dependencies


This plan owns agent-run telemetry entry points and neutral event production in the agent package. The core helper comes from docs/plans/92-carry-truthful-provider-telemetry-through-the-call-lifecycle.md, profile dispatch from docs/plans/93-align-call-spans-with-versioned-genai-and-openinference-profiles.md, privacy/metrics from docs/plans/94-capture-structured-ai-content-with-bounded-privacy-controls.md and docs/plans/95-record-genai-metrics-independently-of-trace-sampling.md. docs/plans/98-verify-exported-telemetry-and-document-the-supported-contract.md owns cross-package exports and documentation examples. Keep baikai-agent free of mandatory OTel dependencies.
