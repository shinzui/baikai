---
title: "OpenAI Chat Completions backend, including any OpenAI-compatible host"
type: Capability
description: "One handler serves OpenAI and every host that speaks its Chat Completions shape — DeepSeek, OpenRouter, Together, Z.ai, Qwen — with per-host request-shaping quirks auto-detected from the Model rather than configured by hand, and a longer response-header allow-list for the gateways commonly in front of them."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-14
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai-openai
  - baikai
interface:
  - Baikai.Provider.OpenAI.Api
  - Baikai.Provider.OpenAI.Internal.Stream
  - Baikai.Provider.OpenAI.Sse
  - Baikai.Provider.OpenAI.Transport
  - Baikai.Provider.OpenAI.Shape
  - Baikai.Compat
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai-openai/test/TransportSpec.hs
    proves: "The HTTP transport beneath the provider and its failure paths, including that the connection cache allocates once per normalised base URL and that an unusable base URL — a query string, credentials in the URL, no scheme, or a full endpoint path — is refused as an InvalidRequest before any key is read from the environment."
  - kind: test
    resource: baikai-openai/test/SseSpec.hs
    proves: "Chunk decoding and reassembly, including that id-bearing index-less tool deltas stay separate calls and that the response-metadata callback fires once before the first chunk on both the 2xx and non-2xx paths. The request-shape cases assert the composed path for five base-URL spellings and that redirectCount is zero; the redirect case drives a fake manager that answers 302 and asserts that only the configured host was ever contacted."
  - kind: test
    resource: baikai-openai/test/ShapeSpec.hs
    proves: "Request shaping across the compatible-host matrix, including which shapes carry an effort word and which are excluded from the compatibleEffort clamp."
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "That OpenAI-compatible hosts auto-detect their request-shaping compat flags, that the system-instruction wrapper is omitted when there is no system prompt, and that an image tool-result block is rejected rather than dropped."
  - kind: module
    resource: baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs
    proves: "openaiChatStreamWith, the SseDriver seam, the chunk decoders, the reasoning-tag scanner and the usage mapping. Internal: exposed for the test suites and outside the compatibility contract."
  - kind: example
    resource: baikai-smoke/test/CompatSmoke.hs
    proves: "A live call against an OpenAI-compatible host that is not OpenAI."
  - kind: example
    resource: baikai-smoke/test/MultiHostSmoke.hs
    proves: "Live calls dispatched to several different compatible hosts through the one registered handler."
---

# OpenAI Chat Completions backend, including any OpenAI-compatible host

`Baikai.Provider.OpenAI.Api.register` installs the handler for the
`OpenAIChatCompletions` tag. That one handler serves OpenAI itself and every host
that imitates its Chat Completions shape; the host is selected by the `Model`'s
base URL, not by a second registration.

Compatible hosts differ in small, load-bearing ways — whether they accept a
system message or need it folded into the prompt, whether they support
`cache_control` on tools, which reasoning-control field they read, whether they
express reasoning depth at all. `Baikai.Compat` holds those quirks as an
`OpenAICompletionsCompat` record, and the provider **auto-detects** the right one
from the model rather than making the caller configure it. Seven distinct
reasoning wire shapes are supported and pinned by a table test.

The response-header allow-list is deliberately longer here than on the Anthropic
side — `x-request-id`, `request-id`, `x-amzn-requestid`, `x-ms-request-id`,
`cf-ray` — because this transport talks to an open-ended set of hosts and the
gateways commonly in front of them.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi

OpenAIApi.register
-- a non-OpenAI host is just a Model with a different baseUrl:
let m = mkModel OpenAIChatCompletions "deepseek-chat" "https://api.deepseek.com"
completeRequest m ctx opts
```

## Limits

- **Chat Completions only.** The OpenAI Responses API is not implemented, so
  anything that exists only there is out of reach. On `api.openai.com` that
  includes prompt-cache control: Chat Completions caches automatically and
  accepts no retention marker, so `Options.cacheRetention` reaches the wire only
  on a compatible host whose compat record sets `cacheControlFormat` —
  OpenRouter, in the shipped table.
- Compat auto-detection is a lookup over known hosts. A host baikai has not seen
  falls back to defaults, and getting it wrong shows up as a rejected request or
  a silently ignored field, not as a typed error.
- Two compatible hosts (Z.ai, Qwen) accept only a bare reasoning toggle, so
  reasoning *depth* is unexpressible there. See
  [CAP-11 — cross-provider reasoning-effort control](reasoning-effort-control.md).
- Image blocks inside a tool result are rejected rather than dropped, as on the
  Anthropic side.
- `fully_observed` evidence is unreachable: no host in this ecosystem echoes the
  reasoning configuration it applied.
- **The base URL is the API root**, without the version segment: baikai appends
  `/v1/chat/completions` itself, and a trailing `/v1` is removed rather than
  doubled. A base URL with no scheme, a scheme other than `http`/`https`,
  credentials, a query string, a fragment, or a path that is already an endpoint
  is refused as an `InvalidRequest` before a key is read. Query strings stay
  unsupported: a host needing `?api-version=` has to be fronted by a gateway.
- **A redirect is never followed.** A 3xx is delivered as the terminal error
  carrying its status, because following one would re-send the bearer token to
  whatever host the `Location` names.
- The `ClientEnv` cache is process-global, unbounded, shared with the Anthropic
  backend and the embeddings client, and keyed per normalised base URL. A fleet
  of per-tenant base URLs is not a supported use of `Model.baseUrl`.
- `RawChunk` gained `model` and `responseId` fields and the four `Sse` entry
  points gained a metadata callback in 0.5.0.0; code that *constructs* these
  needs updating, code that pattern-matches does not.
- Offline evidence is recorded frames and hand-built requests. Which compatible
  hosts actually work today is proven only by `CompatSmoke` and `MultiHostSmoke`,
  both of which need live credentials.
