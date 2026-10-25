---
title: "Explicit reasoning off with truthful fallback evidence"
type: Capability
description: "Request reasoning off distinctly from leaving provider defaults untouched, with catalog-gated translation, recorded substitutions and strict refusal before dispatch."
generated:
  by: codex/gpt-6
  at: "2026-10-25T17:37:51Z"
capabilityId: CAP-31
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.10.0.0"
packages: [baikai, baikai-claude, baikai-openai]
interface: [Baikai.ThinkingLevel, Baikai.Options, Baikai.Compat]
requires:
  - CAP-11
  - CAP-19
evidence:
  - kind: test
    resource: baikai/test/ThinkingLevelSpec.hs
    proves: "Explicit none parses and renders distinctly from positive effort levels."
  - kind: test
    resource: baikai-claude/test/ThinkingSpec.hs
    proves: "Catalog-supported disabled thinking has no budget, effort or display; unsupported off requests retain fallback evidence."
  - kind: test
    resource: baikai-openai/test/ShapeSpec.hs
    proves: "Native accepted-effort policies and compatible toggles translate none without silently treating absence as off."
  - kind: test
    resource: baikai/test/StrictEvidenceSpec.hs
    proves: "Strict evidence refuses a substituted off request before dispatch."
---

# Explicit reasoning off with truthful fallback evidence

Extends [CAP-11 — reasoning-effort control](reasoning-effort-control.md) and
uses [CAP-19 — model-call evidence](model-call-evidence.md) to distinguish
requested, translated and observed reasoning. Earlier releases cannot request
off: an absent `thinking` preference leaves the provider's default in force.

## Shape

```haskell
let opts = emptyOptions & #thinking .~ Just ThinkingNone
completeRequest model ctx opts
```

## Contract

Requires `baikai 0.10.0.0` with `baikai-claude 0.7.3.0` or
`baikai-openai 0.7.3.0` for the corresponding transport. Claude Messages sends
`thinking: {"type": "disabled"}` only when the catalog establishes support.
Native OpenAI Chat and Responses send `none` where accepted; Z.ai and Qwen
send `enable_thinking: false`.

Unsupported requests retain their adjustments; strict evidence refuses a
substitution before dispatch. A host with no thinking controls does not
establish that reasoning is disabled. The translated wire setting proves
what was requested, not what the server executed. No live claim follows from
the offline tests.
