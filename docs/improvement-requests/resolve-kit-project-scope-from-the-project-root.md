---
type: Improvement Request
title: Resolve kit project scope from the project root
description: >-
  Let KitConfig say how to find the project root, so project-scope installs and session
  discovery use the same directory no matter which subdirectory the tool was run from.
timestamp: 2026-09-23T13:49:07Z
requestId: IR-8
status: proposed
origin: mori://shinzui/mori
---

# Improvement Request: Resolve Kit Project Scope from the Project Root

## Status

Proposed. Every consumer inherits this behaviour, and no consumer currently has a way to
override it.

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
