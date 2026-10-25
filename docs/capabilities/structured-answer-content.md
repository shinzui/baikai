---
title: "Structured answer content and persistence"
type: Capability
description: "Preserve structured input and answer values, probabilities and confidence through atomic streams, response codecs, traces and call logs."
generated:
  by: codex/gpt-6
  at: "2026-10-25T13:31:23Z"
capabilityId: CAP-28
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.9.0.0"
packages: [baikai]
interface: [Baikai.Content, Baikai.Response.JSON, Baikai.Stream]
requires:
  - CAP-1
  - CAP-2
evidence:
  - kind: test
    resource: baikai/test/DataContentSpec.hs
    proves: "Mixed content, atomic events, error recovery, named response codecs, traces and both log paths preserve answer evidence."
---

# Structured answer content and persistence

Builds on [CAP-1 — provider dispatch](unified-provider-calls.md) and [CAP-2 — typed streaming](typed-streaming.md).

## Shape

```haskell
import Baikai.Response.JSON (responseToJSON)

let answer = DataContent state Nothing Nothing Nothing
    response = emptyResponse & #message . #content .~ V.singleton (AssistantData answer)
print (responseToJSON response)
```

## Contract

Earlier versions cannot represent structured answers independently of text or
optional call evidence. `UserData` carries JSON input; `AssistantData` carries
chosen values with optional distributions, confidence and method. `DataStart`
and `DataEnd` form an atomic block; there is no partial JSON delta contract.
Named response codecs preserve these fields without global Response instances.

Generative providers serialize user data canonically and refuse structured
assistant history with a typed field path. Probabilities are individually
validated in [0,1]; distributions are never normalized. Core traces and both
call-log paths retain data on successful and failed terminals. Decimal cost
encoding retains its existing precision limits.
