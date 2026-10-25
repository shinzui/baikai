---
title: Pricing policies and calculation bases are explicit
status: accepted
date: 2026-09-07
---

# Pricing policies and calculation bases are explicit

## Context

Four per-million-token rates cannot express Astra's whole-request context tier
or Fable's two cache-write durations. A numeric zero also cannot tell a caller
whether a provider reported no writes or omitted the counter. Local arithmetic
must disclose incomplete billing facts without changing the token categories.

## Decision

`Model.cost` remains the base price record. Optional `Model.pricingPolicy`
contains ordered, exclusive `inputAbove` thresholds with complete replacement
rates and an optional `longCacheWriteCost`. The context measure is the sum of
all disjoint input categories, including cache reads and writes. The selected
tier prices the full request. Policies reject duplicate or unordered thresholds
and negative rates. Catalog JSON uses exact decimal prices; generated runtime
records use `Rational`. Missing policies in older Model JSON decode as absent.

`computeCost` remains the standard calculation entry point. `resolveRates` and
`computeCostWith` accept a cache duration selected by request shaping. The
provider adapter must supply actual shaping and billing facts, rather than
assuming the user's preference was accepted. `computeCostForService` reads actual service/speed observations from usage,
separately from a requested tier. Standard service uses catalog rates; missing or
uncurated products keep a standard-rate estimate with a reason. The lower-level
`computeCostAtRates` prices a resolved rate set once and labels its source
`ResolvedTokenRates`. Fast-mode pricing uses the same arithmetic path after
resolving policy rates, never multiplying an already computed amount.

`Cost.basis.sources` distinguishes standard token calculations from a total
reported by a provider tool. Nonempty `estimateReasons` makes missing knowledge
explicit. Aggregation unions both sets, so adding a fully known component never
hides an estimated component. The additive zero has an empty basis. Neither a
standard calculation nor a subprocess-reported total is described as an invoice.

Evidence schema 2.2 adds the local calculation basis to serialized cost. As
established in schema 2.0, locally calculated amounts and pricing metadata stay
outside the provider response commitment. Raw usage availability is a separate
provider fact. `Usage.availability` carries missing categories, inconsistency
and a set of observed service/speed/server-tool facts
into serialized usage and its canonical envelope. Its absence preserves the
legacy six-field envelope. API adapters annotate normalized usage even when all
counts are missing; evidence marks a wholly unreported block unobserved, and
preserves a partial observation together with its missing categories.

## Consequences

The public Model and Cost records gain fields and require PVP review before
release. Existing flat models retain their numeric totals. Unknown prices retain
the numeric zero but now carry a pricing-unavailable reason. Reasoning tokens
remain an informational subset of output tokens and are never charged again.

Implementation provides validated catalog policies, exact arithmetic,
calculation provenance and aggregation, plus shared usage normalization in Chat,
Responses and Claude. Cumulative snapshots replace reported counters and retain
earlier categories omitted by a later snapshot. Claude prices cache writes from
the marker in the shaped request body, so compatibility downgrades also change
the applied write price. Successful and failed trace terminals and call-log records carry optional
basis and availability; OpenTelemetry exports their canonical JSON. Empty
additive-zero bases are omitted, preserving existing no-pricing trace output.
An error terminal retains the response's partial billing in both traces and
OpenTelemetry; synthetic aborts have no terminal usage to report and leave it
absent.
Missing usage and reported zero remain distinct. Standard token calculations
exclude server-side tool products and uncurated service/speed prices explicitly.
The provider adapters issue one shaped cache duration per call; a mixed-duration
breakdown is outside the current SDK-backed mapping. This decision does not
claim provider invoice reconciliation or live verification, which belong to the
focused acceptance work in plan 77.

## Fast speed selection (2026-09-07)

`Model.fastModeCost` is optional and missing legacy JSON decodes as absent.
`computeCostAtSpeed` is an explicit calculation, not a provider observation;
standard speed agrees exactly with `computeCost`. Fast speed applies the
premium/base ratio for each category to the context- and duration-resolved
rates before pricing once. Undefined ratios (a zero base with a nonzero
resolved policy rate) are rejected as invalid policy. This composes long cache
writes with premium pricing; the two curated Opus models carry their standard
long-cache rate as well as fast rates. Missing fast prices retain the standard
amount with `UnsupportedSpeed`, never a fabricated free call.

Terminal pricing selects fast rates only from `Usage` billing observations.
An accepted fast request whose response omits speed retains a standard-rate
estimate marked `SpeedNotReported`. Contradictory speed observations retain a
standard estimate marked `InconsistentUsage`. These states preserve the split
between preference and observation required by ADR 0002.

## Long cache-write rates belong to the tier (2026-10-10)

Claude Haiku 5.5 is the first model whose price has both a prompt-length tier
and a one-hour cache-write rate, and its one-hour rate changes with the tier:
$0.20/M up to 100,000 prompt tokens and $1/M above. A single policy-level
long rate that overrides whichever tier was selected would bill the larger
prompt five times too low without any estimate reason.

`InputPriceTier` therefore carries an optional absolute `longCacheWriteCost`.
`resolveRates` takes the long rate from the same place as the other rates:
the policy-level value while no tier is crossed, and the crossed tier's own
value otherwise. The rate stays an absolute decimal price transcribed from the
provider's table, not a multiplier of the input rate, so no provider's billing
rule enters the neutral pricing record. Tier JSON without the key decodes as
absent, and catalog JSON emits the key only when a tier has a value.

A policy that has a policy-level long rate must give every tier one. Validation
rejects the combination with "Every input tier must state its long cache-write
rate when the policy has one", because a missing tier rate would otherwise fall
back silently to the lower tier's price. Tier long rates must be nonnegative.
Adding the field changes the exported `InputPriceTier` constructor, so it ships
in a major release. Plan 91 records the implementation.

## OpenAI cache duration follows preparation (2026-10-25)

The native OpenAI cache plan supplies wire controls, prefix placement and the
pricing duration together. Modern models have a documented Short default even
without explicit controls. Legacy `24h` has no modern write premium and uses base
write prices. A modern Long capability requires a base long rate and a long rate
for every input tier; preparation refuses missing rates before credentials.

When reported writes have unknown duration and rates depend on duration, the
provider adds `CacheDurationNotReported` to its standard-rate estimate. Shared
pricing helpers retain their legacy default behavior. Reported duration counters
check aggregate writes and the prepared uniform TTL; they never add writes again.
Conflicting totals, invalid counters or another duration mark usage inconsistent.
Partial and repeated cumulative snapshots retain the same checks and pricing on
both successful and error terminals. Synthetic Long fixtures establish arithmetic
and plumbing without claiming provider support or invoice reconciliation.
