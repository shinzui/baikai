---
title: Kit project scope is one resolved root, and every project-scope path derives from it
status: accepted
date: 2026-09-23
---

# Kit project scope is one resolved root, and every project-scope path derives from it

## Context

`baikai-kit` installs skills and subagents either for the user (`UserScope`,
under the home directory) or for a project (`ProjectScope`). Until
`baikai-kit 0.3.0.0` "the project" was whatever directory the command ran
in: `projectAgentsDir` and the Codex project base both called
`getCurrentDirectory`. Improvement request IR-8
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-8`), raised from
`mori://shinzui/mori`, recorded the consequences. `mytool kit install review
--project` from `src/` wrote under `src/.mytool/agents`; `mytool kit status`
from the repository root did not list it; `kit uninstall --project` from the
root said it was not installed; and an interactive session started from a
subdirectory mounted no project skills, because `agentDirsForSession` looked
in yet another place. Each command was individually correct and collectively
inconsistent.

The consuming tools do not agree on what a project root is — a `.git`
directory, a tool-specific marker such as `.mori`, or a configured workspace —
so the engine cannot hard-code one rule.

## Decision

**`KitConfig.projectRoot :: IO FilePath` is the only source of the project
directory.** `projectAgentsDir`, `resolveAgentsBase` and `providerAgentsBase`
in `Baikai.Kit.Config` are the only functions that turn it into paths, and no
other code in the package calls `getCurrentDirectory` for project scope.
Install, status, update, uninstall and `agentDirsForSession` all reach project
scope through those functions, so they cannot disagree.

The default, set by the `kitConfig` smart constructor, is
`getCurrentDirectory`, which preserves the old behaviour for a tool that
configures nothing. `projectRootByMarkers markers` is the ready-made resolver
most tools want: it walks up to the nearest directory holding any marker and
falls back to the current directory, so a tool still works outside a
project. It does not canonicalise, because replacing a symlinked checkout path
with its target would make install locations surprising. The resolver is a
plain `IO FilePath`, not an `Either`: the supplied resolver cannot fail, and an
exception thrown by a consumer's own resolver propagates.

## Consequences

A consuming tool configures its root once, in its `KitConfig`, and every kit
verb follows. A new kit feature that needs a project-scope path must call one
of the three functions above; `grep -rn getCurrentDirectory baikai-kit/src`
should find only the default in `kitConfig` and the start of the walk in
`projectRootByMarkers`.

Adding a strict field to `KitConfig` breaks every consumer that builds it as a
record literal, which is why `kitConfig` exists and is the documented way to
build one: later optional fields can be added with a default there without a
second break. `KitConfig`'s `Show` instance is hand-written, since a function
field cannot derive one.
