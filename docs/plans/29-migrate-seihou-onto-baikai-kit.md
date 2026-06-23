---
id: 29
slug: migrate-seihou-onto-baikai-kit
title: "Migrate seihou onto baikai-kit"
kind: exec-plan
created_at: 2026-06-23T22:59:48Z
intention: "intention_01kvvb9hgbed48wzdkamgedm24"
master_plan: "docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md"
---

# Migrate seihou onto baikai-kit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, the `seihou` CLI's `kit` feature (installing, updating, removing, and
listing skills and subagents from the `seihou-kit` repository) is powered entirely by the
shared `baikai-kit` Haskell library instead of seihou's own hand-written kit code. The
hand-written modules `Seihou.CLI.Kit` (~525 lines) and `Seihou.CLI.KitPaths` (~123 lines)
are deleted and replaced by a tiny adapter that defines one `KitConfig` value and forwards
to the library. Nothing about the user-facing commands changes shape — `seihou kit list`,
`seihou kit install NAME [--project]`, `seihou kit update [NAME]`, `seihou kit uninstall
NAME [--project]`, and `seihou kit status` behave the same, install to the same paths for
both the Claude Code and Codex layouts, and interactive agent sessions still discover
installed assets through `--add-dir`.

There is exactly one intended behavior change, and it is a gain: `seihou kit status` was the
simplest of the three CLIs' implementations and reported only `NAME / TYPE / SCOPE /
PROVIDERS`, with no notion of whether an installed item is current. The shared library was
modeled on `mori`'s superset, which is version-aware. After migration, `seihou kit status`
gains a `STATE` column reporting `up-to-date`, `outdated`, `dirty`, or `unknown` per item,
computed from a sidecar metadata file the installer writes. seihou's `seihou-kit` manifest is
a v1 manifest whose skills have `name`/`description`/`path`/`files` and whose `agents` array
is presently empty (and the agent schema carries no `version` and no `files`); the library's
manifest record makes those fields optional (`Maybe`), so the existing manifest still parses
unchanged.

You can see it working by running `seihou kit list` against the real `seihou-kit`, installing
a real item with `--project` into a throwaway directory, and observing the same files appear
under `.claude/skills/...` and `.agents/skills/...` (or `.codex/agents/...`) as before, then
running `seihou kit status` and seeing the new `STATE` column populated.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `baikai-kit` to seihou's build inputs (flake registry overlay + `cabal.project`
  if a local path is needed + all three `seihou-cli` components in `seihou-cli.cabal`);
  `cabal build all` is green.
- [ ] M2: Replace `Seihou.CLI.Kit` and `Seihou.CLI.KitPaths` with a thin adapter module that
  defines `seihouKitConfig` and re-exports the package's `KitCommand`, `kitCommandParser`, and
  a `runKit` wrapper; delete the old hand-written logic; keep `Commands.Command`'s `Kit
  KitCommand` variant wired through the adapter.
- [ ] M3: Replace `Seihou.CLI.AgentLaunch.agentDirsForSession` with a call to
  `Baikai.Kit.Session.agentDirsForSession seihouKitConfig`.
- [ ] M4: Port/trim `KitPathsSpec` (path logic now lives in `baikai-kit` / `Baikai.AgentAssets`),
  run the seihou test suite green.
- [ ] M5: Manual verification against the real `seihou-kit`, confirming both Claude and Codex
  layouts and the new `STATE` column.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: seihou consumes `baikai`, `baikai-claude`, and `baikai-openai` through the
  shared haskell-nix **registry overlay**, not through a `source-repository-package` or a
  local path in `cabal.project`. Evidence: `seihou/cabal.project` lists only `seihou-core`,
  `seihou-cli`, `seihou-okf-extension`, the streamly pair, and `okf-core`; it has no `baikai`
  entry. `seihou-cli/seihou-cli.cabal` depends on `baikai ^>=0.1.0.0`, and
  `flake.module.nix` composes `inputs.haskell-nix.lib.haskellExtension` (the registry overlay)
  with `./nix/haskell-overlay.nix`. The registry overlay is where the baikai package set is
  provided. Therefore `baikai-kit` is added the same way: a `baikai-kit ^>=0.1.0.0`
  build-depends line, resolved by the registry overlay.

- Discovery: the kit code spans two cabal components. `Seihou.CLI.Kit` (parser, `runKit`,
  manifest types, git ops) lives under `seihou-cli/src-exe/` and is an `other-modules` entry
  of the `executable seihou` component. `Seihou.CLI.KitPaths` lives under `seihou-cli/src/`
  and is an `exposed-modules` entry of the private `library seihou-cli-internal`. The test
  `Seihou.CLI.KitPathsSpec` lives under `seihou-cli/test/` in the `test-suite
  seihou-cli-test` component and imports `KitPaths`. All three components must therefore see
  `baikai-kit`. (See the "Trapped-modules" note in the cabal: `Seihou.CLI.Kit` is trapped in
  the executable because it uses `Options.Applicative`.)

- Discovery: seihou's `seihou-kit` manifest currently has an **empty** `agents` array — only
  two skills (`seihou-scaffold-kit-skill`, `seihou-module-readme`). So the agent-install code
  path is exercised in seihou's tests/fixtures but not by the live manifest. The library's
  optional `version`/`files` agent fields matter for forward compatibility, not for the
  current manifest.


## Decision Log

Record every decision made while working on the plan.

- Decision: Adopt the package's `Baikai.Kit.Command.KitCommand` directly for seihou's
  `Commands.Command`'s `Kit` variant, rather than keeping seihou's own `KitCommand` plus a
  translation layer.
  Rationale: seihou's hand-written `KitCommand` is structurally identical to the package's
  (`KitList | KitInstall | KitUpdate | KitUninstall | KitStatus`). The only differences are
  cosmetic: seihou wraps install/uninstall arguments in `KitInstallOpts`/`KitUninstallOpts`
  records and represents scope as a `Bool` (`--project`), whereas the package carries `Text`
  plus `KitScope` inline. Both parsers expose the same `--project` flag and the same
  subcommand names, so adopting the package type and `kitCommandParser` is a clean drop-in.
  Date: 2026-06-23

- Decision: Wire `baikai-kit` through the haskell-nix registry overlay (the same mechanism as
  `baikai`), not through a new `source-repository-package` stanza.
  Rationale: consistency with how `baikai` is already consumed; the registry overlay is the
  single source of truth for the baikai package set on this machine, and `baikai-kit` is a
  package inside the `baikai` repo's `cabal.project`.
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This is child plan EP-4 of the MasterPlan at
`docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md`. That initiative
extracts the duplicated "kit" feature (install/update/uninstall/list/status of skills and
subagents from a git-hosted kit repository) out of three CLIs — `mori`, `rei`, and `seihou`
— into a new shared Haskell library, **`baikai-kit`**, which is built by the sibling plan
`docs/plans/26-build-the-baikai-kit-package.md` (EP-1) and lives inside the `baikai` repo at
`baikai-kit/`. THIS plan migrates **seihou** to consume that package and deletes seihou's
hand-written kit code.

This plan has a HARD dependency on EP-26 (the `baikai-kit` package must exist, build, and have
a recorded published version) and a SOFT dependency on
`docs/plans/27-migrate-mori-onto-baikai-kit.md` (EP-2, mori's migration), which exercises the
package's version-aware path first. seihou has the SIMPLEST kit implementation of the three
(no versioning, no sidecar, no status state), so after migration seihou GAINS mori's
version-aware status for free.

The seihou repository under inspection is `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou`
(registered with `mori` as `shinzui/seihou`). The kit content repository is `seihou-kit`
(checked out at `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou-kit`), cloned by the CLI
from `https://github.com/shinzui/seihou-kit.git` into `~/.cache/seihou/kit/`. Note: there are
also template registries `shinzui/agent-seihou` and `shinzui/seihou-modules` — those are kit
content sources, not the CLI; do NOT modify them.

Key seihou files relevant to this plan, by full path:

- `seihou-cli/src-exe/Seihou/CLI/Kit.hs` — the hand-written kit command module
  (~525 lines). It owns: the `KitCommand` ADT and its `*Opts` records; `kitCommandParser ::
  Parser KitCommand`; `runKit :: KitCommand -> IO ()`; manifest types (`KitManifest`,
  `SkillEntry`, `AgentEntry`, `KitItem`); the `listAvailable` / `installItem` / `updateKit` /
  `uninstallItem` / `kitStatus` implementations; git operations `ensureKitRepo` /
  `pullKitRepo`; and `loadManifest` / `lookupItem`. Its repo URL constant is
  `defaultKitRepoUrl = "https://github.com/shinzui/seihou-kit.git"`, cloned with
  `git clone --depth 1 <url> <cacheDir>` into `kitCacheDir = ~/.cache/seihou/kit`. This module
  is an `other-modules` entry of the `executable seihou` component (it is "trapped" there by
  `Options.Applicative`).

- `seihou-cli/src/Seihou/CLI/KitPaths.hs` — provider-layout path logic (~123 lines). It owns
  `data KitProviderLayout = ClaudeLayout | CodexLayout`, `data InstalledKitItem`
  (`installedName`/`installedType`/`installedProvider`), `allKitProviderLayouts`,
  `providerLabel`, `skillTargetDir`, `agentTargetFile`, `codexAgentToml`, and
  `scanInstalledForProvider`. It already delegates path construction to
  `Baikai.AgentAssets` (`skillTargetPath`, `agentTargetPath`, `codexCustomAgentToml`,
  `agentAssetFormat`) and to `Baikai.Interactive` (`InteractiveProvider(..)`,
  `InteractiveScope(..)`). It is an `exposed-modules` entry of `library
  seihou-cli-internal` (hs-source-dirs `src`).

- `seihou-cli/test/Seihou/CLI/KitPathsSpec.hs` — hspec/tasty spec asserting the Claude and
  Codex target paths (e.g. `.claude/skills/review`, `.codex/agents/reviewer.toml`,
  `.agents/skills/review`), the `codexAgentToml` shape, and `scanInstalledForProvider`
  discovery. Listed under `test-suite seihou-cli-test`.

- `seihou-cli/src/Seihou/CLI/AgentLaunch.hs`, lines 63–71 — `agentDirsForSession :: IO
  [FilePath]`, which returns the existing-on-disk subset of `[~/.config/seihou/agents,
  ./.seihou/agents]`. Its sole caller is `seihou-cli/src-exe/Seihou/CLI/AgentLaunchExec.hs`
  line 32 (`addDirs <- agentDirsForSession`), which passes those directories to the launched
  Claude session via `--add-dir` so interactive agents can find installed kit assets.

- `seihou-cli/src-exe/Main.hs`, lines 24 and 125–126 — `import Seihou.CLI.Kit (runKit)` and
  the dispatch arm `Kit kitCmd -> runKit kitCmd`.

- `seihou-cli/src-exe/Seihou/CLI/Commands.hs` — line 50 `import Seihou.CLI.Kit (KitCommand,
  kitCommandParser)`, line 83 the constructor `| Kit KitCommand`, line 35 the re-export
  `KitCommand (..)`, and lines 1245–1251 the `kitInfo` parser info that uses `Kit <$>
  kitCommandParser`.

- `seihou-cli/seihou-cli.cabal` — three components touch kit code: `library
  seihou-cli-internal` (depends on `baikai`, exposes `Seihou.CLI.KitPaths`), `executable
  seihou` (depends on `baikai`, `optparse-applicative`, lists `Seihou.CLI.Kit`), and
  `test-suite seihou-cli-test` (depends on `baikai`, lists `Seihou.CLI.KitPathsSpec`).

- `seihou-cli/help/kit.md` — static help text; described as "install, update, and remove
  skills and subagents from a remote repository (seihou-kit) ... provider-native copies for
  both Claude Code and Codex". It mentions `kit status` "Show installed items with scope and
  providers"; this line may want a trivial update to mention the new STATE column (optional).

- Build wiring: `seihou/cabal.project` (packages: `seihou-core`, `seihou-cli`,
  `seihou-okf-extension`; plus streamly and `okf-core` source-repository-packages — NO
  baikai), `seihou/flake.nix`, `seihou/flake.module.nix` (defines `haskellPackages =
  pkgs.haskell.packages.ghc9124.override` composing
  `inputs.haskell-nix.lib.haskellExtension` — the registry overlay that supplies the baikai
  package set — with `./nix/haskell-overlay.nix`), and `seihou/nix/haskell-overlay.nix` (only
  `okf-core`, `seihou-core`, `seihou-cli`, `seihou-okf-extension` via `callCabal2nix`; baikai
  is NOT listed here — it comes from the registry overlay).

Term definitions:

- **KitConfig**: the small record the library is parameterized over — the tool's name, its kit
  repo URL, and the providers it installs for.
- **Provider layout / AgentAssetProvider**: which agent tool the installed asset targets.
  seihou supports two: `InteractiveClaude` (Claude Code, `.claude/skills`, `.claude/agents`)
  and `InteractiveCodex` (Codex, `.agents/skills`, `.codex/agents` with TOML custom agents).
- **Sidecar**: a small metadata file the library's installer writes next to each installed
  asset, recording name/kind/declared-version and a content hash, used to compute the new
  status STATE. seihou today writes no sidecar; after migration it does.
- **Status STATE**: per-item `up-to-date` / `outdated` / `dirty` / `unknown`, derived by
  comparing the installed sidecar against the upstream manifest and on-disk content.


## Plan of Work

The work is five milestones. Each is independently verifiable.

### M1 — Add `baikai-kit` to seihou's build

Scope: make the `baikai-kit` package visible to all three `seihou-cli` components without
changing any kit behavior yet. At the end, `cabal build all` and `nix build .#seihou` both
succeed with `baikai-kit` resolvable (even though nothing imports it yet — add a throwaway
import or simply confirm the dependency resolves; prefer to land M1 together with M2's first
import so the dependency is genuinely used).

Edits:

1. `seihou-cli/seihou-cli.cabal`: add `baikai-kit ^>=0.1.0.0` to the `build-depends` of
   `library seihou-cli-internal`, `executable seihou`, and `test-suite seihou-cli-test`,
   alongside the existing `baikai ^>=0.1.0.0` lines. Pin the same major/minor as the other
   baikai packages (use the exact version EP-26 records when it publishes; `^>=0.1.0.0`
   matches the current baikai package set).

2. `seihou/flake.module.nix` / registry overlay: confirm `baikai-kit` is provided by
   `inputs.haskell-nix.lib.haskellExtension` (the registry overlay) once EP-26 adds it to the
   baikai repo's package set and the registry is refreshed. No edit to `nix/haskell-overlay.nix`
   is needed (that file only defines seihou's own packages plus `okf-core`; baikai packages
   come from the registry overlay). If — and only if — the registry overlay does not yet
   surface `baikai-kit`, add a temporary `source-repository-package` (or local path) for it to
   `seihou/cabal.project` pinning the same baikai revision; remove it once the registry is
   refreshed.

3. `seihou/cabal.project`: normally no change (baikai is resolved by the package set, not
   pinned here). Only touch it for the temporary fallback in step 2.

Commands: from `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou`, `cabal build all`.
Acceptance: build is green and `cabal build seihou-cli` shows `baikai-kit` among the resolved
dependencies.

### M2 — Replace the kit modules with a thin adapter

Scope: delete `Seihou.CLI.Kit` and `Seihou.CLI.KitPaths`'s hand-written logic and replace with
an adapter that holds `seihouKitConfig` and forwards to the library. At the end, `seihou kit
*` is fully driven by `baikai-kit`.

Edits:

1. Create a single small adapter module, `seihou-cli/src/Seihou/CLI/Kit.hs` — but note the
   placement subtlety. The library-first convention prefers `src/`, yet the current
   `Seihou.CLI.Kit` is trapped in the executable by `Options.Applicative`. The adapter still
   re-exports a `Parser`, so it remains `Options.Applicative`-dependent and must stay in the
   executable component. Keep the adapter at `seihou-cli/src-exe/Seihou/CLI/Kit.hs` (replacing
   the old file in place). Its contents:

   ```haskell
   module Seihou.CLI.Kit
     ( KitCommand,
       kitCommandParser,
       seihouKitConfig,
       runKit,
     )
   where

   import Baikai.Kit.Command (KitCommand, kitCommandParser)
   import Baikai.Kit.Command qualified as Kit
   import Baikai.Kit.Config (KitConfig (..))
   import Baikai.Interactive (InteractiveProvider (InteractiveClaude, InteractiveCodex))

   seihouKitConfig :: KitConfig
   seihouKitConfig =
     KitConfig
       { toolName = "seihou",
         repoUrl = "https://github.com/shinzui/seihou-kit.git",
         providers = [InteractiveClaude, InteractiveCodex]
       }

   runKit :: KitCommand -> IO ()
   runKit = Kit.runKit seihouKitConfig
   ```

   (Confirm the exact module path of `AgentAssetProvider`/`InteractiveProvider` when EP-26
   lands; per the package API contract, `KitConfig.providers :: [AgentAssetProvider]` where
   `AgentAssetProvider = InteractiveProvider (InteractiveClaude | InteractiveCodex)`. If the
   package re-exports these under `Baikai.Kit.Config`, import from there instead.)

2. Delete `seihou-cli/src/Seihou/CLI/KitPaths.hs` entirely (its path logic now lives in
   `baikai-kit`, which itself delegates to `Baikai.AgentAssets`). Remove `Seihou.CLI.KitPaths`
   from `library seihou-cli-internal`'s `exposed-modules` in the cabal.

3. `seihou-cli/src-exe/Main.hs`: no change needed — it already does `import Seihou.CLI.Kit
   (runKit)` and `Kit kitCmd -> runKit kitCmd`. The adapter preserves both names, so the
   dispatch arm now flows through `Baikai.Kit.Command.runKit seihouKitConfig`.

4. `seihou-cli/src-exe/Seihou/CLI/Commands.hs`: no change needed — it imports `KitCommand` and
   `kitCommandParser` from `Seihou.CLI.Kit` (now the adapter re-exports both from the
   package), keeps `| Kit KitCommand`, the `KitCommand (..)` re-export, and `Kit <$>
   kitCommandParser`. Verify it still compiles; the package's `KitCommand` must derive/expose
   whatever `Commands.hs` needs (the `(..)` re-export expects constructors — confirm the
   package exports `KitCommand (..)`; if it exports only the type, change the Commands.hs
   re-export to `KitCommand` without `(..)`).

5. Remove the now-dead helper code: all of the old `Seihou.CLI.Kit` body (manifest types,
   `installItem`, `updateKit`, `uninstallItem`, `kitStatus`, `ensureKitRepo`, `pullKitRepo`,
   `loadManifest`, `lookupItem`, the field accessors) is deleted in step 1's rewrite.

Commands: `cabal build all`. Acceptance: build green; `seihou kit --help` lists the same five
subcommands with the same `--project` flag.

### M3 — Route interactive sessions through the library

Scope: replace seihou's local `agentDirsForSession` with the library's version so the set of
`--add-dir` directories is owned by `baikai-kit` and derived from `seihouKitConfig`.

Edits:

1. `seihou-cli/src/Seihou/CLI/AgentLaunch.hs`: remove the local `agentDirsForSession`
   definition (lines 63–71) and its export, OR replace its body with a thin re-export. Because
   `Baikai.Kit.Session.agentDirsForSession :: KitConfig -> IO [FilePath]` needs `seihouKitConfig`,
   and `seihouKitConfig` lives in the executable-trapped adapter, the cleanest wiring is to
   move the call to the executable side. Change `AgentLaunchExec.hs` line 32 from `addDirs <-
   agentDirsForSession` to:

   ```haskell
   import Baikai.Kit.Session qualified as KitSession
   import Seihou.CLI.Kit (seihouKitConfig)
   -- ...
   addDirs <- KitSession.agentDirsForSession seihouKitConfig
   ```

   and drop the `import Seihou.CLI.AgentLaunch (agentDirsForSession)` line. Delete
   `agentDirsForSession` from `AgentLaunch.hs` and from its export list.

2. Verify the library's `agentDirsForSession` returns the same directory set seihou used:
   `~/.config/seihou/agents` (user) and `./.seihou/agents` (project), filtered to those that
   exist. The library derives these from `KitConfig.toolName = "seihou"` plus the providers;
   confirm the derived paths match exactly (see Validation). If the library only returns Claude
   layout dirs, that still matches seihou's old behavior (seihou's old `agentDirsForSession`
   returned only the `.../agents` Claude-style dirs, not Codex `.agents`/`.codex` dirs).

Commands: `cabal build all`. Acceptance: build green; a debug agent launch shows the same
`--add-dir` set as before.

### M4 — Port/trim the test suite

Scope: the path-logic test `KitPathsSpec` asserts behavior that now lives in `baikai-kit`
(which itself delegates to `Baikai.AgentAssets`). Remove the seihou-side test for deleted code
and rely on `baikai-kit`'s own test suite (EP-26 M7) for path coverage.

Edits:

1. Delete `seihou-cli/test/Seihou/CLI/KitPathsSpec.hs` and remove `Seihou.CLI.KitPathsSpec`
   from `test-suite seihou-cli-test`'s `other-modules`. Remove its registration from the test
   runner `seihou-cli/test/Main.hs` (find the `KitPathsSpec.tests` reference and drop it).

2. If the team wants a seihou-side regression guard, add a tiny spec asserting
   `seihouKitConfig` has the expected `toolName`/`repoUrl`/`providers`, but this is optional;
   the package owns path behavior now.

Commands: `cabal test all` (or `cabal test seihou-cli`). Acceptance: the full seihou test
suite is green with no reference to deleted modules.

### M5 — Manual verification against the real seihou-kit

Scope: exercise every kit subcommand end-to-end against the real `seihou-kit`, confirming
identical install paths for both providers and the new STATE column. See Validation for exact
commands and expected output shapes.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou` unless noted.

Build after M1 + M2:

```bash
cabal build all
```

Expected: all components compile; `baikai-kit` appears in the dependency graph. If the
registry overlay has not yet surfaced `baikai-kit`, the build fails resolving
`baikai-kit ^>=0.1.0.0` — apply the temporary `cabal.project` fallback from M1 step 2.

Nix build (confirms the registry overlay path):

```bash
nix build .#seihou
```

Expected: builds the bundled `seihou` binary; no `baikai-kit` resolution error.

Run the test suite after M4:

```bash
cabal test all
```

Expected transcript shape (the `KitPaths` group is gone; everything else green):

```text
seihou-cli-test
  Seihou.CLI.AgentLaunch
    ...                       OK
  ...
All N tests passed (…s)
```

Manual smoke test of the migrated kit (M5), using a throwaway project dir to avoid polluting
`~/.config/seihou`:

```bash
SEIHOU=$(cabal list-bin seihou)
mkdir -p /tmp/seihou-kit-smoke && cd /tmp/seihou-kit-smoke

# 1. list
"$SEIHOU" kit list
```

Expected (matches the real manifest: two skills, no agents):

```text
Skills:
  seihou-scaffold-kit-skill  Scaffold new Claude Code skills and agents for Seihou, …
  seihou-module-readme       Generate or refresh a human-readable README.md for a Seihou module, …
```

```bash
# 2. install a real item to PROJECT scope (writes both provider layouts)
"$SEIHOU" kit install seihou-module-readme --project
```

Expected:

```text
Installed skill 'seihou-module-readme' for Claude Code and Codex (project scope).
```

```bash
# 3. confirm both layouts on disk
find .claude/skills .agents/skills -maxdepth 2 -type f
```

Expected (identical paths to pre-migration):

```text
.claude/skills/seihou-module-readme/SKILL.md
.agents/skills/seihou-module-readme/SKILL.md
```

```bash
# 4. status — NOW shows the new STATE column
"$SEIHOU" kit status
```

Expected shape (note the added STATE column vs. the old NAME/TYPE/SCOPE/PROVIDERS):

```text
NAME                  TYPE   SCOPE    STATE       PROVIDERS
seihou-module-readme  skill  project  up-to-date  claude,codex
```

```bash
# 5. uninstall from project scope
"$SEIHOU" kit uninstall seihou-module-readme --project
```

Expected:

```text
Uninstalled 'seihou-module-readme' from project scope (claude skill, codex skill).
```

```bash
# 6. status again — empty
"$SEIHOU" kit status
```

Expected:

```text
No kit items installed.
```

Verify interactive-session asset discovery (M3) without launching a full agent, using debug
mode if available, or by inspecting that `~/.config/seihou/agents` and `./.seihou/agents`
(when present) are passed through. After a user-scope install, the dir exists and is included:

```bash
"$SEIHOU" kit install seihou-module-readme   # user scope
ls ~/.config/seihou/agents/.claude/skills    # the installed skill is discoverable
"$SEIHOU" kit uninstall seihou-module-readme  # cleanup
```


## Validation and Acceptance

Acceptance is phrased as observable behavior:

1. **Install paths unchanged for BOTH providers.** Installing any skill with `--project`
   produces the same files at the same paths as before migration: Claude at
   `<dir>/.claude/skills/<name>/<files>` and Codex at `<dir>/.agents/skills/<name>/<files>`;
   for agents (none in the live manifest, but covered by the package), Claude at
   `<dir>/.claude/agents/<name>.md` and Codex at `<dir>/.codex/agents/<name>.toml` with the
   markdown wrapped as a Codex custom-agent TOML. Compare against the pre-migration paths
   asserted by the old `KitPathsSpec` (`.claude/skills/review`, `.codex/agents/reviewer.toml`,
   `.agents/skills/review`).

2. **The new version-aware STATE column appears.** `seihou kit status` now prints a `STATE`
   column with `up-to-date` / `outdated` / `dirty` / `unknown`. This is the single intended
   behavior change and must be called out in the release notes / `help/kit.md`. Confirm a
   freshly installed item reports `up-to-date`; manually edit an installed file and confirm it
   flips to `dirty`; this proves the sidecar mechanism is live.

3. **The real `seihou-kit` manifest parses unchanged.** The manifest at
   `seihou-project/seihou-kit/kit.json` is `version: 1` with two skills (each
   `name`/`description`/`path`/`files`) and an empty `agents` array. It must decode into the
   library's `KitManifest` without error even though (a) skills omit `version` and (b) the
   agent schema has no `version`/`files`, because those package fields are `version :: Maybe
   Text` and `files :: Maybe [Text]` and `aeson` treats `Maybe` as optional. Validate by
   running `seihou kit list` and seeing both skills.

4. **Interactive sessions still discover assets.** After a user-scope install,
   `Baikai.Kit.Session.agentDirsForSession seihouKitConfig` includes `~/.config/seihou/agents`
   (and `./.seihou/agents` when present), matching the directories the old
   `Seihou.CLI.AgentLaunch.agentDirsForSession` returned, so `claude --add-dir` still points at
   the installed kit content.

5. **seihou test suite green.** `cabal test all` passes with `KitPathsSpec` removed and no
   dangling references; `nix build .#seihou` and the `cli-module-placement` flake check pass.


## Idempotence and Recovery

- All kit subcommands are idempotent by design: `install` overwrites in place,
  `uninstall` of a missing item prints "not installed", `update` re-pulls and re-installs.
  Re-running any manual step is safe.

- The deleted modules (`Seihou.CLI.Kit` old body, `Seihou.CLI.KitPaths`,
  `Seihou.CLI.KitPathsSpec`) remain in git history; recover with `git show
  HEAD~1:seihou-cli/src/Seihou/CLI/KitPaths.hs` if needed.

- If the migrated dispatch misbehaves, revert just the wiring: restore the old
  `Seihou.CLI.Kit` from history and re-point `Main.hs` / `Commands.hs` imports; the
  build-input change (M1) is independent and can stay.

- For manual install tests, ALWAYS prefer `--project` scope inside a throwaway directory
  (e.g. `/tmp/seihou-kit-smoke`) so you never pollute `~/.config/seihou`. If you do install at
  user scope to test discovery, uninstall immediately afterward.

- The M1 temporary `cabal.project` fallback (if used) is removable the moment the registry
  overlay surfaces `baikai-kit`; deleting the stanza and rebuilding is safe.


## Interfaces and Dependencies

seihou depends on the `baikai-kit` library (built by `docs/plans/26-build-the-baikai-kit-package.md`),
resolved through the shared haskell-nix registry overlay exactly like `baikai`. The public API
seihou consumes, embedded verbatim from the package contract:

```haskell
-- Baikai.Kit.Manifest
data KitManifest = KitManifest { version :: !Int, skills :: ![SkillEntry], agents :: ![AgentEntry] }
data SkillEntry  = SkillEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text), path :: !Text, files :: ![Text] }
data AgentEntry  = AgentEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text), path :: !Text, files :: !(Maybe [Text]) }
data KitItem     = KitSkillItem !SkillEntry | KitAgentItem !AgentEntry
-- Baikai.Kit.Config
data KitConfig = KitConfig { toolName :: !Text, repoUrl :: !Text, providers :: ![AgentAssetProvider] }  -- AgentAssetProvider = InteractiveProvider (InteractiveClaude | InteractiveCodex)
data KitScope  = UserScope | ProjectScope
-- Baikai.Kit.Repo:    ensureKitRepo :: KitConfig -> IO FilePath ; pullKitRepo :: KitConfig -> FilePath -> IO ()
-- Baikai.Kit.Install: loadManifest :: FilePath -> IO KitManifest ; lookupItem :: Text -> KitManifest -> Maybe KitItem ; installItem/uninstallItem :: KitConfig -> Text -> KitScope -> IO () ; updateKit :: KitConfig -> Maybe Text -> IO () ; listAvailable :: KitConfig -> IO ()
-- Baikai.Kit.Sidecar: data SidecarMeta {...} ; computeKitHash :: FilePath -> [Text] -> IO Text
-- Baikai.Kit.Status:  data KitState = KitUpToDate|KitOutdated|KitDirty|KitUnknown ; classify ; collectStatus ; kitStatus :: KitConfig -> IO ()
-- Baikai.Kit.Session: agentDirsForSession :: KitConfig -> IO [FilePath]
-- Baikai.Kit.Command: data KitCommand = KitList | KitInstall !Text !KitScope | KitUpdate !(Maybe Text) | KitUninstall !Text !KitScope | KitStatus ; kitCommandParser :: Parser KitCommand ; runKit :: KitConfig -> KitCommand -> IO ()
-- Baikai.Kit: umbrella re-export.
```

Record fields carry NO Hungarian prefixes; access via generic-lens labels (`entry ^. #name`).

The one `KitConfig` value seihou must define:

```haskell
seihouKitConfig :: KitConfig
seihouKitConfig = KitConfig
  { toolName  = "seihou"
  , repoUrl   = "https://github.com/shinzui/seihou-kit.git"
  , providers = [InteractiveClaude, InteractiveCodex]
  }
```

`repoUrl` is verified against seihou's existing `Seihou.CLI.Kit.defaultKitRepoUrl =
"https://github.com/shinzui/seihou-kit.git"`, cloned with `git clone --depth 1` into
`~/.cache/seihou/kit`. The library's `ensureKitRepo`/`pullKitRepo` must reproduce this clone
location and depth (or an equivalent per-tool cache under `~/.cache/<toolName>/kit`); confirm
the cache path the package uses matches seihou's so an already-cloned cache is reused, not
re-cloned.

Signatures and modules that must exist at the end of each milestone:

- After M1: `baikai-kit ^>=0.1.0.0` resolves for `library seihou-cli-internal`, `executable
  seihou`, and `test-suite seihou-cli-test` in `seihou-cli/seihou-cli.cabal`.
- After M2: `seihou-cli/src-exe/Seihou/CLI/Kit.hs` exports `seihouKitConfig :: KitConfig`,
  `runKit :: KitCommand -> IO ()` (= `Baikai.Kit.Command.runKit seihouKitConfig`), and
  re-exports `KitCommand` / `kitCommandParser :: Parser KitCommand` from
  `Baikai.Kit.Command`. `Seihou.CLI.KitPaths` no longer exists. `Seihou.CLI.Commands.Command`
  still has the `Kit KitCommand` constructor wired through the adapter.
- After M3: `Seihou.CLI.AgentLaunchExec` calls `Baikai.Kit.Session.agentDirsForSession
  seihouKitConfig`; `Seihou.CLI.AgentLaunch.agentDirsForSession` is removed.
- After M4: `Seihou.CLI.KitPathsSpec` is removed from the build; path coverage is owned by
  `baikai-kit`'s own test suite.
