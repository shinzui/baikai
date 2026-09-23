---
type: Improvement Request
title: Let kit install choose an item interactively
description: >-
  Make the NAME argument of `kit install` optional and give KitConfig a caller-supplied
  chooser, so a tool can offer an interactive picker without re-implementing the kit
  command type, parser, and install flow around baikai-kit.
timestamp: 2026-09-23T13:49:07Z
requestId: IR-6
status: proposed
origin: mori://shinzui/mori
---

# Improvement Request: Let Kit Install Choose an Item Interactively

## Status

Proposed. Nothing is blocked: every consumer can install by name today. The cost is
duplication. Of the three tools that ship a `kit` command on `baikai-kit`, only one uses the
engine's command surface unchanged, and the other two each keep a local copy of it.

## Context

`Baikai.Kit.Command` gives a consuming tool a complete `kit` subcommand: `KitCommand`,
`kitCommandParser`, and `runKit`. Its install verb is `KitInstall !Text !KitScope`, and
`installParser` makes `NAME` a required `strArgument`. There is no way to reach install
without already knowing an item's exact name, and no hook through which a caller can supply
one.

The three consumers that ship `kit` respond to that differently:

- `mori://shinzui/mori` (`mori-cli`, `Mori.Command.Kit`) re-exports `KitCommand` and
  `kitCommandParser` and calls `Kit.runKit moriKitConfig`, a module of about twenty lines.
  `mori kit install` therefore requires a name, even though `mori-cli` has its own fzf
  module (`Mori.Fzf`) that it uses for other commands.
- `mori://shinzui/rei` (`rei-cli`, `Rei.Cli.Commands.Kit.{Types,Parser,Handler,Config}`)
  re-implements the whole surface to make one change: `rei kit install` with no name opens
  an fzf picker over the manifest. It declares its own `KitCommand` and option records,
  its own parser (identical to the engine's apart from the optional name), and a handler
  that converts back to `Baikai.Kit.Command.KitCommand` for four of the five verbs. For
  the fifth it reproduces `runKitCommand`'s install path by hand: `ensureKitRepo`, the same
  cloned/pulled/stale messages, `loadManifest`, `installFrom`, and its own
  `renderKitError`-and-exit wrapper. It also has a parser test for the copy.
- `mori://shinzui/okf` (`okf-cli`, `Okf.Cli.Kit`) mirrors `KitCommand` and the parser
  verbatim so that it can derive `Eq`, which its top-level command type needs, and so that
  the `--project` help text names `.okf/agents`.

As a result, the engine's parser, its help strings, and its install messages exist in three
copies, and they drift apart independently. rei's `--project` help says `.rei/agents/`,
okf's says `.okf/agents`, and the engine's says only "project scope". When
`OverwritePolicy` replaced a boolean in the engine, each mirror had to be updated by hand.

Only the choice of item is tool-specific. Rendering a picker needs a terminal UI (fzf in
both tools that want one), and `baikai-kit` should not take a dependency on it. Everything
around that choice (refreshing the repository, loading the manifest, installing, reporting)
already lives in the engine.

## Requested contract

1. `KitInstall` accepts an optional name, and `installParser` makes `NAME` optional. Given
   a name, behaviour is unchanged.
2. `KitConfig` gains an optional chooser, for example
   `chooseItem :: Maybe (KitManifest -> IO (Maybe Text))`. With no name given,
   `runKitCommand` refreshes the repository and loads the manifest as it does today, then
   calls the chooser. `Just name` installs that item, and `Nothing` (the user cancelled)
   exits successfully without installing anything.
3. With no name and no chooser, the command fails with a `KitError` that says to pass a
   name. It must not fail with a parser error that hides the fact that interactive choice
   exists elsewhere.
4. The chooser receives the whole manifest, so a tool can show kinds, descriptions, and
   versions however it likes. The engine does not prescribe a display format.
5. `KitCommand` derives `Eq`, so a consumer can embed it in its own `Eq`-deriving command
   type without mirroring it.
6. Help text that names the project directory is derived from `toolName`
   (`.<tool>/agents`), so consumers no longer need a local parser to get accurate help.

Offering the same chooser to `uninstall` (over installed items) and to a single-item
`update` would be consistent with this request, but it is not required for acceptance.

## Acceptance

This request is complete when:

1. `kit install` with no name calls the configured chooser and installs the item it
   returns. A test drives this with a stub chooser and a local kit repository, and needs no
   fzf binary.
2. A cancelled choice installs nothing and exits 0, and the absence of a chooser produces a
   `KitError` naming the missing argument. Both are tested.
3. `KitCommand` derives `Eq`, and the parser's project-scope help names `.<tool>/agents`.
4. `mori://shinzui/rei` can delete `Rei.Cli.Commands.Kit.{Types,Parser,Handler}` and the
   parser test, keeping only its `KitConfig` with an fzf chooser, with no change to what
   `rei kit` does.
5. `mori://shinzui/okf` can delete its `KitCommand` mirror and the `toEngineCommand`
   translation.

## Non-goals

This request does not ask `baikai-kit` to depend on fzf or on any terminal UI library, to
ship a default picker, or to change how items are named, resolved, or installed once a name
is known. It does not cover filtering the manifest (by kind, or by installed state) before
it reaches the chooser. A chooser that wants that can filter the manifest it receives.

## References

- `mori://shinzui/baikai/packages/baikai-kit`: `Baikai.Kit.Command` (`KitCommand`,
  `kitCommandParser`, `runKitCommand`) and `Baikai.Kit.Config.KitConfig`
- `mori://shinzui/rei/packages/rei-cli`: `Rei.Cli.Commands.Kit.Handler.installWithPicker`
  and `pickItemName`, the behaviour this request moves into the engine
- `mori://shinzui/okf/packages/okf-cli`: `Okf.Cli.Kit`, the verbatim mirror kept for
  `Eq` and help text
- `mori://shinzui/mori/packages/mori-cli`: `Mori.Command.Kit`, the consumer that uses the
  engine directly and therefore has no picker
