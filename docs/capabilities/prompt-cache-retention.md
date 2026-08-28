---
title: "Prompt-cache retention control and cache accounting"
type: Capability
description: "Ask for short or long prompt-cache retention with one provider-agnostic preference that maps onto each host's own primitive, downgrades transparently where long retention is unsupported, and reports cache-read and cache-write tokens back as disjoint billed classes."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
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
    resource: baikai-claude/test/ShapeSpec.hs
    proves: "The cache marker lands on the last tool definition with the requested ttl, and supportsCacheControlOnTools gates whether tool cache markers are emitted at all."
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "Cached prompt tokens map into baikai's disjoint fields, computeCost bills each token class exactly once, a compatible host that over-reports cached tokens is clamped, and absent cache details produce no cache tokens."
  - kind: example
    resource: baikai-smoke/test/CacheSmoke.hs
    proves: "A live two-call sequence against a real provider where the second call reports cache-read tokens."
  - kind: guide
    resource: docs/user/prompt-caching.md
    proves: "The CacheRetention preference, the host-aware long/short downgrade, and how to read the cache token and cost split back off Usage."
---

# Prompt-cache retention control and cache accounting

`CacheRetention` has three values — `None`, `Short`, `Long` — and each provider
maps them to its own primitive. Anthropic's `Short` is the ephemeral
`cache_control` marker with no TTL; `Long` asks for `ttl: "1h"`. A host that does
not advertise long retention gets a transparent downgrade to short rather than a
rejected request, and a host with no prompt caching at all ignores the preference.

The accounting half matters as much as the request half. Cache-read and
cache-write tokens come back on `Usage` as their own disjoint classes and are
priced separately, so a consumer can see what caching actually saved rather than
inferring it. A compatible host that over-reports cached tokens relative to its
own prompt total is clamped rather than trusted.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md) and reports through
[CAP-7 — usage and cost accounting](usage-and-cost-accounting.md).

## Shape

```haskell
let opts = emptyOptions & #cacheRetention .~ Just CacheRetentionLong
resp <- completeRequest model ctx opts
print (resp ^. #message . #usage . #cacheReadTokens)
```

## Limits

- **A preference, not a contract.** `Long` silently becomes short wherever
  `supportsLongCacheRetention` is false, and the whole preference is ignored by
  hosts with no caching. The request does not fail and nothing in the `Response`
  says the downgrade happened.
- The Anthropic path is the fully realised one — cache markers on content and on
  the last tool definition, gated by `supportsCacheControlOnTools`. Elsewhere the
  capability is mostly the *accounting* half.
- On the OpenAI-compatible transport a marker is emitted only where the host's
  compat record sets `cacheControlFormat = Just CacheControlFormatAnthropic` —
  OpenRouter in the shipped table. `api.openai.com` gets no marker at all,
  because Chat Completions caches automatically and exposes no retention
  control, so on that host the capability is the accounting half only.
- Whether a cache hit actually occurs depends on prefix stability, host policy,
  and timing. baikai reports what the host said it did; it cannot make a hit
  happen.
- The offline evidence covers request shaping and token arithmetic. That caching
  saves money end to end is proven only by `CacheSmoke`, which needs live
  credentials.
