---
id: 79
slug: report-local-edits-and-upstream-drift-as-separate-kit-status-conditions
title: "Report local edits and upstream drift as separate kit status conditions"
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
      at: 2026-09-23T15:41:56Z
      mode: "implement"
      note: "Milestones 1 and 2 implemented"
---

# Report local edits and upstream drift as separate kit status conditions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A user who edits an installed skill by hand today sees `kit status` report it as
`up-to-date`, and only learns it is modified when `kit update` skips it with
`Skipped 'review' (user): installed files were modified locally…`. Meanwhile the state
`kit status` does call `dirty` means something else entirely: that the kit's upstream sources
changed without a version bump. In most tools "dirty" means local edits, so the word misleads in
both directions.

After this change `kit status` runs the very same installed-file check `kit update` runs, and
reports each condition by its own name: `modified` for local edits, `changed-upstream` for
upstream sources that changed without a version bump, `outdated` for a newer version, and
`edits-unknown` for an item installed by an older release that recorded no installed-file
hash. Conditions compose, so a row can read `outdated+changed-upstream+modified`. `dirty` is
gone. Whatever `kit update` would skip, `kit status` has already reported as `modified`, and a
test proves that agreement directly.

This plan implements [IR-7](../improvement-requests/report-local-edits-in-kit-status.md)
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-7`). It is EP-2 of
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md).


## Progress

- [x] (2026-09-23 15:50Z) Milestone 1: factor the local-edit check into the exported `LocalEdits` / `checkLocalEdits`, re-express `locallyModified` through it; existing update tests green.
- [x] (2026-09-23 15:55Z) Milestone 1: replace `KitState` with `KitCondition`, `StatusRow.state` with `StatusRow.conditions`; add `conditionLabel` and `renderConditions`; rewrite the quoted existing assertions; `cabal test baikai-kit` green.
- [x] (2026-09-23 16:00Z) Milestone 2: evaluate local edits in `collectStatus`; add the unmodified/modified pair, the edits-unknown test, the composition test, and the status/update agreement test; `cabal test baikai-kit` green (55 tests).
- [x] (2026-09-23 16:10Z) Milestone 2: update `docs/user/kit.md`, CAP-21 prose and Limits, `CHANGELOG.md`, the bundle logs, and write ADR 0022; validators and `cabal build all --enable-tests` green.


## Surprises & Discoveries

- `reinstallPresent` scans both scopes, and with the default `projectRoot` its project-scope
  pass looks at the process's current directory (the repository checkout during
  `cabal test`). The agreement test therefore sets `projectRoot` to a directory inside the
  temporary `HOME` and passes both scopes to `collectStatus`, so the two commands compare over
  exactly the same, hermetic set of locations. This uses the field added by
  `docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md`.
- Both milestones landed in one commit: the milestone 1 rename alone leaves the user guide
  and CAP-21 describing `dirty`, which the plan requires to change with the code.


## Decision Log

- Decision: Replace the single enumerated `KitState` with a sorted, duplicate-free list of
  `KitCondition` values on `StatusRow.conditions`; an empty list means up to date.
  Rationale: IR-7 requires conditions to compose (outdated, changed upstream, and locally
  modified at once). Enumerating every combination does not scale, and a list of flags in a
  fixed order renders deterministically (`outdated+changed-upstream+modified`) and encodes
  naturally as a JSON array for the later JSON-output plan.
  Date: 2026-09-23

- Decision: Condition labels are `unknown`, `delisted`, `refused`, `outdated`,
  `changed-upstream`, `modified`, and `edits-unknown`; with no conditions the row reads
  `up-to-date`.
  Rationale: `unknown`, `delisted`, `refused`, `outdated`, and `up-to-date` keep their current
  meanings and spellings, so only the misleading `dirty` changes. `changed-upstream` and
  `modified` are the names IR-7 proposes. `edits-unknown` is short and parallels `unknown`.
  Date: 2026-09-23

- Decision: Keep the constructor prefix `Kit` (`KitOutdated`, `KitChangedUpstream`,
  `KitLocallyModified`, …) and keep the existing names `KitUnknown`, `KitDelisted`,
  `KitOutdated`, and `KitUpstreamRefused` for the conditions whose meaning is unchanged.
  Rationale: matches the package's existing sum-type naming and minimises churn in consumers
  and tests; `KitUpToDate`, `KitDirty`, and `KitDirtyOutdated` are removed because they no
  longer describe a single condition.
  Date: 2026-09-23

- Decision: No deprecated aliases for `KitState`, `renderState`, or the removed constructors.
  Rationale: their meaning changes, so an alias would mislead, and the release is already a
  major (`baikai-kit 0.3.0.0`); see `docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md`.
  Date: 2026-09-23

- Decision: An item whose upstream listing is refused still reports its local-edit condition.
  An item with no readable sidecar reports only `unknown` (plus `refused` if applicable), with
  no local-edit condition.
  Rationale: the local-edit check needs only the installed files and the sidecar, not the
  upstream, so a refused upstream is no reason to hide an edit. Without a sidecar there is
  nothing to compare, which `unknown` already says.
  Date: 2026-09-23

- Decision: `checkLocalEdits` returns `EditsUnknown` (not `Edited`) for a missing sidecar,
  and `collectStatus` maps a `Left` from it (for example an unsafe scanned name) to
  `edits-unknown` rather than dropping the row or failing the report.
  Rationale: status must never fail because one item cannot be checked; `edits-unknown` is
  the honest "could not tell". `kit update` is unaffected because it treats only `Edited` as a
  reason to skip.
  Date: 2026-09-23


## Outcomes & Retrospective

IR-7's acceptance criteria hold. `kit status` reports `modified` for an edited copy (only the
provider whose copy was edited), `edits-unknown` for a legacy sidecar, and composes conditions
(`outdated+changed-upstream+modified`). The old `dirty` coverage survives under the renamed
tests "hash mismatch => changed-upstream" and "version and cached hash drift reports
outdated+changed-upstream". "status reports modified for exactly what update would skip"
proves agreement with `kit update`, which now runs the same exported `checkLocalEdits`.
`docs/user/kit.md` describes both checks and which command acts on each; `CHANGELOG.md`
records the rename as breaking; ADR 0022 records the shared check. The one remaining mention
of `dirty` in the docs is the rename note in `docs/user/kit.md`.

`conditionLabel` is exported for
`docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md`, which must use it
for the JSON condition strings.


## Context and Orientation

The repository root is the directory containing `cabal.project`. `baikai-kit` is the package in
`baikai-kit/`: a library a command-line tool embeds to get a `kit` subcommand that installs
AI-agent skills and subagents from a git-hosted *kit* (a repository with a `kit.json` manifest)
into the directories where Claude Code and Codex discover them. Its sources are under
`baikai-kit/src/Baikai/Kit/`, and its whole test suite is `baikai-kit/test/Main.hs`, a `tasty`
suite run one test at a time. The package uses `GHC2024` with `DuplicateRecordFields`,
`OverloadedLabels`, and `OverloadedStrings`, requires explicit deriving strategies
(`deriving stock (…)`), and makes incomplete pattern matches an error. `Baikai.Prelude` provides
`lens` operators and generic-lens labels (`row ^. #name`). Record fields never carry type-name
prefixes.

Terms. A *provider* is one of the two coding agents whose layout the installer writes:
`InteractiveClaude` and `InteractiveCodex` (type `AgentAssetProvider`, an alias for
`Baikai.Interactive.InteractiveProvider`). Every item is installed once per provider, so a
skill installed for both has two copies and two sidecars. A *scope* is `UserScope` or
`ProjectScope`. A *sidecar* is the JSON file written beside each installed copy;
`baikai-kit/src/Baikai/Kit/Sidecar.hs` defines it:

```haskell
data SidecarMeta = SidecarMeta
  { name :: !Text,
    kind :: !Text,
    version :: !(Maybe Text),
    hash :: !Text,                     -- hash of the upstream sources at install time
    installedAt :: !Text,
    installedFiles :: !(Maybe [Text]), -- names written for this provider
    installedHash :: !(Maybe Text)     -- hash of exactly those bytes
  }
```

`installedFiles` and `installedHash` are `Nothing` in sidecars written by releases before
`baikai-kit` 0.2 (the test suite's `legacySidecarJson` is such a sidecar).
`hashEntries :: [(FilePath, ByteString)] -> Text` in the same module computes both hashes.

How `kit update` detects local edits today, in `baikai-kit/src/Baikai/Kit/Install.hs`
(private, not exported):

```haskell
locallyModified :: KitConfig -> KitItem -> KitScope -> IO Bool
locallyModified config item scope = do
  safeName <- orThrow (KitUnsafeName (itemName item)) (safeItemName (itemName item))
  checks <- forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    let kind = kitItemKind item
        root = installedRoot config provider providerBase kind safeName
    mSidecar <- readSidecar (sidecarPath provider kind (Text.pack safeName) providerBase (sidecarFileName config))
    case mSidecar of
      Nothing -> pure False
      Just sidecar ->
        case (sidecar ^. #installedFiles, sidecar ^. #installedHash) of
          (Just recorded, Just expected) -> do
            entries <- forM recorded $ \rel -> do
              bytes <- try @IOException (BS.readFile (root </> Text.unpack rel))
              pure (either (const Nothing) (Just . (Text.unpack rel,)) (bytes :: Either IOException BS.ByteString))
            pure $ case sequence entries of
              Nothing -> True
              Just pairs -> hashEntries pairs /= expected
          _ -> pure False
  pure (or checks)
```

`reinstallPresentIO` calls it under `KeepLocalEdits` and puts the item in `UpdateReport.skipped`
when it returns `True`. A file that cannot be read counts as modified; a legacy sidecar is not
checked. `installedRoot` (private, same module) is the directory the names in `installedFiles`
are relative to: the skill directory for a skill, the provider's agents directory for an agent.

How `kit status` classifies today, in `baikai-kit/src/Baikai/Kit/Status.hs`:

```haskell
data KitState
  = KitUpToDate | KitOutdated | KitDirty | KitDirtyOutdated
  | KitDelisted | KitUpstreamRefused | KitUnknown
  deriving stock (Eq, Ord, Show)

data StatusRow = StatusRow
  { name :: !Text, kind :: !Text, scope :: !Text, providers :: !Text,
    installedVersion :: !(Maybe Text), latestVersion :: !(Maybe Text),
    state :: !KitState }

classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
```

`classify` returns `KitUnknown` without a sidecar, `KitDelisted` when the manifest no longer
lists the item, and otherwise compares the sidecar's version with the manifest's (`outdated`)
and the sidecar's `hash` with the hash of the item's sources in the cached checkout (`dirty`).
`collectStatus :: KitConfig -> FilePath -> [(KitScope, Text)] -> IO [StatusRow]` scans each
scope and provider for installed items (`scanInstalled`), reads each sidecar, computes the
upstream hash with `upstreamHash` (whose `Left` means the upstream lists a source the installer
refuses, such as a symbolic link, and yields `KitUpstreamRefused`), and builds one row per
installed copy — one per provider. `renderStatusTable` merges rows that differ only in provider
(`aggregateStatusRows`, private) and prints `renderState` in the `STATE` column. `kitStatus`
wraps `collectStatus` with the cache refresh and needs no network. `Baikai.Kit.Status` already
imports `Baikai.Kit.Install`, so a function exported from `Install` can be used from `Status`
without an import cycle.

The existing tests that pin today's states, all in `baikai-kit/test/Main.hs`, are listed in
Milestone 1 with the exact assertion each must become. They are kept, not deleted.

`docs/user/kit.md` (section `## Status And Sidecars`) documents the state list and says the
dirty check "does not hash provider-installed target files". The CAP-21 capability record
`docs/capabilities/kit-installer.md` says an item can be "drifted from the cached upstream
(`dirty`)" and, under Limits, "a `dirty` item is reported". Both must change.

Relevant ADRs: [docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md](../adr/0016-deprecated-names-are-removed-at-the-next-major.md)
(why no aliases are kept) and [docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md)
(the new exported check returns `Either KitError`, never exits). ADRs are plain Markdown files
with `title`, `status`, and `date` frontmatter, indexed in `docs/adr/README.md`.

Another plan in this initiative,
`docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md`, will encode
`StatusRow` as JSON and must spell conditions with `conditionLabel`; export it for that reason.


## Plan of Work

### Milestone 1: one local-edit check and a composable status vocabulary

At the end of this milestone the package has one exported local-edit check that `kit update`
uses, and the status types speak in composable conditions. `kit status` output is unchanged
except that `dirty` reads `changed-upstream` and `dirty+outdated` reads
`outdated+changed-upstream`.

In `baikai-kit/src/Baikai/Kit/Install.hs`, add and export:

```haskell
-- | Whether one provider's installed copy of an item still matches what
--   was installed.
data LocalEdits
  = -- | Every recorded file reads back with the recorded hash.
    Unedited
  | -- | A recorded file differs, or cannot be read.
    Edited
  | -- | There is nothing to compare against: no sidecar, or a sidecar
    --   written before @installedFiles@ and @installedHash@ existed.
    EditsUnknown
  deriving stock (Eq, Show)

checkLocalEdits ::
  KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError LocalEdits)
checkLocalEdits config provider scope kind n = kitTry (localEditsIO config provider scope kind n)
```

Write the private `localEditsIO` by moving the per-provider body of `locallyModified` into it
unchanged in substance: validate the name with `safeItemName` (throwing `KitUnsafeName`), find
`providerBase`, `installedRoot`, and the sidecar path, and return `EditsUnknown` for a missing
sidecar or missing `installedFiles`/`installedHash`, `Edited` for an unreadable file or a hash
mismatch, and `Unedited` otherwise. Then rewrite `locallyModified` as:

```haskell
locallyModified config item scope = do
  checks <- forM (config ^. #providers) $ \provider ->
    localEditsIO config provider scope (kitItemKind item) (itemName item)
  pure (Edited `elem` checks)
```

This preserves `kit update`'s behaviour exactly: a legacy or missing sidecar was "not
modified" before and is `EditsUnknown` (not `Edited`) now. The existing test
"update skips locally modified items unless forced" must stay green without edits.

In `baikai-kit/src/Baikai/Kit/Status.hs`, replace `KitState` with:

```haskell
-- | One thing @kit status@ can say about an installed copy. A row carries
--   a sorted list of these; an empty list means up to date.
data KitCondition
  = KitUnknown             -- ^ "unknown": no readable sidecar
  | KitDelisted            -- ^ "delisted": the manifest no longer lists it
  | KitUpstreamRefused     -- ^ "refused": the upstream lists a source the installer refuses
  | KitOutdated            -- ^ "outdated": the manifest version differs
  | KitChangedUpstream     -- ^ "changed-upstream": upstream sources changed, same version
  | KitLocallyModified     -- ^ "modified": installed files were edited
  | KitLocalEditsUnknown   -- ^ "edits-unknown": sidecar predates the installed-file hash
  deriving stock (Eq, Ord, Show, Enum, Bounded)

conditionLabel :: KitCondition -> Text
renderConditions :: [KitCondition] -> Text
-- renderConditions [] = "up-to-date"; otherwise the labels joined with "+"
-- in constructor order.
```

In `StatusRow`, replace `state :: !KitState` with `conditions :: ![KitCondition]`. Change
`classify` to return the upstream conditions only:

```haskell
classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> [KitCondition]
classify Nothing _ _ = [KitUnknown]
classify (Just _) Nothing _ = [KitDelisted]
classify (Just sm) (Just it) mUpstreamHash =
  [KitOutdated | outdated] ++ [KitChangedUpstream | changed]
```

In `collectStatus`, the `Left` branch of `upstreamHash` becomes `[KitUpstreamRefused]` plus
`[KitUnknown]` when there is no sidecar; normalise the final list with `sort . nub`. In
`renderStatusTable` and `aggregateStatusRows`, use `conditions` and `renderConditions` wherever
`state` and `renderState` appear. Update the export list: remove `KitState (..)` and
`renderState`; add `KitCondition (..)`, `conditionLabel`, and `renderConditions`.

Rewrite the existing assertions in `baikai-kit/test/Main.hs` exactly as follows, keeping every
test and changing only the two names given. In `classifyTests`:

- "no sidecar => unknown": `@?= KitUnknown` becomes `@?= [KitUnknown]`.
- "no upstream entry with a sidecar => delisted": `@?= KitDelisted` becomes `@?= [KitDelisted]`.
- "version mismatch => outdated": `@?= KitOutdated` becomes `@?= [KitOutdated]`.
- "version and hash mismatch => dirty+outdated" is renamed
  "version and hash mismatch => outdated+changed-upstream", and `@?= KitDirtyOutdated` becomes
  `@?= [KitOutdated, KitChangedUpstream]`.
- "hash mismatch => dirty" is renamed "hash mismatch => changed-upstream", and `@?= KitDirty`
  becomes `@?= [KitChangedUpstream]`.
- "version and hash match => up-to-date" and "no upstream hash on matching version =>
  up-to-date": `@?= KitUpToDate` becomes `@?= []`.

In `symlinkSafetyTests`, "status reports refused when upstream lists a symlinked source":
`row ^. #state @?= KitUpstreamRefused` becomes `row ^. #conditions @?= [KitUpstreamRefused]`;
and "renderState names the refused state", whose body is
`renderState KitUpstreamRefused @?= "refused"`, becomes
`conditionLabel KitUpstreamRefused @?= "refused"` (rename it "conditionLabel names the refused
condition"). In `statusFilesystemTests`, "delisted installed item keeps sidecar version in
status": `row ^. #state @?= KitDelisted` becomes `row ^. #conditions @?= [KitDelisted]`; and
"version and cached hash drift reports dirty+outdated" is renamed
"version and cached hash drift reports outdated+changed-upstream", and
`row ^. #state @?= KitDirtyOutdated` becomes
`row ^. #conditions @?= [KitOutdated, KitChangedUpstream]`.

Update the test's import list: `KitState (..)` becomes `KitCondition (..)`, `renderState`
becomes `conditionLabel`, and add `renderConditions`. Add one pure test:
"renderConditions joins labels in order" asserting `renderConditions [] @?= "up-to-date"` and
`renderConditions [KitOutdated, KitChangedUpstream, KitLocallyModified] @?= "outdated+changed-upstream+modified"`.

Acceptance: `cabal test baikai-kit` passes. At this point the refused and delisted rows in the
tests still produce exactly the lists above, because local edits are not yet evaluated.

### Milestone 2: status reports local edits

At the end of this milestone `kit status` reports `modified` and `edits-unknown`, and a test
proves that status and update agree.

In `collectStatus`, for each scanned row whose sidecar was read (`Just`), call
`checkLocalEdits config provider scope scannedKind itemName'` and add `KitLocallyModified` for
`Right Edited`, `KitLocalEditsUnknown` for `Right EditsUnknown` or any `Left`, and nothing for
`Right Unedited`. Rows without a sidecar get no local-edit condition. The scope is the `KitScope`
already in hand from the `scopes` argument. Status stays network-free: this reads only local
files.

Add tests to `statusFilesystemTests`, each inside `withPreparedKitHome` (which installs nothing
itself: it prepares a cache with the skill `demo` and agent `reviewer`, both version `0.1.0`).
The Claude copy of `demo` at user scope lives at
`$HOME/.config/testkit/agents/.claude/skills/demo/`, the Codex copy at
`$HOME/.agents/skills/demo/`.

1. "an installed item reports no conditions before an edit": install `demo` at user scope;
   `collectStatus testConfig cache [(UserScope, "user")]`; every `demo` row has
   `conditions == []`.
2. "editing an installed file reports modified": install `demo`, overwrite the Claude copy's
   `SKILL.md` with `"my edits"`; the Claude row (`providers == "claude"`) has
   `[KitLocallyModified]` and the Codex row has `[]`.
3. "a legacy sidecar reports edits-unknown": install `demo`, overwrite the Claude copy's
   `.testkit-kit.json` with `legacySidecarJson`; the Claude row's conditions contain
   `KitLocalEditsUnknown` and do not contain `KitLocallyModified`. (The legacy sidecar's `hash`
   is `"sha256:x"`, so the row also reports `KitChangedUpstream`; assert with `elem`, not
   equality.)
4. "modified composes with outdated and changed-upstream": install `demo`, edit the Claude
   copy, write new content to the cached `skills/demo/SKILL.md`, and write
   `manifestWithDemoVersionJson` (which bumps `demo` to `0.2.0`) to the cached `kit.json`; the
   Claude row has exactly `[KitOutdated, KitChangedUpstream, KitLocallyModified]`.
5. "status reports modified for exactly what update would skip": install `demo` and
   `reviewer` at user scope, edit the Claude copy of `demo`'s `SKILL.md`, leave `reviewer`
   untouched. Compute `modifiedByStatus` as the set of `(name, scope)` for rows whose conditions
   contain `KitLocallyModified` (the scope text `"user"` maps to `UserScope`). Then run
   `reinstallPresent testConfig cache manifest Nothing KeepLocalEdits` (with `manifest` from
   `loadManifest cache`) and assert `sort (report ^. #skipped) == sort modifiedByStatus`, and
   that it equals `[("demo", UserScope)]`.

Documentation and records, in the same commit:

In `docs/user/kit.md`, in `## Status And Sidecars`, replace the state list and the paragraph
that begins "The dirty check compares" with: the list of conditions and their labels (as in the
Decision Log above), a sentence that a row shows `up-to-date` when it has none and otherwise
joins them with `+`, and a short paragraph describing the two checks — the upstream check
(sidecar `hash` against the cached checkout, acted on by `kit update`, which reinstalls) and the
local-edit check (installed files against `installedHash`, the same check `kit update` uses to
skip an item unless `--force`). Change the example table row if needed. Bump `generated.at` and
append a dated entry to `docs/user/log.md`.

In `docs/capabilities/kit-installer.md`, change the sentence listing states to the new
vocabulary (up-to-date, outdated, changed upstream, locally modified, edits unknown, delisted,
refused, unknown, and that they compose), change the Limits bullet that says "a `dirty` item is
reported" to name `changed-upstream` and `modified`, bump `generated.at`, and append a dated
`* **Update**: CAP-21 …` entry to `docs/capabilities/log.md`.

In the root `CHANGELOG.md` under `## [Unreleased]`, add a `### Changed` bullet beginning
`baikai-kit:` and marked `__Breaking__`: `kit status` renames `dirty` to `changed-upstream` and
`dirty+outdated` to `outdated+changed-upstream`; `KitState` is replaced by `[KitCondition]` on
`StatusRow.conditions`; `renderState` is replaced by `conditionLabel` and `renderConditions`;
`classify` returns `[KitCondition]`. Add a `### Added` bullet beginning `baikai-kit:` for the
`modified` and `edits-unknown` conditions and the exported `LocalEdits` and `checkLocalEdits`.

Write a new ADR in `docs/adr/` with the next unused number (list the directory; at the time of
writing the next is 0021, but another plan in this initiative may have taken it) titled
"Kit status and kit update share one local-edit check, and upstream drift and local edits are
separate conditions". Context: IR-7. Decision: `checkLocalEdits` is the only implementation of
the installed-file comparison, used by both commands; `changed-upstream` and `modified` are
never merged into one word. Consequences: the agreement test guards it. Add its row to
`docs/adr/README.md`.

Acceptance: all tests pass; validators exit 0; `cabal build all --enable-tests` succeeds (it
also compiles `baikai-smoke`, which must not reference the removed names).


## Concrete Steps

All commands run from the repository root.

```bash
cabal build baikai-kit
cabal test baikai-kit
```

After Milestone 2 the output includes, among the renamed and existing tests:

```text
  Status.classify
    hash mismatch => changed-upstream:                                    OK
    version and hash mismatch => outdated+changed-upstream:               OK
  Status filesystem
    version and cached hash drift reports outdated+changed-upstream:      OK
    an installed item reports no conditions before an edit:               OK
    editing an installed file reports modified:                           OK
    a legacy sidecar reports edits-unknown:                               OK
    modified composes with outdated and changed-upstream:                 OK
    status reports modified for exactly what update would skip:           OK
```

Then:

```bash
grep -rn "KitDirty\|renderState\|KitUpToDate\|KitState\b" baikai-kit baikai-smoke
grep -n "dirty" docs/user/kit.md docs/capabilities/kit-installer.md
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
cabal build all --enable-tests
```

The first `grep` prints nothing. The second prints at most a line that explains the rename
(for example "`changed-upstream` was called `dirty` before baikai-kit 0.3"); no line may use
`dirty` as a current state.

Commit after each milestone with the trailers:

```text
feat(kit)!: report local edits and upstream drift as separate status conditions

MasterPlan: docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md
ExecPlan: docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md
Intention: intention_01m379fwwker59e1mjhb3k3hfa
```


## Validation and Acceptance

IR-7's acceptance criteria, and how each is shown:

1. Tests 1 and 2 of Milestone 2: an item reports no conditions before an edit and
   `KitLocallyModified` after one installed file is edited.
2. The renamed tests "hash mismatch => changed-upstream" and "version and cached hash drift
   reports outdated+changed-upstream" keep the upstream-drift coverage under the new names.
3. Test 5 asserts that the set `kit update` skips under `KeepLocalEdits` equals the set
   `kit status` reports as modified.
4. `docs/user/kit.md` describes both checks and which command acts on each, and
   `CHANGELOG.md` records the rename as a user-visible, breaking change.

By hand, with any consumer built against this code: install a skill, edit its installed
`SKILL.md`, and run `mytool kit status`; the row's `STATE` column reads `modified` for the
provider whose copy you edited.


## Idempotence and Recovery

All edits are to source, tests, and documentation, and can be repeated. Tests work in
temporary directories. If a renamed test is accidentally dropped, `cabal test baikai-kit`'s
output will lack its name; compare against the list in Concrete Steps.


## Interfaces and Dependencies

No new package dependencies.

At the end of this plan `Baikai.Kit.Install` additionally exports:

```haskell
data LocalEdits = Unedited | Edited | EditsUnknown
  deriving stock (Eq, Show)

checkLocalEdits ::
  KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError LocalEdits)
```

and `Baikai.Kit.Status` exports, in place of `KitState (..)` and `renderState`:

```haskell
data KitCondition
  = KitUnknown | KitDelisted | KitUpstreamRefused | KitOutdated
  | KitChangedUpstream | KitLocallyModified | KitLocalEditsUnknown
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data StatusRow = StatusRow
  { name :: !Text, kind :: !Text, scope :: !Text, providers :: !Text,
    installedVersion :: !(Maybe Text), latestVersion :: !(Maybe Text),
    conditions :: ![KitCondition] }

classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> [KitCondition]
conditionLabel :: KitCondition -> Text
renderConditions :: [KitCondition] -> Text
```

`collectStatus`, `kitStatus`, `StatusReport`, `UpstreamAvailability`, and `renderStatusTable`
keep their signatures.
