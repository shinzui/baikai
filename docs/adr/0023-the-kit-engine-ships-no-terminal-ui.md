---
title: The kit engine ships no terminal UI; interactive choice is injected through KitConfig
status: accepted
date: 2026-09-23
---

# The kit engine ships no terminal UI; interactive choice is injected through KitConfig

## Context

`baikai-kit` gives a command-line tool a complete `kit` subcommand, but until
`baikai-kit 0.3.0.0` `kit install` required an exact item name. Two of the
three tools that ship it wanted `kit install` with no name to open an fzf
picker, and to get that they kept private copies of the engine's command
type, parser and install flow: `mori://shinzui/rei` in `rei-cli`'s
`Rei.Cli.Commands.Kit.{Types,Parser,Handler}`, and `mori://shinzui/okf` in
`okf-cli`'s `Okf.Cli.Kit`, which also mirrored the type to get `Eq` and help
text naming `.okf/agents`. Improvement request IR-6
(`mori://shinzui/baikai/okf/improvement-requests/concepts/IR-6`), raised
from `mori://shinzui/mori`, asked the engine to own that flow.

The obvious alternative — ship a default picker — would make every
consumer, including ones that never prompt, depend on a terminal-UI library
or an external binary, and would make the engine choose a presentation the
tools already disagree about.

## Decision

**`baikai-kit` never depends on fzf or any terminal-UI library and ships no
default picker.** An interactive step is a function field on `KitConfig`
that receives engine data and returns a plain value:
`chooseItem :: Maybe (KitManifest -> IO (Maybe Text))`. Everything around
the choice stays in the engine — refreshing the cache, loading the
manifest, validating and installing the returned name, reporting a
cancelled choice (`Nothing`) as a successful no-op, and failing with the
typed `KitItemNameRequired` when no chooser is configured. The choice never
exits the process ([ADR 0013](0013-library-code-never-calls-exitfailure.md)).

The command surface is built to be adopted rather than copied:
`KitCommand` derives `Eq`, and `kitCommandParser` takes the `KitConfig` so
help text names the tool's own directories.

## Consequences

Consumers own presentation and the engine owns the flow, so a tool's whole
kit integration is a `KitConfig` (built with `kitConfig`, plus `chooseItem`
if it prompts), `kitCommandParser config`, and `runKit config`; rei and okf
can delete their mirrors once they depend on `baikai-kit ^>=0.3`. The test
suite drives the choice with a stub function and needs no fzf binary.

A later interactive step — choosing what to uninstall, confirming an
overwrite — follows the same pattern: an optional function field defaulted
to `Nothing` in `kitConfig`, never a UI dependency in the engine.
