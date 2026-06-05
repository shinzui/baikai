---
id: 21
slug: make-message-construction-and-response-invariants-explicit
title: "Make Message Construction and Response Invariants Explicit"
kind: exec-plan
created_at: 2026-06-05T02:57:11Z
intention: intention_01ktavd0a0e08r0mw24mrgjgb7
master_plan: "docs/masterplans/4-initial-api-hardening-before-0-1.md"
---

# Make Message Construction and Response Invariants Explicit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Baikai's public types will express two invariants that the code already assumes: constructing messages with timestamps is an effect or an explicit value, and provider responses contain assistant output rather than arbitrary conversation messages. Today the pure helper functions `user`, `assistant`, `userImage`, and `toolResult` call `getCurrentTime` through `unsafePerformIO`, and `Response.message :: Message` permits `UserMessage` and `ToolResultMessage` even though provider code and logging assume `AssistantMessage`.

The behavior is visible in tests: deterministic constructors can be given a fixed `UTCTime`, effectful convenience constructors can be tested in `IO`, and cost logging no longer needs a production `error` branch for non-assistant responses.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Audit every use of `user`, `assistant`, `userImage`, `toolResult`, `Response.message`, and `flattenAssistantBlocks`. Completed 2026-06-05; the audit found hidden-time constructors in `Baikai.Message`, response assumptions in `Baikai.Stream`, `Baikai.Cost.Log`, `Baikai.Cost.Pricing`, `Baikai.Trace`, provider CLI constructors, tests, smoke tests, and user docs.
- [x] Add explicit-time and effectful message constructors. Completed 2026-06-05; `userAt`/`userNow`, `userImageAt`/`userImageNow`, `assistantAt`/`assistantNow`, and `toolResult...At`/`toolResult...Now` helpers were added.
- [x] Migrate tests, docs, and provider code away from hidden-time pure constructors. Completed 2026-06-05; user docs now show `userNow`, `appendToolResult` timestamps tool results in `IO`, and deterministic tests use explicit timestamps.
- [x] Redesign `Response` so assistant-only output is encoded in the type. Completed 2026-06-05; `Response.message` is now `AssistantPayload`, and `responseMessage` wraps it as a broad `Message` when needed.
- [x] Update streaming reassembly, tracing, cost logging, and provider packages for the response invariant. Completed 2026-06-05; reassembly constructs assistant payloads, cost logging reads usage directly, and provider CLI responses populate `AssistantPayload`.
- [x] Validate deterministic timestamp behavior and assistant-response invariants. Completed 2026-06-05; `nix develop --command cabal test all` passed, and `rg -n "unsafePerformIO" baikai/src/Baikai/Message.hs` returned no matches.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: Keeping the field name `Response.message` while changing its type to `AssistantPayload` avoided a larger naming churn but still made the non-assistant state unrepresentable.
  Evidence: GHC forced every former `resp ^. #message` pattern match to either consume `AssistantPayload` directly or use `responseMessage` where a broad `Message` was required.
  Impact: EP-5 can treat `Response.message` as assistant-only and decide separately whether streaming terminal events should also narrow from `Message` to `AssistantPayload`.
  Date: 2026-06-05


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat `unsafePerformIO` in public message constructors as an API smell to remove before 0.1.
  Rationale: Hidden effects make tests and replay behavior harder to reason about, and pre-release is the least costly time to choose explicit semantics.
  Date: 2026-06-05
- Decision: Prefer encoding assistant-only responses in the type over keeping a runtime convention.
  Rationale: `Response` comments and provider behavior already promise assistant output; the current broader type forces defensive code and one production `error` path.
  Date: 2026-06-05
- Decision: Keep the existing pure constructor names as deterministic fixture shorthands while adding explicit-time and effectful names.
  Rationale: Removing `user`, `assistant`, `userImage`, and `toolResult` would create unnecessary churn for tests and simple fixtures. Redefining them to use a fixed timestamp removes hidden effects, while `...At` and `...Now` provide the explicit semantics user-facing docs should prefer.
  Date: 2026-06-05
- Decision: Keep streaming terminal events as broad `Message` values for EP-4.
  Rationale: EP-5 owns streaming extension-point stability. EP-4 only needs `reassembleResponse` to produce an assistant-only `Response`, and `responseMessage` preserves a total bridge from responses back to conversation messages.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-4 completed 2026-06-05. Public message construction now has explicit-time and effectful APIs, and the old pure names no longer sample time secretly. `Response.message` is now an `AssistantPayload`, so providers cannot return `UserMessage` or `ToolResultMessage` through the response envelope. `responseMessage` provides the total conversion back to a conversation `Message` for context replay and stream events.

Streaming reassembly, tracing, cost logging, CLI providers, tests, smoke tests, and user docs were migrated to the new shape. The production `error` branch in `runRequestWithLog` is gone because usage is read directly from the assistant payload. `nix develop --command cabal test all` passed on 2026-06-05.


## Context and Orientation

Messages live in `baikai/src/Baikai/Message.hs`. `Message` has three constructors: `UserMessage UserPayload`, `AssistantMessage AssistantPayload`, and `ToolResultMessage ToolResultPayload`. Each payload has a `timestamp :: UTCTime`. The public helpers `user`, `userImage`, `assistant`, and `toolResult` are pure functions, but they call `unsafePerformIO getCurrentTime` internally.

Responses live in `baikai/src/Baikai/Response.hs`. `Response` currently contains `message :: Message`, even though the field comment says it is always built with `AssistantMessage`. `flattenAssistantBlocks` returns an empty vector if the message is not an assistant message. `baikai/src/Baikai/Cost/Log.hs` has a production `error` in `runRequestWithLog` if a provider returns a non-assistant message.

Streaming events live in `baikai/src/Baikai/Stream/Event.hs`, and reassembly lives in `baikai/src/Baikai/Stream.hs`. Terminal events carry a `Message`, and `reassembleResponse` builds a `Response`. Provider packages construct assistant messages in OpenAI, Claude, Codex CLI, and Claude CLI modules.

This plan is a soft dependency for `docs/plans/20-generalize-tool-result-round-trips.md` and a hard dependency for `docs/plans/22-stabilize-compat-and-streaming-extension-points.md`.


## Plan of Work

Milestone 1 removes hidden time from public constructors. In `baikai/src/Baikai/Message.hs`, add explicit-time constructors such as `userAt`, `userImageAt`, `assistantAt`, and `toolResultAt`. Add effectful convenience constructors such as `userNow`, `userImageNow`, `assistantNow`, and `toolResultNow` with `MonadIO` or `IO` return types. Decide whether to remove the old pure names or redefine them as explicit-time-free fixture constructors that do not sample the clock. Because this is pre-0.1, prefer names that make time semantics obvious rather than preserving misleading names.

Milestone 2 migrates call sites. Tests that need deterministic values should use explicit fixed timestamps. Provider code already has real timestamps from call start/end and should continue to construct payload records directly or use `assistantAt`. Docs should avoid showing pure helpers that hide effects.

Milestone 3 redesigns the response invariant. Choose a type shape that prevents non-assistant provider responses. Two reasonable options are `Response { assistant :: AssistantPayload, ... }` or a new `AssistantMessage` newtype distinct from the broad conversation `Message`. The final API should still make it easy to append the assistant turn back into a `Context`, so expose a helper such as `responseMessage :: Response -> Message` if the field no longer stores a `Message` directly.

Milestone 4 updates stream reassembly and logging. `Baikai.Stream.Event.TerminalPayload` may continue to carry a broad `Message` until EP-5, but `reassembleResponse` must produce the final assistant-only response shape. `Baikai.Cost.Log.runRequestWithLog` must no longer contain a production `error` branch for non-assistant responses. `flattenAssistantBlocks` should either become a total accessor over the new assistant payload or be renamed to reflect the new shape.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
```

Audit relevant call sites:

```bash
rg -n "user\\b|userImage|assistant\\b|toolResult|Response \\(|#message|flattenAssistantBlocks|AssistantPayload|unsafePerformIO" baikai baikai-openai baikai-claude baikai-trace-otel baikai-smoke docs README.md
```

Run core tests after constructor changes:

```bash
nix develop --command cabal test baikai-test
```

Run provider tests after response-shape changes:

```bash
nix develop --command cabal test baikai-openai-test baikai-claude-test baikai-trace-otel-test
```

Run the full suite before completion:

```bash
nix develop --command cabal test all
```


## Validation and Acceptance

Acceptance requires deterministic constructor tests. A test should call explicit-time constructors with a known `UTCTime` and assert that the payload timestamp equals that value. A separate test should call the effectful constructor and assert that it returns a message in `IO`.

No public pure message constructor should call `unsafePerformIO getCurrentTime`. Searching `baikai/src/Baikai/Message.hs` for `unsafePerformIO` should either return no matches or only unrelated global constants with clear justification.

`Response` must no longer permit a provider to return `UserMessage` or `ToolResultMessage` through its main assistant-output field. Code that needs to append an assistant turn back to `Context` must use a total helper.

`runRequestWithLog` must not use `error` to recover the assistant usage. It should read usage from the assistant-only response shape directly.

The command:

```bash
nix develop --command cabal test all
```

must complete successfully.


## Idempotence and Recovery

Implement this plan in two commits if possible: one for message constructors, one for response invariants. If the response redesign causes broad churn, keep a transitional `responseMessage :: Response -> Message` helper so provider and context call sites can migrate incrementally. Avoid changing streaming event extensibility here beyond what is required to compile; EP-5 owns the final streaming extension-point decision.


## Interfaces and Dependencies

This plan uses existing dependencies only: `time`, `text`, `vector`, and existing Baikai modules.

At the end, `baikai/src/Baikai/Message.hs` must expose explicit-time and effectful message construction APIs. `baikai/src/Baikai/Response.hs` must encode assistant-only output in its type or expose an equivalent total invariant. `baikai/src/Baikai/Cost/Log.hs`, `baikai/src/Baikai/Stream.hs`, `baikai/src/Baikai/Trace.hs`, and provider packages must consume that invariant without production partial functions.
