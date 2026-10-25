---
title: "TypeSafe closed-set judgments with answer evidence"
type: Capability
description: "Submit one structured state and closed-set schema to TypeSafe and preserve chosen values, probabilities and confidence through streaming, persistence and logs."
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-25T12:55:00Z"
capabilityId: CAP-27
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: unreleased
timestamp: "2026-10-25T13:00:50Z"
reviews:
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-25T13:00:50Z"
    document_timestamp: "2026-10-25T13:00:50Z"
    context: "Implementation self-check against the offline HTTP matrix and compiled public API shape; availability remains unreleased."
packages: [baikai-typesafe, baikai]
interface: [Baikai.Provider.TypeSafe.Api, Baikai.Judgment, Baikai.Response.JSON]
evidence:
  - kind: test
    resource: baikai-typesafe/test/Main.hs
    proves: "Exact loopback HTTP, refusals, strict replies, evidence and persistence through both public call modes."
  - kind: test
    resource: baikai/test/JudgmentSpec.hs
    proves: "Provider-neutral schema compilation, ordering and answer validation."
  - kind: guide
    resource: docs/user/typesafe-judgments.md
    proves: "Installation, declared question subset, request construction and consumer migration."
---

# TypeSafe closed-set judgments with answer evidence

Choose `Baikai.Models.Generated.typesafe_jev_latest` or `typesafe_jev_preview` as
`model` below. `personSchema` stands for a caller-supplied closed-set schema with
boolean, string-choice or zero-based integer-score properties. For a loopback
fixture, override the model's base URL and use an explicit literal API key in
`opts`; the request and response contract is identical. Set `TYPESAFE_API_KEY`
for the official host.

## Shape

```haskell
import Baikai.Provider.TypeSafe.Api qualified as TypeSafe
import Data.Aeson qualified as Aeson

reg <- newProviderRegistry
registerApiProviderWith reg TypeSafe.typesafeProvider
let state = Aeson.object ["ticket" Aeson..= ("Checkout is unavailable." :: Text)]
    ctx = contextOf [userData state]
    opts = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "ticket" personSchema))
response <- completeRequestWith reg model ctx opts
pure (flattenAssistantData (response ^. #message . #content))
```

## Contract

`isJudgmentOnly` reads catalog facts. The request accepts exactly one text or
structured data part. Explicit generation/reasoning/tool controls are refused
before dispatch. A valid reply produces one `AssistantData` block, including
provider confidence and expected score. Probabilities are validated individually
and never normalized. Streams synthesize `DataStart`/`DataEnd` around one HTTP
reply. Named full-response codecs preserve the data independently of optional
call evidence. No retry loop runs inside the adapter.
