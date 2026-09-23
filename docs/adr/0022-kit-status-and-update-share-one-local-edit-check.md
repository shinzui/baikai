---
title: Kit status and kit update share one local-edit check, and upstream drift and local edits are separate conditions
status: accepted
date: 2026-09-23
---

# Kit status and kit update share one local-edit check, and upstream drift and local edits are separate conditions

## Context

`baikai-kit` 0.2 taught `kit update` to notice an installed file the user
had edited by hand: each sidecar records the files this tool wrote for a
provider and their hash, and `update` skips an item whose files no longer
hash to it unless `--force`. `kit status` never ran that check. An edited
item read `up-to-date` until `update` skipped it, and the state `status` did
call `dirty` meant something else entirely — that the kit's upstream sources
had changed without a version bump. Improvement request IR-7
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-7`), raised from
`mori://shinzui/mori`, recorded both problems: a user could not see local
edits before running `update`, and the one word that suggested local edits
meant upstream drift.

Status was also a single enumerated state (`KitUpToDate`, `KitOutdated`,
`KitDirty`, `KitDirtyOutdated`, …), which cannot express three independent
facts at once without one constructor per combination.

## Decision

**There is one implementation of the installed-file comparison,
`Baikai.Kit.Install.checkLocalEdits`, and both `kit status` and `kit update`
call it.** It returns `Unedited`, `Edited` (a file differs or cannot be
read), or `EditsUnknown` (no sidecar, or one written before the installed
hash existed). `update` skips `Edited` under `KeepLocalEdits`; `status`
reports `Edited` as `modified` and `EditsUnknown` as `edits-unknown`.

**Upstream drift and local edits are separate conditions and are never
merged into one word.** `changed-upstream` means the upstream sources
changed without a version bump (what `dirty` used to mean); `modified` means
the installed files were edited. A status row carries a sorted,
duplicate-free list of `KitCondition` values instead of one state, rendered
in a fixed order joined by `+` (`outdated+changed-upstream+modified`), and
spelled by one function, `conditionLabel`, that every output format uses.
The removed names were not kept as deprecated aliases, because their
meaning changed ([ADR 0016](0016-deprecated-names-are-removed-at-the-next-major.md)).

## Consequences

The test "status reports modified for exactly what update would skip" in
`baikai-kit/test/Main.hs` compares the two commands directly; a second
implementation of the check, or a divergence in how either command reads
the result, fails it.

A new condition is a new constructor and a new label, and composes with the
others without touching existing ones. Consumers that matched on
`KitState` must match on the list instead, which the 0.3.0.0 changelog
records as a breaking change.
