---
title: Kit visibility is honoured per provider or refused
status: accepted
date: 2026-10-02
---

# Kit visibility is honoured per provider or refused

## Context

Tool scope and provider discovery previously implied opposite visibility:
Claude assets needed the owning tool's `--add-dir`, while Codex assets
were discovered in every session. An item author could not choose shared
visibility and users could not see the difference in status. IR-12
([request](../improvement-requests/let-a-kit-item-choose-tool-only-or-shared-visibility.md))
asked for an explicit choice and protection of shared names.

## Decision

Visibility is per item and independent of user/project scope. Every
provider honours requested `tool-only` or `shared`, or installation
refuses before writing any provider copy. A tool-only Codex custom agent
requires explicit acceptance of effective shared visibility, supplied by
an install flag or the consumer's optional confirmation callback. The
engine owns the flow and ships no UI, following [ADR 0023](0023-the-kit-engine-ships-no-terminal-ui.md).

Shared Claude copies are links to tool-owned copies; project links use
relative targets so they survive clones. Codex skills remain in native
discovery roots, disabled in the user's config for tool-only visibility.
Consumers append `codexSessionArgs` to their Codex launch arguments to
re-enable their hidden skills. `--add-dir` only grants Codex write access.
An offline check with codex-cli 0.160.0 proved absence in a plain session
and presence with the session arguments.

The kit never takes over a shared name. Only the expected Claude link or
this tool's Codex sidecar authorises reuse. Links and owned config entries
are recorded in sidecars. During a visibility switch, pending removals stay
recorded until the external operation succeeds, so a post-content failure
retains the ownership needed by update. Update reconciles installed provider
copies and surviving sidecars; adding a provider requires explicit install,
so update cannot introduce a new unaccepted shared agent. Existing user-owned disabled entries are reused
without recording ownership, and session arguments still re-enable them.
Shared visibility refuses a user-owned disabled entry rather than silently
leaving the skill hidden or deleting the user's setting.
Config edits preserve the original text and permissions and compare parsed
TOML before atomic rename; symlinks and incompatible edits are refused.
Delimiter comments mark appended blocks, including their separator newline,
so uninstall restores even a file originally lacking a final newline.

One check, `Baikai.Kit.Install.checkVisibility`, computes requested and
effective visibility and broken links/entries for status and update.
Status supplies one Codex config snapshot to all rows. Update repairs
visibility even when local edits skip content. Uninstall removes owned
links/entries and preserves replaced links and foreign Codex assets.

## Consequences

Old sidecars have no requested visibility: update keeps their placement;
status exposes legacy Codex skills as shared and recommends explicit
reinstall. New manifest-driven installs follow changed defaults, while
install flags persist. JSON adds fields at format version 1, following
[ADR 0024](0024-machine-readable-kit-output-is-a-versioned-contract.md).

A standard kit integration needs a dependency bump. A tool that launches
Codex must also wire the session arguments; otherwise its tool-only skills
are hidden in its own sessions. Codex custom agents remain shared until a
provider-supported isolation mechanism exists. Publishing the package and
changing consumers are separate work.
