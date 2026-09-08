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
`ResolvedTokenRates`; plan 69 can use it for catalog-owned fast prices after rate
selection rather than multiplying an already computed amount.

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
