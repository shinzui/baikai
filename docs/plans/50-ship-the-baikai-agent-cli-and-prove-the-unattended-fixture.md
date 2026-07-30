---
id: 50
slug: ship-the-baikai-agent-cli-and-prove-the-unattended-fixture
title: "Ship the baikai agent CLI and prove the unattended fixture"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Ship the baikai agent CLI and prove the unattended fixture

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Everything this initiative needed now exists except the thing anyone actually asked for. There is a
way to describe an unattended coding-agent run, a way to render it into a command line for either
Claude Code or Codex, a way to execute it with a timeout and bounded output, and a way to load its
description from a KDL file with per-value provenance and an operator-owned safety limit. All of it
is a Haskell library. A shell script cannot call any of it.

This plan ships the command. After it, a script runs:

```bash
printf '%s' "$prompt" | baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --set extra-dir=/path/to/keiro
```

and a coding agent does repository work under a policy the repository declared and the operator
capped — with the choice of Claude Code or Codex living in a configuration file rather than in the
script.

This is also the plan that proves the initiative worked. Its acceptance is not "the code compiles"
but "the launch that motivated the request can be expressed without provider flags". The motivating
case is `scripts/sync-keiro-dsl.sh` in the `shinzui/keiro-syntax` repository, whose agent launch is
currently:

```bash
claude -p "$prompt" \
  --add-dir "$keiro_path" \
  --permission-mode acceptEdits \
  --allowedTools Read Write Edit Glob Grep Bash Skill TodoWrite
```

Every one of those flags becomes configuration. This plan builds an end-to-end test that stands up a
fake `claude` executable, a real KDL job file, and the real command-line tool, and asserts the fake
received exactly the arguments and the standard input it should have. No model is ever called.

The plan also does the initiative's paperwork: three commands with a documented exit-code table and
stream discipline a shell script can rely on, the user guide, and the coordinated release across
every affected package.

**The observable outcome**: after this plan, `cabal run baikai -- agent show sync-keiro-dsl` in a
directory containing a job file prints the effective configuration with each value's source and line
number, the exact argument vector that would be spawned, and `<redacted>` in place of any raw
provider argument — without starting a process. `cabal run baikai -- agent list` enumerates the
configured jobs and their scopes. And `agent run` executes one, propagating the agent's exit code so
`set -e` scripts behave.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1: Add the `executable baikai` stanza and its dependencies; wire a testable
      command-line entry point that returns a result record rather than exiting.
- [ ] Milestone 2: Implement provider dispatch from a resolved job to a rendered command.
- [ ] Milestone 3: Implement `agent show` and `agent list`.
- [ ] Milestone 4: Implement `agent run`, including prompt sources, exit codes, and stream
      discipline.
- [ ] Milestone 5: Build the end-to-end fixture test against a fake `claude` executable.
- [ ] Milestone 6: Write `docs/user/unattended-agent-runs.md`, cross-link the other two surfaces,
      and write the consumer migration guide.
- [ ] Milestone 7: Coordinate the release, update the improvement request's status, and run the full
      offline validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet. This plan is the first place all five earlier plans meet, so it is where any disagreement
between them will surface. Record every such disagreement here, because the parent MasterPlan's
retrospective depends on it.)


## Decision Log

Record every decision made while working on the plan.

- Decision: The executable is named `baikai` with an `agent` subcommand group, giving
  `baikai agent run|show|list`.
  Rationale: this is the spelling in the improvement request's own example, and a single named
  executable leaves room for future subcommand groups without minting a new binary each time. The
  package remains `baikai-agent`; a package and its executable need not share a name, and
  `baikai/baikai.cabal` already ships executables named `baikai-gen-models` and
  `baikai-fetch-models`.
  Date: 2026-07-30

- Decision: The command-line logic lives in a library module and returns a result record; the
  `Main.hs` under `app/` only interprets that record into real streams and an exit code.
  Rationale: it is what makes the whole surface testable in-process, without spawning the built
  binary from a test. `settei`'s reference application does exactly this — its
  `runCliWithSnapshot` returns a `CliRun` with an exit code and captured output, and its test suite
  drives that function. Copy the shape.
  Date: 2026-07-30

- Decision: `agent run` propagates the coding agent's own exit code, and Baikai's own failures use
  codes 64 and above following the `sysexits` convention.
  Rationale: the motivating script ends its launch with `|| die "agent run failed"`, so any non-zero
  code works for it — but a script that wants to distinguish "the agent decided the task failed"
  from "the tool could not be started" needs both. Reserving the high range keeps them separable in
  practice, since coding agents conventionally exit 0 or 1. The residual ambiguity is real and must
  be documented rather than hidden: if a provider ever exits in the 64-and-above range, a script
  cannot tell it apart from a Baikai failure, and `--json` output carries the unambiguous answer.
  Date: 2026-07-30

- Decision: Baikai's own diagnostics always go to standard error; the agent's output follows the
  job's configured output mode.
  Rationale: this is what lets `response=$(baikai agent run job)` work for a job configured to
  capture, without the captured value being contaminated by Baikai's progress messages. It is the
  improvement request's requirement that a script capture a final response without losing human
  diagnostics, and the only way to satisfy both is to keep them on separate streams.
  Date: 2026-07-30

- Decision: `agent show` prints the effective configuration **and** the rendered argument vector,
  and renders a refusal as a refusal rather than omitting it.
  Rationale: a command that shows configuration but not the resulting command line leaves the
  operator to guess the mapping, which is the guessing this initiative set out to remove. And a job
  whose policy the provider cannot express, or which exceeds the ceiling, is exactly the case an
  operator most needs `show` for — printing nothing, or printing configuration and silently omitting
  the command, would hide it.
  Date: 2026-07-30

- Decision: This plan does **not** edit `scripts/sync-keiro-dsl.sh` in the `shinzui/keiro-syntax`
  repository.
  Rationale: that file is in a different repository, and the improvement request explicitly places
  moving consuming scripts' workflow logic out of scope. What this plan owes is proof that the launch
  is expressible plus a migration guide showing the exact replacement; making the change is a
  separate commit in that repository, after this one is released.
  Date: 2026-07-30

- Decision: The `--set` flag uses `settei-optparse-applicative`'s override mechanism rather than a
  hand-rolled parser, and takes dotted keys relative to the selected job.
  Rationale: reusing the library's `CliOverride` keeps the command-line layer inside the same
  provenance machinery as every other layer, so `agent show` can attribute a value to the command
  line with the same fidelity as to a file. A hand-rolled flag would resolve outside the resolver and
  lose that.
  Date: 2026-07-30


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository.

Baikai is a multi-package Cabal workspace; Cabal is the Haskell build tool and each package is a
directory containing a `.cabal` file. This plan adds an executable and one library module to
`baikai-agent`, the package created by
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`.

Three earlier plans must be complete before you start, and this plan is the first place all of them
meet. If any is incomplete, its artifacts will be missing and nothing here will compile.

### What you consume, and from where

From `baikai/src/Baikai/Agent.hs`, created by
`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` — the shared vocabulary. Note it is
**not** re-exported from the umbrella module `baikai/src/Baikai.hs`, so `import Baikai.Agent`
explicitly:

```haskell
data AgentProvider = AgentClaude | AgentCodex
data AgentCapability = AgentReadOnly | AgentEditWorkspace | AgentFullAccess
data AgentRunRequest = AgentRunRequest { provider, prompt, modelId, effort, workingDir
                                       , extraDirs, safety, timeout, output, outputLimit
                                       , envPassthrough }
data AgentCommand = AgentCommand { executable, arguments, promptTransport, promptText }
data AgentRunResult = AgentRunResult { provider, exitCode, stdout, stderr, duration }
data AgentRenderError = UnsupportedCapability … | UnsupportedToolRestriction …
                      | SafetyNotExpressible … | ProviderMismatch … | CeilingRejected …
data AgentRunFailure = SpawnFailed … | RunTimedOut … | MissingEnvironment …
                     | WorkingDirMissing … | OutputMalformed …
renderAgentRenderError :: AgentRenderError -> Text
renderAgentRunFailure  :: AgentRunFailure  -> Text
capturedBytes :: AgentCapturedOutput -> Maybe ByteString
```

From the two vendor packages, created by
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md` — the argument-vector
renderers. These are the only reason this plan needs to depend on both provider packages:

```haskell
-- Baikai.Provider.Claude.Agent
data ClaudeAgentConfig = ClaudeAgentConfig { executable, extraArgs, persistSession }
defaultClaudeAgentConfig :: ClaudeAgentConfig
claudeAgentCommand :: ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand

-- Baikai.Provider.OpenAI.Agent
data CodexAgentConfig = CodexAgentConfig { executable, extraArgs, skipGitRepoCheck, ephemeral }
defaultCodexAgentConfig :: CodexAgentConfig
codexAgentCommand :: CodexAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand
```

From `baikai-agent/src/Baikai/Agent/Run.hs`, created by
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` — the process runner:

```haskell
runAgentCommand :: AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
```

It takes both values because `AgentCommand` deliberately carries no working directory: Claude Code
has no working-directory flag, so it is a process-level setting read from the request.

From `baikai-agent/src/Baikai/Agent/Config.hs`, created by
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` — configuration:

```haskell
data AgentJob = AgentJob { provider, executable, modelId, effort, workingDir, extraDirs
                        , capability, allowedTools, providerArgs, timeout, output
                        , outputLimit, envRequires }
data AgentConfigPaths = AgentConfigPaths { userConfig :: !(Maybe FilePath)
                                        , repoConfig :: !(Maybe FilePath) }
defaultAgentConfigPaths :: IO AgentConfigPaths
agentJobRequest :: AgentJob -> Text -> AgentRunRequest
resolveAgentJob :: AgentConfigPaths -> EnvSnapshot -> [CliOverride] -> Text
                -> IO (Either AgentConfigError (ResolveResult AgentJob))
loadAgentCeiling  :: AgentConfigPaths -> IO (Either AgentConfigError AgentCeiling)
applyCeilingToJob :: AgentCeiling -> AgentRunRequest -> Either AgentRenderError AgentRunRequest
data AgentJobEntry = AgentJobEntry { name :: !Text, scope :: !SourceKind }
listAgentJobs :: AgentConfigPaths -> IO (Either AgentConfigError [AgentJobEntry])
renderAgentConfigError :: AgentConfigError -> Text
```

The `ResolveResult a` from `settei` has fields `answer :: Either (NonEmpty ConfigError) a`,
`report :: ResolutionReport`, and `warnings :: [ConfigWarning]`. `Settei.Render` provides
`renderResolutionText`, `renderResolutionJson`, `renderErrorsText`, and `renderWarningsText`.

### The reference application to copy

`/Users/shinzui/Keikaku/bokuno/settei/examples/settei-cli/src/Settei/Example/Cli.hs` is 289 lines and
does almost exactly what this plan needs. Read it in full before writing code. The parts to copy:

Its result record, which is what makes the whole thing testable:

```haskell
data CliRun = CliRun
  { exitCode :: !Int, standardOutput :: !Text, standardError :: !Text }
```

Its separation of parsing from running: `cliOptionsParser :: Parser CliOptions` builds options,
`runCliWithSnapshot :: EnvSnapshot -> CliOptions -> IO CliRun` does the work, and the executable's
`app/Main.hs` — only 19 lines — interprets the record.

Its exit-code constants, defined as named top-level values with Haddock comments:
`usageExitCode = 2`, `sourceExitCode = 3`, `resolutionExitCode = 4`. This plan uses different
numbers, for the reason in the Decision Log, but the same practice of naming them.

Its use of `Options.failureCode usageExitCode` in the `ParserInfo`, which is how
`optparse-applicative` is made to exit with a chosen code on a usage error.

And from `settei-optparse-applicative`: `overrideOptions` for `--set`-style flags,
`configPathOptions` for file paths, `diagnosticModeOptions` and `DiagnosticMode` for explain modes,
`cliSources` to turn parsed overrides into `settei` sources, and `resolutionDiagnostic` and
`schemaDiagnostic` to render them.

There is also an existing in-repository precedent for `optparse-applicative` usage:
`baikai-kit/src/Baikai/Kit/Command.hs` builds a subcommand parser with `hsubparser` and `command`,
and its `runKit` dispatches on a command sum type. Follow that shape for the `agent` subcommand
group.

### The consumer this plan must satisfy

`/Users/shinzui/Keikaku/bokuno/keiro-syntax/scripts/sync-keiro-dsl.sh` is the motivating case. Read
it before Milestone 5. It is a `bash` script with `set -euo pipefail` that resolves a source
repository and commit, takes a lock with `mkdir`, refuses to run on a dirty tree, builds a large
multi-line prompt with `read -r -d ''`, launches the agent, then runs two test suites itself,
updates a marker file, and commits. Only the launch is provider-specific.

Four details of that script shape this plan's requirements. The prompt is large, multi-line, and
contains interpolated paths, so it must arrive on standard input rather than as an argument. The
launch inherits standard output and standard error, because the script's log is the terminal — so
`inherit` must be the default output mode, and it is. The launch ends with
`|| die "agent run failed"`, so a non-zero exit must propagate. And the script, not the agent, owns
the test gate and the commit — which is why the improvement request puts moving that logic out of
scope, and why this plan must not try to absorb it.

### Repository conventions

`baikai-agent` uses `default-language: GHC2024` and `default-extensions: DeriveAnyClass,
DuplicateRecordFields, OverloadedLabels, OverloadedStrings`, with `-Wall -Wcompat
-Wmissing-export-lists` among its warnings and no `-Werror`. Field names carry no type prefix
anywhere in this repository, including internal records — write `exitCode`, not `runExitCode`.
Formatting is `nix fmt`, running `fourmolu` with `fourmolu.yaml`.

The release workflow is `agents/skills/release/SKILL.md`. Read it in full before Milestone 7. It
requires publishing in dependency order with `baikai` first, requires every publishable package to
resolve from Hackage only, and maintains one root `CHANGELOG.md` for every package with per-package
git tags.


## Plan of Work

Seven milestones. Milestone 1 gets a runnable skeleton. Milestones 2 through 4 build the three
commands. Milestone 5 is the acceptance proof. Milestones 6 and 7 document and release.

### Milestone 1 — A runnable, testable skeleton

Scope: add the executable stanza and a command-line entry point that parses arguments and returns a
result record. At the end of this milestone `cabal run baikai -- agent list` runs and reports that no
jobs are configured, and `cabal run baikai -- --help` prints usage.

Add to `baikai-agent/baikai-agent.cabal`. In the **library** stanza, add these dependencies and the
new module `Baikai.Agent.Cli` to `exposed-modules`:

```cabal
    , baikai-claude          ^>=0.5
    , baikai-openai          ^>=0.5
    , optparse-applicative   ^>=0.19
```

Use the major series the two provider packages will carry after this initiative's release. They are
at `0.4.0.0` in-tree and `docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`
makes them PVP-major, so `0.5` is the expected series — verify against the actual in-tree versions
when you get here and adjust. This is the first dependency in the workspace from `baikai-agent` onto
the provider packages, and it exists solely so the executable can dispatch on provider.

Then add the executable stanza, following the pattern of the two executables in
`baikai/baikai.cabal`:

```cabal
executable baikai
  import:         common-options
  hs-source-dirs: app
  main-is:        Main.hs
  build-depends:
    , baikai
    , baikai-agent
    , base
    , optparse-applicative
    , text
```

Keep the executable thin. Everything real goes in `Baikai.Agent.Cli` so tests can reach it.

Create `baikai-agent/src/Baikai/Agent/Cli.hs`. Define the option and result types:

```haskell
data AgentCliCommand
  = AgentRun !Text !PromptSource
  | AgentShow !Text
  | AgentList
  deriving stock (Eq, Show, Generic)

data PromptSource
  = PromptStdin
  | PromptFile !FilePath
  | PromptInline !Text
  deriving stock (Eq, Show, Generic)

data AgentCliOptions = AgentCliOptions
  { command :: !AgentCliCommand,
    overrides :: ![CliOverride],
    userConfig :: !(Maybe FilePath),
    repoConfig :: !(Maybe FilePath),
    jsonOutput :: !Bool
  }
  deriving stock (Generic)

data AgentCliRun = AgentCliRun
  { exitCode :: !Int,
    standardOutput :: !Text,
    standardError :: !Text
  }
  deriving stock (Eq, Show, Generic)
```

`AgentCliRun` is the testability move: the whole command-line surface becomes a function returning
this record, and the executable's job is only to print the two fields and exit with the code. Note
that in `agent run` with an inherited output mode, the agent's output does not pass through this
record at all — it goes straight to the real streams — so document that `standardOutput` here means
*Baikai's* output, not the agent's.

Define the exit codes as named constants with Haddock comments, following the `sysexits` convention
so the numbers are not arbitrary:

```haskell
usageExitCode      = 64  -- command line could not be parsed
configExitCode     = 78  -- configuration file missing, unreadable, or invalid
refusedExitCode    = 77  -- policy refused: ceiling exceeded, or provider cannot express it
unavailableExitCode = 69 -- the coding-agent executable could not be started
timeoutExitCode    = 75  -- the run exceeded its timeout and was terminated
```

Write the parser with `hsubparser` and `command`, following
`baikai-kit/src/Baikai/Kit/Command.hs`. The top level takes one subcommand group, `agent`, which
itself takes `run`, `show`, and `list`. Attach `Options.failureCode usageExitCode` to the
`ParserInfo` so a usage error exits 64 rather than `optparse-applicative`'s default of 1 — otherwise
a typo in a flag would be indistinguishable from an agent that exited 1.

For `--set`, use `overrideOptions` from `Settei.Optparse` rather than writing your own. For
`--user-config` and `--config`, plain `strOption`s. For prompt selection, make `--prompt-stdin`,
`--prompt-file`, and `--prompt` mutually exclusive alternatives so supplying two is a usage error
rather than a silent precedence puzzle.

Implement `runAgentCli :: EnvSnapshot -> AgentCliOptions -> IO AgentCliRun` with only the `AgentList`
branch working for now, and stub the others. Write `baikai-agent/app/Main.hs` following
`examples/settei-cli/app/Main.hs`: parse, run, print `standardOutput` to real standard output, print
`standardError` to real standard error, and exit with the code.

Verify:

```bash
cabal build baikai-agent
cabal run baikai -- --help
cabal run baikai -- agent list
```

In a directory with no job file, `agent list` should report no configured jobs and exit 0. An empty
list is not an error.

### Milestone 2 — Provider dispatch

Scope: implement the single function that turns a resolved job into a rendered command. At the end of
this milestone the dispatch exists and is unit-tested; it is the only place in the codebase that
knows both providers.

```haskell
renderJobCommand :: AgentJob -> AgentRunRequest -> Either AgentRenderError AgentCommand
renderJobCommand job request = case request ^. #provider of
  AgentClaude -> claudeAgentCommand (claudeConfigFor job) request
  AgentCodex -> codexAgentCommand (codexConfigFor job) request
```

The two helpers apply the job's optional executable override onto the vendor default:

```haskell
claudeConfigFor job =
  maybe defaultClaudeAgentConfig
    (\exe -> defaultClaudeAgentConfig { executable = exe })
    (job ^. #executable)
```

Keep this dispatch in exactly one place. It is the answer to the improvement request's first
acceptance criterion — that a script select Claude Code or Codex entirely through configuration —
and if provider knowledge spreads to a second site, adding a third provider later becomes a hunt.

Note that `renderJobCommand` takes both the job and the request even though the request came from the
job. The request is what the renderers consume; the job carries the executable override, which the
request has no field for because it is a configuration concern rather than a run description. Say so
in a comment, because the redundancy looks like an accident.

Unit-test it: a job with `provider = AgentClaude` renders a vector beginning with `-p`, a job with
`AgentCodex` renders one beginning with `exec`, and a job with an executable override renders that
path as the executable.

### Milestone 3 — `agent show` and `agent list`

Scope: implement the two commands that never spawn anything. At the end of this milestone an operator
can inspect a job completely without running it, which is the improvement request's acceptance
criterion 5.

`agent list` loads `listAgentJobs` and prints one line per job: the name and the scope it came from,
rendered from the `SourceKind`. Sort by name — `listAgentJobs` already does — so output is stable
enough to diff. On a configuration error, print the rendered error to standard error and exit
`configExitCode`.

`agent show` is the more valuable command and needs care. Perform the whole pipeline **except**
spawning:

1. Resolve the job with `resolveAgentJob`. On a `Left`, print the rendered configuration error and
   exit `configExitCode`. On a `Right` whose `answer` is `Left`, print `renderErrorsText` of the
   resolution errors — and, because this is an explain command, also print `renderResolutionText` of
   the report, since a failed resolution's provenance is exactly what the operator needs. `settei`
   retains a report on failure specifically so this is possible.
2. Print the effective configuration with `renderResolutionText`, or `renderResolutionJson` when
   `--json` was given. This is where every value's scope and file position comes from, and it is
   where raw provider arguments appear as `<redacted>`, because
   `docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` declared that
   setting secret.
3. Load the ceiling with `loadAgentCeiling` and print it, including which file it came from or that
   it is the built-in default. An operator reading `show` needs to know what is capping the job, not
   only what the job asked for.
4. Convert to a request with `agentJobRequest job placeholderPrompt`. Use a clearly artificial
   placeholder such as `"<prompt supplied at run time>"` and label it as such in the output, so
   nobody mistakes it for a configured value. `show` takes no prompt.
5. Apply the ceiling with `applyCeilingToJob`. On refusal, print the rendered `AgentRenderError` and
   exit `refusedExitCode` — after having printed the configuration, so the operator sees both what
   was asked for and why it was refused.
6. Render with `renderJobCommand`. On refusal, same treatment.
7. Print the rendered command as the executable followed by its arguments, one per line or
   shell-quoted on one line — pick one and be consistent. Also print the prompt transport, because
   "the prompt goes on standard input" is not visible in the argument vector and an operator
   comparing against their old hand-written command will wonder where it went.

Print any `warnings` from the resolve result to standard error. `settei`'s default
`ResolveOptions` warns on unknown keys, which is how an operator learns they misspelled a setting
name that would otherwise be silently ignored.

Exit 0 when nothing was refused.

Test both commands through `runAgentCli` with `AgentConfigPaths` pointing at temporary files. Assert
that `show` output contains the job's provider, a file path with a line number, the rendered
argument vector, and — for a job with raw provider arguments — `<redacted>` and not the argument
value.

### Milestone 4 — `agent run`

Scope: implement execution, prompt sources, exit codes, and stream discipline. At the end of this
milestone a job actually runs.

Reuse Milestone 3's pipeline through step 6, then read the prompt and execute.

Read the prompt from its source. `PromptStdin` reads all of standard input as UTF-8;
`PromptFile` reads the named file; `PromptInline` uses the given text. Read standard input as bytes
and decode explicitly with `Data.Text.Encoding.decodeUtf8`, rather than using `getContents`, whose
behavior depends on the handle's locale encoding — the motivating script's prompt contains
interpolated paths and could contain any character, and a locale-dependent read would corrupt it on
a machine without a UTF-8 locale.

Reject an empty prompt with `usageExitCode` and a message saying which source was empty. A coding
agent given an empty prompt does something unpredictable and expensive; failing fast is kinder. Note
that `--prompt-stdin` with no piped input is the most likely way to hit this, typically a script bug.

Convert with `agentJobRequest job promptText`, apply the ceiling, render, and call `runAgentCommand`.

Interpret the outcome:

```text
Right result, exitCode ExitSuccess       -> exit 0
Right result, exitCode ExitFailure n     -> exit n   (the agent's own code, passed through)
Left (RunTimedOut _)                     -> exit 75
Left (SpawnFailed _ _)                   -> exit 69
Left (WorkingDirMissing _)               -> exit 78
Left (MissingEnvironment _)              -> exit 78
Left (OutputMalformed _)                 -> exit 70
```

Print the rendered `AgentRunFailure` to standard error in every `Left` case. On the pass-through
path, print nothing extra: a script that got exit 3 from the agent does not need Baikai narrating
it, and the agent has already explained itself on its own standard error.

Stream discipline is the part a script depends on. Baikai's own messages — progress, warnings,
errors — always go to standard error. The agent's output follows the job's configured output mode:
with `inherit` it goes straight to Baikai's own real streams and never enters `AgentCliRun`; with
`capture` Baikai holds it and writes the captured standard output to standard output on success; with
`tee` both happen. This is what makes `response=$(baikai agent run job)` yield only the agent's
answer for a capturing job, while a human watching still sees diagnostics.

There is a subtlety in `inherit` mode worth a comment. Because the child inherits Baikai's real
streams directly, its output bypasses `AgentCliRun` entirely, so a test cannot capture it by
inspecting the record. That is correct and intended — it is what the motivating script wants — and
it is why Milestone 5's fixture test uses `capture` mode to observe what the fake executable
received, while a separate case checks that `inherit` produces no captured bytes.

When output was truncated at the byte limit, say so on standard error. A silently truncated response
that a script then parses is a bug waiting to happen.

### Milestone 5 — The end-to-end fixture proof

Scope: prove the motivating launch works, end to end, against a fake executable. At the end of this
milestone the initiative's central acceptance criterion is demonstrated by a test.

This is the most important milestone in the plan. Everything else is machinery; this is the evidence.

Build the fixture in the `baikai-agent` test suite. Both
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` and
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` established
temporary-directory harnesses in this suite — one for fake executables, one for KDL files. Combine
them.

Write a fake `claude` that records what it received and then behaves like a coding agent:

```sh
#!/bin/sh
# Fake claude for testing. Records argv and stdin, then reports success.
printf '%s\n' "$@" > "$FAKE_CLAUDE_ARGV"
cat > "$FAKE_CLAUDE_STDIN"
echo "reconciled the lexical surface"
```

Pass the two output paths through the environment, and give the job an `env-requires` entry for them
so the run also exercises the environment precondition check. Make the script executable with
`getPermissions` and `setOwnerExecutable`, as `baikai-claude/test/Main.hs` already does.

Write the job file, which is the translation of the motivating script's launch:

```kdl
jobs {
  sync-keiro-dsl {
    provider    "claude"
    working-dir "/tmp/…/repo"
    executable  "/tmp/…/claude"
    extra-dirs  "/tmp/…/keiro"
    output      "capture"
    safety {
      capability    "edit-workspace"
      allowed-tools "Read" "Write" "Edit" "Glob" "Grep" "Bash" "Skill" "TodoWrite"
    }
  }
}
```

Note that the real consumer would use `inherit`, and the guide in Milestone 6 shows it that way;
this fixture uses `capture` so the test can observe the output. Add a comment in the test saying so,
and a separate small case asserting `inherit` yields `OutputNotCaptured`, so the difference is
covered rather than papered over.

Then drive `runAgentCli` with `AgentRun "sync-keiro-dsl" PromptStdin`. Standard input cannot be
piped in-process, so make the prompt source injectable for tests — either pass the prompt reader as a
parameter to `runAgentCli` or use `PromptFile` pointing at a temporary file holding the prompt, and
add a separate narrow test for the standard-input reader itself. Choose one, and record the choice in
the Decision Log; the second is simpler and keeps `runAgentCli` free of a function parameter.

Assert five things, which together are the acceptance criterion:

The recorded argument vector is exactly what the Claude renderer promises for this policy:
`-p`, `--no-session-persistence`, `--permission-mode acceptEdits`,
`--allowedTools Read,Write,Edit,Glob,Grep,Bash,Skill,TodoWrite`, and `--add-dir` with the extra
directory. Compare the whole vector, not individual members.

The recorded standard input is exactly the prompt, byte for byte. Use a multi-line prompt containing
a dash-leading line and a non-ASCII character, since the motivating script's prompt is multi-line and
the transport decision exists to make that safe.

The exit code is 0 and the captured standard output contains the fake's message.

No Claude-specific flag appears anywhere in the *test's* own invocation — only in the job file. This
is the criterion "the launch can be represented without embedding Claude-specific flags in that
script", and asserting it in the test's structure rather than its assertions means keeping the
invocation to the job name plus `--set`.

Then add the provider-swap test, which proves the initiative's headline claim. Change **only** the
`provider` line in the job file to `codex`, point `executable` at a fake `codex`, remove the
`allowed-tools` line, and assert the run succeeds with a Codex-shaped argument vector containing
`exec`, `--sandbox workspace-write`, and `--cd`. Removing `allowed-tools` is required, because
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md` makes Codex refuse a tool
allow-list — so also add a case that **keeps** the tool list and asserts the run is refused with
`refusedExitCode` and a message naming the sandbox alternative. That pair is the honest version of
"switching providers is a configuration change": it is, and where it is not, you are told loudly
rather than silently given weaker isolation.

Finally add a ceiling-refusal end-to-end case: a job file asking for `full-access` with no user
policy file, asserting `refusedExitCode` and a message naming both the requested and permitted
capability, and asserting the fake executable was **never invoked** — check that its argv record file
does not exist. That last assertion is what proves refusal happens before process creation, which is
improvement-request acceptance criterion 6.

### Milestone 6 — Documentation and the migration guide

Scope: write the user guide and show the motivating consumer exactly how to migrate. At the end of
this milestone a reader who has never seen this initiative can configure and run a job.

`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` created
`docs/user/unattended-agent-runs.md` with the file-format, precedence, ceiling, and redaction
sections. Add the command-line half around them.

An opening that says what this surface is and, crucially, what it is not. Baikai has three surfaces
that involve a coding-agent binary and a reader landing here needs one paragraph distinguishing
them: batch completions through `claude -p` and `codex exec` that return a response value,
interactive launches that hand over a terminal, and unattended runs that mutate an authorized working
tree and return a process result. Link `docs/user/cli-providers.md` and
`docs/user/interactive-launches.md`, and add reciprocal links from both of those files pointing here
— a reader who starts on either of the other two pages should discover this one.

A quick-start showing a minimal job file and the three commands, with real output.

A reference for each command: its flags, what it prints on which stream, and its exit codes. Present
the exit-code table in full and state plainly that the agent's own code passes through while
Baikai's failures use 64 and above — including the documented ambiguity if a provider ever exits in
that range.

A section on stream discipline, explaining the three output modes and which one a script should pick:
`inherit` when the script's log is the terminal, `capture` when the script wants
`response=$(…)`, `tee` when it wants both.

The capability mapping tables from
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md`, if that plan put them in
`docs/user/interactive-launches.md`, should be linked or moved here — this is now their natural home.
State the Claude read-only caveat (plan mode is the closest available mode and also frames the task
as planning), the Codex tool-allow-list refusal, and that `--add-dir` grants tool access on Claude
and write access on Codex.

Then the migration guide, which is what the motivating consumer needs. Show the before and after
side by side. Before:

```bash
claude -p "$prompt" \
  --add-dir "$keiro_path" \
  --permission-mode acceptEdits \
  --allowedTools Read Write Edit Glob Grep Bash Skill TodoWrite \
  || die "agent run failed"
```

After, in `.baikai/agents.kdl`:

```kdl
jobs {
  sync-keiro-dsl {
    provider    "claude"
    working-dir "."
    output      "inherit"
    safety {
      capability    "edit-workspace"
      allowed-tools "Read" "Write" "Edit" "Glob" "Grep" "Bash" "Skill" "TodoWrite"
    }
  }
}
```

and in the script:

```bash
printf '%s' "$prompt" | baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --set extra-dir="$keiro_path" \
  || die "agent run failed"
```

Explain what each part of the translation does, note that `|| die` still works because the exit code
propagates, and note that the extra directory stays on the command line because it is computed at run
time from a registry lookup while everything else is static. Say explicitly that the script keeps
owning its lock, its dirty-tree check, its test gate, its marker file, and its commit — the
improvement request puts moving those out of scope, and a reader should not infer that this command
wants to absorb them.

Update the root `README.md`: add `baikai-agent` and the `baikai` executable to its package list and
mention the third surface in its highlights.

### Milestone 7 — Release coordination and closing the improvement request

Scope: run the coordinated release, record the initiative as done, and validate. At the end of this
milestone every affected package is released and the improvement request is closed.

Read `agents/skills/release/SKILL.md` in full first. This is the largest release this repository has
done and getting the order wrong means a published package that cannot build.

Work out the version set. Verify each against the actual in-tree value rather than trusting this
list, which was written before implementation:

```text
baikai          0.4.1.0 -> 0.5.0.0  (new Baikai.Agent module; take a major for a new
                                     public surface even though additions are minor by PVP,
                                     and confirm whether any existing export changed)
baikai-claude   0.4.0.0 -> 0.5.0.0  (MAJOR: interactive launcher signatures changed)
baikai-openai   0.4.0.0 -> 0.5.0.0  (MAJOR: interactive launcher signatures changed)
baikai-agent            -> 0.1.0.0  (new package, first release)
baikai-trace-otel       -> patch    (baikai bound only)
baikai-effectful        -> patch    (baikai bound only)
baikai-kit              -> patch    (baikai bound only)
baikai-smoke            -> none     (internal, never published)
```

The provider-package majors come from
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`, which changed four exported
function types. Whether `baikai` itself needs a major depends on whether anything existing changed
or only additions were made; check, and record the reasoning rather than guessing.

Update every internal dependency bound. `baikai-claude`, `baikai-openai`, `baikai-trace-otel`,
`baikai-effectful`, and `baikai-kit` all carry a `baikai ^>=` bound that must move, and
`baikai-agent` carries bounds on `baikai` and both provider packages. The release skill's pre-flight
check requires confirming these.

Publish in dependency order: `baikai` first, then the two provider packages, then
`baikai-trace-otel`, `baikai-effectful`, and `baikai-kit`, then `baikai-agent` last because it
depends on all three of the first group. Do not publish a dependent after an upstream upload fails.

Move the `[Unreleased]` changelog bullets into dated version sections, which is the release
workflow's job and not something feature plans do.

Close the improvement request. Edit
`docs/improvement-requests/add-configurable-cli-for-unattended-coding-agent-runs.md`: change
`status: proposed` to the repository's terminal status, add an entry to its `reviews:` list recording
that the request was reviewed and accepted with corrections, and add a line pointing at
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md` as the accepted
design. Record the corrections the review found, because the request as written contained factual
errors a future reader should not inherit: `codex exec` has no `--ask-for-approval` flag, so approval
is not part of the shared vocabulary; the illustrative result record's plain `ByteString` output
fields could not represent inherited output; and `--add-dir` does not mean the same thing on both
providers. Also add a line to `docs/improvement-requests/log.md` under a dated heading.

Complete the parent MasterPlan
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: set EP-6 to
`Complete`, check off the remaining Progress lines, and write the Outcomes & Retrospective section.
Compare the result against the Vision & Scope honestly — including anything that did not land, any
place where "provider-neutral" turned out to be thinner than hoped, and the fact that migrating
`shinzui/keiro-syntax` remains a separate change in that repository.

Then run the full validation.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, unless stated
otherwise.

After Milestone 1:

```bash
cabal build baikai-agent
cabal run baikai -- --help
cabal run baikai -- agent list
```

After Milestones 2 through 5:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

To exercise the whole surface by hand against a fake executable — no model, no cost — set up a
sandbox:

```bash
mkdir -p /tmp/baikai-demo/.baikai
cat > /tmp/baikai-demo/fake-claude <<'SH'
#!/bin/sh
printf 'argv: %s\n' "$*" >&2
cat
SH
chmod +x /tmp/baikai-demo/fake-claude
cat > /tmp/baikai-demo/.baikai/agents.kdl <<'KDL'
jobs {
  demo {
    provider    "claude"
    working-dir "/tmp/baikai-demo"
    executable  "/tmp/baikai-demo/fake-claude"
    output      "capture"
    timeout     "5m"
    safety {
      capability    "edit-workspace"
      allowed-tools "Read" "Edit"
    }
  }
}
KDL
cd /tmp/baikai-demo
```

Inspect without running:

```bash
cabal run --project-dir /Users/shinzui/Keikaku/bokuno/baikai baikai -- agent show demo
```

Expected shape — the per-key listing comes from `settei`, so exact formatting follows its renderer:

```text
effective configuration for job "demo"
  jobs.demo.provider              claude           /tmp/baikai-demo/.baikai/agents.kdl:3:5 (file)
  jobs.demo.working-dir           /tmp/baikai-demo /tmp/baikai-demo/.baikai/agents.kdl:4:5 (file)
  jobs.demo.output                capture          /tmp/baikai-demo/.baikai/agents.kdl:6:5 (file)
  jobs.demo.output-limit          4194304          built-in defaults
  jobs.demo.safety.capability     edit-workspace   /tmp/baikai-demo/.baikai/agents.kdl:9:7 (file)

policy ceiling: built-in default
  max-capability       edit-workspace
  allow-provider-args  false
  allowed-providers    claude, codex

rendered command
  /tmp/baikai-demo/fake-claude
    -p
    --no-session-persistence
    --permission-mode acceptEdits
    --allowedTools Read,Edit
  prompt transport: standard input
```

Then run it:

```bash
printf 'reconcile the grammar' | cabal run --project-dir /Users/shinzui/Keikaku/bokuno/baikai baikai -- agent run demo --prompt-stdin
echo "exit: $?"
```

Expected: the fake's `argv:` line on standard error, `reconcile the grammar` on standard output
because the fake `cat`s its input and the job captures, and `exit: 0`.

Now prove the ceiling refuses before spawning:

```bash
sed -i '' 's/"edit-workspace"/"full-access"/' /tmp/baikai-demo/.baikai/agents.kdl
printf 'x' | cabal run --project-dir /Users/shinzui/Keikaku/bokuno/baikai baikai -- agent run demo --prompt-stdin
echo "exit: $?"
```

Expected: a message on standard error naming `full-access` and the permitted `edit-workspace`,
`exit: 77`, and **no** `argv:` line — because the fake was never started.

Clean up:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
rm -rf /tmp/baikai-demo
```

Full validation after Milestone 7. Two independent gates cause the `baikai-smoke` suite to make real
billable calls and both must be closed: provider API-key environment variables, and — as discovered
during the work recorded in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md` — the mere presence of
the `claude` or `codex` binary on `PATH`, because `baikai-smoke/test/Smoke.hs` gates its batch CLI
cases on `findExecutable` alone. This `zsh` command closes both while keeping the active toolchain:

```zsh
nix fmt
git diff --check
cabal build all
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
nix flake check
```

Two hazards specific to this plan. Your tests must not depend on the real `HOME` or
`XDG_CONFIG_HOME`, because a developer with a real `~/.config/baikai/agents.kdl` would get different
results from a clean machine — construct `AgentConfigPaths` explicitly everywhere. And your tests
must not depend on the current working directory for repository-configuration discovery, since the
test runner's working directory is not a repository with a job file.

Commit in pieces, then release:

```text
feat(agent): ship the baikai agent CLI

Add the baikai executable with agent run, show, and list. Provider
selection, permissions, paths, and limits come from configuration; the
agent's exit code propagates and Baikai's own failures use codes 64 and
above.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```

```text
test(agent): prove the sync-keiro-dsl launch end to end

Drive the CLI against a fake claude executable and a real job file,
asserting the recorded argv and stdin. Swapping the provider to codex is
a one-line config change; keeping a tool allow-list there is refused
before any process starts.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan, and with it the whole initiative, is accepted when all of the following hold. The first
seven restate the improvement request's own acceptance criteria.

**One.** A shell script invokes one stable command with a prompt and selects Claude Code or Codex
entirely through configuration. Demonstrated by the provider-swap test, where changing only the
`provider` line in a KDL file moves the run from one tool to the other.

**Two.** The `sync-keiro-dsl.sh` launch is representable without Claude-specific flags in the script,
including its extra source directory, its edit permission mode, and its tool allow-list. Demonstrated
by the fixture test, whose invocation names only a job and one `--set`, and whose recorded argument
vector contains all three.

**Three.** Pure command-rendering tests prove the Claude and Codex argument vectors, including
prompts and paths beginning with a dash. Delivered by
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md`; confirm those tests still pass.

**Four.** Integration tests use fake executables to prove standard-input, standard-output, and
standard-error handling, working-directory selection, timeout, non-zero exit, and redaction, without
invoking a live model. Delivered across
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md`,
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`, and this plan's
Milestone 5.

**Five.** An effective-configuration command identifies every selected value's scope and renders no
secret material. `agent show` prints each value with its source kind, file path, and line number, and
prints `<redacted>` for raw provider arguments.

**Six.** Unsupported safety mappings fail before process creation. The ceiling-refusal end-to-end
case asserts the fake executable's record file does not exist after a refused run.

**Seven.** Existing API providers, batch completion providers, and interactive launchers remain
source-compatible — with one deliberate, documented exception: the interactive launchers' return
types changed in
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` to repair a silent safety
downgrade. That is a knowing violation of the original criterion, approved at MasterPlan level and
carried as a major version bump. API providers and batch completion providers are untouched.

Beyond those: `cabal run baikai -- agent list` exits 0 and reports nothing when no configuration
exists. `agent show` exits 0 for a valid job, `configExitCode` for a bad file, and `refusedExitCode`
for a capped or inexpressible policy — printing the configuration before the refusal in the last
case. `agent run` propagates the agent's exit code, maps a timeout to 75, a spawn failure to 69, and
a configuration problem to 78, and prints every Baikai diagnostic to standard error. An empty prompt
is a usage error. Supplying two prompt sources is a usage error. Truncated output is announced on
standard error.

`docs/user/unattended-agent-runs.md` documents all three commands, the exit-code table with its
documented ambiguity, stream discipline, the capability mapping tables with the Claude plan-mode
caveat and the Codex tool-allow-list refusal, and the migration guide with a before-and-after for the
motivating script. `docs/user/cli-providers.md` and `docs/user/interactive-launches.md` both link
here. The root `README.md` lists the new package and executable.

Every package is released in dependency order with correct bounds; `baikai-agent` publishes last. The
improvement request's status is terminal, its `reviews:` list records the acceptance and the three
factual corrections, and `docs/improvement-requests/log.md` has a dated entry. The parent MasterPlan
shows all six plans complete and its Outcomes & Retrospective is written.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`, and
`nix flake check` all succeed. No acceptance step invokes a live model or a real coding-agent binary.


## Idempotence and Recovery

Milestones 1 through 6 are additive within `baikai-agent` plus documentation, so the rest of the
workspace cannot break and all commands are repeatable. Tests write only into temporary directories
that are removed even on failure. The manual demonstration writes under `/tmp/baikai-demo`; remove it
when finished.

Milestone 7 is the exception and is **not** idempotent. Publishing to Hackage cannot be undone: a
version number, once uploaded, is permanent. Follow `agents/skills/release/SKILL.md` exactly, use
`cabal upload` without `--publish` first to check the candidate, and stop the whole release if any
upload fails rather than publishing a dependent against a version that is not there. If you must
correct a published mistake, the only remedy is a new version.

Because of that, treat Milestone 7 as a separate session from Milestones 1 through 6. Everything
before it is complete, testable, and useful in-tree without any release having happened; a consumer
can depend on the workspace through a source-repository pin in the meantime.

To roll back the code, revert the commits and remove the executable stanza. If a release has already
happened, rolling back the code does not roll back the published packages — note the situation in the
Progress section and ship a corrected version rather than trying to unpublish.


## Interfaces and Dependencies

New dependencies in `baikai-agent/baikai-agent.cabal`: `baikai-claude` and `baikai-openai` in the
library stanza, so the dispatch can reach both renderers, and `optparse-applicative ^>=0.19` in both
the library and the new executable stanza. The version is the one `baikai-kit/baikai-kit.cabal`
already uses, keeping one `optparse-applicative` in the build plan. No dependency new to the
workspace is introduced.

New executable stanza `baikai`, with `hs-source-dirs: app` and `main-is: Main.hs`, kept deliberately
thin.

At completion, `baikai-agent/src/Baikai/Agent/Cli.hs` exports:

```haskell
data AgentCliCommand = AgentRun !Text !PromptSource | AgentShow !Text | AgentList
data PromptSource = PromptStdin | PromptFile !FilePath | PromptInline !Text
data AgentCliOptions = AgentCliOptions
  { command :: !AgentCliCommand, overrides :: ![CliOverride]
  , userConfig :: !(Maybe FilePath), repoConfig :: !(Maybe FilePath), jsonOutput :: !Bool }
data AgentCliRun = AgentCliRun
  { exitCode :: !Int, standardOutput :: !Text, standardError :: !Text }
  -- standardOutput is BAIKAI's output; an inherited-mode agent's output bypasses this record

agentCliParser     :: Parser AgentCliOptions
agentCliParserInfo :: ParserInfo AgentCliOptions
runAgentCli        :: EnvSnapshot -> AgentCliOptions -> IO AgentCliRun

-- The single provider dispatch point in the codebase
renderJobCommand :: AgentJob -> AgentRunRequest -> Either AgentRenderError AgentCommand

-- Named exit codes, sysexits convention
usageExitCode, configExitCode, refusedExitCode, unavailableExitCode, timeoutExitCode :: Int
```

The command-line contract, which the user guide documents:

```text
baikai agent run <job>  [--prompt-stdin | --prompt-file PATH | --prompt TEXT]
                        [--set KEY=VALUE ...] [--config PATH] [--user-config PATH] [--json]
baikai agent show <job> [--set KEY=VALUE ...] [--config PATH] [--user-config PATH] [--json]
baikai agent list       [--config PATH] [--user-config PATH] [--json]

exit code   meaning
0           the agent ran and exited 0
n (1..)     the agent ran and exited n, passed through unchanged
64          command line could not be parsed, or an empty/ambiguous prompt
69          the coding-agent executable could not be started
70          the agent produced malformed output
75          the run exceeded its timeout and its process group was terminated
77          policy refused: the ceiling was exceeded, or the provider cannot express it
78          configuration was missing, unreadable, or invalid

stream      content
stdout      agent output in capture and tee modes; agent show and agent list output
stderr      every Baikai diagnostic, warning, and error; agent output in inherit and tee modes
```

Downstream impact. This completes the initiative, so the release covers `baikai`, both provider
packages, the three bound-only dependents, and the new `baikai-agent`. Two external follow-ups
remain and are deliberately **not** part of this plan: the `shinzui/seihou` project must handle the
new `Either` from the interactive launchers before it can upgrade, and the `shinzui/keiro-syntax`
project can then replace its embedded `claude -p` invocation using the migration guide from
Milestone 6. Both are commits in their own repositories.
