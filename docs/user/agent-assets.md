# Agent Assets

`Baikai.AgentAssets` describes provider-native locations for local
agent assets such as skills and custom agents. It is intentionally pure:
it computes layout metadata and paths, but it does not clone kit
repositories, copy files, scan installations, repair updates, or remove
content.

Use this module when your application already owns asset lifecycle and
only needs provider path rules. Use [Kit Packages](kit.md) when you want
the shared `kit` command implementation: repository clone/update,
manifest parsing, install/update/uninstall, status, sidecars, and
session directory discovery.

## Layout Helpers

`skillTargetPath` and `agentTargetPath` accept an
`InteractiveProvider`, an `InteractiveScope`, and an item name:

```haskell
import Baikai.AgentAssets
import Baikai.Interactive

skillTargetPath InteractiveClaude InteractiveProjectScope "example"
-- ".claude/skills/example"

agentTargetPath InteractiveClaude InteractiveProjectScope "example"
-- ".claude/agents/example.md"

skillTargetPath InteractiveCodex InteractiveProjectScope "example"
-- ".agents/skills/example"

agentTargetPath InteractiveCodex InteractiveProjectScope "example"
-- ".codex/agents/example.toml"
```

User-scope paths use a literal `$HOME` prefix so callers can decide how
to resolve or display the home directory:

```haskell
skillTargetPath InteractiveCodex InteractiveUserScope "example"
-- "$HOME/.agents/skills/example"

agentTargetPath InteractiveCodex InteractiveUserScope "example"
-- "$HOME/.codex/agents/example.toml"
```

`skillAsset` and `customAgentAsset` return an `AgentAssetLayout` with the
provider, scope, kind, format, and final path. Skills are directory
assets for both providers. Claude Code custom agents are Markdown files.
Codex custom agents are TOML files.

## Codex Custom Agents

`codexCustomAgentToml` renders the small TOML file shape Codex custom
agents expect:

```haskell
codexCustomAgentToml
  CodexCustomAgent
    { name = "reviewer"
    , description = "Reviews changes"
    , developerInstructions = "Read the diff before commenting."
    }
```

The renderer escapes TOML basic strings for `name` and `description`,
and places instructions in a multiline TOML string. Consumers that have
their own richer manifest model can still use Baikai only for target
path and format metadata.

## Verification Boundary

Debug or dry-run agent launches are useful for proving that an
application selected a provider and rendered a prompt. They do not prove
that Claude Code or Codex loaded a skill or custom agent. To verify
provider asset loading, run a real non-debug provider session from a
working directory that contains the target layout, or use a provider
command that enumerates loaded assets.
