---
title: "Generated model catalog and its refresh pipeline"
type: Capability
description: "Depend on a ready-made Model value for every shipped Anthropic and OpenAI model — context window, output cap, per-million-token prices, modalities, compat quirks — regenerated from models.dev by two committed executables and pinned byte-for-byte by a round-trip test."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-3
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai.Models.Generated
  - baikai-fetch-models
  - baikai-gen-models
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/CatalogSpec.hs
    proves: "Re-running baikai-gen-models over the committed JSON reproduces Baikai/Models/Generated.hs byte-for-byte, so the checked-in module cannot drift from the hand-reviewable catalog data."
  - kind: test
    resource: baikai/test/GenModelsSpec.hs
    proves: "The JSON-to-Haskell generator's behaviour, including its refusal to emit duplicate bindings when two model ids sanitise to the same Haskell identifier."
  - kind: test
    resource: baikai/test/FetchModelsSpec.hs
    proves: "The models.dev normalisation and the hand-maintained override layer that the fetch step applies."
  - kind: module
    resource: baikai/src/Baikai/Models/Generated.hs
    proves: "The catalog itself: one exported Model binding per shipped model, plus allModels."
  - kind: guide
    resource: docs/user/models-and-providers.md
    proves: "When to take a catalog value, when to hand-roll an emptyModel instead, and how the two coexist."
---

# Generated model catalog and its refresh pipeline

`Baikai.Models.Generated` exports one `Model` value per curated model —
`Models.openai_gpt_4o_mini`, `Models.claude_sonnet_5`, and so on — plus
`allModels`. Each value carries everything dispatch and cost accounting need, so
a consumer naming a model gets correct pricing and a correct context window
without maintaining a table.

The catalog has two representations and a two-step pipeline between them:
`baikai-fetch-models` pulls `https://models.dev/api.json` into hand-reviewable
JSON under `baikai/data/models/`, and `baikai-gen-models` renders that JSON into
the Haskell module. Both steps are committed executables, so a consumer can see
exactly how a price got into the library, and `git diff` is the review surface.

This supplies `Model` values to [CAP-1 — provider-neutral model calls with
registry dispatch](unified-provider-calls.md); it is not required by it, since a
hand-rolled `emptyModel` works just as well.

## Shape

```console
$ cabal run baikai-fetch-models   # network → JSON
$ cabal run baikai-gen-models     # JSON → Generated.hs
$ cabal test baikai               # CatalogSpec proves the two agree
```

## Limits

- The catalog is a **snapshot committed at release time**. A model released after
  the last refresh is absent, and a price changed upstream is stale, until
  someone re-runs the pipeline and cuts a release. Consumers who need a newer
  model hand-roll an `emptyModel` rather than waiting.
- Every `anthropic-messages` entry must state two facts about its generation in
  a per-model `compat` block: `thinkingStyle` (`"budget"` or `"adaptive"`) and
  `supportsSamplingParameters`. Neither can be recovered from the model id or
  the base URL, so `baikai-gen-models` refuses an entry that omits them rather
  than falling back to host auto-detection. They are curated in
  `anthropicInclude` (`baikai/fetch/FetchModelsCore.hs`), so a refresh cannot
  lose them, and pinned in `CatalogSpec`.
- Coverage is deliberately curated: tool-capable Anthropic and OpenAI models
  only. Other providers reachable through the OpenAI-compatible transport
  (DeepSeek, OpenRouter, Together, …) have JSON under `baikai/data/models/` but
  are not part of the generated Haskell surface.
- Prices are what models.dev reported plus a small hand-maintained override
  layer. They are an accounting input, not a billing source of truth; the
  authority is the provider's invoice.
- Regenerating requires the `baikai-gen-models` executable on `PATH`, which the
  `build-tool-depends` entry supplies during `cabal test` and nowhere else.
- `Generated.hs` is excluded from the repository's formatter at the pre-commit
  hook level, because formatting it breaks the byte-identity round trip.
