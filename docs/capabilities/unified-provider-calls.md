---
title: "Provider-neutral model calls with registry dispatch"
type: Capability
description: "Write one blocking call — completeRequest — and dispatch it against Anthropic, OpenAI, any OpenAI-compatible host, a local coding-agent CLI, or a handler you registered yourself, chosen by the Model value rather than by a different code path."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-1
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai
  - Baikai.Api
  - Baikai.Model
  - Baikai.Context
  - Baikai.Options
  - Baikai.Response
  - Baikai.Provider
  - Baikai.Provider.Registry
evidence:
  - kind: test
    resource: baikai/test/SurfaceSpec.hs
    proves: "The public record surface — Model, Context, Options, Response, Tool — is buildable from the exported empty/zero bases and selectors alone, with no exported constructors."
  - kind: test
    resource: baikai/test/HelpersSpec.hs
    proves: "Registry behaviour a consumer depends on: newProviderRegistryFrom's last-wins rule for duplicate Api tags, assertRegistered's pass/throw contract, mkModel's dispatch discriminators, and the ApiKeyEnvChain resolution order."
  - kind: test
    resource: baikai/test/ContextSpec.hs
    proves: "Context is a lawful monoid (identity, associativity, first-system-prompt-wins) and the message helpers append in order without inventing timestamps."
  - kind: guide
    resource: docs/user/getting-started.md
    proves: "The whole adoption path: add the dependency, call a vendor package's register, build a Context and Options, and read text back out of a Response."
  - kind: guide
    resource: docs/user/models-and-providers.md
    proves: "How Api-tag dispatch, the process-global convenience registry, an explicit ProviderRegistry, and Custom handlers relate."
---

# Provider-neutral model calls with registry dispatch

`completeRequest model context options` is the one blocking call. Which backend
serves it is decided by the `Model` value's `api` tag, looked up in a
`ProviderRegistry` that each vendor package populates through its own
`register :: IO ()`. Application code that switches from Claude to GPT changes
the `Model` it passes and nothing else — the request type, the response type,
the token accounting, and the error shape are the same on both sides.

A `Model` is data, not a class instance: it carries the API tag, base URL,
per-million-token costs, context window, output cap, and compatibility quirks.
So a host baikai has never heard of is reachable by filling in an `emptyModel`,
and an API baikai does not ship is reachable by registering a handler under
`Custom "your-tag"`.

Simple programs use the process-global registry. Tests and larger applications
build their own with `newProviderRegistry` and call `completeRequestWith`, which
keeps registration out of global state.

## Shape

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi

main :: IO ()
main = do
  OpenAIApi.register
  prompt <- userNow "Say hi."
  let ctx = emptyContext & #messages .~ V.singleton prompt
      opts = emptyOptions & #maxTokens .~ Just 32
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print (flattenAssistantText (flattenAssistantBlocks resp))
```

## Limits

- Evolvable records export no constructors. You build them from `emptyModel` /
  `emptyContext` / `emptyOptions` plus `generic-lens` record updates. Code
  written against the pre-0.3.0.0 constructors does not compile.
- Dispatch to an unregistered `Api` tag does not throw. It returns an
  error-shaped `Response` (or a terminal `EventError`) with category
  `ProviderUnavailable`, so a caller that never inspects `errorInfo` will read a
  dispatch failure as an empty answer.
- The registry is keyed by `Api` tag, not by model. Two hosts that both speak
  Chat Completions share one handler and are distinguished by the `Model`'s base
  URL, not by separate registrations.
- `Baikai.Prelude` is a convenience re-export of `lens` + `generic-lens` and is
  documented as outside the PVP stability contract; so is every `.Internal`
  module.
- The core package on its own can call nothing. It ships no transport; a vendor
  package must be depended on and registered.
