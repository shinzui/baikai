---
id: 89
slug: carry-the-claude-sonnet-4-5-binding-through-its-retirement-without-silent-catalog-removal
title: "Carry the Claude Sonnet 4.5 binding through its retirement without silent catalog removal"
kind: exec-plan
created_at: 2026-10-02T16:49:49Z
intention: "intention_01m3yrb5xtepy8gkyh1key7q72"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-10-02T16:49:49Z
---

# Carry the Claude Sonnet 4.5 binding through its retirement without silent catalog removal

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

On 2026-09-30 Anthropic deprecated Claude Sonnet 4.5 (`claude-sonnet-4-5-20250929`, to which the
`claude-sonnet-4-5` alias resolves) and scheduled its retirement on the Claude API for 2026-11-30.
After that date every request to it fails. Baikai ships a generated binding for it,
`Baikai.Models.Generated.anthropic_claude_sonnet_4_5`, and nothing in the library tells a caller it
is going away. Nothing in the catalog tooling decides what happens to the binding either.
Today the next catalog refresh after models.dev drops the ID would silently omit it from the
candidate JSON. Regenerating would then delete an exported Haskell name in an arbitrary minor release.

After this plan, a caller compiling against the binding gets a GHC deprecation warning. It names the
retirement date, the recommended replacement `anthropic_claude_sonnet_5_5`, and the baikai release
that removes the name. The deprecation is a catalog fact that survives refreshes, rather than a hand
edit to generated code. The fetcher reports a curated model that upstream no longer lists instead of
dropping it, and serves an explicit, dated retained entry so the binding stays byte-for-byte stable
until its scheduled removal. Baikai's own live thinking smoke stops depending on a model that will
stop answering.

To see it working: build any module that mentions `anthropic_claude_sonnet_4_5` and observe the
`-Wdeprecations` warning text; run `baikai-fetch-models --from-file` against an upstream snapshot with
`claude-sonnet-4-5` removed, and observe the reported retention while the output is unchanged.


## Progress

- [ ] Milestone 1: a per-model deprecation fact flows from fetch curation through the catalog JSON into
  a generated `DEPRECATED` pragma on `anthropic_claude_sonnet_4_5`; `cabal test baikai:baikai-test`
  passes and the generated diff touches only that binding's pragma.
- [ ] Milestone 2: the fetcher reports curated IDs absent from upstream, fails on them unless a dated
  retained entry covers them, and renders the retained entry identically to the committed JSON;
  proved by `FetchModelsSpec` cases on an edited fixture.
- [ ] Milestone 3: the live budget-thinking smoke case runs on a curated budget-style model that is
  not deprecated, and user documentation and the changelog record the deprecation and its
  removal release.
- [ ] Milestone 4 (deferred to the baikai 0.8.0.0 release): remove the deprecated binding, its
  retained entry, and the test rows that pin it, as one reviewed change.


## Surprises & Discoveries

- Observation: neither of the two Anthropic models retired in 2026 (`claude-opus-4-1-20250805`,
  `claude-sonnet-4-20250514`) was ever in `anthropicInclude`, so the repository has no precedent for
  retiring a shipped catalog binding. This is the first.
  Evidence: `git log -S'claude-opus-4-1' -- baikai/fetch/FetchModelsCore.hs` and the same search for
  `"claude-sonnet-4"` return no commits (checked 2026-10-02).

- Observation: the Anthropic side is partly guarded already: `baikai/test/CatalogSpec.hs` asserts
  that `expectedAnthropicFacts` covers exactly the catalog's Anthropic IDs, and three test modules
  name `anthropic_claude_sonnet_4_5`, so a silent removal would fail the test suite. The failure would
  invite deleting those rows rather than preserving the binding. The OpenAI side has no equivalent guard.
  Evidence: `baikai/test/CatalogSpec.hs` ("the pinned table must cover exactly the catalog's
  Anthropic ids"), `baikai/test/Main.hs`, `baikai-claude/test/ThinkingSpec.hs`.


## Decision Log

- Decision: deprecate the binding now and remove it in baikai 0.8.0.0, rather than deleting it at
  retirement or keeping it indefinitely.
  Rationale: `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md` fixes one major of
  overlap, and the pragma must name the removing release. Baikai is at 0.7.2.0, so a pragma added in a
  0.7.x release names 0.8.0.0. Deleting the name in a minor release would break compiling consumers
  without warning.
  Date: 2026-10-02

- Decision: the deprecation is a curated catalog fact, carried in the catalog JSON and rendered by
  the generator, never a hand edit to `baikai/src/Baikai/Models/Generated.hs`.
  Rationale: the generated module is byte-for-byte regenerated and checked by `CatalogSpec`;
  `docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md` puts model facts
  in the catalog record, curated in `baikai/fetch/FetchModelsCore.hs`.
  Date: 2026-10-02

- Decision: do not add a lifecycle field to `Baikai.Model.Model`.
  Rationale: adding a field to an exported record is a breaking change, and the problem is a
  compile-time signal for one name. The pragma plus documentation is sufficient; a runtime lifecycle
  fact can be planned separately if a consumer needs to filter `allModels`.
  Date: 2026-10-02


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Baikai's model catalog is generated. `baikai/fetch/FetchModelsCore.hs` is the pure core of the
`baikai-fetch-models` executable (wrapper: `baikai/fetch/FetchModels.hs`). It reads a models.dev
snapshot (`https://models.dev/api.json`), keeps only IDs listed in the curated include sets
`openaiInclude` and `anthropicInclude`, attaches curated per-model facts, applies the dated
`overrides` table, and renders `baikai/data/models/openai.json` and
`baikai/data/models/anthropic.json`. `baikai-gen-models` (core: `baikai/gen/GenModelsCore.hs`)
turns that JSON into `baikai/src/Baikai/Models/Generated.hs`, which exports one `Model` value per
entry (for example `anthropic_claude_sonnet_4_5`) plus `allModels`. `baikai/test/CatalogSpec.hs`
regenerates the module and fails if it differs from the committed file, so the JSON is the source of
truth and the Haskell file is never edited by hand.

A model that the include set names but upstream does not list (or lists with `tool_call: false`) is
currently skipped by `normalizeProvider` without any message. The executable only warns about
overrides that matched no model (`staleOverrides`). models.dev removes retired models, so after
2026-11-30 a refresh can be expected to drop `claude-sonnet-4-5` from the candidate.

A GHC `DEPRECATED` pragma (`{-# DEPRECATED name "text" #-}`) makes every use of `name` outside its
defining module emit a `-Wdeprecations` warning with that text. Uses inside the defining module, such
as `allModels` in `Generated.hs`, do not warn. No package in this repository promotes
`-Wdeprecations` to an error; the cabal files promote only incomplete-pattern warnings.

Current users of the binding inside the repository are `baikai/test/Main.hs` (thinking-style facts),
`baikai/test/CatalogSpec.hs` (`expectedAnthropicFacts`, keyed by ID string), `baikai-claude/test/ThinkingSpec.hs`
(`anthropicModels`), and `baikai-smoke/test/ThinkingSmoke.hs`, whose live case
`"claude-sonnet-4-5-thinking-budget"` is the repository's live proof of the budget thinking wire shape
(`thinking: {type: "enabled", budget_tokens: N}`). The other curated budget-style models are
`claude-haiku-4-5` (retirement "not sooner than October 15, 2026") and `claude-opus-4-5` (retirement
"not sooner than November 24, 2026"), so every budget-style model is near the end of its life.

Relevant ADRs. `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md`: a name deprecated
in `A.B.x` is removed in `A.(B+1).0.0`. The pragma's last sentence names that release, and the
changelog lists it under `### Deprecated`. Releasing that major includes
`grep -rn 'Removed in .* A.B.0.0' */src` returning nothing.
`docs/adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md`: provider capability
and generation facts are fields of the catalog record, curated in fetch code, never tables keyed by
model ID in adapters. Project convention (repository memory): record fields must not carry prefixes,
so new fields in fetch or generator records are named plainly (for example `deprecation`), even beside
older prefixed fields such as `entryId` in `GenModelsCore.ModelEntry`.

Dated source evidence (verified 2026-10-02):
https://platform.claude.com/docs/en/about-claude/model-deprecations lists
`claude-sonnet-4-5-20250929` as Deprecated on September 30, 2026, with retirement on November 30, 2026.
Its recommended replacement is `claude-sonnet-5-5`. The same page lists `claude-haiku-4-5-20251001` as
Active, retiring not sooner than October 15, 2026.
https://platform.claude.com/docs/en/about-claude/pricing still lists Sonnet 4.5 at $3/$3.75/$6/$0.30/$15
(input, 5m write, 1h write, cache hit, output), matching the committed JSON.


## Plan of Work

Milestone 1 adds the deprecation fact. In `baikai/fetch/FetchModelsCore.hs`, add a dated table
`deprecations :: Map (Text, Text) CatalogDeprecation`, keyed by provider and model ID. Give
`CatalogDeprecation` three fields: `retiresOn :: Text` (ISO date), `replacement :: Text` (the
replacement catalog model ID), and `removedIn :: Text` (the baikai version). Seed it with
`("anthropic", "claude-sonnet-4-5")` mapped to `2026-11-30`, `claude-sonnet-5-5`, and `0.8.0.0`, citing the
deprecations page in a dated comment. Carry it on `CatalogModel` as `deprecation :: Maybe
CatalogDeprecation` and render it as an optional `"deprecation"` object after `compat` and before
`enabled`, so existing entries render unchanged. In `baikai/gen/GenModelsCore.hs`, parse the optional
object and render, immediately before the binding's type signature, a pragma of the form:

```haskell
{-# DEPRECATED anthropic_claude_sonnet_4_5 "Anthropic retires claude-sonnet-4-5 on 2026-11-30; use anthropic_claude_sonnet_5_5. Removed in baikai 0.8.0.0." #-}
```

The generator derives the replacement identifier with the same `sanitizeIdentifier` used for
bindings. It must refuse a deprecation whose replacement is not an enabled entry of the same
provider, so the warning can never name a binding that does not exist. Regenerate, and confirm the only
change to `Generated.hs` is that pragma. Existing tests that pin the binding stay as they are; they
still describe a shipped binding. If their deprecation warnings are noisy, add
`{-# OPTIONS_GHC -Wno-deprecations #-}` only to those test modules.

Milestone 2 makes a refresh unable to drop a curated model silently. Add a pure function
`missingCurated :: ProviderSpec -> Map Text UpstreamModel -> [Text]` returning curated IDs that are
absent upstream or present with `tool_call: false`. Add a dated `retainedModels :: Map (Text, Text)
CatalogModel` table whose entries are used by `normalizeProvider` only when upstream lacks the ID.
Each entry carries a dated comment explaining why upstream lost it. In `FetchModels.hs`, print
`baikai-fetch-models: retained <provider>/<id> (absent upstream)` for each retained use. Exit non-zero,
writing nothing, when a missing curated ID has no retained entry. The message names the ID and both
remedies: remove it from the include set, which a reviewer must approve because it deletes a binding, or
add a retained entry. Seed `retainedModels` with the current committed Sonnet 4.5 entry, including
its compat facts and deprecation. That entry is inert while upstream still lists the model. This also
gives the skill's "upstream lags a release" case a single home instead of ad hoc JSON edits.

Milestone 3 moves the budget-shape live smoke case in `baikai-smoke/test/ThinkingSmoke.hs` from
`Models.anthropic_claude_sonnet_4_5` to `Models.anthropic_claude_haiku_4_5`, renaming the label
`claude-haiku-4-5-thinking-budget`. Haiku is the cheapest budget-style model, and Anthropic has not
deprecated it as of 2026-10-02. Record in this plan that the budget case will need another move,
or a decision to retire it, once Haiku 4.5 and Opus 4.5 are deprecated. Add the deprecation, with
its retirement date and replacement, to `docs/user/models-and-providers.md` and to `CHANGELOG.md`
under `## [Unreleased]` / `### Deprecated`, naming `0.8.0.0` as ADR 0016 requires.

Milestone 4 belongs to the 0.8.0.0 release, not to this plan's first delivery. Remove
`claude-sonnet-4-5` from `anthropicInclude`, `deprecations`, and `retainedModels`, regenerate, and
remove the rows that pin it. The rows to update are these exact assertions:
`facts anthropic_claude_sonnet_4_5 @?= (AnthropicThinkingBudget, True)` in `baikai/test/Main.hs`,
`("claude-sonnet-4-5", (AnthropicThinkingBudget, True, True, False))` in
`baikai/test/CatalogSpec.hs`, and
`("claude-sonnet-4-5", anthropic_claude_sonnet_4_5, AnthropicThinkingBudget, True, True, False)` in
`baikai-claude/test/ThinkingSpec.hs`. Removing them is correct only because the binding itself is
removed in that release. The ADR 0016 release grep then confirms nothing else names 0.8.0.0.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Milestone 1:

```bash
cabal run baikai-gen-models
git diff --stat baikai/src/Baikai/Models/Generated.hs baikai/data/models/
cabal build baikai-smoke:baikai-smoke 2>&1 | grep -A2 "anthropic_claude_sonnet_4_5"
```

Expect `Generated.hs` to change by one pragma line, `anthropic.json` by one `deprecation` object,
and the smoke build (before Milestone 3) to print a `-Wdeprecations` warning containing
`Removed in baikai 0.8.0.0`.

Milestone 2, using a repeatable snapshot with the model removed:

```bash
S=$(mktemp -d "${TMPDIR:-/tmp}/baikai-retain.XXXXXX")
curl -sS https://models.dev/api.json -o "$S/api.json"
jq 'del(.anthropic.models["claude-sonnet-4-5"])' "$S/api.json" > "$S/dropped.json"
cabal run baikai-fetch-models -- --from-file "$S/dropped.json" --out-dir "$S/out"
diff -u baikai/data/models/anthropic.json "$S/out/anthropic.json" && echo identical
```

Expect `baikai-fetch-models: retained anthropic/claude-sonnet-4-5 (absent upstream)` on stderr and
`identical`. Temporarily removing the retained entry must make the same command exit non-zero and
write no files.


## Validation and Acceptance

Run the offline gate:

```bash
cabal test baikai:baikai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
fourmolu --mode check baikai/fetch/FetchModelsCore.hs baikai/fetch/FetchModels.hs baikai/gen/GenModelsCore.hs baikai/test/FetchModelsSpec.hs baikai/test/CatalogSpec.hs
git diff --check
```

Acceptance is behavioral. A consumer module using `anthropic_claude_sonnet_4_5` compiles with a
deprecation warning naming 2026-11-30, `anthropic_claude_sonnet_5_5`, and `0.8.0.0`; `allModels` still
contains the binding. New `FetchModelsSpec` cases prove the remaining behavior. One shows that a fixture
missing a curated ID without a retained entry is reported by `missingCurated`. Another shows that a
retained entry renders byte-identically to the committed JSON entry. A deprecation round-trips through
fetch rendering and generator parsing, and the generator rejects a deprecation whose replacement
is absent. `CatalogSpec` still regenerates `Generated.hs` byte-for-byte.

The moved live case is checked with a real key:

```bash
cabal test baikai-smoke:baikai-smoke
```

The output must show `claude-haiku-4-5-thinking-budget` passing. A missing-key skip leaves that
acceptance outstanding and must be recorded as such. Behavior of the retired model itself after
2026-11-30 is not part of acceptance.


## Idempotence and Recovery

Every step is regeneration from checked-in sources and can be repeated. If the generator's new
validation rejects the catalog, fix the JSON source or the curated table, never `Generated.hs`. The
retained-entry fallback only applies when upstream lacks an ID, so it cannot change any entry that
upstream still provides.


## Interfaces and Dependencies

No new library dependencies. This plan owns three new interfaces. `FetchModelsCore` gains
`CatalogDeprecation`, `deprecations`, `retainedModels` and `missingCurated`, exported for
`FetchModelsSpec`. Catalog JSON gains an optional per-model `"deprecation": {"retiresOn",
"replacement", "removedIn"}` object, and `GenModelsCore` gains its parser and pragma renderer. The
public `Baikai.Model.Model` type is unchanged. The update-models skill
(`agents/skills/update-models/SKILL.md`; `.claude/skills/update-models` is a symlink to it) should
mention the retained table and the deprecation table once they exist. That documentation edit belongs
to Milestone 2.
