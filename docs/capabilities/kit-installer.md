---
title: "Kit installer for agent skills and subagents"
type: Capability
description: "Give a command-line tool a real `kit` command: clone or update a git-hosted kit repository, read its manifest, install skills and subagents in each provider's native layout with sidecar metadata, report per-item status, and uninstall — with path handling hardened against traversal and writes rolled back on partial failure."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
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
  - Baikai.Kit.Install
  - Baikai.Kit.Manifest
  - Baikai.Kit.Status
  - Baikai.Kit.Repo
  - Baikai.Kit.Session
requires:
  - CAP-22
evidence:
  - kind: test
    resource: baikai-kit/test/Main.hs
    proves: "The whole lifecycle plus its path safety: manifest decoding, an order-independent content hash that changes when content changes, the six-way status derivation (unknown, delisted, outdated, dirty, dirty+outdated, up-to-date), a skill and an agent round-tripping through both Claude and Codex layouts with sidecars, CRLF frontmatter stripping for Codex TOML, a failed provider write rolling back every staged write, uninstall reporting actual assets versus stale metadata, a failed pull exiting non-zero — and, separately, that safeRelativePath rejects zip-slip, absolute paths, backslashes, and NUL, safeItemName rejects multi-component and hidden names, install refuses a manifest path escaping the install root, and uninstall refuses a traversal name."
  - kind: guide
    resource: docs/user/kit.md
    proves: "The adoption path: KitConfig, the kit.json manifest, wiring the command, and what each subcommand does."
---

# Kit installer for agent skills and subagents

A tool that ships its own AI-agent skills and subagents needs the same six things
every time: clone or update a git-hosted kit, read `kit.json`, install
provider-native files, track what it installed, report drift, and remove it
again. `baikai-kit` is that lifecycle, factored out so each tool supplies only a
`KitConfig` — its name, its kit repository URL, and which providers it targets.

Installation is provider-native. A skill and a custom agent land where Claude
Code and Codex actually discover them, in the format each expects, with a sidecar
file recording the installed version and content hash. That sidecar is what makes
`status` meaningful: an item can be up-to-date, outdated, locally modified
(`dirty`), both, delisted upstream, or unknown, and the six-way derivation is
pinned by tests rather than inferred at a glance.

The installer treats the manifest as untrusted input. Every path is normalised
and checked before use — zip-slip, absolute paths, backslashes, NUL bytes, hidden
and multi-component item names are all rejected — and a write that fails partway
rolls back every staged write rather than leaving half a kit on disk.

This builds on [CAP-22 — provider-native agent-asset layouts](agent-asset-layouts.md),
which supplies the pure path rules the installer writes against. A tool that only
needs those rules should depend on `baikai` alone.

## Shape

```haskell
import Baikai.Kit

myKitConfig :: KitConfig
myKitConfig = KitConfig
  { toolName  = "mytool"
  , repoUrl   = "https://github.com/example/mytool-kit.git"
  , providers = [InteractiveClaude, InteractiveCodex]
  }
```

## Limits

- **Git-hosted kits only.** The repository is fetched with `git`, which must be
  on `PATH`; there is no archive, registry, or local-directory source.
- Only Claude Code and Codex layouts are supported, because those are the layouts
  `Baikai.AgentAssets` describes.
- The content hash detects local modification, but there is no merge or conflict
  resolution: a `dirty` item is reported, not reconciled.
- The package depends on `baikai` for the interactive provider vocabulary even
  though it makes no model calls.
- `baikai-kit 0.1.0.0` was never released — the version was bumped to `0.1.0.1`
  in the first release sweep that included the package — so `0.1.0.1` is the
  earliest version a consumer can actually depend on.
- Still `0.1.0.x` and marked `experimental`; the release history so far is
  dependency-bound widening plus one hardening pass.
