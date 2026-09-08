---
id: 76
slug: account-for-cache-writes-and-context-tier-model-pricing
title: "Account for cache writes and context-tier model pricing"
kind: exec-plan
created_at: 2026-09-07T23:27:02Z
intention: "intention_01m1z343ecehjv11zdr85d1ehe"
master_plan: "docs/masterplans/12-support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers.md"
---

# Account for cache writes and context-tier model pricing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Reported model costs will account for provider-reported cache writes and Astra's long-context rate threshold, with an explicit distinction between a calculation backed by available usage and an estimate missing billing facts. Existing flat-rate models will retain their current totals.


## Progress


- [x] Add optional validated Model pricing policies and explicit Cost calculation bases, preserving old model JSON decoding and cost aggregation laws.
- [x] Curate Astra context tiers and Fable long-write rates through fetch, catalog JSON and generated Haskell; fresh fetch changes only the intended policies.
- [x] Prove exact threshold/cache arithmetic against the generated models, including 5.44752 USD at 272001 input plus 100 output tokens.
- [x] Normalize raw Chat/Responses/Claude usage with explicit availability and commit those provider facts in evidence.
- [x] Price Fable writes using the cache marker in the shaped request; test both durations and compatibility downgrade.
- [x] Propagate successful-call calculation basis and availability into trace, call-log JSON and OpenTelemetry without changing empty-basis legacy traces.
- [x] Retain partial response billing on failed trace terminals and OpenTelemetry error spans; synthetic abort billing remains absent.
- [x] Integrate observed service tiers and the shared fast-mode seam.
- [x] Update trace/log consumers, capability examples and final documentation; complete all acceptance checks.


## Surprises & Discoveries


OpenAI's current prompt-caching guide explicitly subtracts both cached_tokens and cache_write_tokens from inclusive input_tokens to obtain ordinary input. Its documented examples distinguish a write from a read. Missing write fields must still remain unknown; the rate table cannot supply the missing count. Source: https://developers.openai.com/api/docs/guides/prompt-caching.

Fresh fetch output preserves all existing model fields and adds only the two curated pricing policies. The generator rejects malformed policy data before rendering.


## Decision Log


2026-09-07: Keep computeCost :: Model -> Usage -> Cost as the ordinary standard-rate entry point and add catalog-owned optional pricing rules. Unknown billed categories must be represented as estimation reasons rather than presented as observed zeroes.

2026-09-07: Use the total billable input context to select a context tier and apply that tier to the entire call, not only tokens beyond the threshold. Do not count reasoning tokens again on top of output tokens.


2026-09-07: [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) records policy validation and Cost basis aggregation. Schema 2.2 serializes local calculation metadata while retaining the schema 2.0 exclusion of local prices from provider commitments. Raw availability and billing observations are separate provider facts and join the canonical envelope; empty optional facts preserve legacy encodings.


## Outcomes & Retrospective


The implementation delivers catalog-owned context and cache-duration policies,
shared inclusive/exclusive usage normalization, explicit missing-category and
billing observations, and calculation bases that survive aggregation. Generated
Astra rates price the whole request above 272000 input tokens. Fable writes use
the actual shaped TTL, including compatibility downgrades. Unknown write counts,
inconsistent totals, missing service tiers, uncurated tier/speed products and
reported server-tool products remain explicit estimates instead of invoice claims.

`computeCost` remains the standard-policy entry point. `computeCostForService`
separates a requested tier from observed billing facts; `computeCostAtRates`
validates and prices one selected rate record with a `ResolvedTokenRates` source.
Plan 69 has no implemented speed selector yet and remains separately owned. Its
future selector can use this tested seam, including a two-times rate fixture,
without adding another multiplier to a computed cost or making a new speed option
part of this master plan.

Successful and failed trace terminals, call logs and OpenTelemetry carry the same
amounts and calculation bases as responses. Synthetic abort billing remains
absent. A CLI-reported zero total retains its reported-total source. Optional
billing facts join evidence schema 2.2 usage commitments, while empty facts keep
legacy availability encodings and the six-field legacy usage envelope unchanged.
The capability examples display cost bases and agree with their compiled twins.

Validation: 708 core tests, 276 OpenAI tests, 335 Claude tests and 10 OpenTelemetry
tests pass. `doc-shapes` passes all 20 Haskell comparisons and one KDL resolution
with its one declared skip. The 22-concept capability bundle validates. Catalog
regeneration is byte-identical to the committed generated module. `cabal build all` and `git diff --check` pass. EP-4 is complete. No paid live request
was made for arithmetic; focused live acceptance remains the next child's job.


## Context and Orientation


`baikai/src/Baikai/Usage.hs` defines the disjoint token classes and optional
availability/billing facts. `Baikai.Usage.Normalize` implements inclusive and
exclusive input accounting. `Baikai.Model` holds validated pricing policies;
`Baikai.Cost.Pricing` resolves context/duration rates and separates actual service
observations from caller requests. The shared OpenAI `Internal.Usage` parser feeds
both Chat and Responses, while Claude normalizes its SDK usage and preserves
facts across terminal snapshots. Trace and call-log consumers retain the resulting
basis and partial billing on failures.

As verified on 2026-09-07, Astra standard rates per million tokens are input 10, output 50, cache read 1, cache write 12.5. With more than 272,000 input tokens, the full request uses input 20, output 75, cache read 2 and cache write 25. Source: https://developers.openai.com/api/docs/models/gpt-6-astra. Fable 5.1 standard rates are input 10, output 50, cache read 0.25, five-minute writes 12.5 and one-hour writes 20, across its one-million-token context. Source: https://platform.claude.com/docs/en/models/fable-5-1/overview. A rate is not evidence that a write occurred.

The SDK at mori://MercuryTechnologies/openai/packages/openai has Responses InputTokensDetails containing only cached_tokens in local 2.5.4. Raw JSON extraction may be needed for newer billing fields, but their names and inclusive/exclusive semantics must be verified from the current API reference and real/sanitized response fixtures, not guessed from models.dev prices.

[ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) separates observed usage from requested settings; [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) keeps mapping facts in adapters. The existing docs/plans/69-send-anthropic-fast-mode-as-a-catalog-gated-request-option.md owns speed options and fast-mode multiplication; integrate a shared rate-selection seam instead of adding another speed option. No cross-repository ADR was needed.


## Plan of Work


### Milestone 1: Represent pricing rules and incomplete billing knowledge


Extend Model with an optional pricing policy containing strictly increasing input-token thresholds and complete ModelCost rate records for each tier. A threshold is exclusive: the base rate applies at 272000 and the higher Astra rate at 272001. Add a cache-write-duration rate override for Fable's one-hour writes. Preserve Model.cost as the base fallback and old JSON decoding when policy is absent. Add corresponding fetch/generator types and dated curation/overrides; reject duplicate/negative thresholds and invalid rates. Preserve these rules through a fetch round-trip.

Add an explicit cost calculation basis in baikai/src/Baikai/Cost.hs, distinguishing calculated standard-policy totals from estimates with reasons such as missing cache-write usage, unknown service tier or unavailable pricing. Propagate it through JSON and Semigroup combination: any estimated component makes the aggregate estimated and retains reasons. Zero usage observed is different from usage not reported. Update evidence serialization and canonical envelopes with deliberate compatibility/version tests rather than hiding new state outside the commitment. Do not call a locally calculated cost a provider-issued invoice.


### Milestone 2: Normalize raw usage without fabricating cache writes


Inspect current OpenAI Chat and Responses usage schemas and establish the actual billing-category contract in an offline fixture before changing arithmetic. Use the existing raw-object extraction seam where the SDK drops fields. Extract reported cache-write counts only under verified field names. When the endpoint does not expose write counts, preserve known counts and mark the calculation estimated; never derive writes as total minus cached reads without provider documentation that makes that identity valid.

Share normalization rules between baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs and the Responses transport from docs/plans/74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md. For inclusive input totals, subtract each reported cache category exactly once; for exclusive totals, sum them. Missing usage stays unobserved in evidence, while explicitly reported zero is observed. Reject or mark inconsistent totals instead of allowing Natural underflow or fabricating a plausible number. Preserve partial usage when a stream fails.

This plan can begin before Responses exists. Its core arithmetic and Chat normalization are independently testable; completing integration requires the Responses child.


### Milestone 3: Select rates once and propagate the result


Extend computeCost to select the applicable context policy from normalized total input categories, then calculate with exact Rational arithmetic. If the provider's threshold uses a distinct reported input measure, carry that measure in the calculation input and test it explicitly. Introduce a rate-resolution helper that accepts request cache duration and reported service tier separately; adapters call it when the simple standard computeCost entry point lacks needed context. Existing standard callers retain the simple entry point.

Apply Fable's one-hour write rate only when that duration was actually selected by request shaping and usage permits the calculation. Distinguish a requested tier from an observed tier. If they differ or the observed tier is absent, report the basis and estimate status rather than silently claiming a known invoice. Integrate plan 69's fast multiplier at this same rate-resolution seam exactly once. Additional paid tools and unsupported service-tier products remain explicitly outside calculated token cost.

Update providers, baikai-trace-otel, call-log output and any other consumers discovered with rg so stored evidence and displayed totals agree. Document base estimates versus tier-aware calculations in docs/user/prompt-caching.md and docs/user/model-call-evidence.md. Record the policy/basis decision in an ADR and list public record/JSON changes in CHANGELOG.md.


## Concrete Steps


Run from the repository root:

```bash
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test baikai-trace-otel
cabal test baikai-smoke:doc-shapes
git diff --check
```

Add focused cases to baikai/test/CostSpec.hs and UsageSpec.hs if present; otherwise create PricingPolicySpec.hs and register it in baikai/test/Main.hs and baikai/baikai.cabal. Provider wire tests live alongside existing usage/evidence tests. Expected output is all suites passing with exact rational assertions rather than approximate floats.


## Validation and Acceptance


Test 271999, 272000 and 272001 billable input tokens, including cases where the threshold is crossed by cache reads or writes. For 272001 uncached input and 100 output tokens, Astra standard cost must be 5.44752 USD (272001 times 20/M plus 100 times 75/M), not base pricing or pricing only the excess token. Fable 1000 cache-read tokens cost 0.00025 USD; 1000 cache-write tokens cost 0.0125 at five minutes and 0.02 at one hour. Reasoning counted within output never increases totalTokens twice.

A response with missing write counters produces an explicitly estimated cost, and one with an explicit zero counter records that distinction. Repeated terminal usage does not accumulate twice. Flat models with no pricing policy keep their previous results. Trace and evidence totals equal response totals and combined cost bases propagate incomplete knowledge. These acceptance checks are offline; no costly long-context live request is required.


## Idempotence and Recovery


Pricing fixtures require no credentials and are repeatable. Maintain backward decoding for absent policy fields. Do not change rates solely because a live invoice disagrees; establish request tier, TTL, observed counts and excluded tool charges first. If a required raw usage field is not documented, retain estimate status and record the limitation rather than inventing an extraction rule.


## Interfaces and Dependencies


This plan owns optional Model pricing policy, calculation-basis vocabulary, rate resolution and billing normalization availability. It integrates with the Responses child's prepared request and terminal usage; final completion requires both interfaces to agree. Model/gen changes also touch the capability plan's schema, which must preserve all existing compat fields. No dependency upgrade is assumed. Locate SDK sources through Mori and recheck registry releases before choosing any new bound.

Commits carry this file's ExecPlan trailer, the parent MasterPlan trailer and intention intention_01m1z343ecehjv11zdr85d1ehe.
