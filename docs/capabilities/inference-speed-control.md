---
title: "Inference speed preference and speed-aware pricing"
type: Capability
description: "Ask for fast inference with one provider-neutral Options.speed, have it sent only to models whose catalog entry advertises it and dropped with recorded evidence everywhere else, and price the result at the speed the provider says actually ran rather than the one that was requested."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T00:00:00Z"
capabilityId: CAP-24
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.7.0.0"
packages:
  - baikai
  - baikai-claude
interface:
  - Baikai.Speed
  - Baikai.Options
  - Baikai.Cost.Pricing
  - Baikai.Compat
requires:
  - CAP-3
  - CAP-7
  - CAP-19
evidence:
  - kind: test
    resource: baikai-claude/test/ShapeSpec.hs
    proves: "The request half end to end: a fast request on claude-opus-5 carries speed \"fast\" and the anthropic-beta fast-mode header; the same request on claude-sonnet-5 omits the field and records the drop as an evidence adjustment; an explicit standard request sends nothing; and a caller-supplied beta header overrides both the model's and the automatic fast header."
  - kind: test
    resource: baikai/test/CostSpec.hs
    proves: "computeCostAtSpeed prices a fast call at the catalog's fast rates — twice standard for the models that publish them — falls back with an InvalidPricingPolicy estimate reason for a negative or undefined ratio, and agrees with computeCost when the requested speed is standard."
  - kind: test
    resource: baikai/test/PricingPolicySpec.hs
    proves: "A model whose catalog entry prices only standard inference matches an observed standard call exactly, while a fast call against it remains an explicit estimate rather than a silent standard-rate answer; an unavailable price carries an explicit estimate reason."
  - kind: test
    resource: baikai/test/EvidenceSpec.hs
    proves: "FastModeDroppedUnsupportedModel round-trips through the evidence schema as fast_mode_dropped_unsupported_model and is classified as a non-fatal adjustment, so a dropped fast request is visible without failing the call."
  - kind: module
    resource: baikai/src/Baikai/Speed.hs
    proves: "The whole vocabulary: Speed with SpeedStandard and SpeedFast, and its JSON encoding."
---

# Inference speed preference and speed-aware pricing

Anthropic sells the same model at two speeds. Asking for the faster one is a
request-shaping detail (a field plus a beta header), a catalog question (which
models actually offer it), and a billing question (fast tokens cost more) all at
once. `Options.speed` is the single knob; baikai owns the other three parts.

## Shape

```haskell
import Baikai.Models.Generated qualified as Models

-- SpeedFast comes from Baikai, which re-exports Baikai.Speed.
-- sent on a model whose catalog entry advertises fast mode; dropped with a
-- FastModeDroppedUnsupportedModel evidence adjustment on one that does not
let opts = emptyOptions & #speed .~ Just SpeedFast
completeRequest Models.anthropic_claude_opus_5 ctx opts
```

## What the request does

For a model whose catalog entry sets `supportsFastMode`, the Anthropic transport
sends `speed: "fast"` and adds the `anthropic-beta: fast-mode-2026-02-01` header.
For a model that does not, it sends **neither** and records a
`FastModeDroppedUnsupportedModel` adjustment on the [CAP-19 evidence
record](model-call-evidence.md). The call succeeds; the drop is visible.

That asymmetry is the point. Sending an unrecognised field to a model that does
not support it is the kind of thing a provider may accept today and reject
later, so baikai refuses to guess. Equally, failing the call would make `speed`
unusable in any program that talks to more than one model. Every other provider
omits it: the OpenAI transports have nothing to map it to.

A caller who sets their own `Anthropic-Beta` header wins — the automatic fast
header does not overwrite it.

## What the pricing does

A request is a preference. Only the provider's usage report says which speed
actually ran, so `computeCostAtSpeed` prices the **observed** speed, and the
catalog carries fast rates per model rather than assuming a multiplier. Where
the provider does not report a speed, the result is an explicit estimate with a
reason attached to `Cost.basis` — not a standard-rate number presented as fact.
A model whose catalog entry prices only standard inference stays an estimate for
a fast call rather than silently answering at standard rates.

This builds on [CAP-3 — the generated model catalog](generated-model-catalog.md),
which owns `supportsFastMode` and the fast rates, and extends [CAP-7 — usage and
cost accounting](usage-and-cost-accounting.md) with the observed-speed basis.

## Limits

- **Anthropic only, and only two models.** `claude-opus-5` and `claude-opus-4-8`
  advertise fast mode in the shipped catalog. Every other model — including every
  OpenAI model and every compatible host — drops the request.
- **The beta header is a pinned date string.** When Anthropic graduates fast mode
  out of beta or moves the date, that is a catalog and transport change, not
  something a caller can configure around.
- **Fast is a request, not a guarantee.** Nothing in the API promises the fast
  path was taken; the usage report is the only evidence, and a provider that
  reports no speed leaves the cost an estimate.
- **Published fast rates are twice standard** for the models that have them, but
  baikai reads the rate from the catalog rather than applying a factor, so a
  future model priced differently needs a catalog refresh, not a code change.
- `Speed` has exactly two constructors. There is no vocabulary for a provider
  that offers three tiers, and adding one would be a major bump.
- The CLI and interactive providers ignore `speed` entirely — the coding-agent
  tools expose no such control.
