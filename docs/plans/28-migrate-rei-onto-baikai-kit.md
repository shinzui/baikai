---
id: 28
slug: migrate-rei-onto-baikai-kit
title: "Migrate rei onto baikai-kit"
kind: exec-plan
created_at: 2026-06-23T22:59:48Z
intention: "intention_01kvvb9hgbed48wzdkamgedm24"
master_plan: "docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md"
---

# Migrate rei onto baikai-kit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`rei` is a personal time-management and coaching CLI living in the repository
`/Users/shinzui/Keikaku/bokuno/rei-project/rei`. It ships a `kit` feature: `rei kit list`,
`rei kit install <name>`, `rei kit update`, `rei kit uninstall <name>`, and
`rei kit status` clone the `rei-kit` git repository, read its `kit.json` manifest, and copy
skills and subagents into provider-native directory layouts for both Claude Code and Codex,
under either user scope (`~/.config/rei/agents/`) or project scope (`.rei/agents/`). Today
`rei` implements this feature itself, in roughly 765 lines across four modules under
`rei-cli/src/Rei/Cli/Commands/Kit/`, plus a local `agentDirsForSession` discovery helper in
`rei-core`. The implementation is, by `rei`'s own source comments, "adapted from the mori
reference" — a near-duplicate of the same feature in `mori` and `seihou`.

After this change, `rei` no longer carries that duplicated logic. It depends on the shared
Haskell package `baikai-kit` (built by sibling plan
`docs/plans/26-build-the-baikai-kit-package.md`), supplies one small `KitConfig` value
describing its name, kit repository URL, and the two provider layouts it targets, and
reduces its kit code to a thin adapter: a config value, `rei`'s existing optparse parser,
and a dispatch function. The user sees no change. `rei kit list/install/update/uninstall/
status` behave exactly as before; every installed asset lands at byte-identical paths;
the real `rei-kit` `kit.json` still parses; and — critically — `rei`'s unique **FZF
interactive picker** (run when `rei kit install` is given no NAME) still works, because the
package deliberately exposes lower-level engine functions alongside its batteries-included
`runKit`, so `rei` keeps its terminal UI and merely calls the package's install engine.

You can see it working by running, from a checkout of `rei`, `cabal build all` (green),
then `rei kit list` (lists the real `rei-kit` skills and agents), `rei kit install` with no
name (the FZF picker appears, you choose an item, it installs), and `rei kit install
<name> --project` (installs into `.rei/agents/.claude/...` and the Codex roots). An
interactive `rei` coaching session still discovers the installed assets through
`--add-dir`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `baikai-kit` to `rei`'s build inputs (cabal.project subdir + rei-cli `.cabal`
  build-depends); `cabal build all` green with the dependency resolvable but not yet used.
- [ ] M2: Replace `Rei.Cli.Commands.Kit.{Types,Handler,Paths}` with a thin adapter
  (`reiKitConfig`, keep `Parser`, wire install → picker + `installItem`, others → `runKit`);
  delete the old logic; build green.
- [ ] M3: Replace rei's local `agentDirsForSession` with
  `Baikai.Kit.Session.agentDirsForSession reiKitConfig` at all call sites; remove the
  rei-core helper and its re-export.
- [ ] M4: Port/trim the Kit test suite; run `rei`'s test suites green.
- [ ] M5: Manual verification against the real `rei-kit`, including the FZF picker path and
  the Codex output layout.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-06-23, during planning research): the master plan's note that
  rei-`core`'s `agentDirsForSession` is called "in ~6 places (`kitDirs <-
  agentDirsForSession`)" is slightly off. The function is **defined** in rei-core
  (`rei-core/src/Rei/Modules/Agent/Infrastructure/InteractiveSession.hs:106`) and
  **re-exported** from `rei-core/src/Rei/Modules/Agent.hs`, but the **call sites are in
  rei-cli**, in `rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs`, at **eight** lines: 302,
  328, 367, 409, 504, 595, 1132 (and the import at line 76). This is good news: the consumer
  is rei-cli, which already gains a `baikai-kit` dependency for the Kit adapter, so there is
  **no dependency-direction problem** — see the Decision Log.

- Discovery (2026-06-23): `baikai` is wired into `rei` purely through `cabal.project`'s
  `source-repository-package` stanza (subdir list `baikai baikai-claude baikai-openai` at
  tag `2d5bf2c0bfa43b57f0100d6467dfcb7e4c30a915`). There is **no** `baikai-src` flake input
  and **no** entry for baikai in `nix/haskell-overlay.nix`. Consequently, adding `baikai-kit`
  needs only a one-word addition to that subdir list plus a `.cabal` build-depends line; the
  `flake.nix` and the Nix overlay need **no** change. (Contrast the master plan's generic
  "flake + cabal.project + .cabal" recipe, which assumes a flake input per source.)

- Discovery (2026-06-23): rei's FZF picker is **not** a standalone "kit picker" — it is
  inline in `rei-cli/src/Rei/Cli/Commands/Kit/Handler.hs` (`pickItemName`), built on the
  general-purpose `Rei.Cli.Fzf` module. The picker logic (building `Candidate` values from
  skills+agents, the `[skill]`/`[agent]` type tags, the prompt/header/height options) must
  be carried into the new adapter verbatim; only the surrounding install plumbing changes.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `Rei.Cli.Commands.Kit.Parser` (rei's own optparse) rather than adopting the
  package's `kitCommandParser`.
  Rationale: rei's install parser has an **optional** `NAME` argument
  (`itemName :: Maybe Text`) that triggers the FZF picker when omitted, and a `--project`
  switch; the package's `KitInstall !Text !KitScope` requires a `Text` name. rei's shape
  differs, so its parser stays; only `Types`/`Handler`/`Paths` logic is deleted.
  Date: 2026-06-23

- Decision: Put `reiKitConfig` in a new tiny module `Rei.Cli.Commands.Kit.Config` inside
  rei-cli, and have rei-cli's Agent Handler import it for the session-discovery call.
  Rationale: Both consumers of `reiKitConfig` — the Kit adapter and the Agent Handler's
  `agentDirsForSession` calls — live in **rei-cli**. The discovery call sites are in
  `rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs`, not rei-core. So `reiKitConfig` needs to
  be visible only within rei-cli; it does not need to be shared across the package boundary.
  rei-core's local `agentDirsForSession` (and its re-export from `Rei.Modules.Agent`) is
  deleted outright.
  Date: 2026-06-23

- Decision: rei-core does **not** gain a `baikai-kit` dependency.
  Rationale: Because the discovery call sites are in rei-cli (see above), the package's
  `Baikai.Kit.Session.agentDirsForSession reiKitConfig` is invoked from rei-cli. rei-core
  only **defined** the helper; once that definition and its re-export are removed, rei-core
  has no remaining use for kit code. This avoids the dependency-direction concern the master
  plan flagged (a core library depending on a CLI-oriented package): it never arises.
  Date: 2026-06-23

- Decision: Preserve rei's FZF picker by intercepting only the no-NAME install case in the
  adapter and delegating everything else to `runKit reiKitConfig`.
  Rationale: This is the central design point of the whole initiative for rei — the package
  exposes both `runKit` and the engine functions (`ensureKitRepo`, `loadManifest`,
  `installItem`) precisely so a tool can keep its UI. (Mirrors the master plan's Decision Log
  entry on keeping tool-specific UI in the tool.)
  Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This plan is child plan EP-3 of the MasterPlan at
`docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md`. It has a **hard**
dependency on EP-1 (`docs/plans/26-build-the-baikai-kit-package.md`, the `baikai-kit`
package) — rei's new adapter will not compile until that package exists and exports the
agreed API. It has a **soft** dependency on EP-2
(`docs/plans/27-migrate-mori-onto-baikai-kit.md`): prefer to let `mori` shake out the
package API first, but this is a sequencing preference, not a compile requirement. If the
package is confirmed complete, this plan may proceed in parallel with EP-2.

The `rei` repository (registry path `/Users/shinzui/Keikaku/bokuno/rei-project/rei`) is a
multi-package cabal project. `cabal.project` lists two local packages, `rei-core` and
`rei-cli`, built with `ghc-9.12.4`. The kit feature lives entirely in **rei-cli** except for
one discovery helper currently in **rei-core**.

The kit code in rei-cli, under
`rei-cli/src/Rei/Cli/Commands/Kit/`:

- `Types.hs` (~146 lines). Defines the command ADT `KitCommand` (`KitList`,
  `KitInstall !KitInstallOpts`, `KitUpdate !KitUpdateOpts`, `KitUninstall !KitUninstallOpts`,
  `KitStatus`) and the option records `KitInstallOpts { itemName :: !(Maybe Text),
  projectScope :: !Bool }`, `KitUpdateOpts { itemName :: !(Maybe Text) }`,
  `KitUninstallOpts { itemName :: !Text, projectScope :: !Bool }`. The optional `itemName`
  on install is what triggers the FZF picker. It also defines the manifest types
  `KitManifest { version :: !Int, skills :: ![SkillEntry], agents :: ![AgentEntry] }`,
  `SkillEntry { name :: !Text, description :: !Text, path :: !Text, files :: ![Text] }`,
  `AgentEntry { name :: !Text, description :: !Text, path :: !Text, files :: !(Maybe [Text]) }`
  (note rei's `AgentEntry.files` is `Maybe [Text]`), `KitItem = KitSkillItem !SkillEntry |
  KitAgentItem !AgentEntry`, `KitScope = UserScope | ProjectScope`, plus a battery of
  hand-written field accessors (`skillName`, `skillDesc`, `skillPathOf`, `skillFilesOf`,
  `agentNameOf`, `agentDescOf`, `agentPathOf`, `agentFilesOf`, `skillNameDesc`,
  `agentNameDesc`) added to work around `DuplicateRecordFields` ambiguity, and `scopeFromBool
  :: Bool -> KitScope`, `scopeLabel :: KitScope -> Text`.

- `Parser.hs` (~46 lines). `kitCommandParser :: Parser KitCommand`, an `hsubparser` over
  `list`/`install`/`update`/`uninstall`/`status` falling back to `KitList`. The `install`
  subparser uses `optional (strArgument (metavar "NAME" ...))` (so NAME may be omitted to
  pick interactively via fzf) and `switch (long "project" ...)`.

- `Handler.hs` (~440 lines). `handleKitCommand :: FzfConfig -> KitCommand -> IO ()`
  dispatches the five subcommands. It contains: `defaultKitRepoUrl =
  "https://github.com/shinzui/rei-kit.git"`; `listAvailable`; `installItem :: FzfConfig ->
  Maybe Text -> KitScope -> IO ()` (which, when given `Nothing`, calls `pickItemName`);
  `pickItemName :: FzfConfig -> KitManifest -> IO (Maybe Text)` (the **FZF picker**:
  it builds `Candidate Text` values from `skills manifest` and `agents manifest`, tags each
  with `[skill]`/`[agent]`, sets `withPrompt "kit> " <> withHeader "Select a skill or agent
  to install" <> withHeight "50%"`, runs `runFzf`, and maps the `FzfResult`); `doInstall`;
  `agentSourceFile`; `copySkillFile`; `updateKit`; `reinstallIfPresent`;
  `reinstallAllPresent`; `uninstallItem`; `kitStatus` and its scan helpers; the git helpers
  `ensureKitRepo`/`pullKitRepo`; the manifest helpers `loadManifest`/`lookupItem`; and the
  directory helpers `kitCacheDir`/`resolveTargetDir`/`resolveProviderTargetDir`/`isInstalled`.

- `Paths.hs` (~133 lines). Provider-native layout helpers built on `Baikai.AgentAssets`
  (so rei already depends on `baikai`). `KitProviderLayout = ClaudeLayout | CodexLayout`;
  `allKitProviderLayouts = [ClaudeLayout, CodexLayout]`; `skillTargetDir`, `agentTargetFile`
  call `AgentAssets.skillTargetPath`/`agentTargetPath` with `InteractiveProjectScope`;
  `codexAgentToml` calls `AgentAssets.codexCustomAgentToml`; `scanInstalledForProvider` for
  the status scan. This is the same `AgentAssets`-based path computation `baikai-kit` adopts.

- `Kit.hs` (~11 lines). A facade re-exporting `KitCommand`, `kitCommandParser`,
  `handleKitCommand`.

The interactive picker primitives are in `rei-cli/src/Rei/Cli/Fzf.hs` (module
`Rei.Cli.Fzf`), a general-purpose FZF wrapper. The relevant surface the adapter uses:

```haskell
data FzfConfig = FzfConfig { fzfBinary :: !FilePath, fzfAvailable :: !Bool
                           , stdinIsTerminal :: !Bool, stdoutIsTerminal :: !Bool
                           , ttyAvailable :: !Bool }
detectFzfConfig :: IO FzfConfig
isFzfAvailable  :: FzfConfig -> Bool

data Candidate a = Candidate { candidateDisplay :: !Text, candidateValue :: !a }
withPrompt :: Text -> FzfOpts ; withHeader :: Text -> FzfOpts ; withHeight :: Text -> FzfOpts
-- FzfOpts is a Monoid, options are combined with <>

data FzfResult a = FzfSelected !a | FzfNoMatch | FzfCancelled | FzfError !Text
runFzf :: FzfConfig -> FzfOpts -> [Candidate a] -> IO (FzfResult a)
```

CLI wiring lives in `rei-cli/src/Rei/Cli.hs`. The `Kit` constructor is `Kit !KitCommand`
(line 467). The subparser is `(Kit <$> kitCommandParser <**> helper)` (line 902). Dispatch
is `Kit cmd -> handleKitCommand fzfConf cmd` (line 1061), where `fzfConf <- detectFzfConfig`
is established earlier (line 280) and threaded through `handleCommand`. `Rei.Cli` imports
`KitCommand`, `handleKitCommand`, `kitCommandParser` from `Rei.Cli.Commands.Kit` (lines
118-120) and `FzfConfig`, `detectFzfConfig` from `Rei.Cli.Fzf` (line 219).

The discovery helper, `rei-core/src/Rei/Modules/Agent/Infrastructure/InteractiveSession.hs`,
defines:

```haskell
agentDirsForSession :: IO [FilePath]
agentDirsForSession = do
  home <- getHomeDirectory
  cwd <- getCurrentDirectory
  let userAgentDir = home </> ".config" </> "rei" </> "agents"
      projectAgentDir = cwd </> ".rei" </> "agents"
  filterM doesDirectoryExist [userAgentDir, projectAgentDir]
```

It is re-exported from `rei-core/src/Rei/Modules/Agent.hs` and consumed from
**rei-cli** in `rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs` (import at line 76; eight call
sites: 302, 328, 367, 409, 504, 595, 1132, each of the form `kitDirs <- agentDirsForSession`
followed by `addDirs = <root> : kitDirs`).

The real `rei-kit` manifest is at `/Users/shinzui/Keikaku/bokuno/rei-project/rei-kit/kit.json`.
It is a **v1** manifest (`"version": 1`); skills have `path` + `files` (e.g.
`"path": "skills/rei-bootstrap", "files": ["SKILL.md"]`); the single agent uses `"path":
"agents", "files": ["rei-custom-property-guide.md"]` (a directory `path` plus a `files`
list). Crucially, **no entry carries a `version` field**, so the package's
`version :: Maybe Text` on `SkillEntry`/`AgentEntry` is what keeps these parsing, and the
agent's `files` is a `Maybe [Text]` that is present here.

The build files. `cabal.project` pins `baikai`, `baikai-claude`, `baikai-openai` from
`https://github.com/shinzui/baikai` at tag `2d5bf2c0bfa43b57f0100d6467dfcb7e4c30a915`
(subdir list). `rei-cli/rei-cli.cabal` library `build-depends` already lists `baikai`,
`directory ^>=1.3`, `optparse-applicative >=0.19`, `process ^>=1.6`, and exposes the five
`Rei.Cli.Commands.Kit*` modules (lines 137-141). `rei-core/rei-core.cabal` lists `baikai`,
`baikai-claude`, `baikai-openai`. `nix/haskell-overlay.nix` and `flake.nix` contain **no**
baikai entry — baikai flows in via the `cabal.project` source-repository stanza only.


## Plan of Work

The work proceeds in five milestones. Each is independently verifiable.

**M1 — Add `baikai-kit` to rei's build.** Scope: make the new package resolvable from rei
without yet using it. Edit `cabal.project`: in the existing baikai
`source-repository-package` stanza, add `baikai-kit` to the `subdir` list, leaving the
`location` and `tag` exactly as they are (pin the **same** baikai revision rei already
pins, `2d5bf2c0bfa43b57f0100d6467dfcb7e4c30a915`, or, if EP-1 publishes `baikai-kit` only on
a later commit of the baikai repo, bump the single tag to that revision recorded by EP-1 —
verify the tag against EP-1's "published version" note). Edit `rei-cli/rei-cli.cabal`: add
`baikai-kit` to the library `build-depends`. No flake or overlay change is needed (baikai is
not a flake input). At the end of M1, `cabal build all` is green and `baikai-kit`'s modules
are importable, though nothing imports them yet. Acceptance: `cabal build all` succeeds; a
scratch `import Baikai.Kit` in a ghci `:m` (or a throwaway `where` clause) resolves.

**M2 — Replace the kit logic with a thin adapter.** Scope: delete rei's hand-written kit
engine and rewire the handler onto `baikai-kit`, keeping rei's parser and FZF picker. Create
`rei-cli/src/Rei/Cli/Commands/Kit/Config.hs` exporting `reiKitConfig :: KitConfig`. Rewrite
`rei-cli/src/Rei/Cli/Commands/Kit/Handler.hs` to a thin `handleKitCommand :: FzfConfig ->
KitCommand -> IO ()` that: for `KitInstall (KitInstallOpts mName proj)` with `mName = Just
n`, calls `Baikai.Kit.Install.installItem reiKitConfig n (toScope proj)`; for `mName =
Nothing`, runs the FZF picker (carried over from the old `pickItemName`) and, on selection,
calls `installItem reiKitConfig chosenName (toScope proj)`; for every other subcommand
(`KitList`, `KitUpdate`, `KitUninstall`, `KitStatus`), maps `KitCommand` to the package's
`Baikai.Kit.Command.KitCommand` and calls `runKit reiKitConfig`. Keep
`Rei.Cli.Commands.Kit.Parser` unchanged. Reduce `Rei.Cli.Commands.Kit.Types` to only the
command/option ADTs the parser needs (`KitCommand`, `KitInstallOpts`, `KitUpdateOpts`,
`KitUninstallOpts`) — delete the manifest types and all hand-written accessors, importing the
manifest types from `Baikai.Kit.Manifest` where the picker needs them. **Delete**
`rei-cli/src/Rei/Cli/Commands/Kit/Paths.hs` (its `AgentAssets`-based path logic now lives in
the package). Update `Rei.Cli.Commands.Kit` (the facade) and the `.cabal`
`exposed-modules`/`other-modules` list accordingly (drop `Paths`, add `Config`). At the end
of M2, `cabal build all` is green, and the kit feature is fully served by the package + rei's
parser + picker. Acceptance: build green; `rei kit --help` unchanged; the five subcommands
dispatch.

**M3 — Replace the session-discovery helper.** Scope: route interactive-session asset
discovery through the package. Remove `agentDirsForSession` from
`rei-core/src/Rei/Modules/Agent/Infrastructure/InteractiveSession.hs` and from the
`Rei.Modules.Agent` re-export in `rei-core/src/Rei/Modules/Agent.hs`. In
`rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs`, replace the import of `agentDirsForSession`
(line 76, currently via `Rei.Modules.Agent`) with `import Baikai.Kit.Session
(agentDirsForSession)` and `import Rei.Cli.Commands.Kit.Config (reiKitConfig)`, and change
each of the eight call sites from `kitDirs <- agentDirsForSession` to `kitDirs <-
agentDirsForSession reiKitConfig`. Because `Baikai.Kit.Session.agentDirsForSession` derives
`~/.config/rei/agents` and `.rei/agents` from `reiKitConfig`'s `toolName = "rei"` and filters
to existing directories, behavior is identical. rei-core does **not** gain a `baikai-kit`
dependency. Acceptance: `cabal build all` green; the eight call sites compile against the new
signature.

**M4 — Port/trim tests.** Scope: keep test coverage meaningful after the path logic moved to
the package. The existing
`rei-cli/test/Rei/Cli/Commands/Kit/PathsSpec.hs` tests `Rei.Cli.Commands.Kit.Paths`, which
this plan deletes. Remove that spec module and its references in the rei-cli test suite
(`rei-cli/test/Main.hs` and the `other-modules` list in `rei-cli/rei-cli.cabal`'s test
stanza). The provider-layout coverage it provided now lives in `baikai-kit`'s own test suite
(EP-1). Optionally add a small adapter test asserting `reiKitConfig` has `toolName = "rei"`,
`repoUrl = "https://github.com/shinzui/rei-kit.git"`, and both providers. Acceptance: `cabal
test all` green.

**M5 — Manual verification.** Scope: prove parity against the real `rei-kit`, including the
FZF path and Codex output. Run the manual transcript in Concrete Steps. Acceptance: all five
subcommands behave as before; FZF picker works; both Claude and Codex layouts are produced.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/rei-project/rei` unless stated.

M1 — add the dependency and confirm it resolves:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
# Edit cabal.project: add `baikai-kit` to the baikai source-repository subdir list.
# Edit rei-cli/rei-cli.cabal: add `baikai-kit,` to the library build-depends.
cabal build all
```

The `cabal.project` edit (the baikai stanza, near line 190) is:

```diff
 source-repository-package
   type: git
   location: https://github.com/shinzui/baikai
   tag: 2d5bf2c0bfa43b57f0100d6467dfcb7e4c30a915
   subdir:
     baikai
     baikai-claude
     baikai-openai
+    baikai-kit
```

(If EP-1 records that `baikai-kit` first appears at a later baikai commit, bump the single
`tag:` line to that revision — it governs all four subdirs.)

The `rei-cli/rei-cli.cabal` library `build-depends` edit:

```diff
   build-depends:
     ...
     baikai,
+    baikai-kit,
     ...
```

Expected: `cabal build all` ends with `Linking ...` / no errors. (First run rebuilds the
baikai source tree, so it is slow; this is normal.)

M2 — after the adapter rewrite, rebuild:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build all
rei kit --help
```

Expected `rei kit --help` (unchanged from today):

```text
Usage: rei kit COMMAND
  Manage Claude Code and Codex skills and subagents

Available commands:
  list        List available skills and subagents
  install     Install a skill or subagent
  update      Update installed skills and subagents
  uninstall   Uninstall a skill or subagent
  status      Show installed skills and subagents
```

M3/M4 — rebuild and test:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal build all
cabal test all
```

Expected: all suites report `All N tests passed` / `OK`.

M5 — manual verification against the real `rei-kit`. Use a throwaway project directory for
install/uninstall so you never pollute `~/.config/rei`:

```bash
cd /Users/shinzui/Keikaku/bokuno/rei-project/rei
cabal install exe:rei --installdir="$PWD/.dev/bin" --overwrite-policy=always
export PATH="$PWD/.dev/bin:$PATH"

# 1) list — clones rei-kit on first run, lists skills then agents
rei kit list
```

Expected shape:

```text
Fetching rei-kit...
Skills:
  rei-bootstrap          Interactively bootstrap intentions, habits, and reflections ...
  rei-bootstrap-habit    Interactively bootstrap a new habit for Rei personal coaching
  ...
Agents:
  rei-custom-property-guide   Guide users through creating and managing custom properties ...
```

```bash
# 2) install with NO name → the FZF picker appears
mkdir -p /tmp/rei-kit-smoke && cd /tmp/rei-kit-smoke
rei kit install --project
# (fzf opens: prompt "kit> ", header "Select a skill or agent to install",
#  rows like "rei-bootstrap   [skill]   Interactively bootstrap ...". Pick one, press Enter.)
```

Expected after selecting, e.g., `rei-bootstrap`:

```text
Installed skill 'rei-bootstrap' for Claude Code and Codex (project scope).
```

```bash
# 3) install a named skill into project scope; verify BOTH provider layouts on disk
rei kit install rei-bootstrap --project
ls .rei/agents/.claude/skills/rei-bootstrap/      # Claude skill dir
ls .agents/skills/rei-bootstrap/                  # Codex skill dir
# install the agent and verify Codex toml + Claude md
rei kit install rei-custom-property-guide --project
ls .rei/agents/.claude/agents/rei-custom-property-guide.md   # Claude agent (md)
ls .codex/agents/rei-custom-property-guide.toml              # Codex agent (toml)
```

Expected: each `ls` lists the file/dir, confirming byte-identical layouts to pre-migration
(`.claude/skills/<n>/` and `.agents/skills/<n>/` for skills; `.claude/agents/<n>.md` and
`.codex/agents/<n>.toml` for agents).

```bash
# 4) status, then uninstall, then status again
rei kit status
rei kit uninstall rei-bootstrap --project
rei kit uninstall rei-custom-property-guide --project
rei kit status
```

Expected: `status` prints a `NAME / TYPE / SCOPE / PROVIDERS` table while items are installed
and `No kit items installed.` after both uninstalls; each `uninstall` prints `Uninstalled
'<n>' from project scope (...)`.

```bash
# 5) update is a no-op-safe pull
rei kit update
```

Expected: `Kit repository updated.` (or `Kit repository cloned.` on a fresh cache), followed
by an `Updated N item(s).` line.


## Validation and Acceptance

The migration is accepted when all of the following hold:

- **Build and tests green.** From `/Users/shinzui/Keikaku/bokuno/rei-project/rei`, `cabal
  build all` and `cabal test all` both succeed.

- **Install paths are byte-identical for both providers.** For a skill `s`, project scope
  produces `.rei/agents/.claude/skills/s/` (Claude) and `.agents/skills/s/` (Codex); user
  scope produces `~/.config/rei/agents/.claude/skills/s/` and `~/.agents/skills/s/`. For an
  agent `a`, `.rei/agents/.claude/agents/a.md` (Claude) and `.codex/agents/a.toml` (Codex)
  in project scope; the Codex agent file content is the `developer_instructions` TOML
  rendering (verify `name = "a"`, `description = "..."`, `developer_instructions = """..."""`
  appear). These match the pre-migration layout produced by the deleted `Kit.Paths`, which
  used the same `Baikai.AgentAssets` calls, so no installed asset moves.

- **The FZF picker still works.** `rei kit install` with no NAME opens fzf (prompt `kit> `,
  header `Select a skill or agent to install`, height `50%`), shows every skill and agent
  with a `[skill]`/`[agent]` tag and description, and installs the selected item. Cancelling
  (Esc) installs nothing and exits cleanly. When fzf is unavailable, the adapter prints the
  same guidance as before (`Error: no NAME given and fzf is not available. Please run 'rei
  kit install <name>'.`).

- **The real `rei-kit` manifest parses.** `rei kit list` against
  `https://github.com/shinzui/rei-kit.git` lists the nine skills and one agent from the v1
  manifest (`/Users/shinzui/Keikaku/bokuno/rei-project/rei-kit/kit.json`). This exercises the
  package's `version :: Maybe Text` (absent on every entry) and `AgentEntry.files :: Maybe
  [Text]` (present as `["rei-custom-property-guide.md"]` under `path: "agents"`).

- **Interactive sessions still discover assets.** After installing a skill into project scope
  in a directory, starting a `rei` interactive coaching session in that directory passes
  `.rei/agents` (and `~/.config/rei/agents` when present) via `--add-dir`, exactly as before
  — verified because the eight Agent-Handler call sites now use `agentDirsForSession
  reiKitConfig`, which resolves the same two directories.

This is more than compilation: the manual transcript in Concrete Steps exercises a real git
clone, manifest parse, both provider layouts on disk, the FZF picker, status, uninstall, and
update.


## Idempotence and Recovery

- **M1 is safe to repeat.** Adding `baikai-kit` to the subdir list and the `.cabal`
  build-depends is idempotent; re-running `cabal build all` only rebuilds what changed.

- **Deleted modules live in git history.** `Rei.Cli.Commands.Kit.{Types (full),Handler
  (old),Paths}` and rei-core's `agentDirsForSession` are recoverable via `git show
  HEAD:rei-cli/src/Rei/Cli/Commands/Kit/Paths.hs` etc. If the package API turns out to be
  incomplete (a soft-dependency surprise from EP-2 not having shaken it out), revert the M2
  commit, restore the old modules, and report the gap to EP-1 before retrying.

- **Dispatch wiring is reversible.** The single `Kit cmd -> handleKitCommand fzfConf cmd`
  line in `Rei.Cli.hs` is unchanged by this plan (the adapter keeps the same
  `handleKitCommand :: FzfConfig -> KitCommand -> IO ()` signature), so no root-CLI revert is
  needed; reverting the Kit module commit fully restores prior behavior.

- **Manual install tests use throwaway dirs.** Always run the manual `rei kit install` tests
  with `--project` inside a scratch directory (e.g. `/tmp/rei-kit-smoke`) so user-scope state
  under `~/.config/rei/agents` is never written. To clean up, `rm -rf /tmp/rei-kit-smoke`.
  The kit cache (`~/.cache/rei/kit`) may be safely removed at any time; the next command
  re-clones.


## Interfaces and Dependencies

rei consumes the `baikai-kit` public API built by EP-1
(`docs/plans/26-build-the-baikai-kit-package.md`). The contract, embedded verbatim per the
self-containment rule, is:

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

Record fields carry NO Hungarian prefixes; access via generic-lens labels (`entry ^.
#name`). Disambiguation between rei's own `KitCommand`/`KitScope` and the package's is by
qualified import: import the package as `import Baikai.Kit qualified as Kit` (or import
`Baikai.Kit.Install` / `Baikai.Kit.Command` qualified) so `Kit.KitScope`, `Kit.installItem`,
`Kit.runKit` are unambiguous against rei's local `KitCommand`/`KitInstallOpts`.

The `KitConfig` rei must define (new module `Rei.Cli.Commands.Kit.Config`):

```haskell
reiKitConfig :: KitConfig
reiKitConfig = KitConfig
  { toolName  = "rei"
  , repoUrl   = "https://github.com/shinzui/rei-kit.git"   -- verified against the old Handler.hs `defaultKitRepoUrl`
  , providers = [InteractiveClaude, InteractiveCodex]       -- rei supports both today; preserved
  }
```

The `repoUrl` is verified: rei's deleted `Handler.hs` had `defaultKitRepoUrl =
"https://github.com/shinzui/rei-kit.git"`. The `providers` list preserves rei's
`allKitProviderLayouts = [ClaudeLayout, CodexLayout]`.

The central design point — preserving the FZF picker — is realized in the new
`Rei.Cli.Commands.Kit.Handler`. Sketch (qualified-import style; the picker body is carried
over from the old `pickItemName`):

```haskell
import Baikai.Kit.Config (KitConfig)
import Baikai.Kit.Manifest (KitManifest, SkillEntry, AgentEntry)
import Baikai.Kit.Repo (ensureKitRepo)
import Baikai.Kit.Install (loadManifest, installItem)
import Baikai.Kit.Command qualified as KitCmd
import Control.Lens ((^.))             -- generic-lens labels
import Rei.Cli.Commands.Kit.Config (reiKitConfig)
import Rei.Cli.Commands.Kit.Types     -- rei's own KitCommand/KitInstallOpts/...
import Rei.Cli.Fzf

handleKitCommand :: FzfConfig -> KitCommand -> IO ()
handleKitCommand fzfConf = \case
  KitInstall (KitInstallOpts mName proj) -> doInstall fzfConf mName (toScope proj)
  KitList                                -> KitCmd.runKit reiKitConfig KitCmd.KitList
  KitUpdate  (KitUpdateOpts mName)       -> KitCmd.runKit reiKitConfig (KitCmd.KitUpdate mName)
  KitUninstall (KitUninstallOpts n proj) -> KitCmd.runKit reiKitConfig (KitCmd.KitUninstall n (toScope proj))
  KitStatus                              -> KitCmd.runKit reiKitConfig KitCmd.KitStatus

toScope :: Bool -> KitCmd.KitScope
toScope True  = KitCmd.ProjectScope
toScope False = KitCmd.UserScope

doInstall :: FzfConfig -> Maybe Text -> KitCmd.KitScope -> IO ()
doInstall fzfConf mName scope = do
  repoDir  <- ensureKitRepo reiKitConfig                 -- engine: clone/pull
  manifest <- loadManifest repoDir                       -- engine: parse kit.json
  mChosen  <- case mName of
                Just n  -> pure (Just n)
                Nothing -> pickItemName fzfConf manifest  -- KEEP rei's FZF picker
  case mChosen of
    Nothing   -> pure ()
    Just name -> installItem reiKitConfig name scope      -- engine: install both providers

-- pickItemName is the old Rei.Cli.Commands.Kit.Handler.pickItemName, carried over verbatim
-- except it reads names/descriptions from the package's SkillEntry/AgentEntry via labels:
--   skillCands = [ Candidate (display (s ^. #name) "skill" (s ^. #description)) (s ^. #name)
--               | s <- manifest ^. #skills ]
--   agentCands = [ Candidate (display (a ^. #name) "agent" (a ^. #description)) (a ^. #name)
--               | a <- manifest ^. #agents ]
-- and runs `runFzf fzfConf (withPrompt "kit> " <> withHeader "Select a skill or agent to
-- install" <> withHeight "50%") (skillCands ++ agentCands)`, mapping FzfResult as before.
```

This is the crux: the package's `runKit` serves list/update/uninstall/status with one line
each, while `installItem` is called directly so rei's `doInstall` can interpose the FZF
picker for the no-NAME case. No terminal-UI code enters the package.

Build inputs and module changes:

- `cabal.project`: `baikai-kit` added to the baikai source-repository `subdir` list (same
  `location`/`tag`). No flake/overlay change (baikai is not a flake input).
- `rei-cli/rei-cli.cabal`: library `build-depends` gains `baikai-kit`. `exposed-modules`/
  `other-modules`: drop `Rei.Cli.Commands.Kit.Paths`, add `Rei.Cli.Commands.Kit.Config`;
  keep `Kit`, `Kit.Handler`, `Kit.Parser`, `Kit.Types` (trimmed). Test stanza drops
  `Rei.Cli.Commands.Kit.PathsSpec` from `other-modules`.
- `rei-core/rei-core.cabal`: **no change** — rei-core does not depend on `baikai-kit`.
- `rei-core/src/Rei/Modules/Agent/Infrastructure/InteractiveSession.hs`: delete
  `agentDirsForSession` and drop it from the module export list.
- `rei-core/src/Rei/Modules/Agent.hs`: drop `agentDirsForSession` from the re-export.
- `rei-cli/src/Rei/Cli/Commands/Agent/Handler.hs`: import `agentDirsForSession` from
  `Baikai.Kit.Session` and `reiKitConfig` from `Rei.Cli.Commands.Kit.Config`; change the
  eight call sites (lines 302, 328, 367, 409, 504, 595, 1132 — and the import at 76) from
  `agentDirsForSession` to `agentDirsForSession reiKitConfig`.

Required end-state signatures:

- After M2: `Rei.Cli.Commands.Kit.Config.reiKitConfig :: Baikai.Kit.Config.KitConfig`;
  `Rei.Cli.Commands.Kit.Handler.handleKitCommand :: FzfConfig -> KitCommand -> IO ()`
  (unchanged signature, so `Rei.Cli`'s dispatch line is untouched);
  `Rei.Cli.Commands.Kit.Parser.kitCommandParser :: Parser KitCommand` (unchanged).
- After M3: every `kitDirs <- agentDirsForSession reiKitConfig` in the Agent Handler resolves
  to `Baikai.Kit.Session.agentDirsForSession :: KitConfig -> IO [FilePath]`; rei-core no
  longer exports `agentDirsForSession`.
