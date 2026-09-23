---
type: Improvement Request
title: Report local edits in kit status
description: >-
  Make `kit status` run the same installed-file check `kit update` already runs, so an item
  that has been edited in place is reported before an update skips it, and rename the state
  that currently calls upstream drift "dirty".
timestamp: 2026-09-23T17:40:00Z
requestId: IR-7
status: completed
completedAt: "2026-09-23T00:00:00Z"
targetPlan: docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md
origin: mori://shinzui/mori
---

# Improvement Request: Report Local Edits in Kit Status

## Status

Completed on 2026-09-23 by
[docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md](../plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md)
(commit `7936ba5`). Evidence per criterion, in `baikai-kit/test/Main.hs`:

1. "editing an installed file reports modified" (the edited provider's row is `[modified]`,
   the other `[]`) and its companion "an installed item reports no conditions before an edit".
2. The drift tests are kept as "hash mismatch => changed-upstream" and "version and cached
   hash drift reports outdated+changed-upstream".
3. "status reports modified for exactly what update would skip" compares the set `kit status`
   reports as `modified` with `UpdateReport.skipped` under `KeepLocalEdits`; both commands call
   the one exported `checkLocalEdits`.
4. `docs/user/kit.md` describes the upstream check and the local-edit check and which command
   acts on each; `CHANGELOG.md` records the `dirty` → `changed-upstream` rename as breaking.
   The shared check is recorded in
   [ADR 0022](../adr/0022-kit-status-and-update-share-one-local-edit-check.md).

Released as `baikai-kit 0.3.0.0`, prepared in commit `d1329de` (`chore(release): baikai-kit
0.3.0.0`) and not yet uploaded to Hackage; a consumer can depend on it from git until then.

Accepted and planned on 2026-09-23. The accepted design is EP-2,
[docs/plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md](../plans/79-report-local-edits-and-upstream-drift-as-separate-kit-status-conditions.md),
of the MasterPlan
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md),
which ships IR-6 through IR-9 together as `baikai-kit 0.3.0.0`.

The names left to review are settled as `modified` (local edits), `changed-upstream` (upstream
sources changed without a version bump), and `edits-unknown` (a sidecar written before
`installedHash` existed); `unknown`, `delisted`, `refused`, `outdated`, and `up-to-date` keep
their meanings. `KitState` is replaced by a sorted list of `KitCondition` flags on
`StatusRow.conditions`, which is how the conditions compose. The installed-file comparison is
factored into one exported check that both `kit status` and `kit update` call.

This is a reporting gap, not a defect. The current behaviour is documented in
`docs/user/kit.md`. The problem is that `status` and `update` disagree about whether an item has
been modified, and `status` is the command a user runs to find out.

## Context

`baikai-kit` records two independent hashes in each item's sidecar (`SidecarMeta`):

- `hash` is the hash of the item's *upstream sources* at install time.
- `installedHash`, over `installedFiles`, is the hash of the *files written into the
  provider directory*.

The two commands use different hashes:

- `kit status` (`Baikai.Kit.Status.classify`) compares the recorded `hash` with the hash of
  the item's sources in the cached checkout. When they differ, the row is `dirty`, which
  means the kit changed upstream without a version bump. `installedHash` is never read.
  `docs/user/kit.md` says so: the dirty check "does not hash provider-installed target
  files".
- `kit update` (`Baikai.Kit.Install.locallyModified`) re-hashes the installed files against
  `installedHash`. With `KeepLocalEdits` it skips any item whose installed files have
  changed, and prints `Skipped '<name>' … run 'kit update <name> --force' to overwrite.`

So a user who edits an installed skill sees it reported as `up-to-date` by `kit status`, and
learns that it is modified only when `kit update` skips it. The state that `status` does
call `dirty` does not describe local edits at all. In most version-control and package
tools, "dirty" means a local working copy has diverged, which is the case `status` cannot
detect. The name therefore misleads users in both directions.

Both hashes are already written at install time, and the local-edit check is already
implemented. It is not wired into `status`.

## Requested contract

1. `kit status` evaluates the local-edit check for every installed row, using the same
   logic as `locallyModified`, and reports an item whose installed files no longer match
   `installedHash` (or cannot be read) as locally modified.
2. The two conditions are named separately. Local edits get a state such as `modified`.
   Upstream sources that changed without a version bump get a state that says so, such as
   `changed-upstream`, in place of today's `dirty`. The exact names are left to review, but
   `dirty` must not continue to mean upstream drift.
3. The states compose. An item can be outdated, changed upstream, and locally modified at
   once, and the report says all of it rather than choosing one. That may be a set of
   flags on `StatusRow` in place of one enumerated `KitState`.
4. A sidecar written before `installedFiles`/`installedHash` existed is reported as "local
   edits unknown", not as unmodified, matching how `unknown` already treats a missing
   sidecar.
5. `status` still needs no network, as it does today.

## Acceptance

This request is complete when:

1. A test installs an item, edits one installed file, and asserts that `kitStatus` reports
   it as locally modified. A companion test asserts that the same item is reported
   unmodified before the edit.
2. The existing upstream-drift tests (`hash mismatch => dirty`,
   `version and cached hash drift reports dirty+outdated`) are kept under the new state
   names.
3. For every item `kit update` would skip under `KeepLocalEdits`, `kit status` reports that
   item as locally modified. A test asserts this agreement directly.
4. `docs/user/kit.md` describes both checks and states which command acts on each. The
   CHANGELOG records the state rename as a user-visible change.

## Non-goals

This request does not ask `status` to show a diff, to restore modified files, or to change
what `kit update` does with a modified item. It does not change the sidecar format beyond
what reading `installedHash` in `status` requires.

## References

- `mori://shinzui/baikai/packages/baikai-kit`: `Baikai.Kit.Status.classify` and
  `collectStatus`, `Baikai.Kit.Install.locallyModified`, and
  `Baikai.Kit.Sidecar.SidecarMeta`
- `docs/user/kit.md`: the documented state table and the note that the dirty check does
  not hash installed files
