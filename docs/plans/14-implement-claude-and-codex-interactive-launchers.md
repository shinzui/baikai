---
id: 14
slug: implement-claude-and-codex-interactive-launchers
title: "Implement Claude and Codex interactive launchers"
kind: exec-plan
created_at: 2026-05-24T21:48:55Z
intention: intention_01ksdzsd7jenf8w00bapj1mjyr
master_plan: "docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md"
---

# Implement Claude and Codex interactive launchers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Baikai's vendor packages can launch real interactive Claude Code and Codex sessions from a shared `Baikai.Interactive` request. Downstream projects no longer need to hand-roll the exact `claude` or `codex` command-line arguments for working directory, model, prompts, mounted directories, permissions, sandboxing, or approval policy.

The observable behavior is that a caller can use the Claude launcher from `baikai-claude` or the Codex launcher from `baikai-openai` to spawn the local CLI. Automated tests should verify command construction without requiring live authentication; optional smoke checks may run the real binaries when they are installed and the test environment is interactive.


## Progress

- [x] Implement Claude Code interactive launch module in `baikai-claude`. Completed 2026-05-24. Added `Baikai.Provider.Claude.Interactive` with `ClaudeInteractiveConfig`, `defaultClaudeInteractiveConfig`, `claudeInteractiveCommand`, and `launchClaudeInteractive`.
- [x] Implement Codex interactive launch module in `baikai-openai`. Completed 2026-05-24. Added `Baikai.Provider.OpenAI.Interactive` with `CodexInteractiveConfig`, `defaultCodexInteractiveConfig`, `codexInteractiveCommand`, `codexInteractivePrompt`, and `launchCodexInteractive`.
- [x] Add command-construction tests that do not spawn external CLIs. Completed 2026-05-24. Added `baikai-claude-test` and `baikai-openai-test`.
- [x] Add optional smoke checks gated on binary availability and interactive environment. Completed 2026-05-24. Added `InteractiveSmoke` help-output checks that skip when `claude` or `codex` are absent and verify the installed binaries expose the flags used by the launchers without starting an interactive session.
- [x] Document launcher configuration and how it differs from batch CLI providers. Completed 2026-05-24. Added `docs/user/interactive-launches.md` and linked it from `docs/user/cli-providers.md`.


## Surprises & Discoveries

- Existing batch modules already use the short names `Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli`. Interactive modules must use distinct names so imports make behavior obvious.

- The installed Codex CLI exposes `--model`, `--cd`, `--add-dir`, `--sandbox`, and `--ask-for-approval` for interactive launches, but no top-level system-prompt flag. Evidence: `codex --help` lists the launch flags and accepts a positional prompt. The Codex launcher therefore preserves `InteractiveLaunchRequest.systemPrompt` by prepending a "System instructions" section to the initial prompt text through `codexInteractivePrompt`.

- Live interactive sessions are not suitable as default smoke tests because starting a real Claude Code or Codex terminal session can require authentication, terminal trust, and manual exit. Evidence: `claude --help` and `codex --help` both describe interactive terminal behavior. The smoke suite now performs non-authenticated help-output checks for required flags instead.


## Decision Log

- Decision: Keep batch and interactive modules side by side.
  Rationale: `Baikai.Provider.Claude.Cli` means `claude -p` and `Baikai.Provider.OpenAI.Cli` means `codex exec`. Reusing those names for interactive sessions would be a breaking semantic change.
  Date: 2026-05-24

- Decision: Prefer testable command builders over only end-to-end smoke tests.
  Rationale: Interactive sessions require local binaries, authentication, and a terminal. Most CI and agent runs can still validate the important command-line semantics by testing pure argument construction.
  Date: 2026-05-24

- Decision: Use `Baikai.Provider.OpenAI.Interactive` as the Codex interactive module name.
  Rationale: The package is named `baikai-openai` and already exposes `Baikai.Provider.OpenAI.Cli` for the Codex batch CLI provider. Keeping the module under `OpenAI` matches the package namespace while the exported `CodexInteractiveConfig` and `launchCodexInteractive` names make the concrete CLI clear.
  Date: 2026-05-24

- Decision: Preserve Codex system prompts by embedding them in the initial prompt text.
  Rationale: The installed Codex CLI help does not expose an interactive system-prompt flag. Dropping the field would violate the shared request semantics, while passing an unknown flag would break launches.
  Date: 2026-05-24


## Outcomes & Retrospective

Implemented vendor-specific interactive launchers without changing the existing batch CLI providers. `Baikai.Provider.Claude.Interactive` renders and launches `claude` with model, system prompt, extra directories, allowed tools, config extra args, request extra args, and the initial user prompt. `Baikai.Provider.OpenAI.Interactive` renders and launches `codex` with model, working directory, extra directories, sandbox, approval policy, config extra args, request extra args, and the initial prompt.

The implementation added pure command-construction tests in new vendor test suites, plus smoke-suite help checks that prove locally installed CLI binaries expose the required launch flags without starting a live terminal session. Documentation now gives callers concrete examples and explains when to use the interactive launch surface instead of the batch `completeRequest` / `streamRequest` providers.

Validation completed on 2026-05-24:

```text
cabal build all
Build completed successfully.

cabal test all
All baikai, baikai-claude, baikai-openai, baikai-smoke, and baikai-trace-otel test suites passed.
Smoke output included:
[baikai-smoke] claude interactive flags ok via /Users/shinzui/.local/bin/claude.
[baikai-smoke] codex interactive flags ok via /opt/homebrew/bin/codex.
```


## Context and Orientation

This plan depends on `docs/plans/13-add-interactive-launch-core-abstraction.md`, which creates `Baikai.Interactive` in the core `baikai` package. Implement this plan only after that module exists and is exposed.

Current batch CLI providers live at `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. The Claude batch provider runs `claude -p --output-format json --no-session-persistence` and returns a `Baikai.Response.Response`. The Codex batch provider runs `codex exec --json` and returns a `Response`. Those modules remain unchanged except for documentation links if necessary.

The new interactive launchers belong in vendor packages because they know provider-specific CLI flags. Claude Code supports concepts such as allowed tools and added directories. Codex supports sandbox and approval policy flags. Baikai core should not depend on provider packages or process libraries beyond what EP-1 needs for shared types.


## Plan of Work

Milestone 1 implements testable command construction. In `baikai-claude`, add a module such as `Baikai.Provider.Claude.Interactive`. In `baikai-openai`, add a module such as `Baikai.Provider.OpenAI.Interactive` or `Baikai.Provider.Codex.Interactive`; record the final name in this plan's Decision Log during implementation. Each module should expose a config type, a default config, a pure function that renders executable arguments from `InteractiveLaunchRequest`, and an IO launcher that runs the process.

The expected interface shape is equivalent to:

```haskell
data ClaudeInteractiveConfig = ClaudeInteractiveConfig
  { executable :: FilePath
  , extraArgs :: [Text]
  }

launchClaudeInteractive
  :: ClaudeInteractiveConfig
  -> InteractiveLaunchRequest
  -> IO InteractiveLaunchResult

claudeInteractiveCommand
  :: ClaudeInteractiveConfig
  -> InteractiveLaunchRequest
  -> (FilePath, [String])
```

Codex should follow the same pattern with a Codex-specific config. The pure command builders allow tests to verify flags without spawning external processes.

Milestone 2 implements process launch. Use the existing process style in each package where practical. `baikai-claude` already depends on `cradle`; `baikai-openai` already depends on `process`. The launchers should inherit stdin/stdout/stderr by default so the user gets a real interactive terminal. They should return an `InteractiveLaunchResult` carrying the provider identity and exit code.

Milestone 3 adds tests and optional smoke checks. Unit tests should assert that Claude receives model, system prompt, user prompt, and add-directory flags in the expected order. Codex tests should assert model, working directory, sandbox, approval policy, and add-directory flags. Live smoke tests should be skipped unless the binary is present and the environment is suitable for an interactive process.

Milestone 4 updates documentation. `docs/user/cli-providers.md` should keep describing batch providers and link to the new interactive launch documentation. A new or updated document should show when to choose `completeRequest` versus `launchClaudeInteractive` or `launchCodexInteractive`.

This plan is complete as of 2026-05-24.


## Concrete Steps

Run commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build all
cabal test all
```

For optional live smoke checks, first verify local binaries:

```bash
command -v claude
command -v codex
```

If the implementation adds a live smoke flag or environment variable, document the exact invocation here before running it.


## Validation and Acceptance

Acceptance requires `cabal build all` and `cabal test all` to pass. Tests must prove command rendering for Claude and Codex without starting the CLIs. The exposed modules in `baikai-claude/baikai-claude.cabal` and `baikai-openai/baikai-openai.cabal` must include the new interactive modules. Documentation must clearly state that `Baikai.Provider.*.Cli` remains a batch completion provider, while the new `*.Interactive` modules start real sessions.


## Idempotence and Recovery

The implementation should be additive. If a live smoke check starts an interactive session accidentally, exit the session normally and rerun only the pure tests. Do not make live interactive tests part of the default `cabal test all` path unless they reliably skip in non-interactive environments.


## Interfaces and Dependencies

Use `Baikai.Interactive` from the core package. Use existing dependencies where possible: `cradle` in `baikai-claude` and `process` in `baikai-openai`. Do not add new dependencies unless command execution cannot be implemented with the existing package dependencies. The final modules should be listed in the vendor cabal files and documented in `docs/user`.


## Revision Note

2026-05-24: Implemented the plan, recorded the Codex system-prompt flag discovery, updated progress and outcomes with validation evidence, and documented the completed launcher APIs.
