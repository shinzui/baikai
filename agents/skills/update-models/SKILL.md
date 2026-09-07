---
name: update-models
description: Refresh baikai's supported OpenAI and Anthropic model catalog after provider releases, verifying API compatibility, prices and limits, updating fetcher curation, and regenerating the Haskell bindings.
---

# Update supported models

Run from the repository root. Read `docs/user/models-and-providers.md` and
`baikai/fetch/FetchModelsCore.hs` for the catalog contract. This is a catalog
update; changing application defaults or publishing packages is separate work.

## Verify the release

Compare the committed `baikai/data/models/{openai,anthropic}.json` with current
official documentation, opening the individual model and migration pages:

- OpenAI: https://developers.openai.com/api/docs/models/all
- Anthropic: https://platform.claude.com/docs/en/models/overview

Record exact API IDs, text/image inputs, reasoning support, context and output
limits, and standard USD prices per million tokens (input, output, cache read,
and cache write). Distinguish base pricing from long-context, batch, service-tier,
and cache-TTL rates; the catalog only represents one rate per token category.

Confirm streaming and tool use on the API baikai actually implements: OpenAI
Chat Completions or Anthropic Messages. Responses-only models do not belong in
the OpenAI include set. Check migration notes for thinking modes, accepted
effort levels, sampling parameters, forced tool choice and history constraints.
Inspect the local request/shape code to establish compatibility. Use Mori to
locate dependency sources if SDK API changes are needed; a new model ID alone
usually needs no dependency update. Do not infer capabilities from model names.

## Refresh and review

1. Update `openaiInclude` or `anthropicInclude` in
   `baikai/fetch/FetchModelsCore.hs`. Every Anthropic ID needs explicit thinking
   style and sampling support, with a dated official source comment. Update
   `expectedAnthropicFacts` in `baikai/test/CatalogSpec.hs` as well.
2. Fetch a candidate into a temporary directory before replacing committed data:

   ```sh
   candidate_dir=$(mktemp -d "${TMPDIR:-/tmp}/baikai-models.XXXXXX")
   cabal run baikai-fetch-models -- --out-dir "$candidate_dir"
   diff -u baikai/data/models/openai.json "$candidate_dir/openai.json"
   diff -u baikai/data/models/anthropic.json "$candidate_dir/anthropic.json"
   ```

   `diff` exits 1 for expected differences. The fetcher reads models.dev, which
   is a secondary source; verify new entries and changed values against the
   official pages. Check for missing IDs and unexpected removals. If needed,
   save the upstream JSON and use `--from-file` for a repeatable refresh.
3. Add dated, source-backed corrections to `overrides` when upstream values
   are wrong. Overrides only modify present models; they cannot restore an ID
   absent from upstream. If upstream lags a release, add verified catalog JSON
   manually and document the fetch limitation rather than silently dropping it
   on the next refresh. Preserve unrelated entries unless their changes have
   also been verified. Review stale-override warnings.
4. Copy reviewed candidate JSON into `baikai/data/models/`, then run
   `cabal run baikai-gen-models`. Never hand-edit
   `baikai/src/Baikai/Models/Generated.hs`.
5. Update catalog examples and model-specific restrictions in
   `docs/user/models-and-providers.md`, and add an Unreleased changelog entry.
   Preserve existing bindings unless removal is part of the task.

## Validate

Run `cabal test baikai:baikai-test` for fetch normalization, generator validation
and byte-for-byte catalog regeneration. Add focused regression coverage when
new capability or pricing behavior needs it. If request shaping changes, run
the affected provider's tests too. Check changed handwritten Haskell with
`fourmolu --mode check baikai/fetch/FetchModelsCore.hs baikai/test/CatalogSpec.hs`
and run `git diff --check`; inspect the final JSON and generated diff together.
Do not format `Generated.hs`: its generator owns the byte layout. The full
repository formatter is `nix fmt`; bare `treefmt` has no checked-in config.

Report added bindings, verified sources, checks run, and any remaining API or
pricing limitations. Offline tests do not establish live account access; only
claim a live smoke test when one was actually run.
