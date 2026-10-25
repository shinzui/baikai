---
title: "Context-tiered cache-write duration pricing"
type: Capability
description: "Resolve a whole-request input-context tier and select that same tier's long cache-write rate, so context thresholds and cache duration are priced together."
generated:
  by: codex/gpt-6
  at: "2026-10-10T23:26:03Z"
capabilityId: CAP-26
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.8.0.0"
packages:
  - baikai
interface:
  - Baikai.Model
  - Baikai.Cost.Pricing
requires:
  - CAP-7
  - CAP-12
evidence:
  - kind: test
    resource: baikai-openai/test/NativeCacheSpec.hs
    proves: "Native prefix shaping and public dispatch preserve replay, refuse unsupported controls before credentials, and use effective-duration pricing with explicit estimates; synthetic Long fixtures do not establish provider support."
  - kind: test
    resource: baikai/test/PricingPolicySpec.hs
    proves: "Haiku-shaped short and long write rates below, at, and above 100,000 tokens; disjoint cache counters contribute to the threshold; missing tier long rates reject and legacy JSON without the new key decodes."
  - kind: module
    resource: baikai/src/Baikai/Cost/Pricing.hs
    proves: "resolveRates selects the complete tier and its long write rate together, applying the policy-level long rate only below all tiers."
  - kind: module
    resource: baikai/src/Baikai/Model.hs
    proves: "InputPriceTier.longCacheWriteCost and validation of nonnegative, complete long-duration tier policies."
---

# Context-tiered cache-write duration pricing

This builds on [CAP-7 — usage and cost accounting](usage-and-cost-accounting.md)
and [CAP-12 — prompt-cache retention control](prompt-cache-retention.md).
Before `baikai 0.8.0.0`, the policy-level long rate overwrote every selected
tier's cache-write rate; a distinct long rate for a crossed tier was impossible.

## Shape

```haskell
import Baikai.Cost.Pricing (resolveRates)
import Baikai.Models.Generated qualified as Models
import Baikai.Usage (zeroUsage)

let usage = zeroUsage & #cacheWriteTokens .~ 100001
print (resolveRates (Just CacheRetentionLong) Models.anthropic_claude_haiku_5_5 usage)
```

Thresholds are exclusive and count fresh input, cache reads, and cache writes
together. The selected tier supplies all rates for the entire request. Long
retention selects its `longCacheWriteCost`; below every tier, it selects the
policy-level long rate. Haiku 5.5 thus uses $1 per million long-write tokens
above 100,000 input tokens and $0.20 below or at the threshold.

## Limits

- `InputPriceTier` gains a third constructor argument. Positional constructions
  must supply it when upgrading to 0.8.0.0.
- Legacy tier JSON without the field decodes as `Nothing`. A policy that names
  a policy-level long rate must also name a long rate on every tier; otherwise
  validation rejects it rather than silently using an incorrect rate.
- The duration is the shaped request's retention. Catalog rates remain an
  accounting estimate; the provider invoice is the authority.

## Native prompt caching (unreleased)

Endpoint-specific catalog policy gates native retention and stable system-prefix
breakpoints. Modern Short uses `30m`; absent/None controls preserve wire shape
while the documented modern default supplies Short for pricing. Long requires
verified endpoint support plus base and every tier's long-write rate. It remains
disabled in curated modern bindings. Legacy `24h` uses base write pricing without
a modern premium. Unknown duration with reported writes and duration-sensitive
rates is an explicit estimate; conflicting duration details mark usage inconsistent.

`NativeCacheSpec` verifies request capture, public dispatch and exact synthetic
prices offline. OpenAI live reuse remains pending: the 2026-10-25 Responses
probe returned HTTP 429 quota exhaustion. See the [caching guide](../user/prompt-caching.md)
for isolated endpoint checks and the supported policy matrix.
