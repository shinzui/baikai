---
title: "Kit installer for agent skills and subagents"
type: Capability
description: "Give a command-line tool a real `kit` command: clone or update a git-hosted kit repository, read its manifest, install skills and subagents in each provider's native layout with sidecar metadata, report per-item status including local edits, print it as versioned JSON, and uninstall — refusing symbolic links and escaping paths in the untrusted manifest, returning every failure as a typed `KitError` rather than exiting, and restoring what was there when a write fails partway."
generated:
  by: claude-code/opus-5
  at: "2026-09-23T17:00:00Z"
capabilityId: CAP-21
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.1.0.1"
packages:
  - baikai-kit
interface:
  - Baikai.Kit
  - Baikai.Kit.Command
  - Baikai.Kit.Config
  - Baikai.Kit.Error
  - Baikai.Kit.Install
  - Baikai.Kit.Json
  - Baikai.Kit.Manifest
  - Baikai.Kit.Path
  - Baikai.Kit.Repo
  - Baikai.Kit.Session
  - Baikai.Kit.Sidecar
  - Baikai.Kit.Status
requires:
  - CAP-22
evidence:
  - kind: test
    resource: baikai-kit/test/Main.hs
    proves: "The whole lifecycle, its path safety and its failure shapes: manifest decoding, an order-independent content hash that changes when content changes, the status derivation as composable conditions including refused, a skill and an agent round-tripping through both Claude and Codex layouts with sidecars, CRLF frontmatter normalised on every branch, uninstall reporting actual assets versus stale metadata. Path safety: safeRelativePath rejects zip-slip, absolute paths, backslashes and NUL, safeItemName rejects multi-component and hidden names, install refuses a manifest path escaping the install root, uninstall refuses a traversal name, and a kit checkout containing a symbolic link has that source refused by install (which writes nothing), by the content hash, and by status. Typed failures: loadManifest returns missing and invalid manifests as values, installItem returns KitItemNotFound, kit status offline on a fresh HOME exits 0 while reporting the unavailable upstream, and runKit still exits 1 on an unsafe install or uninstall. Install fidelity: a multi-file agent installs every listed file for both providers and uninstall removes its resource directory, a failure in the rename phase restores the previous files and leaves no temporary or backup residue, a destination that is a directory is refused before any write, an unsupported manifest version is refused, a sidecar written before the installed-file fields still decodes, and update skips a locally modified item unless forced. Project scope: findProjectRoot walks up from a nested directory, accepts a start that is the root, and returns Nothing without a marker; with a configured projectRoot an install from a nested subdirectory is found by status, session discovery, and uninstall from a sibling one, the same holds with projectRootByMarkers, and without a resolver project scope stays the current directory. Local edits: an installed item reports no conditions until one of its files is edited and then reports modified for that provider only, a legacy sidecar reports edits-unknown, modified composes with outdated and changed-upstream, and the set kit status reports as modified equals the set kit update skips. Command surface: kit install parses with and without a name, KitCommand compares with ==, install help names the tool's project directory, a stub chooser sees the whole manifest and its pick is installed, a cancelled choice installs nothing and exits 0, and no chooser is KitItemNameRequired. JSON: the kit-list, kit-status and kit-update documents match goldens over a fixture covering every condition, both scopes, both providers and both kinds; the command emits the same status document as the encoder; --json stdout is exactly one document under a stale cache and an unreachable repository, is empty when list cannot clone or update cannot pull, and keeps the first-clone notice off stdout."
  - kind: guide
    resource: docs/user/kit.md
    proves: "The adoption path: KitConfig and kitConfig, how project scope is located, the kit.json manifest, wiring the command, choosing an item interactively, the status conditions and which command acts on each, the three JSON documents with their format-version rule, and what each subcommand does."
---

# Kit installer for agent skills and subagents

A tool that ships its own AI-agent skills and subagents needs the same six things
every time: clone or update a git-hosted kit, read `kit.json`, install
provider-native files, track what it installed, report drift, and remove it
again. `baikai-kit` is that lifecycle, factored out so each tool supplies only a
`KitConfig` — its name, its kit repository URL, which providers it targets, and
optionally how to find its project root and how to let the user choose an item.
Every project-scope path derives from that one root, so install, status, update,
uninstall, and session discovery agree whichever subdirectory a command runs
from. `kit install` without a name hands the manifest to a chooser the tool
supplies — an fzf picker, say — and installs what it returns; the engine itself
ships no terminal UI.

Installation is provider-native. A skill and a custom agent land where Claude
Code and Codex actually discover them, in the format each expects, with a sidecar
file recording the installed version, the upstream content hash, and the files
this tool wrote for that provider with their hash. That sidecar is what makes
`status` meaningful — an item can be up to date, outdated, changed upstream
without a version bump (`changed-upstream`), edited locally (`modified`), too old
to check for edits (`edits-unknown`), delisted, refused, or unknown, and these
compose (`outdated+changed-upstream+modified`), with the derivation pinned by
tests rather than inferred at a glance. The local-edit check is the same one
`update` runs to notice a file the user edited by hand and skip it rather than
overwrite it, so the two commands cannot disagree about what was edited.
`kit list`, `kit status` and `kit update` also print that information as one
versioned JSON document with `--json`, written by explicit encoders and pinned
by golden tests, with every warning kept off stdout.

The installer treats the manifest as untrusted input, and checks it both
lexically and physically. Lexically: zip-slip, absolute paths, backslashes, NUL
bytes, hidden and multi-component item names are rejected. Physically: a source
whose path crosses a symbolic link, or whose canonical form lies outside the kit
checkout, is refused at install, at the content hash and at status — because
`git` recreates committed symbolic links and a kit is meant to be plain files.
The physical check is check-then-read, so a process that can write to the cache
between the check and the read remains a residual limit, stated below.

Nothing in the package exits the process except `runKit`, the command adapter
that is documented to be a subcommand. Every other function returns
`Either KitError a`, so a tool embedding the library can render the failure and
choose its own exit code
([ADR 0013](../adr/0013-library-code-never-calls-exitfailure.md)). A write that
fails partway restores what was there before, or names the paths it could not
restore.

This builds on [CAP-22 — provider-native agent-asset layouts](agent-asset-layouts.md),
which supplies the pure path rules the installer writes against. A tool that only
needs those rules should depend on `baikai` alone.

## Shape

```haskell
import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Kit

myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { projectRoot = projectRootByMarkers [".git", ".mytool"]
    }
```

## Limits

- **Git-hosted kits only.** The repository is fetched with `git`, which must be
  on `PATH`; there is no archive, registry, or local-directory source.
- Only Claude Code and Codex layouts are supported, because those are the layouts
  `Baikai.AgentAssets` describes.
- The content hash detects drift and local modification, but there is no merge or
  conflict resolution: a `changed-upstream` item is reported and reinstalled by
  `update`, and a `modified` one is reported and skipped by `update` until
  `--force`, not reconciled. There is no diff or restore command.
- **The symbolic-link check is check-then-read.** A process with write access to
  `~/.cache/<tool>/kit` could swap a plain file for a link between the check and
  the read. That directory is owned by the invoking user and written only by
  `git`, which runs earlier in the same command, so the residual threat is a
  local process already running as the user.
- `readSidecar` still prints a warning to stderr when a sidecar does not parse,
  the one place the library writes to a stream of its own accord; it returns
  `Nothing` and the item shows as `unknown`.
- Two concurrent installs of the same item still race on the final rename. Each
  rename installs a complete file, so no half-written file is ever visible, but
  which of the two wins is not defined.
- The package depends on `baikai` for the interactive provider vocabulary even
  though it makes no model calls.
- `baikai-kit 0.1.0.0` was never released — the version was bumped to `0.1.0.1`
  in the first release sweep that included the package — so `0.1.0.1` is the
  earliest version a consumer can actually depend on.
- Still marked `experimental`. The surface changed shape again in 0.3.0.0:
  `KitConfig` gained the `projectRoot` and `chooseItem` fields and is built with
  `kitConfig`, `KitCommand`'s constructors changed (`KitInstall` takes
  `Maybe Text`; `KitList`, `KitStatus` and `KitUpdate` take an `OutputFormat`),
  `kitCommandParser` takes the `KitConfig`, and `KitCondition` lists replaced
  `KitState`. A consumer raising its bound fixes each at a call site the compiler
  names. The JSON documents are the one part with an explicit compatibility
  rule, their `formatVersion`.
