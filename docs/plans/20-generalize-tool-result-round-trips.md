---
id: 20
slug: generalize-tool-result-round-trips
title: "Generalize Tool Result Round Trips"
kind: exec-plan
created_at: 2026-06-05T02:57:11Z
master_plan: "docs/masterplans/4-initial-api-hardening-before-0-1.md"
---

# Generalize Tool Result Round Trips

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a caller can answer model-issued tool calls with text, image content, or an explicit error result through Baikai's helper API. The current `appendToolResult` helper only accepts a dispatcher of type `ToolCall -> IO Text` and always creates a successful one-text-block result. That is too narrow for the public content model, which already supports `ToolResultImage` and an `isError` flag.

The behavior is visible in tests and smoke examples: a dispatcher can return a normal text result, an image result, or a structured error result, and the follow-up `Context` contains a `ToolResultMessage` that faithfully carries the selected content and error flag.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Audit current tool-call and tool-result helper usage.
- [ ] Introduce a richer dispatcher result type or helper family.
- [ ] Update `appendToolResult` or add a replacement while preserving an ergonomic text-only helper.
- [ ] Update provider request encoders if they assume text-only tool results.
- [ ] Add unit tests for text, image, and error tool results.
- [ ] Update smoke tests and user docs.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

None yet.


## Decision Log

Record every decision made while working on the plan.

- Decision: Treat the current text-only helper as an ergonomic shorthand, not as the final expressive API.
  Rationale: The core content types already expose image tool results and error flags, so the helper should not make those shapes second-class.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Tool calling is the two-turn workflow where a model returns an `AssistantToolCall`, the caller executes the named tool locally, then the caller sends a follow-up request containing one `ToolResultMessage` per tool call. The public content types live in `baikai/src/Baikai/Content.hs`. `ToolCall` carries `id_`, `name`, and JSON `arguments`. `ToolResultContent` can already be `ToolResultText TextContent` or `ToolResultImage ImageContent`.

The message payload lives in `baikai/src/Baikai/Message.hs`. `ToolResultPayload` contains `toolCallId`, `toolName`, `content :: Vector ToolResultContent`, `isError :: Bool`, and `timestamp`. The current `toolResult` helper builds only one text block.

The follow-up helper lives in `baikai/src/Baikai/Context.hs`:

```haskell
appendToolResult ::
  Context ->
  Response ->
  (ToolCall -> IO Text) ->
  IO Context
```

It extracts every `AssistantToolCall` from the response's assistant content, runs the dispatcher, and appends the assistant message plus one text-only successful tool result for each call.

Provider request encoders consume tool result messages in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Smoke coverage for a text tool round trip lives in `baikai-smoke/test/ToolsSmoke.hs`.


## Plan of Work

Milestone 1 designs the helper API. Choose a result type that can express all current `ToolResultPayload` fields without forcing callers to construct the full message by hand. A reasonable target is:

```haskell
data ToolResult = ToolResult
  { toolResultContent :: !(Vector ToolResultContent)
  , toolResultIsError :: !Bool
  }

toolResultText :: Text -> ToolResult
toolResultErrorText :: Text -> ToolResult
toolResultImage :: ImageContent -> ToolResult
```

The final names can differ, but the API must support multiple content blocks, image content, and error results.

Milestone 2 updates message and context helpers. In `baikai/src/Baikai/Message.hs`, add constructors that build `ToolResultMessage` from a `ToolCall` and rich content. In `baikai/src/Baikai/Context.hs`, either change `appendToolResult` to accept `ToolCall -> IO ToolResult` or add a new `appendToolResults` with the richer type and keep the old text-only helper as a wrapper. Since this is before the initial release, prefer the cleaner final name unless existing docs heavily depend on the old one.

Milestone 3 verifies provider encoding. Confirm OpenAI and Claude request mapping supports every `ToolResultContent` constructor. If a provider cannot support image tool results, decide whether to fail clearly before sending the request or encode only supported blocks with a documented limitation. Do not silently drop tool result content.

Milestone 4 updates tests and docs. Add core tests that call the helper with text, image, and error results and inspect the resulting `Context.messages`. Update `baikai-smoke/test/ToolsSmoke.hs` for the new helper shape while keeping the live request text-based unless a reliable provider image-tool-result case is available. Update `docs/user/tools.md`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
```

Audit existing helper usage:

```bash
rg -n "appendToolResult|toolResult|ToolResultContent|ToolResultMessage|AssistantToolCall" baikai baikai-openai baikai-claude baikai-smoke docs
```

Run core tests after helper changes:

```bash
nix develop --command cabal test baikai-test
```

Run provider and smoke tests after request encoder updates:

```bash
nix develop --command cabal test baikai-openai-test baikai-claude-test baikai-smoke
```

Run the full suite before completion:

```bash
nix develop --command cabal test all
```


## Validation and Acceptance

Acceptance requires unit tests that build a fake response containing two `AssistantToolCall` blocks and then append tool results through the new helper. The resulting context must contain the original messages, the assistant message, and one `ToolResultMessage` per tool call in order.

At least one unit test must return `ToolResultText`, one must return `ToolResultImage`, and one must return an error result with `isError = True`. The tests must inspect the resulting payloads rather than only checking vector length.

Provider request encoders must either encode the richer tool result content correctly or reject unsupported content with a clear `BaikaiError`. Silent content loss is not acceptable.

The command:

```bash
nix develop --command cabal test all
```

must complete successfully.


## Idempotence and Recovery

This is a source-level API change and can be implemented additively first. If changing `appendToolResult` directly causes too much churn, add the richer helper under a new name, migrate tests and docs, then decide whether to keep or remove the old helper before release. Since this is pre-0.1, removing the narrow helper is acceptable if the replacement is clearly more correct.


## Interfaces and Dependencies

This plan uses existing modules only. It relies on `Data.Vector`, `Data.Text`, `Data.Aeson.Value`, and the existing content types in `Baikai.Content`.

At the end, `baikai/src/Baikai/Context.hs` must expose a helper that accepts rich tool results. `baikai/src/Baikai/Message.hs` must expose message constructors that do not force callers into text-only successful results. Provider encoders in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` and `baikai-claude/src/Baikai/Provider/Claude/Api.hs` must have explicit behavior for every public `ToolResultContent` constructor.
