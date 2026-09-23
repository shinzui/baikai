---
type: Guide
title: Kit Packages
description: Integrate the shared kit installer lifecycle for agent skills and subagents.
docId: DOC-5
tags: [kits, skills, agents, installation, lifecycle]
generated:
  by: human:nadeem
  at: 2026-09-23T17:00:00Z
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

Every application supplies a small `KitConfig`. Build it with
`kitConfig`, which takes the three required values and sets every optional
field to its default, then override what you need with record update
syntax:

```haskell
import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Kit

myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { projectRoot = projectRootByMarkers [".git", ".mytool"]
    }
```

A record literal (`KitConfig { … }`) still compiles, but it must set every
field, including ones later releases add; `kitConfig` does not.

`toolName` controls the cache, agent base directories, and sidecar file:

```text
~/.cache/mytool/kit
~/.config/mytool/agents
<project root>/.mytool/agents
.mytool-kit.json
```

`projectRoot` is an `IO FilePath` action that returns the directory project
scope lives under; see Project Scope below.

Claude Code assets install below the tool's agent base so the launcher
can mount that directory with `--add-dir`. Codex assets install into
Codex-native discovery roots: `$HOME/.agents`, `$HOME/.codex`, `.agents`,
and `.codex`.

## Project Scope

`--project` installs into the project rather than the user's home. Which
directory is "the project" is the tool's `projectRoot`. With `kitConfig`'s
default it is the current directory, exactly as in earlier releases. Most
tools want the repository root instead, so that `mytool kit install review
--project` run from `src/` and `mytool kit status` run from the root see
the same item; one line configures that:

```haskell
myKitConfig = (kitConfig "mytool" url providers) {projectRoot = projectRootByMarkers [".git", ".mytool"]}
```

`projectRootByMarkers markers` walks up from the current directory to the
nearest directory containing any of `markers` (a file or a directory) and
falls back to the current directory when none does, so the tool still
works outside a project. It does not resolve symbolic links. The walk
itself is exported as `findProjectRoot markers start`, which returns
`Nothing` when no marker is found, for a tool that wants its own fallback.
A tool with its own notion of a root can supply any `IO FilePath`; an
exception it throws propagates to the caller.

Every project-scope operation uses that one root: install, status, update,
uninstall, and `agentDirsForSession`. Claude Code files go under
`<project root>/.<tool>/agents/.claude`, and Codex files under
`<project root>/.agents` and `<project root>/.codex`.

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
  command <- execParser (info (Kit.kitCommandParser myKitConfig <**> helper) mempty)
  Kit.runKit myKitConfig command
```

The built-in parser supports:

```text
kit list [--json]
kit install [NAME] [--project]
kit update [NAME] [--force] [--json]
kit uninstall NAME [--project]
kit status [--json]
```

`kit update` reinstalls every item that is already installed. It skips an
item whose installed files were edited locally since they were installed,
printing

```text
Skipped 'review' (user): installed files were modified locally; run 'kit update review --force' to overwrite.
```

A skip is not a failure: the command still exits 0. `--force` reinstalls
anyway and discards those edits.

`kitCommandParser` takes the configuration so its help text can name the
tool's own directory: `mytool kit install --help` describes `--project` as
installing under `.mytool/agents`. `KitCommand` derives `Eq`, so a tool
can test its parsing by comparing parsed commands.

### Choosing an item interactively

`kit install` with no `NAME` asks the tool to choose. A tool opts in by
setting `chooseItem`, a function that receives the whole loaded manifest
(every skill and agent, with names, descriptions and versions) and returns
the chosen name, or `Nothing` when the user cancelled:

```haskell
myKitConfig :: KitConfig
myKitConfig =
  (kitConfig "mytool" "https://github.com/example/mytool-kit.git" [InteractiveClaude, InteractiveCodex])
    { chooseItem = Just pickWithFzf
    }

-- Owned by the tool: render the manifest however it likes and return the
-- chosen name, or Nothing when the user cancels.
pickWithFzf :: KitManifest -> IO (Maybe Text)
```

The engine refreshes the kit, loads the manifest, calls the chooser, and
installs the result exactly as if it had been typed; a name the manifest
does not list fails with the usual `'<name>' not found in kit manifest.`
A cancelled choice prints `No item chosen; nothing installed.` and exits 0.
An exception the chooser throws propagates.

Without a chooser (`kitConfig`'s default), `kit install` with no name
fails before touching the network with the `KitItemNameRequired` error:

```text
Error: no item name given: pass NAME to 'kit install' (run 'kit list' to see what is available).
```

`baikai-kit` ships no picker and depends on no terminal-UI library; the
tool owns presentation, and the engine owns everything around the choice.

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

## Machine-Readable Output

`kit list`, `kit status`, and `kit update` accept `--json`. With it, a
successful command prints exactly one JSON document on stdout, followed by
a newline, and nothing else; a failed command prints nothing on stdout,
prints `Error: …` on stderr, and exits 1. So "exit 0" means "stdout is one
complete document". Warnings — a stale cache, an unreachable repository,
the `Fetched <tool>-kit.` notice after a first clone — go to stderr, and
the document itself records whether the upstream was consulted. The
document is written as UTF-8 whatever the locale.

```bash
mytool kit status --json | jq '.items[] | select(.conditions | index("modified")) | .name'
```

Every document carries two keys that never change meaning:
`formatVersion`, an integer (`1` in this release), and `document`, which
names the shape (`kit-list`, `kit-status`, or `kit-update`). Adding a key
keeps the format version; removing or renaming a key, or changing what a
value means, increments it. Every key below is always present; a value
that does not exist is `null`, never an omitted key. Key order is not
part of the contract.

`kit list --json`:

```json
{
  "formatVersion": 1,
  "document": "kit-list",
  "upstream": {"state": "ready", "detail": null},
  "items": [
    {
      "name": "review",
      "kind": "skill",
      "description": "Review a change",
      "version": "0.1.0",
      "installed": [
        {"scope": "user", "provider": "claude", "version": "0.1.0", "path": "/home/me/.config/mytool/agents/.claude/skills/review"},
        {"scope": "user", "provider": "codex", "version": "0.1.0", "path": "/home/me/.agents/skills/review"}
      ]
    }
  ]
}
```

- `upstream.state` is `ready` (the cache was cloned or refreshed), `stale`
  (the refresh failed and the cached copy was used), or `unavailable`;
  `upstream.detail` is `null` when ready, and otherwise git's or the
  engine's message.
- `items` lists what the kit offers: the manifest's skills in manifest
  order, then its agents. An installed item the manifest no longer lists
  is not here; `kit status` reports it as `delisted`.
- `kind` is `skill` or `agent`; `version` is the manifest version or
  `null`.
- `installed` holds one entry per installed copy — `scope` (`user` or
  `project`), `provider` (`claude` or `codex`), the installed `version`
  from its sidecar (`null` without a readable one), and the `path` of the
  skill directory or agent file — sorted user before project, then by
  provider. It is `[]` when the item is not installed.

`kit status --json`:

```json
{
  "formatVersion": 1,
  "document": "kit-status",
  "upstream": {"state": "stale", "detail": "fatal: unable to access …"},
  "items": [
    {
      "name": "review",
      "kind": "skill",
      "scope": "project",
      "provider": "claude",
      "installedVersion": "0.1.0",
      "latestVersion": "0.2.0",
      "conditions": ["outdated", "modified"],
      "upToDate": false
    }
  ]
}
```

- `items` has one entry per installed copy — item, scope, and provider —
  never merged across providers the way the table merges them, sorted by
  name, kind, scope, and provider.
- `installedVersion` comes from the sidecar and `latestVersion` from the
  manifest; either may be `null`.
- `conditions` uses the labels in Status And Sidecars — `unknown`,
  `delisted`, `refused`, `outdated`, `changed-upstream`, `modified`,
  `edits-unknown` — in that order, and `upToDate` is `true` exactly when
  the list is empty.

`kit update --json`:

```json
{
  "formatVersion": 1,
  "document": "kit-update",
  "refresh": "pulled",
  "updated": [{"name": "planner", "scope": "user"}],
  "skipped": [{"name": "review", "scope": "user", "reason": "locally-modified"}]
}
```

- `refresh` is `cloned`, `pulled`, `stale`, or `null` when no refresh was
  attempted (the library's `reinstallPresent`).
- `updated` and `skipped` are in the order the update ran. `reason` is
  `locally-modified`, the only reason an item is skipped today; a new
  reason would be a new value, not a new key.

Library callers get the identical values without running the command:
`listDocument`, `statusDocument`, and `updateDocument` in
`Baikai.Kit.Json` return an aeson `Value`, and `kitJsonFormatVersion` is
the format version. `installedCopies` in `Baikai.Kit.Status` returns the
install locations the list document reports. The shapes are pinned by the
golden files in `baikai-kit/test/golden/`.

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
item, kind, scope, version, conditions, and provider coverage:

```text
NAME    TYPE   SCOPE    PROVIDERS  INSTALLED  LATEST  STATE
review  skill  project  codex      0.1.0      0.2.0   outdated
review  skill  project  claude     0.1.0      0.2.0   outdated+modified
```

Each row carries a list of conditions. A row with none reads
`up-to-date`; otherwise the `STATE` column joins them with `+`, always in
the order below, so a skill with a newer version upstream, changed
sources, and a hand-edited copy reads `outdated+changed-upstream+modified`.
The conditions are:

- `unknown`: the sidecar is missing or unreadable, so nothing can be
  compared.
- `delisted`: the sidecar is valid, but the item is no longer present in
  the current manifest.
- `refused`: the cached upstream item now lists a source the installer
  refuses — a symbolic link, or a path outside the kit. Fix the kit before
  updating.
- `outdated`: the sidecar version differs from the current manifest
  version.
- `changed-upstream`: the kit's sources for the item changed since it was
  installed, without a version change. (Before `baikai-kit` 0.3 this was
  called `dirty`.)
- `modified`: files this tool installed were edited, or removed, since
  they were installed.
- `edits-unknown`: the sidecar was written by a release older than 0.2,
  which recorded no installed-file hash, so local edits cannot be
  detected. Reinstalling the item records one.

Two separate checks produce these. The upstream check compares the
sidecar's upstream hash and version with the cached kit checkout; it
yields `outdated` and `changed-upstream`, and `kit update` acts on it by
reinstalling. The local-edit check hashes the installed files and compares
them with the sidecar's `installedHash`; it yields `modified` and
`edits-unknown`, and it is the very check `kit update` uses to skip an
item unless `--force` — so whatever `kit update` would skip, `kit status`
has already reported as `modified`. Both checks read only local files, so
`kit status` still needs no network.

Library callers get the conditions as `StatusRow.conditions ::
[KitCondition]`, spelled by `conditionLabel` and joined by
`renderConditions`. The local-edit check is exported on its own as
`checkLocalEdits`, returning `Unedited`, `Edited`, or `EditsUnknown` for
one provider's copy.

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
<project root>/.<tool>/agents
```

The project directory comes from the same `projectRoot` the installer
uses, so a session started from a subdirectory mounts the skills a
project-scope install put at the root.

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
