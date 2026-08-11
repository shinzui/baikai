---
title: "Provider-native agent-asset layouts"
type: Capability
description: "Ask where Claude Code or Codex discovers a skill or a custom agent, at project or user scope, and get the answer as pure path rules plus the provider-native file format — including Codex's TOML rendering — with no filesystem access and no opinion about who writes the files."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-22
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
interface:
  - Baikai.AgentAssets
evidence:
  - kind: test
    resource: baikai/test/AgentAssetsSpec.hs
    proves: "The concrete path rules for both providers at both scopes — Claude Code project and user paths, and Codex's split of .agents for skills and .codex for agents plus its home discovery roots — that skills are directory assets while custom agents use provider-native file formats, that a layout carries provider, scope, kind, format, and path together, and that Codex custom-agent TOML escapes strings while preserving instructions."
  - kind: guide
    resource: docs/user/agent-assets.md
    proves: "What the module answers, what it deliberately leaves to the caller, and how the layout values are meant to be consumed."
  - kind: module
    resource: baikai/src/Baikai/AgentAssets.hs
    proves: "The whole surface: skillAsset, customAgentAsset, agentAssetLayout, skillTargetPath, agentTargetPath, agentAssetFormat, and codexCustomAgentToml."
---

# Provider-native agent-asset layouts

Claude Code and Codex each discover local skills and custom agents from their own
directories, in their own formats, differently at project scope and user scope.
`Baikai.AgentAssets` encodes those rules as pure functions: give it a provider, a
scope, and an asset, and it returns an `AgentAssetLayout` carrying the target
path, the asset kind, and the provider-native format. `codexCustomAgentToml`
additionally renders a Codex custom agent, escaping strings while leaving
instruction text intact.

The module is deliberately inert. It performs no filesystem access and expresses
no opinion about cloning, copying, updating, status, or uninstalling — those
belong to the caller, or to [CAP-21 — the kit installer](kit-installer.md), which
is built on exactly these rules. A tool that just needs to know *where a file
goes* takes this and nothing else.

It shares its provider and scope vocabulary with
[CAP-16 — interactive agent-session launches](interactive-launches.md), so a tool
that launches sessions and installs assets uses one set of names for both.

## Shape

```haskell
import Baikai.AgentAssets

layout = agentAssetLayout InteractiveClaude ProjectScope (skillAsset "reviewer")
-- layout ^. #path is where Claude Code will look for it
```

## Limits

- **Pure rules, nothing else.** No file is read, written, or checked for
  existence. A path this module returns is where an asset *should* go, not
  evidence that anything is there.
- Only Claude Code and Codex are described. A third agent tool needs its own
  rules; there is no extension point.
- The rules encode those tools' current discovery conventions. When a tool moves
  its directories, this module is wrong until it is updated, and nothing in the
  type system will say so.
- `AgentAssetProvider` and `AgentAssetScope` are aliases over the interactive
  vocabulary, so the two capabilities are coupled at the type level even though
  they are adopted separately.
