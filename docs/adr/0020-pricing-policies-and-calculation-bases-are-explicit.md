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
assuming the user's preference was accepted. Provider service-tier integration
belongs at this same rate-resolution boundary; it must not multiply prices twice.

`Cost.basis.sources` distinguishes standard token calculations from a total
reported by a provider tool. Nonempty `estimateReasons` makes missing knowledge
explicit. Aggregation unions both sets, so adding a fully known component never
hides an estimated component. The additive zero has an empty basis. Neither a
standard calculation nor a subprocess-reported total is described as an invoice.

Evidence schema 2.2 adds the local calculation basis to serialized cost. As
established in schema 2.0, locally calculated amounts and pricing metadata stay
outside the provider response commitment. Raw usage availability is a separate
provider fact. `Usage.availability` carries missing categories and inconsistency
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
earlier categories omitted by a later snapshot. Missing usage and reported zero
remain distinct. Observed service tiers, mixed cache durations and downstream
trace/log presentation remain work
in [plan 76](../plans/76-account-for-cache-writes-and-context-tier-model-pricing.md).
This decision does not claim those integrations or live billing verification
are complete.
