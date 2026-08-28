---
title: "Typed tool calling and the two-turn round trip"
type: Capability
description: "Declare tools once as provider-neutral Tool values with verbatim JSON Schema, constrain the model with ToolChoice, and either drive the request/result round trip by hand or hand the whole loop to runToolLoop, which bounds the turn budget and turns a dispatcher exception into a tool-result error rather than a crash."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-4
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.Tool
  - Baikai.Content
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/HelpersSpec.hs
    proves: "runToolLoop's full contract: it resolves repeated tool turns, leaves the final response separate from the context, returns a replay-valid context when the turn budget is exhausted, converts a synchronous dispatcher exception into an error tool result, and terminates a ToolUse response that carries no tool calls."
  - kind: test
    resource: baikai/test/StreamSpec.hs
    proves: "A tool call cut off by the output cap keeps its raw argument text, is marked by isCutOffToolCall, and is dispatched by neither runToolLoop nor appendToolResult."
  - kind: test
    resource: baikai-claude/test/ShapeSpec.hs
    proves: "A tool's input_schema reaches Anthropic as the caller's verbatim JSON Schema, and ToolChoiceNone keeps the tool definitions while sending tool_choice none."
  - kind: test
    resource: baikai-openai/test/ShapeSpec.hs
    proves: "Streamed tool-call deltas reassemble correctly, including id-bearing index-less deltas that must stay separate calls."
  - kind: example
    resource: baikai-smoke/test/ToolsSmoke.hs
    proves: "A live end-to-end round trip against a real provider: the model requests get_time, runToolLoop executes it, and the final answer references the synthesised timestamp."
  - kind: guide
    resource: docs/user/tools.md
    proves: "Declaring tools, the ToolChoice options, and the two-turn appendToolResult pattern written out."
---

# Typed tool calling and the two-turn round trip

A `Tool` is a name, a description, and a JSON Schema `Value` that baikai forwards
**verbatim** — it neither validates nor rewrites the schema, so anything the
provider accepts is expressible. `ToolChoice` constrains the model to auto, none,
any, or a named tool, and the same value maps onto both vendors' wire formats.

When the model asks for a tool, the response comes back with tool-call blocks and
a `ToolUse` stop reason. The consumer runs the tool and sends the result back as
a second turn. `runToolLoop` does that repeatedly against a dispatcher you
supply, which is the path most consumers take; `appendToolResult` is the manual
alternative when the loop needs to be driven by the caller's own scheduler.

The loop is written to fail usefully. A dispatcher that throws produces an error
tool result the model can react to rather than an exception that unwinds the
call; exhausting the turn budget returns a context that is still valid to replay,
not a truncated one.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
let ctx =
      contextOf [user "What time is it? Use the tool."]
        & #tools .~ V.singleton getTimeTool
    opts = emptyOptions & #toolChoice .~ Just ToolChoiceAuto
(finalCtx, resp) <- runToolLoop 8 dispatcher model ctx opts
print (responseError resp, length (finalCtx ^. #messages))
```

## Limits

- **API providers only.** The `claude -p` and `codex exec` subprocess providers
  take text and return text; a request carrying tools reaches them with the tools
  ignored, because those tools run inside the coding agent's own loop, not the
  caller's. See [CAP-15 — subscription-backed batch CLI
  backends](subscription-cli-backends.md).
- baikai does not validate tool arguments against the declared schema. What the
  model produced is handed to the dispatcher as-is — with one exception: a call
  whose arguments were **cut off** by the output cap is never dispatched.
  `ToolCall.arguments` then holds the raw text as a JSON string,
  `isCutOffToolCall` is `True`, the response's `stopReason` is `Length`,
  `runToolLoop` stops with the response intact, and `appendToolResult` appends an
  `isError` result rather than calling the dispatcher.
- Image blocks inside a tool result are **rejected**, on both API providers,
  rather than silently dropped — a deliberate refusal, but it means a
  multimodal tool result is not expressible today.
- The turn budget passed to `runToolLoop` is a count of model turns, not a
  wall-clock or token bound.
- The offline evidence proves the mapping and the loop mechanics. That a
  particular model actually *chooses* to call a tool is proven only by
  `ToolsSmoke`, which needs a live API key.
