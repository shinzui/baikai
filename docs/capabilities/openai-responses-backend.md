---
title: "OpenAI Responses API backend"
type: Capability
description: "A second, native OpenAI protocol alongside Chat Completions: the Responses provider streams item-ordered output, carries encrypted reasoning across tool turns without server-side state, and is registered explicitly so a consumer chooses which protocol a model dispatches to."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T00:00:00Z"
capabilityId: CAP-23
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.7.0.0"
packages:
  - baikai-openai
  - baikai
interface:
  - Baikai.Provider.OpenAI.Responses
  - Baikai.Provider.OpenAI.Responses.Request
  - Baikai.Provider.OpenAI.Responses.Stream
  - Baikai.Provider.OpenAI.Responses.Assembler
  - Baikai.Api
requires:
  - CAP-1
  - CAP-2
  - CAP-19
evidence:
  - kind: test
    resource: baikai-openai/test/ResponsesSpec.hs
    proves: "Stateless request mapping: text, image, system prompt, token cap and metadata; every accepted effort survives while minimal adjusts with evidence; function tools keep permissive schemas; JSON schema and JSON object both use the Responses text.format shape; an unsupported option fails rather than disappearing; and foreign, malformed, duplicated or Anthropic-scoped replay state is refused without exposing the payload."
  - kind: test
    resource: baikai-openai/test/ResponsesAssemblerSpec.hs
    proves: "Item-ordered assembly: text streams immediately and snapshot reconciliation never duplicates it, parallel function calls retain their call IDs, later content parts wait for earlier ones, an interrupted function-call prefix stays cut off rather than becoming executable JSON, contradictory snapshots fail, and a successful reasoning item must carry replayable continuation."
  - kind: test
    resource: baikai-openai/test/ResponsesStreamSpec.hs
    proves: "The stream contract and its terminals: usage merges earlier categories and matches the evidence cost, partial usage survives a failed stream with missing categories explicit, EOF after a delta closes partial content and fails, an in-band rate limit keeps its classification, a completed terminal cancels a driver still waiting on bytes, a consumer timeout releases a blocked driver, and the public two-turn tool loop preserves encrypted reasoning and call identity."
  - kind: test
    resource: baikai-openai/test/ResponsesEvidenceSpec.hs
    proves: "Strict evidence over the Responses transport: exact request and replay commitment under arbitrary byte fragmentation, refusal before transport still producing a strict record, non-2xx classification with the captured request ID, one failed record for a nested in-band error, and a strict trace cancellation recording exactly one abort while releasing the worker."
  - kind: test
    resource: baikai-openai/test/ResponsesTransportSpec.hs
    proves: "The POST path normalizes exactly one version segment and never follows a redirect."
  - kind: module
    resource: baikai-openai/src/Baikai/Provider/OpenAI/Responses.hs
    proves: "register, openaiResponsesProvider and openaiResponsesStream — the whole public surface a consumer touches."
---

# OpenAI Responses API backend

OpenAI ships two protocols. [CAP-14](openai-chat-completions-backend.md) speaks
Chat Completions, which every OpenAI-compatible host also speaks. This record is
the other one: `/v1/responses`, OpenAI's own newer shape, which Chat Completions
cannot express.

The difference that matters to a consumer is **reasoning continuity across tool
turns**. On Chat Completions a model's reasoning is gone once the turn ends. The
Responses API returns reasoning items — a plaintext summary plus an encrypted
blob — and accepts them back on the next request, so a tool round trip resumes
the model's own reasoning instead of restarting it. baikai carries this as
`ThinkingContent.replayState`, scoped to the provider and model that issued it,
and refuses to send it anywhere else.

This provider is **stateless**: it never sets `store`, and it never relies on a
server-side conversation ID. The replay state travels in the request. That keeps
the provider usable against a host that has retention disabled, and it keeps the
`Context` the single source of truth for what the model has seen.

## Registration is explicit

`Baikai.Provider.OpenAI.Responses.register` is a separate call from the Chat
Completions registration. Registering both gives a registry that dispatches on
the `Model`'s `Api` tag: `OpenAIChatCompletions` to one, `OpenAIResponses` to
the other.

GPT-6 Astra carries `OpenAIResponses` in the generated catalog, so a program that
upgrades to `baikai-openai 0.7.0.0` and calls Astra **must** add the second
`register` call or dispatch fails. This is the one upgrade step this release
asks for.

## Shape

```haskell
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Responses qualified as OpenAIResponses

-- separate from the Chat Completions registration; without it an
-- OpenAIResponses model has no handler and dispatch fails
OpenAIResponses.register
completeRequest Models.openai_gpt_6_astra ctx opts
```

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md) and [CAP-2 — typed incremental
streaming](typed-streaming.md), and produces the same [CAP-19 — verifiable
model-call evidence](model-call-evidence.md) the other API providers do.

## Limits

- **`stability: experimental`.** This is the protocol's first release in baikai.
  It has been through no compatibility cycle, and the replay-state encoding is
  the part most likely to move.
- **Registration is not automatic and cannot be.** Making it automatic would mean
  core deciding which OpenAI protocol a consumer's models use.
- **No server-side state.** `store`, `previous_response_id` and the hosted
  conversation features are not mapped. A caller who wants OpenAI to retain the
  thread cannot get it here.
- **Hosted tools are not mapped.** Function tools work; web search, file search
  and code interpreter do not.
- Replay state is **opaque**. Its `Show` output is a diagnostic, not the payload,
  and there is deliberately no accessor that returns the encrypted bytes.
- Replay state is refused when it came from a different provider or model, is
  malformed, is duplicated, or belongs to an incomplete call. The refusal is an
  `InvalidRequest` before transport, not a silent drop.
- Only OpenAI itself is known to serve this endpoint. The compatible hosts CAP-14
  covers speak Chat Completions; none of them is tested here.
