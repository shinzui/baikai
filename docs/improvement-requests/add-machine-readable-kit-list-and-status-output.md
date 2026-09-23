---
type: Improvement Request
title: Add machine-readable kit list and status output
description: >-
  Give `kit list` and `kit status` a `--json` mode backed by stable encodings of the
  manifest and status rows, so scripts, agents, and other tools can consume kit state
  without parsing a column-aligned table.
timestamp: 2026-09-23T13:49:07Z
requestId: IR-9
status: proposed
origin: mori://shinzui/mori
---

# Improvement Request: Add Machine-Readable Kit List and Status Output

## Status

Proposed. This is a convenience rather than a blocker, but it is cheap because the data is
already structured.

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
