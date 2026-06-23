---
id: 26
slug: build-the-baikai-kit-package
title: "Build the baikai-kit package"
kind: exec-plan
created_at: 2026-06-23T22:59:48Z
intention: "intention_01kvvb9hgbed48wzdkamgedm24"
master_plan: "docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md"
---

# Build the baikai-kit package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

The author maintains several command-line tools (`mori`, `rei`, `seihou`) that each ship a
"kit" feature: a way to install **skills** and **subagents** from a remote git repository
into local directories that an interactive AI coding session (Claude Code or Codex)
auto-discovers. A **skill** is a directory containing a `SKILL.md` (and optionally helper
files) that the agent loads as a reusable capability. A **subagent** (called "agent" in the
manifests) is a single Markdown file describing a specialized agent persona. All three tools
implement this feature by copying near-identical Haskell code — roughly 2,000 lines in total
— so every bug fix and feature must be made three times, and the implementations have already
drifted (`mori` supports version-aware status but lacks Codex output; `seihou`/`rei` support
Codex but lack version-aware status).

This plan creates one library package, **`baikai-kit`**, that owns the whole kit mechanism
behind a small `KitConfig` record. After this plan, a developer can write a few lines —
construct a `KitConfig` naming the tool, its kit repo URL, and its target provider layouts,
then call `runKit config command` — and get the complete `kit list/install/update/uninstall/
status` behavior plus the `--add-dir` discovery helper that interactive sessions need. You can
see it working by building the package and running its test suite, which exercises manifest
parsing against captured copies of all three tools' real `kit.json` files, the deterministic
content hash, the status `classify` logic, and a full install/uninstall round-trip against a
temporary on-disk kit repository.

This package is the foundation of MasterPlan
`docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md`. The three sibling
plans (`docs/plans/27-migrate-mori-onto-baikai-kit.md`,
`docs/plans/28-migrate-rei-onto-baikai-kit.md`,
`docs/plans/29-migrate-seihou-onto-baikai-kit.md`) replace each tool's hand-written kit code
with calls into this package; none of them can compile until this package exists and exports
the API specified below. Treat the API in "Interfaces and Dependencies" as a contract those
plans depend on verbatim.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here.

- [x] M1: Scaffold the package — `baikai-kit/baikai-kit.cabal`, empty module set, add to
  `cabal.project`, `cabal build baikai-kit` succeeds with stub modules.
  Completed: 2026-06-23T23:40:04Z.
- [x] M2: Implement `Baikai.Kit.Manifest` (types + `FromJSON`) and `Baikai.Kit.Config`
  (`KitConfig` + derived path helpers).
  Completed: 2026-06-23T23:40:04Z.
- [x] M3: Implement `Baikai.Kit.Repo` (git clone/pull + offline fallback) and
  `Baikai.Kit.Sidecar` (metadata type, hashing, read/write/path).
  Completed: 2026-06-23T23:40:04Z.
- [x] M4: Implement `Baikai.Kit.Install` (load/lookup/install/uninstall/update) routed through
  `Baikai.AgentAssets`, including Codex agent TOML conversion.
  Completed: 2026-06-23T23:40:04Z.
- [x] M5: Implement `Baikai.Kit.Status` (state model, classify, collect, render) and
  `Baikai.Kit.Session` (`agentDirsForSession`).
  Completed: 2026-06-23T23:40:04Z.
- [x] M6: Implement `Baikai.Kit.Command` (optparse parser + `runKit`) and the umbrella
  `Baikai.Kit` re-export.
  Completed: 2026-06-23T23:40:04Z.
- [x] M7: Port and extend the test suite; all tests green via `cabal test baikai-kit`.
  Completed: 2026-06-23T23:40:04Z.
- [x] M8: Record the published `baikai-kit` version in this plan and the MasterPlan for the
  migration plans to pin.
  Completed: 2026-06-23T23:40:04Z.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-23T23:40:04Z): `cabal test baikai-kit` runs the test executable from the
  package directory, so manifest fixture paths are relative to `baikai-kit/` (`test/fixtures/...`)
  rather than the repository root. The final test suite uses that layout and passed all 13 tests.


## Decision Log

Record every decision made while working on the plan.

- Decision: Unify the three tools' `AgentEntry` shapes by giving the package's `AgentEntry`
  both `path :: Text` and `files :: Maybe [Text]`.
  Rationale: `mori`/`seihou` agents are a single file named by `path`; `rei` agents use
  `path` as a directory plus a `files` list. With `files :: Maybe [Text]`, `Nothing` means
  "`path` is the file" and `Just fs` means "sources are `path </> f` for each `f`". This is a
  superset that parses all three existing manifests.
  Date: 2026-06-23

- Decision: Publish the initial shared package as `baikai-kit-0.1.0.0`.
  Rationale: The package is a new sibling package with no previous public releases. The
  `0.1.0.0` version is now recorded in `baikai-kit/baikai-kit.cabal` and is the version the
  migration plans should pin with `baikai-kit ^>=0.1.0`.
  Date: 2026-06-23

- Decision: For Codex custom agents, strip a leading YAML frontmatter block before writing
  `developer_instructions` to the Codex TOML file.
  Rationale: Existing seihou/rei code fed the whole Markdown file through the Codex renderer,
  but the shared package API explicitly calls for recovering the instruction body. The manifest
  still supplies the authoritative agent `name` and `description`, so the frontmatter metadata is
  not needed in the instruction body.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.

Completed EP-1 on 2026-06-23. The repository now contains a new `baikai-kit` package at
version `0.1.0.0`, added to `cabal.project`, with public modules for manifest parsing,
configuration, git cache management, installation, sidecars and hashing, status rendering,
session discovery, command parsing, and an umbrella `Baikai.Kit` re-export. The test suite
captures the real `mori-kit`, `rei-kit`, and `seihou-kit` manifests, verifies deterministic
SHA-256 hashing, covers all four `classify` states, and performs a skill/agent install and
uninstall round-trip through both Claude and Codex provider layouts.

Validation evidence: `cabal test baikai-kit` passed all 13 tests at 2026-06-23T23:40:04Z, and
`cabal build all` completed successfully before the final test rerun. The only remaining work
for the larger initiative is in the migration plans EP-2, EP-3, and EP-4, which now have their
hard dependency satisfied.


## Context and Orientation

This work happens in the `baikai` repository, whose root is the current working directory
(`/Users/shinzui/Keikaku/bokuno/baikai`). It is a Cabal multi-package project. The
`cabal.project` file lists the packages:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-smoke
  baikai-trace-otel
  baikai-effectful
```

GHC is provided by a Nix devShell (GHC 9.12); all dependencies resolve from Hackage. Build
and test commands are plain `cabal` invocations run from the repository root.

The existing package **`baikai-effectful`** is the best structural template for a new sibling
package. Its layout is `baikai-effectful/baikai-effectful.cabal`, `baikai-effectful/src/...`,
`baikai-effectful/test/...`. Its cabal file uses `cabal-version: 3.4`, a `common
common-options` stanza with the project's warning flags and `default-language: GHC2024`, and
`default-extensions: DeriveAnyClass DuplicateRecordFields OverloadedLabels OverloadedStrings`.
Read it before scaffolding.

This package builds on the existing **`baikai`** library package (`baikai/baikai.cabal`,
modules under `baikai/src/Baikai/`). Two existing modules matter:

`Baikai.AgentAssets` (`baikai/src/Baikai/AgentAssets.hs`, ~145 lines) already computes
provider-native install paths and renders Codex agent TOML. Its relevant exports:

```haskell
type AgentAssetProvider = InteractiveProvider          -- InteractiveClaude | InteractiveCodex
type AgentAssetScope    = InteractiveScope             -- InteractiveUserScope | InteractiveProjectScope

skillTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
-- Claude/project:  ".claude/skills/<name>"      Claude/user: "$HOME/.claude/skills/<name>"
-- Codex/project:   ".agents/skills/<name>"      Codex/user:  "$HOME/.agents/skills/<name>"

agentTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
-- Claude/project:  ".claude/agents/<name>.md"   Codex/project: ".codex/agents/<name>.toml"

agentAssetFormat :: AgentAssetProvider -> AgentAssetKind -> AgentAssetFormat
-- SkillAsset -> DirectoryAsset ; Claude CustomAgentAsset -> MarkdownFile ;
-- Codex CustomAgentAsset -> TomlFile

data CodexCustomAgent = CodexCustomAgent { name :: !Text, description :: !Text, developerInstructions :: !Text }
codexCustomAgentToml :: CodexCustomAgent -> Text     -- renders the minimal Codex TOML
```

The package must call `skillTargetPath provider InteractiveProjectScope name` and
`agentTargetPath provider InteractiveProjectScope name` to get the **relative** subpath (for
example `.claude/skills/foo`), then join it under the resolved agents base directory. Do not
use the `$HOME`/user-scope form from `AgentAssets`; the package resolves the base directory
itself (see `Baikai.Kit.Config`).

`Baikai.Interactive` (`baikai/src/Baikai/Interactive.hs`) exports the
`InteractiveProvider (..)` (`InteractiveClaude`, `InteractiveCodex`) and `InteractiveScope (..)`
(`InteractiveUserScope`, `InteractiveProjectScope`) constructors that `AgentAssetProvider`/
`AgentAssetScope` are aliases for.

`Baikai.Prelude` (`baikai/src/Baikai/Prelude.hs`) is the project prelude: it re-exports the
`lens`/`generic-lens` vocabulary (so `record ^. #fieldName` works), `MonadIO`, the scalar
types (`Text`, `Vector`, `Natural`), `Generic`, and the aeson `FromJSON`/`ToJSON` surface.
New modules in `baikai-kit` should `import Baikai.Prelude` and use overloaded labels for field
access instead of writing hand-rolled accessor functions.

**House rule (important):** record fields in this codebase carry **no Hungarian-style
prefixes**. Do not name fields `kitVersion`, `skillName`, `agentPath`, etc. Name them
`version`, `name`, `path`, and disambiguate at use sites with `OverloadedLabels`
(`entry ^. #name`) — `DuplicateRecordFields` is on. This differs from `mori`'s current code,
which uses hand-written accessor functions like `skillName`/`agentNameOf` to dodge
`DuplicateRecordFields`; do **not** copy those accessors. Use labels.

The reference implementation to port from is `mori`'s
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/src/Mori/Command/Kit.hs` (~806
lines) and its test suite
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/test/Mori/Command/KitSpec.hs`
(~380 lines). Read both in full before implementing. The logic to port is described
concretely below so this plan stands alone, but the `mori` source is the ground truth for
edge cases (offline fallback messages, hash framing bytes, status precedence).

Terms used in this plan: a **manifest** is the `kit.json` file at the root of a kit git
repository, listing the available skills and agents. A **sidecar** is a small JSON file the
installer writes next to each installed asset recording its name, kind, declared version, a
content hash, and an install timestamp; it lets `kit status` detect when an installed asset
is outdated or locally modified. The **agents base directory** is the per-scope root under
which provider layouts live: `~/.config/<tool>/agents` for user scope, `<cwd>/.<tool>/agents`
for project scope; the actual assets sit under `<base>/.claude/...` or the Codex equivalents.


## Plan of Work

The work is one new package with seven library modules plus a test suite, built in eight
milestones. Each milestone is independently verifiable with `cabal build`/`cabal test`.

### M1 — Scaffold the package

Create the directory `baikai-kit/` with `baikai-kit/src/` and `baikai-kit/test/`. Write
`baikai-kit/baikai-kit.cabal` modeled on `baikai-effectful/baikai-effectful.cabal`: same
`cabal-version: 3.4`, same `common common-options` stanza (copy the `ghc-options` and
`default-language: GHC2024` and the four `default-extensions` verbatim), `name:
baikai-kit`, `version: 0.1.0.0`, a `library` stanza listing the seven exposed modules
(below) with `build-depends` on `baikai ^>=0.2.0`, `base >=4.20 && <5`, `aeson`,
`bytestring`, `text ^>=2.1`, `time`, `directory`, `filepath`, `process`, `binary`,
`optparse-applicative`, and a SHA-256 provider. For hashing, mirror `mori`'s dependencies:
`crypton` (module `Crypto.Hash`) and `memory` (module `Data.ByteArray.Encoding`); confirm
the exact package names `mori`'s cabal uses by reading
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/*.cabal` and matching them.

Add a `test-suite baikai-kit-test` stanza (type `exitcode-stdio-1.0`, `main-is: Main.hs`,
`hs-source-dirs: test`, depends on `baikai-kit`, `baikai`, `tasty`, `tasty-hunit`,
`temporary`, plus whatever the tests use). Use `tasty`/`tasty-hunit` to match the rest of
the repo (see `baikai/baikai.cabal`'s test suite).

Create the seven modules as compiling stubs (module header + `Baikai.Prelude` import +
the type declarations only, no logic yet) so the package builds:

- `Baikai.Kit` (umbrella re-export)
- `Baikai.Kit.Manifest`
- `Baikai.Kit.Config`
- `Baikai.Kit.Repo`
- `Baikai.Kit.Install`
- `Baikai.Kit.Sidecar`
- `Baikai.Kit.Status`
- `Baikai.Kit.Session`
- `Baikai.Kit.Command`

Add `baikai-kit` to `cabal.project`'s `packages:` list.

Acceptance: from the repo root, `cabal build baikai-kit` succeeds.

### M2 — Manifest and Config

In `Baikai.Kit.Manifest` define `KitManifest`, `SkillEntry`, `AgentEntry`, `KitItem` exactly
as in "Interfaces and Dependencies". Derive `FromJSON` via `Generic`. The crucial parsing
choices for backward compatibility: `version :: Maybe Text` on both entry records, and
`files :: Maybe [Text]` on `AgentEntry`. Aeson's generic instance treats `Maybe` fields as
optional automatically, so a manifest entry omitting `version` or an agent omitting `files`
will parse. Add a helper `agentSources :: AgentEntry -> [(FilePath, FilePath)]` returning a
list of `(sourceRelativeToRepoOfPath, destinationFileName)` pairs: when `files` is `Just fs`,
each `f` gives `(path </> f, f)`; when `files` is `Nothing`, the single pair is
`(path, takeFileName path)`. Add `itemName :: KitItem -> Text`, `itemVersion :: KitItem ->
Maybe Text`, and `itemKind :: KitItem -> Text` (`"skill"`/`"agent"`).

In `Baikai.Kit.Config` define `KitConfig` (fields `toolName`, `repoUrl`, `providers`) and the
derived path helpers `kitCacheDir`, `userAgentsDir`, `projectAgentsDir`, `sidecarFileName`,
plus `resolveAgentsBase :: KitConfig -> KitScope -> IO FilePath` (dispatches user/project).
`KitScope` is defined here (or in `Baikai.Kit.Install` and imported — pick one home and keep
it consistent; this plan puts `KitScope` in `Baikai.Kit.Config`). `kitCacheDir` returns
`getHomeDirectory >>= \h -> pure (h </> ".cache" </> toolName' </> "kit")` where `toolName'`
is `Text.unpack (config ^. #toolName)`. `sidecarFileName config = "." <> (config ^. #toolName)
<> "-kit.json"`.

Acceptance: `cabal build baikai-kit` succeeds; a GHCi or test snippet can decode a small
`kit.json` string into a `KitManifest`.

### M3 — Repo and Sidecar

In `Baikai.Kit.Repo` port `ensureKitRepo` and `pullKitRepo` from `mori`'s `Kit.hs` lines
~581–620, parameterized by `KitConfig`: clone with `git clone --depth 1 <repoUrl> <cacheDir>`
when `<cacheDir>/.git` is absent, otherwise `git pull --ff-only --quiet` in `<cacheDir>`.
Preserve the offline-resilience behavior: if a clone or pull fails but `<cacheDir>/kit.json`
exists, emit a warning to stderr and return the cache dir anyway; only `exitFailure` if no
cached manifest exists. Use `System.Process.readProcessWithExitCode` and guard pulls with
`Control.Exception.try @IOException`.

In `Baikai.Kit.Sidecar` port `SidecarMeta` (fields `name`, `kind`, `version :: Maybe Text`,
`hash`, `installedAt`), `computeKitHash`, `sidecarPath`, `readSidecar`, `writeSidecar` from
`mori`'s `Kit.hs` lines ~682–754. `computeKitHash baseDir relFiles` sorts the file list,
reads each file, and frames each as `pathBytes ++ NUL ++ word64be(length) ++ content ++ NUL`,
concatenates, SHA-256s, and returns `"sha256:" <> hex`. Keep this framing byte-for-byte
identical to `mori` so hashes computed by the package match hashes `mori` wrote previously.
`sidecarPath` takes the `KitItem`, the resolved agents base, and the sidecar filename (from
`Baikai.Kit.Config.sidecarFileName`), and returns the path next to the installed asset: for a
skill, `<base>/.claude/skills/<name>/<sidecarFileName>`; for an agent,
`<base>/.claude/agents/<name><sidecarFileName>` (note `mori` concatenates without a path
separator for agents, e.g. `foo.mori-kit.json`). Since the package now also supports Codex,
generalize: write one sidecar per installed provider layout, next to that layout's asset. Keep
the Claude path identical to `mori`'s. `readSidecar` returns `Nothing` for a missing file and
`Nothing` + stderr warning for a parse error. `writeSidecar` stamps `getCurrentTime` formatted
as `%Y-%m-%dT%H:%M:%SZ`.

Acceptance: `cabal build baikai-kit` succeeds; a test computes a known hash over a fixed set of
temp files and asserts the `sha256:` prefix and stability across runs.

### M4 — Install (the core)

In `Baikai.Kit.Install` define `KitScope` re-export (from Config), and port `loadManifest`,
`loadManifestMaybe`, `lookupItem`, `installItem`, `uninstallItem`, `updateKit`,
`listAvailable`, and the internal `doInstall`/`copySkillFile` from `mori`'s `Kit.hs`
(lines ~214–362, 626–646), with two changes from `mori`:

1. **Route every path through `Baikai.AgentAssets` and over `config ^. #providers`.** For each
   provider in `config ^. #providers`, compute the skill target as `base </> skillTargetPath
   provider InteractiveProjectScope name` and the agent target as `base </> agentTargetPath
   provider InteractiveProjectScope name`. Install the asset into each provider's layout.

2. **Convert agents to Codex TOML when the provider is `InteractiveCodex`.** For
   `InteractiveClaude`, copy the source `.md` verbatim (as `mori`/`seihou`/`rei` do for
   Claude). For `InteractiveCodex`, read the source `.md`, split YAML frontmatter from the
   body to recover `name`, `description`, and the instruction body, build a `CodexCustomAgent`,
   and write `codexCustomAgentToml` to the `.toml` target. Reuse `seihou`/`rei`'s existing
   frontmatter-splitting helper as a model — read
   `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou/seihou-cli/src/Seihou/CLI/KitPaths.hs`
   and port its `codexAgentToml`-feeding logic. Skills install identically across providers (a
   directory copy); only their base subpath differs.

After copying an asset for a provider layout, compute its content hash with `computeKitHash`
over the source files and write the sidecar next to the installed asset
(`Baikai.Kit.Sidecar.writeSidecar`). `uninstallItem` removes the asset (and its sidecar) from
every provider layout under the scope. `updateKit` pulls the repo then reinstalls every item
currently installed in either scope (port `reinstallIfPresent`/`reinstallAllPresent`).
`listAvailable` prints the manifest's skills and agents in aligned columns (port the existing
renderer; it is pure formatting).

Acceptance: `cabal build baikai-kit` succeeds; the install round-trip test (M7) passes.

### M5 — Status and Session

In `Baikai.Kit.Status` port `KitState`, `renderState`, `StatusRow`, `classify`,
`collectStatus`, `kitStatus`, `scanInstalled`/`scanSkills`/`scanAgents`, and
`renderStatusTable` from `mori`'s `Kit.hs` lines ~368–575, parameterized by `KitConfig`.
`classify` keeps `mori`'s precedence exactly: no sidecar or no upstream entry → `KitUnknown`;
upstream version present and differs from sidecar version → `KitOutdated`; upstream content
hash differs from sidecar hash → `KitDirty`; otherwise `KitUpToDate`. `collectStatus` scans
each scope's installed assets, reads sidecars, recomputes the upstream hash from the cache
(tolerating IO errors by yielding `Nothing`), and builds rows. `kitStatus` resolves the cache
(tolerating an offline cache via the empty-string convention `mori` uses), the user base, and
the project base, then renders the table.

In `Baikai.Kit.Session` implement `agentDirsForSession :: KitConfig -> IO [FilePath]` returning
the subset of `[userAgentsDir config, projectAgentsDir config]` that exist on disk (port the
`agentDirsForSession` / `agentDirsForRoot` helper each tool currently defines in its
interactive-session module). This is the helper the tools pass to `claude --add-dir`.

Acceptance: `cabal build baikai-kit` succeeds; `classify` unit tests cover all four states.

### M6 — Command glue and umbrella

In `Baikai.Kit.Command` define `KitCommand` (`KitList`, `KitInstall Text KitScope`,
`KitUpdate (Maybe Text)`, `KitUninstall Text KitScope`, `KitStatus`), a `kitCommandParser ::
Parser KitCommand` built with `optparse-applicative`'s `hsubparser` (port `mori`'s
`kitCommandParser`, generalizing the `--project` help text to not name a specific tool), and
`runKit :: KitConfig -> KitCommand -> IO ()` dispatching to the `Baikai.Kit.Install`/`Status`
functions. In `Baikai.Kit` re-export the public surface from all sibling modules so a consumer
can `import Baikai.Kit` and get everything.

Note the deliberate seam for tool-specific UI: `runKit` is the batteries-included path, but the
engine functions (`installItem`, `loadManifest`, `lookupItem`, `listAvailable`) are also
exported so a tool like `rei` can intercept the no-argument `install` (to run its FZF picker)
and call `installItem config chosenName scope` directly while delegating every other subcommand
to `runKit`.

Acceptance: `cabal build baikai-kit` succeeds; `cabal build all` in the repo still succeeds.

### M7 — Tests

Port `mori`'s `KitSpec.hs` into `baikai-kit/test/` and extend it. Required test groups:

1. **Manifest backward compatibility.** Capture the three tools' real manifests as fixtures:
   copy `/Users/shinzui/Keikaku/bokuno/mori-project/mori-kit/kit.json`,
   `/Users/shinzui/Keikaku/bokuno/rei-project/rei-kit/kit.json`, and
   `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou-kit/kit.json` into
   `baikai-kit/test/fixtures/` and assert each decodes into a `KitManifest` without error,
   with the expected skill/agent counts. This is the guard that the migrations will not break
   existing manifests.
2. **Hash determinism.** `computeKitHash` over a fixed temp directory is stable across calls
   and changes when file content changes.
3. **`classify`.** All four `KitState` outcomes, matching `mori`'s `KitSpec` cases.
4. **Install round-trip.** Build a temporary on-disk "kit repo" directory (a `kit.json` plus a
   skill directory and an agent `.md`), point a `KitConfig` at a temp `HOME`/cache via the
   `temporary` package and environment overrides, run `installItem`/`uninstallItem` for the
   Claude provider, and assert the files land at and leave the expected paths with a valid
   sidecar. If feasible, add a Codex-provider case asserting a `.toml` is produced.

Acceptance: `cabal test baikai-kit` is green.

### M8 — Record the version

Set the package `version` in `baikai-kit/baikai-kit.cabal` (start at `0.1.0.0`). Record that
exact version string in this plan's Decision Log and in the MasterPlan's Surprises &
Discoveries so the migration plans (EP-2/3/4) pin the same version. Commit.


## Concrete Steps

Run everything from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`.

```bash
# M1: scaffold
mkdir -p baikai-kit/src/Baikai/Kit baikai-kit/test/fixtures
# (author baikai-kit/baikai-kit.cabal, stub modules, edit cabal.project)
cabal build baikai-kit

# M2-M6: implement modules incrementally, rebuilding after each
cabal build baikai-kit

# M7: tests
cp /Users/shinzui/Keikaku/bokuno/mori-project/mori-kit/kit.json     baikai-kit/test/fixtures/mori-kit.json
cp /Users/shinzui/Keikaku/bokuno/rei-project/rei-kit/kit.json       baikai-kit/test/fixtures/rei-kit.json
cp /Users/shinzui/Keikaku/bokuno/seihou-project/seihou-kit/kit.json baikai-kit/test/fixtures/seihou-kit.json
cabal test baikai-kit

# whole-repo sanity
cabal build all
```

Expected test transcript shape (exact names will vary):

```text
baikai-kit-test
  Manifest
    mori-kit.json decodes:    OK
    rei-kit.json decodes:     OK
    seihou-kit.json decodes:  OK
  Hash
    deterministic:            OK
  Status.classify
    up-to-date/outdated/dirty/unknown: OK
  Install
    skill round-trip:         OK
    agent round-trip:         OK

All N tests passed
```


## Validation and Acceptance

The package is accepted when, from the repo root: `cabal build baikai-kit` succeeds,
`cabal test baikai-kit` is green with all of the M7 test groups present and passing, and
`cabal build all` still succeeds (no regression to the other packages). The decisive behavioral
proof is the M7 install round-trip (assets appear at the exact expected paths and are removed
cleanly, with a valid sidecar) and the manifest fixtures (all three real `kit.json` files parse)
— together these demonstrate the package reproduces the tools' behavior and will not break their
existing kit repositories. The published version string is recorded for the migration plans.


## Idempotence and Recovery

All steps are repeatable. Re-running `cabal build`/`cabal test` is always safe. The scaffold
step uses `mkdir -p` and additive file writes; re-running it does not clobber working code once
modules are fleshed out (write real content with the editor, not the scaffold step). The git
clone/pull logic in `Baikai.Kit.Repo` is itself idempotent by design (clone-if-absent,
pull-otherwise, fall back to cache offline). If a milestone leaves the package not building,
revert the offending module to its previous stub and rebuild; no external state is mutated by
building or testing the package (the tests use temporary directories, never the developer's real
`~/.config` or `~/.cache`).


## Interfaces and Dependencies

New package `baikai-kit` depends on: `baikai ^>=0.2.0` (for `Baikai.AgentAssets`,
`Baikai.Interactive`, `Baikai.Prelude`), `base`, `aeson`, `bytestring`, `text ^>=2.1`, `time`,
`directory`, `filepath`, `process`, `binary`, `optparse-applicative`, and a SHA-256 stack
(`crypton` + `memory`, matching `mori`'s cabal — verify exact names in
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/*.cabal`). Test suite additionally
depends on `tasty`, `tasty-hunit`, `temporary`.

The public API that the migration plans (`docs/plans/27`, `28`, `29`) depend on — this is a
contract; keep these names and shapes:

```haskell
-- Baikai.Kit.Manifest
data KitManifest = KitManifest { version :: !Int, skills :: ![SkillEntry], agents :: ![AgentEntry] }
data SkillEntry  = SkillEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text)
                               , path :: !Text, files :: ![Text] }
data AgentEntry  = AgentEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text)
                               , path :: !Text, files :: !(Maybe [Text]) }
data KitItem     = KitSkillItem !SkillEntry | KitAgentItem !AgentEntry
itemName  :: KitItem -> Text
itemKind  :: KitItem -> Text
itemVersion :: KitItem -> Maybe Text
-- all records: deriving stock (Generic, Show); deriving anyclass (FromJSON); no field prefixes

-- Baikai.Kit.Config
data KitConfig = KitConfig { toolName :: !Text, repoUrl :: !Text, providers :: ![AgentAssetProvider] }
data KitScope  = UserScope | ProjectScope
kitCacheDir      :: KitConfig -> IO FilePath
userAgentsDir    :: KitConfig -> IO FilePath
projectAgentsDir :: KitConfig -> IO FilePath
resolveAgentsBase:: KitConfig -> KitScope -> IO FilePath
sidecarFileName  :: KitConfig -> Text

-- Baikai.Kit.Repo
ensureKitRepo :: KitConfig -> IO FilePath
pullKitRepo   :: KitConfig -> FilePath -> IO ()

-- Baikai.Kit.Install
loadManifest      :: FilePath -> IO KitManifest
loadManifestMaybe :: FilePath -> IO (Maybe KitManifest)
lookupItem        :: Text -> KitManifest -> Maybe KitItem
installItem       :: KitConfig -> Text -> KitScope -> IO ()
uninstallItem     :: KitConfig -> Text -> KitScope -> IO ()
updateKit         :: KitConfig -> Maybe Text -> IO ()
listAvailable     :: KitConfig -> IO ()

-- Baikai.Kit.Sidecar
data SidecarMeta = SidecarMeta { name :: !Text, kind :: !Text, version :: !(Maybe Text)
                               , hash :: !Text, installedAt :: !Text }   -- FromJSON, ToJSON
computeKitHash :: FilePath -> [Text] -> IO Text

-- Baikai.Kit.Status
data KitState  = KitUpToDate | KitOutdated | KitDirty | KitUnknown
data StatusRow = StatusRow { name :: !Text, kind :: !Text, scope :: !Text
                           , installedVersion :: !(Maybe Text), latestVersion :: !(Maybe Text)
                           , state :: !KitState }
classify      :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
collectStatus :: KitConfig -> FilePath -> [(FilePath, Text)] -> IO [StatusRow]
kitStatus     :: KitConfig -> IO ()
renderState   :: KitState -> Text

-- Baikai.Kit.Session
agentDirsForSession :: KitConfig -> IO [FilePath]

-- Baikai.Kit.Command
data KitCommand  = KitList | KitInstall !Text !KitScope | KitUpdate !(Maybe Text)
                 | KitUninstall !Text !KitScope | KitStatus
kitCommandParser :: Parser KitCommand
runKit           :: KitConfig -> KitCommand -> IO ()

-- Baikai.Kit  (umbrella) re-exports all of the above.
```

`AgentAssetProvider` in `KitConfig` is `Baikai.AgentAssets.AgentAssetProvider`
(= `Baikai.Interactive.InteractiveProvider`), so a consumer constructs a config like
`KitConfig { toolName = "mori", repoUrl = "https://github.com/shinzui/mori-kit.git",
providers = [InteractiveClaude] }`.

Revision note (2026-06-23): Implemented EP-1 completely, updated progress, decisions,
discoveries, outcomes, and recorded `baikai-kit-0.1.0.0` for the dependent migration plans.
