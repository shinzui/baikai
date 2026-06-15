---
id: 24
slug: port-pi-mono-model-catalog-scraper-to-haskell-for-baikai
title: "Port pi-mono Model-Catalog Scraper to Haskell for baikai"
kind: exec-plan
created_at: 2026-06-15T22:14:27Z
intention: "intention_01kv6nhsa5e8mvkjj12ay1ts26"
---

# Port pi-mono Model-Catalog Scraper to Haskell for baikai

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, baikai's model catalog is maintained entirely by hand. The catalog is four JSON
files under `baikai/data/models/` (`anthropic.json`, `openai.json`, `deepseek.json`,
`openrouter.json`). A separate code generator, the executable `baikai-gen-models` (source
`baikai/gen/GenModels.hs`), reads those JSON files and emits a single Haskell module,
`baikai/src/Baikai/Models/Generated.hs`, containing one `Baikai.Model.Model` value per
enabled model. When a provider ships a new model or changes prices, a human must find the
new numbers, hand-edit the JSON, and re-run the generator. This is slow and goes stale:
in practice the OpenAI catalog sat on `gpt-4o`/`o1` for a month after `gpt-5.x` shipped,
and the Anthropic catalog had wrong cache prices and a missing flagship.

After this change, a maintainer will be able to run a single command —
`cabal run baikai-fetch-models` from the repository root — that reaches out over the
network to upstream catalog sources (primarily `https://models.dev/api.json`), filters and
normalizes the data into baikai's catalog JSON shape, applies a small, reviewable layer of
hand-maintained corrections, and rewrites `baikai/data/models/anthropic.json` and
`baikai/data/models/openai.json` in place. The maintainer then re-runs the existing
`cabal run baikai-gen-models` and reviews the `git diff` before committing. The observable
win: refreshing the catalog goes from "manually transcribe prices from a pricing page" to
"run two commands and review a diff."

This work is explicitly the "future plan" anticipated by the existing catalog ExecPlan
`docs/plans/12-generated-model-catalog.md`, whose Decision Log records (dated 2026-05-14):
"The generator deliberately does not scrape provider websites or external APIs. The catalog
JSON files are hand-curated by the baikai maintainers… A future plan can add a scraper if
the catalog grows large enough to require automation." This plan is that scraper, scoped
down to baikai's actual surface (two first-party providers, Anthropic and OpenAI) rather
than pi-mono's ~25-provider sprawl.

The reference implementation we are porting is pi-mono's TypeScript scraper at
`/Users/shinzui/Keikaku/hub/agents/pi-mono/packages/ai/scripts/generate-models.ts`
(~2,240 lines). We are not copying its scale; we are copying its *architecture*: fetch a
live catalog, keep only tool-capable chat models, map upstream fields to our own `Model`
shape, and layer a set of explicit per-model corrections on top because the upstream data
is not fully trustworthy (pi-mono, for example, hard-overrides Claude Opus cache pricing
that models.dev reports at 3× the true value).

The key boundary to keep in mind throughout: this scraper produces **catalog JSON**, the
same files a human edits today. It does **not** emit Haskell and does **not** replace
`baikai-gen-models`. The pipeline becomes: `baikai-fetch-models` (network → JSON) →
`baikai-gen-models` (JSON → `Generated.hs`). Keeping these two steps separate means the
network fetch never runs at build time, the JSON stays human-reviewable in `git diff`, and
the existing round-trip test that guards `Generated.hs` is untouched.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Offline normalizer (no network):

- [ ] Add a `baikai-fetch-models` executable stanza to `baikai/baikai.cabal` with deps
      `aeson`, `bytestring`, `containers`, `text`, `scientific`, `vector`, `filepath`,
      `directory`, `optparse-applicative` (or hand-rolled arg parsing to match
      `GenModels.hs`).
- [ ] Create `baikai/fetch/FetchModels.hs` with a pure `normalize` step that turns a parsed
      models.dev payload (read from a local file via `--from-file`) into baikai catalog JSON
      for the `anthropic` and `openai` providers.
- [ ] Add a unit test `baikai/test/FetchModelsSpec.hs` that feeds a small fixture JSON and
      asserts the normalized output for a couple of known models.
- [ ] Verify: `cabal run baikai-fetch-models -- --from-file <fixture> --provider openai`
      prints catalog JSON matching the fixture's expectation.

Milestone 2 — Live fetch:

- [ ] Add `http-client` + `http-client-tls` deps and an `IO` fetch of
      `https://models.dev/api.json` behind a `--from-url` default.
- [ ] Wire `--out-dir baikai/data/models` to write `anthropic.json` and `openai.json`.
- [ ] Verify: `cabal run baikai-fetch-models` rewrites the two files; `git diff` shows only
      data changes; `cabal run baikai-gen-models` then succeeds and `cabal test baikai`
      (CatalogSpec) passes.

Milestone 3 — Override layer:

- [ ] Add a hand-maintained `overrides` table (price/capability corrections, model
      include/exclude sets) applied after normalization, mirroring pi-mono's correction
      pattern.
- [ ] Document each override with a dated comment explaining why upstream is wrong.
- [ ] Verify: a deliberately-wrong fixture value is corrected by the override and covered by
      a test.

Milestone 4 — Documentation & guardrails:

- [ ] Update `baikai/README.md` "Develop" section with the new refresh workflow.
- [ ] Decide and document the curation policy (which models are `enabled`) in the plan and
      in a header comment in `FetchModels.hs`.
- [ ] Note the known pre-commit/treefmt interaction (see Surprises) so future regenerations
      do not trip on it.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-15, found while hand-refreshing the catalog that motivated this plan):
  the pre-commit hook reformats `Generated.hs` even though `nix/treefmt.nix` explicitly
  excludes it. `nix/treefmt.nix` sets
  `settings.global.excludes = [ "baikai/src/Baikai/Models/Generated.hs" ]` precisely because
  "the generator emits its own layout, so keep fourmolu's hands off it — otherwise
  formatting and generation fight and the round-trip test fails." The generator emits
  **leading-comma** import/record layout; this repo's fourmolu emits **trailing-comma**. The
  pre-commit `treefmt` hook (wired in `nix/pre-commit.nix` via `config.treefmt.build.wrapper`)
  did not honor that exclude when handed the staged file list, and rewrote the file to
  trailing-comma style, which made `CatalogSpec` fail:

  ```text
  Baikai.Models.Generated
    regenerating from data/models produces no diff: FAIL
      Generated.hs is out of sync with data/models/*.json.
  ```

  Workaround used during the manual refresh: regenerate, then
  `git commit --no-verify` the generated file. This plan's refresh workflow will hit the
  same trap, so Milestone 4 must either (a) fix the pre-commit hook to honor the treefmt
  exclude, or (b) teach the generator to emit fourmolu's trailing-comma layout so the two
  stop fighting. Capturing here so the next contributor does not rediscover it.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep fetch and generation as two separate executables. `baikai-fetch-models`
  (new) does network → catalog JSON; the existing `baikai-gen-models` does catalog JSON →
  `Generated.hs`. Do not merge them.
  Rationale: Preserves the existing round-trip test (`baikai/test/CatalogSpec.hs`) that
  asserts `Generated.hs` is byte-identical to `baikai-gen-models` output, keeps the network
  dependency out of the build and out of `cabal test`, and keeps the catalog JSON as a
  human-reviewable artifact in `git diff` — exactly the properties
  `docs/plans/12-generated-model-catalog.md` chose deliberately.
  Date: 2026-06-15

- Decision: Primary (and initially only) upstream source is `https://models.dev/api.json`,
  scoped to the `anthropic` and `openai` provider objects.
  Rationale: baikai only ships first-party Anthropic and OpenAI providers plus two
  OpenAI-compatible hosts (`deepseek`, `openrouter`). pi-mono pulls ~25 providers from
  models.dev + OpenRouter API + Vercel AI Gateway + NVIDIA NIM; almost none apply to baikai.
  models.dev already carries Anthropic and OpenAI with the exact fields we need
  (`cost.{input,output,cache_read,cache_write}`, `limit.{context,output}`, `reasoning`,
  `modalities.input`, `tool_call`). Deepseek/openrouter refresh is deferred (see below).
  Date: 2026-06-15

- Decision: Filter to tool-capable chat models and exclude Responses-API-only models for the
  `openai` catalog.
  Rationale: `baikai/data/models/openai.json` declares `"api": "openai-chat-completions"`,
  and `Baikai.Api` (`baikai/src/Baikai/Api.hs`) has no `openai-responses` tag — its only
  values are `OpenAIChatCompletions`, `AnthropicMessages`, `OpenAICompletionsCli`,
  `AnthropicMessagesCli`. Models that only work on OpenAI's Responses API (`*-pro`,
  `*-codex`, `*-deep-research`) cannot be represented or correctly called, so they must be
  excluded. This matches the curation used in the manual refresh in commit that immediately
  precedes this plan.
  Date: 2026-06-15

- Decision: An explicit, hand-maintained override layer is in scope and is the point of the
  port, not an afterthought.
  Rationale: Upstream catalog data is not fully trustworthy. pi-mono carries dozens of
  corrections (e.g. `generate-models.ts` hard-fixes Claude Opus 4.5 cache pricing because
  "models.dev has 3x the correct pricing"). A pure passthrough would re-introduce the very
  staleness/wrongness this plan exists to fix. The override layer is small, data-driven, and
  each entry must carry a dated comment justifying it.
  Date: 2026-06-15

- Decision: Defer refreshing `deepseek.json` and `openrouter.json` to a follow-up.
  Rationale: They use different shapes/sources (OpenRouter has its own
  `https://openrouter.ai/api/v1/models` endpoint in pi-mono) and are lower-churn. Scoping
  Milestones 1–4 to the two first-party providers keeps this plan deliverable and testable.
  The executable should be structured so adding a third provider is a localized change.
  Date: 2026-06-15

- Decision: Curation policy for `enabled`/inclusion is "current generations only," matching
  the existing curated style of the hand-maintained files (the pre-plan `anthropic.json` held
  only the 4.x line, not models.dev's full 25). The exact include/exclude sets live in the
  override layer so the policy is auditable in one place.
  Rationale: baikai's catalog is intentionally a curated short list, not an exhaustive
  mirror. Dumping every tool-capable id would contradict the project's established style and
  surface long-deprecated models.
  Date: 2026-06-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about baikai. Read it fully before editing anything.

baikai is a Haskell library that provides a provider-agnostic interface to AI model
providers. It is a multi-package repository; the package relevant here is `baikai`, rooted
at `baikai/` with its Cabal manifest at `baikai/baikai.cabal`. The toolchain is GHC 9.12.4
inside a Nix flake; you enter the dev shell with `nix develop` (or rely on `direnv` if
configured) from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`. Standard build
and test commands, run from the repo root, are `cabal build all` and `cabal test all`.

"Catalog" here means the set of models baikai knows how to talk to, with their prices and
limits. The catalog has two representations:

1. **Source JSON**, hand-edited today, four files under `baikai/data/models/`:
   `anthropic.json`, `openai.json`, `deepseek.json`, `openrouter.json`. Each file describes
   one provider and a list of models. The exact schema (parsed by `CatalogFile` in
   `baikai/gen/GenModels.hs`) is:

   ```json
   {
     "provider": "openai",
     "baseUrl": "https://api.openai.com",
     "api": "openai-chat-completions",
     "compat": "auto",
     "models": [
       {
         "id": "gpt-5.4",
         "name": "GPT-5.4",
         "reasoning": true,
         "input": ["text", "image"],
         "cost": { "input": 2.5, "output": 15.0, "cacheRead": 0.25, "cacheWrite": 0.0 },
         "contextWindow": 1050000,
         "maxOutputTokens": 128000,
         "enabled": true
       }
     ]
   }
   ```

   The top-level `api` is parsed by `parseApi` in `baikai/src/Baikai/Api.hs`; valid values
   are exactly `"openai-chat-completions"`, `"anthropic-messages"`, `"openai-completions-cli"`,
   `"anthropic-messages-cli"`. There is no Responses-API value. The top-level `compat` is
   either the string `"auto"` (meaning "auto-detect compatibility quirks from `baseUrl`") or
   a structured object `{ "kind": "openai-completions" | "anthropic-messages", ... }`; all
   four existing files use `"auto"`. `input` values map to `Baikai.Model.InputModality`,
   which has exactly two constructors, `InputText` and `InputImage` — there is no `pdf`
   modality, so upstream `pdf` must be dropped. Costs are US dollars per **million** tokens.

2. **Generated Haskell**, the file `baikai/src/Baikai/Models/Generated.hs`, which begins with
   `-- AUTO-GENERATED by baikai-gen-models. Do not edit by hand.` It contains one
   `Baikai.Model.Model` record per enabled model. You never edit this by hand.

The generator that turns (1) into (2) is the Cabal executable `baikai-gen-models`, source at
`baikai/gen/GenModels.hs`, declared in `baikai/baikai.cabal` (stanza
`executable baikai-gen-models`, deps: `aeson`, `baikai`, `base`, `bytestring`, `containers`,
`directory`, `filepath`, `scientific`, `text`). You run it from the repo root with
`cabal run baikai-gen-models`; it prints e.g. `Wrote …/Generated.hs (30 enabled models)`.
It reads every `.json` in `baikai/data/models/`, keeps entries with `"enabled": true`, sorts
deterministically, and writes byte-stable output. A regression test,
`baikai/test/CatalogSpec.hs` (test group "Baikai.Models.Generated"), re-runs the generator
into a temp file and asserts byte-identity with the committed `Generated.hs`; if they differ
the test fails with "Generated.hs is out of sync with data/models/*.json." This is why the
generator and any formatter must not fight over `Generated.hs` (see Surprises).

The `Baikai.Model.Model` record (defined in `baikai/src/Baikai/Model.hs`) has fields
`modelId, name, api, provider, baseUrl, reasoning, input, cost, contextWindow,
maxOutputTokens, headers, compat`. Costs are `ModelCost { inputCost, outputCost,
cacheReadCost, cacheWriteCost }` stored as exact `Rational`. This plan does not change any of
these types; it only produces the JSON the generator already consumes.

The thing we are porting lives **outside** this repository, in a sibling project: pi-mono,
at `/Users/shinzui/Keikaku/hub/agents/pi-mono`. Its scraper is the TypeScript file
`packages/ai/scripts/generate-models.ts`. Read it for reference but do not depend on it at
runtime. Its shape (the fields it reads from models.dev) is what we mirror:

- It fetches `https://models.dev/api.json` (a single ~2.3 MB JSON document keyed by provider
  id; `data.openai.models` and `data.anthropic.models` are objects keyed by model id).
- Per provider it iterates models, keeps only `tool_call === true`, and maps:
  `id`, `name`, `reasoning === true`, `modalities.input` (image → `["text","image"]` else
  `["text"]`), `cost.input/output/cache_read/cache_write` (defaulting missing to 0),
  `limit.context` → `contextWindow`, `limit.output` → `maxOutputTokens`.
- It then applies a large set of per-model corrections and capability maps before emitting.

baikai's own scraper does not need the capability maps (those feed pi-mono's `thinkingLevelMap`,
which baikai's `Model` does not have). baikai needs only: fetch, the field mapping above, the
curation include/exclude policy, and a price/flag override layer.

The decision to build this was pre-authorized by the existing, checked-in plan
`docs/plans/12-generated-model-catalog.md` (its Decision Log defers the scraper to "a future
plan"). That file is the canonical description of the generator and catalog format; this plan
reproduces the parts a novice needs so you do not have to read it, but it is there if you
want the original rationale.


## Plan of Work

The work is four milestones. Each is independently verifiable and leaves the repository
building and testing green. The guiding principle is to make the *pure, testable* core
(parse upstream JSON → normalize → render catalog JSON) exist and be tested before adding the
*impure* network fetch on top, so almost all logic is covered by deterministic unit tests
against a checked-in fixture rather than a live HTTP call.

### Milestone 1 — Offline normalizer (no network)

Scope: stand up a new executable `baikai-fetch-models` and the module `FetchModels.hs`, but
in this milestone it only reads a local models.dev-shaped JSON file (passed with
`--from-file`) and prints baikai catalog JSON to stdout. No network yet.

Add an executable stanza to `baikai/baikai.cabal` modeled exactly on the existing
`executable baikai-gen-models` stanza (same `import: common-options`, a new
`hs-source-dirs: fetch`, `main-is: FetchModels.hs`). Dependencies for this milestone:
`aeson`, `baikai`, `base`, `bytestring`, `containers`, `directory`, `filepath`, `scientific`,
`text`, `vector`. Use the same hand-rolled `getArgs` style argument parsing that
`GenModels.hs` uses (it parses `--models-dir`/`--out` by walking the args list) rather than
introducing `optparse-applicative`, to keep the dependency footprint identical to the
existing generator. If you prefer `optparse-applicative`, that is acceptable but add it to
the stanza and note it in the Decision Log.

Create `baikai/fetch/FetchModels.hs`. Define a small record `UpstreamModel` mirroring the
fields we read from models.dev (`id`, `name`, `tool_call`, `reasoning`, `limit.context`,
`limit.output`, `cost.input`, `cost.output`, `cost.cache_read`, `cost.cache_write`,
`modalities.input`) with a `FromJSON` instance tolerant of missing fields (use `.:?` with
defaults, exactly as pi-mono defaults missing numbers to 0 and missing arrays to empty).
Define the output records `CatalogModel` and `Catalog` whose `ToJSON` produces the exact
catalog schema shown in Context (note: `input` must render inline as `["text", "image"]`;
costs render as JSON numbers; `enabled` is always `true` for emitted models). Write a pure
function:

```haskell
normalizeProvider :: ProviderSpec -> Map Text UpstreamModel -> Catalog
```

where `ProviderSpec` carries the provider id, `baseUrl`, `api` string, and the curation
predicate (which model ids to keep). `normalizeProvider` filters to `tool_call == True`,
applies the curation predicate, maps each `UpstreamModel` to a `CatalogModel` using the field
mapping from Context (drop `pdf` from modalities; missing costs → 0; missing limits → a
documented fallback such as 0 so a human notices), and sorts models by id for deterministic
output.

Render with `Data.Aeson.Encode.Pretty` if you add `aeson-pretty`, OR — to avoid a new
dependency and to exactly control formatting (2-space indent, inline `input` array, trailing
`.0` on integer-valued costs to match the existing files) — hand-write a small renderer the
way `GenModels.hs` hand-writes Haskell. Match the existing files' formatting closely enough
that re-running the tool on an unchanged upstream produces a minimal `git diff`. State which
approach you chose in the Decision Log.

Add `baikai/test/FetchModelsSpec.hs` and register it in the `baikai-test` suite's
`other-modules` in `baikai/baikai.cabal`. Check in a tiny fixture
`baikai/test/fixtures/models-dev-sample.json` containing a handful of OpenAI and Anthropic
models (include at least one with `tool_call: false` to prove it is filtered, one with a
`pdf` modality to prove `pdf` is dropped, and one missing a cache cost to prove the default).
Assert the normalized `Catalog` for that fixture equals an expected value.

Acceptance: from the repo root,
`cabal run baikai-fetch-models -- --from-file baikai/test/fixtures/models-dev-sample.json --provider openai`
prints catalog JSON whose `models` list contains exactly the curated, tool-capable OpenAI
entries; `cabal test baikai` passes including the new `FetchModelsSpec`.

### Milestone 2 — Live fetch and in-place write

Scope: add the network and file-writing side so the tool, run with no `--from-file`, fetches
`https://models.dev/api.json` and rewrites `baikai/data/models/anthropic.json` and
`baikai/data/models/openai.json`.

Add `http-client` and `http-client-tls` to the `baikai-fetch-models` stanza (these are
already used elsewhere in the repo — see `baikai-openai`'s cabal file — so they are in the
dependency set). Add an `IO` function `fetchUpstream :: String -> IO ByteString` that GETs a
URL with a TLS manager (`newTlsManager`), checks for a 2xx status, and returns the body. Keep
it tiny; no retries needed for a manual tool.

Add flags: `--from-url URL` (default `https://models.dev/api.json`), `--from-file PATH`
(offline override used by tests and debugging), `--out-dir DIR` (default
`baikai/data/models`, resolved relative to the package dir the same way `GenModels.hs`
resolves its defaults by walking up to `baikai.cabal`), and `--provider {openai|anthropic|all}`
(default `all`). When `--out-dir` is given (or defaulted) and no `--stdout` flag is set, write
each provider's catalog to `<out-dir>/<provider>.json`; otherwise print to stdout.

Acceptance: from the repo root, `cabal run baikai-fetch-models` rewrites the two JSON files;
`git diff baikai/data/models` shows only data changes (no structural churn);
`cabal run baikai-gen-models` then succeeds; `cabal test baikai` passes (the `CatalogSpec`
round-trip is green because the generator was re-run). Because the network is involved, also
verify the offline path still works:
`cabal run baikai-fetch-models -- --from-file baikai/test/fixtures/models-dev-sample.json --stdout`.

### Milestone 3 — Override layer

Scope: add the hand-maintained corrections that make the output trustworthy, mirroring
pi-mono's correction pattern but as a small data table.

In `FetchModels.hs`, define an `overrides` structure with three kinds of entry, applied after
`normalizeProvider`: (a) **price/flag corrections** keyed by `(provider, modelId)` that
overwrite specific `cost.*`, `reasoning`, `contextWindow`, or `maxOutputTokens` fields;
(b) an **include set / exclude set** per provider that encodes the curation policy (the
predicate from Milestone 1 becomes data here); (c) optional **name overrides** for cleaner
display names (e.g. strip a models.dev `" (latest)"` suffix, which the manual refresh had to
do for `claude-opus-4-5` etc.). Each correction must have an adjacent dated comment stating
why upstream is wrong, exactly as `generate-models.ts` documents its Opus 4.5 cache-price fix.

Add the curation include lists discovered during the manual refresh as the initial policy:
for Anthropic, the current generations (`claude-opus-4-8/4-7/4-6/4-5`,
`claude-sonnet-4-6/4-5`, `claude-haiku-4-5`, `claude-fable-5`); for OpenAI, the
chat-completions-compatible current line (`gpt-5.5`, `gpt-5.4`/`-mini`/`-nano`, `gpt-5.2`,
`gpt-5.1`, `gpt-5`/`-mini`/`-nano`, `gpt-4.1`/`-mini`/`-nano`, `gpt-4o`/`-mini`, `o3`,
`o3-mini`, `o4-mini`, `o1`), explicitly excluding Responses-API-only `*-pro`/`*-codex`/
`*-deep-research`.

Acceptance: add a fixture entry whose upstream cache price is deliberately wrong and a test
asserting the override corrects it; `cabal test baikai` passes. Running the live tool and
diffing should show the corrected values, not the raw upstream ones.

### Milestone 4 — Documentation and the treefmt guardrail

Scope: make the workflow discoverable and prevent the known formatting trap.

Update `baikai/README.md` (the "Develop" section that currently documents
`cabal run baikai-gen-models`) to describe the two-step refresh:
`cabal run baikai-fetch-models` then `cabal run baikai-gen-models`, then review `git diff`.
Add a header comment in `FetchModels.hs` stating the curation policy and the override
philosophy. Finally, resolve the pre-commit/treefmt conflict recorded in Surprises so a
maintainer can commit a regenerated `Generated.hs` without `--no-verify`: either fix
`nix/pre-commit.nix` so the `treefmt` hook honors `nix/treefmt.nix`'s
`settings.global.excludes`, or change `GenModels.hs` to emit fourmolu's trailing-comma layout
so the formatter no longer rewrites the file. Prefer the pre-commit fix because it keeps the
generator's output stable and is the smaller, more local change; if it proves intractable,
fall back to the generator change. Record the choice in the Decision Log.

Acceptance: after a fresh `cabal run baikai-fetch-models && cabal run baikai-gen-models`, a
normal `git commit` (no `--no-verify`) of `Generated.hs` succeeds and `cabal test baikai`
stays green.


## Concrete Steps

All commands are run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`, inside
the Nix dev shell (`nix develop`).

Inspect the reference scraper (read-only, in the sibling repo):

```bash
sed -n '1,60p;549,672p' /Users/shinzui/Keikaku/hub/agents/pi-mono/packages/ai/scripts/generate-models.ts
```

You should see the `ModelsDevModel` interface (the upstream field shape) and the
`loadModelsDevData` function's OpenAI/Anthropic branches (the field mapping). These are the
only parts of that 2,240-line file this plan needs.

Confirm the upstream document shape before coding (one-off, requires network):

```bash
curl -fsSL https://models.dev/api.json -o /tmp/models_dev.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/models_dev.json'))
m = d['openai']['models']['gpt-5.4']
print({k: m.get(k) for k in ('name','tool_call','reasoning','cost','limit','modalities')})
PY
```

Expected (values may drift; shape is the point):

```text
{'name': 'GPT-5.4', 'tool_call': True, 'reasoning': True,
 'cost': {'input': 2.5, 'output': 15, 'cache_read': 0.25, ...},
 'limit': {'context': 1050000, 'output': 128000},
 'modalities': {'input': ['text','image','pdf'], 'output': ['text']}}
```

Milestone 1 build/run/test (after editing `baikai/baikai.cabal`, adding
`baikai/fetch/FetchModels.hs`, `baikai/test/FetchModelsSpec.hs`, and the fixture):

```bash
cabal build baikai
cabal run baikai-fetch-models -- --from-file baikai/test/fixtures/models-dev-sample.json --provider openai
cabal test baikai
```

Expected: the run prints a JSON object with `"provider": "openai"` and a `models` array of
the curated, tool-capable fixture entries; the test prints `All NN tests passed` including a
`Baikai.FetchModels` group.

Milestone 2 live refresh:

```bash
cabal run baikai-fetch-models
git --no-pager diff --stat baikai/data/models
cabal run baikai-gen-models
cabal test baikai
```

Expected: `baikai/data/models/anthropic.json` and `openai.json` show as modified (data only),
`baikai-gen-models` prints `Wrote …/Generated.hs (NN enabled models)`, and `cabal test baikai`
passes including `Baikai.Models.Generated regenerating from data/models produces no diff: OK`.

Committing a regeneration (note the trailers required by this plan):

```bash
git add baikai/data/models/anthropic.json baikai/data/models/openai.json \
        baikai/src/Baikai/Models/Generated.hs
git commit -m "chore(baikai): refresh model catalogs via baikai-fetch-models

ExecPlan: docs/plans/24-port-pi-mono-model-catalog-scraper-to-haskell-for-baikai.md
Intention: intention_01kv6nhsa5e8mvkjj12ay1ts26"
```

Until Milestone 4 fixes the pre-commit/treefmt interaction, this commit may require
`--no-verify` because the pre-commit hook reformats the excluded `Generated.hs` (see
Surprises & Discoveries). After Milestone 4, plain `git commit` must work.


## Validation and Acceptance

The plan is "done" when a maintainer can refresh the Anthropic and OpenAI catalogs with one
command, the result flows through the existing generator unchanged, and the override layer
demonstrably corrects at least one known-bad upstream value. Concretely:

Unit-level (deterministic, no network), run from the repo root:

```bash
cabal test baikai
```

Expected: `All NN tests passed`, including a `Baikai.FetchModels` group with at least these
cases passing — a `tool_call: false` fixture model is excluded; a model whose upstream
`modalities.input` contains `pdf` emits `"input": ["text", "image"]` (no `pdf`); a model with
a missing `cache_read` emits `"cacheRead": 0.0`; and (after Milestone 3) a fixture model with
a deliberately wrong cache price emits the overridden value, not the upstream one.

End-to-end (requires network), run from the repo root:

```bash
cabal run baikai-fetch-models
git --no-pager diff --stat baikai/data/models
cabal run baikai-gen-models
cabal test baikai
```

Acceptance behaviors to observe:

1. `baikai-fetch-models` exits 0 and reports which providers it wrote (e.g.
   `Wrote baikai/data/models/openai.json (18 models)`).
2. `git diff baikai/data/models/openai.json` shows current models present (e.g. a `gpt-5.x`
   id) and shows that excluded Responses-API-only ids (`*-pro`, `*-codex`, `*-deep-research`)
   are absent.
3. `baikai-gen-models` regenerates `Generated.hs` without error.
4. `cabal test baikai` passes, crucially including
   `Baikai.Models.Generated regenerating from data/models produces no diff: OK` — this proves
   the fetched JSON is consistent with the regenerated Haskell.

Proof the change is effective beyond compilation: pick a model whose price changed upstream
since the last manual edit, run the two commands, and show the `git diff` line where the cost
moved to the correct value. Equivalently, the override test (case above) fails before the
override is added and passes after — include that before/after in the milestone's Progress
notes when implementing.

Negative/robustness checks:

```bash
cabal run baikai-fetch-models -- --from-url https://models.dev/does-not-exist
```

Expected: non-zero exit, a clear error message, and no modification to any file under
`baikai/data/models` (verify with `git status`).


## Idempotence and Recovery

The tool is safe to run repeatedly. `baikai-fetch-models` overwrites the two target JSON
files wholesale each run; running it twice against the same upstream produces the same files,
so there is no drift. Because the output is deterministic (models sorted by id, fixed
formatting), re-running on an unchanged upstream yields an empty `git diff`.

Recovery from a bad refresh is `git`: the catalog JSON and `Generated.hs` are all tracked, so
`git checkout -- baikai/data/models baikai/src/Baikai/Models/Generated.hs` restores the
previous committed state. Always review `git diff` before committing — an upstream change
could, for example, drop a model or change a price unexpectedly; the diff is the safety gate.

If the network fetch fails (models.dev down, no connectivity), the tool should exit non-zero
with a clear message and write nothing; use `--from-file` with a previously saved
`/tmp/models_dev.json` to proceed offline. Never write partial output: build the full
`Catalog` for a provider in memory and write it in one `writeFile`, so a crash mid-run cannot
leave a truncated JSON file.

The override layer is purely additive and order-independent per `(provider, modelId)` key;
adding or removing an override only affects that model. If an override references a model id
that no longer exists upstream, the tool should warn (so stale overrides get noticed) but not
fail.


## Interfaces and Dependencies

External service: `https://models.dev/api.json` — a single JSON document, keyed by provider
id, where `data.<provider>.models` is an object keyed by model id. This is the upstream
catalog. No API key is required; it is a public GET. pi-mono's `loadModelsDevData` in
`/Users/shinzui/Keikaku/hub/agents/pi-mono/packages/ai/scripts/generate-models.ts` is the
reference reader.

Libraries (all already in the repo's dependency set; `http-client`/`http-client-tls` are used
by `baikai-openai`, the rest by `baikai-gen-models`):

- `aeson` — parse the upstream document and the fixture; render catalog JSON (or hand-render).
- `http-client` + `http-client-tls` — `newTlsManager`, `httpLbs`, `parseRequest` for the GET.
- `bytestring`, `text`, `containers` (`Data.Map.Strict`), `scientific`, `vector` — data
  plumbing.
- `directory`, `filepath` — locate the package dir and write `<out-dir>/<provider>.json`,
  resolving defaults the same way `GenModels.hs` does (walk up to `baikai.cabal`).
- `tasty` + `tasty-hunit` — the `FetchModelsSpec` unit tests, matching the existing
  `baikai-test` suite.

New files:

- `baikai/fetch/FetchModels.hs` — the executable's `Main`, plus the pure core.
- `baikai/test/FetchModelsSpec.hs` — unit tests, registered in `other-modules` of the
  `baikai-test` stanza in `baikai/baikai.cabal`.
- `baikai/test/fixtures/models-dev-sample.json` — a small upstream-shaped fixture.

Cabal changes in `baikai/baikai.cabal`: a new `executable baikai-fetch-models` stanza
(`hs-source-dirs: fetch`, `main-is: FetchModels.hs`), and the new test module added to the
existing `baikai-test` suite. Optionally add `build-tool-depends: baikai:baikai-fetch-models`
to the test suite only if a test shells out to the executable; the unit tests should instead
call the pure functions directly and need no build-tool dependency.

Signatures that must exist by the end of each milestone (names are guidance; keep them stable
once chosen):

End of Milestone 1 (pure core, offline):

```haskell
-- Upstream shape (subset of models.dev fields we consume)
data UpstreamModel = UpstreamModel
  { uId        :: Text
  , uName      :: Maybe Text
  , uToolCall  :: Bool
  , uReasoning :: Bool
  , uCtx       :: Maybe Integer
  , uMaxOut    :: Maybe Integer
  , uCostIn    :: Maybe Scientific
  , uCostOut   :: Maybe Scientific
  , uCacheRead :: Maybe Scientific
  , uCacheWrite:: Maybe Scientific
  , uInputMods :: [Text]
  }
instance FromJSON UpstreamModel

data ProviderSpec = ProviderSpec
  { psProvider :: Text          -- "openai" | "anthropic"
  , psBaseUrl  :: Text
  , psApi      :: Text          -- "openai-chat-completions" | "anthropic-messages"
  , psInclude  :: Text -> Bool  -- curation predicate (becomes data in M3)
  }

data CatalogModel = CatalogModel { {- id,name,reasoning,input,cost,contextWindow,maxOutputTokens,enabled -} }
data Catalog      = Catalog { cProvider :: Text, cBaseUrl :: Text, cApi :: Text, cModels :: [CatalogModel] }
instance ToJSON Catalog   -- emits the exact catalog schema

normalizeProvider :: ProviderSpec -> Map Text UpstreamModel -> Catalog
renderCatalog     :: Catalog -> ByteString   -- formatting matched to existing files
```

End of Milestone 2 (impure shell):

```haskell
fetchUpstream :: String -> IO ByteString                 -- GET a URL via TLS manager
parseUpstream :: ByteString -> Either String (Map Text (Map Text UpstreamModel))
                                                          -- provider -> (modelId -> model)
data Options = Options { optFromUrl :: String, optFromFile :: Maybe FilePath
                       , optOutDir :: Maybe FilePath, optProvider :: ProviderSel, optStdout :: Bool }
main :: IO ()
```

End of Milestone 3 (overrides):

```haskell
data Override = Override
  { ovProvider :: Text, ovModelId :: Text
  , ovSetCostIn :: Maybe Scientific, ovSetCacheRead :: Maybe Scientific {- etc -}
  , ovName :: Maybe Text, ovReasoning :: Maybe Bool }
overrides       :: [Override]                 -- hand-maintained, each with a dated comment
applyOverrides  :: [Override] -> Catalog -> Catalog
```

End of Milestone 4: no new signatures; documentation and the `nix/pre-commit.nix` (or
`GenModels.hs`) change described in the Plan of Work.

Out of scope / deferred (do not implement here): refreshing `deepseek.json` and
`openrouter.json`; the OpenRouter and Vercel AI Gateway and NVIDIA NIM sources pi-mono also
reads; any `thinkingLevelMap`/effort capability metadata (baikai's `Model` has no such
field); structured non-`"auto"` `compat` emission (all current catalogs use `"auto"`).
