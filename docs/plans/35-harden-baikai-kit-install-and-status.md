---
id: 35
slug: harden-baikai-kit-install-and-status
title: "Harden baikai-kit install and status"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Harden baikai-kit install and status

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`baikai-kit` is the shared installer that lets a command-line tool ship a git-hosted
"kit" of agent skills and subagents: it clones the kit repository into a cache, reads a
`kit.json` manifest, copies provider-native files into Claude Code and Codex discovery
directories, writes sidecar metadata next to each installed asset, and reports install
status. Today a malicious or compromised kit repository can write files anywhere on the
user's disk (`files: ["../../../../.zshenv"]` escapes the install root because
`</>` performs no sanitization), and several reporting paths lie to the user: `kit
status` hides that an item is locally drifted when it is also outdated, calls installed
items "unknown" the moment they are delisted upstream, `kit update` prints success when
`git pull` failed, and `kit uninstall` prints success when it only deleted a metadata
file. A mid-failure during a multi-provider install leaves a half-installed item, and a
CRLF-encoded agent file leaks its YAML frontmatter into the generated Codex TOML.

After this plan, every manifest-supplied path is validated by one shared sanitization
function before it is joined onto any base directory, so a hostile kit repository cannot
write or delete outside the install roots; `kit status` reports `dirty+outdated` and
`delisted` states truthfully; installs are staged and rolled back on failure so an item
is never half-installed; `kit update` exits nonzero when the pull fails; `kit uninstall`
reports exactly what it removed; and frontmatter stripping works on CRLF files. All of
this is observable by running `cabal test baikai-kit` from the repository root: the new
tests fail against the current code and pass after the fixes. This plan is EP-2 of the
MasterPlan at `docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`
and covers all seven Theme 8 findings of
`docs/reviews/2026-07-01-correctness-and-api-review.md`. It has no dependencies on other
plans and touches only the `baikai-kit` package plus `docs/user/kit.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] Milestone 1: create `baikai-kit/src/Baikai/Kit/Path.hs` with `safeItemName`, `safeRelativePath`, `safeUnder`; add it to `exposed-modules` in `baikai-kit/baikai-kit.cabal`.
- [ ] Milestone 1: wire sanitization into `installItem`/`doInstall`, `uninstallItem`, `isInstalled`, `copySkillFile`, `agentSourceBase` call sites in `baikai-kit/src/Baikai/Kit/Install.hs` and into `computeKitHash` in `baikai-kit/src/Baikai/Kit/Sidecar.hs`.
- [ ] Milestone 1: rewrite `stripYamlFrontmatter` line-wise (CRLF and EOF tolerant) and export it from `Baikai.Kit.Install`.
- [ ] Milestone 1: unit tests for `safeItemName`/`safeRelativePath`/`safeUnder` and `stripYamlFrontmatter`; filesystem tests proving zip-slip install and traversal uninstall are refused.
- [ ] Milestone 2: add `KitItemKind` and `kitItemKind`/`kindLabel` to `baikai-kit/src/Baikai/Kit/Manifest.hs`; rework `sidecarPath` in `baikai-kit/src/Baikai/Kit/Sidecar.hs` to take kind and name and to use `System.FilePath.dropExtension`; delete `dummyAgent`/`agentSidecarTarget` hack in `Install.hs`.
- [ ] Milestone 2: key sidecar lookup off the scan in `collectStatus` (`baikai-kit/src/Baikai/Kit/Status.hs`); add `KitDirtyOutdated` and `KitDelisted` states; rework `classify`.
- [ ] Milestone 2: update existing `classify` tests, add new classify and filesystem status tests (dirty+outdated, delisted-with-sidecar), update the states list in `docs/user/kit.md`.
- [ ] Milestone 3: staged two-phase install (`PlannedWrite`, plan across all providers, temp-file writes, rename into place, cleanup on failure) in `Install.hs`; `newSidecarMeta` in `Sidecar.hs`.
- [ ] Milestone 3: truthful uninstall (`RemovalOutcome`, `uninstallOutcomes`, pure `renderUninstallReport`).
- [ ] Milestone 3: `PullResult` in `baikai-kit/src/Baikai/Kit/Repo.hs`; `updateKit` fails loudly on pull failure; `ensureKitRepo` keeps warn-and-use-cache.
- [ ] Milestone 3: rollback, uninstall-report, and pull-failure tests; full `cabal build all --enable-tests` and `cabal test baikai-kit` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Path sanitization lives in a new pure module `Baikai.Kit.Path` returning
  `Either Text FilePath`, and is the single choke point used by install, uninstall,
  sidecar hashing, and status hashing.
  Rationale: the vulnerability exists because four call sites each join untrusted
  manifest text with `</>` independently; a single validated entry point makes the
  invariant auditable and unit-testable as a pure function.
  Date: 2026-07-01
- Decision: `KitState` stays a flat printable enum and gains two constructors,
  `KitDirtyOutdated` (rendered `dirty+outdated`) and `KitDelisted` (rendered
  `delisted`), rather than becoming a record of boolean facts.
  Rationale: `StatusRow`, the table renderer, and the provider aggregation added by
  commit `a219ace` ("fix(kit): aggregate status by provider") all group and sort on an
  `Eq`/`Ord` state value; an additive enum keeps that machinery and the exported API
  intact while still exposing both facts. Only two combinations beyond the existing
  states are truthful and reachable, so the enum does not explode.
  Date: 2026-07-01
- Decision: `sidecarPath` is re-keyed by `KitItemKind` and item name instead of a full
  `KitItem`, and the agent sidecar path is derived with `System.FilePath.dropExtension`
  on the provider target path instead of suffix-chopping `".md"`/`".toml"` by hand.
  Rationale: one refactor fixes two findings at once — status can compute a sidecar path
  for a scanned-but-delisted item (no manifest entry exists to build a `KitItem` from),
  and the path derivation becomes correct for any future provider extension. It also
  deletes the `dummyAgent` fabrication in `Install.hs`. On-disk layout is unchanged for
  the current providers, so existing installs keep working.
  Date: 2026-07-01
- Decision: Multi-provider install failure isolation is achieved by staging, not by
  backup/restore: one plan of writes is computed and validated across all providers
  before anything is written, every target is first written to `<target>.baikai-kit-tmp`
  in its final directory, and only when every temp write succeeded are the temps renamed
  into place. Any failure before the rename phase deletes the temps and leaves prior
  installs untouched.
  Rationale: same-directory rename is atomic on POSIX; validating and writing everything
  before the first rename means the observable state is "all providers installed" or
  "nothing changed", without the complexity of backing up and restoring existing files.
  A failure during the rename phase itself is theoretically possible but requires the
  filesystem to fail a same-directory rename after a successful write; this residual
  risk is accepted and documented.
  Date: 2026-07-01
- Decision: `pullKitRepo` returns a `PullResult` (`PullSucceeded | PullFailed Text`) and
  stops printing; callers decide. `updateKit` treats `PullFailed` as an error: it prints
  the failure to stderr, does not print "Kit repository updated.", does not reinstall
  anything, and exits nonzero. `ensureKitRepo` (used by `list`/`install`/`status`)
  keeps the warn-and-continue-from-cache behavior.
  Rationale: `update` has one job; reporting success while serving stale content is the
  bug under fix. But offline `list`/`install` from a previously cloned cache is a
  feature worth keeping, so only the `update` verb becomes strict.
  Date: 2026-07-01
- Decision: Uninstall reports per-provider outcomes: a success line names the kinds and
  providers actually removed; a removal that deleted only sidecar metadata prints a
  "removed stale kit metadata" line instead of claiming an asset was uninstalled; and
  nothing removed keeps the existing "is not installed" line. Rendering is a pure
  function so it can be unit-tested without capturing stdout.
  Rationale: the current code reports the first kind found across all providers and
  counts a sidecar-only deletion as an "agent" uninstall — both are lies. Separating
  outcome collection (`IO`) from message rendering (pure) matches the test strategy.
  Date: 2026-07-01
- Decision: Validation failures (unsafe path, unsafe name, missing source file) are
  reported to stderr followed by `exitFailure`, matching the package's existing error
  style (`loadManifest`, missing-item lookup). Tests catch the `ExitCode` exception with
  `try @ExitCode`.
  Rationale: consistency with the module's established error handling; converting the
  whole package to `Either`-returning APIs is out of scope for this plan and would
  belong to the API-freeze plans (EP-9/EP-10).
  Date: 2026-07-01
- Decision: No package version bump is made here even though `sidecarPath` and
  `pullKitRepo` change signature (both are re-exported through the `Baikai.Kit`
  umbrella). The `mori` registry shows no registered project depends on `baikai-kit`,
  and releases in this repository are cut by the release skill, which owns versioning.
  Rationale: avoid unilateral version churn; the surface-hygiene plan (EP-10) will
  decide whether these helpers should be internalized before the freeze.
  Date: 2026-07-01
- Decision: All new record types (`PlannedWrite`, `RemovalOutcome`) use bare field names
  (`destination`, `content`, `provider`, `skillRemoved`, ...) with no Hungarian-style
  prefixes, including on internal records.
  Rationale: repository-wide rule; `DuplicateRecordFields` and `OverloadedLabels` are
  already default extensions in `baikai-kit/baikai-kit.cabal`, so bare names cannot
  collide.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The `baikai-kit` package lives in `baikai-kit/` at the repository root. Its library
modules are under `baikai-kit/src/Baikai/Kit/` and are all re-exported wholesale through
the umbrella module `baikai-kit/src/Baikai/Kit.hs`. Its single test suite is
`baikai-kit/test/Main.hs` (tasty + tasty-hunit + temporary), declared in
`baikai-kit/baikai-kit.cabal`. The intended user-facing behavior is documented in
`docs/user/kit.md`. The package builds with `cabal build baikai-kit` and tests with
`cabal test baikai-kit`, both from the repository root.

A "kit" is a git repository containing a `kit.json` manifest that lists skills (each
with a `name`, a repo-relative directory `path`, and a list of `files` below that
directory) and agents (each with a `name` and a `path` to a Markdown file, optionally a
`files` list). The manifest is attacker-controlled from the installer's point of view:
users point their tool at arbitrary git URLs. A "sidecar" is a small JSON file the
installer writes next to each installed asset recording the item name, kind, version,
install time, and a content hash of the upstream source files (`SidecarMeta` in
`baikai-kit/src/Baikai/Kit/Sidecar.hs`). "Providers" here are the two interactive
agent hosts, Claude Code (`InteractiveClaude`) and Codex (`InteractiveCodex`); the pure
per-provider path rules (`skillTargetPath`, `agentTargetPath`) live in
`baikai/src/Baikai/AgentAssets.hs` and return relative paths like
`.claude/skills/<name>` or `.codex/agents/<name>.toml` that `baikai-kit` joins onto a
per-provider base directory (`providerAgentsBase` in
`baikai-kit/src/Baikai/Kit/Config.hs`: the tool's agents dir for Claude, `$HOME` or the
current directory for Codex).

The module map, with the findings each one carries (numbering follows Theme 8 of
`docs/reviews/2026-07-01-correctness-and-api-review.md`):

`baikai-kit/src/Baikai/Kit/Install.hs` — install/uninstall/update/list. Finding 8.1
(major, security): `doInstall` joins manifest text straight into filesystem paths with
`</>` — `sourceDir = repoDir </> Text.unpack (entry ^. #path)` at line 162 and
`copySkillFile` at lines 191–196 computes `dst = targetDir </> Text.unpack fileName`.
`System.FilePath.</>` performs no sanitization and *discards the left operand entirely
when the right side is absolute* (`"/a" </> "/etc/passwd" == "/etc/passwd"`). A manifest
with `files: ["../../../../.zshenv"]` therefore writes the user's shell init file
(zip-slip), and a `path` or `name` containing `..` steers reads and writes outside both
the cache and the install root. The same unsanitized `name` flows into `uninstallItem`
(lines 98–118), where `removeIfDirectory` calls `removeDirectoryRecursive` — a traversal
name like `../../work` deletes an arbitrary directory tree. Finding 8.4 (minor):
`doInstall` (lines 160–189) loops over providers writing files as it goes; an exception
on the second provider (unwritable target, missing source discovered late) leaves the
first provider installed and the second absent, with no rollback. Finding 8.7 (minor):
`stripYamlFrontmatter` (lines 294–301) matches the literal byte sequences `"---\n"` and
`"\n---\n"`, so a CRLF-encoded agent file never matches and the whole YAML frontmatter
leaks into the `developer_instructions` field of the generated Codex TOML. Finding 8.8
(reporting): `uninstallItem` reports only the first removed kind across all providers
(`case removals of (kind : _) -> ...`) and treats a sidecar-only removal
(`agentRemoved || sidecarRemoved`) as a successful "agent" uninstall.

`baikai-kit/src/Baikai/Kit/Status.hs` — `kit status`. Finding 8.2 (major): `classify`
(lines 53–65) checks the version first and returns `KitOutdated` without ever looking at
the hash, so an item that is both outdated and content-drifted reports only `outdated`;
the user runs `kit update` and their local state is silently overwritten with no hint it
had drifted. Finding 8.3 (minor): in `collectStatus` (lines 76–94, feeding the scan
from lines 120–145), the sidecar is only read when the item is found in the manifest
(`mSidecar <- case mItem of Just item -> readSidecar (sidecarPath provider item ...)`),
because `sidecarPath` demands a `KitItem`. An installed item that upstream has delisted
therefore shows `unknown` with a blank installed version even though a perfectly valid
sidecar sits on disk. Note that commit `a219ace` recently added per-provider row
aggregation (`aggregateStatusRows` groups rows by name/kind/scope/versions/state and
joins provider labels); any state or row change must keep that aggregation working.

`baikai-kit/src/Baikai/Kit/Sidecar.hs` — sidecar read/write and `computeKitHash`.
Finding 8.5 (minor): the agent sidecar path (lines 58–67) is built by reversing the
target path string and pattern-matching the character sequences `dm.` and `lmot.` to
chop `".md"`/`".toml"`, then gluing the sidecar file name on with `<>`. It produces the
right answer for exactly the two current providers and silently produces garbage for any
other extension. Also relevant to 8.1: `computeKitHash` reads
`dir </> Text.unpack rel` for each manifest-supplied relative file, so hash computation
performs unsanitized reads too.

`baikai-kit/src/Baikai/Kit/Repo.hs` — clone/pull. Finding 8.6 (minor): `pullKitRepo`
(lines 46–56) turns any `git pull` failure into a stderr warning and returns `()`;
`updateKit` in `Install.hs` then prints "Kit repository updated." and reinstalls from
the stale cache. A user behind a broken network or a moved repository sees success
forever.

`baikai-kit/src/Baikai/Kit/Manifest.hs` holds the manifest types (`KitManifest`,
`SkillEntry`, `AgentEntry`, `KitItem`) and helpers; `baikai-kit/src/Baikai/Kit/Config.hs`
holds `KitConfig`/`KitScope` and directory resolution; `baikai-kit/src/Baikai/Kit/Command.hs`
is the optparse adapter (unchanged by this plan except through the functions it calls);
`baikai-kit/src/Baikai/Kit/Session.hs` is unrelated discovery code (untouched).

The existing test suite (`baikai-kit/test/Main.hs`) shows the harness pattern to reuse:
`withSystemTempDirectory` plus a `withPreparedKitHome` helper that fabricates a kit
cache under `<tmp>/home/.cache/testkit/kit` (including a fake `.git` directory so
`ensureKitRepo` skips cloning — note the fake `.git` makes any real `git pull` in that
directory fail, which Milestone 3 exploits), writes a manifest and source files, sets
`HOME` to the temp home, runs the action, and restores `HOME`. Project-scope paths
resolve against the current working directory, so tests stick to `UserScope`.


## Plan of Work

The work is three milestones. Milestone 1 delivers the security fix and the other pure
text bug as unit-testable functions plus their wiring. Milestone 2 makes `kit status`
truthful. Milestone 3 makes install, uninstall, and update robust and honest. Each
milestone leaves `cabal build all --enable-tests` and `cabal test baikai-kit` green and
is independently verifiable by named tests.

### Milestone 1 — Path sanitization and CRLF-safe frontmatter stripping

Scope: findings 8.1 (path traversal / zip-slip, the security item) and 8.7 (CRLF
frontmatter). At the end of this milestone a hostile manifest cannot make the installer
read, write, or delete anything outside the kit cache and the provider install roots,
and a CRLF agent file converts to clean Codex TOML. New pure functions carry negative
unit tests, and two filesystem tests demonstrate the refusals end to end.

Create `baikai-kit/src/Baikai/Kit/Path.hs`, a dependency-free pure module (imports:
`Baikai.Prelude`, `Data.Text qualified as Text`, `System.FilePath`), and add it to
`exposed-modules` in `baikai-kit/baikai-kit.cabal` (it is then automatically re-exported
by adding it to `baikai-kit/src/Baikai/Kit.hs` alongside the other modules). It exports
exactly three functions:

```haskell
-- | Validate untrusted manifest text as a safe relative path. Rejects: empty
-- input, NUL bytes, backslashes (kit manifests are cross-platform; a backslash
-- is either a Windows separator or an obfuscation attempt), absolute paths
-- ('System.FilePath.isAbsolute'), and any path whose normalised form
-- ('System.FilePath.normalise' then 'System.FilePath.splitDirectories')
-- contains a ".." component. Returns the normalised relative 'FilePath' on
-- success, or a human-readable reason on failure.
safeRelativePath :: Text -> Either Text FilePath

-- | Validate an item name for use as a single path segment: everything
-- 'safeRelativePath' rejects, plus multi-component paths (no '/'), "." and
-- "..", and names starting with '.' (dot names are invisible to the status
-- scan and could collide with the sidecar file name, which starts with '.').
safeItemName :: Text -> Either Text FilePath

-- | Join validated untrusted text under a trusted base:
-- @safeUnder base rel = (base '</>') <$> safeRelativePath rel@.
safeUnder :: FilePath -> Text -> Either Text FilePath
```

Note why normalisation matters: `normalise "skills/./review"` is `"skills/review"`
(harmless `.` components disappear), while `"a/../../x"` keeps its `..` components and
is rejected. There is no attempt to resolve symlinks; the invariant is purely lexical,
which is sufficient because the base directories are trusted and the manifest cannot
create symlinks by itself (files are copied, never linked).

Wire it in. In `baikai-kit/src/Baikai/Kit/Install.hs` add a small helper used by the
IO entry points:

```haskell
requireSafe :: Text -> Either Text a -> IO a
requireSafe what = \case
  Right a -> pure a
  Left reason -> do
    hPutStrLn stderr $ "Error: unsafe " <> Text.unpack what <> ": " <> Text.unpack reason
    exitFailure
```

Then: in `doInstall` (both the skill and agent equations), before any filesystem
action, validate the entry's `name` with `safeItemName`, the entry's `path` with
`safeRelativePath`, and every element of `files` with `safeRelativePath`, and build
`sourceDir`/`dst` values with `safeUnder` instead of raw `</>` (`copySkillFile` should
receive already-validated `FilePath` pieces or perform `safeUnder` itself). In
`uninstallItem` and `isInstalled`, validate the incoming name with `safeItemName` before
computing `skillTarget`/`agentTarget`/sidecar paths — this is what stops
`removeDirectoryRecursive` from being steered outside the install root. In
`baikai-kit/src/Baikai/Kit/Sidecar.hs`, change `computeKitHash`'s `readOne` to join with
`safeUnder` and throw `userError` (an `IOException`) on `Left` — install validates
before it ever gets here, so this is defense in depth, and `Status.tryHash`'s existing
`try @IOException` already converts it to `Nothing` for the status path
(`upstreamHash` in `baikai-kit/src/Baikai/Kit/Status.hs` needs no separate change; its
`agentSourceBase` input flows into `computeKitHash`, which now refuses to escape).

Still in `Install.hs`, rewrite `stripYamlFrontmatter` line-wise and add it to the module
export list so the tests can reach it:

```haskell
-- | Strip a leading YAML frontmatter block (an opening "---" line through the
-- next "---" line). Tolerates CRLF line endings and a closing delimiter on the
-- final line without a trailing newline. Output uses LF line endings. Input
-- without a complete frontmatter block is returned unchanged.
stripYamlFrontmatter :: Text -> Text
stripYamlFrontmatter input =
  case map dropCr (Text.splitOn "\n" input) of
    ("---" : rest)
      | (_, _ : body) <- break (== "---") rest ->
          Text.intercalate "\n" body
    _ -> input
  where
    dropCr = Text.dropWhileEnd (== '\r')
```

(The `break` produces an empty second component when no closing `---` line exists, so
the guard fails and the unterminated case falls through to `input`, preserving current
behavior. Normalising the body to LF is deliberate: the TOML multiline writer in
`baikai/src/Baikai/AgentAssets.hs` escapes `\r` explicitly today, and LF-only output is
what Codex expects.)

Tests, in `baikai-kit/test/Main.hs` (new test groups; follow the existing style).
Pure: `safeRelativePath` accepts `"SKILL.md"`, `"skills/review"`, `"a/./b"`
(normalised); rejects `""`, `"/etc/passwd"`, `"../x"`, `"a/../../x"`, `".."`, `"a/.."`,
`"a\\..\\b"`, `"a\0b"`. `safeItemName` additionally rejects `"a/b"`, `"."`,
`".hidden"`. `safeUnder "/base" "/abs"` is `Left` (this is the exact `</>`-discards-base
case). `stripYamlFrontmatter` cases: LF frontmatter stripped; CRLF frontmatter
(`"---\r\nname: x\r\n---\r\nBody.\r\n"`) yields a body containing no `name:` and no
`\r`; no frontmatter unchanged; unterminated frontmatter unchanged; closing `---` as
the last line with no trailing newline stripped. Filesystem, using
`withPreparedKitHome` extended to also write a malicious manifest entry: a skill whose
`files` contains `"../../../../escape.txt"` — `try @ExitCode (installItem config
"evil" UserScope)` returns `Left (ExitFailure 1)` and `<tmp>/escape.txt` (and every
ancestor outside the temp home) does not exist; `uninstallItem config "../victim"
UserScope` against a planted `<home>/victim` directory exits nonzero and leaves the
directory in place. (`exitFailure` throws the `ExitCode` exception, which
`Control.Exception.try @ExitCode` catches in-process; import `System.Exit (ExitCode
(..))` in the test.)

Acceptance: `cabal test baikai-kit` passes; temporarily reverting the `Install.hs`
wiring makes the zip-slip test fail by finding `escape.txt` on disk, proving the test
exercises the vulnerability.

### Milestone 2 — Truthful status: scan-keyed sidecars, richer states, principled sidecar paths

Scope: findings 8.2 (dirty hidden behind outdated), 8.3 (delisted items reported
unknown), and 8.5 (suffix-chopped sidecar path). At the end, `kit status` shows
`dirty+outdated` when both facts hold and `delisted` (with the installed version read
from the sidecar) for installed items no longer in the manifest, and the sidecar path
derivation no longer depends on hardcoded extension chopping.

First the enabling refactor. In `baikai-kit/src/Baikai/Kit/Manifest.hs` add:

```haskell
data KitItemKind = SkillKind | AgentKind
  deriving stock (Eq, Ord, Show)

kitItemKind :: KitItem -> KitItemKind
kitItemKind KitSkillItem {} = SkillKind
kitItemKind KitAgentItem {} = AgentKind

kindLabel :: KitItemKind -> Text
kindLabel SkillKind = "skill"
kindLabel AgentKind = "agent"
```

and export them. In `baikai-kit/src/Baikai/Kit/Sidecar.hs` change `sidecarPath` to be
keyed by kind and name instead of a `KitItem`:

```haskell
sidecarPath :: AgentAssetProvider -> KitItemKind -> Text -> FilePath -> Text -> FilePath
sidecarPath provider SkillKind itemName targetBase sidecarName =
  targetBase
    </> skillTargetPath provider InteractiveProjectScope (Text.unpack itemName)
    </> Text.unpack sidecarName
sidecarPath provider AgentKind itemName targetBase sidecarName =
  targetBase
    </> dropExtension (agentTargetPath provider InteractiveProjectScope (Text.unpack itemName))
      <> Text.unpack sidecarName
```

`System.FilePath.dropExtension` removes the last extension whatever it is, so
`reviewer.md` and `reviewer.toml` both become `reviewer`, and a hypothetical future
`.yaml` provider works unchanged; the reversed-string `dm.`/`lmot.` matching is deleted.
The on-disk sidecar name (`reviewer` + `.testkit-kit.json`, because `sidecarFileName`
starts with a dot) is byte-identical to before, so existing installs remain readable —
the existing round-trip test's hardcoded expectations must not change. Update the
callers: `writeSidecar` passes `kitItemKind item` and `itemName item`; in `Install.hs`,
`agentSidecarTarget` becomes `sidecarPath provider AgentKind n targetBase (sidecarFileName
config)` and the `dummyAgent` fabrication is deleted.

Now the status fixes, in `baikai-kit/src/Baikai/Kit/Status.hs`. Change `scanInstalled`
to return `KitItemKind` instead of the kind `Text` (adjust `scanSkills`/`scanAgents`
and reuse `kindLabel` where the row needs text). In `collectStatus`, read the sidecar
from the scan, unconditionally:

```haskell
mSidecar <- readSidecar (sidecarPath provider scannedKind itemName' baseDir (sidecarFileName config))
```

so a delisted item's sidecar is found. `installedVersion = mSidecar >>= (^. #version)`
already does the right thing once `mSidecar` is populated.

Extend the state enum and rework `classify`:

```haskell
data KitState
  = KitUpToDate
  | KitOutdated
  | KitDirty
  | KitDirtyOutdated
  | KitDelisted
  | KitUnknown
  deriving stock (Eq, Ord, Show)

renderState :: KitState -> Text
renderState = \case
  KitUpToDate -> "up-to-date"
  KitOutdated -> "outdated"
  KitDirty -> "dirty"
  KitDirtyOutdated -> "dirty+outdated"
  KitDelisted -> "delisted"
  KitUnknown -> "unknown"

classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
classify Nothing _ _ = KitUnknown
classify (Just _) Nothing _ = KitDelisted
classify (Just sm) (Just it) mUpstreamHash =
  let outdated = case itemVersion it of
        Just latest -> (sm ^. #version) /= Just latest
        Nothing -> False
      dirty = case mUpstreamHash of
        Just up -> up /= sm ^. #hash
        Nothing -> False
   in case (outdated, dirty) of
        (True, True) -> KitDirtyOutdated
        (True, False) -> KitOutdated
        (False, True) -> KitDirty
        (False, False) -> KitUpToDate
```

Semantics note for the reader: "dirty" in this package means the *cached upstream*
content hash no longer matches the hash recorded at install time (the sidecar); per
`docs/user/kit.md` it does not hash the provider-installed target files. The finding is
that the version check short-circuited and hid this fact whenever the version also
changed — after `classify` above, both facts are always visible, and a user about to run
`kit update` can see that content drifted independently of the version bump. The
`aggregateStatusRows` grouping from commit `a219ace` keys on the state value and needs
no change beyond `KitState`'s extended `Ord`.

Existing tests to update in `baikai-kit/test/Main.hs`: "no upstream entry => unknown"
becomes `KitDelisted`; "version mismatch beats hash mismatch => outdated" becomes
"version and hash mismatch => dirty+outdated" asserting `KitDirtyOutdated`. New pure
tests: `classify (Just sidecar) Nothing anything @?= KitDelisted`; a direct `sidecarPath`
unit test asserting the Claude and Codex agent sidecar paths equal
`".claude/agents/reviewer" <> sidecarName` and `".codex/agents/reviewer" <> sidecarName`
respectively. New filesystem test: with `withPreparedKitHome`, install `demo`, then
overwrite the cache's `kit.json` with a manifest that omits `demo`, run `collectStatus
config cache [(UserScope, "user")]` and assert the `demo` rows have `state = KitDelisted`
and `installedVersion = Just "0.1.0"`; separately, install `demo`, then bump the
manifest version *and* modify the cached `SKILL.md`, and assert `KitDirtyOutdated`
(`collectStatus` is already exported, so rows can be asserted directly without parsing
table output).

Also update `docs/user/kit.md`: in the "Status And Sidecars" states list, add
`dirty+outdated` ("both of the above") and `delisted` ("the sidecar is valid but the
item is no longer in the manifest"), and reword `unknown` to "the sidecar is missing or
unreadable".

Acceptance: `cabal test baikai-kit` passes including the two new filesystem status
tests; running any downstream tool's `kit status` after hand-editing its cache shows the
new states (optional manual check — the automated tests are the gate).

### Milestone 3 — Robust install, truthful uninstall, loud update failures

Scope: findings 8.4 (no failure isolation/rollback in multi-provider install), 8.8
(misleading uninstall reporting), and 8.6 (update prints success on failed pull). At the
end, an install either completes for every provider or changes nothing; uninstall output
names exactly what was removed; and `kit update` exits nonzero when the pull fails.

Staged install, in `baikai-kit/src/Baikai/Kit/Install.hs`. Introduce two internal
types (bare field names, per the repository rule):

```haskell
data PlannedWrite = PlannedWrite
  { destination :: !FilePath,
    content :: !WriteContent
  }

data WriteContent
  = CopyFrom !FilePath
  | WriteBytes !LBS.ByteString
```

Refactor `doInstall` into plan-then-execute. `planInstall :: KitConfig -> FilePath ->
KitItem -> KitScope -> IO [PlannedWrite]` performs all of Milestone 1's validation,
checks with `doesFileExist` that every source file exists in the cache, reads the agent
body and applies `agentAsCodexToml` at plan time (so a missing or unreadable source
fails before anything is written), obtains one `SidecarMeta` per item via a new
`newSidecarMeta :: KitItem -> Text -> IO SidecarMeta` in
`baikai-kit/src/Baikai/Kit/Sidecar.hs` (the existing `writeSidecar` body minus the file
write; keep `writeSidecar` exported and reimplement it on top), and returns the writes
for *all* configured providers — asset files and sidecars — as data. `executePlan ::
[PlannedWrite] -> IO ()` then runs two phases: phase one creates each destination's
parent directory (`createDirectoryIfMissing True`) and writes every `content` to
`destination <> ".baikai-kit-tmp"`, accumulating the temp paths; if any step throws, it
best-effort deletes the accumulated temp files (`removeFile` wrapped in `try
@IOException`) and rethrows. Phase two renames every temp onto its `destination` with
`System.Directory.renameFile` (same-directory rename, atomic on POSIX). `installItem`
wraps the whole thing in `try @IOException`; on `Left` it prints `"Error: install
failed, no changes were made: " <> show e` to stderr and exits nonzero. Empty
directories created in phase one may survive a rollback; that is harmless and accepted
(see Idempotence and Recovery). `reinstallIfPresent` and `reinstallAllPresent` go
through the same plan/execute path automatically since they call `doInstall`.

Truthful uninstall, same file. Replace the anonymous per-provider booleans with:

```haskell
data RemovalOutcome = RemovalOutcome
  { provider :: !AgentAssetProvider,
    skillRemoved :: !Bool,
    agentRemoved :: !Bool,
    sidecarRemoved :: !Bool
  }

uninstallOutcomes :: KitConfig -> Text -> KitScope -> IO [RemovalOutcome]

renderUninstallReport :: Text -> KitScope -> [RemovalOutcome] -> Text
```

`uninstallOutcomes` is the existing removal loop (after Milestone 1's `safeItemName`
gate) returning one outcome per provider. `renderUninstallReport` is pure: if any
outcome removed a skill or agent, the line is `"Uninstalled <kinds> '<name>' from
<scope> scope (<providers>)."` where `<kinds>` is the deduplicated, `"+"`-joined list of
kinds actually removed (normally just `skill` or `agent`; both only in a corrupted
layout) and `<providers>` is the comma-joined labels of providers where an asset was
removed; else if any outcome removed only a sidecar, `"Removed stale kit metadata for
'<name>' from <scope> scope."`; else `"'<name>' is not installed in <scope> scope."`.
`uninstallItem` becomes `uninstallOutcomes` + `Text.IO.putStrLn . renderUninstallReport`.
Export `RemovalOutcome (..)`, `uninstallOutcomes`, and `renderUninstallReport` from the
module so the renderer is unit-testable. Reuse `providerLabel` — move it from
`Status.hs` into `Baikai.Kit.Config` (exported) so both modules share one definition
instead of duplicating it.

Loud update failures, in `baikai-kit/src/Baikai/Kit/Repo.hs`:

```haskell
data PullResult
  = PullSucceeded
  | PullFailed !Text
  deriving stock (Eq, Show)

pullKitRepo :: KitConfig -> FilePath -> IO PullResult
```

`pullKitRepo` no longer prints; it returns `PullFailed` carrying the git stderr (or the
`IOException` text when `git` itself could not run). `ensureKitRepo` keeps today's
behavior by printing the warning itself on `PullFailed` and continuing with the cache.
In `Install.hs`, `updateKit`'s existing-cache branch becomes: on `PullSucceeded` print
"Kit repository updated." and proceed to reinstall; on `PullFailed err` print `"Error:
failed to update kit repository: " <> err` and `"The cached copy is unchanged;
installed items were not reinstalled."` to stderr and `exitFailure` — no success line,
no reinstall from stale content. Export `PullResult (..)` from `Baikai.Kit.Repo`.

Tests, in `baikai-kit/test/Main.hs`. Rollback: in a prepared home, create
`<home>/.codex` as a *file* (`BS.writeFile (home </> ".codex") ""`) so the Codex agent
write cannot create its parent directory; `try @ExitCode (installItem config "reviewer"
UserScope)` returns `Left (ExitFailure 1)`, and afterwards the Claude agent target
`<home>/.config/testkit/agents/.claude/agents/reviewer.md` does not exist, its sidecar
does not exist, and no `*.baikai-kit-tmp` file exists anywhere under `<home>` (walk with
`listDirectory` recursively or check the two parent dirs) — proving the claude half was
rolled back, not left installed. Uninstall rendering (pure): outcomes with one provider
skill-removed render the skill line naming `claude`; both providers render
`claude,codex`; sidecar-only renders the stale-metadata line; all-false renders
not-installed. Uninstall filesystem: install `demo`, delete the Codex skill directory by
hand, run `uninstallOutcomes` and assert claude reports `skillRemoved = True` while
codex reports all-false. Pull failure: the prepared home's cache contains a fake `.git`
directory, so `pullKitRepo testConfig cache` returns `PullFailed _` (assert with a
pattern match), and `try @ExitCode (updateKit testConfig Nothing)` returns
`Left (ExitFailure 1)`.

Acceptance: `cabal build all --enable-tests` and `cabal test baikai-kit` pass; the
rollback test fails against the pre-milestone code (the claude file survives), proving
it exercises the fix.


## Concrete Steps

All commands run from the repository root (the directory containing `cabal.project`).
Iterate per milestone in this order: edit sources, then build, then test.

```bash
cabal build baikai-kit --enable-tests
cabal test baikai-kit
```

Expected test output shape on success (names will match the groups added by each
milestone):

```text
baikai-kit
  Manifest backward compatibility
    mori-kit.json decodes:                                       OK
    ...
  Path safety
    safeRelativePath rejects zip-slip and absolute paths:        OK
    install refuses a manifest that escapes the install root:    OK
    uninstall refuses a traversal name:                          OK
  Frontmatter
    stripYamlFrontmatter handles CRLF:                           OK
  Status.classify
    version and hash mismatch => dirty+outdated:                 OK
    delisted item with sidecar => delisted:                      OK
  Install
    failed provider write rolls back all providers:              OK
    ...

All N tests passed
```

A failing test prints `FAIL` with the assertion message (for example, `expected file to
be missing: /tmp/.../reviewer.md`); treat any `FAIL` or a nonzero exit from `cabal
test` as not-done. Before finishing, run the full workspace build to confirm nothing
outside `baikai-kit` regressed:

```bash
cabal build all --enable-tests
cabal test baikai-kit
```

Commit per milestone with conventional-commit messages, for example:

```text
fix(kit): sanitize manifest paths against traversal and zip-slip
fix(kit): report dirty+outdated and delisted states truthfully
fix(kit): stage installs, report uninstalls honestly, fail update on pull error
```

Update the Progress checklist and (if anything unexpected surfaced) Surprises &
Discoveries in this file at every stopping point.


## Validation and Acceptance

The change is accepted when all of the following hold, each demonstrated by a named
test in `baikai-kit/test/Main.hs` run via `cabal test baikai-kit` from the repository
root:

1. Installing a skill whose manifest lists `files: ["../../../../escape.txt"]` exits
   nonzero with an "unsafe" error on stderr and creates no file outside the temp home;
   `safeUnder "/base" "/etc/passwd"` is a `Left` (the `</>`-discards-base case is
   covered by a pure test).
2. `uninstallItem` with the name `"../victim"` exits nonzero and the planted
   `<home>/victim` directory still exists.
3. `classify` on a sidecar whose version differs from the manifest *and* whose hash
   differs from upstream returns `KitDirtyOutdated`, rendered `dirty+outdated` in the
   status table.
4. After installing an item and removing it from the cached `kit.json`, `collectStatus`
   returns rows for it with `state = KitDelisted` and the installed version populated
   from the sidecar (not `-`).
5. A forced failure on the second provider during `installItem` leaves no first-provider
   asset, no sidecar, and no `*.baikai-kit-tmp` residue: the observable outcome of a
   failed install is "nothing changed" plus a nonzero exit.
6. `sidecarPath` for agents equals the provider target path with its extension dropped
   plus the sidecar file name, for both providers, via `System.FilePath.dropExtension`
   (pure unit test), and the existing install round-trip test still finds sidecars at
   the same on-disk paths as before this plan.
7. `pullKitRepo` against a cache with a fake `.git` returns `PullFailed`, and
   `updateKit` in that situation exits nonzero and never prints "Kit repository
   updated.".
8. `stripYamlFrontmatter` on a CRLF-encoded agent file returns only the body (no YAML
   keys, no `\r`), and the generated Codex TOML for such an agent contains
   `developer_instructions` without the frontmatter text.
9. Uninstall reporting: removing an item installed for both providers produces one line
   naming the actual kind and both provider labels; an on-disk state where only a stale
   sidecar remains produces the stale-metadata line, not an "Uninstalled" line.

Beyond the suite, a manual smoke (optional, requires any downstream tool built against
this package) follows the isolated-`HOME` recipe in `docs/user/kit.md`'s "Smoke Checks"
section; with a kit repo edited to include a traversal path, `kit install` must refuse.


## Idempotence and Recovery

All edits are ordinary source changes; re-running builds and tests is always safe. The
filesystem tests run under `withSystemTempDirectory` and set/restore `HOME`, so they
neither read nor write real user state and can be re-run indefinitely.

The staged installer is itself the recovery mechanism it tests: re-running a failed
`kit install` after fixing the cause converges to the fully installed state, because
phase one overwrites any leftover `*.baikai-kit-tmp` file and phase two overwrites the
destinations. A rollback may leave freshly created empty directories (for example an
empty `.codex/agents/`); this is cosmetic, causes no behavior change anywhere in the
package (scans return empty lists for empty directories), and is deliberately not
cleaned up to keep the rollback path simple and safe.

If a milestone must be abandoned midway, `git restore` the touched files under
`baikai-kit/` — no generated artifacts or migrations are involved. Milestone 2 changes
the signature of `sidecarPath` and Milestone 3 changes `pullKitRepo`; both are
re-exported through `Baikai.Kit`, so after each milestone `cabal build all
--enable-tests` must be run to confirm no other workspace package (none is known to
import them today) breaks.


## Interfaces and Dependencies

No new package dependencies are required: `filepath` (validation, `dropExtension`),
`directory` (`renameFile`, existence checks), `bytestring`, `aeson`, `text`, `process`,
and the test-side `tasty`/`tasty-hunit`/`temporary` are already declared in
`baikai-kit/baikai-kit.cabal`. The only cabal change is adding `Baikai.Kit.Path` to the
library's `exposed-modules`.

At the end of Milestone 1 these exist:

```haskell
-- baikai-kit/src/Baikai/Kit/Path.hs (new module, exported via Baikai.Kit)
safeRelativePath :: Text -> Either Text FilePath
safeItemName     :: Text -> Either Text FilePath
safeUnder        :: FilePath -> Text -> Either Text FilePath

-- baikai-kit/src/Baikai/Kit/Install.hs (added to the export list)
stripYamlFrontmatter :: Text -> Text
```

At the end of Milestone 2:

```haskell
-- baikai-kit/src/Baikai/Kit/Manifest.hs
data KitItemKind = SkillKind | AgentKind
kitItemKind :: KitItem -> KitItemKind
kindLabel   :: KitItemKind -> Text

-- baikai-kit/src/Baikai/Kit/Sidecar.hs (changed signature)
sidecarPath :: AgentAssetProvider -> KitItemKind -> Text -> FilePath -> Text -> FilePath

-- baikai-kit/src/Baikai/Kit/Status.hs
data KitState = KitUpToDate | KitOutdated | KitDirty | KitDirtyOutdated | KitDelisted | KitUnknown
```

At the end of Milestone 3:

```haskell
-- baikai-kit/src/Baikai/Kit/Repo.hs
data PullResult = PullSucceeded | PullFailed !Text
pullKitRepo :: KitConfig -> FilePath -> IO PullResult

-- baikai-kit/src/Baikai/Kit/Sidecar.hs
newSidecarMeta :: KitItem -> Text -> IO SidecarMeta

-- baikai-kit/src/Baikai/Kit/Install.hs
data RemovalOutcome = RemovalOutcome
  { provider :: !AgentAssetProvider, skillRemoved :: !Bool, agentRemoved :: !Bool, sidecarRemoved :: !Bool }
uninstallOutcomes     :: KitConfig -> Text -> KitScope -> IO [RemovalOutcome]
renderUninstallReport :: Text -> KitScope -> [RemovalOutcome] -> Text

-- baikai-kit/src/Baikai/Kit/Config.hs (moved from Status.hs)
providerLabel :: AgentAssetProvider -> Text
```

`PlannedWrite`/`WriteContent` stay internal to `Baikai.Kit.Install` (not exported). All
record fields use bare names with no Hungarian-style prefixes; `DuplicateRecordFields`
and `OverloadedLabels` are already default extensions in this package, so the `provider`
and `name` field reuse across records is legal. The signature changes to `sidecarPath`
and `pullKitRepo` are API-breaking for `baikai-kit` (version left to the release
tooling; see the Decision Log) and are flagged for EP-10
(`docs/plans/43-tighten-the-public-surface-and-sweep-the-docs.md`) to consider
internalizing before the API freeze.
