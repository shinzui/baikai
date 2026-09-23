# Bundle Update Log

## 2026-09-23
* **Update**: Kit Packages builds `KitConfig` with `kitConfig`, documents the
  `projectRoot` field, and adds a Project Scope section: how the root is located
  (`projectRootByMarkers`, `findProjectRoot`, or the current directory by
  default), and that install, status, update, uninstall and session discovery
  all use it.

* **Update**: Kit Packages documents `kit status` conditions: they compose,
  `dirty` is renamed `changed-upstream`, `modified` and `edits-unknown` report
  local edits, and the two checks (upstream and local-edit) are described with
  the command that acts on each.

* **Update**: Kit Packages documents `kit install` without a name: the
  `chooseItem` field, what the chooser receives and returns, the cancel and
  missing-chooser behaviour, and that `kitCommandParser` now takes the
  configuration so its help names `.<tool>/agents`.

## 2026-09-08
* **Update**: Getting Started's package table lists `baikai-openai`'s native
  Responses API provider alongside Chat Completions and `codex exec`, and says
  the three are registered separately. The provider itself, its `Api` tag, the
  reasoning-continuation round trip and the `Options.speed` control were already
  documented in Models & Providers and Tools during development; this closes the
  one summary line that still described the package as Chat Completions only.

## 2026-08-28
* **Migration**: Adopt the shared user-documentation profile and assign stable document handles.
