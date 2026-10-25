---
title: "Prompt-cache retention control and cache accounting"
type: Capability
description: "Ask for short or long prompt-cache retention with one provider-agnostic preference that maps onto each host's own primitive, downgrades transparently where long retention is unsupported, and reports cache-read and cache-write tokens back as disjoint billed classes."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-12
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.CacheRetention
requires:
  - CAP-1
  - CAP-7
evidence:
  - kind: test
    resource: baikai-openai/test/NativeCacheSpec.hs
    proves: "Catalog-gated native controls, identical stable prefixes across fresh questions, public complete/stream dispatch, local refusal, synthetic duration pricing and content-free evidence; this is offline evidence, not a live cache-hit claim."
  - kind: test
    resource: baikai-claude/test/ShapeSpec.hs
    proves: "System, last-tool and automatic markers share the effective TTL, including long-retention downgrade; empty system text is preserved and the tool-marker flag gates only tools."
  - kind: test
    resource: baikai-openai/test/BillingSpec.hs
    proves: "Reported cache reads and writes are normalized once, missing categories and inconsistent counts are explicit, and repeated snapshots preserve cumulative totals."
  - kind: test
    resource: baikai-claude/test/SseSpec.hs
    proves: "Fable write costs follow the shaped TTL, including a compatibility downgrade, and observed billing facts survive terminal snapshots."
  - kind: example
    resource: baikai-smoke/test/CacheSmoke.hs
    proves: "A live sequence checks cache writes, an identical-request hit, and a shared-system-prefix hit with a different first question, including nonzero cache costs."
  - kind: guide
    resource: docs/user/prompt-caching.md
    proves: "The CacheRetention preference, the host-aware long/short downgrade, and how to read the cache token and cost split back off Usage."
---

# Prompt-cache retention control and cache accounting

`CacheRetention` has three values — `None`, `Short`, `Long` — and each provider
maps them to its own primitive. Anthropic's `Short` is the ephemeral
`cache_control` marker with no TTL; `Long` asks for `ttl: "1h"`. Anthropic-style hosts that lack long retention downgrade to short. Native
OpenAI bindings refuse unsupported explicit preferences locally.

The accounting half matters as much as the request half. Cache-read and
cache-write tokens come back on `Usage` as their own disjoint classes and are
priced separately, so a consumer can see what caching actually saved rather than
inferring it. A compatible host that over-reports cached tokens relative to its
own prompt total is clamped and marked inconsistent; missing counts remain
unknown in the cost basis. Fable writes use the cache duration in the actual
request body, so a host downgrade also changes the write rate.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md) and reports through
[CAP-7 — usage and cost accounting](usage-and-cost-accounting.md).

## Shape

```haskell
let opts = emptyOptions & #cacheRetention .~ Just CacheRetentionLong
resp <- completeRequest model ctx opts
print (resp ^. #message . #usage . #cacheReadTokens)
print (resp ^. #message . #usage . #cost . #basis)
```

## Limits

- **Provider-specific behavior.** Claude can downgrade long retention when
  the host lacks support; Responses rejects unsupported retention preferences
  before dispatch. The shaped marker determines the applied write price. A
  preference does not guarantee a cache hit.
- The Anthropic path places an automatic marker plus explicit markers on a
  non-empty system prompt and the last tool definition, at most three slots.
  Only the tool marker is gated by `supportsCacheControlOnTools`. All markers
  use the same effective TTL, including a long-to-short downgrade.
- Native OpenAI controls use an optional endpoint-specific `NativeCachePolicy`.
  Modern Short emits `30m` and one non-empty system-prefix breakpoint, preserving
  implicit caching. Responses moves the original instruction into exactly one
  developer input block; Chat preserves its instruction role. Legacy bindings
  emit only supported `in_memory` or `24h` values and no breakpoint. Native
  unsupported preferences fail before credentials; absent policy preserves legacy
  Responses behavior and disables native Chat controls. Compatible Anthropic
  markers retain their long-to-short downgrade.
- Modern Long stays disabled while `12h` endpoint support is unverified. The
  2026-10-25 Responses probe returned quota exhaustion, not acceptance or usage.
  Offline native tests prove serialization, dispatch, pricing and redaction;
  OpenAI live shared-prefix reuse remains pending.
- Whether a cache hit actually occurs depends on prefix stability, host policy,
  and timing. baikai reports what the host said it did; it cannot make a hit
  happen.
- The offline evidence covers request shaping and token arithmetic. That caching
  saves money end to end is proven only by `CacheSmoke`, which needs live
  credentials.
