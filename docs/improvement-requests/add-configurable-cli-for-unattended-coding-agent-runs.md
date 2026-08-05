---
type: Improvement Request
title: Add a configurable CLI for unattended coding-agent runs
description: Provide a provider-neutral command that lets automation invoke Claude Code or Codex with repository-scoped prompts, permissions, paths, and policy without embedding provider flags in shell scripts.
timestamp: "2026-07-29T20:38:55Z"
requestId: IR-1
status: completed
completedAt: "2026-08-05T00:00:00Z"
origin: mori://shinzui/keiro-syntax
targetPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
resolution: >-
  Implemented in mori://shinzui/baikai as the six ExecPlans of
  docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md. The
  provider-neutral vocabulary and the pure policy ceiling are Baikai.Agent in the core
  package; the argument-vector renderers are Baikai.Provider.Claude.Agent and
  Baikai.Provider.OpenAI.Agent; the process runner, the layered KDL configuration layer,
  and the baikai executable with agent run, show, and list are the new baikai-agent
  package. All seven acceptance criteria are demonstrated by tests that call no live
  model and require no coding-agent binary — see the per-criterion evidence in this
  document's Status section. Criterion 7 is met with one knowing, pre-approved
  exception: the interactive launchers' return types changed to repair a silent safety
  downgrade, carried as a major version bump on both provider packages. Two follow-ups
  are deliberately outside this request: the Hackage release of the affected packages,
  and migrating mori://shinzui/keiro-syntax's own scripts/sync-keiro-dsl.sh, which is a
  commit in that repository.
reviews:
  - kind: model
    reviewer: claude
    reviewed_at: 2026-07-30T05:14:54Z
    document_timestamp: 2026-07-29T20:38:55Z
    scope: technical-accuracy
    outcome: approved
    provider: anthropic
    model: claude-opus-5
    context: >-
      In-repository review at mori://shinzui/baikai against the batch, interactive, and
      agent-asset surfaces, the cradle dependency source, the settei package family, and the
      installed Claude Code 2.1.220 and codex-cli 0.146.0 help output. The central request is
      sound and the abstraction belongs in Baikai. Four corrections were carried into the
      accepted design: codex exec exposes no --ask-for-approval flag, so approval policy is not
      part of the shared unattended vocabulary; the illustrative AgentRunResult ByteString
      output fields cannot represent the inherited output mode the same request allows; --add-dir
      grants tool access on Claude Code but write access on codex exec, so extraDirs is not
      fully provider-neutral; and the existing interactive launchers already violate the
      fail-visibly safety requirement this request introduces, which the design repairs rather
      than documents. The accepted design is
      docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md.
---

# Improvement Request: Add a configurable CLI for unattended coding-agent runs

## Status

- **Status:** completed — built, tested, and documented in `shinzui/baikai` on 2026-08-05
- **Origin:** `shinzui/keiro-syntax`, whose `scripts/sync-keiro-dsl.sh` currently embeds a direct `claude -p` invocation
- **Owner of the build:** `shinzui/baikai`
- **Size:** additive but architectural: one unattended-agent request/result contract, vendor renderers, a configuration layer, and a companion executable
- **Accepted design:** `docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`, which decomposes the build into six ExecPlans (`docs/plans/45` through `docs/plans/50`)

### What was built

| Piece | Where it lives | ExecPlan |
|-------|----------------|----------|
| Provider-neutral request, result, capability profile, and the pure policy ceiling | `baikai/src/Baikai/Agent.hs` | `docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` |
| Claude and Codex argument-vector renderers | `baikai-claude/src/Baikai/Provider/Claude/Agent.hs`, `baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs` | `docs/plans/46-render-claude-and-codex-unattended-agent-commands.md` |
| Repair of the interactive launchers' silent safety downgrade | both `…/Interactive.hs` modules | `docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` |
| The `baikai-agent` package and the unattended process runner | `baikai-agent/src/Baikai/Agent/Run.hs` | `docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` |
| Layered KDL configuration with per-value provenance and the operator ceiling | `baikai-agent/src/Baikai/Agent/Config.hs` | `docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` |
| The `baikai` executable: `agent run`, `agent show`, `agent list` | `baikai-agent/src/Baikai/Agent/Cli.hs`, `baikai-agent/app/Main.hs` | `docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` |

The user-facing guide is `docs/user/unattended-agent-runs.md`, which documents the job
format, layer precedence, the ceiling, the three commands with their exit codes and
stream discipline, the capability mapping tables, and a before-and-after migration of
the launch that motivated this request.

### How each acceptance criterion was met

Every item below is proved by a test that calls no live model and requires no
coding-agent binary. The fixtures are `sh` scripts written into temporary directories.

1. **One stable command, provider by configuration.** `baikai agent run <job>`. Proved by
   the provider-swap test in `baikai-agent/test/CliTests.hs`, where changing only the
   `provider` line in a KDL file moves the run from `claude` to `codex`.
2. **The `sync-keiro-dsl.sh` launch is representable without Claude flags.** Proved by the
   fixture test whose invocation names only a job and one `--set extra-dirs=…`, and whose
   recorded argument vector contains `--permission-mode acceptEdits`, the full
   `--allowedTools` list, and `--add-dir`.
3. **Pure command-rendering tests, including dash-leading prompts and paths.** In the two
   vendor test suites. Both renderers deliver the prompt on standard input, so a
   dash-leading prompt cannot be parsed as a flag at all.
4. **Fake-executable integration tests.** Across the `baikai-agent` suite: prompt
   round-trip on standard input, stream separation, working-directory selection, timeout
   with process-group termination, non-zero exit pass-through, spawn failure, output
   truncation, and redaction.
5. **An effective-configuration command that renders no secret material.** `baikai agent
   show` prints every value with its file, line, and column, and `<redacted>` for raw
   provider arguments — in the configuration listing *and* in the rendered argument
   vector.
6. **Unsupported safety mappings fail before process creation.** Proved by asserting that
   the fake executable's record file does not exist after a refused run.
7. **Existing surfaces remain source-compatible**, with one knowing exception recorded in
   the review below: the interactive launchers now return `Either`, repairing a silent
   safety downgrade, at the cost of a major version bump on both provider packages. API
   providers and batch completion providers are untouched.

### What remains, outside this request

Publishing the affected packages to Hackage is a release step rather than an acceptance
criterion, and has not happened yet; consumers can depend on the workspace through a
source-repository pin in the meantime. Migrating
`mori://shinzui/keiro-syntax`'s own `scripts/sync-keiro-dsl.sh` to the new command is a
commit in that repository, following the migration guide in
`docs/user/unattended-agent-runs.md`. Adapting `mori://shinzui/seihou`, whose
`Seihou.CLI.AgentLaunchExec` builds interactive launch requests, to the launchers' new
`Either` return is likewise a commit in that repository.

The review recorded in this document's frontmatter approves the request and corrects four
factual points in it. Where this document and the MasterPlan disagree, the MasterPlan wins; its
Decision Log records why. The corrections: `codex exec` exposes no `--ask-for-approval` flag, so
approval policy is not part of the shared unattended vocabulary and any approval intent travels
as an explicit provider argument; the illustrative `AgentRunResult` `ByteString` output fields
cannot represent the inherited output mode this document also asks for, so the accepted design
models captured output as a three-state value; `--add-dir` grants tool access on Claude Code but
write access on `codex exec`, so `extraDirs` carries provider-dependent authority; and the
existing interactive launchers already violate the fail-visibly safety requirement introduced
here, which the accepted design repairs — knowingly relaxing acceptance criterion 7 for those
two launchers, at the cost of a major version bump on both provider packages.

## Problem

Baikai already abstracts API completions, batch calls through `claude -p` and
`codex exec`, and interactive terminal launches. It does not provide a command
that shell automation can call through a stable, provider-neutral contract.
Consumers must either write a Haskell executable or embed provider flags directly
in each script.

`shinzui/keiro-syntax/scripts/sync-keiro-dsl.sh` demonstrates the gap. Its
deterministic workflow resolves a source repository and commit, prevents
concurrent or dirty-tree execution, constructs a task prompt, runs the syntax
test suites, updates a sync marker, and commits the result. Only the agent launch
is provider-specific:

```bash
claude -p "$prompt" \
  --add-dir "$keiro_path" \
  --permission-mode acceptEdits \
  --allowedTools Read Write Edit Glob Grep Bash Skill TodoWrite
```

Those flags mix four concerns that Baikai is positioned to normalize:

- selection of Claude Code or Codex;
- the executable, model, and reasoning effort;
- working and additional readable directories;
- unattended safety and permission policy.

The existing batch provider is close but not a complete scripting surface. Its
configuration is supplied as Haskell records, arbitrary provider arguments remain
the principal escape hatch, and no shipped executable loads a repository-owned
job definition. The interactive launcher models structured safety and additional
directories, but inherits a terminal and is intentionally aimed at human-driven
sessions. Neither surface is the contract needed by unattended automation that
expects the coding agent to own its internal tool loop and edit the working tree.

Without a shared command, scripts reproduce authentication assumptions, provider
flags, error handling, output capture, permission spelling, and migration logic.
Changing from Claude Code to Codex is therefore a rewrite rather than a
configuration change.

## Request

Add a distinct **unattended coding-agent run** abstraction to Baikai and expose it
through a companion CLI. The exact package and executable names may follow the
repository's package conventions; illustrative names are `baikai-agent` for the
library contract and `baikai-cli` with an `agent run` subcommand for the shell
surface.

The command should let a script invoke a named, repository-configured job while
supplying the prompt through standard input or a file:

```bash
baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --set extra-dir="$keiro_path"
```

The job configuration should cover, with structured fields where semantics can
be shared safely:

- provider (`claude` or `codex`) and executable override;
- optional model and reasoning effort;
- working directory and additional readable directories;
- a permission profile or structured provider-neutral safety policy;
- provider-specific arguments as an explicit escape hatch;
- environment-variable references without embedding secret values;
- timeout, output limits, and whether stdout/stderr are inherited, captured, or
  streamed;
- prompt source, with run-specific values able to override repository defaults.

Configuration precedence must be documented and deterministic. A suitable order
is built-in defaults, user configuration, repository configuration, environment,
then explicit CLI flags. The selected effective configuration should be
inspectable without launching an agent, with secrets redacted.

## Library contract

The library layer should represent the operation independently of the CLI parser.
Conceptually it needs:

```haskell
data AgentRunRequest = AgentRunRequest
  { provider :: AgentProvider
  , prompt :: Text
  , model :: Maybe Text
  , effort :: Maybe ThinkingLevel
  , workingDir :: FilePath
  , extraDirs :: [FilePath]
  , safety :: AgentSafety
  , extraArgs :: [Text]
  , timeout :: Maybe NominalDiffTime
  }

data AgentRunResult = AgentRunResult
  { provider :: AgentProvider
  , exitCode :: ExitCode
  , stdout :: ByteString
  , stderr :: ByteString
  , duration :: NominalDiffTime
  }
```

The spelling is illustrative. The important distinction is semantic: this is not
a normal Baikai completion returning a `Response`, and it is not an interactive
terminal session. It is an unattended coding-agent process that may perform an
internal tool loop and mutate the explicitly authorized working tree before
returning a process result.

Provider packages should own translation from the shared request into native
arguments. Claude Code may render `--permission-mode`, `--allowedTools`, and
`--add-dir`; Codex may render its sandbox, approval, `--cd`, and `--add-dir`
arguments. Unsupported shared policy must fail visibly rather than silently
downgrade to a weaker policy.

## Safety requirements

This command is intended for automation that can modify repositories, so its
default and override behavior are part of the API contract:

1. Default to no broader filesystem authority than the selected working directory
   and explicit extra directories.
2. Never infer an unrestricted permission mode from arbitrary provider arguments.
3. Reject contradictory structured safety fields and raw arguments, or define and
   display an unambiguous precedence rule.
4. Redact secret values from diagnostics, effective-configuration output, and
   persisted traces.
5. Preserve provider stderr and distinguish spawn failure, timeout, provider
   rejection, malformed output, and non-zero process exit.
6. Render commands as executable plus argument vectors, never through a shell
   string; protect dash-leading prompts with the provider's supported separator or
   stdin transport.

Repository configuration is untrusted input when an automation daemon encounters
a checkout. User-level policy must be able to cap, rather than merely default,
the permissions a repository job may request. Raw provider arguments that can
weaken sandboxing or approvals should require an explicit user-level opt-in.

## CLI behavior

At minimum the companion CLI should provide:

- `agent run <job>` to execute one configured run;
- `agent show <job>` to print the effective redacted configuration and rendered
  provider command without executing it;
- `agent list` to enumerate configured jobs and their source scopes;
- stable exit behavior suitable for `set -e` shell scripts;
- stdout/stderr discipline that permits a calling script to capture a final
  response without losing human diagnostics.

The CLI should also support a fully explicit invocation for consumers that do not
want a named job, while keeping repository configuration the concise path for
repeated automation.

## Relationship to Handan

This provider-neutral process contract belongs in Baikai rather than making
Handan a generic subprocess runner. Handan's distinguishing contract is a catalog
of named, typed, traced, and evaluable judgments and effect programs. A raw coding
agent that edits a working tree usually yields an exit code and filesystem diff,
not a replayable typed model result.

Handan may later consume the Baikai agent-run library for a deliberately
registered delegated-agent task. Such a task should declare its weaker replay and
evaluation guarantees and add workflow-specific preconditions, artifact
discovery, and verification. It should not own the provider flag mapping or the
general shell-facing configuration contract.

## Acceptance criteria

The request is satisfied when:

1. A shell script can invoke one stable Baikai command with a prompt and select
   Claude Code or Codex entirely through configuration.
2. The `sync-keiro-dsl.sh` launch above can be represented without embedding
   Claude-specific flags in that script, including its extra source directory,
   edit permission mode, and tool allow-list.
3. Pure command-rendering tests prove the Claude and Codex argument vectors for
   the shared request, including prompts and paths beginning with `-`.
4. Integration tests use fake executables to prove stdin/stdout/stderr handling,
   working-directory selection, timeout, non-zero exit, and redaction without
   invoking a live model.
5. An effective-configuration command identifies every selected value's scope and
   renders no secret material.
6. Unsupported safety mappings fail before process creation.
7. Existing API providers, batch completion providers, and interactive launchers
   remain source-compatible.

## Out of scope

- Moving deterministic workflow logic, tests, marker handling, or commits out of
  consuming scripts merely because they invoke the new command.
- Defining Handan's task registry or result envelope.
- Normalizing the native tool names exposed by every current or future coding
  agent; a capability profile plus an explicit provider escape hatch is enough for
  the first version.
- Installing or authenticating Claude Code or Codex.
- Treating an unattended agent run as a Baikai API completion with fabricated
  token usage or response metadata.

## Evidence and related surfaces

- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
  `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` already own batch native-command
  construction.
- `Baikai.Interactive.InteractiveLaunchRequest` already establishes shared fields
  for model, working directory, additional directories, safety, raw arguments, and
  effort.
- `docs/user/cli-providers.md` documents why batch CLI-backed completion is not a
  tool-equivalent feature path.
- `docs/user/interactive-launches.md` documents why inherited-terminal launches
  are a separate use case.
- `shinzui/keiro-syntax/scripts/sync-keiro-dsl.sh` is the first concrete consumer
  and acceptance fixture for the unattended automation shape.
