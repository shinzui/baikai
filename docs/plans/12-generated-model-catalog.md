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

- [ ] Milestone 1: define the catalog file schema. Add JSON files under
      `baikai/data/models/` for `anthropic.json`, `openai.json`, `deepseek.json`,
      `openrouter.json` (the four hosts the smoke tests reference). Each file
      lists model entries with the same fields as `Model` plus an `enabled :: Bool`
      flag.
- [ ] Milestone 2: implement the generator. A new executable
      `baikai-gen-models` under `baikai.cabal` reads the JSON catalog, validates
      each entry, sorts deterministically, and writes
      `baikai/src/Baikai/Models/Generated.hs`. The output has stable formatting so
      `cabal run baikai-gen-models` is idempotent.
- [ ] Milestone 3: add the generator as a step documented in the README and add
      a tasty test in `baikai/test/CatalogSpec.hs` that re-runs the generator
      (via `System.Process`) into a temp file and asserts the temp output
      matches the committed module byte-for-byte.
- [ ] Milestone 4: migrate the smoke tests to use generated model names where
      applicable. Hand-rolled `Model` records in the smoke tests are replaced by
      `Models.anthropic_claude_sonnet_4_6` etc. The multi-host smoke test
      (EP-5) keeps one hand-rolled entry to demonstrate that overriding compat
      manually is still supported.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The catalog generator is a Haskell executable target inside
  `baikai.cabal`, not a sibling cabal package.
  Rationale: The generator's dependencies are limited to `aeson`, `bytestring`,
  `text`, `directory`, `filepath`, and `pretty-simple` (or `prettyprinter`) for
  source formatting. None pollutes consumers — library users do not build the
  exe target. Keeping the generator inside `baikai.cabal` avoids a new cabal
  package and matches the masterplan's Decision Log. If the dep closure grows,
  a follow-up plan can split.
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

(To be filled during and after implementation.)


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
