---
title: "Anthropic Messages API backend"
type: Capability
description: "Register one handler and dispatch baikai calls to Anthropic's Messages API over SSE: typed content and tool blocks, thinking blocks with signatures preserved, an allow-listed response-header capture, and Anthropic's own error taxonomy classified into baikai's categories."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-13
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai-claude
interface:
  - Baikai.Provider.Claude.Api
  - Baikai.Provider.Claude.Sse
  - Baikai.Provider.Claude.Transport
  - Baikai.Provider.Claude.Shape
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai-claude/test/TransportSpec.hs
    proves: "The HTTP transport layer beneath the provider, including request construction, the failure paths that never reach a live host, that the connection cache allocates once per normalised base URL, and that an unusable base URL — a query string, credentials in the URL, no scheme, or a full endpoint path — is refused as an InvalidRequest before any key is read from the environment."
  - kind: test
    resource: baikai-claude/test/SseSpec.hs
    proves: "Anthropic's SSE frame handling: event decoding, the response-metadata callback that fires exactly once before the first event on both the 2xx and non-2xx paths, and reassembly into baikai's event algebra. The request-shape cases assert the composed path for four base-URL spellings and that redirectCount is zero; the redirect case drives a fake manager that answers 302 and asserts that only the configured host was ever contacted."
  - kind: test
    resource: baikai-claude/test/ShapeSpec.hs
    proves: "Request shaping: verbatim tool input_schema, tool_choice mapping, and cache-control marker placement gated on host capability."
  - kind: test
    resource: baikai-claude/test/Main.hs
    proves: "The provider-level contract, including that an image tool-result block is rejected rather than dropped and that responseFormat maps onto Anthropic's native output_config."
  - kind: module
    resource: baikai-claude/src/Baikai/Provider/Claude/Api.hs
    proves: "The register / registerWith entry points, claudeMessagesStreamWith, the SseDriver seam, and anthropicStrength."
---

# Anthropic Messages API backend

`Baikai.Provider.Claude.Api.register` installs the handler for the
`AnthropicMessages` tag, after which any `Model` carrying that tag dispatches to
Anthropic's Messages API. The provider streams over SSE and reassembles into
baikai's event algebra, so blocking and streaming callers see the same types they
would against any other backend.

It is built on the `MercuryTechnologies/claude` SDK for the wire types and
`servant-client` for transport, which is where the typed error classification
comes from: a `ClientError` carries the status, `Retry-After`, and body that
`Baikai.Error`'s classifiers turn into a category.

Response-header capture is an **allow-list** — `request-id`, `x-request-id`,
`cf-ray`, in that preference order — not a denylist, so a header a future gateway
adds is not recorded by default. Those identifiers, along with the model
Anthropic reports in `message_start`, are what let this transport reach
`model_observed` in [CAP-19 — verifiable model-call
evidence](model-call-evidence.md).

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
import Baikai.Provider.Claude.Api qualified as ClaudeApi

ClaudeApi.register   -- or registerWith config, or registerWithRegistry
```

## Limits

- Image blocks inside a **tool result** are rejected rather than silently
  dropped. The refusal is deliberate; the consequence is that multimodal tool
  results are not expressible.
- `fully_observed` evidence is unreachable on this transport, because Anthropic
  does not echo the thinking configuration it applied. A 2xx status never raises
  evidence strength either — acceptance is not execution.
- **The base URL is the API root**, without the version segment: baikai appends
  `/v1/messages` itself, and a trailing `/v1` is removed rather than doubled. A
  base URL with no scheme, a scheme other than `http`/`https`, credentials, a
  query string, a fragment, or a path that is already an endpoint is refused as
  an `InvalidRequest` before a key is read. Query strings stay unsupported: a
  host needing one has to be fronted by a gateway.
- **A redirect is never followed.** A 3xx is delivered as the terminal error
  carrying its status, because following one would re-send the `x-api-key`
  header to whatever host the `Location` names.
- **Sampling parameters follow the model generation.** `temperature` and `top_p`
  are omitted for a generation whose catalog record says it rejects them (the
  adaptive-era ones return a 400), and the omission is recorded as
  `sampling_dropped_unsupported_model`. `seed`, `frequencyPenalty` and
  `presencePenalty` have no Messages API field on any generation and are recorded
  as `sampling_dropped_unsupported_api`. `Options.metadata` is not forwarded.
- **A one-hour cache write is priced at the five-minute rate.** The API reports a
  single `cache_creation_input_tokens` with no per-TTL split, and the catalog
  carries one `cacheWriteCost`, so the dollar cost of a `CacheRetentionLong` write
  is under-stated. Token counts are unaffected.
- A model whose `maxOutputTokens` is `0` sends `max_tokens = 1024` rather than
  `0`, which Anthropic rejects. An explicit `Options.maxTokens` of `Just 0` is
  forwarded as written.
- The `ClientEnv` cache is process-global, unbounded, shared with the
  OpenAI-compatible backend and the embeddings client, and keyed per normalised
  base URL. A fleet of per-tenant base URLs is not a supported use of
  `Model.baseUrl`.
- `Baikai.Provider.Claude.Internal.*` is exposed for provider tests and debugging
  and is documented as outside the PVP contract. `mapRequest` in particular
  changed shape in 0.5.0.0.
- The four `Sse` streaming entry points each take a response-metadata callback
  added in 0.5.0.0; pre-0.5 call sites need `(\_ -> pure ())` inserted.
- Everything above is proven against recorded frames and hand-built requests. No
  offline test contacts Anthropic; live behaviour is covered only by
  `baikai-smoke`, which needs `ANTHROPIC_API_KEY`.
