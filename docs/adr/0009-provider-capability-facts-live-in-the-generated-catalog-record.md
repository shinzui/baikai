---
title: Provider capability facts such as thinking style and sampling support live in the generated catalog record and never in a hand table
status: accepted
date: 2026-08-27
---

# Provider capability facts such as thinking style and sampling support live in the generated catalog record and never in a hand table

## Context

Two facts about an Anthropic model generation cannot be recovered from
anything baikai already knows. Which extended-thinking request shape the
generation accepts — the older budget shape
`{"type":"enabled","budget_tokens":N}` or the newer
`{"type":"adaptive"}` — is one; whether it accepts the sampling
parameters `temperature`, `top_p` and `top_k` is the other. Sending the
wrong answer is not a degraded call, it is an HTTP 400.

Neither fact is derivable from the base URL, which names a host and not a
generation, and neither is derivable from the model id, though baikai
tried. `defaultAnthropicThinkingStyle` in `baikai/src/Baikai/Compat.hs`
was a prefix table:

```haskell
defaultAnthropicThinkingStyle modelId
  | adaptive "claude-opus-4-6" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-7" = AnthropicThinkingAdaptive
  | adaptive "claude-opus-4-8" = AnthropicThinkingAdaptive
  | adaptive "claude-fable-5" = AnthropicThinkingAdaptive
  | otherwise = AnthropicThinkingBudget
```

`Baikai.Model.anthropicMessagesCompatFor` overlaid it on every model
whose `compat` was `CompatNone`, which was every model in the generated
catalog. The table did not know `claude-sonnet-5`, so the newest Sonnet —
an id a caller reads straight out of `Baikai.Models.Generated` — got
`budget_tokens` and a 400 on any thinking request. It did not know
`claude-sonnet-4-6` either. Sampling support was worse: it was not
modelled at all, so `temperature` went to every Anthropic model
unconditionally.

The failure mode is structural, not clerical. The catalog is regenerated
from `baikai/data/models/*.json` whenever the model list is refreshed;
the table is a Haskell literal nobody refreshes at the same time. A new
generation therefore arrives in the catalog already carrying the wrong
wire facts, and nothing in the build says so. The 2026-08 review recorded
this as C.1 (`docs/reviews/correctness-and-api-review-follow-up.md`).

## Decision

A fact about what a provider or model generation accepts on the wire is a
field of the compatibility record carried by the model's generated
catalog entry. It is sourced from the catalog data and the fetcher's
curation, and no adapter consults a table keyed by model id.

Concretely:

- `Baikai.Compat.AnthropicMessagesCompat` carries both facts:
  `thinkingStyle` (already there) and `supportsSamplingParameters` (new,
  default `True`). The record is the right home because it already exists
  to carry per-host and per-generation wire quirks.
- `anthropicInclude` in `baikai/fetch/FetchModelsCore.hs` — the one place
  a human vets an Anthropic id into the catalog — is a
  `Map Text AnthropicGenerationFacts`, each entry carrying a dated
  comment naming its source, exactly as the `overrides` table does. An id
  cannot be curated in without its facts, and a wholesale refresh cannot
  lose them.
- The fetcher renders the facts as a per-model `"compat"` block in
  `baikai/data/models/anthropic.json`, so `git diff` on the JSON stays
  the review surface for a generation change.
- `baikai-gen-models` refuses an `anthropic-messages` entry that reaches
  it without such a block (`checkAnthropicCompat` in
  `baikai/gen/GenModelsCore.hs`). Falling back to host auto-detection
  would silently reintroduce the guess, so the generator dies instead.
- `Baikai.Model.anthropicMessagesCompatFor` returns the explicit record
  when there is one and host auto-detection otherwise. The model id is
  never consulted.
- `defaultAnthropicThinkingStyle` is deprecated and unused; it is removed
  at the next major (`docs/plans/67-freeze-the-public-surface.md`).

## Consequences

A hand-rolled model — one built from `emptyModel` or `mkModel` rather
than taken from the catalog — states its own facts or starts from a
catalog value. `CompatNone` now means the budget style with sampling
supported, which is what every generation before Opus 4.7 and every known
Anthropic-compatible host accepts; a hand-rolled model naming an
adaptive-era id and leaving `compat` at `CompatNone` gets the budget
shape and a 400, and must set
`CompatAnthropicMessages (defaultAnthropicMessagesCompat {thinkingStyle = AnthropicThinkingAdaptive, supportsSamplingParameters = False})`.
This is the deliberate trade: a wrong answer that a caller wrote is
better than a wrong answer baikai guessed on their behalf.

Adding a model generation is a reviewed catalog change rather than a code
change: an `anthropicInclude` entry with its dated source comment, a
fetch or a hand edit of the JSON, a regeneration, and a row in
`CatalogSpec`'s pinned table. The generator's refusal and that table are
what make a missing fact a build failure rather than a runtime 400.

The rule generalises past thinking and sampling. Any future
"this generation rejects X" fact belongs in the same place, and any
future adapter that wants to branch on the model id should add a field
instead.

Where the facts themselves are wrong — the curated table is written from
the Anthropic API reference, not from a live probe — the fix is one map
entry, a regeneration and a Decision Log note. The keyed smoke cases in
`baikai-smoke/test/ThinkingSmoke.hs` are where the table meets reality.
