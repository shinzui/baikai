---
type: Improvement Request
title: Add machine-readable kit list and status output
description: >-
  Give `kit list` and `kit status` a `--json` mode backed by stable encodings of the
  manifest and status rows, so scripts, agents, and other tools can consume kit state
  without parsing a column-aligned table.
timestamp: 2026-09-23T17:40:00Z
requestId: IR-9
status: completed
completedAt: "2026-09-23T00:00:00Z"
targetPlan: docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md
origin: mori://shinzui/mori
---

# Improvement Request: Add Machine-Readable Kit List and Status Output

## Status

Completed on 2026-09-23 by
[docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md](../plans/81-add-versioned-json-output-to-kit-list-status-and-update.md)
(commits `4745a0e` and `d1329de`). Evidence per criterion, in the "JSON" group of
`baikai-kit/test/Main.hs`:

1. "kit-list document matches the golden", "kit-status document matches the golden", and
   "kit-update document matches the golden" pin `baikai-kit/test/golden/{list,status,update}.json`
   over a fixture with five skills and two agents across both scopes and both providers, covering
   `unknown`, `delisted`, `refused`, `outdated`, `changed-upstream`, `modified`,
   `edits-unknown`, and up to date. "the command and the encoder agree" checks the `--json`
   command against the same status golden.
2. "status --json parses as one document when the cache is stale" and "… when the repository
   is unreachable"; in addition, "list --json writes nothing to stdout when the repository is
   unreachable", "update --json writes nothing to stdout when the pull fails", and "list --json
   keeps the first-clone notice off stdout".
3. `docs/user/kit.md` has a Machine-Readable Output section documenting every key and the
   `formatVersion` rule. The contract is recorded in
   [ADR 0024](../adr/0024-machine-readable-kit-output-is-a-versioned-contract.md).

Released as `baikai-kit 0.3.0.0`, prepared in commit `d1329de` (`chore(release): baikai-kit
0.3.0.0`) and not yet uploaded to Hackage; a consumer can depend on it from git until then.

Accepted and planned on 2026-09-23. The accepted design is EP-4,
[docs/plans/81-add-versioned-json-output-to-kit-list-status-and-update.md](../plans/81-add-versioned-json-output-to-kit-list-status-and-update.md),
of the MasterPlan
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md).
It is sequenced after the IR-7 plan, because the status document encodes the condition
vocabulary that plan introduces, and after the IR-6 plan, because it extends the command type
that plan reshapes. Its final milestone prepares the `baikai-kit 0.3.0.0` release.

The shapes are exposed as explicit encoder functions (`listDocument`, `statusDocument`,
`updateDocument` in a new `Baikai.Kit.Json` module) rather than `ToJSON` instances, so renaming
a Haskell field cannot silently change the contract. Each document carries `formatVersion` and
`document`, every documented key is always present, and a failed command writes nothing to
stdout.

This is a convenience rather than a blocker, but it is cheap because the data is already
structured.

## Context

`kit list` prints `renderAvailable manifest` and `kit status` prints
`renderStatusTable rows`. Both produce text formatted for a terminal. The structures behind
them are already typed:

- `KitManifest`, `SkillEntry`, and `AgentEntry` derive `FromJSON` but not `ToJSON`.
- `StatusReport` carries `upstream` availability and a list of `StatusRow` records with
  name, kind, scope, providers, installed and latest version, and state. Neither type has a
  `ToJSON` instance.
- `UpdateReport` records the items updated and skipped as `(name, scope)` pairs.

Two kinds of callers need this data rather than the text:

- Agents that `mori://shinzui/mori` launches read the kit skill catalogue. At present they
  must either parse `kit list` output or read the cached `kit.json`, which bypasses the
  engine's version gate and path checks.
- An interactive chooser (see [IR-6](./let-kit-install-choose-an-item-interactively.md))
  or a shell completion needs names, kinds, and installed state. Today it would get them by
  scraping the same columns.

The status table also merges rows across providers (`aggregateStatusRows`), which suits a
reader but loses per-provider detail that a script may need.

## Requested contract

1. `kit list --json` prints the manifest items as JSON: name, kind, description, and
   version, plus whether and where each item is installed.
2. `kit status --json` prints the status report as JSON: upstream availability and one
   entry per installed item per scope, with per-provider detail, not only the aggregated
   rows.
3. `kit update --json` prints the update report (refresh outcome, updated items, skipped
   items with their reason).
4. The JSON shapes are part of the public contract, include a top-level format version, are
   pinned by golden tests, and are exposed as `ToJSON` instances (or explicit encoders) so
   library callers get the same shape without going through the command.
5. In `--json` mode, warnings (such as a stale cache or an unreachable repository) go to
   stderr or into the JSON document, and never into stdout as bare text.

## Acceptance

This request is complete when:

1. Golden tests pin the `list`, `status`, and `update` JSON for a fixture kit that covers
   skills and agents, both scopes, both providers, and each status state.
2. A test asserts that `--json` stdout parses as a single JSON document when the kit cache
   is stale or the repository is unreachable.
3. `docs/user/kit.md` documents the fields and the format version.

## Non-goals

This request does not change the human-readable output, add filtering flags, or add JSON
output to `install` or `uninstall`.

## References

- `mori://shinzui/baikai/packages/baikai-kit`: `Baikai.Kit.Install.renderAvailable`,
  `Baikai.Kit.Status.StatusReport`, `StatusRow`, `renderStatusTable`, and
  `aggregateStatusRows`, and `Baikai.Kit.Manifest.KitManifest`
- [IR-6](./let-kit-install-choose-an-item-interactively.md): the chooser that would
  consume the manifest in structured form
