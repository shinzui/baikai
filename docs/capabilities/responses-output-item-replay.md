---
title: "Persisted Responses output-item replay"
type: Capability
description: "Carry complete assistant messages and function-call items through persisted Responses history so a later tool turn can reuse the original input prefix."
generated:
  by: codex/gpt-6
  at: "2026-11-23T14:58:14Z"
capabilityId: CAP-33
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.7.4.0"
packages: [baikai-openai, baikai]
interface: [Baikai.Provider.OpenAI.Responses, Baikai.Content]
requires: [CAP-23]
evidence:
  - kind: test
    resource: baikai-openai/test/ResponsesStreamSpec.hs
    proves: "Persisted history retains the input prefix through two tool rounds, refuses inconsistent or foreign replay before transport, and preserves legacy assistant block encoding."
  - kind: guide
    resource: docs/user/models-and-providers.md
    proves: "How to continue or restore a GPT-6.2 conversation with its prefix intact."
---

# Persisted Responses output-item replay

The [Responses backend](openai-responses-backend.md) stores completed
assistant messages and function calls alongside their public projections.
Append the tool result to the context with `appendToolResult` and reuse
the rest of the history. The provider sends the original completed items
when the API, model, and projected content match. Saved responses keep the
replay state through a JSON round trip.

GPT-6.2 bindings put a reusable system prompt at the head of the input as
a developer item. Keep the prompt and earlier history stable across tool turns.
