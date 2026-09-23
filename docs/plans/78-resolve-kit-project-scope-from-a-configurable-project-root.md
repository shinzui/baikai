---
id: 78
slug: resolve-kit-project-scope-from-a-configurable-project-root
title: "Resolve kit project scope from a configurable project root"
kind: exec-plan
created_at: 2026-09-23T14:11:21Z
intention: "intention_01m379fwwker59e1mjhb3k3hfa"
master_plan: "docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-23T14:11:21Z
---

# Resolve kit project scope from a configurable project root

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today, a tool built on `baikai-kit` treats "the project" as whatever directory the user
happened to be in. Running `mytool kit install review --project` from `src/` writes the skill
under `src/.mytool/agents/…`; a later `mytool kit status` from the repository root does not see
it, `mytool kit uninstall review --project` from the root says it is not installed, and an
interactive session started from a subdirectory mounts no project skills at all.

After this change, a tool tells `baikai-kit` how to find its project root, and every
project-scope operation — install, status, uninstall, update, and the session-directory lookup
— uses that one root. A tool with no opinion writes one line to get the common behaviour
("walk up to the nearest directory containing `.git` or `.mytool`"), and a tool that supplies
nothing keeps exactly today's current-directory behaviour.

You can see it working by running the new tests with `cabal test baikai-kit`: one installs a
skill at project scope from a nested subdirectory, then finds it from a sibling subdirectory
with `kitStatus`, `agentDirsForSession`, and `uninstallItem`.

This plan implements [IR-8](../improvement-requests/resolve-kit-project-scope-from-the-project-root.md)
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-8`). It is EP-1 of
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md).


## Progress

- [ ] Milestone 1: add `projectRoot` to `KitConfig`, the `kitConfig` smart constructor, the hand-written `Show` instance, `findProjectRoot`, and `projectRootByMarkers`; route `projectAgentsDir` and the Codex project base through `projectRoot`.
- [ ] Milestone 1: switch the test suite's `testConfig` to `kitConfig`; add the three resolver tests; `cabal test baikai-kit` green.
- [ ] Milestone 2: add the configured-root round-trip test and the unchanged-default test; `cabal test baikai-kit` green.
- [ ] Milestone 2: update CAP-21's Shape block and `baikai-smoke/doc-shapes/Shape/Cap21.hs` together; `cabal test baikai-smoke:test:doc-shapes` green.
- [ ] Milestone 2: document project scope in `docs/user/kit.md`; add the changelog entry, the ADR, and the bundle log entries; validators green; `cabal build all --enable-tests` green.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Represent the resolver as a plain field `projectRoot :: !(IO FilePath)`, not
  `Maybe (IO FilePath)`.
  Rationale: a `Maybe` would need a second code path for `Nothing` at every use; a plain action
  whose default is `getCurrentDirectory` has one path and states the default in the constructor.
  Date: 2026-09-23

- Decision: Add a smart constructor `kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig`
  and document it as the way to build a `KitConfig`.
  Rationale: every consumer builds `KitConfig` as a record literal, and omitting a strict field
  is a compile error. IR-8 asks for a change that is additive for callers that supply nothing;
  the smart constructor is how a caller supplies nothing. A record literal still works for a
  caller that sets every field. This makes the release breaking (`baikai-kit 0.3.0.0`), which
  the MasterPlan already accepts.
  Date: 2026-09-23

- Decision: The marker resolver does not canonicalise paths and falls back to the current
  directory when no marker is found.
  Rationale: canonicalising would replace a user's symlinked checkout path with its target and
  make install locations surprising; falling back keeps a tool working outside any project,
  which is exactly today's behaviour. `findProjectRoot` exposes the `Maybe` for a caller who
  wants to treat "no marker" differently.
  Date: 2026-09-23

- Decision: `projectRoot` is an `IO FilePath`, not `IO (Either KitError FilePath)`.
  Rationale: the supplied resolver never fails (it falls back), and a consumer's own resolver
  can fall back the same way. Adding a `KitError` constructor for a failure the engine cannot
  describe would add a branch every caller must handle for no benefit. The Haddock states that
  an exception thrown by a consumer's resolver propagates.
  Date: 2026-09-23


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository root is the directory containing `cabal.project`. `baikai-kit` is the package in
`baikai-kit/`; its sources are under `baikai-kit/src/Baikai/Kit/` and its whole test suite is
the single file `baikai-kit/test/Main.hs` (a `tasty` suite run with `NumThreads 1`, so tests run
one after another and may change process-global state such as `HOME` or the current directory
as long as they restore it). The package compiles with `GHC2024` plus `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`, and `DeriveAnyClass`, and with
`-Wmissing-deriving-strategies` (write `deriving stock (…)`) and
`-Werror=incomplete-patterns`. `Baikai.Prelude` (from the core `baikai` package) re-exports
`lens` operators (`^.`, `.~`, `&`, `view`) and generic-lens labels, so `config ^. #toolName`
reads a record field by name. Record fields in this repository never carry type-name prefixes:
write `projectRoot`, not `kitConfigProjectRoot`.

Terms used below. A *kit* is a git repository of skills and subagents with a `kit.json`
manifest; `baikai-kit` clones it into `~/.cache/<tool>/kit`. *Scope* is where an item is
installed: `UserScope` under the user's home, `ProjectScope` under the project. A *provider* is
one of the two coding agents whose directory layout the installer writes: `InteractiveClaude`
(Claude Code) and `InteractiveCodex` (Codex), from `Baikai.Interactive` in the core package;
`AgentAssetProvider` is an alias for that type. The *agents base* is the directory below which a
provider's files are written for a scope. A *sidecar* is the small JSON file written beside each
installed item.

How project scope is resolved today, in `baikai-kit/src/Baikai/Kit/Config.hs`:

```haskell
data KitConfig = KitConfig
  { toolName :: !Text,
    repoUrl :: !Text,
    providers :: ![AgentAssetProvider]
  }
  deriving stock (Generic, Show)

projectAgentsDir :: KitConfig -> IO FilePath
projectAgentsDir config = do
  cwd <- getCurrentDirectory
  pure (cwd </> "." <> Text.unpack (config ^. #toolName) </> "agents")

resolveAgentsBase :: KitConfig -> KitScope -> IO FilePath
resolveAgentsBase config UserScope = userAgentsDir config
resolveAgentsBase config ProjectScope = projectAgentsDir config

providerAgentsBase :: KitConfig -> AgentAssetProvider -> KitScope -> IO FilePath
providerAgentsBase config InteractiveClaude scope = resolveAgentsBase config scope
providerAgentsBase _config InteractiveCodex UserScope = getHomeDirectory
providerAgentsBase _config InteractiveCodex ProjectScope = getCurrentDirectory
```

Every project-scope path in the package flows through these three functions. In
`baikai-kit/src/Baikai/Kit/Install.hs`, `planInstall`, `uninstallItem`, `isInstalled`, and the
private `locallyModified` call `providerAgentsBase`. In `baikai-kit/src/Baikai/Kit/Status.hs`,
`scanInstalled` calls `providerAgentsBase`. In `baikai-kit/src/Baikai/Kit/Session.hs`,
`agentDirsForSession` calls `userAgentsDir` and `projectAgentsDir` and keeps those that exist.
So fixing the three functions in `Config.hs` fixes every caller; the only other direct use of
`getCurrentDirectory` for project scope is the Codex line above. Confirm there is no other with:

```bash
grep -rn "getCurrentDirectory" baikai-kit/src
```

which today prints two lines, both in `Config.hs`.

Consumers build `KitConfig` as a record literal. For example the CAP-21 capability record
`docs/capabilities/kit-installer.md` shows, in its `## Shape` section:

```haskell
myKitConfig :: KitConfig
myKitConfig =
  KitConfig
    { toolName = "mytool",
      repoUrl = "https://github.com/example/mytool-kit.git",
      providers = [InteractiveClaude, InteractiveCodex]
    }
```

and `baikai-smoke/doc-shapes/Shape/Cap21.hs` holds the same block between `-- BEGIN CAP-21` and
`-- END CAP-21` markers. The `baikai-smoke:test:doc-shapes` test suite compiles that module and
fails if the record's block and the module's marked region differ. The test suite in
`baikai-kit/test/Main.hs` builds `testConfig` the same way, and several tests modify it with
`testConfig & #repoUrl .~ "file:///nonexistent-kit"`.

The existing test helper `withPreparedKitHome` creates a temporary `HOME`, a fake kit cache at
`$HOME/.cache/testkit/kit` holding a `.git` directory (so `git pull` fails and the cache is used
as a stale copy), a skill `demo` at `skills/demo/SKILL.md`, an agent `reviewer` at
`agents/reviewer.md`, and a `kit.json` listing both, then sets `HOME` and restores it afterwards.
No existing test exercises `ProjectScope`.

Relevant ADRs: [docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md](../adr/0017-a-documented-example-compiles-in-the-test-suite.md)
requires a change that moves a name documented in a capability record to edit the record and
its compiled twin in the same commit.
[docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md)
requires library functions to return values rather than exit; nothing in this plan exits.
The ADR format is plain Markdown with `title`, `status`, and `date` frontmatter, as in
`docs/adr/0013-library-code-never-calls-exitfailure.md`, plus a row in `docs/adr/README.md`.

A later plan in the same initiative,
`docs/plans/80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md`, will add a
second function field (`chooseItem`) to `KitConfig` and extend the `kitConfig` constructor and
`Show` instance this plan creates, so keep both easy to extend: one field per line, defaults in
one place.


## Plan of Work

### Milestone 1: the resolver and the configuration field

At the end of this milestone `KitConfig` carries a project-root action, every project-scope
path uses it, the package exports a smart constructor and a marker-walking resolver, and three
tests prove the resolver. Nothing observable changes for a tool that uses `kitConfig` without
setting `projectRoot`.

In `baikai-kit/src/Baikai/Kit/Config.hs`:

Add the field `projectRoot :: !(IO FilePath)` as the last field of `KitConfig`, with a Haddock
comment saying it returns the directory that project scope lives under, that it is run once per
project-scope path lookup, and that an exception it throws propagates to the caller. Change the
deriving clause to `deriving stock (Generic)` and write a `Show` instance by hand that prints the
three data fields and `projectRoot = <IO FilePath>`:

```haskell
instance Show KitConfig where
  showsPrec d config =
    showParen (d > 10) $
      showString "KitConfig {toolName = "
        . shows (config ^. #toolName)
        . showString ", repoUrl = "
        . shows (config ^. #repoUrl)
        . showString ", providers = "
        . shows (config ^. #providers)
        . showString ", projectRoot = <IO FilePath>}"
```

Add and export the smart constructor:

```haskell
-- | A configuration with every optional behaviour at its default:
--   project scope is the current directory.
kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig
kitConfig toolName repoUrl providers =
  KitConfig {toolName, repoUrl, providers, projectRoot = getCurrentDirectory}
```

Add and export the resolver, with `doesPathExist` and `makeAbsolute` imported from
`System.Directory` and `takeDirectory` from `System.FilePath`:

```haskell
-- | The nearest directory, starting at @start@ and walking towards the
--   filesystem root, that contains any of @markers@ (a file or a
--   directory, e.g. ".git" or ".mytool"). 'Nothing' if none does.
findProjectRoot :: [FilePath] -> FilePath -> IO (Maybe FilePath)
findProjectRoot markers start = makeAbsolute start >>= go
  where
    go dir = do
      found <- or <$> traverse (doesPathExist . (dir </>)) markers
      if found
        then pure (Just dir)
        else
          let parent = takeDirectory dir
           in if parent == dir then pure Nothing else go parent

-- | A ready-made 'projectRoot': the nearest ancestor of the current
--   directory holding one of @markers@, or the current directory itself
--   when there is none.
projectRootByMarkers :: [FilePath] -> IO FilePath
projectRootByMarkers markers = do
  cwd <- getCurrentDirectory
  fromMaybe cwd <$> findProjectRoot markers cwd
```

Then make every project-scope path use the field. Replace the body of `projectAgentsDir` with
`root <- config ^. #projectRoot` followed by the same `</> "." <> tool </> "agents"`, and replace
the Codex project clause with
`providerAgentsBase config InteractiveCodex ProjectScope = config ^. #projectRoot`. Add
`kitConfig`, `findProjectRoot`, and `projectRootByMarkers` to the module's export list.
`Baikai.Kit` re-exports the whole module, so nothing else needs an export change. After this,
`grep -rn "getCurrentDirectory" baikai-kit/src` must print only the two uses inside
`kitConfig` and `projectRootByMarkers`.

In `baikai-kit/test/Main.hs`, change `testConfig` to
`kitConfig "testkit" "file:///not-used" [InteractiveClaude, InteractiveCodex]` and import
`kitConfig`, `findProjectRoot`, and `projectRootByMarkers` from `Baikai.Kit`. The existing
`& #repoUrl .~` modifications keep working. Add a test group `projectRootTests` to the list in
`main` with three resolver tests. Use a marker name that cannot exist anywhere above the system
temporary directory, such as `".testkit-root-marker"`, so the walk to the filesystem root cannot
find a real `.git` belonging to someone else:

1. "findProjectRoot walks up from a nested directory": in a temporary directory `tmp`, create
   `tmp/root/.testkit-root-marker` (an empty file) and `tmp/root/a/b`; assert
   `findProjectRoot [".testkit-root-marker"] (tmp </> "root" </> "a" </> "b")` returns
   `Just (tmp </> "root")`.
2. "findProjectRoot accepts a start directory that is itself the root": same tree, start at
   `tmp </> "root"`, expect `Just (tmp </> "root")`.
3. "findProjectRoot returns Nothing when no marker exists": start at `tmp </> "root" </> "a"`
   with marker list `[".testkit-no-such-marker"]`, expect `Nothing`. In the same test, run
   `projectRootByMarkers [".testkit-no-such-marker"]` inside
   `withCurrentDirectory (tmp </> "root" </> "a")` and assert the result equals
   `getCurrentDirectory` evaluated inside the same block (compare to that, not to the
   temporary path you built, because on macOS the current directory is reported through the
   `/private` prefix while `withSystemTempDirectory` hands out `/var/…`).

Acceptance: `cabal test baikai-kit` passes, including the three new tests and every existing
test unchanged.

### Milestone 2: every command agrees on the root

At the end of this milestone a test proves that install, status, uninstall, and session
discovery all see the same project scope from different subdirectories, another proves the
default is unchanged, and the documentation, capability record, changelog, and ADR describe the
new field.

Add two tests to `projectRootTests`, both inside `withPreparedKitHome` (which already supplies
a kit with `demo` and `reviewer`). Create a project tree in a second temporary directory:
`proj/.testkit-root-marker`, `proj/src/deep`, and `proj/docs`.

4. "a configured root puts project scope in one place": let
   `config = testConfig { projectRoot = pure proj }` — or, equivalently,
   `testConfig & #projectRoot .~ pure proj`. Inside `withCurrentDirectory (proj </> "src" </> "deep")`,
   call `installItem config "demo" ProjectScope` and assert `Right`. Assert that
   `proj/.testkit/agents/.claude/skills/demo/SKILL.md` and `proj/.agents/skills/demo/SKILL.md`
   exist and that `proj/src/deep/.testkit` does not. Then inside
   `withCurrentDirectory (proj </> "docs")`: call `kitStatus config` and assert its rows contain
   an entry named `demo` with scope `"project"`; call `agentDirsForSession config` and assert it
   contains `proj </> ".testkit" </> "agents"`; call `uninstallItem config "demo" ProjectScope`
   and assert that `renderUninstallReport "demo" ProjectScope` of the result starts with
   `"Uninstalled skill 'demo' from project scope"`, and that the Claude skill directory is gone.
   Also repeat the install and status steps with
   `testConfig & #projectRoot .~ projectRootByMarkers [".testkit-root-marker"]` to prove the
   ready-made resolver reaches the same directory. When comparing directories that came from
   `getCurrentDirectory` against paths you built, canonicalise both with `canonicalizePath`.
5. "without a resolver, project scope is the current directory": with the plain `testConfig`,
   inside `withCurrentDirectory (proj </> "src" </> "deep")`, install `demo` at project scope and
   assert that `.testkit/agents/.claude/skills/demo/SKILL.md` exists relative to that directory
   (resolve it with `getCurrentDirectory` inside the block) and that
   `proj/.testkit` does not exist.

The status and uninstall calls above need `ProjectScope` and `renderUninstallReport` imported
from `Baikai.Kit` (today the test imports only `KitScope (UserScope)`; widen it to
`KitScope (..)`), plus `agentDirsForSession`; and `withCurrentDirectory` and `canonicalizePath`
from `System.Directory`.

Documentation and records, in the same commit as the code they describe:

In `docs/capabilities/kit-installer.md`, replace the `## Shape` block with a version built from
the smart constructor that shows the new field, and put exactly the same text between the
markers in `baikai-smoke/doc-shapes/Shape/Cap21.hs`:

```haskell
myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { projectRoot = projectRootByMarkers [".git", ".mytool"]
    }
```

Run the repository formatter over the twin module if it is available (`nix fmt`), and if it
reflows the block, copy the formatted block back into the record, as ADR 0017 describes. Bump
the record's `generated.at`, and append a dated `* **Update**: CAP-21 …` entry to
`docs/capabilities/log.md` describing the new field.

In `docs/user/kit.md`, rewrite the `## KitConfig` section to build the config with `kitConfig`,
explain `projectRoot` and `projectRootByMarkers`, and change the path listing so the last
two lines read `<project root>/.<tool>/agents` rather than `<cwd>/.<tool>/agents`. Add a short
`## Project Scope` section saying how the root is located (the tool's `projectRoot`, by default
the current directory), that install, status, update, uninstall, and `agentDirsForSession` all
use it, that Codex project files go to `.agents` and `.codex` under the same root, and how a
tool configures it in one line. Update the `## Session Discovery` listing the same way. Bump
`generated.at` in the frontmatter and append a dated entry to `docs/user/log.md`.

Under `## [Unreleased]` in the root `CHANGELOG.md`, add a `### Added` bullet beginning
`baikai-kit:` describing `projectRoot`, `kitConfig`, `findProjectRoot`, and
`projectRootByMarkers`, and a `### Changed` bullet beginning `baikai-kit:` marked
`__Breaking__` saying that `KitConfig` gains a strict field, so a record literal must set it or
switch to `kitConfig`, and that `KitConfig`'s `Show` instance is now hand-written.

Write a new ADR in `docs/adr/` with the next unused number (list the directory to find it; at
the time of writing it is 0021) titled "Kit project scope is one resolved root, and every
project-scope path derives from it". Context: IR-8's symptoms. Decision: `KitConfig.projectRoot`
is the only source of the project directory; `projectAgentsDir`, `resolveAgentsBase`, and
`providerAgentsBase` are the only functions that turn it into paths, and no code in the package
calls `getCurrentDirectory` for project scope. Consequences: consumers configure the root once;
new kit features that touch project scope must go through those functions. Add its row to the
table in `docs/adr/README.md`.

Acceptance: `cabal test baikai-kit` and `cabal test baikai-smoke:test:doc-shapes` pass, the
validators below exit 0, and `cabal build all --enable-tests` succeeds.


## Concrete Steps

All commands run from the repository root.

```bash
cabal build baikai-kit
cabal test baikai-kit
```

After Milestone 1 the test output includes, among the existing groups:

```text
  Project root
    findProjectRoot walks up from a nested directory:                     OK
    findProjectRoot accepts a start directory that is itself the root:    OK
    findProjectRoot returns Nothing when no marker exists:                OK
```

After Milestone 2:

```text
    a configured root puts project scope in one place:                    OK
    without a resolver, project scope is the current directory:           OK
```

Then:

```bash
grep -rn "getCurrentDirectory" baikai-kit/src
cabal test baikai-smoke:test:doc-shapes
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
cabal build all --enable-tests
```

The `grep` prints exactly two lines, both in `baikai-kit/src/Baikai/Kit/Config.hs`, inside
`kitConfig` and `projectRootByMarkers`.

Commit after each milestone with a Conventional Commits message and the trailers:

```text
feat(kit): resolve project scope from a configurable project root

MasterPlan: docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md
ExecPlan: docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md
Intention: intention_01m379fwwker59e1mjhb3k3hfa
```


## Validation and Acceptance

The change is accepted when all of the following hold, which together are IR-8's acceptance
criteria:

1. Test 4 passes: with a configured root, an install at project scope from a nested
   subdirectory writes under the root, and `kitStatus`, `uninstallItem`, and
   `agentDirsForSession` all find it from a different subdirectory. The same holds with
   `projectRootByMarkers`.
2. Tests 1–3 pass: the marker walk handles a nested start, a start that is the root, and no
   marker before the filesystem root.
3. Test 5 passes: with no resolver configured, project scope is the current directory, as
   before.
4. `docs/user/kit.md` says how project scope is located and how a tool configures it.

To see the behaviour by hand, build a throwaway tool or use any consumer after it adopts this
release, then from a checkout run `mytool kit install review --project` inside `src/` and
`mytool kit status` at the root; the item is listed with scope `project`.


## Idempotence and Recovery

Every step edits source or documentation and can be repeated. The tests create everything in
temporary directories and restore `HOME` and the current directory with `finally` and
`withCurrentDirectory`, so a failing test leaves nothing behind. If `doc-shapes` fails after
formatting, copy the formatted block from `baikai-smoke/doc-shapes/Shape/Cap21.hs` into the
record rather than the other way round.


## Interfaces and Dependencies

No new package dependencies: `System.Directory` (`doesPathExist`, `makeAbsolute`,
`getCurrentDirectory`, `withCurrentDirectory`, `canonicalizePath`) and `System.FilePath` are
already used.

At the end of this plan `Baikai.Kit.Config` exports, in addition to what it exports today:

```haskell
data KitConfig = KitConfig
  { toolName :: !Text,
    repoUrl :: !Text,
    providers :: ![AgentAssetProvider],
    projectRoot :: !(IO FilePath)
  }
  deriving stock (Generic)
instance Show KitConfig

kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig
findProjectRoot :: [FilePath] -> FilePath -> IO (Maybe FilePath)
projectRootByMarkers :: [FilePath] -> IO FilePath
```

`projectAgentsDir`, `resolveAgentsBase`, and `providerAgentsBase` keep their signatures and now
derive every project-scope path from `projectRoot`.
