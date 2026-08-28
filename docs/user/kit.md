---
type: Guide
title: Kit Packages
description: Integrate the shared kit installer lifecycle for agent skills and subagents.
docId: DOC-5
tags: [kits, skills, agents, installation, lifecycle]
generated:
  by: human:nadeem
  at: 2026-08-27T20:05:09Z
---

# Kit Packages

`baikai-kit` is the shared installer for command-line tools that ship a
git-hosted kit of local AI-agent skills and subagents. It owns the
common lifecycle: clone or update the kit repository, read `kit.json`,
install provider-native files, write sidecar metadata, report status,
update installed items, uninstall them, and return the directories that
interactive sessions should mount.

Use `Baikai.AgentAssets` when you only need pure provider path rules.
Use `baikai-kit` when your application has a real `kit` command.

## Package Setup

Add the package alongside the core `baikai` package:

```cabal
build-depends:
  , baikai
  , baikai-kit
```

If you consume Baikai from git, include the `baikai-kit` subdirectory in
your `cabal.project` pin:

```cabal
source-repository-package
    type: git
    location: https://github.com/shinzui/baikai
    tag: <commit>
    subdir: baikai

source-repository-package
    type: git
    location: https://github.com/shinzui/baikai
    tag: <commit>
    subdir: baikai-kit
```

Applications that also use Claude or OpenAI providers will usually pin
`baikai-claude` and `baikai-openai` from the same commit.

## KitConfig

Every application supplies a small `KitConfig`:

```haskell
import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Kit

myKitConfig :: KitConfig
myKitConfig =
  KitConfig
    { toolName = "mytool"
    , repoUrl = "https://github.com/example/mytool-kit.git"
    , providers = [InteractiveClaude, InteractiveCodex]
    }
```

`toolName` controls the cache, agent base directories, and sidecar file:

```text
~/.cache/mytool/kit
~/.config/mytool/agents
<cwd>/.mytool/agents
.mytool-kit.json
```

Claude Code assets install below the tool's agent base so the launcher
can mount that directory with `--add-dir`. Codex assets install into
Codex-native discovery roots: `$HOME/.agents`, `$HOME/.codex`, `.agents`,
and `.codex`.

## Manifest

The kit repository must contain `kit.json` at its root:

```json
{
  "version": 1,
  "skills": [
    {
      "name": "review",
      "description": "Review a change",
      "version": "0.1.0",
      "path": "skills/review",
      "files": ["SKILL.md"]
    }
  ],
  "agents": [
    {
      "name": "planner",
      "description": "Plan implementation work",
      "version": "0.1.0",
      "path": "agents/planner.md"
    }
  ]
}
```

The top-level `version` must be `1` or `2`; the two decode identically,
and any other value is refused with a message naming the file and the
version it declared, rather than being installed under guesswork.

`version` on each skill or agent is optional, so older manifests without
per-item versions still parse. `files` on an agent is also optional. If
it is absent, `path` is treated as the single source file. If it is
present, `path` is treated as a directory and each listed file is copied
from below it.

Skills are installed as directories for every provider. Agents are
installed as Claude Markdown files for Claude Code and as Codex custom
agent TOML for Codex. When an agent lists several `files`, the first is
the agent body and becomes the provider's agent file; the rest are
installed into a resource directory named after the agent beside it —
`<agents dir>/<name>/<file>` — because both providers' agent directories
are flat and a second Markdown file placed there directly would be
discovered as a bogus agent. Uninstalling the agent removes that
directory too.

**A kit must contain plain files.** The manifest is untrusted input: a
user points the tool at an arbitrary git URL, and `git` recreates
committed symbolic links on checkout. A source path is therefore refused
if any component below the kit checkout is a symbolic link, or if it
resolves outside the checkout — at install, when the content hash is
computed, and when `kit status` compares against the upstream. The
refusal is by design and applies to links pointing inside the checkout as
well; a link never adds anything a plain file could not, because copying
files is all the installer does with a source. The check is
check-then-read: a process that can write to `~/.cache/<tool>/kit` between
the check and the read could still swap a file for a link. That directory
is owned by the invoking user and written only by `git`, which runs before
the check in the same command.

## Command Adapter

For the standard CLI shape, delegate parsing and dispatch to
`Baikai.Kit.Command`:

```haskell
import Baikai.Kit qualified as Kit
import Options.Applicative

main :: IO ()
main = do
  command <- execParser (info (Kit.kitCommandParser <**> helper) mempty)
  Kit.runKit myKitConfig command
```

The built-in parser supports:

```text
kit list
kit install NAME [--project]
kit update [NAME] [--force]
kit uninstall NAME [--project]
kit status
```

`kit update` reinstalls every item that is already installed. It skips an
item whose installed files were edited locally since they were installed,
printing

```text
Skipped 'review' (user): installed files were modified locally; run 'kit update review --force' to overwrite.
```

A skip is not a failure: the command still exits 0. `--force` reinstalls
anyway and discards those edits.

If your tool has custom UI around one command, keep your own parser and
call the lower-level functions. Every one of them returns
`Either KitError a` and prints nothing:

```haskell
result <- installItem myKitConfig "review" ProjectScope
case result of
  Left err -> Text.IO.hPutStrLn stderr (renderKitError err)
  Right item -> Text.IO.putStrLn ("installed " <> itemName item)
```

`runKit` prints `Error: <rendered>` to stderr and exits 1 on any failure;
`runKitCommand` has the same signature but returns the `KitError`, so a
tool that wants its own exit codes can map it. `KitError` also has an
`Exception` instance, so a caller that prefers exceptions can write
`either throwIO pure`. No function in `baikai-kit` other than `runKit`
exits the process — see
[ADR 0013](../adr/0013-library-code-never-calls-exitfailure.md).

## Offline Behaviour

`kit status` needs no network. With no cache and no way to fetch one it
prints a note on stderr, prints `No kit items installed.` (or whatever is
installed) and exits 0. `kit list` and `kit install` need the manifest and
fail without a cache; with a cache they cannot refresh, they warn and
continue from it. `kit update` treats a failed fetch as an error, because
fetching is the one thing it exists to do.

## Status And Sidecars

Each install writes a sidecar next to the provider-native asset. The
sidecar records the item name, kind, optional version, install time, a
deterministic hash of the upstream kit files, and — since `baikai-kit`
0.2 — `installedFiles` and `installedHash`: the names this tool wrote for
that provider, relative to the provider's target directory, and the hash
of exactly those bytes. Those two fields are what `kit update` compares
against to notice a local edit; a sidecar written by an older release has
neither and is updated without the check.

`kitStatus` scans user and project scopes and prints rows grouped by
item, kind, scope, version, state, and provider coverage:

```text
NAME    TYPE   SCOPE    PROVIDERS     INSTALLED  LATEST  STATE
review  skill  project  claude,codex  0.1.0      0.1.0   up-to-date
```

States are:

- `up-to-date`: the installed sidecar matches the current manifest item.
- `outdated`: the sidecar version differs from the current manifest
  version.
- `dirty`: the cached upstream file hash differs from the sidecar hash.
- `dirty+outdated`: both the version and cached upstream file hash differ.
- `delisted`: the sidecar is valid, but the item is no longer present in
  the current manifest.
- `refused`: the cached upstream item now lists a source the installer
  refuses — a symbolic link, or a path outside the kit. Fix the kit before
  updating.
- `unknown`: the sidecar is missing or unreadable.

The dirty check compares sidecar metadata with the cached upstream item
hash. It does not hash provider-installed target files; the check that
does is the local-edit check `kit update` runs, described above.

A crash between the two write phases can leave `*.baikai-kit-tmp` or
`*.baikai-kit-bak` files in a target directory. They are harmless to both
providers and to the status scan, a later install does not remove them,
and they are safe to delete by hand.

## Session Discovery

Interactive launch code can use the same config to find mounted
directories:

```haskell
import Baikai.Kit qualified as Kit

launch :: IO ()
launch = do
  extraDirs <- Kit.agentDirsForSession myKitConfig
  -- pass extraDirs to launchClaudeInteractive or launchCodexInteractive
  pure ()
```

`agentDirsForSession` returns only existing directories from:

```text
~/.config/<tool>/agents
<cwd>/.<tool>/agents
```

Those directories are useful for Claude Code because its provider-native
layout lives under the tool agent base. Codex also receives the extra
dirs when your launcher passes them through, but Codex skills and custom
agents are installed into Codex-native discovery paths.

## Smoke Checks

Use an isolated `HOME` and throwaway project directory when testing a
new adapter:

```bash
mkdir -p /tmp/mytool-kit-smoke/home /tmp/mytool-kit-smoke/work
cd /tmp/mytool-kit-smoke/work

HOME=/tmp/mytool-kit-smoke/home mytool kit list
HOME=/tmp/mytool-kit-smoke/home mytool kit install review --project
HOME=/tmp/mytool-kit-smoke/home mytool kit status
HOME=/tmp/mytool-kit-smoke/home mytool kit update review
HOME=/tmp/mytool-kit-smoke/home mytool kit update review --force
HOME=/tmp/mytool-kit-smoke/home mytool kit uninstall review --project
```

After a project-scope install with both providers enabled, expect Claude
files under `.<tool>/agents/.claude/...` and Codex files under
`.agents/...` or `.codex/...`.
