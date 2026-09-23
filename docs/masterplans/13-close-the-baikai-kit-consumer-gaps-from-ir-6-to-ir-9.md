---
id: 13
slug: close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9
title: "Close the baikai-kit consumer gaps from IR-6 to IR-9"
kind: master-plan
created_at: 2026-09-23T14:11:21Z
intention: "intention_01m379fwwker59e1mjhb3k3hfa"
provenance:
  created_by:
    model: "claude-opus-5-5"
    harness: "claude-code"
    at: 2026-09-23T14:11:21Z
  revisions:
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-09-23T14:24:17Z
      mode: "implement"
      note: "Coordinate EP-1..EP-4 implementation; registry, progress, and discoveries updated"
---

# Close the baikai-kit consumer gaps from IR-6 to IR-9

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

`baikai-kit` is the Haskell package in this repository (directory `baikai-kit/`) that gives a
command-line tool a complete `kit` subcommand: it clones a git-hosted "kit" of AI-agent skills
and subagents, reads the kit's `kit.json` manifest, installs items into the directories where
Claude Code and Codex discover them, writes a small JSON "sidecar" file beside each installed
item recording what was installed, and reports, updates, and uninstalls those items. Three
tools in the workspace ship it as their `kit` command: `mori://shinzui/mori` (`mori-cli`),
`mori://shinzui/rei` (`rei-cli`), and `mori://shinzui/okf` (`okf-cli`).

Four improvement requests, all raised from `mori://shinzui/mori` on 2026-09-23, describe
where the engine falls short for those consumers. Each lives in this repository's
improvement-request bundle:

- [IR-6, let kit install choose an item interactively](../improvement-requests/let-kit-install-choose-an-item-interactively.md)
  (`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-6`): `kit install` requires a
  name, so rei and okf keep private copies of the command type and parser.
- [IR-7, report local edits in kit status](../improvement-requests/report-local-edits-in-kit-status.md)
  (`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-7`): `kit status` never looks at
  installed files, so an edited item reads `up-to-date`, and its `dirty` state means upstream
  drift rather than local edits.
- [IR-8, resolve kit project scope from the project root](../improvement-requests/resolve-kit-project-scope-from-the-project-root.md)
  (`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-8`): every project-scope path is
  the current directory, so installs, status, uninstall, and session discovery disagree when run
  from different subdirectories.
- [IR-9, add machine-readable kit list and status output](../improvement-requests/add-machine-readable-kit-list-and-status-output.md)
  (`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-9`): `list`, `status`, and
  `update` print only column-aligned text.

After this initiative, a consuming tool configures `baikai-kit` with one value and gets all of
the following without owning any kit code of its own. `kit install` with no name asks a
chooser the tool supplied (for example an fzf picker) and installs what it returns; a
cancelled choice exits 0; a tool with no chooser gets a clear error naming the missing `NAME`.
`KitCommand` derives `Eq`, and the parser's help names the tool's own project directory.
Project scope is resolved from a root the tool describes, with a ready-made resolver that
walks up to the nearest marker such as `.git`, so install, status, uninstall, and session
discovery always agree. `kit status` reports local edits (`modified`) separately from
upstream drift (`changed-upstream`), and the two compose with `outdated`. `kit list --json`,
`kit status --json`, and `kit update --json` print one versioned JSON document on stdout,
pinned by golden tests, and never mix warnings into it. The package is prepared for release as
`baikai-kit 0.3.0.0`.

In scope: the `baikai-kit` library, its test suite, `docs/user/kit.md`, the CAP-21 capability
record `docs/capabilities/kit-installer.md` and its compiled twin
`baikai-smoke/doc-shapes/Shape/Cap21.hs`, the root `CHANGELOG.md`, the four improvement
requests' status, and ADRs for the durable decisions.

Out of scope: migrating the consumers. IR-6's acceptance criteria 4 and 5 ("rei can delete its
`Rei.Cli.Commands.Kit.{Types,Parser,Handler}`", "okf can delete its `KitCommand` mirror") are
proved by the shape of the new API, and the actual deletions happen in those repositories after
they raise their bound to `baikai-kit ^>=0.3`. Shipping a default picker, any terminal-UI
dependency, a diff or restore command, filtering flags, JSON output for `install` or
`uninstall`, and uploading to Hackage are also excluded, as the requests themselves exclude
them.


## Decomposition Strategy

The work splits cleanly along the four requests, because each one is a distinct user-visible
behaviour with its own acceptance tests, and each touches a different centre of the package:
IR-8 lives in `Baikai.Kit.Config` and `Baikai.Kit.Session`, IR-7 in `Baikai.Kit.Status` and the
local-edit check in `Baikai.Kit.Install`, IR-6 in `Baikai.Kit.Command` and `KitConfig`, and
IR-9 in a new encoding module plus `Baikai.Kit.Command`. One child plan per request keeps each
plan independently verifiable and lets the two plans with no shared code (IR-8 and IR-7) run in
parallel.

Two shared artifacts force ordering rather than merging. `KitConfig` gains a field in both the
IR-8 and IR-6 plans, and every consumer builds `KitConfig` as a record literal (for example
`mori://shinzui/rei`'s `Rei.Cli.Commands.Kit.Config.reiKitConfig`), so adding any strict field
is a compile error for them. The first plan to change `KitConfig` therefore introduces a smart
constructor and replaces the derived `Show` instance (a function-typed field cannot derive
`Show`), and the second extends both. `KitCommand` is changed by the IR-6 plan (optional install
name, `Eq`, config-aware parser) and by the IR-9 plan (a `--json` flag on three verbs); the IR-6
plan owns the new shape and the IR-9 plan extends it. The IR-9 plan also serialises the status
row, whose shape the IR-7 plan changes; encoding it before that change would pin a
`dirty`-bearing contract only to break it.

Alternatives considered. One plan for everything was rejected: it would exceed ten files and
five milestones across unrelated modules, which is the MasterPlan threshold. Merging IR-6 and
IR-9 because both edit `KitCommand` was rejected because the edits are additive to different
constructors and the behaviours are tested separately. A fifth "foundation" plan that only
reshapes `KitConfig` and `KitCommand` was rejected as a plan with no user-visible behaviour of
its own. Folding the release into its own plan was rejected as too small; it is the last
milestone of the final plan.

ADRs consulted, from `docs/adr/`, and how they bind this initiative:

- [docs/adr/0013-library-code-never-calls-exitfailure.md](../adr/0013-library-code-never-calls-exitfailure.md):
  only `Baikai.Kit.Command.runKit` may exit. A cancelled choice, a missing chooser, and every
  JSON-mode path must return values from `runKitCommand`; a missing chooser is a new `KitError`
  constructor, not an exit.
- [docs/adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md](../adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md):
  the JSON document is written as UTF-8 bytes (`Data.ByteString.Lazy.hPut` of
  `Data.Aeson.encode`), never through the locale.
- [docs/adr/0016-deprecated-names-are-removed-at-the-next-major.md](../adr/0016-deprecated-names-are-removed-at-the-next-major.md):
  the renamed and reshaped names (`KitState`'s constructors, `renderState`, the
  `kitCommandParser` signature) cannot sensibly be kept as deprecated aliases because their
  meaning changes, so they change outright in the 0.3.0.0 major, recorded under `### Changed`
  in the changelog with a migration note.
- [docs/adr/0017-a-documented-example-compiles-in-the-test-suite.md](../adr/0017-a-documented-example-compiles-in-the-test-suite.md):
  CAP-21's `## Shape` block builds `KitConfig` as a record literal and has a compiled twin in
  `baikai-smoke/doc-shapes/Shape/Cap21.hs`. Whichever plan changes `KitConfig` must edit both in
  the same commit; `cabal test baikai-smoke:test:doc-shapes` enforces it.
- [docs/adr/0005-what-baikai-deliberately-does-not-do.md](../adr/0005-what-baikai-deliberately-does-not-do.md)
  is not directly about the kit but sets the precedent that deliberate exclusions are recorded;
  "the engine ships no terminal UI" is such an exclusion.

No cross-repository ADR in the Mori registry governs `baikai-kit`'s surface.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Resolve kit project scope from a configurable project root (IR-8) | docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md | None | None | Complete |
| 2 | Report local edits and upstream drift as separate kit status conditions (IR-7) | docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md | None | None | Complete |
| 3 | Let kit install choose an item through a caller-supplied chooser (IR-6) | docs/plans/80-let-kit-install-choose-an-item-through-a-caller-supplied-chooser.md | EP-1 | None | Complete |
| 4 | Add versioned JSON output to kit list, status, and update (IR-9), and prepare baikai-kit 0.3.0.0 | docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md | EP-2, EP-3 | EP-1 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 and EP-2 have no dependencies and touch disjoint code (`Config`/`Session` versus
`Status`/the local-edit check), so they can be implemented in parallel or in either order.

EP-3 hard-depends on EP-1. EP-1 adds the `projectRoot` field to `KitConfig`, introduces the
`kitConfig` smart constructor, and replaces the derived `Show` instance with a hand-written one.
EP-3 adds a second function-typed field, `chooseItem`, and must extend exactly those three
artifacts; without them its field would either break every consumer's record literal a second
time or fail to derive `Show`.

EP-4 hard-depends on EP-2 and EP-3. It encodes `StatusRow` into the public JSON contract, so
the status conditions EP-2 introduces (`modified`, `changed-upstream`, `edits-unknown`) must
already exist; and it adds a `--json` flag to the `KitCommand` constructors and parser whose
new shape EP-3 defines. EP-4's soft dependency on EP-1 is already implied by the chain: its
golden fixture covers both scopes, and a configured `projectRoot` lets the test place project
scope in a temporary directory without changing the process's current directory.

The resulting order is EP-1 ∥ EP-2, then EP-3, then EP-4. EP-2 may also run alongside EP-3.


## Integration Points

**`KitConfig` (in `baikai-kit/src/Baikai/Kit/Config.hs`).** Touched by EP-1 and EP-3. EP-1
defines the shape: it adds `projectRoot :: !(IO FilePath)`, adds the exported smart constructor
`kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig` whose defaults reproduce
today's behaviour (`projectRoot = getCurrentDirectory`), and replaces
`deriving stock (Generic, Show)` with `deriving stock (Generic)` plus a hand-written `Show`
instance that prints the data fields and a placeholder for each function field. EP-3 adds
`chooseItem :: !(Maybe (KitManifest -> IO (Maybe Text)))`, defaults it to `Nothing` in
`kitConfig`, and extends the `Show` instance. Neither plan may reorder the three existing
fields. Both plans update the test suite's `testConfig` to use `kitConfig`.

**`KitCommand` and `kitCommandParser` (in `baikai-kit/src/Baikai/Kit/Command.hs`).** Touched by
EP-3 and EP-4. EP-3 defines the shape: `KitInstall !(Maybe Text) !KitScope`,
`deriving stock (Eq, Show)`, and `kitCommandParser :: KitConfig -> Parser KitCommand` (the
parser takes the config so help text can name `.<tool>/agents`). EP-4 adds a trailing
`!OutputFormat` field to `KitList`, `KitStatus`, and `KitUpdate` (with
`data OutputFormat = HumanOutput | JsonOutput deriving stock (Eq, Show)`), keeps `Eq`, and adds
a `--json` switch to those three subcommands only.

**`StatusRow` and the status vocabulary (in `baikai-kit/src/Baikai/Kit/Status.hs`).** Defined by
EP-2, consumed by EP-4. EP-2 replaces `state :: !KitState` with
`conditions :: ![KitCondition]` (sorted, duplicate-free, empty meaning up to date) and exports
`conditionLabel :: KitCondition -> Text` and `renderConditions :: [KitCondition] -> Text`. EP-4
must use `conditionLabel` for the JSON strings, so the table and the JSON can never spell a
condition differently.

**The local-edit check (in `baikai-kit/src/Baikai/Kit/Install.hs`).** Defined by EP-2. EP-2
factors today's private `locallyModified` into an exported per-provider check returning
`LocalEdits` (`Unedited`, `Edited`, `EditsUnknown`), used by both `kit update` and
`kit status`, so the two commands cannot disagree. No other plan touches it.

**Project-scope path resolution (in `Baikai.Kit.Config`).** Defined by EP-1. Every project-scope
path must be derived from `projectRoot` through `projectAgentsDir`, `resolveAgentsBase`, or
`providerAgentsBase`. Any later plan that needs a project-scope path (EP-4's list output
reports installed locations) must call these functions and never `getCurrentDirectory`.

**`CHANGELOG.md` (repository root) and `docs/user/kit.md`.** Every plan appends to both. Each
plan adds bullets under `## [Unreleased]`, each beginning with `baikai-kit:`; EP-4 alone moves
them under a new `## [baikai-kit 0.3.0.0] - <date>` heading and bumps
`baikai-kit/baikai-kit.cabal` to `0.3.0.0`. Each plan edits only its own sections of
`docs/user/kit.md`, bumps its `generated.at`, and appends an entry to `docs/user/log.md`.

**CAP-21 (`docs/capabilities/kit-installer.md`) and `baikai-smoke/doc-shapes/Shape/Cap21.hs`.**
EP-1 changes the `## Shape` block and its twin together. EP-2 corrects the prose and Limits that
say `dirty`. EP-4 adds the new module to `interface`, extends the evidence text, and records a
`docs/capabilities/log.md` entry for the release.

**ADR numbering.** Plans that create an ADR take the next unused number in `docs/adr/` at the
moment they commit (currently the next is 0021) and add a row to `docs/adr/README.md`. Numbers
are not pre-assigned, because EP-1 and EP-2 may commit in either order.

Cross-plan decisions that deserve ADRs, and the plan responsible for writing each:

- EP-1: "Kit project scope is one resolved root, and every project-scope path derives from
  it" — an architecture boundary that later kit features must respect.
- EP-2: "`kit status` and `kit update` share one local-edit check; upstream drift and local
  edits are separate conditions" — shared interface ownership.
- EP-3: "The kit engine ships no terminal UI; interactive choice is injected through
  `KitConfig`" — a deliberate exclusion.
- EP-4: "Machine-readable kit output is a versioned contract written by explicit encoders, and
  stdout carries only the document" — a durable integration constraint.


## Progress

- [x] EP-1: Milestone 1 — `projectRoot`, `kitConfig`, the marker resolver, and resolver tests.
- [x] EP-1: Milestone 2 — install, status, uninstall, and session discovery agree across subdirectories; docs, CAP-21 Shape and twin, changelog, ADR.
- [x] EP-2: Milestone 1 — shared local-edit check and the `KitCondition` vocabulary, existing drift tests kept under new names.
- [x] EP-2: Milestone 2 — `kit status` reports local edits; agreement test with `kit update`; docs, changelog, ADR.
- [x] EP-3: Milestone 1 — `KitCommand` derives `Eq`, optional install name, config-aware parser and help text.
- [x] EP-3: Milestone 2 — `chooseItem` wired into install, cancel and missing-chooser paths tested; docs, changelog, ADR.
- [ ] EP-4: Milestone 1 — explicit encoders and golden tests for list, status, and update documents.
- [ ] EP-4: Milestone 2 — `--json` flags, stdout discipline under stale and unreachable caches.
- [ ] EP-4: Milestone 3 — documentation, ADR, CAP-21 refresh, and `baikai-kit 0.3.0.0` release preparation.
- [ ] Mark IR-6, IR-7, IR-8, and IR-9 completed with per-criterion evidence.


## Surprises & Discoveries

- IR-8's contract item 4 asks for a change that is "additive for existing callers". In Haskell
  that is not achievable by adding a field: every consumer builds `KitConfig` as a record
  literal, and omitting a strict field is a compile error, not a default. Evidence: `KitConfig`
  in `baikai-kit/src/Baikai/Kit/Config.hs` has only strict fields, and
  `mori://shinzui/rei`'s `rei-cli/src/Rei/Cli/Commands/Kit/Config.hs` constructs it as
  `KitConfig { toolName = …, repoUrl = …, providers = … }`. The initiative therefore honours the
  intent (no behaviour change for a consumer that supplies nothing) through the `kitConfig`
  smart constructor, and the release is a major version.
- The CAP-21 `## Shape` block is compiled (ADR 0017), so the `KitConfig` change breaks
  `cabal test baikai-smoke:test:doc-shapes` unless the record and its twin change together.
- `runKitCommand` prints `Fetched <tool>-kit.` to stdout when it clones the cache
  (`withRepo` in `baikai-kit/src/Baikai/Kit/Command.hs`), which would corrupt a JSON document on
  a first run. EP-4 must move that line to stderr in JSON mode.
- (EP-1) `okf log add` reflows every existing entry of the `log.md` it appends to. Every plan
  that appends to `docs/capabilities/log.md` or `docs/user/log.md` should insert the dated
  entry by hand. ADR 0021 was taken by EP-1, so the next free ADR number is 0022.
- (EP-1) A change to `KitConfig` cannot be committed separately from the CAP-21 Shape block
  and twin; EP-3's field addition should expect to land its milestone 2 docs with the code.
  `CHANGELOG.md` `## [Unreleased]` now has `### Added` and `### Changed` subsections for later
  plans to append to.
- (EP-2) `KitCondition`'s constructor order is the render order, and `StatusRow.conditions`
  is always `sort . nub`-normalised in `collectStatus`, so EP-4 can encode the list as-is.
  ADR 0022 was taken; the next free ADR number is 0023. `reinstallPresent` scans the
  project scope too, so any test that compares status with update should set `projectRoot`
  to a temporary directory.
- (EP-3) `KitCommand` now derives `Eq`, `KitInstall` takes `Maybe Text`, and
  `kitCommandParser :: KitConfig -> Parser KitCommand`; `runKitCommand` factors the install
  tail into a local `installNamed`. ADR 0023 was taken; the next free ADR number is 0024. The
  `Fetched <tool>-kit.` line still goes to stdout via `withRepo`, which EP-4 must redirect in
  JSON mode.


## Decision Log

- Decision: Decompose into four child plans, one per improvement request, with the release as
  the last milestone of the IR-9 plan.
  Rationale: each request is an independently testable behaviour centred on a different module;
  a single plan would exceed the size threshold, and a separate release plan would have no
  behaviour of its own.
  Date: 2026-09-23

- Decision: EP-1 (IR-8) owns the `KitConfig` reshape — the `kitConfig` smart constructor and the
  hand-written `Show` — and EP-3 (IR-6) hard-depends on it.
  Rationale: both add a function-typed field; the first to land must introduce the constructor
  and the `Show` instance, and fixing the order removes a conditional from both plans. IR-8 was
  chosen first because its change is the more fundamental one (every project-scope path) and it
  has no other dependency.
  Date: 2026-09-23

- Decision: EP-3 (IR-6) owns the `KitCommand` reshape and EP-4 (IR-9) extends it; EP-4 also
  hard-depends on EP-2 (IR-7).
  Rationale: EP-4's golden JSON pins the status vocabulary, which EP-2 renames, and its flags
  extend constructors EP-3 changes. Encoding before either lands would pin a contract that is
  about to break.
  Date: 2026-09-23

- Decision: The initiative ships as `baikai-kit 0.3.0.0`, a major release, and does not keep
  deprecated aliases for `KitState`, `renderState`, or the old `kitCommandParser` signature.
  Rationale: `KitConfig` gains strict fields and `KitCommand` constructors change arity, which is
  breaking regardless. The old status states change meaning (`dirty` stops meaning upstream
  drift), so an alias would be a lie, and ADR 0016 prefers a clean break to a permanent second
  surface.
  Date: 2026-09-23

- Decision: Consumer migrations (rei, okf, mori) are out of scope; IR-6 acceptance items 4 and 5
  are demonstrated by the new API's shape and closed when those repositories adopt it.
  Rationale: those changes are owned by other repositories and cannot be verified here.
  Date: 2026-09-23

- Decision: Link each improvement request to its child ExecPlan with the profile's
  `targetPlan` field and move it from `proposed` to `accepted`.
  Rationale: `targetPlan` and `accepted` are the vocabulary of the current
  `mori://shinzui/okf-profiles` `coordination.improvementRequests` profile, which has no
  `planned` status; the bundle's pinned v0.6.0 profile accepts both, so the change is valid now
  and after the pin is raised.
  Date: 2026-09-23


## Outcomes & Retrospective

(To be filled during and after implementation.)
