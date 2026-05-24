---
id: 13
slug: add-interactive-launch-core-abstraction
title: "Add interactive launch core abstraction"
kind: exec-plan
created_at: 2026-05-24T21:48:55Z
master_plan: "docs/masterplans/3-interactive-cli-launches-and-agent-asset-layouts.md"
---

# Add interactive launch core abstraction

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, Baikai exposes a provider-neutral vocabulary for launching interactive local agent CLIs. A caller can build one `InteractiveLaunchRequest` containing a rendered system prompt, an initial user prompt, an optional model, a working directory, extra readable directories, and provider safety preferences. Provider packages can consume that request to launch Claude Code or Codex without each downstream application inventing its own request type.

The observable result is not a live Claude or Codex process yet. The observable result is a compiling `baikai` package with a documented `Baikai.Interactive` module and tests proving the core data model can represent the interactive inputs Seihou and similar projects need.


## Progress

- [ ] Add `Baikai.Interactive` to the core `baikai` library and cabal exposed modules.
- [ ] Define provider-neutral request, result, provider, scope, and safety-option types.
- [ ] Add pure tests for default values and helper constructors.
- [ ] Document the boundary between completion providers and interactive launchers.


## Surprises & Discoveries

- Existing batch CLI providers intentionally use `completeRequest` and `streamRequest`, so this work must not alter `Baikai.Provider.Registry.ApiProvider`. Evidence: `Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli` register handlers by API tag and return `Baikai.Response.Response`.


## Decision Log

- Decision: Represent interactive launches as a separate `Baikai.Interactive` module in the core package.
  Rationale: Core types are shared by both vendor packages and by consumers that need to build launch requests without depending on Claude or OpenAI package transitive dependencies.
  Date: 2026-05-24

- Decision: Return process status rather than `Response`.
  Rationale: An interactive launch hands control to the local CLI and its terminal UI. Baikai can report whether the process exited successfully, but it cannot truthfully return a single assistant message.
  Date: 2026-05-24


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Baikai is a multi-package Haskell workspace rooted at `/Users/shinzui/Keikaku/bokuno/baikai`. The core package is `baikai/`, with exposed modules listed in `baikai/baikai.cabal`. The vendor packages are `baikai-claude/` and `baikai-openai/`.

The existing completion abstraction lives in `baikai/src/Baikai/Provider.hs` and `baikai/src/Baikai/Provider/Registry.hs`. It dispatches by `Baikai.Api.Api` tag and returns `Baikai.Response.Response` through `completeRequest` and `streamRequest`. The batch CLI providers live in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`; they should remain batch providers for `claude -p` and `codex exec`.

An "interactive launch" means starting the local `claude` or `codex` binary in a way that opens a real terminal session for the user. It is not a chat completion call. It may inherit authentication from the local CLI and may let the CLI manage tools, approvals, filesystem access, and session state.


## Plan of Work

Milestone 1 adds the core type module. Create `baikai/src/Baikai/Interactive.hs` and expose it from `baikai/baikai.cabal`. Define a small set of records and sum types that are expressive enough for both Claude Code and Codex but do not import vendor packages.

The expected types are equivalent to:

```haskell
data InteractiveProvider = InteractiveClaude | InteractiveCodex

data InteractiveLaunchRequest = InteractiveLaunchRequest
  { systemPrompt :: Maybe Text
  , userPrompt :: Text
  , model :: Maybe Text
  , workingDir :: Maybe FilePath
  , extraDirs :: [FilePath]
  , safety :: InteractiveSafety
  , extraArgs :: [Text]
  }

data InteractiveSafety
  = DefaultSafety
  | ClaudeAllowedTools [Text]
  | CodexSandbox CodexSandboxMode CodexApprovalPolicy

data InteractiveLaunchResult = InteractiveLaunchResult
  { provider :: InteractiveProvider
  , exitCode :: ExitCode
  }
```

The exact field names may differ, but the module must distinguish provider identity, request contents, provider safety preferences, and launch results.

Milestone 2 adds pure helper constructors and tests. Add tests under `baikai/test/InteractiveSpec.hs` and register them in `baikai/baikai.cabal` and `baikai/test/Main.hs`. Test defaults such as no explicit model, empty `extraDirs`, and provider identity rendering. These tests should not spawn external processes.

Milestone 3 documents the abstraction boundary. Update `docs/user/cli-providers.md` or a new `docs/user/interactive-launches.md` so users understand that batch CLI providers remain available through `completeRequest`, while interactive launchers are a separate surface implemented by vendor packages.


## Concrete Steps

Run commands from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai
cabal test baikai-test
```

Expected result after Milestone 1 is a clean build. Expected result after Milestone 2 is a passing core test suite that includes the new interactive tests.


## Validation and Acceptance

Acceptance requires `cabal build baikai` to succeed, `cabal test baikai-test` to pass, and the public module list in `baikai/baikai.cabal` to expose `Baikai.Interactive`. A downstream package should be able to import `Baikai.Interactive`, construct an interactive launch request with a working directory and model omitted, and compile without depending on `baikai-claude` or `baikai-openai`.


## Idempotence and Recovery

The changes are additive. Re-running tests and builds is safe. If the type design proves too narrow during EP-2, extend the core types additively rather than changing existing constructors unless no implementation has consumed them yet. Do not remove or alter `Baikai.Provider.Registry.ApiProvider`.


## Interfaces and Dependencies

This plan should not add new package dependencies. The core package already depends on `base`, `text`, and common data libraries. Use `System.Exit.ExitCode` from `base` for launch results. Use `Data.Text.Text` for prompts, model names, and extra arguments. The central interface is `baikai/src/Baikai/Interactive.hs`; later plans consume it from `baikai-claude` and `baikai-openai`.
