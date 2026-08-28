---
title: "effectful binding for the transport"
type: Capability
description: "Call baikai from effectful code through a dynamic Baikai effect with three operations — Complete, StreamCollect, StreamEach — and swap a real provider for a fake one by changing which interpreter runs, without a class, a monad transformer, or a policy decision baked into the binding."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-20
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai-effectful
interface:
  - Baikai.Effectful
requires:
  - CAP-1
  - CAP-2
evidence:
  - kind: test
    resource: baikai-effectful/test/CompleteSpec.hs
    proves: "The Complete operation dispatches through the interpreter and returns the stub provider's text, so the effect and its interpreter agree without a live provider."
  - kind: test
    resource: baikai-effectful/test/StreamSpec.hs
    proves: "streamCollect returns the whole event sequence and streamEach observes each event in order, so the streaming operations preserve baikai's event algebra through the effect boundary."
  - kind: test
    resource: baikai-effectful/test/StubProvider.hs
    proves: "That the binding is testable against a fake provider registered into an explicit registry — the substitution the capability exists to enable."
  - kind: module
    resource: baikai-effectful/src/Baikai/Effectful.hs
    proves: "The dynamic Baikai effect, its three operations, and the registry-backed interpreters."
---

# effectful binding for the transport

`baikai-effectful` is one module: a dynamic
[`effectful`](https://hackage.haskell.org/package/effectful) effect named
`Baikai` with three operations — `Complete`, `StreamCollect`, `StreamEach` — and
interpreters that run them against a `ProviderRegistry`. Application code written
in `Eff es` gets `complete`, `streamCollect`, and `streamEach` without importing
`streamly` or reaching for the process-global registry.

The binding is deliberately **thin and policy-free**. It adds no retries, no
fallbacks, no caching, and no cost budget; it exposes baikai's transport and
nothing else. That is the same layering choice `Baikai.Embedding` makes — policy
belongs a layer up, in the application or in a higher-level library.

The payoff is substitution. Because the interpreter takes the registry, a test
runs the same application code against a stub provider by interpreting with a
registry that has one registered, with no conditional in the code under test.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md) and
[CAP-2 — typed incremental streaming](typed-streaming.md), whose event algebra
`StreamCollect` and `StreamEach` carry through unchanged.

## Shape

```haskell
import Baikai.Effectful
import Effectful (Eff, (:>))

program :: (Baikai :> es) => Eff es Response
program = complete model ctx opts
```

## Limits

- Three operations, and that is the whole surface. Anything else in baikai —
  tracing, the cost log, evidence, embeddings, the agent surfaces — is used
  directly in `IO`, not through this effect.
- Policy-free means exactly that: no retry, no fallback, no budget. A consumer
  who wants those writes them above the effect.
- The package's release history is almost entirely `baikai` bound widening; its
  own API has not changed since 0.1.0.0. That stability is real but it also means
  the binding has not grown to cover the surfaces baikai added since.
- `LiveSpec` needs credentials and is skipped in a default run; the offline
  evidence is the stub-provider path.
