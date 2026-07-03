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

`version` on each skill or agent is optional, so older manifests without
per-item versions still parse. `files` on an agent is also optional. If
it is absent, `path` is treated as the single source file. If it is
present, `path` is treated as a directory and each listed file is copied
from below it.

Skills are installed as directories for every provider. Agents are
installed as Claude Markdown files for Claude Code and as Codex custom
agent TOML for Codex.

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
kit update [NAME]
kit uninstall NAME [--project]
kit status
```

If your tool has custom UI around one command, keep your own parser and
call the lower-level functions:

```haskell
listAvailable myKitConfig
installItem myKitConfig "review" ProjectScope
updateKit myKitConfig Nothing
uninstallItem myKitConfig "review" ProjectScope
kitStatus myKitConfig
```

## Status And Sidecars

Each install writes a sidecar next to the provider-native asset. The
sidecar records the item name, kind, optional version, install time, and
a deterministic hash of the upstream kit files.

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
- `unknown`: the sidecar is missing or unreadable.

The current dirty check compares sidecar metadata with the cached
upstream item hash. It does not hash provider-installed target files.

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
HOME=/tmp/mytool-kit-smoke/home mytool kit uninstall review --project
```

After a project-scope install with both providers enabled, expect Claude
files under `.<tool>/agents/.claude/...` and Codex files under
`.agents/...` or `.codex/...`.
