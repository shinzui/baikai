---
id: 80
slug: let-kit-install-choose-an-item-through-a-caller-supplied-chooser
title: "Let kit install choose an item through a caller-supplied chooser"
kind: exec-plan
created_at: 2026-09-23T14:11:21Z
intention: "intention_01m379fwwker59e1mjhb3k3hfa"
master_plan: "docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-23T14:11:21Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-23T15:52:52Z
      mode: "implement"
      note: "Milestones 1 and 2 implemented"
---

# Let kit install choose an item through a caller-supplied chooser

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`baikai-kit` gives a tool a ready-made `kit` subcommand, but `kit install` demands an exact item
name. Two of the three tools that ship it want `kit install` with no name to open a picker
(fzf), and to get that they keep private copies of the whole command type, parser, and install
flow: `mori://shinzui/rei` in `rei-cli`'s `Rei.Cli.Commands.Kit.{Types,Parser,Handler}`, and
`mori://shinzui/okf` in `okf-cli`'s `Okf.Cli.Kit`, which also mirrors the type because it needs
`Eq` and help text that names `.okf/agents`.

After this change a tool supplies only a function — "given the manifest, return the name the
user picked, or nothing if they cancelled" — in its `KitConfig`, and the engine does the rest.
`mytool kit install` with no name refreshes the kit, loads the manifest, calls that function,
and installs the result; a cancelled pick prints `No item chosen; nothing installed.` and exits
0; a tool that supplies no chooser gets a clear error telling the user to pass `NAME`.
`KitCommand` derives `Eq`, and `mytool kit install --help` says `--project` installs under
`.mytool/agents`. The engine itself still ships no picker and depends on no terminal UI library.

You can see it working with `cabal test baikai-kit`: a stub chooser (no fzf needed) picks
`demo` and the skill appears on disk; a stub that returns `Nothing` installs nothing and
succeeds; with no chooser the command returns `KitItemNameRequired`.

This plan implements [IR-6](../improvement-requests/let-kit-install-choose-an-item-interactively.md)
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-6`). It is EP-3 of
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md)
and depends on EP-1,
[docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md](78-resolve-kit-project-scope-from-a-configurable-project-root.md),
which must be complete before this plan starts (see Context and Orientation for what it
provides).


## Progress

- [x] (2026-09-23 16:00Z) Milestone 1: `KitCommand` derives `Eq`; `KitInstall` takes `Maybe Text`; `kitCommandParser` takes the `KitConfig` and names `.<tool>/agents` in help; existing call sites and tests updated; parser tests added; `cabal test baikai-kit` green.
- [x] (2026-09-23 16:00Z) Milestone 2: `chooseItem` added to `KitConfig`, `kitConfig`, and the `Show` instance; `KitItemNameRequired` added to `KitError`; `runKitCommand` handles an absent name; chooser, cancel, and missing-chooser tests green (61 tests).
- [x] (2026-09-23 16:15Z) Milestone 2: `docs/user/kit.md`, `CHANGELOG.md`, `docs/user/log.md`, and ADR 0023 updated; validators and `cabal build all --enable-tests` green.


## Surprises & Discoveries

- The milestones were implemented together and committed once: Milestone 1's temporary
  `KitInstall Nothing _ -> Left KitItemNameRequired` branch is exactly Milestone 2's
  no-chooser branch, so there was no intermediate state worth committing separately.
- The rendered help, as a consumer sees it (built with `kitConfig "mytool" …`):

  ```text
  Usage: mytool kit install [NAME] [--project]

  Available options:
    NAME                     Name of the skill or subagent to install; omit it to
                             choose interactively if this tool offers a chooser
    --project                Install to project scope (.mytool/agents under the
                             project root) instead of user scope
  ```

- CAP-21's Shape block needed no change: it uses record-update syntax on `kitConfig`, so the
  new field is filled by the constructor, which is what the smart constructor from
  `docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md` was for.


## Decision Log

- Decision: `kitCommandParser` changes type to `KitConfig -> Parser KitCommand` rather than
  gaining a second, config-aware sibling.
  Rationale: help text that names `.<tool>/agents` needs the tool name, and one parser is
  simpler than two that drift apart — which is the very problem IR-6 describes. The release is
  already a major (`baikai-kit 0.3.0.0`); the one direct consumer of the parser
  (`mori://shinzui/mori`'s `Mori.Command.Kit`) changes one call site.
  Date: 2026-09-23

- Decision: With no name and no chooser, `runKitCommand` returns `Left KitItemNameRequired`
  before touching the network.
  Rationale: there is nothing the refresh could change about the outcome, and failing fast
  avoids a clone on a machine that may be offline. IR-6 only requires the manifest to be loaded
  before calling a chooser, which still holds.
  Date: 2026-09-23

- Decision: A cancelled choice prints `No item chosen; nothing installed.` on stdout and
  returns `Right ()`.
  Rationale: IR-6 requires a successful exit; one line of output tells a user who pressed
  Escape by accident that nothing happened. It goes to stdout because it is the command's
  normal result, like `Installed …`.
  Date: 2026-09-23

- Decision: The chooser is offered only to `install`. `uninstall` and `update NAME` keep a
  required or optional name as today.
  Rationale: IR-6 lists those as consistent but not required for acceptance; adding them later
  is additive.
  Date: 2026-09-23


## Outcomes & Retrospective

IR-6's acceptance criteria 1–3 hold in `baikai-kit/test/Main.hs`'s "Command" group: a stub
chooser sees the whole manifest (`["demo", "reviewer"]`) and its pick is installed; a cancelled
choice installs nothing and `runKit` returns normally (exit 0); no chooser yields
`KitItemNameRequired`, and `runKit` exits 1 with a message naming `NAME`; parsed commands are
compared with `==`; help names `.testkit/agents`. Criteria 4 and 5 are shown by the API shape: a
consumer's integration is `kitConfig … {chooseItem = Just picker}`, `kitCommandParser config`,
and `runKit config`. The deletions in `mori://shinzui/rei` and `mori://shinzui/okf` wait for
them to adopt `baikai-kit ^>=0.3`. ADR 0023 records the no-terminal-UI boundary.

`docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md` extends the
`KitCommand` shape defined here; it must keep `deriving stock (Eq, Show)` and the
`KitConfig -> Parser KitCommand` signature.


## Context and Orientation

The repository root is the directory containing `cabal.project`. `baikai-kit`, in `baikai-kit/`,
is a Haskell library that a command-line tool embeds to get a `kit` subcommand: it clones a
git-hosted *kit* (a repository with a `kit.json` manifest listing skills and agents), and
installs, updates, reports on, and uninstalls those items in the directories where Claude Code
and Codex look for them. Sources are in `baikai-kit/src/Baikai/Kit/`; the test suite is the
single file `baikai-kit/test/Main.hs` (`tasty`, tests run one at a time). The package uses
`GHC2024` with `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`, requires
`deriving stock (…)` strategies, and makes incomplete pattern matches an error. `Baikai.Prelude`
provides `lens` operators and generic-lens labels (`config ^. #toolName`). Record fields never
carry type-name prefixes.

The command surface lives in `baikai-kit/src/Baikai/Kit/Command.hs` and uses
`optparse-applicative` (a library for declaring command-line parsers; `Parser a` describes how to
parse arguments into an `a`, `hsubparser` builds subcommands, `strArgument` a positional
argument, and `optional` makes one optional). Today:

```haskell
data KitCommand
  = KitList
  | KitInstall !Text !KitScope
  | KitUpdate !(Maybe Text) !OverwritePolicy
  | KitUninstall !Text !KitScope
  | KitStatus
  deriving stock (Show)

kitCommandParser :: Parser KitCommand      -- list/install/update/uninstall/status, default list
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())
runKit :: KitConfig -> KitCommand -> IO ()  -- runKitCommand, then on Left: "Error: …" to stderr, exit 1

installParser :: Parser KitCommand
installParser =
  KitInstall
    <$> strArgument (metavar "NAME" <> help "Name of the skill or subagent to install")
    <*> scopeParser "Install to project scope instead of user scope"
```

`runKitCommand`'s install branch is:

```haskell
KitInstall n scope -> withRepo $ \repo ->
  loadManifest (repo ^. #dir) `thenE` \manifest ->
    installFrom config (repo ^. #dir) manifest n scope `thenE` \item ->
      printed $
        "Installed " <> itemKind item <> " '" <> itemName item <> "' to " <> scopeLabel scope <> " scope."
```

where `withRepo` refreshes or clones the cache (`ensureKitRepo`), warns on stderr if the cache
is stale, prints `Fetched <tool>-kit.` after a first clone, and passes the `KitRepo` on;
`loadManifest` reads `kit.json` from the cache directory; and `installFrom` installs one named
item from an already-loaded manifest. `OverwritePolicy` (from `Baikai.Kit.Install`) and
`KitScope` (from `Baikai.Kit.Config`) both already derive `Eq`, so `KitCommand` can derive it.

`KitManifest` (in `baikai-kit/src/Baikai/Kit/Manifest.hs`) is
`{ version :: Int, skills :: [SkillEntry], agents :: [AgentEntry] }`, where each entry has a
`name`, `description`, optional `version`, and source paths. `Baikai.Kit.Manifest` imports only
`Baikai.Kit.Error` and `Baikai.Kit.Path`, so `Baikai.Kit.Config` may import it without an
import cycle.

Failures are values of `KitError` in `baikai-kit/src/Baikai/Kit/Error.hs`, a closed sum with
positional constructors (for example `KitItemNotFound Text`) and one renderer,
`renderKitError :: KitError -> Text`.
[docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md)
requires that no function but `runKit` exits the process: a missing name must be a `KitError`,
and a cancelled choice must be `Right ()`.

What EP-1 provides (from
`docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md`, which must be
complete first). In `baikai-kit/src/Baikai/Kit/Config.hs`, `KitConfig` has four fields —
`toolName`, `repoUrl`, `providers`, and `projectRoot :: !(IO FilePath)` — and derives only
`Generic`, with a hand-written `Show` instance that prints each data field and a placeholder for
`projectRoot`. The smart constructor `kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig`
fills the optional fields with defaults, and the test suite's `testConfig` is
`kitConfig "testkit" "file:///not-used" [InteractiveClaude, InteractiveCodex]`. Verify before
starting:

```bash
grep -n "projectRoot\|^kitConfig\|instance Show KitConfig" baikai-kit/src/Baikai/Kit/Config.hs
```

If that prints nothing, EP-1 is not done; stop and implement it first.

The existing tests that construct `KitInstall` are in `baikai-kit/test/Main.hs`, in
`pathSafetyTests`, test "install refuses a manifest file path that escapes the install root":
`runKit testConfig (KitInstall "evil" UserScope)`. The test helper `withPreparedKitHome`
creates a temporary `HOME` with a fake kit cache (a `.git` directory, so refreshing fails and
the cache is used as-is) that lists a skill `demo` and an agent `reviewer`; the Claude copy of
`demo` installs to `$HOME/.config/testkit/agents/.claude/skills/demo/SKILL.md`.

The three consumers are, for reference only (no change is made in them by this plan):
`mori://shinzui/mori` package `mori-cli`, module `Mori.Command.Kit`, which re-exports
`kitCommandParser` and calls `runKit`; `mori://shinzui/rei` package `rei-cli`, modules
`Rei.Cli.Commands.Kit.{Types,Parser,Handler,Config}`, whose `installWithPicker` and
`pickItemName` are the behaviour this plan moves into the engine; and `mori://shinzui/okf`
package `okf-cli`, module `Okf.Cli.Kit`, the verbatim mirror kept for `Eq` and help text.

ADRs are plain Markdown files in `docs/adr/` with `title`, `status`, and `date` frontmatter,
indexed in `docs/adr/README.md`. No existing ADR covers interactive choice.


## Plan of Work

### Milestone 1: the command type and parser

At the end of this milestone `KitCommand` derives `Eq`, `KitInstall` carries `Maybe Text`, and
`kitCommandParser` takes the configuration so its help text names the tool's directory. The
engine still refuses an install without a name (temporarily, through the same
`KitItemNameRequired` error Milestone 2 introduces; add the constructor now so this milestone
compiles).

In `baikai-kit/src/Baikai/Kit/Error.hs`, add a constructor
`KitItemNameRequired` (no fields) with a Haddock comment "kit install was given no name and the
tool supplies no chooser", and its rendering in `renderKitError`:

```haskell
KitItemNameRequired ->
  "no item name given: pass NAME to 'kit install' (run 'kit list' to see what is available)."
```

In `baikai-kit/src/Baikai/Kit/Command.hs`:

- Change `KitInstall !Text !KitScope` to `KitInstall !(Maybe Text) !KitScope` and the deriving
  clause to `deriving stock (Eq, Show)`.
- Change `kitCommandParser :: Parser KitCommand` to
  `kitCommandParser :: KitConfig -> Parser KitCommand`, and pass the config to
  `installParser` and `uninstallParser`.
- In `installParser config`, use
  `optional (strArgument (metavar "NAME" <> help "Name of the skill or subagent to install; omit it to choose interactively if this tool offers a chooser"))`,
  and give the scope flag the help text
  `"Install to project scope (" <> projectDirLabel config <> " under the project root) instead of user scope"`.
- In `uninstallParser config`, keep `NAME` required and use
  `"Uninstall from project scope (" <> projectDirLabel config <> ") instead of user scope"`.
- Add a private helper `projectDirLabel :: KitConfig -> String` returning
  `"." <> Text.unpack (config ^. #toolName) <> "/agents"`.
- In `runKitCommand`, split the install branch: `KitInstall (Just n) scope` does exactly what
  the old branch did; `KitInstall Nothing _` returns `pure (Left KitItemNameRequired)` for now.
  Factor the successful-install tail into a local `installNamed repo manifest n scope` so
  Milestone 2 can reuse it.

In `baikai-kit/test/Main.hs`, change `runKit testConfig (KitInstall "evil" UserScope)` to
`runKit testConfig (KitInstall (Just "evil") UserScope)`. Add `optparse-applicative` to the
test suite's `build-depends` in `baikai-kit/baikai-kit.cabal` and import
`Options.Applicative (defaultPrefs, execParserPure, getParseResult, helper, info, renderFailure, ParserResult (..), (<**>))`.
Add a test group `commandTests` to `main` with:

1. "install parses with and without a name":
   `parse ["install"] @?= Just (KitInstall Nothing UserScope)`,
   `parse ["install", "demo", "--project"] @?= Just (KitInstall (Just "demo") ProjectScope)`,
   and `parse [] @?= Just KitList`, where
   `parse args = getParseResult (execParserPure defaultPrefs (info (kitCommandParser testConfig) mempty) args)`.
   These comparisons compile only because `KitCommand` derives `Eq`.
2. "install help names the tool's project directory": run
   `execParserPure defaultPrefs (info (kitCommandParser testConfig <**> helper) mempty) ["install", "--help"]`,
   expect `Failure failure`, and assert that `fst (renderFailure failure "kit")` contains
   `".testkit/agents"`.
3. "install with no name and no chooser is a KitItemNameRequired error":
   `runKitCommand testConfig (KitInstall Nothing UserScope)` returns
   `Left KitItemNameRequired`, and `try @ExitCode (runKit testConfig (KitInstall Nothing UserScope))`
   returns `Left (ExitFailure 1)`. (This needs no kit home: it fails before any I/O.)

Acceptance: `cabal test baikai-kit` passes.

### Milestone 2: the chooser

At the end of this milestone a tool can supply a chooser and `kit install` with no name uses it.

In `baikai-kit/src/Baikai/Kit/Config.hs`, import `KitManifest` from `Baikai.Kit.Manifest` and
add a last field to `KitConfig`:

```haskell
    -- | Called by @kit install@ when no name is given, with the whole
    --   manifest. 'Just' a name installs that item; 'Nothing' means the
    --   user cancelled. When this is 'Nothing', @kit install@ without a
    --   name fails with 'KitItemNameRequired'.
    chooseItem :: !(Maybe (KitManifest -> IO (Maybe Text)))
```

Default it to `Nothing` in `kitConfig`, and extend the hand-written `Show` instance with
`", chooseItem = "` followed by `"Nothing"` or `"Just <chooser>"`.

In `runKitCommand`, replace the temporary `KitInstall Nothing _` branch:

```haskell
KitInstall Nothing scope -> case config ^. #chooseItem of
  Nothing -> pure (Left KitItemNameRequired)
  Just choose -> withRepo $ \repo ->
    loadManifest (repo ^. #dir) `thenE` \manifest -> do
      picked <- choose manifest
      case picked of
        Nothing -> printed "No item chosen; nothing installed."
        Just n -> installNamed repo manifest n scope
```

A name the chooser returns that the manifest does not list fails exactly as a typed name would,
with `KitItemNotFound`. An exception thrown by the chooser propagates; say so in the field's
Haddock.

Add tests to `commandTests`, each inside `withPreparedKitHome`:

4. "install with no name installs what the chooser returns": create an `IORef [Text]`; let
   `config = testConfig & #chooseItem .~ Just (\m -> do writeIORef seen (map (view #name) (m ^. #skills) ++ map (view #name) (m ^. #agents)); pure (Just "demo"))`.
   `runKitCommand config (KitInstall Nothing UserScope)` returns `Right ()`; the Claude copy of
   `demo`'s `SKILL.md` exists; `readIORef seen` is `["demo", "reviewer"]` (the chooser saw the
   whole manifest).
5. "a cancelled choice installs nothing and succeeds": the chooser returns `Nothing`;
   `runKitCommand` returns `Right ()`; `$HOME/.config/testkit/agents/.claude/skills/demo` does not
   exist; and `try @ExitCode (runKit config (KitInstall Nothing UserScope))` returns `Right ()`.
6. "a chosen name the manifest lacks is KitItemNotFound": the chooser returns `Just "nope"`;
   the result is `Left (KitItemNotFound "nope")`.

Import `Data.IORef` in the test module and `KitItemNameRequired` via `KitError (..)` (already
imported).

Documentation and records, in the same commit:

In `docs/user/kit.md`, `## Command Adapter`: change the example to
`execParser (info (Kit.kitCommandParser myKitConfig <**> helper) mempty)`, change the built-in
parser listing to `kit install [NAME] [--project]`, and add a subsection "Choosing an item
interactively" explaining `chooseItem`, what the chooser receives, what `Nothing` means, what
happens without a chooser (the error text above), and that `baikai-kit` ships no picker. Show a
sketch that uses the smart constructor and names a tool-owned function, for example:

```haskell
myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { chooseItem = Just pickWithFzf
    }

-- Owned by the tool: render the manifest however it likes and return the
-- chosen name, or Nothing when the user cancels.
pickWithFzf :: KitManifest -> IO (Maybe Text)
```

Bump `generated.at` and append a dated entry to `docs/user/log.md`.

In the root `CHANGELOG.md` under `## [Unreleased]`: an `### Added` bullet beginning
`baikai-kit:` for `KitConfig.chooseItem`, `KitItemNameRequired`, `kit install` with no name, and
`Eq` on `KitCommand`; a `### Changed` bullet beginning `baikai-kit:` marked `__Breaking__`:
`KitInstall` takes `Maybe Text`, `kitCommandParser` takes the `KitConfig` (migration:
`kitCommandParser` becomes `kitCommandParser myKitConfig`), and `KitError` gains a constructor.

Write a new ADR in `docs/adr/` with the next unused number (list the directory first; other
plans in this initiative add ADRs too) titled "The kit engine ships no terminal UI; interactive
choice is injected through KitConfig". Context: IR-6 and the three consumers' copies.
Decision: `baikai-kit` never depends on fzf or any terminal-UI library and ships no default
picker; any interactive step is a function field on `KitConfig` that receives engine data and
returns a plain value; everything around the choice stays in the engine. Consequences: consumers
own presentation, the engine owns the flow, and new interactive steps follow the same pattern.
Add its row to `docs/adr/README.md`.

Acceptance: `cabal test baikai-kit` passes; the validators exit 0; `cabal build all --enable-tests`
succeeds (it compiles `baikai-smoke`, whose CAP-21 Shape uses record-update syntax on
`kitConfig` and is unaffected by the new field).


## Concrete Steps

All commands run from the repository root.

```bash
grep -n "projectRoot\|^kitConfig\|instance Show KitConfig" baikai-kit/src/Baikai/Kit/Config.hs
cabal build baikai-kit
cabal test baikai-kit
```

After Milestone 2 the output includes:

```text
  Command
    install parses with and without a name:                               OK
    install help names the tool's project directory:                      OK
    install with no name and no chooser is a KitItemNameRequired error:   OK
    install with no name installs what the chooser returns:               OK
    a cancelled choice installs nothing and succeeds:                     OK
    a chosen name the manifest lacks is KitItemNotFound:                  OK
```

Then:

```bash
grep -rn "fzf" baikai-kit/baikai-kit.cabal baikai-kit/src
okf validate docs/user --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
cabal build all --enable-tests
```

The first `grep` prints nothing: the engine has no terminal-UI dependency.

Commit after each milestone with the trailers:

```text
feat(kit)!: let kit install choose an item through a caller-supplied chooser

MasterPlan: docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md
ExecPlan: docs/plans/80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md
Intention: intention_01m379fwwker59e1mjhb3k3hfa
```


## Validation and Acceptance

IR-6's acceptance criteria and how each is shown:

1. Test 4: `kit install` with no name calls the configured chooser with the whole manifest and
   installs what it returns, using a stub chooser and a local kit, with no fzf binary.
2. Test 5 (a cancelled choice installs nothing and exits 0) and test 3 (no chooser produces
   `KitItemNameRequired`, whose message names `NAME`).
3. Test 1 compiles only with `Eq` on `KitCommand`; test 2 shows help naming `.testkit/agents`.
4. and 5. (rei and okf can delete their copies) are satisfied by the API shape: a consumer's
   whole kit integration becomes a `KitConfig` built with `kitConfig` plus `chooseItem`,
   `kitCommandParser config`, and `runKit config`. Those deletions are made in
   `mori://shinzui/rei` and `mori://shinzui/okf` after they adopt `baikai-kit ^>=0.3`, outside
   this repository.


## Idempotence and Recovery

All edits are to source, tests, and documentation and can be repeated. Tests run in temporary
directories. If Milestone 1 is committed alone, the build is consistent: `kit install` without a
name returns `KitItemNameRequired` until Milestone 2 wires the chooser.


## Interfaces and Dependencies

The test suite gains a dependency on `optparse-applicative` (already a library dependency, bound
`^>=0.19`). No library dependency changes.

At the end of this plan:

```haskell
-- Baikai.Kit.Config
data KitConfig = KitConfig
  { toolName :: !Text,
    repoUrl :: !Text,
    providers :: ![AgentAssetProvider],
    projectRoot :: !(IO FilePath),
    chooseItem :: !(Maybe (KitManifest -> IO (Maybe Text)))
  }
kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig   -- chooseItem = Nothing

-- Baikai.Kit.Error
data KitError = … | KitItemNameRequired

-- Baikai.Kit.Command
data KitCommand
  = KitList
  | KitInstall !(Maybe Text) !KitScope
  | KitUpdate !(Maybe Text) !OverwritePolicy
  | KitUninstall !Text !KitScope
  | KitStatus
  deriving stock (Eq, Show)

kitCommandParser :: KitConfig -> Parser KitCommand
```

`runKitCommand` and `runKit` keep their signatures. A later plan,
`docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md`, will add an output
format field to `KitList`, `KitUpdate`, and `KitStatus`; it must keep `Eq` and this parser's
signature.
