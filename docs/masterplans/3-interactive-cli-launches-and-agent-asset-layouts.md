---
id: 3
slug: interactive-cli-launches-and-agent-asset-layouts
title: "Interactive CLI launches and agent asset layouts"
kind: master-plan
created_at: 2026-05-24T21:48:48Z
intention: intention_01ksdzsd7jenf8w00bapj1mjyr
---

# Interactive CLI launches and agent asset layouts

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, Baikai has two clearly separated integration surfaces. The existing `completeRequest` and `streamRequest` registry remains the surface for one-shot API completions and batch CLI subprocesses such as `claude -p` and `codex exec`. A new interactive launch surface exists beside it for programs that need to open a real Claude Code or Codex terminal session and let the provider own the interactive tool loop.

Callers such as Seihou can ask Baikai to launch an interactive provider with a rendered system prompt, an initial user prompt, a working directory, extra readable directories, optional model selection, and provider-specific safety settings. Baikai owns the command-line details for `claude` and `codex`, including Codex sandbox and approval flags and Claude allowed-tool flags. The caller still owns its product-specific prompt construction and any project-specific lifecycle commands.

The initiative also adds provider-native agent asset layout helpers. A kit installer remains a filesystem command in the consuming project, but it can ask Baikai where Claude Code and Codex expect skills and custom agents to live. This makes the provider discovery rules reusable across projects without turning Baikai into a kit package manager.

In scope: a core interactive request/result model in `baikai`, Claude Code and Codex launch implementations in `baikai-claude` and `baikai-openai`, agent asset layout helpers in `baikai`, provider-neutral reasoning-effort control for interactive launches, user documentation, tests, and smoke checks that do not require an authenticated interactive session unless explicitly marked live.

Out of scope: replacing `completeRequest` with an interactive session API, implementing a long-running programmatic conversation protocol, managing kit repository manifests, installing files into a user's project, or proving that a non-debug Codex session loaded a project skill in automated tests.


## Decomposition Strategy

The work is decomposed by functional concern. EP-1 defines the core vocabulary: what an interactive launch request is, what options can be expressed provider-neutrally, what result is returned, and which provider-specific settings are represented without depending on vendor packages. EP-2 implements the vendor-specific launchers against that vocabulary. EP-3 adds reusable provider asset layout helpers and documentation for kit installers. EP-4 is a follow-up that extends the established core request and both launchers with a shared reasoning-effort setting while preserving provider-specific command-line translation at the vendor boundary.

This split keeps the existing completion registry stable. The current CLI provider modules deliberately wrap `claude -p` and `codex exec` as batch providers. Changing those modules to mean "interactive session" would silently change existing semantics and break users who rely on `Response` values and synthetic streams. A sibling abstraction lets Baikai support both use cases honestly.

Alternatives considered and rejected: extending `ApiProvider` with an optional interactive method was rejected because it would couple two different return shapes and make many providers report "not supported" at runtime. Moving kit installation into Baikai was rejected because kit manifests, update policy, scope selection, and file ownership are product-specific. Adding only docs and leaving launch code in each consumer was rejected because every project would rediscover the same `claude` and `codex` flag details.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Add interactive launch core abstraction | docs/plans/13-add-interactive-launch-core-abstraction.md | None | None | Complete |
| EP-2 | Implement Claude and Codex interactive launchers | docs/plans/14-implement-claude-and-codex-interactive-launchers.md | EP-1 | None | Complete |
| EP-3 | Add agent asset layout helpers for kits | docs/plans/15-add-agent-asset-layout-helpers-for-kits.md | EP-1 | EP-2 | Complete |
| EP-4 | Add reasoning-effort control to interactive CLI launches | docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md | EP-2 | None | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 must run first because it defines the core modules and types that later plans consume. The most important artifact is the provider-neutral interactive launch request type. Without it, EP-2 would have to invent vendor-specific APIs that could not be shared by consumers.

EP-2 hard-depends on EP-1 because the Claude and Codex launchers should implement the core interactive surface rather than define one-off functions. EP-2 can add vendor-specific configuration types in the vendor packages, but the shared request and result model comes from EP-1.

EP-3 hard-depends on EP-1 because provider identity and scope terminology should be shared with the interactive surface. EP-3 has a soft dependency on EP-2 because the final documentation is clearer once the concrete launchers exist, but most of the path helper work can proceed after EP-1.

EP-4 hard-depends on EP-2 because it extends the request and pure command builders delivered by EP-1 and EP-2. Its dependency is already satisfied. The recommended implementation order for the original work was EP-1, then EP-2, then EP-3; the later EP-4 follow-up can proceed independently now that all three are complete.


## Integration Points

`baikai/src/Baikai/Interactive.hs` is owned by EP-1 and consumed by EP-2 and EP-3. It should expose the provider-neutral interactive request and result types. Later plans should import these types rather than redefining prompt, working directory, model, or extra-directory fields.

`Baikai.Provider.Claude.Interactive` is owned by EP-2 in `baikai-claude`. It should expose Claude-specific configuration and a launcher function that consumes the EP-1 request type. It must not replace `Baikai.Provider.Claude.Cli`, which remains the `claude -p` batch provider.

`Baikai.Provider.OpenAI.Interactive` or `Baikai.Provider.Codex.Interactive` is owned by EP-2 in `baikai-openai`. The module name should be chosen during implementation and recorded in the child plan. It must not replace `Baikai.Provider.OpenAI.Cli`, which remains the `codex exec` batch provider.

`Baikai.ThinkingLevel` and the `InteractiveLaunchRequest` fields in `baikai/src/Baikai/Interactive.hs` are extended by EP-4. EP-4 also updates the Claude and OpenAI interactive modules owned by EP-2 so each translates the shared effort setting into its own CLI syntax. The batch/API request shapers consume the same six-level vocabulary and must preserve native higher effort values while keeping compatibility clamps explicit.

`baikai/src/Baikai/AgentAssets.hs` is owned by EP-3. It should expose provider-native layout helpers for skills and agents. Consumers such as Seihou can use these helpers in their kit installer, but Baikai should not own copying, updating, or deleting kit files.

Documentation is shared across all three plans. EP-1 should document the conceptual split between batch completions and interactive launches. EP-2 should document concrete launcher configuration. EP-3 should document how kit installers consume layout helpers and why debug-mode launch validation is not proof of provider skill loading.


## Progress

- [x] EP-1: Define `Baikai.Interactive` request, result, provider identity, and safety-option types.
- [x] EP-1: Add pure tests for request construction and command-independent option rendering.
- [x] EP-1: Document the conceptual boundary between batch completion providers and interactive launchers.
- [x] EP-2: Implement Claude Code interactive launcher without changing `Baikai.Provider.Claude.Cli`.
- [x] EP-2: Implement Codex interactive launcher without changing `Baikai.Provider.OpenAI.Cli`.
- [x] EP-2: Add command-construction tests and smoke checks for installed CLI flag availability without starting live interactive sessions.
- [x] EP-3: Add provider-native skill and custom-agent layout helpers for Claude Code and Codex.
- [x] EP-3: Document how kit installers should consume layout helpers while retaining ownership of filesystem lifecycle.
- [x] EP-3: Add tests for all user/project layout paths and Codex custom-agent TOML generation if that helper is included.
- [ ] EP-4: Add six-level reasoning-effort control to the shared request, API mappings, and both interactive launchers; document and validate the coordinated change.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Existing Baikai CLI providers are batch providers by design, not interactive launchers. Evidence: `docs/user/cli-providers.md` says they drive `claude -p` and `codex exec` through `completeRequest` and `streamRequest`, with synthetic streaming and no tool-equivalent path. `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` shells out to `claude -p --output-format json --no-session-persistence`, and `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` shells out to `codex exec --json`.

- Seihou already discovered the consumer-side need for this split. Evidence: `/Users/shinzui/Keikaku/bokuno/seihou-project/seihou/docs/references/baikai-codex-agent-migration.md` records that API completions should use Baikai, while `claude-cli` and `codex-cli` should launch interactive sessions directly. This MasterPlan turns that repeated consumer pattern into a Baikai-owned interactive surface.

- EP-1 completed without changing the existing batch CLI provider registry. Evidence: `cabal test baikai-test` passed all 23 tests after adding `Baikai.Interactive`, including existing completion registry and trace tests.

- EP-2 completed without changing the batch CLI providers. Evidence: `Baikai.Provider.Claude.Interactive` and `Baikai.Provider.OpenAI.Interactive` are new exposed modules, while `Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli` remained batch providers. `cabal test all` passed, including new command-construction tests and smoke help checks for locally installed `claude` and `codex` flags.

- Codex interactive launches do not have a top-level system-prompt flag in the installed CLI. Evidence: `codex --help` lists `--model`, `--cd`, `--add-dir`, `--sandbox`, and `--ask-for-approval`, but not a system-prompt option. EP-2 records the decision to embed the system prompt into the initial prompt text for Codex.

- EP-3 completed by reusing `InteractiveProvider` and `InteractiveScope` for asset layout metadata. Evidence: `Baikai.AgentAssets` exposes asset-specific kinds, formats, layouts, and Codex TOML rendering while keeping provider and scope vocabulary shared with `Baikai.Interactive`.

- Provider documentation confirmed the path split used by EP-3. Evidence: Codex skills use `.agents/skills` and `$HOME/.agents/skills`, while Codex custom agents use `.codex/agents` and `$HOME/.codex/agents`; Claude Code uses `.claude/skills` and `.claude/agents`.

- The completed initiative needed to reopen for EP-4 because downstream interactive-launch consumers require deterministic reasoning-effort selection, while the original request exposed model selection but only raw vendor-specific `extraArgs` for effort. Evidence: `docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md` defines the shared field and both pure argv translations.


## Decision Log

- Decision: Add a sibling interactive launch abstraction instead of changing `ApiProvider`.
  Rationale: `ApiProvider` returns `Response` values and stream events for one-shot completions. Interactive launches return an `ExitCode` after handing control to a terminal process. Combining those shapes would make the API less honest and risk breaking existing batch CLI users.
  Date: 2026-05-24

- Decision: Keep kit installation outside Baikai while adding asset layout helpers.
  Rationale: Baikai can own provider discovery rules, but kit manifests, cloning, update policy, uninstall behavior, and project scope rules belong to each consuming application.
  Date: 2026-05-24

- Decision: Make Claude and Codex launchers vendor-package modules.
  Rationale: The existing package split keeps provider-specific dependencies outside the core package. Core should define shared request and layout vocabulary; vendor packages should own command-line flags for their tools.
  Date: 2026-05-24

- Decision: Reopen the initiative and register reasoning-effort control as EP-4, hard-dependent on the completed EP-2.
  Rationale: The follow-up extends the exact shared request and vendor launchers established here, so keeping it under this MasterPlan preserves ownership and integration history rather than treating the feature as unrelated work.
  Date: 2026-07-20


## Outcomes & Retrospective

The original three-plan initiative completed with a provider-neutral interactive launch vocabulary in `Baikai.Interactive`, vendor interactive launchers in `Baikai.Provider.Claude.Interactive` and `Baikai.Provider.OpenAI.Interactive`, and provider-native asset layout helpers in `Baikai.AgentAssets`. The initiative is temporarily reopened while EP-4 adds reasoning-effort control to that surface.

The existing batch completion registry remains intact. `Baikai.Provider.Claude.Cli` still drives `claude -p` through `completeRequest` / `streamRequest`, and `Baikai.Provider.OpenAI.Cli` still drives `codex exec`. The new interactive launch modules start real terminal sessions and return an `InteractiveLaunchResult` after the CLI exits.

Asset layout support stayed intentionally pure. Baikai computes and documents where Claude Code and Codex expect skills and custom agents, including Codex TOML rendering, but does not own kit manifests or filesystem lifecycle operations. Consumers such as Seihou can now replace duplicated layout constants with Baikai helpers while retaining application-specific install, update, status, and uninstall behavior.


## Revision Note

2026-05-24: Marked EP-2 complete after adding vendor interactive launchers, command-construction tests, smoke help checks, and interactive launch documentation. Recorded the Codex system-prompt flag discovery because EP-3 documentation should preserve that distinction.

2026-05-24: Marked EP-3 complete after adding `Baikai.AgentAssets`, path and TOML tests, and asset-layout documentation. Filled the MasterPlan retrospective because all child plans are complete.

2026-07-20: Reopened the initiative to register EP-4, a follow-up that adds provider-neutral reasoning-effort control to the shared interactive request and both vendor launchers.
