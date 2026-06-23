---
id: 27
slug: migrate-mori-onto-baikai-kit
title: "Migrate mori onto baikai-kit"
kind: exec-plan
created_at: 2026-06-23T22:59:48Z
intention: "intention_01kvvb9hgbed48wzdkamgedm24"
master_plan: "docs/masterplans/5-shared-baikai-kit-package-for-cli-skill-agent-kits.md"
---

# Migrate mori onto baikai-kit

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A `mori` user must see no change. The five subcommands `mori kit list`, `mori kit install`,
`mori kit update`, `mori kit uninstall`, and `mori kit status` keep their exact behavior, their
exact output shape, and their exact on-disk install paths. The interactive sessions that mori
launches (`mori agent ask`, the various bootstrap flows, the plain interactive session) keep
discovering installed skills and subagents through `claude --add-dir`, exactly as before.

What changes is internal. mori currently carries a ~806-line hand-written module,
`mori-cli/src/Mori/Command/Kit.hs`, plus a ~380-line test, `mori-cli/test/Mori/Command/KitSpec.hs`.
Both are deleted and replaced by a dependency on the shared `baikai-kit` package (built by
`docs/plans/26-build-the-baikai-kit-package.md`). mori is migrated first because `baikai-kit` was
derived from mori's implementation, so this migration is the truest validation of the package's
public API: if mori behaves identically against the package, the API is faithful.

This plan has a HARD dependency on `docs/plans/26-build-the-baikai-kit-package.md` being complete
and the `baikai-kit` package version published. EP-26's milestone M8 records the exact published
version in its Decision Log and in the MasterPlan; read that before pinning. Until you know the
exact version, use the constraint `baikai-kit ^>=0.1.0` (EP-26 scaffolds the package at
`version: 0.1.0.0`).

You can see the migration working when, after deleting `Mori.Command.Kit`, `mori kit list` still
prints the four skills from the real `mori-kit` manifest, `mori kit install mori-config --project`
writes a directory at `.mori/agents/.claude/skills/mori-config/` byte-for-byte identical to the
pre-migration layout, and an interactive `mori agent ask` session still passes that directory to
`claude --add-dir`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Add `baikai` and `baikai-kit` to mori's build (flake input + `nix/haskell-overlay.nix`
  + `cabal.project` source-repository-package + `mori-cli.cabal` `build-depends`). `cabal build
  mori-cli` succeeds with the new dependency resolvable.
- [ ] M2: Replace `Mori.Command.Kit` with a thin adapter that defines `moriKitConfig` and
  re-exposes `kitCommandParser` plus a `runKit`-calling wrapper; delete the old logic; update the
  `Mori.Cli` dispatch site.
- [ ] M3: Replace the interactive-session `agentDirsForSession` body with
  `Baikai.Kit.Session.agentDirsForSession moriKitConfig`; reconcile the one non-cwd caller
  (`agentDirsForRoot projectRootFp` at `Agent.hs:2572`).
- [ ] M4: Port/trim `Mori.Command.KitSpec` (the pure logic now lives in `baikai-kit`); keep only
  mori-specific wiring tests; run mori's test suite green.
- [ ] M5: Manual verification against the real `mori-kit` repo (all five subcommands, path
  equivalence, interactive discovery).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- mori does NOT currently depend on `baikai`. A grep for `baikai` across
  `mori-cli/mori-cli.cabal`, `cabal.project`, and `flake.nix` returns nothing. `Mori.Command.Kit`
  hardcodes `.claude/skills` and `.claude/agents` directly (see `doInstall`,
  `Kit.hs:260`/`Kit.hs:268`) and never imports `Baikai.AgentAssets`. So mori is Claude-only today,
  and this migration ADDS the `baikai`/`baikai-kit` source to mori's flake and `cabal.project` for
  the first time. After migration mori could gain Codex support for free, but this plan keeps
  `providers = [InteractiveClaude]` to preserve exact behavior.

- The interactive-session helper has TWO entry points. `agentDirsForSession`
  (`Agent.hs:1451`) is cwd-based and used by 14 call sites. But `agentDirsForRoot`
  (`Agent.hs:1442`) takes an explicit `projectRoot` argument and is called once at `Agent.hs:2572`
  with a REGISTERED PROJECT's root (`projectRootFp`), which is generally NOT the cwd. `baikai-kit`'s
  `agentDirsForSession :: KitConfig -> IO [FilePath]` is hardcoded to cwd, so it can replace the 14
  cwd call sites but cannot replace the one non-cwd call. The plan keeps a thin local
  `agentDirsForRoot` for that single case (see M3).

- mori's `agentDirsForRoot` returns only directories that EXIST (`filterM doesDirectoryExist`),
  whereas the baikai-kit session helper's filtering semantics must be confirmed against EP-26's
  `Baikai.Kit.Session` before swapping, so an interactive launch never passes a nonexistent
  `--add-dir`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep `providers = [InteractiveClaude]` for `moriKitConfig`.
  Rationale: mori is Claude-only today (hardcoded `.claude/...` paths, no `Baikai.AgentAssets`
  usage). Restricting to `InteractiveClaude` makes the new code route through exactly the same
  `.claude/skills/<name>` and `.claude/agents/<name>.md` paths, guaranteeing already-installed
  assets are not orphaned. Adding `InteractiveCodex` is an optional follow-up once verified.
  Date: 2026-06-23

- Decision: Retain a local `agentDirsForRoot` in `Mori.Command.Agent` for the non-cwd caller.
  Rationale: `baikai-kit`'s `agentDirsForSession` resolves project scope from cwd; mori's `ask`
  flow (`Agent.hs:2572`) resolves from a registered project root that differs from cwd. A blanket
  swap would change behavior. Date: 2026-06-23


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This task lives in the **mori** repository, whose registry path is
`/Users/shinzui/Keikaku/bokuno/mori-project/mori`. All paths in the Concrete Steps are relative to
that directory unless stated otherwise.

The kit feature today is implemented entirely in
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/src/Mori/Command/Kit.hs`. That module
defines the `KitCommand` ADT, the optparse-applicative parser `kitCommandParser`, the dispatcher
`runKit`, the manifest types (`KitManifest`, `SkillEntry`, `AgentEntry`, `KitItem`), the sidecar
machinery (`SidecarMeta`, `computeKitHash`, `sidecarPath`, `readSidecar`, `writeSidecar`), the
status machinery (`KitState`, `StatusRow`, `classify`, `collectStatus`, `renderState`), the git
clone/pull (`ensureKitRepo`, `pullKitRepo`), and the directory resolution. Crucially, the install
paths are hardcoded. `resolveTargetDir UserScope` is `$HOME/.config/mori/agents` and
`resolveTargetDir ProjectScope` is `<cwd>/.mori/agents`; under each, skills go to
`.claude/skills/<name>` and agents go to `.claude/agents/<name>.md`. The kit cache is
`$HOME/.cache/mori/kit`, cloned from `defaultKitRepoUrl = "https://github.com/shinzui/mori-kit.git"`.

The CLI wiring is in `/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/src/Mori/Cli.hs`.
The relevant lines are:

```haskell
-- line 32
import Mori.Command.Kit (KitCommand, kitCommandParser, runKit)

-- line 90 (a constructor of the top-level Command ADT)
  | Kit !KitCommand

-- line 124 (the dispatch case)
    Kit kitCmd -> runKit kitCmd

-- line 280 (the subparser registration)
        <> command "kit" (info (Kit <$> kitCommandParser) (progDesc "Manage Claude Code skills and subagents"))
```

The interactive-session integration is in
`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/src/Mori/Command/Agent.hs`. The relevant
definitions are at lines 1442-1461:

```haskell
agentDirsForRoot :: FilePath -> IO [FilePath]
agentDirsForRoot projectRoot = do
  home <- getHomeDirectory
  let userAgentDir = home </> ".config" </> "mori" </> "agents"
      projectAgentDir = projectRoot </> ".mori" </> "agents"
  filterM doesDirectoryExist [userAgentDir, projectAgentDir]

agentDirsForSession :: IO [FilePath]
agentDirsForSession = getCurrentDirectory >>= agentDirsForRoot

buildClaudeArgs :: [FilePath] -> [String] -> String -> [String]
buildClaudeArgs addDirs allowedTools promptStr =
  ["--permission-mode", "acceptEdits"]
    ++ concatMap (\d -> ["--add-dir", d]) addDirs
    ++ "--allowedTools"
    : allowedTools
    ++ ["--append-system-prompt", promptStr]
```

`agentDirsForSession` is called 14 times (e.g. `Agent.hs:848, 931, 980, 1019, ...`).
`agentDirsForRoot` is called once with a non-cwd root at `Agent.hs:2572`
(`agentDirs <- agentDirsForRoot projectRootFp`), inside the `mori agent ask` flow that targets a
registered project root.

The real manifest at `/Users/shinzui/Keikaku/bokuno/mori-project/mori-kit/kit.json` is
`version: 2`, with four skills (`automation-config`, `mori-config`, `cookbook-config`,
`mori-bootstrap-corpus`, all `version: "0.1.0"`, each with `files: ["SKILL.md"]`) and an empty
`agents` array. The post-migration code must still load this manifest and list these four skills.

The shared package being consumed, `baikai-kit`, is built in this repo
(`/Users/shinzui/Keikaku/bokuno/baikai`, git remote `https://github.com/shinzui/baikai.git`) by
`docs/plans/26-build-the-baikai-kit-package.md`. It depends on the `baikai` library package
(`/Users/shinzui/Keikaku/bokuno/baikai/baikai`, currently `version: 0.2.0.0`), whose
`Baikai.AgentAssets` module owns the provider/scope path layout. The non-obvious term to define:
a **sidecar** is a small JSON file the installer writes next to each installed asset recording its
name, kind, declared version, a content hash, and an install timestamp; `mori kit status` reads
sidecars to decide up-to-date / outdated / dirty / unknown.

The single most important equivalence to verify is that routing mori's installs through
`Baikai.AgentAssets` with `InteractiveClaude` + `InteractiveProjectScope` (and the user-scope
variant) reproduces mori's hardcoded paths. The evidence is in
`/Users/shinzui/Keikaku/bokuno/baikai/baikai/src/Baikai/AgentAssets.hs`:

```haskell
skillTargetPath InteractiveClaude InteractiveProjectScope name =
  joinPath [".claude", "skills", name]
agentTargetPath InteractiveClaude InteractiveProjectScope name =
  joinPath [".claude", "agents", name <> ".md"]
```

These are joined under the resolved agents base (mori's `.mori/agents` for project scope,
`$HOME/.config/mori/agents` for user scope), yielding `.claude/skills/<name>` and
`.claude/agents/<name>.md` — byte-identical to mori's `doInstall` targets in
`Kit.hs:260`/`Kit.hs:268`. The Codex branch (`InteractiveCodex`) would instead produce
`.agents/skills/<name>` and `.codex/agents/<name>.toml`, which is why mori stays on
`[InteractiveClaude]`.


## Plan of Work

The work is five independently verifiable milestones. Build the dependency wiring first so the
package is resolvable, then swap the command module, then the session helper, then the tests, then
verify by hand.


### M1 — Add baikai and baikai-kit to mori's build

After this milestone, mori's `cabal.project` and flake know about `baikai` and `baikai-kit`, and
`cabal build mori-cli` resolves the new dependency. mori uses GitHub `source-repository-package`
pins in `cabal.project` mirrored by `flake = false` inputs in `flake.nix` that are threaded through
`nix/haskell-overlay.nix` via `callCabal2nix`. The `okf-core` integration is the closest template:
a single-package import from a subdirectory of a monorepo.

In `cabal.project`, add a `source-repository-package` stanza pointing at the `baikai` repo and
listing both subdirectories that mori needs (`baikai` and `baikai-kit`). Pin the `tag` to the
commit at which EP-26 published the recorded `baikai-kit` version:

```text
-- baikai-kit (shinzui — shared CLI skill/subagent kit mechanism). MasterPlan #5 EP-2.
-- The tag MUST equal flake.nix's baikai-src input rev (integration contract).
-- baikai-kit derives from mori's former Mori.Command.Kit; mori is migrated first.
source-repository-package
  type: git
  location: https://github.com/shinzui/baikai
  tag: <PIN-TO-EP-26-PUBLISH-COMMIT>
  subdir: baikai baikai-kit
```

In `flake.nix`, add a `flake = false` input mirroring that tag, next to the existing `okf-core-src`
input:

```text
    # baikai + baikai-kit (shinzui). MasterPlan #5 EP-2. The SHA MUST equal
    # cabal.project's baikai source-repository-package tag.
    baikai-src = { url = "github:shinzui/baikai/<PIN-TO-EP-26-PUBLISH-COMMIT>"; flake = false; };
```

In `flake.module.nix` (line 21), thread the new input into the overlay alongside `okf-core-src`:

```text
            inherit (inputs) keiro-src keiki-src kiroku-src shibuya-src shibuya-pgmq-adapter-src codd-src hasql-notifications-src okf-core-src baikai-src;
```

In `nix/haskell-overlay.nix`, add `baikai-src` to the argument list (next to the `, okf-core-src`
entry around line 16) and define both packages from the subdirectories, mirroring the `okf-core`
block at lines 212-214:

```text
  baikai = dontCheck (doJailbreak (final.callCabal2nix "baikai"
    "${baikai-src}/baikai"
    { }));
  baikai-kit = dontCheck (doJailbreak (final.callCabal2nix "baikai-kit"
    "${baikai-src}/baikai-kit"
    { }));
```

In `mori-cli/mori-cli.cabal`, add `baikai-kit` (and, if any module references `baikai` types
directly, `baikai`) to the `library` stanza's `build-depends` (after the existing alphabetical
neighbors, e.g. before `base64-bytestring`):

```text
    baikai-kit ^>=0.1.0,
```

Acceptance: from `/Users/shinzui/Keikaku/bokuno/mori-project/mori`, `cabal build mori-cli`
configures and resolves with `baikai-kit` present (it will still compile the old `Mori.Command.Kit`
at this point — M1 only proves the dependency is available).


### M2 — Replace Mori.Command.Kit with a thin adapter

After this milestone, `Mori.Command.Kit` is a small module that defines `moriKitConfig :: KitConfig`
and re-exports `kitCommandParser` from `baikai-kit`, plus a `runKit` wrapper that closes over
`moriKitConfig`. All of the ~806 lines of hand-written logic are deleted. `Mori.Cli` is unchanged at
its three import-site lines except that `runKit` now means the adapter's wrapper.

Rewrite `mori-cli/src/Mori/Command/Kit.hs` to:

```haskell
module Mori.Command.Kit
  ( KitCommand,
    kitCommandParser,
    runKit,
    moriKitConfig,
  )
where

import Baikai.Interactive (InteractiveProvider (InteractiveClaude))
import Baikai.Kit.Command (KitCommand, kitCommandParser)
import Baikai.Kit.Command qualified as Kit
import Baikai.Kit.Config (KitConfig (..))

moriKitConfig :: KitConfig
moriKitConfig =
  KitConfig
    { toolName = "mori",
      repoUrl = "https://github.com/shinzui/mori-kit.git",
      providers = [InteractiveClaude]
    }

runKit :: KitCommand -> IO ()
runKit = Kit.runKit moriKitConfig
```

Note the `repoUrl` exactly matches the old `defaultKitRepoUrl` in `Kit.hs:152`. Note record fields
carry NO Hungarian prefix; `KitConfig`'s fields are `toolName`, `repoUrl`, `providers`. The
`Mori.Cli` import on line 32 already imports `KitCommand, kitCommandParser, runKit`, all still
exported, so `Mori.Cli` needs no edit (verify the import compiles). The `command "kit"` registration
(line 280) and the dispatch (line 124, `Kit kitCmd -> runKit kitCmd`) are unchanged.

Important: the old module re-exported a large testing surface (`SidecarMeta`, `computeKitHash`,
`KitState`, `StatusRow`, `KitItem`, `SkillEntry`, `AgentEntry`, `classify`, `collectStatus`,
`renderState`, `itemVersion`, and the sidecar accessors) for `KitSpec`. Those symbols now live in
`baikai-kit` (`Baikai.Kit.Sidecar`, `Baikai.Kit.Status`, `Baikai.Kit.Manifest`). Removing them from
`Mori.Command.Kit` will break `KitSpec` compilation; that is handled in M4. Do M2 and M4 together if
you want a single green build, or expect `KitSpec` to fail to compile between M2 and M4.

Acceptance: `cabal build mori-cli` succeeds; the `mori-cli` library no longer contains the old kit
logic; `mori kit --help` lists `list`, `install`, `update`, `uninstall`, `status`.


### M3 — Route interactive sessions through baikai-kit's session helper

After this milestone, the 14 cwd-based call sites get their directory list from
`Baikai.Kit.Session.agentDirsForSession moriKitConfig`, and the one non-cwd call site keeps a local
helper.

In `mori-cli/src/Mori/Command/Agent.hs`, import the session helper and `moriKitConfig`:

```haskell
import Baikai.Kit.Session qualified as KitSession
import Mori.Command.Kit (moriKitConfig)
```

Redefine the cwd-based helper to delegate, keeping the same name and type so the 14 call sites are
untouched:

```haskell
agentDirsForSession :: IO [FilePath]
agentDirsForSession = KitSession.agentDirsForSession moriKitConfig
```

Keep `agentDirsForRoot :: FilePath -> IO [FilePath]` as-is (it is still needed at `Agent.hs:2572`
for the registered-project-root case, which `baikai-kit` does not cover because its session helper
resolves project scope from cwd). Before finalizing, confirm against EP-26's `Baikai.Kit.Session`
that `agentDirsForSession moriKitConfig` returns the same two-entry, existence-filtered list mori
expects: user base `$HOME/.config/mori/agents` and project base `<cwd>/.mori/agents`, each filtered
by `doesDirectoryExist`. If the helper instead returns the `.claude/...` subpaths or unfiltered
paths, adjust the call sites or open a discrepancy note rather than silently changing `--add-dir`
behavior.

Acceptance: `cabal build mori-cli` succeeds; an interactive launch (e.g. `mori agent ask --debug`)
still resolves the same `--add-dir` list it did before migration (compare against a pre-migration
binary or against the printed prompt/dirs).


### M4 — Port/trim the KitSpec test

After this milestone, the mori test suite is green and no longer tests logic that now lives in
`baikai-kit`. The pure hashing, sidecar I/O, `classify` truth table, and `collectStatus` fixtures in
`mori-cli/test/Mori/Command/KitSpec.hs` (~380 lines) are covered by `baikai-kit`'s own test suite
(EP-26 M7). Delete `KitSpec.hs` and remove `Mori.Command.KitSpec` from the `other-modules` list of
the `test-suite mori-cli-test` stanza in `mori-cli.cabal` (line 190). If you want a mori-specific
wiring smoke test, add a tiny test that asserts `moriKitConfig` has `toolName == "mori"`,
`repoUrl == "https://github.com/shinzui/mori-kit.git"`, and `providers == [InteractiveClaude]`;
otherwise no replacement is required.

Acceptance: `cabal test mori-cli` is green and `KitSpec` is gone (or replaced by the small config
assertion).


### M5 — Manual verification against the real mori-kit repo

After this milestone you have hand-confirmed all five subcommands and the path equivalence against
the live `https://github.com/shinzui/mori-kit.git` cache. Covered in Concrete Steps and Validation.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/mori-project/mori` unless noted.

M1 — wire and resolve the dependency. After editing `cabal.project`, `flake.nix`,
`flake.module.nix`, `nix/haskell-overlay.nix`, and `mori-cli/mori-cli.cabal`:

```bash
cabal build mori-cli
```

Expect a successful configure that includes `baikai-kit` in the build plan (it still compiles the
old `Mori.Command.Kit`). If using the nix devshell, you may need `nix flake lock --update-input
baikai-src` first so the pinned rev is fetched.

M2/M4 — after rewriting `Mori.Command.Kit` and deleting `KitSpec`:

```bash
cabal build mori-cli
cabal test mori-cli
```

Expect both green. `cabal test` should run the mori suite without `Mori.Command.KitSpec`.

M5 — exercise the binary against the real kit. Use a throwaway project directory so installs land
under `--project` scope and never touch your real `$HOME/.config/mori`:

```bash
mkdir -p /tmp/mori-kit-verify && cd /tmp/mori-kit-verify
mori kit list
```

Expected output shape (four skills, no agents):

```text
Skills:
  automation-config       Author, validate, and debug mori automation configurations
  mori-config             Author, validate, and edit mori.dhall project configurations
  cookbook-config         Author, validate, and edit mori/cookbook.dhall cookbook catalogs
  mori-bootstrap-corpus   Bootstrap a complete corpus project from a repo name
```

Install one real skill to project scope and confirm the path:

```bash
mori kit install mori-config --project
ls -la /tmp/mori-kit-verify/.mori/agents/.claude/skills/mori-config/
```

Expected: the directory exists and contains `SKILL.md` plus the `.mori-kit.json` sidecar
(`.mori/agents/.claude/skills/mori-config/SKILL.md`). The install message shape:

```text
Installed skill 'mori-config' to /tmp/mori-kit-verify/.mori/agents
```

Show status and then uninstall:

```bash
mori kit status
mori kit uninstall mori-config --project
```

`mori kit status` prints a table whose header is `NAME  TYPE  SCOPE  INSTALLED  LATEST  STATE` and a
row `mori-config  skill  project  0.1.0  0.1.0  up-to-date`. `mori kit uninstall mori-config
--project` prints `Uninstalled skill 'mori-config' from project scope.` and removes the directory.

Path-equivalence check (the load-bearing assertion of this plan): the installed path
`/tmp/mori-kit-verify/.mori/agents/.claude/skills/mori-config/` is exactly the path the
pre-migration `mori` produced (`resolveTargetDir ProjectScope` = `<cwd>/.mori/agents`, then
`.claude/skills/<name>`). Confirm no `.agents/` or `.codex/` directory was created (those would
indicate a Codex provider leaked in).


## Validation and Acceptance

Acceptance is behavioral parity, not just compilation.

Byte-identical Claude install paths. Before migration, `mori kit install mori-config --project`
created `<cwd>/.mori/agents/.claude/skills/mori-config/SKILL.md`. After migration it must create the
same path. The mechanism is `Baikai.AgentAssets.skillTargetPath InteractiveClaude
InteractiveProjectScope "mori-config"` = `joinPath [".claude","skills","mori-config"]` joined under
`<cwd>/.mori/agents`. Verify by listing the directory (Concrete Steps M5) and by diffing the
installed `SKILL.md` against `/Users/shinzui/Keikaku/bokuno/mori-project/mori-kit/skills/mori-config/SKILL.md`.

All five subcommands behave identically. `list` shows the four skills; `install <name> --project`
and `install <name>` (user scope) write to the right base; `update` re-pulls and reinstalls present
items; `uninstall <name> --project` removes; `status` prints the table with correct
INSTALLED/LATEST/STATE. Compare each against the recorded pre-migration transcript.

Real manifest parses. `mori kit list` against the live `mori-kit` repo loads `kit.json`
(`version: 2`, four skills, zero agents) without error.

Interactive session still discovers assets. With a skill installed to `--project` scope in the
throwaway dir, `mori agent ask --debug` (or whichever flow prints/uses `--add-dir`) includes
`<cwd>/.mori/agents` in its add-dir list. Confirm the `mori agent ask` registered-project path
(`Agent.hs:2572`) still uses the kept local `agentDirsForRoot` with the project's root.

mori's own test suite green:

```bash
cabal test mori-cli
```

Expect all tests to pass with `Mori.Command.KitSpec` removed (or replaced by the small config
assertion).


## Idempotence and Recovery

The build-wiring edits (M1) are idempotent: re-running `cabal build mori-cli` after the edits is
safe. `mori kit install` / `uninstall` are idempotent in the sense that reinstalling overwrites and
re-uninstalling reports "not installed".

The old `Mori.Command.Kit` and `Mori.Command.KitSpec` remain in git history; if the adapter
misbehaves, recover by `git revert` of the M2/M3/M4 commits, which restores the hand-written module
and the original `Mori.Cli`/`Mori.Command.Agent` wiring. The narrowest rollback is to revert only
the `Mori.Cli` dispatch wiring (it imports `kitCommandParser`/`runKit` from `Mori.Command.Kit`), but
in practice revert M2 as a unit.

Install/verification tests must prefer `--project` scope in a throwaway directory (e.g.
`/tmp/mori-kit-verify`) to avoid polluting the user's real `$HOME/.config/mori`. The kit cache lives
at `$HOME/.cache/mori/kit` and is a read-only `--depth 1` clone of `mori-kit`; verification reads it
but should not modify it. If the cache is corrupted, delete `$HOME/.cache/mori/kit` and rerun any
`mori kit` command to re-clone.


## Interfaces and Dependencies

mori depends on the `baikai-kit` library package and (transitively / directly if any module
references its types) the `baikai` library package, both pinned via a single GitHub
`source-repository-package` in `cabal.project` with subdirs `baikai baikai-kit`, mirrored by the
`baikai-src` flake input and the `nix/haskell-overlay.nix` `callCabal2nix` blocks. Pin the version
constraint to EP-26's published value; default `baikai-kit ^>=0.1.0`.

The `baikai-kit` public API contract that this plan consumes (record fields carry NO Hungarian
prefixes; access via generic-lens labels, e.g. `entry ^. #name`):

```haskell
-- Baikai.Kit.Manifest
data KitManifest = KitManifest { version :: !Int, skills :: ![SkillEntry], agents :: ![AgentEntry] }
data SkillEntry  = SkillEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text), path :: !Text, files :: ![Text] }
data AgentEntry  = AgentEntry  { name :: !Text, description :: !Text, version :: !(Maybe Text), path :: !Text, files :: !(Maybe [Text]) }
data KitItem     = KitSkillItem !SkillEntry | KitAgentItem !AgentEntry

-- Baikai.Kit.Config
data KitConfig = KitConfig { toolName :: !Text, repoUrl :: !Text, providers :: ![AgentAssetProvider] }
  -- AgentAssetProvider = Baikai.Interactive.InteractiveProvider (InteractiveClaude | InteractiveCodex)
data KitScope  = UserScope | ProjectScope

-- Baikai.Kit.Repo
ensureKitRepo :: KitConfig -> IO FilePath
pullKitRepo   :: KitConfig -> FilePath -> IO ()

-- Baikai.Kit.Install
loadManifest  :: FilePath -> IO KitManifest
lookupItem    :: Text -> KitManifest -> Maybe KitItem
installItem   :: KitConfig -> Text -> KitScope -> IO ()
uninstallItem :: KitConfig -> Text -> KitScope -> IO ()
updateKit     :: KitConfig -> Maybe Text -> IO ()
listAvailable :: KitConfig -> IO ()

-- Baikai.Kit.Sidecar
data SidecarMeta = SidecarMeta { {- name, kind, version, hash, installedAt -} }
computeKitHash :: FilePath -> [Text] -> IO Text

-- Baikai.Kit.Status
data KitState = KitUpToDate | KitOutdated | KitDirty | KitUnknown
classify      :: {- ... -}
collectStatus :: {- ... -}
kitStatus     :: KitConfig -> IO ()

-- Baikai.Kit.Session
agentDirsForSession :: KitConfig -> IO [FilePath]

-- Baikai.Kit.Command
data KitCommand = KitList | KitInstall !Text !KitScope | KitUpdate !(Maybe Text) | KitUninstall !Text !KitScope | KitStatus
kitCommandParser :: Parser KitCommand
runKit           :: KitConfig -> KitCommand -> IO ()

-- Baikai.Kit
-- umbrella re-export of all the above.
```

Integration note. The package routes installs through `Baikai.AgentAssets` using
`InteractiveProjectScope` (and `InteractiveUserScope`) relative subpaths joined under the resolved
agents base. For `providers = [InteractiveClaude]` this yields `.claude/skills/<name>` and
`.claude/agents/<name>.md`, identical to mori's current hardcoded paths in `Kit.hs:260`/`Kit.hs:268`.
Verify this equivalence explicitly (Validation): install a skill, list the directory, and confirm
the path matches `<base>/.claude/skills/<name>` with no `.agents/`/`.codex/` artifacts.

The mori-side interfaces that must exist at the end of each milestone:

```haskell
-- End of M2, in Mori.Command.Kit:
moriKitConfig :: KitConfig
runKit        :: KitCommand -> IO ()  -- wrapper closing over moriKitConfig
-- re-exports: KitCommand, kitCommandParser (from Baikai.Kit.Command)

-- End of M3, in Mori.Command.Agent (unchanged signatures, new bodies/keeps):
agentDirsForSession :: IO [FilePath]        -- delegates to KitSession.agentDirsForSession moriKitConfig
agentDirsForRoot    :: FilePath -> IO [FilePath]  -- kept local for the non-cwd caller at Agent.hs:2572
```

`Mori.Cli` (lines 32, 90, 124, 280) keeps importing `KitCommand`, `kitCommandParser`, `runKit` from
`Mori.Command.Kit` and needs no edit because the adapter re-exports those three names.
