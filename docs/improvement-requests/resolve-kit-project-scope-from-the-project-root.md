---
type: Improvement Request
title: Resolve kit project scope from the project root
description: >-
  Let KitConfig say how to find the project root, so project-scope installs and session
  discovery use the same directory no matter which subdirectory the tool was run from.
timestamp: 2026-09-23T17:40:00Z
requestId: IR-8
status: completed
completedAt: "2026-09-23T00:00:00Z"
targetPlan: docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md
origin: mori://shinzui/mori
---

# Improvement Request: Resolve Kit Project Scope from the Project Root

## Status

Completed on 2026-09-23 by
[docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md](../plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md)
(commit `ea4113e`). `KitConfig` gained `projectRoot :: IO FilePath`, built by the `kitConfig`
smart constructor with the current directory as default; `projectRootByMarkers` and
`findProjectRoot` supply the marker walk. Evidence per criterion, all in the "Project root"
group of `baikai-kit/test/Main.hs`:

1. "a configured root puts project scope in one place" installs `demo` at project scope from
   `proj/src/deep`, asserts the files are under `proj`, and from `proj/docs` finds it with
   `kitStatus`, `agentDirsForSession`, and `uninstallItem`; it repeats the install and status
   steps with `projectRootByMarkers`.
2. "findProjectRoot walks up from a nested directory", "… accepts a start directory that is
   itself the root", and "… returns Nothing when no marker exists" (which also checks that
   `projectRootByMarkers` falls back to the current directory).
3. "without a resolver, project scope is the current directory".
4. `docs/user/kit.md` has a Project Scope section. The boundary is recorded in
   [ADR 0021](../adr/0021-kit-project-scope-is-one-resolved-root.md).

Released as `baikai-kit 0.3.0.0`, prepared in commit `d1329de` (`chore(release): baikai-kit
0.3.0.0`) and not yet uploaded to Hackage; a consumer can depend on it from git until then.

Accepted and planned on 2026-09-23. The accepted design is EP-1,
[docs/plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md](../plans/78-resolve-kit-project-scope-from-a-configurable-project-root.md),
of the MasterPlan
[docs/masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md](../masterplans/13-close-the-baikai-kit-consumer-gaps-from-ir-6-to-ir-9.md),
which ships IR-6 through IR-9 together as `baikai-kit 0.3.0.0`.

One correction to the contract. Item 4 asks for a change that is additive for existing callers,
but every consumer builds `KitConfig` as a record literal, and in Haskell omitting a strict field
is a compile error rather than a default. The plan therefore adds `projectRoot :: IO FilePath`
together with a smart constructor, `kitConfig`, whose default is today's current-directory
behaviour: a consumer that switches to `kitConfig` and supplies nothing sees no behaviour change,
but the release is a major version. The ready-made resolver is `projectRootByMarkers`, built on
`findProjectRoot`; it does not canonicalise paths and falls back to the current directory when
no marker is found.

Every consumer inherits this behaviour, and no consumer currently has a way to override it.

## Context

`Baikai.Kit.Config.projectAgentsDir` is `getCurrentDirectory </> ".<tool>/agents"`. Every
project-scope path derives from it: `resolveAgentsBase ProjectScope`, and
`providerAgentsBase` for Claude and for Codex (the Codex project base is the bare
`getCurrentDirectory`). So does `Baikai.Kit.Session.agentDirsForSession`, which consumers
call to find the directories to mount into an interactive session.

"The project" therefore means whatever directory the command happened to be run from:

- `mori kit install foo --project`, run from `mori-cli/src`, writes to
  `mori-cli/src/.mori/agents/…`. A later `mori kit status` from the repository root does
  not see it, and `mori kit uninstall foo --project` from the root reports it as not
  installed.
- An interactive session started from a subdirectory (`mori agent …`, `rei agent …`,
  `okf assist`) finds no project-scope skills, even though they are installed at the
  repository root. It mounts no project kit, and nothing tells the user why.

The consuming tools already know where their project root is. `mori://shinzui/mori` has
`--path`-driven resolvers and a `mori.dhall` it locates, and okf has its configured bundle
roots. None of them can pass that knowledge to `baikai-kit`, because `KitConfig` holds only
`toolName`, `repoUrl`, and `providers`.

## Requested contract

1. `KitConfig` gains a way to resolve the project root, for example
   `projectRoot :: IO FilePath`, or a `Maybe` of it that falls back to the current
   behaviour.
2. Every project-scope path uses that root: `projectAgentsDir`, `resolveAgentsBase`,
   `providerAgentsBase` for every provider, the `status` scan, `uninstall`, and
   `agentDirsForSession`. Install, status, uninstall, and session discovery must never
   disagree about where the project scope is.
3. The engine offers a ready-made resolver that walks up from the current directory to the
   nearest directory containing a given marker (for example `.git`, or `.<tool>`), so a
   consumer with no root concept of its own gets sensible behaviour in one line.
4. A consumer that supplies nothing keeps today's current-directory behaviour, so the
   change is additive for existing callers.

## Acceptance

This request is complete when:

1. A test with a configured root installs an item at project scope from a nested
   subdirectory, then asserts that the files are under the root and that `status`,
   `uninstall`, and `agentDirsForSession` all find it from a different subdirectory.
2. A test of the provided marker-walking resolver covers a nested start directory, a
   directory that is itself the root, and the case where no marker exists before the
   filesystem root.
3. A test with no resolver configured shows that the existing current-directory behaviour
   is unchanged.
4. `docs/user/kit.md` says how project scope is located and how a tool configures it.

## Non-goals

This request does not change user scope (`~/.config/<tool>/agents`) or the cache directory,
and it does not ask the engine to understand any tool's project file format. Finding
`mori.dhall` or an okf bundle stays in the consumer, which passes the result in.

## References

- `mori://shinzui/baikai/packages/baikai-kit`: `Baikai.Kit.Config.projectAgentsDir`,
  `resolveAgentsBase`, `providerAgentsBase`, and `Baikai.Kit.Session.agentDirsForSession`
- `mori://shinzui/mori/packages/mori-cli`: `Mori.Command.Kit` and
  `Mori.Command.Agent`, which call `agentDirsForSession` from whatever directory the user
  is in
