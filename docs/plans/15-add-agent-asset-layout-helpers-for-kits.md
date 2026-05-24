---
id: 15
slug: add-agent-asset-layout-helpers-for-kits
title: "Add agent asset layout helpers for kits"
kind: exec-plan
created_at: 2026-05-24T21:48:55Z
intention: intention_01ksdzsd7jenf8w00bapj1mjyr
master_plan: "docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md"
---

# Add agent asset layout helpers for kits

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Baikai exposes a small provider-native layout helper module for projects that install agent skills, custom agents, or similar kit content. A project such as Seihou can ask Baikai where Claude Code and Codex expect skill and agent files for user scope and project scope, then perform its own install, update, status, and uninstall logic.

The observable behavior is a compiling `Baikai.AgentAssets` module with tests proving the Claude Code and Codex paths. Baikai does not clone kit repositories or copy files; it only centralizes provider discovery rules so every consumer uses the same paths.


## Progress

- [x] Add `Baikai.AgentAssets` to the core `baikai` library. Completed 2026-05-24. The module is exposed from `baikai/baikai.cabal` and re-exported by `Baikai`.
- [x] Define scope, artifact kind, provider, format, and path helper types. Completed 2026-05-24. `AgentAssetProvider` and `AgentAssetScope` reuse `InteractiveProvider` and `InteractiveScope`; `AgentAssetKind`, `AgentAssetFormat`, `AgentAssetLayout`, and `CodexCustomAgent` are asset-specific.
- [x] Add tests for Claude Code and Codex user/project paths. Completed 2026-05-24. `AgentAssetsSpec` covers every provider, scope, and kind combination, including the Codex `.agents/skills` project path.
- [x] Document how consumers should use layout helpers in kit installers. Completed 2026-05-24. Added `docs/user/agent-assets.md`.
- [x] Reconcile documentation with the interactive launch modules from EP-2. Completed 2026-05-24. `docs/user/interactive-launches.md` now links to asset layout docs and states that launchers do not install or verify provider asset files.


## Surprises & Discoveries

- Seihou's implementation showed that Codex project skills should use `.agents/skills`, not `.codex/skills`. This plan should encode that corrected path and document that consumers must verify provider docs before changing it.

- Official Codex documentation confirms that Codex project skills are discovered from `.agents/skills` and user skills from `$HOME/.agents/skills`; custom agents are TOML files under `.codex/agents/` for project scope and `~/.codex/agents/` for user scope. Evidence: <https://developers.openai.com/codex/skills> and <https://developers.openai.com/codex/subagents>.

- Official Claude Code documentation confirms `.claude/skills` for skills and `.claude/agents` for custom subagents. Evidence: <https://docs.anthropic.com/en/docs/claude-code/skills> and <https://docs.anthropic.com/en/docs/claude-code/sub-agents>.


## Decision Log

- Decision: Baikai owns layout metadata, not kit lifecycle operations.
  Rationale: Provider discovery paths are reusable across projects. Cloning kit repositories, interpreting manifests, copying files, reporting status, and uninstalling are application responsibilities.
  Date: 2026-05-24

- Decision: Include Codex custom-agent TOML support as layout/format metadata, not as a full manifest generator unless needed.
  Rationale: Consumers may already have their own manifest and conversion rules. Baikai should make the target format explicit and optionally provide a small TOML renderer only if tests show repeated consumers need it.
  Date: 2026-05-24

- Decision: Reuse `InteractiveProvider` and `InteractiveScope` as the asset provider and scope vocabulary.
  Rationale: The asset helpers and interactive launchers describe the same local provider families and user/project scope distinction. Reusing those types prevents drift between launch options and layout metadata.
  Date: 2026-05-24

- Decision: Include a minimal Codex custom-agent TOML renderer.
  Rationale: Seihou already needed to convert kit agent metadata into Codex TOML. Keeping the renderer small and pure gives consumers a reusable default without turning Baikai into a kit manifest system.
  Date: 2026-05-24


## Outcomes & Retrospective

Implemented `Baikai.AgentAssets` as a pure core module that computes provider-native skill and custom-agent paths for Claude Code and Codex. The module reuses `InteractiveProvider` and `InteractiveScope`, exposes path and format metadata through `AgentAssetLayout`, and includes `codexCustomAgentToml` for the minimal Codex TOML shape.

Tests now assert all user/project path combinations and format choices. Documentation explains that Baikai owns provider layout metadata only, while consuming applications own manifests, copying, updates, status, and uninstall behavior. The documentation also records that debug-mode launches do not prove provider asset loading.

Validation completed on 2026-05-24:

```text
cabal build baikai
Build completed successfully.

cabal test baikai-test
All 31 tests passed.

cabal build all
Build completed successfully.

cabal test all
All baikai, baikai-claude, baikai-openai, baikai-smoke, and baikai-trace-otel test suites passed.
```


## Context and Orientation

This plan depends on `docs/plans/13-add-interactive-launch-core-abstraction.md`, which defines provider identity and any shared scope vocabulary in `Baikai.Interactive`. If EP-1 uses provider names or scope types that fit asset layouts, reuse them. If not, define the asset-specific types in `Baikai.AgentAssets` and document the distinction.

The current Baikai repository has no kit or skill layout module. The closest related docs are `docs/user/cli-providers.md`, which explain batch `claude -p` and `codex exec` providers. Seihou has already implemented application-local path helpers in `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou/seihou-cli/src/Seihou/CLI/KitPaths.hs`; use that file as evidence of consumer needs, but do not copy Seihou-specific target-base rules wholesale.

An "agent asset" means a file or directory that a provider discovers outside the prompt itself. For this plan, the asset kinds are skill directories and custom-agent files. "User scope" means a path under the user's home directory. "Project scope" means a path under the project working tree.


## Plan of Work

Milestone 1 defines asset layout types. Create `baikai/src/Baikai/AgentAssets.hs` and expose it in `baikai/baikai.cabal`. Define types equivalent to:

```haskell
data AgentAssetProvider = AssetClaudeCode | AssetCodex
data AgentAssetScope = AssetUserScope | AssetProjectScope
data AgentAssetKind = SkillAsset | AgentAsset
data AgentAssetFormat = DirectoryAsset | MarkdownFile | TomlFile

data AgentAssetLayout = AgentAssetLayout
  { provider :: AgentAssetProvider
  , scope :: AgentAssetScope
  , kind :: AgentAssetKind
  , format :: AgentAssetFormat
  , relativePath :: FilePath
  }
```

The exact names may differ. The important requirement is that callers can ask for a provider, scope, and item name and receive the relative or home-based target path and expected format.

Milestone 2 implements helper functions. Provide functions equivalent to:

```haskell
skillTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
agentTargetPath :: AgentAssetProvider -> AgentAssetScope -> FilePath -> FilePath
agentAssetFormat :: AgentAssetProvider -> AgentAssetKind -> AgentAssetFormat
```

For Claude Code, the project paths should be `.claude/skills/<name>/` and `.claude/agents/<name>.md` relative to the caller's chosen Claude base. Because applications may mount a custom Claude base, consider returning relative provider paths rather than absolute filesystem paths. For Codex, project paths should be `.agents/skills/<name>/` and `.codex/agents/<name>.toml`; user paths should be `$HOME/.agents/skills/<name>/` and `$HOME/.codex/agents/<name>.toml`.

Milestone 3 adds tests. Add `baikai/test/AgentAssetsSpec.hs` and register it in `baikai/baikai.cabal` and `baikai/test/Main.hs`. Tests must cover every provider/scope/kind combination and assert the Codex project skill path is `.agents/skills/<name>`, not `.codex/skills/<name>`.

Milestone 4 documents consumer usage. Add documentation explaining that a kit command should use Baikai for layout metadata, but still own manifest loading, file copying, update repair, status reporting, and uninstall behavior.

This plan is complete as of 2026-05-24.


## Concrete Steps

Run commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai
cabal test baikai-test
```

If EP-3 documentation references EP-2 modules, also run:

```bash
cabal build all
```


## Validation and Acceptance

Acceptance requires `cabal build baikai` and `cabal test baikai-test` to pass. Tests must assert at least these paths:

```text
.agents/skills/example
.codex/agents/example.toml
$HOME/.agents/skills/example
$HOME/.codex/agents/example.toml
.claude/skills/example
.claude/agents/example.md
```

Documentation must state that Baikai does not install kit content and that debug-mode agent launches do not prove downstream provider asset loading.


## Idempotence and Recovery

This work is additive and pure. Re-running tests is safe. Because the module only computes paths and metadata, implementation should not create, delete, or modify files outside the repository. If a path assumption changes based on provider documentation, update tests and record the source of the change in this plan's Surprises & Discoveries.


## Interfaces and Dependencies

This plan should not add dependencies. Use `System.FilePath` from `filepath` if needed; the core package already depends on `base` but does not currently list `filepath`, so prefer simple relative path strings or add `filepath` only if it materially improves path handling. The final public module is `baikai/src/Baikai/AgentAssets.hs`, exposed by `baikai/baikai.cabal`.


## Revision Note

2026-05-24: Implemented the plan, recorded provider documentation sources for the selected paths, updated progress and outcomes with validation evidence, and documented the completed asset layout API.
