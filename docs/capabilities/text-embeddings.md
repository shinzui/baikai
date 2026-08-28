---
title: "Text embeddings over an OpenAI-compatible endpoint"
type: Capability
description: "Call /v1/embeddings against OpenAI or any host that speaks its shape through a small policy-free IO client that resolves its key per host through the same table as chat calls and shares their connection cache, with a total accessor for the common single-vector case."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-6
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.1.0"
packages:
  - baikai
interface:
  - Baikai.Embedding
evidence:
  - kind: test
    resource: baikai/test/EmbeddingSpec.hs
    proves: "The hermetic request-mapping case asserts that input text, model id, and dimensions land where the OpenAI /v1/embeddings wire expects them, and that an empty data array decodes to a typed decodeError rather than crashing on an empty vector. The key-resolution cases assert that a DeepSeek base URL resolves DEEPSEEK_API_KEY rather than OPENAI_API_KEY, that an unknown host refuses with an AuthError naming EmbeddingModel.apiKey instead of sending OpenAI's key, that an explicit source still wins, and that two spellings of one host add exactly one entry to the shared connection cache."
  - kind: module
    resource: baikai/src/Baikai/Embedding.hs
    proves: "The whole surface: EmbeddingModel, openAIEmbeddingModel, mkEmbeddingRequest, embed / embedOne, and the total firstEmbedding accessor."
---

# Text embeddings over an OpenAI-compatible endpoint

`Baikai.Embedding` is a small client for the OpenAI-shaped `/v1/embeddings`
endpoint. An `EmbeddingModel` is a bare provider model id plus a base URL — there
is deliberately no `Api` tag and no chat-catalog entry, because none of a chat
`Model`'s fields (context window, output cap, chat pricing, modalities) mean
anything for embeddings.

It resolves its key through baikai's `Baikai.Auth`, using the **same per-host
table as chat calls**: `EmbeddingModel.apiKey` is `Maybe ApiKeySource`, and
`Nothing` means the conventional variable for the model's host. A host the table
does not know refuses with an `AuthError` naming `EmbeddingModel.apiKey` rather
than falling back to another provider's credential — which is what it did
before, sending `OPENAI_API_KEY` to whatever host the base URL happened to name.
An explicit source still wins.

It also shares the process-global connection cache in `Baikai.Http` with the
chat providers, so repeated embedding calls to one host reuse one TLS manager
instead of allocating one per call.

`firstEmbedding` is total: the common "one input, one vector" case does not
require indexing into a vector that might be empty.

The client is policy-free plain `IO` — no effect binding, no retry policy, no
registry. That is the same layering choice `baikai-effectful` makes for the chat
transport: policy belongs a layer up.

## Shape

```haskell
import Baikai.Embedding (embedOne, openAIEmbeddingModel)

embedOne (openAIEmbeddingModel "text-embedding-3-small") "some text"
```

## Limits

- **Not part of the registry.** Embeddings do not dispatch through
  [CAP-1](unified-provider-calls.md), carry no `Api` tag, and are not reachable
  through `completeRequest`. Tracing, cost accounting, and evidence do not cover
  them.
- **OpenAI wire shape only.** Anthropic has no embeddings endpoint and there is
  no Anthropic path here. Other hosts work exactly to the extent they mimic
  OpenAI's request and response bodies.
- No cost accounting. `EmbeddingModel` carries no prices, so an embedding call
  produces no `Usage` and no `Cost`.
- Round-trip evidence is still thin: the offline cases cover request mapping,
  key resolution and connection sharing, but the only test that actually reaches
  a host is gated behind `BAIKAI_EMBEDDING_LIVE=1` and does not run in a default
  `cabal test`. There is no smoke case, no batching test, and no user guide —
  the module header is the documentation.
- The connection cache is unbounded and keyed per normalised base URL, so a
  fleet of per-tenant base URLs is not a supported use of
  `EmbeddingModel.baseUrl`.
