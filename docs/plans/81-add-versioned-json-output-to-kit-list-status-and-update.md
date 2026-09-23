---
id: 81
slug: add-versioned-json-output-to-kit-list-status-and-update
title: "Add versioned JSON output to kit list, status, and update"
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
      at: 2026-09-23T16:14:22Z
      mode: "implement"
      note: "Milestones 1-3 implemented; baikai-kit 0.3.0.0 prepared"
---

# Add versioned JSON output to kit list, status, and update

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`kit list`, `kit status`, and `kit update` print text laid out for a terminal. A script, an
agent, or another tool that wants the same facts — which items the kit offers, which are
installed where, which are outdated or edited, what an update did — must scrape those columns,
or read the cached `kit.json` directly and bypass the engine's manifest-version and path checks.

After this change each of the three verbs accepts `--json` and prints exactly one JSON document
on stdout: `{"formatVersion": 1, "document": "kit-status", …}`. Warnings (a stale cache, an
unreachable repository, the notice printed after a first clone) never reach stdout in that mode;
they go to stderr, and the document itself records whether the upstream was consulted. The
shapes are a public, versioned contract, pinned by golden tests over a fixture that covers
skills and agents, both scopes, both providers, and every status condition; library callers get
the identical shape from exported encoder functions without running the command.

The last milestone prepares the release that carries this initiative: `baikai-kit 0.3.0.0`.

You can see it working with `cabal test baikai-kit`, and by hand with any consumer:
`mytool kit status --json | jq '.items[] | select(.conditions | index("modified"))'`.

This plan implements [IR-9](../improvement-requests/add-machine-readable-kit-list-and-status-output.md)
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-9`). It is EP-4 of
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md)
and must start only after
[docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md](79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md)
and
[docs/plans/80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md](80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md)
are complete (and therefore also
[docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md](78-resolve-kit-project-scope-from-a-configurable-project-root.md)).


## Progress

- [x] (2026-09-23 16:30Z) Milestone 1: add `installedCopies` to `Baikai.Kit.Status`; add the `Baikai.Kit.Json` module with `kitJsonFormatVersion`, `listDocument`, `statusDocument`, and `updateDocument`; register it in the cabal file and the umbrella module.
- [x] (2026-09-23 16:45Z) Milestone 1: build the golden fixture, the stdout-capture helper, the normaliser, and the accept mode; generate and review `test/golden/{list,status,update}.json`; `cabal test baikai-kit` green.
- [x] (2026-09-23 16:45Z) Milestone 2: add `OutputFormat` and `--json` to `list`, `status`, and `update`; route JSON-mode warnings and the clone notice to stderr; update the quoted existing call sites; stdout-discipline tests green (72 tests, three consecutive runs).
- [x] (2026-09-23 17:10Z) Milestone 3: document the three documents and the format version in `docs/user/kit.md`; write ADR 0024; changelog entries.
- [x] (2026-09-23 17:30Z) Milestone 3: prepare `baikai-kit 0.3.0.0` — cabal version, changelog section, README version table, CAP-21 record and log; validators, `doc-shapes`, and `cabal build all --enable-tests` green; `cabal test all` green for every keyless suite (see Surprises for `baikai-smoke` and `baikai-agent`).


## Surprises & Discoveries

- tasty's console reporter writes to stdout from its own thread, and prints the previous
  test's `OK` and the current test's name at about the moment the current test starts (earlier
  runs show a test's stderr interleaved mid-word with the reporter's `OK`). A capture that
  redirects stdout immediately could record the reporter's text. `captureStdout` therefore
  pauses 200 ms before redirecting; the reporter then blocks on the running test's result, so
  nothing else writes to stdout during the capture. Three consecutive full runs were clean.
- `kit-list` lists only what the manifest offers, so an installed item the manifest has
  dropped (the fixture's `delta`) appears in `kit-status` as `delisted` but not in `kit-list`.
  That is what `kit list` has always meant; the user guide says so.
- `Baikai.Prelude` re-exports lens's `.=` and generic-lens's `field`, which clash with aeson's
  `.=` and a test helper named `field`. `Baikai.Kit.Json` imports the prelude
  `hiding ((.=))`, and the test helper is named `jsonKey`.
- `baikai-kit/baikai-kit.cabal` was reflowed (single-space `field: value`, lower-case
  `ghc`, trailing-comma dependency lists) in commit `044ab1b` when
  `docs/plans/80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md` formatted
  it. That is the repository's current formatter: the `treefmt` pre-commit hook rejects the old
  layout whenever the file is staged (`Error: unexpected changes detected, --fail-on-change is
  enabled`). Other packages' `.cabal` files keep the old layout only because they have not been
  touched since the formatter changed. The reflowed layout is kept.
- `cabal test all` at release time: every suite passed except two outside this change.
  `baikai-smoke` (the live suite, which runs batch CLI cases whenever `claude` is on `PATH`)
  failed on a live `claude-haiku-4-5-20251001` call; it does not import `Baikai.Kit` (only the
  separate `doc-shapes` suite does, and it passed). `baikai-agent-test` reported 2 of 116
  failures under the parallel `cabal test all` load and passed 116/116 when rerun alone
  (`cabal test baikai-agent`), consistent with its timing-sensitive process tests; it does not
  depend on `baikai-kit`.
- The release follows the repository's release commits (for example
  `chore(release): baikai-effectful 0.4.0.2`), which also bump the package's row in the
  `README.md` version table; that row now reads 0.3.0.0.
- A golden was checked to bite: renaming `"modified"` to `"edited"` in `status.json` fails
  "kit-status document matches the golden" and nothing else.


## Decision Log

- Decision: Expose the JSON shapes as explicit encoder functions returning `Data.Aeson.Value`
  (`listDocument`, `statusDocument`, `updateDocument`) in a new module `Baikai.Kit.Json`, not as
  `ToJSON` instances on the Haskell types.
  Rationale: the JSON is a versioned public contract; a generic `ToJSON` instance would change
  the contract silently whenever a Haskell field is renamed. IR-9 allows either form. Explicit
  encoders keep the key names in one reviewed place and give library callers the same shape as
  the command.
  Date: 2026-09-23

- Decision: Every document carries `formatVersion` (an integer, `1` in this release) and
  `document` (`"kit-list"`, `"kit-status"`, or `"kit-update"`). Adding a key does not change
  `formatVersion`; removing or renaming a key, or changing a value's meaning, increments it.
  Rationale: IR-9 asks for a top-level format version; the rule tells consumers what they may
  rely on and tells maintainers when to bump.
  Date: 2026-09-23

- Decision: Every documented key is always present; an absent value is `null`, never an omitted
  key.
  Rationale: consumers written in `jq` or shell can test a key without first testing for its
  existence, and goldens pin presence.
  Date: 2026-09-23

- Decision: `kit-status` lists one entry per installed copy — per item, scope, and provider — and
  never aggregates across providers; entries are sorted by name, kind, scope, and provider.
  Rationale: IR-9 asks for per-provider detail. `collectStatus` already returns unaggregated rows
  (the table aggregates only when rendering), but in filesystem listing order, which is not
  stable across machines, so the encoder sorts.
  Date: 2026-09-23

- Decision: In JSON mode a failed command prints nothing on stdout; `runKit` still prints
  `Error: …` to stderr and exits 1.
  Rationale: a consumer can rely on "exit 0 means stdout is a complete document". Emitting an
  error document would be a second contract for no stated need.
  Date: 2026-09-23

- Decision: Golden files hold compact JSON as written by `Data.Aeson.encode`, and tests compare
  decoded values, not bytes.
  Rationale: aeson's key order is not part of the contract; comparing `Value`s pins content
  without pinning formatting, and avoids a new pretty-printing dependency. Review goldens with
  `jq . < file`.
  Date: 2026-09-23

- Decision: Preparing `baikai-kit 0.3.0.0` (cabal version, changelog section, capability record)
  is this plan's last milestone; uploading to Hackage is not part of it.
  Rationale: this is the final plan of the initiative that makes the breaking changes; publishing
  is a separate, deliberate act by the maintainer.
  Date: 2026-09-23

- Decision: Keep the `` `baikai-kit`: `` prefix on the bullets moved under
  `## [baikai-kit 0.3.0.0]`, rather than dropping it as Milestone 3 first said.
  Rationale: the earlier package sections the plan meant to match (for example
  `## [baikai-kit 0.2.0.0]`) keep that prefix, so keeping it is what matches.
  Date: 2026-09-23

- Decision: Implement the command's JSON branches (Milestone 2) before generating the goldens,
  and commit Milestones 1 and 2 together.
  Rationale: test 10 compares the command's output with the encoder's golden; with both in
  place a single accept run produced goldens that the command and the encoders agree on.
  Date: 2026-09-23


## Outcomes & Retrospective

IR-9's acceptance criteria hold. `kit list --json`, `kit status --json`, and
`kit update --json` print one versioned document each, written by explicit encoders in the new
`Baikai.Kit.Json` and pinned by `baikai-kit/test/golden/{list,status,update}.json` over a
fixture that covers every status condition, both scopes, both providers, and both kinds. The
command's status document equals the encoder's. Stdout is one document under a stale cache and
an unreachable repository, empty when `list` cannot clone or `update` cannot pull, and free of
the first-clone notice. `docs/user/kit.md` documents every key and the `formatVersion` rule, and
ADR 0024 records the contract. The suite has 72 tests.

`baikai-kit 0.3.0.0` is prepared (cabal version, changelog section, README row, CAP-21) and not
uploaded; that is the maintainer's step. After uploading, poll the Hackage index before
concluding that a consumer's resolver error is a bad bound: the index lags an upload.

Lessons: a test that captures stdout in a `tasty` suite shares the handle with tasty's
reporter thread, and has to let the reporter finish first. Writing the command path before
accepting goldens let one accept run serve both the encoder and the command tests.


## Context and Orientation

The repository root is the directory containing `cabal.project`. `baikai-kit`, in `baikai-kit/`,
is a Haskell library that a command-line tool embeds to get a `kit` subcommand: it clones a
git-hosted *kit* (a repository with a `kit.json` manifest listing skills and agents) into
`~/.cache/<tool>/kit`, and installs, updates, reports on, and uninstalls those items in the
directories where Claude Code and Codex discover them. Sources are in `baikai-kit/src/Baikai/Kit/`;
the test suite is the single file `baikai-kit/test/Main.hs` (`tasty`, tests run one at a time,
so a test may temporarily redirect process-wide handles or environment variables and restore
them). The package uses `GHC2024` with `DuplicateRecordFields`, `OverloadedLabels`, and
`OverloadedStrings`, requires `deriving stock (…)`, and makes incomplete pattern matches an
error. `Baikai.Prelude` provides `lens` operators and generic-lens labels (`row ^. #name`).
Record fields never carry type-name prefixes. `aeson` (`^>=2.2`) is already a library
dependency.

Terms. A *provider* is `InteractiveClaude` or `InteractiveCodex` (type `AgentAssetProvider`),
and `providerLabel` in `Baikai.Kit.Config` renders them `"claude"` and `"codex"`. A *scope* is
`UserScope` or `ProjectScope`, rendered `"user"` and `"project"` by `scopeLabel`. Each item is
installed once per provider: an *installed copy* is one item at one scope for one provider. A
*sidecar* is the JSON file written beside each installed copy, read by `readSidecar` in
`Baikai.Kit.Sidecar` (field `version :: Maybe Text` among others).

The state after the plans this one depends on:

From `docs/plans/78-…` (EP-1): `KitConfig` (in `Baikai.Kit.Config`) has fields `toolName`,
`repoUrl`, `providers`, `projectRoot :: !(IO FilePath)`, and (from EP-3) `chooseItem`; it is
built with `kitConfig toolName repoUrl providers`, and every project-scope path comes from
`providerAgentsBase config provider scope`. Never call `getCurrentDirectory` for project scope.

From `docs/plans/79-…` (EP-2): in `Baikai.Kit.Status`,

```haskell
data KitCondition
  = KitUnknown | KitDelisted | KitUpstreamRefused | KitOutdated
  | KitChangedUpstream | KitLocallyModified | KitLocalEditsUnknown
conditionLabel :: KitCondition -> Text
  -- "unknown", "delisted", "refused", "outdated", "changed-upstream", "modified", "edits-unknown"

data StatusRow = StatusRow
  { name :: !Text, kind :: !Text, scope :: !Text, providers :: !Text,
    installedVersion :: !(Maybe Text), latestVersion :: !(Maybe Text),
    conditions :: ![KitCondition] }   -- empty means up to date

data UpstreamAvailability = UpstreamReady | UpstreamStale !Text | UpstreamUnavailable !KitError
data StatusReport = StatusReport { upstream :: !UpstreamAvailability, rows :: ![StatusRow] }
kitStatus :: KitConfig -> IO StatusReport
```

The rows `collectStatus` returns are one per installed copy: `providers` holds a single label
such as `"claude"`. Only `renderStatusTable` merges them. `scanInstalled` (private) walks each
provider's skill and agent directories for a scope and returns
`(provider, baseDir, name, KitItemKind)`.

From `docs/plans/80-…` (EP-3): in `Baikai.Kit.Command`,

```haskell
data KitCommand
  = KitList
  | KitInstall !(Maybe Text) !KitScope
  | KitUpdate !(Maybe Text) !OverwritePolicy
  | KitUninstall !Text !KitScope
  | KitStatus
  deriving stock (Eq, Show)
kitCommandParser :: KitConfig -> Parser KitCommand
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())
runKit :: KitConfig -> KitCommand -> IO ()
```

Check all three are in place before starting:

```bash
grep -n "projectRoot" baikai-kit/src/Baikai/Kit/Config.hs
grep -n "KitLocallyModified\|conditionLabel" baikai-kit/src/Baikai/Kit/Status.hs
grep -n "deriving stock (Eq, Show)\|kitCommandParser ::" baikai-kit/src/Baikai/Kit/Command.hs
```

Each prints at least one line; if not, the corresponding plan is incomplete.

`runKitCommand` (in `baikai-kit/src/Baikai/Kit/Command.hs`) has a local helper `withRepo` that
calls `ensureKitRepo`, prints a warning to stderr when the refresh failed and the cache is used
as-is (`RepoStale`), prints `Fetched <tool>-kit.` **to stdout** after a first clone
(`RepoCloned`), and passes the `KitRepo` (fields `dir` and `refresh`) on. The `KitStatus` branch
prints notes about the upstream to stderr (`noteUpstream`) and the table to stdout. The
`KitUpdate` branch calls `updateKit :: KitConfig -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)`,
where (in `Baikai.Kit.Install`)

```haskell
data UpdateReport = UpdateReport
  { refresh :: !(Maybe RepoRefresh),     -- RepoCloned | RepoPulled | RepoStale Text
    updated :: ![(Text, KitScope)],
    skipped :: ![(Text, KitScope)] }     -- skipped only because of local edits
```

and `reinstallPresent` is its network-free half, which returns `refresh = Nothing`. `updateKit`
treats a failed pull as the error `KitPullFailed`. `readSidecar` prints a parse warning to stderr
(never stdout), which is acceptable in JSON mode.

Relevant ADRs:
[docs/adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md](../adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md)
— text leaving the process is UTF-8 bytes, never locale-encoded, so write the document with
`Data.ByteString.Lazy.hPut stdout (Data.Aeson.encode doc <> "\n")`, not `putStrLn`.
[docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md)
— every JSON-mode path returns a value from `runKitCommand`; only `runKit` exits.
[docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md](../adr/0016-deprecated-names-are-removed-at-the-next-major.md)
— at release, `grep -rn 'Removed in .* 0.3.0.0' baikai-kit/src` must be empty.
[docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md](../adr/0017-a-documented-example-compiles-in-the-test-suite.md)
— CAP-21's Shape block is compiled by `cabal test baikai-smoke:test:doc-shapes`; this plan does
not change the Shape, but the suite is part of the release gate. ADRs are plain Markdown files
with `title`, `status`, and `date` frontmatter indexed in `docs/adr/README.md`.

The test suite's helper `withPreparedKitHome :: (FilePath -> FilePath -> IO a) -> IO a` creates a
temporary `HOME` and a fake cache at `$HOME/.cache/testkit/kit` containing a `.git` directory (so
the refresh always fails and the cache is used as-is, which `kitStatus` reports as
`UpstreamStale`), `skills/demo/SKILL.md`, `agents/reviewer.md`, and a `kit.json` listing both,
and passes `home` and `cache` to the action. `testConfig` is
`kitConfig "testkit" "file:///not-used" [InteractiveClaude, InteractiveCodex]`. Existing tests
write manifests as `ByteString` literals such as `manifestJson`; follow that style. Test files
are read relative to the package directory (`test/fixtures/…`), because `cabal test` runs the
suite from `baikai-kit/`.

The root `CHANGELOG.md` holds every package's history, newest first, with sections headed
`## [<package> <version>] - <date>` and subsections `### Added`, `### Changed`, and so on. Earlier
plans in this initiative added bullets under `## [Unreleased]` that begin `baikai-kit:`.


## Plan of Work

### Milestone 1: encoders and goldens

At the end of this milestone the three documents exist as library functions and are pinned by
golden tests against a fixture that covers every condition.

In `baikai-kit/src/Baikai/Kit/Status.hs`, add and export a description of where things are
installed, built on the existing `scanInstalled` and `readSidecar`:

```haskell
-- | One item at one scope for one provider, and where it is.
data InstalledCopy = InstalledCopy
  { name :: !Text,
    kind :: !KitItemKind,
    scope :: !KitScope,
    provider :: !AgentAssetProvider,
    path :: !FilePath,          -- the skill directory or the agent file
    version :: !(Maybe Text)    -- from the sidecar; Nothing without one
  }
  deriving stock (Eq, Generic, Show)

installedCopies :: KitConfig -> IO [InstalledCopy]
```

`path` is `baseDir </> skillTargetPath provider InteractiveProjectScope (Text.unpack name)` for a
skill and `baseDir </> agentTargetPath provider InteractiveProjectScope (Text.unpack name)` for an
agent (both functions come from `Baikai.AgentAssets` and are already imported there; the
`InteractiveProjectScope` argument selects the relative layout, which is the same below any base).
Scan `[UserScope, ProjectScope]`.

Create `baikai-kit/src/Baikai/Kit/Json.hs`, exporting:

```haskell
module Baikai.Kit.Json
  ( kitJsonFormatVersion,
    listDocument,
    statusDocument,
    updateDocument,
  )
where

kitJsonFormatVersion :: Int
kitJsonFormatVersion = 1

listDocument :: UpstreamAvailability -> KitManifest -> [InstalledCopy] -> Value
statusDocument :: StatusReport -> Value
updateDocument :: UpdateReport -> Value
```

Build each with `Data.Aeson.object` and `(.=)`. The shapes, which are the contract, are:

```json
{
  "formatVersion": 1,
  "document": "kit-list",
  "upstream": {"state": "ready", "detail": null},
  "items": [
    {
      "name": "demo",
      "kind": "skill",
      "description": "Demo skill",
      "version": "0.1.0",
      "installed": [
        {"scope": "user", "provider": "claude", "version": "0.1.0", "path": "/home/me/.config/testkit/agents/.claude/skills/demo"}
      ]
    }
  ]
}
```

`items` lists the manifest's skills in manifest order, then its agents in manifest order;
`installed` holds the copies whose name and kind match, sorted by scope (user before project)
then provider (claude before codex), and is `[]` when the item is not installed. `upstream`
encodes `UpstreamReady` as `{"state": "ready", "detail": null}`, `UpstreamStale t` as
`{"state": "stale", "detail": t}`, and `UpstreamUnavailable e` as
`{"state": "unavailable", "detail": renderKitError e}`; write one private `upstreamValue` and
use it in both list and status.

```json
{
  "formatVersion": 1,
  "document": "kit-status",
  "upstream": {"state": "stale", "detail": "fatal: …"},
  "items": [
    {
      "name": "demo",
      "kind": "skill",
      "scope": "user",
      "provider": "claude",
      "installedVersion": "0.1.0",
      "latestVersion": "0.2.0",
      "conditions": ["outdated", "modified"],
      "upToDate": false
    }
  ]
}
```

`items` is `report ^. #rows` sorted by `(name, kind, scope, providers)`, one entry per row, with
`provider` taken from the row's `providers` field; `conditions` is `map conditionLabel`;
`upToDate` is `null conditions`.

```json
{
  "formatVersion": 1,
  "document": "kit-update",
  "refresh": "pulled",
  "updated": [{"name": "reviewer", "scope": "user"}],
  "skipped": [{"name": "demo", "scope": "user", "reason": "locally-modified"}]
}
```

`refresh` is `"cloned"`, `"pulled"`, `"stale"`, or `null` (for `Nothing`); `updated` and
`skipped` keep the report's order.

Add `Baikai.Kit.Json` to `exposed-modules` in `baikai-kit/baikai-kit.cabal` and re-export it
from `baikai-kit/src/Baikai/Kit.hs` like the other modules.

In `baikai-kit/test/Main.hs`, add a test group `jsonTests` with these helpers:

- `captureStdout :: IO a -> IO (a, BS.ByteString)`: with `withSystemTempFile` (from
  `System.IO.Temp`, package `temporary`, already a test dependency), `hFlush stdout`, save a
  duplicate with `hDuplicate stdout`, point stdout at the file with `hDuplicateTo fileHandle stdout`,
  run the action, then in a `finally` flush, restore with `hDuplicateTo saved stdout`, and close
  `saved` and the file handle; then read the file. `hDuplicate` and `hDuplicateTo` come from
  `GHC.IO.Handle`.
- `normalise :: [(Text, Text)] -> Value -> Value`: walk the value and, in every string,
  replace each given prefix (the temporary home with `"$HOME"`, the temporary project root with
  `"$PROJECT"`) and replace a non-null `upstream.detail` with `"<detail>"` (git's message names
  temporary paths and varies by git version).
- `golden :: FilePath -> Value -> Assertion`: when the environment variable
  `BAIKAI_KIT_ACCEPT_GOLDEN` is set, write `Aeson.encode value` to
  `"test/golden" </> file` (creating the directory) and pass; otherwise decode that file and
  assert it equals `value`, failing with both values shown when it does not.

Build the fixture `withStatusFixture :: (FilePath -> FilePath -> KitConfig -> IO a) -> IO a`
inside `withPreparedKitHome`. Create a project directory in the temporary area (a sibling of
`home`) and let `config = testConfig & #projectRoot .~ pure proj`. Write kit sources in the cache
for skills `alpha`, `beta`, `gamma`, `delta`, `epsilon` (each `skills/<name>/SKILL.md`) and agents
`reviewer` and `planner` (each `agents/<name>.md`), and a manifest listing all seven at version
`0.1.0`. Install `alpha`, `gamma`, `epsilon`, and `reviewer` at user scope, and `beta`, `delta`,
and `planner` at project scope, with `installItem config name scope`. Then create each condition:

- `alpha`: delete the Codex copy's sidecar (`$HOME/.agents/skills/alpha/.testkit-kit.json`); its
  Claude row stays up to date and its Codex row becomes `unknown`.
- `beta`: bump its version to `0.2.0` in the manifest → `outdated`.
- `gamma`: write new content to the cached `skills/gamma/SKILL.md` → `changed-upstream`.
- `delta`: remove it from the manifest → `delisted`.
- `epsilon`: create a directory outside the cache containing `secret.txt`, link it as
  `skills/epsilon/sub` in the cache with `createDirectoryLink`, and list
  `["SKILL.md", "sub/secret.txt"]` as its files in the manifest → `refused`.
- `reviewer`: overwrite the Claude copy (`$HOME/.config/testkit/agents/.claude/agents/reviewer.md`)
  → its Claude row is `modified`, its Codex row stays up to date.
- `planner`: read the Claude copy's sidecar
  (`<proj>/.testkit/agents/.claude/agents/planner.testkit-kit.json`) with `readSidecar`, set
  `installedFiles` and `installedHash` to `Nothing`, and write it back with `Aeson.encode` →
  `edits-unknown`.

Write the final manifest last. The golden tests:

1. "kit-status document matches the golden": in the fixture, compute
   `statusDocument <$> kitStatus config` (the `--json` command path arrives in Milestone 2 and
   is compared with the same golden by test 10), normalise, and compare with `status.json`. Before accepting the golden, check by eye (with
   `jq . < baikai-kit/test/golden/status.json`) that it contains `unknown`, `outdated`,
   `changed-upstream`, `delisted`, `refused`, `modified`, `edits-unknown`, and entries with
   `"upToDate": true`, entries for both scopes and both providers, and both kinds.
2. "kit-list document matches the golden": `manifest <- loadManifest cache`,
   `copies <- installedCopies config`, `listDocument (UpstreamStale "x") manifest copies`,
   normalise, compare with `list.json`.
3. "kit-update document matches the golden": in a plain `withPreparedKitHome`, install `demo` and
   `reviewer` at user scope, edit the Claude copy of `demo`, run
   `reinstallPresent testConfig cache manifest Nothing KeepLocalEdits`, and compare
   `updateDocument` of the report with `update.json` (expect `refresh` null, `updated`
   `reviewer`, `skipped` `demo` with reason `locally-modified`). In the same test assert that
   `updateDocument (report & #refresh .~ Just RepoPulled)` has `"refresh": "pulled"`.
4. "every document names its format version": each of the three values has
   `formatVersion == kitJsonFormatVersion` and the expected `document`.

Generate the goldens once, inspect them, then run again without the variable:

```bash
BAIKAI_KIT_ACCEPT_GOLDEN=1 cabal test baikai-kit
cabal test baikai-kit
```

Commit `baikai-kit/test/golden/*.json` with the code.

Acceptance: `cabal test baikai-kit` passes without the variable set.

### Milestone 2: the `--json` flag and stdout discipline

At the end of this milestone the three verbs accept `--json`, print exactly one document on
stdout, and send every warning to stderr.

In `baikai-kit/src/Baikai/Kit/Command.hs`, add and export

```haskell
data OutputFormat = HumanOutput | JsonOutput
  deriving stock (Eq, Show)
```

and give `KitList`, `KitStatus`, and `KitUpdate` a trailing `!OutputFormat` field, keeping
`deriving stock (Eq, Show)`. In the parser add a switch
`flag HumanOutput JsonOutput (long "json" <> help "Print one JSON document on stdout")` to
`list`, `status`, and `update` only; the default command becomes `pure (KitList HumanOutput)`.
Keep `kitCommandParser :: KitConfig -> Parser KitCommand`.

In `runKitCommand`: give `withRepo` the format; in `JsonOutput` it prints the clone notice
(`Fetched <tool>-kit.`) to stderr instead of stdout, and also returns the
`UpstreamAvailability` it observed (`RepoStale err` → `UpstreamStale err`, otherwise
`UpstreamReady`) so the list document can record it. Then:

- `KitList JsonOutput`: load the manifest, call `installedCopies config`, and emit
  `listDocument availability manifest copies`.
- `KitStatus JsonOutput`: `report <- kitStatus config`, keep the stderr notes, and emit
  `statusDocument report` instead of the table.
- `KitUpdate n policy JsonOutput`: on `Right report` emit `updateDocument report`.
- The `HumanOutput` branches behave exactly as today.

`emit :: Value -> IO (Either KitError ())` writes `Data.ByteString.Lazy.hPut stdout (Aeson.encode v <> "\n")`
and returns `Right ()`. On any `Left`, nothing has been written to stdout.

Update the existing call sites in `baikai-kit/test/Main.hs`: in "kit status offline on a fresh
HOME exits 0", `runKit config KitStatus` becomes `runKit config (KitStatus HumanOutput)`; in
"install parses with and without a name", `parse [] @?= Just KitList` becomes
`parse [] @?= Just (KitList HumanOutput)`. Add to `jsonTests`:

5. "status --json parses as one document when the cache is stale": inside `withPreparedKitHome`,
   install `demo`, capture `runKitCommand testConfig (KitStatus JsonOutput)`; the result is
   `Right ()`, `Aeson.eitherDecodeStrict'` of stdout succeeds, and `upstream.state` is `"stale"`.
6. "status --json parses as one document when the repository is unreachable": with a fresh
   temporary `HOME` (set and restored as the existing offline test does) and
   `repoUrl = "file:///nonexistent-kit"`, the same checks hold with `upstream.state`
   `"unavailable"` and `items` `[]`.
7. "list --json writes nothing to stdout when the repository is unreachable": same setup; the
   result is `Left (KitCloneFailed …)` and the captured stdout is empty.
8. "list --json keeps the first-clone notice off stdout": create a real kit repository in a
   temporary directory — write `kit.json` (use `manifestJson`) and the two sources, then run
   `git init`, `git add .`, and
   `git -c user.name=test -c user.email=test@example.com commit -m kit` there with
   `readProcessWithExitCode` from `System.Process` (add `process` to the test suite's
   `build-depends`) — and use `repoUrl = "file://" <> Text.pack repoDir` with a fresh `HOME`.
   Capture `runKitCommand config (KitList JsonOutput)`; stdout decodes, `upstream.state` is
   `"ready"`, and the item names are `["demo", "reviewer"]`. This test needs `git` on `PATH`, as
   the kit itself does.
9. "update --json writes nothing to stdout when the pull fails": inside `withPreparedKitHome`
   (whose fake `.git` makes the pull fail), capture
   `runKitCommand testConfig (KitUpdate Nothing KeepLocalEdits JsonOutput)`; the result is
   `Left (KitPullFailed _)` and stdout is empty.
10. "the command and the encoder agree": in the golden fixture, capture
    `runKitCommand config (KitStatus JsonOutput)`, decode, normalise, and compare with the same
    `status.json` golden.
11. "--json parses on list, status, and update only": `parse ["status", "--json"]` is
    `Just (KitStatus JsonOutput)`, `parse ["update", "--json"]` is
    `Just (KitUpdate Nothing KeepLocalEdits JsonOutput)`, and `parse ["install", "demo", "--json"]`
    is `Nothing`.

Acceptance: `cabal test baikai-kit` passes.

### Milestone 3: documentation, decision record, and release preparation

At the end of this milestone the contract is documented, the decision is recorded, and the
package is ready to publish as `baikai-kit 0.3.0.0`.

In `docs/user/kit.md`, add a section `## Machine-Readable Output` that shows the three commands
with `--json`, the three document shapes above, the meaning of every key, the list of condition
strings (point to the status section for their meaning), the `formatVersion` rule from the
Decision Log, that stdout holds exactly one document on success and nothing on failure, that
warnings go to stderr, and that library callers get the same values from `listDocument`,
`statusDocument`, and `updateDocument` in `Baikai.Kit.Json`. Update the built-in parser listing
(`kit list [--json]`, `kit update [NAME] [--force] [--json]`, `kit status [--json]`). Bump
`generated.at` and append a dated entry to `docs/user/log.md`.

Write a new ADR in `docs/adr/` with the next unused number (list the directory first) titled
"Machine-readable kit output is a versioned contract written by explicit encoders, and stdout
carries only the document". Record the explicit-encoder choice, the `formatVersion` rule, the
always-present keys, the stdout rule, and ADR 0007's UTF-8 requirement. Add its row to
`docs/adr/README.md`.

In the root `CHANGELOG.md` under `## [Unreleased]`, add an `### Added` bullet beginning
`baikai-kit:` for `--json`, `Baikai.Kit.Json`, `OutputFormat`, `InstalledCopy`, and
`installedCopies`, and a `### Changed` bullet beginning `baikai-kit:` marked `__Breaking__`:
`KitList`, `KitStatus`, and `KitUpdate` gain an `OutputFormat` field.

Then prepare the release:

1. In `baikai-kit/baikai-kit.cabal`, change `version: 0.2.0.1` to `version: 0.3.0.0`.
2. In `CHANGELOG.md`, add a heading `## [baikai-kit 0.3.0.0] - <today's date>` directly below
   `## [Unreleased]`, and move every bullet beginning `baikai-kit:` from Unreleased under it,
   grouped into `### Added` and `### Changed`, dropping the `baikai-kit:` prefix to match the
   style of earlier package sections. Open the section with one sentence summarising the four
   improvement requests, and keep each `__Breaking__` marker and migration note.
3. Run `grep -rn 'Removed in .* 0.3.0.0' baikai-kit/src`; it must print nothing (ADR 0016).
4. In `docs/capabilities/kit-installer.md` (CAP-21), add `Baikai.Kit.Json` to `interface`;
   extend the test evidence's `proves` text with project-root resolution, local-edit and
   upstream-drift conditions with the status/update agreement, the chooser, and the golden JSON
   documents with stdout discipline; in the prose, mention the chooser, the project root, and
   `--json`; replace the Limits bullet that begins "Still marked `experimental`" with one that
   states the 0.3 surface changes (`KitConfig` fields and `kitConfig`, `KitCommand` shape and
   `kitCommandParser`'s argument, `KitCondition` replacing `KitState`) and that a consumer raising
   its bound fixes them at compiler-named call sites. Bump `generated.at` and append a dated
   `* **Update**: CAP-21 …` entry to `docs/capabilities/log.md`.

Acceptance: the whole keyless gate is green and the validators pass (Concrete Steps).
Publishing to Hackage is not part of this plan; when the maintainer publishes, the index can lag
an upload by some minutes, and a resolver error immediately afterwards is that lag, not a bad
bound.


## Concrete Steps

All commands run from the repository root.

```bash
grep -n "projectRoot" baikai-kit/src/Baikai/Kit/Config.hs
grep -n "KitLocallyModified\|conditionLabel" baikai-kit/src/Baikai/Kit/Status.hs
grep -n "deriving stock (Eq, Show)\|kitCommandParser ::" baikai-kit/src/Baikai/Kit/Command.hs
cabal build baikai-kit
BAIKAI_KIT_ACCEPT_GOLDEN=1 cabal test baikai-kit
jq . < baikai-kit/test/golden/status.json
cabal test baikai-kit
```

After Milestone 2 the output includes:

```text
  JSON
    kit-status document matches the golden:                               OK
    kit-list document matches the golden:                                 OK
    kit-update document matches the golden:                               OK
    every document names its format version:                              OK
    status --json parses as one document when the cache is stale:         OK
    status --json parses as one document when the repository is unreachable: OK
    list --json writes nothing to stdout when the repository is unreachable: OK
    list --json keeps the first-clone notice off stdout:                  OK
    update --json writes nothing to stdout when the pull fails:           OK
    the command and the encoder agree:                                    OK
    --json parses on list, status, and update only:                       OK
```

For Milestone 3:

```bash
grep -rn 'Removed in .* 0.3.0.0' baikai-kit/src
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
cabal test baikai-smoke:test:doc-shapes
cabal build all --enable-tests
cabal test all
```

The `grep` prints nothing; every other command exits 0.

Commit after each milestone with the trailers; the release commit uses the `chore(release)` type
the repository already uses:

```text
chore(release): baikai-kit 0.3.0.0

MasterPlan: docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md
ExecPlan: docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md
Intention: intention_01m379fwwker59e1mjhb3k3hfa
```


## Validation and Acceptance

IR-9's acceptance criteria and how each is shown:

1. Tests 1–3 pin the list, status, and update documents against goldens built from a fixture
   covering skills and agents, both scopes, both providers, and each status condition (`unknown`,
   `delisted`, `refused`, `outdated`, `changed-upstream`, `modified`, `edits-unknown`, and up to
   date). Test 10 shows the command emits the same document the encoder produces.
2. Tests 5 and 6 show `--json` stdout parses as a single JSON document when the cache is stale
   and when the repository is unreachable; tests 7–9 show failures and the clone notice never
   reach stdout.
3. `docs/user/kit.md` documents every field and the format version.

By hand with a consumer built on this release:

```bash
mytool kit status --json | jq '.formatVersion, (.items | length)'
```

prints `1` and the number of installed copies, with any warning on the terminal via stderr.


## Idempotence and Recovery

Code and documentation edits can be repeated. Regenerating goldens with
`BAIKAI_KIT_ACCEPT_GOLDEN=1` overwrites them, so only do it deliberately and review the diff with
`git diff baikai-kit/test/golden`; a golden that changes unexpectedly is a contract change and
needs a `formatVersion` decision. `captureStdout` restores stdout in a `finally`, so a failing
test does not swallow later output. The release edits are plain text and can be reverted with
`git revert` before publishing.


## Interfaces and Dependencies

The test suite gains `process` in `build-depends` (for `git` in test 8); `temporary`,
`aeson`, and `bytestring` are already there. The library gains no dependency.

At the end of this plan:

```haskell
-- Baikai.Kit.Status (in addition to EP-2's exports)
data InstalledCopy = InstalledCopy
  { name :: !Text, kind :: !KitItemKind, scope :: !KitScope,
    provider :: !AgentAssetProvider, path :: !FilePath, version :: !(Maybe Text) }
installedCopies :: KitConfig -> IO [InstalledCopy]

-- Baikai.Kit.Json (new, exposed, re-exported by Baikai.Kit)
kitJsonFormatVersion :: Int
listDocument :: UpstreamAvailability -> KitManifest -> [InstalledCopy] -> Value
statusDocument :: StatusReport -> Value
updateDocument :: UpdateReport -> Value

-- Baikai.Kit.Command
data OutputFormat = HumanOutput | JsonOutput
data KitCommand
  = KitList !OutputFormat
  | KitInstall !(Maybe Text) !KitScope
  | KitUpdate !(Maybe Text) !OverwritePolicy !OutputFormat
  | KitUninstall !Text !KitScope
  | KitStatus !OutputFormat
  deriving stock (Eq, Show)
kitCommandParser :: KitConfig -> Parser KitCommand
```

`baikai-kit/baikai-kit.cabal` declares `version: 0.3.0.0`.
