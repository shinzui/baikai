---
name: update-models
description: Refresh baikai's OpenAI and Anthropic model catalog, audit provider implementation compatibility against new releases, and create intention-linked execution plans for necessary support changes.
---

# Update supported models

Run from the repository root. Read `docs/user/models-and-providers.md` and
`baikai/fetch/FetchModelsCore.hs` for the catalog contract. Complete the catalog
refresh and assess whether the new models need implementation changes. Create
or update plans for those changes as part of the refresh; implement the planned
features only when requested. Changing application defaults or publishing
packages is separate work.

## Verify the release

Compare the committed `baikai/data/models/{openai,anthropic}.json` with current
official documentation, opening the individual model and migration pages:

- OpenAI: https://developers.openai.com/api/docs/models/all
- Anthropic: https://platform.claude.com/docs/en/models/overview

Record exact API IDs, text/image inputs, reasoning support, context and output
limits, and standard USD prices per million tokens (input, output, cache read,
and cache write). Distinguish base pricing from long-context, batch, service-tier,
and cache-TTL rates; the catalog only represents one rate per token category.

Confirm each capability on the exact endpoint selected by the catalog and
implemented by the current provider. Read `baikai/src/Baikai/Api.hs` and the
provider registrations rather than assuming the supported protocols are fixed.
A model page listing both Chat Completions and function calling does not prove
that function calling works on Chat Completions: migration guidance may require
Responses for tools. Do not infer capabilities from model names or combine
independent endpoint and feature lists into a compatibility claim.

## Audit implementation compatibility

Before enabling a new entry, trace the intended call through request shaping,
stream assembly, conversation replay, and accounting. Compare the actual code
and existing tests with the provider's migration requirements:

- **Dispatch and requests:** Check the API tag, registration, streaming and
  tool support, accepted effort levels, sampling fields, forced tool choice,
  structured output, output caps and cache configuration. Inspect
  `baikai-openai/src/Baikai/Provider/OpenAI/` and
  `baikai-claude/src/Baikai/Provider/Claude/`, including their request and shape
  modules. Check defaults as well as explicitly set options.
- **Responses and replay:** Check new event types, terminal/error handling,
  tool-call identities, empty signed thinking, opaque continuation data, and
  what reaches the next tool turn. Follow `baikai/src/Baikai/Content.hs`,
  `baikai/src/Baikai/Context.hs` and `baikai/src/Baikai/Provider/Registry.hs`.
  Distinguish preserving Baikai-owned history from restrictions on caller edits.
- **Usage, pricing and evidence:** Inspect `baikai/src/Baikai/Usage.hs`,
  `baikai/src/Baikai/Cost/Pricing.hs`, `baikai/src/Baikai/Evidence.hs` and provider
  usage extraction. Verify cache-write reporting, inclusive versus exclusive
  token counts, pricing thresholds and cache durations. A new rate in JSON
  does not implement the accounting rule, and missing usage is not observed zero.
- **SDK and tests:** Use Mori to locate dependency sources before assuming an
  SDK supports new fields or events. Verify Hackage releases and upstream tags
  before choosing bounds or compatibility workarounds. Inspect provider tests
  and `baikai-smoke/test/` for coverage of the actual endpoint and multi-turn
  behavior, including hardcoded options incompatible with the new model.

For each mismatch, record the official source and verification date, affected
code, concrete failing configuration, necessary behavior and proposed proof.
Separate confirmed gaps from unresolved questions; make uncertain protocol
behavior an investigation milestone rather than an invented implementation fact.
Follow `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`:
generation restrictions belong in catalog compatibility facts, not adapter
tables keyed by model ID.

Do not enable an entry on an incompatible route just because its metadata can
be generated. A partially supported entry needs an explicit scope and effective
guards; documentation alone does not prevent unsupported requests. If the
required route or guards do not exist, leave a new entry unenabled and plan the
support work. For an already shipped binding, plan a compatibility-preserving
correction rather than silently deleting it. Report any current exposure clearly.

## Plan necessary support changes

Create plans when the audit finds necessary changes; do not stop at a list of
caveats or ask whether the user wants plans. First search `docs/plans/` and
`docs/masterplans/` for existing work. Reuse or update a matching plan, preserving
its intention, and describe integration with related work rather than duplicating
it. If the current implementation already covers the release, report that finding
with its evidence and create no empty plans.

Use the `exec-plan` skill in `agents/skills/exec-plan/SKILL.md` for a bounded
change. For multiple independently verifiable work streams with shared interfaces
or ordering constraints, also use `agents/skills/master-plan/SKILL.md` to create
a master and coordinated children. Read their specifications and ADR workflow;
use their init scripts instead of hand-authoring frontmatter or allocating numbers.

The user has instructed this workflow to create intentions with Mina. For each
new plan, including a master when needed, run:

```sh
mina ci --json "<plan title>"
```

Read `intentionId` from the result and pass it to the relevant initializer's
`--intention` option. Create a distinct intention for each new child and pass
`--master-plan` as well. This standing instruction replaces the planning skills'
optional intention question. Preserve explicit child intentions rather than
overwriting them with the parent's. If creation fails, report the failure and
retain useful planning progress; never invent an ID or create duplicate intentions
when a successful result is already available.

Each plan must explain the current mismatch, required behavior, affected modules,
catalog/SDK implications, dependencies and shared-interface ownership, and exact
validation commands. Include observable acceptance for request rejection or
translation, streaming and tool replay, and accounting where relevant. Use a
focused live check for unresolved endpoint behavior; a missing key or skipped
case leaves that acceptance outstanding. Carry dated source evidence and relevant
ADR context into the plan. Do not expand ordinary model support into unrelated
provider features. When committing plans, include the planning skills' required
trailers and the matching intention IDs.

## Refresh and review

1. Update `openaiInclude` or `anthropicInclude` (or their current replacements) in
   `baikai/fetch/FetchModelsCore.hs`. OpenAI entries carry optional explicit
   endpoint restrictions; preserve those blocks when refreshing, and test tools
   against the selected API before advertising agent support. Every Anthropic ID needs explicit thinking
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

Report catalog changes separately from implemented and live-verified support.
Include verified sources, checks run, necessary changes, and links to the plans
created or updated with their intention IDs. State remaining API or pricing
limitations and which plan closes each one. Offline tests do not establish live
account access; only claim a live smoke test when one was actually run.

When a provider catalog mixes APIs, set the per-model `api` override alongside
its endpoint-specific `compat` block in fetch curation. Verify the rendered
candidate and regenerated binding retain both. Entries without an override
inherit the file-level API; changing one model must not migrate older models.
