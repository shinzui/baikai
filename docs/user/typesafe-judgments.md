---
type: Guide
title: TypeSafe judgments
description: "Install and use TypeSafe System One judgments, inspect answer evidence and migrate judgment-only consumers."
docId: DOC-12
tags: [typesafe, judgments, structured-data, probabilities]
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-25T12:55:00Z"
---

# TypeSafe judgments

Add `baikai-typesafe ^>=0.1.0.0` and `baikai ^>=0.9.0` to the Cabal
dependencies. Both packages are available on Hackage.
The provider uses the released `typesafe-hs ^>=0.1.0.0` wire client without a
checkout override.

Register `Baikai.Provider.TypeSafe.Api.typesafeProvider` with
`registerApiProviderWith` on your explicit registry. Select
`Baikai.Models.Generated.typesafe_jev_latest` or `typesafe_jev_preview`.
`isJudgmentOnly model` queries the catalog fact; provider names and `jev-` prefixes
are not routing rules.

Supply `contextOf [userData state]` with a JSON string, object or array, or one
`user` text message. Put a `JsonSchema (jsonSchemaFormat "ticket" schemaValue)`
in `Options.responseFormat`. The schema must be an object with nonempty
`properties`. A boolean asks a predicate; a distinct string enum asks a choice
(1–255 labels); an integer enum containing exactly 0 to N−1 asks a score
(2–10 levels). Described `anyOf` or `oneOf` const branches attach choice/level
criteria, including true/false predicate criteria. Property descriptions become
instructions, defaulting to the property name. Instructions and descriptions
must be text, objects or arrays, with null allowed only for optional criteria.
Missing score descriptions use their decimal indices.

Question order follows `required` when it lists every property exactly once;
otherwise it is ascending property key. All properties are answered. Unsupported
schema constraints are refused by path. `additionalProperties`, when supplied,
must be false. `JsonSchemaFormat.name` and `strict` are local metadata.

A complete example is [CAP-27](../capabilities/typesafe-judgments.md); its shape
compiles in `baikai-smoke:test:doc-shapes`. The exact three-question request and
response are in `baikai-typesafe/test/fixtures/` and are exercised against a local
HTTP fixture by the provider's offline suite.

The official host resolves `TYPESAFE_API_KEY`; an explicit `Options.apiKey` wins.
Custom gateways require an explicit source, including `ApiKeyEnv
"TYPESAFE_API_KEY"` if forwarding that credential is intentional. Override
`Model.baseUrl` with a root or trailing `/v1`; gateway prefixes are retained.
Header precedence is provider defaults, model headers, then option headers,
case-insensitively. Redirects are disabled. A positive `timeoutMs` bounds the
whole call including body reading; cancellation closes the response. There are
no internal retries.

Read `flattenAssistantData (response ^. #message . #content)`. Each block carries
`value`, optional `probabilities`, optional `confidence`, and
`method = Just "provider_classification"`. Predicates use true at probability
≥0.5; choices preserve the selected label even when it is not the argmax;
TypeSafe scores preserve the reported expected score, including fractions.
Neither confidence nor score is derived locally. Distributions need not sum to
one. Baikai checks finite values, declared answer names and keys, required wire
fields and score legends before emitting data.

Both complete and stream dispatch work. The wire call is non-streaming; events
are `EventStart`, `DataStart`, `DataEnd`, `EventDone`, or an error terminal without
a data success event. Local unsupported inputs return non-retryable
`InvalidRequest` with `UnsupportedFeature path`; the recognized upstream
unknown-model error supplies `UnsupportedModel id`. Malformed replies are
`DecodeFailure`. HTTP status and transport failures use core classification.

Every explicit generation, sampling, reasoning, speed and tool-choice control
is refused, including explicit standard speed. An absent control, empty stop
sequences and `CacheRetentionNone` pass. System prompts, tools and multi-turn
history are refused. Transport options, metadata and evidence stay available;
metadata remains local. Unknown catalog prices are unavailable estimates.

Answer probabilities and confidence are content. They survive named
`Baikai.Response.JSON.responseToJSON` / `responseFromJSON`, terminal traces, call
logs and OpenTelemetry even without call evidence opt-in. Optional call evidence
separately records the actual request, observed model, usage and
`x-typesafe-request-id`; it never substitutes a requested model for an observation.

For `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`,
route on `isJudgmentOnly` before generative structured-output capability checks,
clear post-routing generation defaults, send one `UserData`, and retain
`AssistantData` in the consumer's existing response codec. Compare its schema
reader against `compileJudgments`, including the question-order rule. Do not add
conflicting Response instances or reuse cached call evidence as a fresh
observation. Cached answers can retain their distributions after removing
per-call evidence.

The live suite skips unless explicitly selected, even when a key exists:

```bash
cabal test baikai-smoke:test:typesafe-live
cabal test baikai-smoke:test:typesafe-live --test-options='--live'
```

The second command performs one paid call and requires a nonempty key. Offline
fixture success is separate from live verification.

## Minimal request

This uses the same public calls compiled by the doc-shapes and selected live suites:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Baikai
import Baikai.Models.Generated (typesafe_jev_latest)
import Baikai.Provider.TypeSafe.Api (typesafeProvider)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Aeson qualified as Aeson
import Data.Text (Text)

main :: IO ()
main = do
  registry <- newProviderRegistry
  registerApiProviderWith registry typesafeProvider
  let questionSchema = Aeson.object
        [ "type" Aeson..= ("object" :: Text)
        , "properties" Aeson..= Aeson.object
            [ "urgent" Aeson..= Aeson.object
                [ "type" Aeson..= ("boolean" :: Text)
                , "description" Aeson..= ("Is service blocked?" :: Text)
                ]
            ]
        , "additionalProperties" Aeson..= False
        ]
      state = Aeson.object ["ticket" Aeson..= ("Checkout is unavailable." :: Text)]
      context = contextOf [userData state]
      options = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "ticket" questionSchema))
  response <- completeRequestWith registry typesafe_jev_latest context options
  case responseError response of
    Just err -> print err
    Nothing -> print (flattenAssistantData (response ^. #message . #content))
```
