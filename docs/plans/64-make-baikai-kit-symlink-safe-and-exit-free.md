---
id: 64
slug: make-baikai-kit-symlink-safe-and-exit-free
title: "Make baikai-kit symlink-safe and exit-free"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Make baikai-kit symlink-safe and exit-free

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`baikai-kit` is the shared installer that lets a command-line tool ship a git-hosted
"kit" of agent skills and subagents: it clones the kit repository into a cache under
`~/.cache/<tool>/kit`, reads a `kit.json` manifest, copies provider-native files into
the Claude Code and Codex discovery directories, writes a small JSON "sidecar" next to
each installed asset, and reports install status. Four tools in this workspace
(`mori`, `rei`, `seihou`, `okf`) embed it as their `kit` subcommand.

Today the installer has three defects a user can hit. First, its path safety is
purely lexical: it rejects `..` and absolute paths in the manifest, but git checks out
committed symbolic links, so a kit repository that commits `skills/x/sub -> /` and lists
`files: ["sub/etc/passwd"]` has that file read through the link and copied into
`~/.claude/skills/x/sub/etc/passwd`, a directory the agent reads. Second, the library
calls `exitFailure` from inside ordinary functions (`loadManifest`, `installItem`,
`listAvailable`, `updateKit`, `ensureKitRepo`), so an application that embeds
`Baikai.Kit` has its whole process terminated on a missing manifest, an unsafe name, or
a first clone that fails offline; `kit status` on a fresh machine without network exits
1 instead of reporting that nothing is installed. Third, install fidelity has gaps: an
agent that lists several `files` installs only the first; a failure during the final
rename phase leaves earlier renames in place while the message says "no changes were
made"; the temporary file name is fixed, so two concurrent installs of one item clobber
each other; the manifest `version` is decoded and never checked; and `kit update`
silently overwrites installed files the user has edited by hand.

After this plan, a source path that is a symbolic link, contains a symbolic link, or
resolves outside the kit checkout is refused by install, by the content hash, and by
`kit status` (which shows a new `refused` state instead of reading through the link).
Every library function returns `Either KitError a` and never exits; only the command
adapter `Baikai.Kit.Command.runKit` prints and exits, and `kit status` offline on a
fresh home prints "No kit items installed." and exits 0. Every listed agent file is
installed, a failure in the rename phase restores what was there before, temporary
files carry unique names, a manifest with an unsupported `version` is refused with a
clear message, and `kit update` skips items whose installed files were modified locally
unless `--force` is given. `docs/user/kit.md` and the capability record
`docs/capabilities/kit-installer.md` describe exactly this behaviour. Everything is
observable by running `cabal test baikai-kit` from the repository root: the new tests
fail against the current code and pass after the fixes. This plan is EP-7 of
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`, owns
`baikai-kit/` entirely, has no dependency on any other plan, and continues the work of
`docs/plans/35-harden-baikai-kit-install-and-status.md`, whose accepted "purely
lexical" invariant it overturns.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented
here, even if it requires splitting a partially completed task into two ("done" vs.
"remaining"). This section must always reflect the actual current state of the work.

- [ ] Milestone 1: create `baikai-kit/src/Baikai/Kit/Error.hs` with `KitError` and `renderKitError`; add `safeSourcePath` to `baikai-kit/src/Baikai/Kit/Path.hs` and delete `safeUnder`; add `itemSources` to `baikai-kit/src/Baikai/Kit/Manifest.hs`.
- [ ] Milestone 1: route `computeKitHash` (`Sidecar.hs`), `planInstall` (`Install.hs`) and `upstreamHash` (`Status.hs`) through `safeSourcePath`; add `KitUpstreamRefused` to `KitState`.
- [ ] Milestone 1: symlink fixture tests (install, hash, status) green; `cabal build all --enable-tests` green.
- [ ] Milestone 2: `ensureKitRepo` returns `Either KitError KitRepo`; `loadManifest`/`loadManifestMaybe` return typed errors; `installItem`, `installFrom`, `listAvailable`, `updateKit`, `uninstallItem`, `kitStatus` return `Either`/reports; `requireSafe` deleted; no `exitFailure` remains outside `Baikai.Kit.Command`.
- [ ] Milestone 2: `runKitCommand` and the exiting `runKit` in `Command.hs`; existing `try @ExitCode` tests moved onto `runKit`; offline-status test green.
- [ ] Milestone 2: ADR `docs/adr/NNNN-library-code-never-calls-exitfailure.md` written and indexed in `docs/adr/README.md`.
- [ ] Milestone 3: multi-file agents installed under `<agents dir>/<name>/`; destination pre-check; `openTempFile` temp names; journaled phase two with backups and restore; `executePlanWith` test seam.
- [ ] Milestone 3: manifest `version` gate (`supportedManifestVersions = [1, 2]`); `installedFiles`/`installedHash` in `SidecarMeta`; `reinstallPresent` with `OverwritePolicy`; `--force` on `kit update`; `stripYamlFrontmatter` normalises every branch.
- [ ] Milestone 3: fidelity tests green; `CHANGELOG.md` `[Unreleased]` entries written.
- [ ] Milestone 4: `docs/user/kit.md`, `docs/capabilities/kit-installer.md` and `docs/capabilities/log.md` updated; `okf validate docs/capabilities` green; keyless `cabal test all` gate green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The symlink rule is "a kit is plain files": a source path is refused if any
  component below the kit checkout is a symbolic link (checked with
  `System.Directory.pathIsSymbolicLink` on every prefix of the relative path), or if
  its canonical form (`System.Directory.canonicalizePath`) is not component-wise below
  the canonical form of the checkout. Both checks run even though the first implies the
  second for the paths we walk; the second is defence in depth against a symlinked
  ancestor we did not walk. Symlinks that point *inside* the checkout are refused too.
  Rationale: refusing every link is simpler to explain and test than following links
  and deciding where they land, no existing kit uses symlinks (the three fixtures under
  `baikai-kit/test/fixtures/` are plain files), and copying files is the only thing the
  installer does with a source, so a link never adds anything a plain file could not.
  The check is check-then-read (a TOCTOU window): between `pathIsSymbolicLink` and the
  read, a process with write access to `~/.cache/<tool>/kit` could swap a file for a
  link. That directory is owned by the invoking user and written only by `git`, which
  runs before the check in the same command, so the residual threat is a local process
  already running as the user; it is accepted and documented.
  Date: 2026-08-27
- Decision: The check lives in one function, `Baikai.Kit.Path.safeSourcePath ::
  FilePath -> FilePath -> IO (Either KitError FilePath)` (kit root, relative path), and
  install (`planInstall`), the content hash (`computeKitHash`) and status
  (`upstreamHash`) all resolve every source file through it. The relative path is
  derived by a new pure `Baikai.Kit.Manifest.itemSources`, which replaces the
  unsanitised joins in `Status.upstreamHash`/`agentSourceBase` and the exported
  `agentSources`. The unused `safeUnder` is deleted.
  Rationale: plan 35's lesson was that one validated entry point is auditable; the
  symlink residual exists precisely because `Status.hs` grew a second, unsanitised join
  after that plan. One physical check plus one pure source-list derivation removes both.
  Date: 2026-08-27
- Decision: Errors are a closed sum type `Baikai.Kit.Error.KitError` (constructors
  prefixed `Kit…`, matching `KitState`'s naming), rendered by `renderKitError ::
  KitError -> Text`, and every library function returns `Either KitError a` rather than
  throwing. `KitError` also gets an `Exception` instance so a consumer that prefers
  exceptions can `either throwIO pure`. `IOException`s the library anticipates on its
  own paths (reading the manifest, inspecting sources, writing targets, running `git`)
  are caught and wrapped; anything else propagates.
  Rationale: the three registered consumers that call the library directly today
  (`rei-cli` calls `ensureKitRepo`, `loadManifest` and `installItem`; `mori-cli`,
  `seihou-cli` and `okf-cli` call only `runKit`) are all command-line programs that want
  to render the failure and choose their own exit code. An `Either` makes the change
  visible at compile time in `rei-cli` — the compiler flags every call site — whereas a
  thrown `KitException` would compile unchanged and keep terminating their process with
  an uncaught exception, which is the silent break the MasterPlan forbids. `Either` also
  matches the package's existing `PullResult` and `Either Text` conventions.
  Date: 2026-08-27
- Decision: Exit lives only in `Baikai.Kit.Command`: `runKitCommand :: KitConfig ->
  KitCommand -> IO (Either KitError ())` performs a verb and prints its normal output;
  `runKit :: KitConfig -> KitCommand -> IO ()` keeps its signature, prints `Error: …` to
  stderr and calls `exitWith (ExitFailure 1)` on `Left`. Every `KitError` maps to exit
  code 1.
  Rationale: `runKit` is the documented adapter every consumer uses, so keeping its
  signature means `mori`, `seihou` and `okf` need no code change for exit behaviour; a
  richer exit-code vocabulary (sysexits) belongs to the consumer's CLI, which can use
  `runKitCommand` and map `KitError` itself. Exit code 1 is what today's tests assert.
  Date: 2026-08-27
- Decision: Signatures that change (all exported through the `Baikai.Kit` umbrella
  unless marked internal): `loadManifest :: FilePath -> IO (Either KitError
  KitManifest)`; `loadManifestMaybe :: FilePath -> IO (Either KitError (Maybe
  KitManifest))`; `installItem :: KitConfig -> Text -> KitScope -> IO (Either KitError
  KitItem)`; new `installFrom :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope
  -> IO (Either KitError KitItem)`; `listAvailable :: KitConfig -> IO (Either KitError
  KitManifest)` plus new pure `renderAvailable`; `updateKit :: KitConfig -> Maybe Text ->
  OverwritePolicy -> IO (Either KitError UpdateReport)`; new `reinstallPresent`;
  `uninstallItem :: KitConfig -> Text -> KitScope -> IO (Either KitError
  [RemovalOutcome])` (absorbing `uninstallOutcomes`, which is removed);
  `ensureKitRepo :: KitConfig -> IO (Either KitError KitRepo)`; `kitStatus :: KitConfig
  -> IO StatusReport` plus pure `renderStatusTable`; `computeKitHash :: FilePath ->
  FilePath -> [FilePath] -> IO (Either KitError Text)`; `newSidecarMeta` gains the
  installed-file arguments; `SidecarMeta` gains two optional fields; `KitCommand`'s
  `KitUpdate` gains an `OverwritePolicy` argument; `KitState` gains `KitUpstreamRefused`;
  removed: `requireSafe` (was internal), `safeUnder`, `uninstallOutcomes`,
  `agentSources`, `writeSidecar`; internal `reinstallIfPresent`, `reinstallAllPresent`
  and `isInstalled` return `Either` and are folded into `reinstallPresent`.
  Rationale: each is either a function that exited, a function that printed a
  library-owned message, or a function whose result the CLI must now render itself.
  Date: 2026-08-27
- Decision: These are PVP-major changes for `baikai-kit` (0.1.0.4 → 0.2.0.0), but this
  plan does not bump the version: bumps are owned by EP-10,
  `docs/plans/67-freeze-the-public-surface.md`. This plan records every change under
  `## [Unreleased]` in `CHANGELOG.md` in the same commits as the code, and the
  Interfaces section lists the downstream edits each consumer will need when it moves
  its `baikai-kit ^>=0.1.0.x` bound to `0.2`.
  Rationale: MasterPlan rule ("Version bumps are owned by EP-10"); consumers' caret
  bounds mean the changes cannot reach them until they opt in.
  Date: 2026-08-27
- Decision: A multi-file agent (`files: [a, b, …]`) installs its first file as the
  provider's agent file (`.claude/agents/<name>.md`, or the Codex TOML rendered from it)
  and every remaining file under a resource directory named after the agent beside it
  (`<agents dir>/<name>/<file>`). Uninstall removes that directory with the agent.
  Rationale: `docs/user/kit.md` already promises "each listed file is copied"; the
  agents directories of both providers are flat, so extra Markdown files placed there
  directly would be discovered as bogus agents, and a sibling directory mirrors how
  skills already own a directory. The status scan ignores the directory because it
  filters on the agent file extension.
  Date: 2026-08-27
- Decision: `executePlan` becomes a journaled two-phase write. Before any write, every
  destination is checked not to be a directory. Phase one writes each payload to a
  uniquely named temporary file in the destination directory obtained from
  `System.IO.openTempFile` with template `<file name>.baikai-kit-tmp`. Phase two, per
  entry, moves an existing destination aside to a unique `.baikai-kit-bak` name, then
  renames the temporary into place, recording both in a journal; a failure restores
  every completed entry in reverse order (backup renamed back, or the new file removed),
  deletes the remaining temporaries, and returns `KitWriteFailed reason restored
  leftInconsistent` naming any path whose restore also failed. Success deletes the
  backups.
  Rationale: plan 35 accepted an unrolled phase two and a fixed temp name; REV-2
  observed that the failure message then lies and that two concurrent installs clobber
  each other. Same-directory renames stay atomic on POSIX, so the observable states are
  "everything installed", "everything as before", or a truthful list of what could not
  be restored. `openTempFile` creates the file with mode 0600, so installed files are
  now owner-readable only; both providers run as the invoking user and git does not
  track that mode, so nothing observable changes. Concurrent installs of one item still
  race on the final rename, but each rename installs a complete file.
  Date: 2026-08-27
- Decision: The manifest `version` is gated: `supportedManifestVersions = [1, 2]` in
  `Baikai.Kit.Manifest`; `loadManifest` returns `KitManifestVersionUnsupported` for any
  other value.
  Rationale: the three real manifests in `baikai-kit/test/fixtures/` declare 1 and 2 and
  decode identically; a future version 3 with different semantics must be refused with
  a clear message rather than misinstalled.
  Date: 2026-08-27
- Decision: "Dirty-update refusal" is implemented as *local-modification* refusal, not
  as a gate on the `dirty` state. Each provider sidecar records `installedFiles` (the
  files this tool wrote for that provider, relative to the provider target) and
  `installedHash` (the content hash of exactly those bytes). `kit update` recomputes
  that hash from the files on disk and skips an item at a scope when any provider's hash
  differs, printing how to force; `kit update --force` (`OverwriteLocalEdits`)
  reinstalls anyway. Sidecars written before this plan lack the fields and are updated
  without the check. `kit status` does not gain a "modified" state.
  Rationale: in this package `dirty` means the cached *upstream* content differs from
  what was installed (`docs/user/kit.md`, "Status And Sidecars"), which is exactly the
  case `update` exists to apply, so refusing on `dirty` would refuse every real update.
  The hazard the MasterPlan names is overwriting a user's local edits, and only a hash
  of what was actually written can detect that. Extending `KitState` would multiply its
  combinations; the refusal message at update time is where the user needs the fact.
  Date: 2026-08-27
- Decision: `ensureKitRepo` returns `KitRepo { dir, refresh }` with `RepoRefresh =
  RepoCloned | RepoPulled | RepoStale Text` and never prints. A first clone that fails
  with no usable cache is `Left (KitCloneFailed url output)`. `kit status` treats a
  `Left` as "no upstream" (`UpstreamUnavailable`), prints a note on stderr and exits 0;
  `kit list` and `kit install` treat it as an error; all three print a warning and
  continue from the cache on `RepoStale`. `kit update` treats a failed pull as an error
  (unchanged from plan 35).
  Rationale: status reports what is installed, which needs no network; list and install
  need the manifest and cannot proceed without it; the warn-and-use-cache behaviour that
  plan 35 kept is preserved, but rendered by the CLI rather than printed by the library.
  Date: 2026-08-27
- Decision: `stripYamlFrontmatter` normalises line endings to LF on every branch,
  including input without frontmatter and unterminated frontmatter, and matches the
  `---` delimiter after stripping trailing spaces, tabs and `\r`.
  Rationale: plan 35 normalised only the stripped branch, so a CRLF agent file without
  frontmatter still leaked `\r` into the Codex TOML.
  Date: 2026-08-27
- Decision: New record types (`KitRepo`, `UpdateReport`, `StatusReport`, `ItemSources`)
  use bare field names with no Hungarian-style prefixes; `DuplicateRecordFields` and
  `OverloadedLabels` are default extensions in `baikai-kit/baikai-kit.cabal`.
  Rationale: repository-wide rule, including internal records.
  Date: 2026-08-27
- Decision: This plan creates the ADR "library code never calls `exitFailure`" under
  the plain-file convention of `docs/adr/0001-architecture-decision-record-convention.md`,
  slug `library-code-never-calls-exitfailure`, numbered with the next free number at
  implementation time (other plans of this MasterPlan also create ADRs).
  Rationale: the MasterPlan assigns this decision to EP-7, and it constrains every
  package, not only `baikai-kit`.
  Date: 2026-08-27


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

The `baikai-kit` package lives in `baikai-kit/` at the repository root. Its library
modules are under `baikai-kit/src/Baikai/Kit/` and are re-exported wholesale by the
umbrella module `baikai-kit/src/Baikai/Kit.hs`; any new module must be added both to
`exposed-modules` in `baikai-kit/baikai-kit.cabal` and to that umbrella. The single test
suite is `baikai-kit/test/Main.hs` (tasty, tasty-hunit, temporary), and the package
builds with `cabal build baikai-kit` and tests with `cabal test baikai-kit`, both from
the repository root (the directory containing `cabal.project`). The toolchain is GHC
9.12.4 with `directory` 1.3.10.1, `filepath` 1.5.5.0 and `process` 1.6.26.1 (from
`ghc-pkg field <pkg> version`); these boot libraries are not registered in the Mori
registry, so their APIs are described in this plan rather than located on disk.

Terms used throughout. A *kit* is a git repository whose root holds a `kit.json`
*manifest* listing skills (each with a `name`, a repo-relative directory `path`, and a
list of `files` below it) and agents (each with a `name`, a `path`, and an optional
`files` list; without `files`, `path` is the single source file). The manifest is
attacker-controlled from the installer's point of view: users point their tool at
arbitrary git URLs. A *sidecar* is the small JSON file the installer writes next to each
installed asset (`SidecarMeta` in `baikai-kit/src/Baikai/Kit/Sidecar.hs`) recording the
item name, kind, version, install time and a content hash of the upstream source files;
its file name is `.<tool>-kit.json` (`sidecarFileName` in
`baikai-kit/src/Baikai/Kit/Config.hs`). A *symbolic link* (symlink) is a filesystem
entry that names another path; reading it reads the target, and `git` recreates
committed symlinks on checkout. A *canonical path* is the absolute path with every
symlink resolved and every `.`/`..` removed (`System.Directory.canonicalizePath`); on
macOS `/var/folders/...` canonicalises to `/private/var/folders/...`, which matters for
the tests. *TOCTOU* (time-of-check to time-of-use) names the window between checking a
path and reading it, during which the path could change. A *staged write* writes to a
temporary file first and renames it into place, so a reader never sees a half-written
file. *Providers* are the two interactive agent hosts, Claude Code (`InteractiveClaude`)
and Codex (`InteractiveCodex`); `AgentAssetProvider` in `baikai/src/Baikai/AgentAssets.hs`
is a synonym for that type, and the pure per-provider path rules `skillTargetPath` and
`agentTargetPath` there return relative paths such as `.claude/skills/<name>` and
`.codex/agents/<name>.toml` that `baikai-kit` joins onto a per-provider base directory
(`providerAgentsBase` in `Config.hs`: `~/.config/<tool>/agents` or `<cwd>/.<tool>/agents`
for Claude, `$HOME` or the current directory for Codex). A *scope* is `UserScope` or
`ProjectScope` (`KitScope` in `Config.hs`).

The module map at HEAD `5411947`, with the findings each carries. Finding numbers are
from `docs/reviews/correctness-and-api-review-follow-up.md` (REV-2); "Theme 8" refers to
its disposition of the July review's kit findings.

`baikai-kit/src/Baikai/Kit/Path.hs` — `safeRelativePath` (lines 12–23) and
`safeItemName` (25–37) are the lexical validators from plan 35; `safeUnder` (39–40) is
exported and unused (Theme 8.1 residual). Nothing here touches the filesystem, which is
the gap: E.5 (= F.10, major, security).

`baikai-kit/src/Baikai/Kit/Install.hs` — `planInstall` (215–266) validates names and
paths lexically, then `requireSourceFile` (286–289) uses `doesFileExist`, which follows
symlinks, and `executePlan`'s `writeTemp` (310) uses `LBS.readFile`, which reads through
them; `computeKitHash` is called at 222 and 245. F.11 (major): `loadManifest` (74–86)
exits at 80 and 85, `installItem` (109–125) at 116 and 125, `updateKit` (166–187) at
178, `safeAgentSources` (268–284) at 277, `requireSafe` (318–323) at 323; `listAvailable`
(189–209) exits through `ensureKitRepo` and `loadManifest`. F.12 (minor): the agent
equation of `planInstall` copies only `primarySource` (243, 247, 255); phase two of
`executePlan` (294) is a bare loop of `renameFile` with no rollback, and the temp name
at 298 is the fixed `destination <> ".baikai-kit-tmp"`. Theme 8.4 residual:
`reinstallIfPresent` (325–334) and `reinstallAllPresent` (336–355) call `doInstall`
without `try`, so an `IOException` during `kit update` escapes as an uncaught exception.
Theme 8.2 residual: neither consults anything before overwriting installed files.
Theme 8.7 residual: `stripYamlFrontmatter` (406–414) returns input without frontmatter
untouched, `\r` included.

`baikai-kit/src/Baikai/Kit/Repo.hs` — `ensureKitRepo` (24–54) prints a warning and
continues on a failed pull (34), prints "Fetching …" (37), and on a failed first clone
with no cached manifest exits at 54 (F.11; Theme 8.6 residual). A missing `git` binary
makes `readProcessWithExitCode` at 40 throw an uncaught `IOException`. `pullKitRepo`
(56–66) already returns `PullResult` and is unchanged.

`baikai-kit/src/Baikai/Kit/Status.hs` — `upstreamHash` (109–115) joins the manifest
`path` unsanitised at 113 and through `agentSourceBase` (205–209); the read is guarded by
`try @IOException` in `tryHash` (117–122) but still follows symlinks (Theme 8.1
residual). `resolveCacheOrEmpty` (100–107) wraps `ensureKitRepo` in `try
@IOException`, which does not catch the `ExitCode` exception `exitFailure` throws, so
`kit status` on a fresh home offline exits 1 (F.11). `kitStatus` (73–77) prints the
table itself.

`baikai-kit/src/Baikai/Kit/Sidecar.hs` — `computeKitHash` (41–54) reads `dir </>
safeRel` with `BS.readFile` at 51 after a lexical check only. `writeSidecar` (79–84) is
exported and unused since plan 35's staged install.

`baikai-kit/src/Baikai/Kit/Manifest.hs` — `KitManifest.version :: Int` (line 21) is
decoded and never checked (F.12). `agentSources` (58–64) joins manifest text with `</>`.

`baikai-kit/src/Baikai/Kit/Command.hs` — the optparse adapter; `runKit` (33–39)
dispatches to the functions above and is the only place that should exit after this
plan. `baikai-kit/src/Baikai/Kit/Session.hs` (`agentDirsForSession`) is untouched.

The test suite `baikai-kit/test/Main.hs` runs under `localOption (NumThreads 1)` (line
61) because the filesystem tests set the process-wide `HOME` variable to a temporary
home (`withPreparedKitHome`, 368–384): two tests running in parallel would share one
mutable environment, invalidate each other's isolation, and could write into the real
home directory. Keep that option and that helper. `withPreparedKitHome` fabricates a
cache at `<tmp>/home/.cache/testkit/kit` containing a fake `.git` directory (so
`ensureKitRepo` skips cloning and any real `git pull` fails), a skill `demo`
(`skills/demo/SKILL.md`), an agent `reviewer` (`agents/reviewer.md`) and a manifest,
then runs the action and restores `HOME` with `finally`. Project-scope paths resolve
against the current directory, so tests use `UserScope`.

Downstream consumers, found with `mori registry dependents shinzui/baikai --packages`
and the projects' checkouts: `rei-cli`
(`/Users/shinzui/Keikaku/bokuno/rei-project/rei/rei-cli/src/Rei/Cli/Commands/Kit/Handler.hs`)
calls `ensureKitRepo`, `loadManifest` and `installItem` directly for an fzf picker and
`Kit.runKit` for everything else; `mori-cli`
(`/Users/shinzui/Keikaku/bokuno/mori-project/mori/mori-cli/src/Mori/Command/Kit.hs`)
calls only `Kit.runKit` and `kitCommandParser`; `seihou-cli`
(`/Users/shinzui/Keikaku/bokuno/seihou-project/seihou/seihou-cli/src-exe/Seihou/CLI/Kit.hs`)
and `okf-cli` (`/Users/shinzui/Keikaku/bokuno/okf/okf-cli/src/Okf/Cli/Kit.hs`) mirror
`KitCommand` in a local type and pattern-match every constructor, so a change to
`KitUpdate`'s arity is a compile error for them (good — visible), while a new
constructor would be a silent runtime pattern-match failure (bad — avoided). All four
pin `baikai-kit ^>=0.1.0.x`, so none of this reaches them until they raise the bound.
All four also use `Baikai.Kit.Session.agentDirsForSession`, which does not change.

ADR context. The local corpus `docs/adr/` is a plain-file convention described in
`docs/adr/0001-architecture-decision-record-convention.md` (one decision per
`NNNN-slug.md`, frontmatter `title`/`status`/`date`, body Context/Decision/Consequences,
indexed in `docs/adr/README.md`); this plan creates one record under it. Records
0002–0004 concern model-call evidence and 0005 the evidence boundary and retries; none
bears on the kit. A Mori search of registered concepts for "symlink", "exitFailure" and
"library code never" returned nothing, so no cross-repository ADR applies.


## Plan of Work

The work is four milestones fixed by the MasterPlan. Milestone 1 closes the security
finding with a physical path check. Milestone 2 removes every exit from library code
and gives the CLI adapter the job of rendering and exiting. Milestone 3 fixes install
fidelity. Milestone 4 makes the guide and the capability record match. Each milestone
leaves `cabal build all --enable-tests` and `cabal test baikai-kit` green and is
verifiable by named tests. Milestone 1 introduces `KitError` because the physical check
needs a typed reason; Milestone 2 then spreads it everywhere.

### Milestone 1 — symlinked kit sources refused on install, hash and status

Scope: E.5/F.10 and the two Theme 8.1 residuals (the unsanitised `upstreamHash` join and
the unused `safeUnder`). At the end, a kit whose checkout contains a symbolic link
anywhere under a listed source path cannot have that path read by install, by the
content hash, or by status; the refusal is a typed value, and status shows `refused`.

Create `baikai-kit/src/Baikai/Kit/Error.hs` (add it to `exposed-modules` and to
`Baikai.Kit`). It imports only `Baikai.Prelude`, `Control.Exception (Exception)` and
`Data.Text`:

```haskell
-- | Every way a kit operation can fail. Library functions return these;
-- only 'Baikai.Kit.Command.runKit' turns one into a process exit.
data KitError
  = KitManifestMissing FilePath
  | KitManifestInvalid FilePath Text
  | KitManifestVersionUnsupported FilePath Int
  | KitItemNotFound Text
  | KitItemHasNoFiles Text
  | KitUnsafeName Text Text
  | KitUnsafePath Text Text
  | KitSourceMissing FilePath
  | KitSourceSymlink FilePath
  | KitSourceEscapes FilePath FilePath
  | KitSourceUnreadable FilePath Text
  | KitCloneFailed Text Text
  | KitPullFailed Text
  | KitWriteFailed Text [FilePath] [FilePath]
  deriving stock (Eq, Show)
  deriving anyclass (Exception)

renderKitError :: KitError -> Text
```

The two-`Text` constructors carry the offending manifest text and the reason from the
lexical validator; `KitSourceEscapes` carries the canonical path and the canonical kit
root; `KitCloneFailed` carries the repository URL and git's output; `KitWriteFailed`
carries the reason, the paths restored by rollback, and the paths left inconsistent
(both empty when nothing was changed). Constructors are positional because
`-Wpartial-fields` is on and a record sum would warn. Exact rendering, one line each
except where noted: `kit.json not found in kit repository (<path>).`; `failed to parse
<path>: <reason>`; `<path> declares manifest version <n>; this installer supports
versions 1 and 2.`; `'<name>' not found in kit manifest.`; `'<name>' lists no source
files.`; `unsafe item name '<text>': <reason>`; `unsafe manifest path '<text>':
<reason>`; `source file does not exist: <path>`; `refusing symbolic link in kit source:
<path>`; `kit source resolves outside the kit checkout: <path> (checkout: <root>)`;
`cannot inspect kit source <path>: <reason>`; `failed to fetch kit repository <url>:
<output>`; `failed to update kit repository: <output>` followed on a second line by `The
cached copy is unchanged; installed items were not reinstalled.`; and for
`KitWriteFailed`, `install failed: <reason>` followed by `No changes were made.` when
both lists are empty, otherwise by `Restored: <paths>` and `Left inconsistent (repair by
reinstalling): <paths>` for whichever lists are non-empty.

Add the physical check to `baikai-kit/src/Baikai/Kit/Path.hs` and delete `safeUnder`
(remove it from the export list; the umbrella re-export follows). Also remove it from
the import list and the test in `baikai-kit/test/Main.hs`: the test case
`testCase "safeUnder rejects an absolute right operand" $ assertLeft (safeUnder "/base"
"/etc/passwd")` (lines 167–168) asserted the `</>`-discards-base hazard; that hazard is
now covered by the `safeSourcePath` test below, which passes an absolute path and
expects `KitUnsafePath`.

```haskell
-- | Resolve an untrusted relative source path below a trusted kit checkout.
-- Runs 'safeRelativePath' on the relative path, then walks every prefix of
-- it below @root@: a prefix that does not exist is 'KitSourceMissing', a
-- prefix that is a symbolic link ('pathIsSymbolicLink') is
-- 'KitSourceSymlink'. Finally the canonical form of the full path must lie
-- component-wise below the canonical form of @root@ ('canonicalizePath' on
-- both, compared with 'splitDirectories'), else 'KitSourceEscapes', and the
-- full path must be a regular file ('doesFileExist'), else
-- 'KitSourceMissing'. Any 'IOException' raised while inspecting a prefix is
-- 'KitSourceUnreadable'. Returns @root '</>' rel@. Check-then-read: the
-- caller reads the returned path afterwards; a writer to the checkout could
-- swap a file for a link in between, which is accepted because the checkout
-- is owned by the invoking user and written only by git before this runs.
safeSourcePath :: FilePath -> FilePath -> IO (Either KitError FilePath)
```

Implementation notes for the walk: split the validated relative path with
`splitDirectories`, drop any `"."` component, and fold over the prefixes `root </> c1`,
`root </> c1 </> c2`, …, checking `doesPathExist` before `pathIsSymbolicLink` (the latter
throws on a missing path). `doesPathExist` on a dangling link returns `False`, which
yields `KitSourceMissing` — also a refusal, and the link is never followed. Canonicalise
`root` too: a checkout under a symlinked parent (the macOS temporary directory in the
tests, `/var` → `/private/var`) must still be accepted, and a string-prefix comparison
would wrongly accept `/kit2` as below `/kit`, hence the component-wise comparison.

Add a pure source-list derivation to `baikai-kit/src/Baikai/Kit/Manifest.hs`, which
now imports `Baikai.Kit.Error` and `Baikai.Kit.Path (safeItemName, safeRelativePath)`
(`Path` and `Error` import nothing from the kit, so there is no cycle). Replace
`agentSources` with it and remove `agentSources` from the export list.

```haskell
-- | Where an item's files live inside the kit checkout: a directory relative
-- to the checkout and file names relative to that directory (the first is
-- the agent body for agents). Lexically validated; physical checks are
-- 'Baikai.Kit.Path.safeSourcePath'. Fails with 'KitUnsafeName' /
-- 'KitUnsafePath' / 'KitItemHasNoFiles'.
data ItemSources = ItemSources
  { base :: !FilePath,
    files :: ![FilePath]
  }
  deriving stock (Eq, Generic, Show)

itemSources :: KitItem -> Either KitError ItemSources

supportedManifestVersions :: [Int]
supportedManifestVersions = [1, 2]
```

For a skill, `base` is the validated `path` and `files` the validated `files`; for an
agent with `files`, the same; for an agent without `files`, `base` is `takeDirectory`
of the validated `path` and `files` is `[takeFileName path]`. An empty `files` list is
`KitItemHasNoFiles` for both kinds (a skill directory holding only a sidecar is not an
install). The item `name` is validated with `safeItemName` here as well so that every
consumer of `itemSources` has already seen the name pass.

Wire the check into the three readers. In `baikai-kit/src/Baikai/Kit/Sidecar.hs`
change the hash to take the kit root, the relative base and the relative files, and to
resolve each file through `safeSourcePath root (base </> file)` before reading:

```haskell
-- | Content hash of the listed files. The hashed bytes are, per file sorted
-- by name: the file name relative to @base@, NUL, the big-endian length, the
-- content, NUL — unchanged from earlier releases, so existing sidecars keep
-- matching. Every file is resolved through 'safeSourcePath' first.
computeKitHash :: FilePath -> FilePath -> [FilePath] -> IO (Either KitError Text)

-- | The pure core: hash already-read (relative name, bytes) pairs.
hashEntries :: [(FilePath, BS.ByteString)] -> Text
```

Keep the hashed relative name as the file name relative to `base` (not to the root), or
every sidecar written before this plan would report `dirty`. Export `hashEntries`;
Milestone 3 uses it for the installed-file hash. Update the two hash tests at lines
94–109 to call `computeKitHash dir "." [...]` and to match on `Right h`.

In `baikai-kit/src/Baikai/Kit/Install.hs`, `planInstall` obtains `ItemSources` from
`itemSources item`, resolves every file with `safeSourcePath repoDir (base </> file)`
and uses the returned absolute paths for `CopyFrom` and for the agent body; delete
`requireSourceFile` and `safeAgentSources`. For this milestone `planInstall` may still
fail through `requireSafe`-style exits for the *lexical* errors it already handled;
Milestone 2 removes those. The minimal change is to make `planInstall` return `IO
(Either KitError [PlannedWrite])` now and have `installItem` print `renderKitError` and
`exitFailure` on `Left` until Milestone 2 replaces that.

In `baikai-kit/src/Baikai/Kit/Status.hs`, rewrite `upstreamHash` to use `itemSources`
and the new `computeKitHash`, returning `IO (Either KitError (Maybe Text))`: `""` cache
or no item is `Right Nothing`; `Left (KitSourceMissing _)` becomes `Right Nothing`
(the upstream file is gone, so there is nothing to compare — today's behaviour);
every other `Left` is returned. Delete `agentSourceBase` and `tryHash`. Add
`KitUpstreamRefused` to `KitState` (rendered `refused`) and, in `collectStatus`, set the
row's state to `KitUpstreamRefused` when `upstreamHash` returned a `Left`, otherwise call
`classify` as today with the `Maybe Text`. `classify`'s signature does not change.

Tests, in `baikai-kit/test/Main.hs`. Extend the fixture helpers: a
`withSymlinkedKitHome` variant (or a flag on `withPreparedKitHome`) that additionally
writes `<tmp>/outside/secret.txt` containing `top secret`, creates a directory link
`cache/skills/demo/sub -> <tmp>/outside` with `System.Directory.createDirectoryLink`,
and writes a manifest whose `demo` skill lists `files: ["SKILL.md", "sub/secret.txt"]`.
The link target is absolute in the test; a committed kit would use a relative target,
and `pathIsSymbolicLink` does not care. Then, in a new group "Symlink safety":
`safeSourcePath cache "skills/demo/sub/secret.txt"` returns `Left (KitSourceSymlink p)`
with `p == cache </> "skills" </> "demo" </> "sub"`; `safeSourcePath cache
"/etc/passwd"` returns `Left (KitUnsafePath _ _)`; `safeSourcePath cache
"skills/demo/SKILL.md"` returns `Right _`; `computeKitHash cache "skills/demo"
["SKILL.md", "sub/secret.txt"]` returns `Left (KitSourceSymlink _)`; `installItem
testConfig "demo" UserScope` fails with `KitSourceSymlink` (in this milestone, `try
@ExitCode` returning `Left (ExitFailure 1)`; Milestone 2 changes the assertion to the
`Either`) and afterwards neither `<claudeBase>/.claude/skills/demo/sub/secret.txt` nor
`<claudeBase>/.claude/skills/demo/SKILL.md` exists (nothing at all was written); and for
status, install `demo` from a clean fixture, then plant the link and rewrite the
manifest to list `sub/secret.txt`, and assert every `demo` row from `collectStatus
testConfig cache [(UserScope, "user")]` has `state == KitUpstreamRefused`. Add a
`classify`-independent pure test that `renderState KitUpstreamRefused == "refused"`.

Acceptance: `cabal test baikai-kit` passes; temporarily replacing `safeSourcePath`'s
body with `pure (Right (root </> rel))` makes the install test fail by finding
`secret.txt` under the Claude skill directory, proving the test exercises the read.

### Milestone 2 — library code returns typed errors; only the CLI exits

Scope: F.11 and the Theme 8.6 residual. At the end, `grep -n "exitFailure\|exitWith"
baikai-kit/src` matches only `Baikai/Kit/Command.hs`, every function in `Install.hs`,
`Repo.hs` and `Status.hs` returns a value a caller can inspect, and `kit status` with no
cache and no network exits 0.

`baikai-kit/src/Baikai/Kit/Repo.hs`:

```haskell
data RepoRefresh
  = RepoCloned
  | RepoPulled
  | RepoStale !Text
  deriving stock (Eq, Show)

data KitRepo = KitRepo
  { dir :: !FilePath,
    refresh :: !RepoRefresh
  }
  deriving stock (Eq, Generic, Show)

ensureKitRepo :: KitConfig -> IO (Either KitError KitRepo)
```

With a `.git` directory present: pull, and return `RepoPulled` or `RepoStale err`. Without
one: `createDirectoryIfMissing`, run `git clone --depth 1` inside `try @IOException`
(a missing `git` binary is a `KitCloneFailed` whose output is the exception text), and
on failure return `RepoStale output` if `kit.json` already exists in the cache, else
`Left (KitCloneFailed url output)`. Remove both `hPutStrLn` calls and the "Fetching …"
line; export `RepoRefresh (..)` and `KitRepo (..)`.

`baikai-kit/src/Baikai/Kit/Install.hs`:

```haskell
loadManifest      :: FilePath -> IO (Either KitError KitManifest)
loadManifestMaybe :: FilePath -> IO (Either KitError (Maybe KitManifest))
installItem       :: KitConfig -> Text -> KitScope -> IO (Either KitError KitItem)
installFrom       :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> IO (Either KitError KitItem)
listAvailable     :: KitConfig -> IO (Either KitError KitManifest)
renderAvailable   :: KitManifest -> Text
uninstallItem     :: KitConfig -> Text -> KitScope -> IO (Either KitError [RemovalOutcome])
```

`loadManifest` returns `KitManifestMissing` when the file is absent, `KitManifestInvalid`
with aeson's message when it does not decode, and `KitManifestVersionUnsupported` when
`version` is not in `supportedManifestVersions` (the gate is Milestone 3's item, but it
is cheapest to add while this function is rewritten; its test is listed under
Milestone 3). `loadManifestMaybe ""` and an absent file are `Right Nothing`; invalid or
unsupported manifests are `Left`, and the warning print is deleted. `installFrom` is the
network-free half: look the item up (`KitItemNotFound`), plan, execute, return the
item. `installItem` is `ensureKitRepo`, then `loadManifest (dir repo)`, then
`installFrom`; the `KitRepo`'s refresh state is dropped by this convenience, which is why
the CLI composes the three itself. `listAvailable` is the same composition without the
install; `renderAvailable` is the current `listAvailable` body as a pure function
(`"No items available in the kit."`, or the `Skills:`/`Agents:` columns). `uninstallItem`
absorbs `uninstallOutcomes`: it validates the name (`KitUnsafeName`) and returns the
outcomes; the report line is rendered by the caller with the unchanged pure
`renderUninstallReport`. Delete `requireSafe` and `uninstallOutcomes`. Internally,
`isInstalled`, `reinstallIfPresent` and `reinstallAllPresent` return `Either`; Milestone
3 reshapes them into `reinstallPresent`, so for this milestone it is enough that the
first `Left` aborts `updateKit`, which becomes `updateKit :: KitConfig -> Maybe Text ->
IO (Either KitError ())` here and gains its policy argument and report in Milestone 3.

`baikai-kit/src/Baikai/Kit/Status.hs`:

```haskell
data UpstreamAvailability
  = UpstreamReady
  | UpstreamStale !Text
  | UpstreamUnavailable !KitError
  deriving stock (Eq, Show)

data StatusReport = StatusReport
  { upstream :: !UpstreamAvailability,
    rows :: ![StatusRow]
  }
  deriving stock (Eq, Generic, Show)

kitStatus         :: KitConfig -> IO StatusReport
renderStatusTable :: [StatusRow] -> Text
collectStatus     :: KitConfig -> FilePath -> [(KitScope, Text)] -> IO [StatusRow]
```

`kitStatus` calls `ensureKitRepo`; a `Left e` gives `UpstreamUnavailable e` and an empty
cache path; a `RepoStale err` gives `UpstreamStale err`; then it calls `loadManifestMaybe`
on the cache, and a `Left e` there also gives `UpstreamUnavailable e` with an empty cache
path (a manifest that cannot be read is no upstream). `collectStatus` keeps its
signature and treats a `Left` from `loadManifestMaybe` as no manifest, so the existing
status tests are unchanged. `renderStatusTable` is the current printer made pure,
returning `"No kit items installed."` for an empty list. Delete `resolveCacheOrEmpty`.

`baikai-kit/src/Baikai/Kit/Command.hs`:

```haskell
-- | Run one verb and print its normal output. Never exits.
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())

-- | The command adapter: 'runKitCommand', then on 'Left' print
-- @Error: <renderKitError e>@ to stderr and 'exitWith' ('ExitFailure' 1).
-- This is the only function in baikai-kit that exits the process.
runKit :: KitConfig -> KitCommand -> IO ()
```

`runKitCommand` composes the library per verb. For `KitList`: `ensureKitRepo`, warn on
`RepoStale`, `loadManifest`, print `renderAvailable`. For `KitInstall`: `ensureKitRepo`,
warn, `loadManifest`, `installFrom`, print `Installed <kind> '<name>' to <scope> scope.`.
For `KitUninstall`: `uninstallItem`, print `renderUninstallReport`. For `KitUpdate`:
`updateKit`, print its report (Milestone 3 defines the lines). For `KitStatus`:
`kitStatus`, print a note on stderr for `UpstreamUnavailable` (`Note: kit repository
unavailable (<renderKitError e>); showing installed items without upstream comparison.`)
or `UpstreamStale` (`Warning: kit repository could not be refreshed (<err>); comparing
against the cached copy.`), then print `renderStatusTable rows` to stdout, and return
`Right ()` in every case. The `RepoStale` warning for list and install reads `Warning:
kit repository could not be refreshed (<err>); using the cached copy.` and `RepoCloned`
prints `Fetched <tool>-kit.` to stdout (the clone has already happened; a small kit
clones in well under a second, so progress-before is not worth a library print).

Tests, in `baikai-kit/test/Main.hs`. Every existing `try @ExitCode` assertion moves to
the adapter and gains an `Either` twin. Quote and replace: at lines 172–173, `result <-
try @ExitCode (installItem testConfig "evil" UserScope)` / `result @?= Left (ExitFailure
1)` becomes an assertion that `installItem testConfig "evil" UserScope` returns `Left
(KitUnsafePath _ _)` plus a second case that `try @ExitCode (runKit testConfig
(KitInstall "evil" UserScope))` returns `Left (ExitFailure 1)`; at 179–180, `result <-
try @ExitCode (uninstallItem testConfig "../victim" UserScope)` / `result @?= Left
(ExitFailure 1)` becomes `uninstallItem … ` returning `Left (KitUnsafeName _ _)` plus
`try @ExitCode (runKit testConfig (KitUninstall "../victim" UserScope))` returning `Left
(ExitFailure 1)`; at 284–285 the rollback test's `result @?= Left (ExitFailure 1)`
becomes `Left (KitWriteFailed _ _ _)`; at 317–318, `updateResult <- try @ExitCode
(updateKit testConfig Nothing)` / `updateResult @?= Left (ExitFailure 1)` becomes
`updateKit testConfig Nothing KeepLocalEdits` returning `Left (KitPullFailed _)` (add the
policy argument when Milestone 3 lands; until then omit it). The test "uninstallOutcomes
reports per-provider removals" (299–310) keeps its assertions (`view #skillRemoved
claudeOutcome @?= True` and the three `False`s) and calls `uninstallItem`, matching
`Right outcomes`. Round-trip calls of `installItem`/`uninstallItem` that ignored the
result now bind `Right _`; write a small `assertRight :: Show e => Either e a -> IO a`
helper. New cases, group "Typed errors": `loadManifest` on a directory without
`kit.json` returns `Left (KitManifestMissing _)`; on a file containing `{` returns `Left
(KitManifestInvalid _ _)`; `installItem testConfig "nope" UserScope` returns `Left
(KitItemNotFound "nope")`. New case "kit status offline on a fresh HOME exits 0": under
`withSystemTempDirectory`, set `HOME` to an empty directory (restore with `finally`, as
`withPreparedKitHome` does), use a config whose `repoUrl` is `file:///nonexistent-kit`
so `git clone` fails immediately without network, and assert `try @ExitCode (runKit
config KitStatus)` returns `Right ()` and `kitStatus config` returns a report with
`rows == []` and `upstream` matching `UpstreamUnavailable (KitCloneFailed _ _)`. Also
assert `grep`-style at the process level is unnecessary: add a compile-time guard
instead by keeping `System.Exit` imported only in `Command.hs` (a reviewer checks this
with `grep -rn "System.Exit" baikai-kit/src`).

The ADR. Create `docs/adr/NNNN-library-code-never-calls-exitfailure.md`, where `NNNN`
is the next free number in `docs/adr/` at implementation time (`ls docs/adr` — 0006 if
no other plan of this MasterPlan has landed one first), with frontmatter `title:
Library code never calls exitFailure`, `status: accepted`, `date:` the day of the
commit, and add its row to the table in `docs/adr/README.md`. Context: the July hardening
kept `exitFailure` "for consistency with the module's established error style"
(plan 35's Decision Log) and REV-2 F.11 found that consumers embedding the library had
their process terminated with nothing to catch. Decision: no exposed module of any
baikai package calls `exitFailure`, `exitWith` or `error` on a failure path; failures
are values (`Either` or a typed exception with a documented instance); process exit
belongs to an executable's `Main` or to a function whose documented contract is to *be*
a subcommand (today `Baikai.Kit.Command.runKit`), which must say so in its Haddock.
Consequences: adapters grow a `runXCommand` twin that returns the error; consumers
choose exit codes; tests assert on values instead of catching `ExitCode`.

Acceptance: `cabal test baikai-kit` passes; `grep -rn "exitFailure\|exitWith"
baikai-kit/src` prints exactly one line, in `Command.hs`.

### Milestone 3 — install fidelity (every listed file, phase-two rollback, unique temp names, manifest version gate, dirty-update refusal)

Scope: F.12 (multi-file agents, phase-two rollback, unique temp names, manifest version
gate) plus the Theme 8.2 residual (update over local edits), the Theme 8.4 residual
(`reinstall*` without `try`), and the Theme 8.7 residual (CRLF consistency).

Multi-file agents, in `planInstall`'s agent equation. With `ItemSources {base, files =
primary : extras}`: the primary file becomes the provider agent file exactly as today
(copied for Claude, rendered to TOML for Codex); each extra file becomes a `CopyFrom`
write to `takeDirectory (agentTarget …) </> safeName </> extra`. The sidecar for that
provider records `installedFiles` as `[takeFileName agentFile]` plus `safeName </>
extra` for each extra (relative to the agents directory), and for skills as the
validated `files` (relative to the skill directory). Uninstall additionally removes the
directory `takeDirectory (agentTarget …) </> safeName` with `removeIfDirectory`; its
removal is folded into `agentRemoved` (the directory is part of the agent, not a kind of
its own) so `RemovalOutcome` and `renderUninstallReport` do not change.

Sidecar fields, in `baikai-kit/src/Baikai/Kit/Sidecar.hs`:

```haskell
data SidecarMeta = SidecarMeta
  { name :: !Text,
    kind :: !Text,
    version :: !(Maybe Text),
    hash :: !Text,
    installedAt :: !Text,
    installedFiles :: !(Maybe [Text]),
    installedHash :: !(Maybe Text)
  }

newSidecarMeta :: KitItem -> Text -> [Text] -> Text -> IO SidecarMeta
```

The generic aeson instances stay; aeson 2.2's generic decoder treats a missing `Maybe`
field as `Nothing` (`allowOmittedFields` defaults to true), so sidecars written before
this plan keep reading — pin that with a test that decodes a literal sidecar JSON
lacking both fields. `installedHash` is `hashEntries` over the `(relative name, bytes)`
pairs of that provider's non-sidecar writes, computed at plan time from the bytes about
to be written (for `CopyFrom` read the source once and turn it into `WriteBytes`, so
plan time and write time see the same bytes). Delete `writeSidecar`.

Journaled execution, replacing `executePlan`:

```haskell
-- | Test seam: run a plan with an injectable rename step. Not part of the
-- stable surface; EP-10 may relocate it behind an .Internal module.
executePlanWith :: (FilePath -> FilePath -> IO ()) -> [PlannedWrite] -> IO (Either KitError ())

executePlan :: [PlannedWrite] -> IO (Either KitError ())
executePlan = executePlanWith renameFile
```

Export `PlannedWrite (..)`, `WriteContent (..)` and `executePlanWith` with Haddocks
saying they are a test seam. Steps: (0) for every destination, `doesDirectoryExist` →
`Left (KitWriteFailed ("destination is a directory: " <> dest) [] [])`; (1) phase one:
`createDirectoryIfMissing True (takeDirectory dest)`, then `openTempFile (takeDirectory
dest) (takeFileName dest <> ".baikai-kit-tmp")` — `openTempFile` splits the template at
its extension, so the file is named `<name><random>.baikai-kit-tmp`, which keeps the
suffix the existing residue check looks for — write the bytes through the handle with
`LBS.hPut`, `hClose`; any `IOException` removes every temporary so far and returns
`KitWriteFailed reason [] []`; (2) phase two, per entry: if the destination exists,
reserve a backup name with `openTempFile dir (takeFileName dest <> ".baikai-kit-bak")`,
close it, and `renameFile dest backup` (replacing the empty reservation); then apply the
injected rename `temp dest`; push `(dest, Maybe backup)` onto the journal. On an
`IOException` at entry k: for each journal entry in reverse, `renameFile backup dest`
when there is a backup, else `removeFile dest`, collecting successes as `restored` and
failures as `leftInconsistent`; remove the temporaries of entries after k; return
`Left (KitWriteFailed reason restored leftInconsistent)`. On success, remove every
backup (best effort). `installFrom` no longer needs its own `try`: `executePlan` returns
the value.

Manifest version gate: already in `loadManifest` (Milestone 2); its test lives here.

Update with local-modification refusal, in `Install.hs`:

```haskell
data OverwritePolicy
  = KeepLocalEdits
  | OverwriteLocalEdits
  deriving stock (Eq, Show)

data UpdateReport = UpdateReport
  { refresh :: !RepoRefresh,
    updated :: ![(Text, KitScope)],
    skipped :: ![(Text, KitScope)]
  }
  deriving stock (Eq, Generic, Show)

updateKit        :: KitConfig -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)
reinstallPresent :: KitConfig -> FilePath -> KitManifest -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)
```

`updateKit`: if `<cache>/.git` exists, `pullKitRepo`; `PullFailed err` is `Left
(KitPullFailed err)`. Otherwise `ensureKitRepo`, and both `Left` and `RepoStale` are
errors for update (`KitCloneFailed`) because update's one job is to fetch. Then
`loadManifest` and `reinstallPresent`, which is the network-free second half (exported
so the test can drive it against the fake-`.git` fixture, and so a consumer that
refreshed the cache itself can reuse it). `reinstallPresent` folds the old
`reinstallIfPresent`/`reinstallAllPresent`: the candidate names are the one given or
every manifest name; for each name and each scope, `isInstalled` (an unsafe manifest
name is `Left (KitUnsafeName …)` and aborts); for an installed item, read each
provider's sidecar and, when it carries `installedFiles` and `installedHash`, recompute
`hashEntries` over those files read from the provider target (a missing file counts as
modified); if any provider differs and the policy is `KeepLocalEdits`, append to
`skipped`; else `installFrom` (its `Left` aborts the whole update — the report so far is
lost, which is acceptable because the error names the item and a rerun resumes) and
append to `updated`. `refresh` is `RepoPulled` or `RepoCloned`.

`KitCommand` in `Command.hs` becomes `KitUpdate !(Maybe Text) !OverwritePolicy`, with
`updateParser` adding `flag KeepLocalEdits OverwriteLocalEdits (long "force" <> help
"Reinstall items even if their installed files were modified locally")`. The report
prints `Kit repository updated.` or `Kit repository cloned.`, then `Updated '<name>'
(<scope>)` per updated entry, `Skipped '<name>' (<scope>): installed files were modified
locally; run 'kit update <name> --force' to overwrite.` per skipped entry, and finally
`Updated <n> item(s).` plus, when anything was skipped, `Skipped <m> item(s).`. Skips
are not an error: the command returns `Right ()` and exits 0.

CRLF consistency, in `stripYamlFrontmatter`: split on `\n`, drop a trailing `\r` from
every line, compare against `---` after `Text.stripEnd`, and rejoin with `\n` on *every*
branch, so input without frontmatter and unterminated frontmatter also come out LF-only.

Tests, in `baikai-kit/test/Main.hs`, group "Install fidelity". Multi-file agent: a
manifest whose `reviewer` agent has `path: "agents/reviewer"` and `files:
["reviewer.md", "guide.md"]` with both files present in the cache; after `installItem`,
`<claudeBase>/.claude/agents/reviewer.md` and
`<claudeBase>/.claude/agents/reviewer/guide.md` exist, `<home>/.codex/agents/reviewer.toml`
and `<home>/.codex/agents/reviewer/guide.md` exist, the Claude sidecar's
`installedFiles` is `Just ["reviewer.md", "reviewer/guide.md"]`, and after
`uninstallItem` the `reviewer` directory is gone. Phase-two rollback: write
`<home>/a.txt` with content `old`; build a plan of two `WriteBytes` writes to
`<home>/a.txt` (`new`) and `<home>/b.txt` (`new`); call `executePlanWith` with a rename
that, when the destination ends in `b.txt`, asserts the temporary lies in `home`, ends
in `.baikai-kit-tmp` and is not `dest <> ".baikai-kit-tmp"` (the unique-name check),
then throws `userError "boom"`, and otherwise calls `renameFile`; assert the result is
`Left (KitWriteFailed _ [home </> "a.txt"] [])`, `a.txt` reads `old`, `b.txt` is absent,
and `findFilesWithSuffix home ".baikai-kit-tmp"` and `… ".baikai-kit-bak"` are both
empty. Directory pre-check: create the directory `<claudeBase>/.claude/agents/reviewer.md`
and assert `installItem testConfig "reviewer" UserScope` is `Left (KitWriteFailed _ []
[])` and `<home>/.codex/agents/reviewer.toml` does not exist. Version gate: a manifest
with `"version": 99` makes `loadManifest cache` return `Left
(KitManifestVersionUnsupported _ 99)` and `installItem` the same. Legacy sidecar: decode
`{"name":"demo","kind":"skill","version":"0.1.0","hash":"sha256:x","installedAt":"t"}`
to a `SidecarMeta` with both new fields `Nothing`. Local-edit refusal: install `demo`,
overwrite `<claudeSkill>/SKILL.md` with `my edits`, change the cached `SKILL.md` to `new
upstream`, load the manifest, and assert `reinstallPresent testConfig cache manifest
(Just "demo") KeepLocalEdits` returns `Right` with `skipped == [("demo", UserScope)]`
and `updated == []` while `SKILL.md` still reads `my edits`; then with
`OverwriteLocalEdits` `updated == [("demo", UserScope)]` and the file reads `new
upstream`; then rewrite the Claude sidecar without the two fields and assert
`KeepLocalEdits` updates it (legacy sidecars are not checked). `reinstallPresent` wraps
its `installFrom` result, so also assert that planting the `.codex` file from the
rollback test makes `reinstallPresent` return `Left (KitWriteFailed …)` rather than
throw — this is the Theme 8.4 residual. Frontmatter: `stripYamlFrontmatter "Body.\r\n"
== "Body.\n"` and `stripYamlFrontmatter "---\r\nname: x\r\nBody.\r\n" == "---\nname:
x\nBody.\n"`; the existing cases at lines 188–194 stay as they are.

Changelog: add to `CHANGELOG.md` under `## [Unreleased]` a `### Changed`, `### Added`,
`### Fixed` and `### Removed` set of bullets prefixed `` `baikai-kit`: `` describing the
symlink refusal, the typed-error surface and the `runKitCommand`/`runKit` split, the
multi-file agent layout, the journaled phase two and unique temporaries, the manifest
version gate, the `--force` update policy and sidecar fields, the LF normalisation, the
new `refused` state, and the removals (`safeUnder`, `uninstallOutcomes`, `agentSources`,
`writeSidecar`, `requireSafe`), each marked **Breaking** where a signature changed and
noting that the version bump is made by EP-10.

Acceptance: `cabal test baikai-kit` passes; reverting the journal (making the injected
rename loop a bare `forM_`) makes the rollback test fail with `a.txt` reading `new`.

### Milestone 4 — `docs/user/kit.md` and the kit capability record match

Scope: bring the guide and the capability record to the code. `docs/user/kit.md`: in
"Manifest", state that `version` must be `1` or `2` and that other values are refused,
and that a kit must contain plain files — a symbolic link anywhere under a listed
`path` or file is refused at install, hash and status; after the multi-file sentence
(lines 102–105) describe where extra agent files land
(`<agents dir>/<name>/<file>`) and that the first file is the agent body. In "Command
Adapter", replace the lower-level example (lines 139–145) with the typed shape:

```haskell
result <- installItem myKitConfig "review" ProjectScope
case result of
  Left err -> Text.IO.hPutStrLn stderr (renderKitError err)
  Right item -> Text.IO.putStrLn ("installed " <> itemName item)
```

and say that every lower-level function returns `Either KitError a`, that `runKit`
prints and exits 1 on any error while `runKitCommand` returns it, and that `KitError`
has an `Exception` instance for callers who prefer `throwIO`. Document `kit update
[NAME] [--force]` in the supported-commands block and describe the skip line. In
"Status And Sidecars", add `refused` ("the cached upstream item now lists a source the
installer refuses — a symbolic link or a path outside the kit; fix the kit before
updating"), add the two sidecar fields, and add a short "Offline behaviour" paragraph:
`status` with no cache prints a note and exits 0, `list`/`install` fail without a cache
and warn-and-continue with a stale one, `update` fails on a failed pull. In "Smoke
Checks" add `kit update review --force`.

`docs/capabilities/kit-installer.md`: update `description` to name symlink refusal
and typed errors; add `Baikai.Kit.Error`, `Baikai.Kit.Config`, `Baikai.Kit.Path` and
`Baikai.Kit.Sidecar` to `interface` (the record omits modules the guide tells consumers
to use); rewrite the test evidence `proves` sentence to list the new proofs (symlink
refused on install, hash and status; typed errors and an offline status exit 0;
multi-file agents; phase-two restore; version gate; local-edit refusal); rewrite the
"treats the manifest as untrusted input" paragraph to say lexical *and* physical checks
and to name the TOCTOU limit; in "Limits" replace the "one hardening pass" bullet with
the honest residuals (check-then-read; `readSidecar` still prints a parse warning;
concurrent installs of one item race on the final rename). Bump `generated.at` to the
edit date. Append a dated `## 2026-…` entry to `docs/capabilities/log.md` with an
`* **Update**: CAP-21 …` bullet summarising the change, because the release gate runs
`--log-enforce`. Then validate:

```bash
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
mori validate
```

Acceptance: both validators exit 0; `docs/user/kit.md` contains no statement the tests
contradict (walk its sections against the test names in `cabal test baikai-kit`
output).


## Concrete Steps

All commands run from the repository root. Iterate per milestone: edit, build, test,
update this file's Progress, commit.

```bash
cabal build baikai-kit --enable-tests
cabal test baikai-kit
```

Expected output shape on success (group names as added by each milestone):

```text
baikai-kit
  Manifest backward compatibility
    mori-kit.json decodes:                                            OK
    ...
  Symlink safety
    safeSourcePath refuses a symlinked component:                     OK
    computeKitHash refuses a symlinked source:                        OK
    install refuses a symlinked source and writes nothing:            OK
    status reports refused when upstream lists a symlinked source:    OK
  Typed errors
    loadManifest returns typed errors:                                OK
    installItem returns KitItemNotFound:                              OK
    kit status offline on a fresh HOME exits 0:                       OK
    runKit exits 1 on an unsafe install:                              OK
  Install fidelity
    multi-file agent installs every listed file:                      OK
    phase-two failure restores the previous files:                    OK
    destination directory is refused before any write:                OK
    unsupported manifest version is refused:                          OK
    update skips locally modified items unless forced:                OK
  ...

All N tests passed
```

A `FAIL` line prints the assertion message (for example `expected file to be missing:
/private/var/.../secret.txt`); treat any `FAIL` or a nonzero `cabal test` exit as
not-done. Before each commit, confirm the workspace still builds:

```bash
cabal build all --enable-tests
```

Confirm the exit boundary after Milestone 2:

```bash
grep -rn "exitFailure\|exitWith\|System.Exit" baikai-kit/src
```

Expected: matches only in `baikai-kit/src/Baikai/Kit/Command.hs`.

Before the final commit, run the keyless test gate from
`agents/skills/release/SKILL.md`. It removes provider keys and the directories that hold
the `claude` and `codex` binaries from `PATH`, because `baikai-smoke` makes billable
calls when a key is present and spawns the coding agents when they are merely on
`PATH`; adjust the two filtered entries to where those binaries live on the machine:

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

Every suite must pass, not merely skip.

Commit per milestone with conventional-commit messages and the three trailers, for
example:

```text
fix(kit): refuse symlinked kit sources on install, hash and status

Add safeSourcePath (per-component pathIsSymbolicLink plus a canonical
prefix check) and route planInstall, computeKitHash and upstreamHash
through one source-list derivation; status shows `refused`.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/64-make-baikai-kit-symlink-safe-and-exit-free.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
refactor(kit)!: return KitError from library code; only runKit exits

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/64-make-baikai-kit-symlink-safe-and-exit-free.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(kit): install every agent file, journal phase two, gate manifest version, refuse local-edit overwrite

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/64-make-baikai-kit-symlink-safe-and-exit-free.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
docs(kit): describe symlink refusal, typed errors and --force in the guide and CAP-21

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/64-make-baikai-kit-symlink-safe-and-exit-free.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

The ADR commit (`docs(adr): library code never calls exitFailure`) carries the same
trailers. Update the Progress checklist and, if anything unexpected surfaced,
Surprises & Discoveries at every stopping point.


## Validation and Acceptance

The change is accepted when all of the following hold, each demonstrated by a named
test in `baikai-kit/test/Main.hs` run through `cabal test baikai-kit`, and the last by
the validators named in Milestone 4:

1. With a kit checkout containing `skills/demo/sub` as a symbolic link to a directory
   outside the checkout and a manifest listing `sub/secret.txt`, `installItem` returns
   `Left (KitSourceSymlink _)` and writes nothing (neither `secret.txt` nor `SKILL.md`
   appears under any provider target); `computeKitHash` on the same listing returns the
   same `Left`; `collectStatus` classifies the installed item `KitUpstreamRefused`,
   rendered `refused`; `safeSourcePath` accepts the plain `SKILL.md`.
2. `grep -rn "exitFailure\|exitWith" baikai-kit/src` matches only `Command.hs`;
   `installItem`, `loadManifest`, `listAvailable`, `updateKit`, `uninstallItem` and
   `ensureKitRepo` return `Left` values for a missing item, a missing or malformed
   manifest, an unsafe name, a failed pull and a failed first clone respectively, with
   no exception and no exit; `runKit` on the unsafe install and the traversal uninstall
   still exits with `ExitFailure 1` after printing `Error: …`.
3. With `HOME` pointing at an empty directory and a `repoUrl` git cannot clone, `runKit
   config KitStatus` returns normally (exit 0) after printing `No kit items installed.`
   and a stderr note, and `kitStatus` reports `UpstreamUnavailable (KitCloneFailed _ _)`
   with no rows.
4. An agent with two listed files installs both for both providers, its sidecar lists
   both relative names, and uninstall removes the resource directory.
5. A plan of two writes whose second rename fails leaves the first destination with its
   previous content, no second destination, no `.baikai-kit-tmp` or `.baikai-kit-bak`
   residue, and returns `KitWriteFailed` naming the restored path; the temporary name
   observed by the failing rename is unique (not `<dest>.baikai-kit-tmp`) and in the
   destination directory; a directory sitting where a file must go is refused before any
   provider is written.
6. A manifest with `"version": 99` is refused as `KitManifestVersionUnsupported`;
   versions 1 and 2 (the three fixtures) load.
7. `reinstallPresent` with `KeepLocalEdits` skips an item whose installed `SKILL.md` no
   longer matches the sidecar's `installedHash` and reports it in `skipped`; with
   `OverwriteLocalEdits` it reinstalls; a sidecar without the new fields is reinstalled
   without the check; a write failure during reinstall is returned, not thrown.
8. `stripYamlFrontmatter` returns LF-only text for CRLF input with, without, and with
   unterminated frontmatter.
9. `okf validate docs/capabilities --profile docs/capabilities/profile.dhall
   --profile-enforce --log-enforce`, `okf graph docs/capabilities` and `mori validate`
   exit 0, and `docs/user/kit.md` describes the manifest version rule, the symlink rule,
   the multi-file layout, the `Either KitError` shape, `--force`, the `refused` state and
   offline behaviour.

Beyond the suite, an optional manual smoke follows the isolated-`HOME` recipe in
`docs/user/kit.md` "Smoke Checks" with any downstream tool rebuilt against this
checkout: commit a symlink into a scratch kit and confirm `kit install` prints
`Error: refusing symbolic link in kit source: …` and exits 1, and that `kit status` with
the network disabled and `~/.cache/<tool>` removed prints `No kit items installed.` and
exits 0.


## Idempotence and Recovery

All edits are ordinary source changes; builds and tests can be re-run indefinitely. The
filesystem tests run under `withSystemTempDirectory`, set and restore `HOME`, and never
touch real user state; the offline-status test uses a `file://` URL that cannot reach a
network.

The journaled installer is its own recovery path: a failed install returns
`KitWriteFailed` listing anything left inconsistent, and re-running `kit install` after
fixing the cause converges — phase one writes fresh uniquely named temporaries, phase
two replaces destinations, backups are removed on success. A crash between phases can
leave `*.baikai-kit-tmp` or `*.baikai-kit-bak` files in a target directory; they are
harmless to both providers and the status scan, and a subsequent successful install of
the same item does not remove them, so the plan notes them in `docs/user/kit.md` as safe
to delete by hand. Empty directories created in phase one may survive a rollback, as
before.

Local-edit refusal is safe to repeat: `kit update` without `--force` never overwrites a
modified item, and `--force` is explicit. Sidecars written by this version are readable
by the previous version (the new fields are extra keys the old generic decoder ignores),
so a downgrade of the consuming tool is not blocked.

If a milestone must be abandoned midway, `git restore` the touched files under
`baikai-kit/`, `docs/`, and `CHANGELOG.md`; there are no generated artifacts or
migrations. After each milestone run `cabal build all --enable-tests`; no other package
in this workspace imports `Baikai.Kit`, so a break shows up only in `baikai-kit`'s own
build and tests. Downstream consumers are protected by their `^>=0.1.0.x` bounds until
EP-10 releases 0.2.0.0.


## Interfaces and Dependencies

No new package dependencies: `directory` (`pathIsSymbolicLink`, `canonicalizePath`,
`doesPathExist`, `createDirectoryLink` in tests, `renameFile`, `removeFile`),
`filepath` (`splitDirectories`, `normalise`, `takeDirectory`, `takeFileName`), `base`
(`System.IO.openTempFile`, `hClose`), `bytestring`, `aeson`, `text`, `process` and the
test-side `tasty`, `tasty-hunit`, `temporary` are already declared in
`baikai-kit/baikai-kit.cabal`. The only cabal change is adding `Baikai.Kit.Error` to
`exposed-modules` (and to `baikai-kit/src/Baikai/Kit.hs`).

At the end of Milestone 1:

```haskell
-- baikai-kit/src/Baikai/Kit/Error.hs (new)
data KitError = KitManifestMissing FilePath | KitManifestInvalid FilePath Text
  | KitManifestVersionUnsupported FilePath Int | KitItemNotFound Text | KitItemHasNoFiles Text
  | KitUnsafeName Text Text | KitUnsafePath Text Text | KitSourceMissing FilePath
  | KitSourceSymlink FilePath | KitSourceEscapes FilePath FilePath | KitSourceUnreadable FilePath Text
  | KitCloneFailed Text Text | KitPullFailed Text | KitWriteFailed Text [FilePath] [FilePath]
renderKitError :: KitError -> Text

-- baikai-kit/src/Baikai/Kit/Path.hs (safeUnder removed)
safeRelativePath :: Text -> Either Text FilePath                      -- unchanged
safeItemName     :: Text -> Either Text FilePath                      -- unchanged
safeSourcePath   :: FilePath -> FilePath -> IO (Either KitError FilePath)

-- baikai-kit/src/Baikai/Kit/Manifest.hs (agentSources removed)
data ItemSources = ItemSources { base :: !FilePath, files :: ![FilePath] }
itemSources :: KitItem -> Either KitError ItemSources
supportedManifestVersions :: [Int]

-- baikai-kit/src/Baikai/Kit/Sidecar.hs (writeSidecar removed)
computeKitHash :: FilePath -> FilePath -> [FilePath] -> IO (Either KitError Text)
hashEntries    :: [(FilePath, BS.ByteString)] -> Text

-- baikai-kit/src/Baikai/Kit/Status.hs
data KitState = KitUpToDate | KitOutdated | KitDirty | KitDirtyOutdated | KitDelisted | KitUpstreamRefused | KitUnknown
```

At the end of Milestone 2:

```haskell
-- baikai-kit/src/Baikai/Kit/Repo.hs
data RepoRefresh = RepoCloned | RepoPulled | RepoStale !Text
data KitRepo = KitRepo { dir :: !FilePath, refresh :: !RepoRefresh }
ensureKitRepo :: KitConfig -> IO (Either KitError KitRepo)
pullKitRepo   :: KitConfig -> FilePath -> IO PullResult                -- unchanged

-- baikai-kit/src/Baikai/Kit/Install.hs (requireSafe, uninstallOutcomes removed)
loadManifest      :: FilePath -> IO (Either KitError KitManifest)
loadManifestMaybe :: FilePath -> IO (Either KitError (Maybe KitManifest))
installItem       :: KitConfig -> Text -> KitScope -> IO (Either KitError KitItem)
installFrom       :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> IO (Either KitError KitItem)
listAvailable     :: KitConfig -> IO (Either KitError KitManifest)
renderAvailable   :: KitManifest -> Text
uninstallItem     :: KitConfig -> Text -> KitScope -> IO (Either KitError [RemovalOutcome])
renderUninstallReport :: Text -> KitScope -> [RemovalOutcome] -> Text  -- unchanged

-- baikai-kit/src/Baikai/Kit/Status.hs
data UpstreamAvailability = UpstreamReady | UpstreamStale !Text | UpstreamUnavailable !KitError
data StatusReport = StatusReport { upstream :: !UpstreamAvailability, rows :: ![StatusRow] }
kitStatus         :: KitConfig -> IO StatusReport
renderStatusTable :: [StatusRow] -> Text
collectStatus     :: KitConfig -> FilePath -> [(KitScope, Text)] -> IO [StatusRow]  -- unchanged

-- baikai-kit/src/Baikai/Kit/Command.hs
runKitCommand :: KitConfig -> KitCommand -> IO (Either KitError ())
runKit        :: KitConfig -> KitCommand -> IO ()                      -- unchanged signature; exits
```

At the end of Milestone 3:

```haskell
-- baikai-kit/src/Baikai/Kit/Install.hs
data OverwritePolicy = KeepLocalEdits | OverwriteLocalEdits
data UpdateReport = UpdateReport { refresh :: !RepoRefresh, updated :: ![(Text, KitScope)], skipped :: ![(Text, KitScope)] }
updateKit        :: KitConfig -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)
reinstallPresent :: KitConfig -> FilePath -> KitManifest -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)
data PlannedWrite = PlannedWrite { destination :: !FilePath, content :: !WriteContent }
data WriteContent = CopyFrom !FilePath | WriteBytes !LBS.ByteString
executePlanWith  :: (FilePath -> FilePath -> IO ()) -> [PlannedWrite] -> IO (Either KitError ())
stripYamlFrontmatter :: Text -> Text                                   -- unchanged signature

-- baikai-kit/src/Baikai/Kit/Sidecar.hs
data SidecarMeta = SidecarMeta { name, kind :: !Text, version :: !(Maybe Text), hash, installedAt :: !Text,
                                 installedFiles :: !(Maybe [Text]), installedHash :: !(Maybe Text) }
newSidecarMeta :: KitItem -> Text -> [Text] -> Text -> IO SidecarMeta

-- baikai-kit/src/Baikai/Kit/Command.hs
data KitCommand = KitList | KitInstall !Text !KitScope | KitUpdate !(Maybe Text) !OverwritePolicy
                | KitUninstall !Text !KitScope | KitStatus
```

`Baikai.Kit.Session` and `Baikai.Kit.Config` are unchanged. All new record fields use
bare names. The `Exception` instance on `KitError` is derived with `DeriveAnyClass`,
which is a default extension of the package.

Downstream edits the consumers will need when they raise their bound to `baikai-kit
^>=0.2.0` (not made by this plan; listed so EP-10's release notes can point to them):
`rei-cli`'s `installWithPicker` binds `Right repo <- ensureKitRepo`, `Right manifest <-
loadManifest (repo ^. #dir)` and calls `installFrom reiKitConfig (repo ^. #dir) manifest
n scope`, rendering `Left` with `renderKitError`; `seihou-cli` and `okf-cli` add the
`OverwritePolicy` field to their mirrored `KitUpdate` constructor and their parsers;
`mori-cli` needs no change. None of the four needs to change how it uses
`agentDirsForSession`.
