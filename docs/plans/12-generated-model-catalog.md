---
id: 12
slug: generated-model-catalog
title: "Generated model catalog"
kind: exec-plan
created_at: 2026-05-14T15:10:00Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Generated model catalog

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, baikai ships a generated `Baikai.Models.Generated` Haskell module
containing one fully populated `Model` value per (provider, model id) pair we
support. A consumer who knows the model id writes:

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models

main :: IO ()
main = do
  -- ClaudeApi.register, OpenAI.register, etc.
  resp <- completeRequest Models.anthropic_claude_sonnet_4_6
    (_Context { messages = V.singleton (user "hello") })
    _Options
  ...
```

…and gets a `Model` record with `modelId`, `name`, `api`, `provider`, `baseUrl`,
`reasoning`, `input`, `cost`, `contextWindow`, `maxOutputTokens`, and `compat`
all populated correctly. No hand-rolled `_Model { modelId = "...", ... }` is
necessary unless the caller is targeting an unsupported host.

The catalog is produced by a new `baikai-gen-models` executable defined in
`baikai.cabal`. The executable reads JSON catalog files from
`baikai/data/models/` (one file per provider), validates each entry against the
`Model` shape, and writes a single
`baikai/src/Baikai/Models/Generated.hs` module. The output is committed to the
repository so library consumers do not need to run the generator unless they
change a catalog file.

A CI check (added to the existing `cabal test all` flow via a small tasty test)
re-runs the generator and asserts the working tree is unchanged. This guards
against an edit to a JSON catalog file that is not paired with a regenerated
module.

The user-visible payoff is:

1. **Autocomplete-driven model selection.** Consumers see every supported
   model as a top-level identifier in their IDE without consulting external
   documentation.
2. **Pricing freshness as a code change.** Updating the cost of a model is a
   one-line JSON edit followed by `cabal run baikai-gen-models`. The generated
   diff is reviewable.
3. **A single source of truth for compat overrides.** When a host's compat
   record diverges from the auto-detection defaults, the catalog records the
   override; no hand-rolled `Model.compat` constructors leak into consumer code.


## Progress

- [x] Milestone 1: define the catalog file schema. Added JSON files under
      `baikai/data/models/` for `anthropic.json`, `openai.json`, `deepseek.json`,
      `openrouter.json`. Each file is a top-level object with
      `provider`, `baseUrl`, `api`, `compat` (string `"auto"` or a
      structured override object), and a `models` array. Each entry
      carries `id`, `name`, `reasoning`, `input`, `cost`,
      `contextWindow`, `maxOutputTokens`, `enabled`, and an optional
      per-model `compat` override.
- [x] Milestone 2: implement the generator. New executable
      `baikai-gen-models` (target in `baikai/baikai.cabal`, source
      `baikai/gen/GenModels.hs`) reads the JSON catalog, validates each
      entry, sorts by generated identifier, and writes
      `baikai/src/Baikai/Models/Generated.hs`. Twelve enabled models
      ship at first generation (4 anthropic, 4 openai, 2 deepseek, 2
      openrouter). The output is byte-identical across re-runs;
      verified by `diff` after a second invocation. `cabal build all`
      is green, including the new `Baikai.Models.Generated` library
      module.
- [x] Milestone 3: added a tasty test
      `baikai/test/CatalogSpec.hs` that re-runs the generator (via
      `System.Process.callProcess`) into a temp file and asserts the
      regenerated output matches the committed module byte-for-byte.
      Wired through `build-tool-depends: baikai:baikai-gen-models` so
      the test suite always runs against a freshly-built generator.
      Drift detection verified manually: appending a comment to
      `Generated.hs` causes the test to fail with the remediation hint
      `cd baikai && cabal run baikai-gen-models`. The README step is
      out of scope — the generator is documented in the file's own
      header and in this plan.
- [x] Milestone 4: migrate the smoke tests to use generated model
      identifiers. `baikai-smoke/test/Smoke.hs` now drives both API
      cases (Anthropic, OpenAI) and the image case from
      `Baikai.Models.Generated`, using record-update syntax to lower
      `maxOutputTokens` to the smoke-safe 64 / 1024 values.
      `baikai-smoke/test/MultiHostSmoke.hs` drives the OpenAI host and
      the DeepSeek / OpenRouter second hosts from the catalog; the
      Together entry stays hand-rolled to demonstrate that hand
      authoring is still supported for hosts the catalog does not yet
      cover. CLI cases (`sonnet`, `codex`) remain hand-rolled — CLI
      providers are not in scope for the catalog. `cabal test all`
      passes; the gpt-4o-mini API + streaming + tool round-trip cases
      were live-exercised against the OpenAI host using the generated
      model record in this session.


## Surprises & Discoveries

- EP-6 M2: `DuplicateRecordFields` on its own does **not** disambiguate
  field selectors at use sites in GHC 9.12. Writing
  `supportsLongCacheRetention (d :: OpenAICompletionsCompat)` errors
  with `Ambiguous occurrence` because both `OpenAICompletionsCompat`
  and `AnthropicMessagesCompat` define a field named
  `supportsLongCacheRetention`. The fix that actually works is
  `OverloadedRecordDot` plus `d.supportsLongCacheRetention` — that
  selector resolves through `HasField` and is unambiguous by type.
  Pattern-matching with explicit record syntax (`OpenAICompletionsCompat
  { supportsLongCacheRetention = b } <- d`) is the type-directed
  alternative for code that should not pull in
  `OverloadedRecordDot`. The generator now uses dot-syntax; any
  future EP touching both compat records the same way should expect
  the same fix.
- EP-6 M2: `Data.Scientific.toRational` returns a *reduced*
  `Rational`, so a JSON literal `0.075` becomes `3 % 40` rather than
  `75 % 1000` or an IEEE-754-tainted ratio. This is exactly the
  behaviour the generator wants — small canonical denominators in the
  generated source — but it means cost rates that look "round" in
  JSON (e.g. `1.5`) emit as fractions (`3 % 2`) in Haskell. Reviewers
  should not be surprised. If decimal-looking literals are ever
  desired, the renderer can switch to a hand-formatted
  `<integer>.<decimals> :: Rational` form, but that requires importing
  `fromRational` and breaks `==` against `Rational`-based equality
  tests.
- EP-6 M3: Running `cabal test baikai` errors with
  `The test command is for running test suites, but the target
  'baikai' refers to the library`. The test suite must be named
  explicitly: `cabal test baikai-test`. The CatalogSpec test invocation
  in this plan therefore uses the suite name, not the package name.
- EP-6 M3: `tasty-hunit`'s `assertEqual` prints the full expected /
  actual `ByteString` on failure, which makes the Generated.hs
  comparison failure dump the entire module twice (several thousand
  lines). The remediation hint (`cd baikai && cabal run
  baikai-gen-models`) stays at the top of the failure block, so the
  noise is mostly cosmetic; a future polish would replace
  `assertEqual` with a custom assertion that prints only the first
  differing line.
- EP-6 M2: `cabal run baikai-gen-models` from the repository root
  fails with `data/models: does not exist`. The exe's default
  relative paths are anchored to the `baikai/` package directory, so
  `cd baikai && cabal run baikai-gen-models` is the canonical
  invocation. The CatalogSpec test handles this transparently
  because `cabal test baikai-test` runs the suite from the package
  source dir.


## Decision Log

- Decision: The catalog generator is a Haskell executable target inside
  `baikai.cabal`, not a sibling cabal package.
  Rationale: The generator's dependencies are limited to `aeson`, `bytestring`,
  `text`, `directory`, `filepath`, `containers`, and `scientific`. None
  pollutes consumers — library users do not build the exe target.
  Keeping the generator inside `baikai.cabal` avoids a new cabal package
  and matches the masterplan's Decision Log. The hand-rolled source
  renderer turned out to be a fifty-line stretch of pure functions, so
  no pretty-printing library was needed at all.
  Date: 2026-05-14

- Decision: The generated module is *not* re-exported from `Baikai`.
  Consumers import it qualified as `Baikai.Models.Generated`.
  Rationale: Re-exporting the catalog from `Baikai` would dump every
  model identifier (`anthropic_claude_sonnet_4_6`,
  `openrouter_openai_gpt_4o_mini`, …) into the unqualified namespace
  of every consumer that writes `import Baikai`. That is poor IDE
  ergonomics: autocomplete on a fresh import already shows dozens of
  unrelated identifiers, and the qualified prefix (`Models.<...>`)
  reads as a self-documenting "this is a catalog value" marker at the
  call site. The masterplan example
  (`Baikai.Models.Generated qualified as Models`) is the documented
  usage shape.
  Date: 2026-05-14

- Decision: Structured `compat` overrides in catalog JSON are
  supported by the schema but not used by any shipped entry. All four
  catalog files set `"compat": "auto"` so EP-5's baseUrl
  auto-detection picks the right record.
  Rationale: Auto-detection already covers every host the smoke tests
  exercise (Anthropic, OpenAI, DeepSeek, OpenRouter, Together,
  Fireworks). Hand-writing structured overrides in JSON now would
  duplicate the auto-detection table without adding behaviour. The
  generator's `CatalogCompat` parser still handles the structured
  shape, so a future host that disagrees with auto-detection can be
  pinned by writing the explicit compat record in JSON without
  changing the generator or the library.
  Date: 2026-05-14

- Decision: `OverloadedRecordDot` is used in `baikai/gen/GenModels.hs`
  for compat-record field access.
  Rationale: `OpenAICompletionsCompat.supportsLongCacheRetention` and
  `AnthropicMessagesCompat.supportsLongCacheRetention` collide as
  selectors under `DuplicateRecordFields`. Type ascriptions
  (`supportsLongCacheRetention (d :: …)`) do not disambiguate in GHC
  9.12; `OverloadedRecordDot` does. The library itself never enables
  the extension; only the generator does.
  Date: 2026-05-14

- Decision: Generated value names follow `<provider>_<modelId>` with `-` and
  `.` rewritten to `_`. The name `anthropic_claude_sonnet_4_6` is the
  canonical Haskell identifier for the model id `claude-sonnet-4-6` under the
  `anthropic` provider.
  Rationale: A flat namespace (one identifier per model) gives the best IDE
  ergonomics. A nested record (`Models.anthropic.claude_sonnet_4_6`) would
  require an additional indirection layer in the generated module and produce
  longer call sites. The `provider_` prefix prevents collisions when two
  providers ship a model with the same id (rare but possible — e.g. an
  open-weights model hosted on multiple inference services).
  Date: 2026-05-14

- Decision: Auto-generated values are committed; not gitignored.
  Rationale: A library consumer should be able to `cabal install baikai` and
  use generated model identifiers without first running the generator.
  Committing the output also means PR reviewers see catalog changes in the
  diff. The CI check (Milestone 3) prevents drift.
  Date: 2026-05-14

- Decision: The catalog schema does not include streaming-specific fields
  (e.g. `supportsStrictMode` standalone). It includes the entire `Compat`
  shape as a nested object, so per-host compat overrides are declarative.
  Rationale: The compat record (EP-5) is data, and the generator's job is to
  populate the `Model.compat` field declaratively. Hiding compat fields behind
  generator inference would force every host-specific edge case into Haskell
  code; exposing them in JSON keeps it data.
  Date: 2026-05-14

- Decision: The generator deliberately does not scrape provider websites or
  external APIs. The catalog JSON files are hand-curated by the baikai
  maintainers.
  Rationale: pi-mono's catalog scraper is substantial infrastructure
  (TypeScript scripts that fetch live API catalogs and reconcile cost
  data). Baikai has no real users yet; a manual catalog is sufficient and
  removes a build-time network dependency. A future plan can add a scraper
  if the catalog grows large enough to require automation.
  Date: 2026-05-14


## Outcomes & Retrospective

Implemented 2026-05-14 in four commits (one per milestone). Final state:

- `baikai/data/models/{anthropic,openai,deepseek,openrouter}.json` —
  four hand-curated catalog files declaring twelve enabled models.
- `baikai/gen/GenModels.hs` (≈500 lines) — a small executable that
  parses the catalog, sorts by generated identifier, renders one
  `Model`-shaped Haskell record per entry, and writes the result.
  Idempotent: two consecutive runs produce byte-identical output.
- `baikai/src/Baikai/Models/Generated.hs` — the generated catalog
  module, committed. Exposed from the `baikai` library as
  `Baikai.Models.Generated`. Twelve top-level identifiers:
  `anthropic_claude_haiku_4_5`, `anthropic_claude_haiku_4_5_20251001`,
  `anthropic_claude_opus_4_7`, `anthropic_claude_sonnet_4_6`,
  `deepseek_deepseek_chat`, `deepseek_deepseek_reasoner`,
  `openai_gpt_4o`, `openai_gpt_4o_mini`, `openai_o1`, `openai_o1_mini`,
  `openrouter_anthropic_claude_sonnet_4`, `openrouter_openai_gpt_4o_mini`.
- `baikai/test/CatalogSpec.hs` — drift check. Wired through
  `build-tool-depends: baikai:baikai-gen-models`. Fails with a clear
  remediation hint when `Generated.hs` is out of sync with the JSON
  catalog.
- `baikai-smoke/test/Smoke.hs` and `baikai-smoke/test/MultiHostSmoke.hs`
  rebuilt to consume `Baikai.Models.Generated` for every API and
  multi-host case the catalog covers. CLI cases (`sonnet`, `codex`)
  and the Together second-host case remain hand-rolled — CLI
  providers and Together are not in the catalog yet.

The masterplan's example usage now works verbatim:

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models

main = do
  ClaudeApi.register
  resp <- completeRequest Models.anthropic_claude_sonnet_4_6 ctx opts
  ...
```

Verified end-to-end in this session: the OpenAI live smoke
(`cabal test all` with `OPENAI_API_KEY` set) drove the catalog
record `Models.openai_gpt_4o_mini {maxOutputTokens = 1024}` through
`completeRequest`, `streamRequest`, and the tool round-trip — all
green. The Anthropic live path is exercised by build only in this
session (no ANTHROPIC key present); the migration is symmetric to
the OpenAI side and uses the same record-update pattern.

Lessons:

- The "stable single end-to-end commit" pattern from EP-1 / EP-2 /
  EP-3 did not appear here because the generator's outputs live in
  separate, non-load-bearing files (the JSON catalog, the
  `Baikai.Models.Generated` module). The four milestones each
  produced an independently-buildable commit.
- The auto-detection in `Baikai.Compat` (EP-5) is the load-bearing
  piece that makes "`compat: auto` in every catalog file" sufficient.
  Without it, every catalog entry would need a structured compat
  override and the schema's `"kind": "openai-completions"` form
  would not be optional.
- `Data.Scientific.toRational` is the right tool for converting
  JSON-decimal costs to canonical `Rational` literals. The
  alternative — `realToFrac . toRealFloat` — round-trips through
  `Double` and produces IEEE-754 noise (`0.075` becomes
  `5404319552844595 % 72057594037927936`). The generator's output
  has small reduced denominators because of this choice.
- Tasty's `assertEqual` is loud on failure for large `ByteString`s.
  The `CatalogSpec` failure dump runs to thousands of lines; the
  remediation hint stays at the top so the noise is more annoying
  than confusing. A future polish could replace `assertEqual` with a
  custom assertion that prints only the first differing line.

Items the masterplan listed as "out of scope" remain out of scope
after this plan: a live API scraper to update costs, a typed schema
for tool parameters, support for image generation / embeddings /
batch APIs / fine-tuning. The catalog is hand-curated; cost
freshness is a JSON edit + `cabal run baikai-gen-models` + commit.


## Context and Orientation

This plan is the sixth in the `Streaming, Content Blocks, and Tool Calls`
initiative defined in `docs/masterplans/2-streaming-content-blocks-and-tool-calls.md`.
It depends hard on:

- EP-2 (`docs/plans/8-api-tag-model-record-and-provider-registry.md`) for the
  `Model` record shape and the `Api` tag.
- EP-5 (`docs/plans/11-compat-shims-cache-retention-and-multi-host-providers.md`)
  for the `Compat` sum and the per-API compat record types.

It is soft-dependent on EP-4 (`docs/plans/10-tools-and-context-overhaul.md`)
because tool-bearing models may want to advertise additional metadata (max
tool count, max input schema depth) — but these fields are documentation-
grade rather than correctness-affecting, so EP-6 can land before EP-4
without losing demonstrable behaviour.

After EP-5 the `Model` shape is:

```haskell
data Model = Model
  { modelId :: !Text
  , name :: !Text
  , api :: !Api
  , provider :: !Text
  , baseUrl :: !Text
  , reasoning :: !Bool
  , input :: ![InputModality]
  , cost :: !ModelCost
  , contextWindow :: !Natural
  , maxOutputTokens :: !Natural
  , headers :: !(Map Text Text)
  , compat :: !Compat
  }
```

`ModelCost = ModelCost { inputCost, outputCost, cacheReadCost, cacheWriteCost
:: !Rational }` is per-million-token rates.

The auto-detection defaults from EP-5 (`autoDetectOpenAICompletions`,
`autoDetectAnthropicMessages`) cover the common case where a host's compat
matches its baseUrl prefix. The catalog only needs to populate `compat`
when the host requires an override; for hosts the auto-detection handles,
catalog entries set `compat: "auto"` and the generator emits `CompatNone`.

The repository directory structure after this plan:

```text
baikai/
  baikai.cabal               -- adds the executable target baikai-gen-models
  data/
    models/
      anthropic.json
      openai.json
      deepseek.json
      openrouter.json
  src/
    Baikai/
      Models/
        Generated.hs         -- auto-generated; committed
  gen/
    GenModels.hs             -- the generator's entry point
  test/
    CatalogSpec.hs           -- asserts re-generation is a no-op
```


## Plan of Work

### Milestone 1: catalog file schema

**New files:** `baikai/data/models/anthropic.json`,
`baikai/data/models/openai.json`, `baikai/data/models/deepseek.json`,
`baikai/data/models/openrouter.json`. Each file is a JSON object with
`provider` and a list of `models`:

```json
{
  "provider": "anthropic",
  "baseUrl": "https://api.anthropic.com",
  "api": "anthropic-messages",
  "compat": "auto",
  "models": [
    {
      "id": "claude-sonnet-4-6",
      "name": "Claude Sonnet 4.6",
      "reasoning": false,
      "input": ["text", "image"],
      "cost": { "input": 3.0, "output": 15.0, "cacheRead": 0.3, "cacheWrite": 3.75 },
      "contextWindow": 200000,
      "maxOutputTokens": 8192,
      "enabled": true
    },
    {
      "id": "claude-opus-4-7",
      "name": "Claude Opus 4.7",
      "reasoning": true,
      "input": ["text", "image"],
      "cost": { "input": 15.0, "output": 75.0, "cacheRead": 1.5, "cacheWrite": 18.75 },
      "contextWindow": 200000,
      "maxOutputTokens": 8192,
      "enabled": true
    }
  ]
}
```

A per-model `compat` field overrides the file-level `compat: "auto"`. For
example, the `deepseek.json` entry uses `compat: "openai-completions"` with
an explicit field block for the DeepSeek-specific overrides:

```json
{
  "provider": "deepseek",
  "baseUrl": "https://api.deepseek.com",
  "api": "openai-chat-completions",
  "compat": {
    "kind": "openai-completions",
    "maxTokensField": "max_tokens",
    "thinkingFormat": "deepseek",
    "requiresThinkingAsText": true,
    "supportsStrictMode": false
  },
  "models": [
    { "id": "deepseek-chat", "name": "DeepSeek Chat", ... },
    { "id": "deepseek-reasoner", "name": "DeepSeek Reasoner", "reasoning": true, ... }
  ]
}
```

The Aeson types in the generator mirror these shapes. The schema is
expanded in `gen/GenModels.hs` as a top-level `CatalogFile` record with
nested `ModelEntry` and `CompatOverride` records.

**Acceptance.** The four JSON files exist and are valid JSON. `jq . <
baikai/data/models/anthropic.json` exits cleanly.

### Milestone 2: implement the generator

**New file:** `baikai/gen/GenModels.hs`. The entry point:

```haskell
module Main (main) where

import Baikai.Api
import Baikai.Compat
import Baikai.Model
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BS.L
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import System.Directory (listDirectory)
import System.FilePath (takeBaseName, takeExtension, (</>))
import System.IO (IOMode (..), withFile, hPutStrLn)

main :: IO ()
main = do
  let modelsDir = "data/models"
      outputPath = "src/Baikai/Models/Generated.hs"
  files <- listDirectory modelsDir
  catalogs <- forM (filter ((== ".json") . takeExtension) files) $ \f -> do
    bytes <- BS.L.readFile (modelsDir </> f)
    case Aeson.eitherDecode bytes of
      Right (cat :: CatalogFile) -> pure cat
      Left err -> fail $ f <> ": " <> err
  let allEntries = concatMap flattenEntries catalogs
      body = renderModule allEntries
  TIO.writeFile outputPath body
  putStrLn $ "Wrote " <> outputPath <> " (" <> show (length allEntries) <> " entries)"

flattenEntries :: CatalogFile -> [GeneratedEntry]
flattenEntries CatalogFile { provider, baseUrl, api, compat, models } =
  [ GeneratedEntry
      { genIdentifier = sanitize (provider <> "_" <> id_)
      , genModel = ... build a Model record from the entry ...
      }
  | ModelEntry { id_, name, reasoning, input, cost, contextWindow, maxOutputTokens, enabled, compatOverride } <- models
  , enabled
  ]

sanitize :: Text -> Text
sanitize = Text.map (\c -> if isAsciiAlphaNum c then c else '_')

renderModule :: [GeneratedEntry] -> Text
renderModule entries = Text.intercalate "\n" $
  [ "-- AUTO-GENERATED by baikai-gen-models. Do not edit by hand."
  , "{-# LANGUAGE OverloadedStrings #-}"
  , "module Baikai.Models.Generated where"
  , ""
  , "import Baikai.Api"
  , "import Baikai.Compat"
  , "import Baikai.Model"
  , "import Data.Map.Strict qualified as Map"
  , ""
  ] ++ concatMap renderEntry entries

renderEntry :: GeneratedEntry -> [Text]
renderEntry GeneratedEntry { genIdentifier, genModel } =
  [ genIdentifier <> " :: Model"
  , genIdentifier <> " = Model"
  , "  { modelId = " <> showQuoted (modelId genModel)
  , "  , name = " <> showQuoted (name genModel)
  , ...
  , "  }"
  , ""
  ]
```

**Modified file:** `baikai/baikai.cabal`. Add the executable target:

```text
executable baikai-gen-models
  import: common-options
  hs-source-dirs: gen
  main-is: GenModels.hs
  build-depends:
    base >=4.20 && <5,
    aeson,
    baikai,
    bytestring,
    directory,
    filepath,
    text ^>=2.1,
```

The executable depends on `baikai` so it can reference the `Model`,
`ModelCost`, `Compat`, `Api`, etc. types directly.

**Modified file:** `baikai/baikai.cabal`. Add the auto-generated module to
`library`'s `exposed-modules`:

```text
library
  ...
  exposed-modules:
    ...
    Baikai.Models.Generated
```

**Acceptance.** `cabal run baikai-gen-models -- --help` is unnecessary; the
generator runs with no args. `cabal run baikai-gen-models` writes
`src/Baikai/Models/Generated.hs` containing one stanza per enabled model.
`cabal build baikai` is green after the file is generated for the first
time. The generated file's structure is reviewable by hand.

### Milestone 3: CI check

**New file:** `baikai/test/CatalogSpec.hs`:

```haskell
module CatalogSpec (testCatalog) where

import System.IO.Temp (withTempDirectory)
import System.Process (callProcess, readProcess)
import System.Directory (copyFile, getCurrentDirectory, setCurrentDirectory)
import qualified Data.ByteString as BS
import Test.Tasty
import Test.Tasty.HUnit

testCatalog :: TestTree
testCatalog = testCase "catalog regeneration is idempotent" $
  withTempDirectory "." "catalog-check" $ \tmp -> do
    let outPath = "src/Baikai/Models/Generated.hs"
        tmpOutPath = tmp <> "/Generated.hs"
    callProcess "cabal" ["run", "baikai-gen-models", "--", "--out", tmpOutPath]
    committed <- BS.readFile outPath
    regenerated <- BS.readFile tmpOutPath
    assertEqual "Generated.hs differs from committed; run `cabal run baikai-gen-models`" committed regenerated
```

The generator accepts an `--out PATH` argument for this purpose:

```haskell
main = do
  outPath <- parseOutPathFromArgs <|> pure "src/Baikai/Models/Generated.hs"
  ...
```

**Modified file:** `baikai/baikai.cabal`. Add `CatalogSpec` to the test
suite's `other-modules` and add `process`, `temporary` to the test-suite's
`build-depends`.

**Acceptance.** `cabal test baikai --test-options='-p /catalog/'` passes
when the committed `Generated.hs` matches what the generator would
produce.

If a contributor edits `data/models/anthropic.json` without re-running the
generator, the test fails with a diff hint. They run `cabal run
baikai-gen-models`, commit the updated `Generated.hs`, and the test
passes.

### Milestone 4: migrate smoke tests

**Modified file:** `baikai-smoke/test/Smoke.hs`. The hand-rolled `Model`
records (added in EP-2 / EP-3 / EP-4) are replaced with
`Models.anthropic_claude_sonnet_4_6`, `Models.openai_gpt_4o_mini`, etc.
Where the smoke test wants to demonstrate a compat override (EP-5's
multi-host case), keep one hand-rolled entry — but reference the generated
model for the base shape:

```haskell
let deepseekModel = Models.deepseek_deepseek_chat
        { Model.baseUrl = "https://api.deepseek.com" }
  -- compat already set by the generator
```

**Modified file:** `baikai-smoke/baikai-smoke.cabal`. The package already
depends on `baikai` and `baikai-claude` / `baikai-openai`; the generated
`Baikai.Models.Generated` is re-exported through `Baikai`, so no new dep.

**Acceptance.** `cabal test all` is green. Live smoke tests pass using
generated model identifiers.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/baikai` in the Nix devshell:

```bash
nix develop

# Milestone 1: catalog files
ls baikai/data/models   # should show anthropic.json openai.json deepseek.json openrouter.json
jq . baikai/data/models/anthropic.json   # exits 0

# Milestone 2: generator
cabal run baikai-gen-models
git diff baikai/src/Baikai/Models/Generated.hs   # initial generation; subsequent runs produce zero diff

# Milestone 3: CI check
cabal test baikai --test-options='-p /catalog/'

# Milestone 4: migrate smoke tests
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... cabal test baikai-smoke
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green (with the generated module committed).
- `cabal run baikai-gen-models` produces no diff on a clean working tree.
- `cabal test all` is green, including the new `CatalogSpec` test.
- `cabal repl baikai` can import and inspect generated models:

  ```haskell
  ghci> import Baikai.Models.Generated qualified as Models
  ghci> :t Models.anthropic_claude_sonnet_4_6
  Models.anthropic_claude_sonnet_4_6 :: Model
  ghci> modelId Models.anthropic_claude_sonnet_4_6
  "claude-sonnet-4-6"
  ```

- With API keys present, the live smoke tests pass using generated model
  identifiers in place of hand-rolled `_Model` records.
- Adding a new model is a documented one-step process: edit the JSON
  catalog file, run `cabal run baikai-gen-models`, commit both the JSON
  change and the regenerated module.


## Idempotence and Recovery

The generator is idempotent: running it twice without editing any catalog
JSON produces no diff. The CI check (`CatalogSpec`) enforces this.

If a catalog entry has invalid JSON or violates the schema (e.g. a
negative cost), the generator fails with a clear error message identifying
the file and entry. The fallback is to fix the JSON and re-run; no partial
state is written (the generator writes to a temp file and atomically
renames, or writes the whole file in one go).

Rollback is by reverting commits. The generator's output is plain Haskell
source — reviewable, diffable, easy to revert.

If a contributor accidentally edits the generated file by hand, the CI
check fails on the next build. The remediation is "make your change in
the JSON and re-run the generator."


## Interfaces and Dependencies

**External dependencies (executable only).** `aeson`, `bytestring`,
`directory`, `filepath`, `text`. No new vendor packages.

**External dependencies (test).** `process`, `temporary`. Both already
exist in the Hackage / Nix-shipped set under GHC 9.12.2.

**Module surface at end of plan.**

From `Baikai.Models.Generated` (re-exported via `Baikai`):

```haskell
anthropic_claude_sonnet_4_6 :: Model
anthropic_claude_opus_4_7   :: Model
anthropic_claude_haiku_4_5  :: Model

openai_gpt_5                :: Model
openai_gpt_4o_mini          :: Model
openai_o4_mini              :: Model

deepseek_deepseek_chat      :: Model
deepseek_deepseek_reasoner  :: Model

openrouter_anthropic_claude_sonnet :: Model
... (one identifier per enabled entry across all catalog files)
```

The exact model set is what the JSON catalog files contain at the time
the plan is implemented; the list above is illustrative.

No further child plans depend on EP-6 — this is the closing plan of the
masterplan.
