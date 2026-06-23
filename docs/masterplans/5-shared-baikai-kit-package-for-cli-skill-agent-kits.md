---
id: 5
slug: shared-baikai-kit-package-for-cli-skill-agent-kits
title: "Shared baikai-kit package for CLI skill/agent kits"
kind: master-plan
created_at: 2026-06-23T22:59:42Z
intention: "intention_01kvvb9hgbed48wzdkamgedm24"
---

# Shared baikai-kit package for CLI skill/agent kits

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Several of the author's command-line tools — `mori`, `rei`, and `seihou` — ship a feature
called a "kit". A kit is a remotely-hosted collection of **skills** (directories of
Markdown plus helper files that an interactive AI coding session, such as Claude Code or
Codex, auto-discovers) and **subagents** (single Markdown files describing a specialized
agent). Each tool lets a user run `<tool> kit list`, `<tool> kit install <name>`,
`<tool> kit update`, `<tool> kit uninstall <name>`, and `<tool> kit status`. Installation
clones the tool's kit git repository (for example `github.com/shinzui/mori-kit`) into a
local cache, reads a JSON manifest named `kit.json`, and copies the requested skill or
subagent into a provider-native directory layout (`.claude/skills/<name>/`,
`.claude/agents/<name>.md`, or the Codex equivalents) under either a user-scope directory
(`~/.config/<tool>/agents/`) or a project-scope directory (`.<tool>/agents/`). When the
tool later launches an interactive session it passes those directories to the underlying
agent with `--add-dir` flags so the freshly installed skills and subagents are available.

Today each tool re-implements this entire feature from scratch. The three implementations
are near-identical copies: `mori` has ~806 lines in one `Kit.hs` (plus a 380-line test
suite), `rei` has ~765 lines across four modules, and `seihou` has ~648 lines across two
modules. The manifest types, the git clone/pull logic, the manifest loader, the item
lookup, the install/uninstall/update flows, the status reporting, and the
`--add-dir` discovery helper are all duplicated. `rei`'s own source comments state it was
"adapted from the mori reference." A bug fixed in one tool is not fixed in the others, and
`mori` lacks the Codex provider layout that `seihou` and `rei` support.

After this initiative, there is a single Haskell library package, **`baikai-kit`**, that
owns the entire kit mechanism behind a small configuration record. Each tool depends on
`baikai-kit`, supplies a `KitConfig` value describing its name, kit repository URL, and
which provider layouts it targets, and reduces its kit code to a thin parser plus a
dispatch call. The user-visible behavior of every tool is unchanged (every existing
`kit.json` file continues to parse, every command behaves the same), with three additive
improvements: `mori` gains the Codex provider layout, and `seihou` and `rei` gain `mori`'s
version-aware status reporting (the `up-to-date` / `outdated` / `dirty` / `unknown` states
backed by a per-install sidecar metadata file and a content hash). Roughly 2,000 lines of
triplicated code collapse into one tested package plus three small adapters.

In scope: the new `baikai-kit` package and its test suite; migrating `mori`, `rei`, and
`seihou` to consume it; preserving each tool's existing CLI surface and on-disk behavior;
preserving backward compatibility with each tool's existing `kit.json`. Out of scope:
changing the kit repositories' contents or manifest format beyond what already parses;
changing the interactive-session launch code paths beyond having them call the package's
discovery helper; adding new providers beyond Claude Code and Codex; any `okf`/`handan` or
other tools not named here (they can adopt `baikai-kit` later by the same recipe).


## Decomposition Strategy

The initiative decomposes into one foundational package plan and three independent
migration plans, grouped into two phases.

The decomposition is by functional concern. The package (EP-1) is a single, cohesive
deliverable: it is the only work that designs new code, and everything else consumes it,
so it must come first and be verifiable on its own (its own test suite, ported and
extended from `mori`'s existing `KitSpec`). Each migration (EP-2 `mori`, EP-3 `rei`,
EP-4 `seihou`) is its own functional concern because each lives in a different repository,
has a different module structure to dismantle, a different `KitConfig`, and an independent
build/test/commit cycle. Each migration produces an independently verifiable behavior: the
tool builds, its `kit` commands still work against its real kit repository, and its
interactive sessions still discover installed assets.

`mori` is migrated first among the tools (EP-2) because the package is built from `mori`'s
superset implementation, so `mori`'s migration is the truest end-to-end test of the
package's API: if the package cannot reproduce `mori`'s behavior, the package design is
wrong and we want to learn that before touching the other two. `rei` (EP-3) and `seihou`
(EP-4) follow and can proceed in parallel with each other once the package exists.

Alternatives considered. A single mega-ExecPlan was rejected: it would touch four
repositories and well over ten modules, exceeding the ExecPlan size guidance, and it would
prevent the three migrations from being picked up independently or in parallel. Splitting
the package into multiple plans (types, then git, then install, then status) was rejected:
those layers are tightly coupled, share the same module set, and are most safely built and
tested as one unit; splitting them would create hard dependencies with no independent
verifiability. Putting the kit logic into the existing `baikai` core package (rather than a
new sibling package) was rejected during design because it would pull `process` (git),
`directory`, and a SHA-256 hashing dependency into `baikai`'s otherwise dependency-light,
pure abstraction core; a sibling package matches the existing layout
(`baikai`, `baikai-claude`, `baikai-openai`, `baikai-effectful`, ...).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Build the baikai-kit package | docs/plans/26-build-the-baikai-kit-package.md | None | None | Complete |
| 2 | Migrate mori onto baikai-kit | docs/plans/27-migrate-mori-onto-baikai-kit.md | EP-1 | None | Not Started |
| 3 | Migrate rei onto baikai-kit | docs/plans/28-migrate-rei-onto-baikai-kit.md | EP-1 | EP-2 | Not Started |
| 4 | Migrate seihou onto baikai-kit | docs/plans/29-migrate-seihou-onto-baikai-kit.md | EP-1 | EP-2 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 (the package) is the root. It has no dependencies and must be completed and released
before any migration can compile, because each migration replaces tool-local code with
calls into `baikai-kit`'s modules — that code will not compile until the package exists and
exposes the agreed API. This is the only hard dependency in the initiative, and every
migration has it.

EP-2 (`mori`) is the first migration and carries a soft dependency on nothing but the
package. EP-3 (`rei`) and EP-4 (`seihou`) each carry a soft dependency on EP-2: not a
compile-time requirement, but a sequencing preference. Because the package is derived from
`mori`, migrating `mori` first is the most likely place to surface a missing or awkward
piece of the package API. If EP-2 reveals that the package needs an adjustment (a new
exported function, a `KitConfig` field, a relaxed parser), that adjustment is folded back
into EP-1 before EP-3 and EP-4 begin, sparing them from discovering the same gap
independently. If a contributor is confident the package is complete, EP-3 and EP-4 may
start in parallel with EP-2; the soft dependency only means "prefer to let mori shake out
the API first."

Once EP-1 is complete and released, EP-2, EP-3, and EP-4 are mutually independent — they
touch three separate repositories and share no code beyond the package — and may be
implemented in parallel by different sessions.


## Integration Points

There is one dominant integration point, plus the cross-repository release mechanics.

**The `baikai-kit` public API.** This is the shared contract. EP-1 is responsible for
defining it; EP-2, EP-3, and EP-4 consume it. To prevent drift, the exact API surface is
specified here, and every child plan repeats it verbatim in its own text (per the
self-containment rule). The intended public surface is:

```haskell
-- Package: baikai-kit  (depends on: baikai, aeson, process, directory, filepath,
--                        bytestring, binary, crypton (SHA-256), bytestring-encoding/
--                        memory, time, text, optparse-applicative)

-- Baikai.Kit.Manifest
data KitManifest = KitManifest
  { version :: !Int
  , skills  :: ![SkillEntry]
  , agents  :: ![AgentEntry]
  }                                   -- deriving (Generic, Show); FromJSON

data SkillEntry = SkillEntry
  { name        :: !Text
  , description :: !Text
  , version     :: !(Maybe Text)      -- optional: absent in seihou/rei v1 manifests
  , path        :: !Text
  , files       :: ![Text]
  }                                   -- deriving (Generic, Show); FromJSON

data AgentEntry = AgentEntry
  { name        :: !Text
  , description :: !Text
  , version     :: !(Maybe Text)      -- optional
  , path        :: !Text
  , files       :: !(Maybe [Text])    -- optional: when present, sources are path </> each
                                      -- file; when absent, path itself is the single file
  }                                   -- deriving (Generic, Show); FromJSON

data KitItem = KitSkillItem !SkillEntry | KitAgentItem !AgentEntry

-- Baikai.Kit.Config
data KitConfig = KitConfig
  { toolName  :: !Text                     -- "mori" | "rei" | "seihou"
  , repoUrl   :: !Text                      -- git URL of the <tool>-kit repository
  , providers :: ![AgentAssetProvider]      -- from Baikai.AgentAssets; layouts to install
                                            -- into. [InteractiveClaude] for mori today;
                                            -- [InteractiveClaude, InteractiveCodex] for
                                            -- seihou/rei.
  }
-- Derived paths (pure or IO, all keyed off toolName):
kitCacheDir     :: KitConfig -> IO FilePath        -- ~/.cache/<tool>/kit
userAgentsDir   :: KitConfig -> IO FilePath        -- ~/.config/<tool>/agents
projectAgentsDir:: KitConfig -> IO FilePath        -- <cwd>/.<tool>/agents
sidecarFileName :: KitConfig -> Text               -- ".<tool>-kit.json"

-- Baikai.Kit.Repo
ensureKitRepo   :: KitConfig -> IO FilePath         -- clone --depth 1 or pull --ff-only;
                                                    -- offline fallback to cached kit.json
pullKitRepo     :: KitConfig -> FilePath -> IO ()

-- Baikai.Kit.Install   (engine + batteries-included entry points)
loadManifest    :: FilePath -> IO KitManifest        -- reads <repo>/kit.json, exits on error
loadManifestMaybe :: FilePath -> IO (Maybe KitManifest)
lookupItem      :: Text -> KitManifest -> Maybe KitItem
data KitScope = UserScope | ProjectScope
installItem     :: KitConfig -> Text -> KitScope -> IO ()
uninstallItem   :: KitConfig -> Text -> KitScope -> IO ()
updateKit       :: KitConfig -> Maybe Text -> IO ()
listAvailable   :: KitConfig -> IO ()

-- Baikai.Kit.Sidecar
data SidecarMeta = SidecarMeta
  { name :: !Text, kind :: !Text, version :: !(Maybe Text)
  , hash :: !Text, installedAt :: !Text }            -- FromJSON, ToJSON
computeKitHash  :: FilePath -> [Text] -> IO Text      -- deterministic "sha256:<hex>"

-- Baikai.Kit.Status
data KitState = KitUpToDate | KitOutdated | KitDirty | KitUnknown
data StatusRow = StatusRow { ... }
classify        :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
collectStatus   :: KitConfig -> FilePath -> [(FilePath, Text)] -> IO [StatusRow]
kitStatus       :: KitConfig -> IO ()

-- Baikai.Kit.Session
agentDirsForSession :: KitConfig -> IO [FilePath]     -- existing [userAgentsDir, projectAgentsDir]

-- Baikai.Kit.Command   (optparse-applicative glue, optional for callers)
data KitCommand = KitList | KitInstall !Text !KitScope | KitUpdate !(Maybe Text)
                | KitUninstall !Text !KitScope | KitStatus
kitCommandParser :: Parser KitCommand
runKit          :: KitConfig -> KitCommand -> IO ()
```

The record types deliberately carry **no field-name prefixes** (no `kitVersion`,
`skillName`, etc.); fields are accessed with `generic-lens` overloaded labels
(`entry ^. #name`) following baikai's house style and the project rule recorded in the
author's memory. `DuplicateRecordFields` plus `OverloadedLabels` (already in baikai's
default extensions) make this unambiguous.

**Manifest backward compatibility.** The unified `FromJSON` instances must parse all three
tools' existing `kit.json` files unchanged. The two compatibility-critical choices are:
`version` on `SkillEntry`/`AgentEntry` is `Maybe Text` (so `seihou` and `rei` v1 entries
that omit it still parse), and `files` on `AgentEntry` is `Maybe [Text]` (so `mori`'s
single-`path` agents and `rei`'s `path` + `files` agents both parse). The top-level
`version :: Int` is present in every existing manifest. EP-1 must include a test that loads
a captured copy of each tool's real `kit.json`. EP-2/3/4 must each verify their tool's live
manifest still loads.

**Provider layout resolution.** The package computes install subpaths by calling
`Baikai.AgentAssets.skillTargetPath` / `agentTargetPath` with `InteractiveProjectScope`
(the relative form, e.g. `.claude/skills/<name>` or `.agents/skills/<name>`) and joining
the result under the resolved agents base directory. This is exactly what `seihou` and
`rei` already do by hand; `mori` currently hardcodes `.claude/...` and gains Codex for free
by going through this path. EP-1 owns this helper; the migrations rely on it producing
byte-identical paths to what each tool produced before (for the Claude layout) so no
installed asset moves on disk.

**Cross-repository release mechanics.** `baikai-kit` lives in the `baikai` repository and
must be made resolvable by the three consuming repositories before their migrations can
build. EP-1 adds `baikai-kit` to `baikai`'s `cabal.project` and bumps the package set, and
records the exact version it publishes (start `0.1.0.0`). Critically, the three tools each
resolve baikai by a **different** mechanism, so each migration wires `baikai-kit` in
differently — this was confirmed during EP-2/3/4 research and is the main cross-repo risk:

- `mori` does **not** depend on `baikai` at all today; EP-2 adds it for the first time,
  wiring `baikai` and `baikai-kit` through mori's full Nix toolchain (`flake.nix`,
  `flake.module.nix`, `nix/haskell-overlay.nix`, `cabal.project`, `mori-cli.cabal`),
  modeled on mori's existing `okf-core` source pin.
- `rei` wires `baikai` **only** via a `source-repository-package` subdir entry in
  `cabal.project` (pinned to a baikai git tag), with no flake input and no overlay entry;
  EP-3 adds `baikai-kit` by extending that same `cabal.project` subdir list plus the
  `rei-cli.cabal` build-depends — no flake/overlay change.
- `seihou` pins **no** baikai source in `cabal.project`; `baikai`/`baikai-claude`/
  `baikai-openai` arrive through a shared `haskell-nix` registry overlay
  (`flake.module.nix`). EP-4 adds `baikai-kit` as a plain build-depends resolved by that
  overlay, with a documented temporary `source-repository-package` fallback if the registry
  has not yet surfaced `baikai-kit`.

The implication for EP-1: for `seihou` (and `mori`'s overlay) to resolve `baikai-kit`
without a manual source pin, the new package should be surfaced through the same shared
`haskell-nix` registry/overlay that already publishes `baikai`. EP-1 (or a follow-up step
recorded in its Decision Log) must ensure `baikai-kit` is registered there, or each
migration falls back to a `source-repository-package` pin of the baikai repo's
`baikai-kit` subdirectory at the revision EP-1 tags.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Scaffold `baikai-kit` package (cabal file, module skeleton, wired into `cabal.project`, builds empty)
- [x] EP-1: Port manifest + config + repo + install + sidecar + status + session modules
- [x] EP-1: Port and extend the test suite (manifest backward-compat fixtures, hash determinism, classify, install round-trip)
- [x] EP-1: Tag/record the published `baikai-kit` version for consumers
- [ ] EP-2: Add `baikai-kit` dependency to `mori`, replace `Mori.Command.Kit` with adapter, build green
- [ ] EP-2: Verify `mori kit list/install/update/uninstall/status` against real `mori-kit`; verify interactive `--add-dir` discovery
- [ ] EP-3: Add `baikai-kit` dependency to `rei`, replace `Rei.Cli.Commands.Kit.*` with adapter (preserve FZF picker), build green
- [ ] EP-3: Verify `rei kit ...` against real `rei-kit`; verify interactive discovery
- [ ] EP-4: Add `baikai-kit` dependency to `seihou`, replace `Seihou.CLI.Kit`/`KitPaths` with adapter, build green
- [ ] EP-4: Verify `seihou kit ...` against real `seihou-kit`; verify interactive discovery


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery (2026-06-23, during planning research): `mori`'s `Kit.hs` hardcodes
  `.claude/skills` and `.claude/agents` paths and does **not** route through
  `Baikai.AgentAssets`; only `seihou` and `rei` do. Consequence: routing the package
  through `AgentAssets` gives `mori` Codex support for free, but EP-2 must verify the
  Claude-layout paths remain byte-identical so no already-installed `mori` asset is
  orphaned.

- Discovery (2026-06-23, during EP-2/3/4 drafting): the three tools resolve baikai by three
  different build mechanisms (mori: none today / full Nix wiring; rei: `cabal.project`
  source-repo subdir pin; seihou: shared `haskell-nix` registry overlay). Captured in the
  Integration Points "Cross-repository release mechanics" entry above. EP-1 should surface
  `baikai-kit` through the shared registry overlay so seihou/mori resolve it without manual
  pins.

- Discovery (2026-06-23, during EP-2 drafting): `mori`'s session-discovery helper
  `agentDirsForRoot` takes a `projectRoot` argument and has one caller (the `mori agent ask`
  flow, `Agent.hs:2572`) that passes a **registered project root that is not the current
  working directory**. The package's `agentDirsForSession` resolves project scope from `cwd`
  only, so EP-2 replaces the cwd call sites with the package helper but keeps a small local
  `agentDirsForRoot` for that single non-cwd caller. The other tools do not have this case.

- Discovery (2026-06-23, during EP-3 drafting): in `rei`, the local `agentDirsForSession` is
  *defined* in rei-core but every *call site* (eight of them) is in rei-cli. EP-3 therefore
  places `reiKitConfig` in a new rei-cli module and gives only rei-cli the `baikai-kit`
  dependency; rei-core's local helper is deleted and rei-core does not gain the dependency.
  EP-3 also keeps rei's own optparse parser and FZF picker (`runFzf`/`Candidate`/`FzfResult`),
  interposing the picker before calling the package's `installItem` for the no-NAME case.

- Discovery (2026-06-23, EP-1 completion): `baikai-kit` is implemented and recorded at version
  `0.1.0.0`. Validation evidence from the `baikai` repository: `cabal test baikai-kit` passed
  all 13 tests (manifest fixtures for `mori`, `rei`, `seihou`; hash determinism; `classify`;
  install/uninstall round-trip across Claude and Codex), and `cabal build all` completed
  successfully. EP-2, EP-3, and EP-4 should pin `baikai-kit ^>=0.1.0`.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Build a new sibling package `baikai-kit` rather than adding kit logic to the
  `baikai` core package.
  Rationale: Keeps `process`/`directory`/SHA-256 dependencies out of baikai's pure,
  dependency-light core; matches the existing multi-package repository layout. (User chose
  this option explicitly during planning.)
  Date: 2026-06-23

- Decision: Base the package on `mori`'s superset feature set (manifest entry versions,
  per-install sidecar metadata, SHA-256 content hash, and the
  up-to-date/outdated/dirty/unknown status model) rather than the minimal common subset.
  Rationale: `seihou` and `rei` are strict subsets of `mori`; adopting the superset gives
  them version-aware status for free and the manifest stays backward compatible because the
  extra fields are optional. (User chose this option explicitly during planning.)
  Date: 2026-06-23

- Decision: Migrate `mori` first (EP-2), then `rei` and `seihou` (EP-3/EP-4) in parallel.
  Rationale: The package is derived from `mori`, so `mori`'s migration is the strongest
  validation of the API; gaps found there are folded back into EP-1 before the other two
  start.
  Date: 2026-06-23

- Decision: Keep tool-specific UI (e.g. `rei`'s FZF interactive picker) and each tool's
  optparse wiring in the tool, not in the package. The package exposes both a
  batteries-included `runKit` and the lower-level engine functions so a tool can intercept
  one subcommand (e.g. interactive install) while delegating the rest.
  Rationale: Preserves each tool's UX without leaking terminal-UI concerns into a library.
  Date: 2026-06-23

- Decision: Treat EP-1's `baikai-kit-0.1.0.0` implementation as the initial package contract
  for migrations.
  Rationale: The package builds in the baikai multi-package project, exposes the planned public
  modules and functions, and has direct regression coverage for all three current manifests plus
  install/status primitives. The migration plans can now consume it without stubbing.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-1 is complete as of 2026-06-23. The `baikai` repository now ships the new `baikai-kit`
package at version `0.1.0.0`; the package is wired into `cabal.project`, builds with the rest
of the repository, and has a passing focused test suite. The initiative is not complete yet:
the remaining outcomes depend on migrating `mori`, `rei`, and `seihou` in EP-2 through EP-4.

Revision note (2026-06-23): Marked EP-1 complete after implementing and validating
`baikai-kit-0.1.0.0`; recorded validation evidence and the package version for EP-2 through EP-4.
