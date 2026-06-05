---
id: 22
slug: stabilize-compat-and-streaming-extension-points
title: "Stabilize Compat and Streaming Extension Points"
kind: exec-plan
created_at: 2026-06-05T02:57:16Z
master_plan: "docs/masterplans/4-initial-api-hardening-before-0-1.md"
---

# Stabilize Compat and Streaming Extension Points

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Baikai's initial API will have an explicit stability story for two areas most likely to change after release: provider compatibility shims and streaming events. The current core package exposes concrete OpenAI- and Anthropic-specific compat records from `Baikai.Compat` and includes those records in `Baikai.Model.Compat`. The streaming event algebra is a closed public sum. Both choices are workable for 0.1 only if the API makes clear which parts are stable, which parts are extension points, and how new provider quirks or content events can be added without forcing unnecessary downstream churn.

The behavior is visible in documentation and tests: callers can still construct and use models from the generated catalog, providers still apply compatibility flags correctly, and streaming consumers have a documented way to handle unknown future details or an explicit commitment that constructor additions are breaking changes for the 0.1 line.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Audit exported compat and streaming event constructors.
- [ ] Decide whether compat records remain public, become opaque, or move toward provider packages.
- [ ] Decide whether streaming remains a closed event algebra or gains an extension constructor.
- [ ] Implement the chosen API changes after response invariants are settled.
- [ ] Update generated model catalog expectations and provider mapping tests.
- [ ] Update user docs with the compatibility and streaming stability policy.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

None yet.


## Decision Log

Record every decision made while working on the plan.

- Decision: Run this plan after the message/response invariant plan.
  Rationale: Streaming terminal events and reassembly depend on the final assistant response shape, so event stability should not be decided against a soon-to-change response model.
  Date: 2026-06-05
- Decision: Treat compat and streaming as API policy work, not only code cleanup.
  Rationale: The core question is what downstream users are allowed to rely on in 0.1; documentation and constructor exposure matter as much as implementation.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Compatibility shims are provider-quirk records. They capture details such as whether an OpenAI-compatible host accepts `strict: true` on tool definitions, which field name it expects for max output tokens, and how it handles reasoning controls. The core compat module is `baikai/src/Baikai/Compat.hs`. `baikai/src/Baikai/Model.hs` exposes:

```haskell
data Compat
  = CompatNone
  | CompatOpenAICompletions !OpenAICompletionsCompat
  | CompatAnthropicMessages !AnthropicMessagesCompat
```

Generated models in `baikai/src/Baikai/Models/Generated.hs` currently use `CompatNone`, which means providers auto-detect compat behavior from the model `baseUrl`. Provider request mapping reads compat through `openaiCompletionsCompatFor` and `anthropicMessagesCompatFor`.

Streaming events live in `baikai/src/Baikai/Stream/Event.hs`. `AssistantMessageEvent` is a closed sum with constructors such as `EventStart`, `TextDelta`, `ToolCallEnd`, `EventDone`, and `EventError`. The module documentation already says adding a new variant is a breaking change. Streaming reassembly lives in `baikai/src/Baikai/Stream.hs`, tracing lives in `baikai/src/Baikai/Trace.hs`, and provider streams are implemented in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`.

This plan has a hard dependency on `docs/plans/21-make-message-construction-and-response-invariants-explicit.md` because terminal event payloads and reassembly must match the final response invariant.


## Plan of Work

Milestone 1 audits exported surface area. Confirm every module re-exported from `Baikai` and every provider package export that exposes compat or streaming constructors. The result should be a short note in this plan's Surprises & Discoveries section during implementation with the exact modules that commit users to compat or event constructors.

Milestone 2 settles compat policy. There are three acceptable outcomes. The first is to keep concrete compat records public and document them as part of the 0.1 API, accepting that new provider quirks may require version bumps. The second is to make compat records opaque by exporting smart constructors/defaults and update functions while hiding record constructors. The third is to move provider-specific compat records toward provider packages and keep core `Model` compat more generic. Choose one and record the decision. For initial release, the likely pragmatic choice is to keep the records public but narrow the top-level `Baikai` re-export if the team wants to discourage casual dependence.

Milestone 3 settles streaming policy. Decide whether `AssistantMessageEvent` remains a closed sum with documented breaking-change semantics or gains an explicit extension constructor such as `ProviderEvent Api Value` or `UnknownEvent Text Value`. A closed sum is easier to consume exhaustively and may be right for 0.1. An extension constructor reduces future breakage but weakens type precision. If the closed sum remains, update docs to tell consumers to include a wildcard branch if they want forward resilience.

Milestone 4 implements the chosen changes. Update `baikai/src/Baikai.hs`, `baikai/src/Baikai/Compat.hs`, `baikai/src/Baikai/Model.hs`, `baikai/src/Baikai/Stream/Event.hs`, and provider mapping code as needed. If constructors are hidden, add enough functions that callers can still configure known hosts. If an extension event constructor is added, update reassembly, tracing, and provider tests.

Milestone 5 updates docs and tests. Update `docs/user/models-and-providers.md`, `docs/user/streaming.md`, and any examples that pattern-match on events or construct compat records. Run the generated catalog regeneration test because compat policy touches generated model construction.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
```

Audit exports and pattern matches:

```bash
rg -n "module Baikai|Compat \\(\\.\\.\\)|OpenAICompletionsCompat|AnthropicMessagesCompat|AssistantMessageEvent \\(\\.\\.\\)|EventStart|EventDone|EventError" baikai baikai-openai baikai-claude baikai-trace-otel docs
```

Run core tests after compat or event changes:

```bash
nix develop --command cabal test baikai-test
```

Run provider and tracing tests after event or compat mapping changes:

```bash
nix develop --command cabal test baikai-openai-test baikai-claude-test baikai-trace-otel-test
```

Run the full suite before completion:

```bash
nix develop --command cabal test all
```


## Validation and Acceptance

Acceptance requires a recorded decision in this plan about compat exposure: public records, opaque records, or provider-package ownership. The implementation and docs must match that decision.

Acceptance also requires a recorded decision about streaming events: closed algebra with breaking-change semantics or explicit extension constructor. The implementation and docs must match that decision.

Generated model catalog tests must still pass. In the current suite this is covered by `baikai-test`, which runs the catalog regeneration check.

Provider tests must still demonstrate that compat flags affect request mapping. If existing tests do not cover this, add focused tests around at least one OpenAI-compatible and one Anthropic-compatible compat difference.

The command:

```bash
nix develop --command cabal test all
```

must complete successfully.


## Idempotence and Recovery

Make policy decisions before large code edits. If hiding compat constructors causes too much churn, preserve public constructors for 0.1 and document them explicitly rather than producing an incomplete opaque API. If adding an extension event constructor complicates provider streams or reassembly, keep the closed algebra and strengthen documentation. The important outcome is a deliberate stability policy, not a maximal abstraction.


## Interfaces and Dependencies

This plan should not add dependencies. It uses existing `aeson` only if an extension event constructor carries raw provider data.

At the end, `baikai/src/Baikai/Compat.hs`, `baikai/src/Baikai/Model.hs`, and `baikai/src/Baikai.hs` must expose compat in a way that matches the recorded policy. `baikai/src/Baikai/Stream/Event.hs` and `docs/user/streaming.md` must expose and document streaming event stability in a way that matches the recorded policy. Provider mapping modules must continue to compile and apply compat decisions.
