---
title: "Provider-neutral closed-set judgments"
type: Capability
description: "Compile closed-set schemas, order questions, refuse unsupported generation controls and validate provider-neutral judgment answers."
generated:
  by: codex/gpt-6
  at: "2026-10-25T13:31:23Z"
capabilityId: CAP-29
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.9.0.0"
packages: [baikai]
interface: [Baikai.Judgment, Baikai.Model]
requires:
  - CAP-28
evidence:
  - kind: test
    resource: baikai/test/JudgmentSpec.hs
    proves: "Schema subset, question ordering, typed refusal paths, strict answers and judgment-only catalog facts."
---

# Provider-neutral closed-set judgments

Builds on [CAP-28 — structured answer content](structured-answer-content.md).

## Shape

```haskell
import Baikai.Judgment (compileJudgments, judgmentList)

case compileJudgments (jsonSchemaFormat "ticket" personSchema) of
  Left problem -> print problem
  Right questions -> print (judgmentList questions)
```

## Contract

Earlier versions have no neutral judgment compiler or validation protocol.
Boolean predicates, distinct string choices and contiguous zero-based integer
scores are supported. The schema determines question order; unsupported keywords
produce typed request problems. `prepareJudgment` combines request validation
with generation-control refusal; `validateAnswers` preserves the provider's
chosen values, confidence and expected scores.

`isJudgmentOnly` reads the model's catalog-owned output kind. Consumers can
route before applying generative defaults without matching provider names.
This vocabulary performs no network call and embeds no retry policy.
