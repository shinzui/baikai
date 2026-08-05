---
id: 46
slug: render-claude-and-codex-unattended-agent-commands
title: "Render Claude and Codex unattended agent commands"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Render Claude and Codex unattended agent commands

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

A previous plan, `docs/plans/45-add-the-unattended-agent-run-core-abstraction.md`, added a
provider-neutral way to describe an **unattended coding-agent run**: starting the `claude` or
`codex` command-line tool with no human present, letting it edit files inside directories it
was explicitly authorized to touch, and collecting a process result. That plan produced only
vocabulary. Nothing yet turns a described run into an actual command line.

This plan writes that translation, for both tools. After it, a Haskell programmer can hand a
neutral request to `claudeAgentCommand` or `codexAgentCommand` and get back the exact
executable name and list of arguments that would be spawned — or a structured refusal
explaining why the requested policy cannot be expressed for that tool. No process is spawned
by any code in this plan; every function here is pure, which is what makes the behavior
exhaustively testable without ever invoking a paid model.

The refusal half is as important as the rendering half, and it is why this plan is separate
from the runner. The two tools have genuinely different safety vocabularies. Claude Code has a
permission mode and a tool allow-list. Codex has a sandbox mode and no tool allow-list at all.
A shared request can therefore describe a policy that one tool cannot honor. The rule this plan
implements is that such a request **fails before anything is spawned**, with a message naming
what was asked for and why it cannot be done. It never quietly renders a near-miss flag, and it
never silently drops the part the tool cannot express. The repository currently gets this wrong
on its interactive surface — a fact documented below and repaired by
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` — and this plan is where
the correct behavior is established.

**The observable outcome**, verifiable by running one test command: after this plan,
`cabal test baikai-claude-test baikai-openai-test` passes with new test groups in which a
request for permission to edit its workspace, restricted to a named list of tools, renders for
Claude as an argument vector containing `-p`, `--permission-mode acceptEdits`, and
`--allowedTools Read,Write`; the same request is **refused** for Codex, because `codex exec` has
no tool allow-list flag; and in both cases the prompt appears nowhere in the argument vector
because it travels on standard input.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (2026-08-05): Re-verify the installed tools' flags and record any drift from
      the flag table in Context and Orientation before writing code. No mapping-relevant drift;
      Claude Code is now 2.1.222 rather than 2.1.220. Evidence in Surprises & Discoveries.
- [x] Milestone 2 (2026-08-05): Add `Baikai.Provider.Claude.Agent` with `ClaudeAgentConfig` and
      `claudeAgentCommand`; register it in `baikai-claude/baikai-claude.cabal`.
      `cabal build baikai-claude` succeeds with no warnings.
- [x] Milestone 3 (2026-08-05): Add `Baikai.Provider.OpenAI.Agent` with `CodexAgentConfig` and
      `codexAgentCommand`; register it in `baikai-openai/baikai-openai.cabal`.
      `cabal build baikai-openai` succeeds with no warnings.
- [x] Milestone 4 (2026-08-05): Add exact whole-argument-vector tests for both renderers,
      covering every capability, every effort level, both refusals, blank model values,
      configuration booleans, and dash-leading prompts and paths.
      `cabal test baikai-claude-test baikai-openai-test` passes; both suites build with no
      warnings.
- [x] Milestone 5 (2026-08-05): Document the mapping tables, add changelog bullets, and run the
      full offline validation. `nix fmt`, `git diff --check`, `cabal build all`, the key- and
      CLI-scrubbed `cabal test all`, and `nix flake check` all succeed; `baikai-claude-test`
      went 155 -> 170 cases and `baikai-openai-test` 62 -> 77, and the smoke suite reported
      `no provider keys or CLI binaries available; skipping all cases`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Milestone 1 verification (2026-08-05): **no drift in any flag this plan maps.** The installed
  tools are Claude Code `2.1.222` — a patch ahead of the `2.1.220` the plan was written against
  — and `codex-cli 0.146.0`, unchanged. Every fact the mapping depends on still holds:

  ```text
  claude --help
    --permission-mode <mode>   (choices: "acceptEdits", "auto", "bypassPermissions",
                                "manual", "dontAsk", "plan")
    --allowedTools, --allowed-tools <tools...>
                               Comma or space-separated list of tool names to allow
    --add-dir <directories...> Additional directories to allow tool access to
    --effort <level>           (low, medium, high, xhigh, max)
    --no-session-persistence   ... (only works with --print)
    --input-format <format>    "text" (default), or "stream-json"
    -p, --print                Print response and exit (useful for pipes)

  codex exec --help
    -s, --sandbox <SANDBOX_MODE>  [possible values: read-only, workspace-write,
                                   danger-full-access]
    -C, --cd <DIR>                working root
    --add-dir <DIR>               Additional directories that should be writable
    --skip-git-repo-check, --ephemeral, -m/--model, -c/--config
    [PROMPT]  If not provided as an argument (or if `-` is used), instructions are
              read from stdin. If stdin is piped and a prompt is also provided,
              stdin is appended as a `<stdin>` block
  ```

  `codex exec --help | grep ask-for-approval` printed nothing and exited 1, so `codex exec`
  still has no approval flag and the shared vocabulary still needs no approval field.
  `--permission-mode` still offers both `plan` and `acceptEdits`, which the capability mapping
  requires. Claude's `--allowedTools` and `--add-dir` are still variadic, so the comma-joined
  tool list and the repeated `--add-dir` remain the correct renderings. No mapping changed as a
  result of this milestone.


- Gap recorded (2026-08-05): `PromptAsArgument` is **not** exercised by this plan's tests, and
  the Decision Log's claim that it is "retained and tested as a fallback" is only half true. It
  is retained — `Baikai.Agent` exports it and the runner in
  `docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` must honor it
  — but neither renderer here can produce it: both always select `PromptOnStdin`, which the
  tests assert explicitly. There is therefore no rendering behavior to test on that branch. The
  transport's two-sided contract is EP-4's to pin, where a fixture executable can observe
  whether the prompt arrived on standard input or as an argument. Milestone 4's checklist line
  was corrected accordingly rather than claiming coverage that does not exist.

## Decision Log

Record every decision made while working on the plan.

- Decision: The prompt travels on **standard input** by default for both providers, and the
  rendered argument vector contains no prompt text at all.
  Rationale: it removes an entire class of bug. A prompt beginning with a dash cannot be
  mistaken for a flag, a prompt cannot be swallowed by a preceding variadic flag such as
  Claude's `--add-dir` or `--allowedTools`, and no shell quoting is involved anywhere because
  Baikai spawns an executable with an argument vector rather than a shell string. Both tools
  support it: `codex exec` documents reading instructions from standard input when no positional
  prompt is given, and Claude Code's `-p`/`--print` mode is documented as useful for pipes with
  `--input-format text` as its default. The `PromptAsArgument` transport is retained and tested
  as a fallback.
  Date: 2026-07-30

- Decision: Map the read-only capability to Claude's `--permission-mode plan`, and document the
  caveat rather than hide it.
  Rationale: Claude Code has no permission mode meaning exactly "may read, must not write". Its
  six modes are `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`. Of
  those, `manual` and `dontAsk` can block waiting for a human and are unusable unattended,
  `acceptEdits` and `bypassPermissions` permit writes, and `auto` delegates the decision to a
  classifier whose behavior is not a stable contract. `plan` is the only mode that reliably does
  not modify the tree. Its caveat is real and must be documented: plan mode also frames the task
  as producing a plan, so a read-only Claude run behaves differently from a read-only Codex run,
  which merely has a `read-only` sandbox. The alternative — refusing the read-only capability
  for Claude entirely — was rejected because read-only analysis runs are a legitimate use, and
  refusing them would push callers straight to the raw-argument escape hatch, which is worse for
  safety than a documented approximation.
  Date: 2026-07-30

- Decision: A non-empty tool allow-list is a **refusal** for Codex, not a silent drop.
  Rationale: `codex exec` has no tool allow-list flag. A caller who restricts tools and gets a
  run with unrestricted tools has been given more authority than they asked for, which is the
  exact failure mode the improvement request's safety requirements forbid. The refusal message
  names the sandbox mode as the alternative, so the error is actionable.
  Date: 2026-07-30

- Decision: Neither renderer inspects or rewrites the raw `providerArgs` escape hatch; it is
  appended verbatim after all structured flags.
  Rationale: the authority to pass raw arguments is gated once, at the policy ceiling in
  `Baikai.Agent.applyAgentCeiling`, which refuses them unless an operator opted in. Adding a
  second, weaker check here — scanning for dangerous flag spellings — would create the
  impression of a security boundary that a renamed or newly added vendor flag defeats. One real
  gate is safer than one real gate plus one illusory one.
  Date: 2026-07-30

- Decision: Emit Codex's `--cd` flag even though the runner also sets the child process's
  working directory.
  Rationale: this matches the existing precedent exactly —
  `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` renders `--cd` while
  `launchCodexInteractive` also sets the process working directory — and it makes the agent's
  working root explicit in the rendered command that `agent show` prints, rather than implicit in
  process state a reader cannot see.
  Date: 2026-07-30


- Decision (2026-08-05): the Codex renderer emits no `--json` flag.
  Rationale: the batch completion provider in `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`
  needs machine-readable events because it must reconstruct a `Response` value. An unattended
  run's deliverable is the changed working tree, and its standard output is read by a shell
  script or a human tailing a log, so plain output is the useful default. A caller who wants
  JSONL can ask for it through raw provider arguments, which the operator ceiling gates.
  Date: 2026-08-05

- Decision (2026-08-05): the Codex renderer emits no `-o`/`--output-last-message`.
  Rationale: writing the agent's final message to a file is genuinely useful, but there is
  nowhere in the shared vocabulary to say *where* the file goes, so supporting it here would
  make it a Codex-only behavior with no Claude counterpart and no provider-neutral spelling.
  That is a core vocabulary change and belongs in a later plan rather than being smuggled in.
  Date: 2026-08-05

- Decision (2026-08-05): both renderers read the requested capability as
  `req ^. #safety . #capability` rather than the plan's `req ^. #safety ^. #capability`.
  Rationale: the two are equivalent in effect, but the composed-lens form is one traversal and
  is the form used elsewhere in the repository. No behavior differs.
  Date: 2026-08-05

- Decision (2026-08-05): the tests assert the rendered command field by field through
  `generic-lens` labels rather than comparing one whole `AgentCommand` value with `@?=` as
  Milestone 4's prose implied.
  Rationale: constructing an expected `AgentCommand` with record syntax needs its field names in
  scope, and both vendor test suites already import `Baikai.Provider.*.Interactive` unqualified,
  which exports `executable` and `extraArgs`. Bringing a second `executable` into scope would
  make the existing record updates in those files ambiguous. Asserting `executable`,
  `arguments`, `promptTransport`, and `promptText` separately is equally strict — the argument
  vector is still compared whole, so a flag in the wrong order or an extra flag still fails —
  and it leaves the existing tests untouched. Refusals are still compared as whole `Either`
  values, since a `Left` needs only constructors.
  Date: 2026-08-05

- Decision (2026-08-05): add the missing `Outcomes & Retrospective` section to this plan.
  Rationale: the ExecPlan specification requires it and the plan skeleton places it between the
  Decision Log and Context and Orientation, but this file was authored without it. Adding it in
  its skeleton position rather than at the end keeps the section order consistent with every
  other plan in `docs/plans/`.
  Date: 2026-08-05

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Outcome (2026-08-05): complete, and the headline behavior is real. The same neutral
edit-workspace request with a tool allow-list renders for Claude as
`["-p","--no-session-persistence","--permission-mode","acceptEdits","--allowedTools","Read,Write"]`
and is *refused* for Codex with `UnsupportedToolRestriction`, whose message names the sandbox
alternative — both pinned by tests, neither reaching a process. `baikai-claude-test` grew from
155 to 170 cases and `baikai-openai-test` from 62 to 77. Both new modules are additive: no
existing signature changed, and the interactive modules were not touched, so
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md` can proceed without a
conflict.

The mapping tables are published in `docs/user/interactive-launches.md` alongside the three
facts that matter more than the tables themselves: Codex refuses a tool allow-list, `--add-dir`
grants tool access on Claude but write access on Codex, and the prompt never enters the argument
vector on either provider.

Gaps. `PromptAsArgument` has no renderer that produces it, so its contract is untested here and
is EP-4's to pin with a fixture executable — recorded in Surprises & Discoveries and carried to
the parent MasterPlan. Nothing in this plan can be exercised end to end, because no runner
exists yet; the evidence is pure tests by design, and no acceptance step ran an installed
coding-agent binary with a prompt.

Lessons worth carrying forward. First, adding an unqualified import to a vendor test suite is
the riskiest part of touching these files: `DuplicateRecordFields` makes several field names
collide across the three Claude and Codex surfaces, so import the new module qualified and read
fields through labels. Second, re-verifying the vendor flags before writing the mapping was the
only reason the mapping can be asserted rather than assumed — the installed Claude Code had
already moved a patch version since the plan was written, and a future plan touching these
renderers should repeat that check rather than trusting this plan's table.

## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository.

Baikai is a multi-package Cabal workspace; Cabal is the Haskell build tool and each package is a
directory containing a `.cabal` file. The packages are listed in `cabal.project` at the
repository root. This plan edits exactly two packages: `baikai-claude`, which holds everything
specific to Anthropic and the `claude` binary, and `baikai-openai`, which holds everything
specific to OpenAI and the `codex` binary. It does not edit the core `baikai` package.

The architectural rule you are following is that the core package owns provider-neutral
vocabulary and vendor packages own their own tool's command-line flags. You can see the rule
already applied to the interactive surface: `baikai/src/Baikai/Interactive.hs` defines a neutral
request type, and `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` plus
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` each translate it into their own
flags. This plan adds the same shape for unattended runs.

### What the previous plan produced

`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` created
`baikai/src/Baikai/Agent.hs`. Read that file before starting. The names this plan consumes are:

```haskell
data AgentProvider = AgentClaude | AgentCodex
data AgentCapability = AgentReadOnly | AgentEditWorkspace | AgentFullAccess

data AgentSafety = AgentSafety
  { capability :: !AgentCapability, allowedTools :: ![Text], providerArgs :: ![Text] }
agentSafety :: AgentCapability -> AgentSafety

data AgentRunRequest = AgentRunRequest
  { provider :: !AgentProvider, prompt :: !Text, modelId :: !(Maybe Text)
  , effort :: !(Maybe ThinkingLevel), workingDir :: !FilePath, extraDirs :: ![FilePath]
  , safety :: !AgentSafety, timeout :: !(Maybe NominalDiffTime)
  , output :: !AgentOutputMode, outputLimit :: !(Maybe Int), envPassthrough :: ![Text] }
agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest

data AgentPromptTransport = PromptOnStdin | PromptAsArgument
data AgentCommand = AgentCommand
  { executable :: !FilePath, arguments :: ![String]
  , promptTransport :: !AgentPromptTransport, promptText :: !Text }

data AgentRenderError
  = UnsupportedCapability !AgentProvider !AgentCapability !Text
  | UnsupportedToolRestriction !AgentProvider !Text
  | ProviderMismatch !AgentProvider !AgentProvider   -- renderer's provider, request's provider
  | CeilingRejected ![CeilingViolation]
renderAgentRenderError :: AgentRenderError -> Text
```

Two things about that module matter here. It is **not** re-exported from the umbrella module
`baikai/src/Baikai.hs`, because its field accessor names would conflict with
`Baikai.Interactive`'s; you must write `import Baikai.Agent` explicitly. And `AgentCommand`
carries no working directory on purpose: Claude Code has no working-directory flag, so the
working directory is a process-level setting the runner reads from the request. Your Codex
renderer still emits `--cd` because Codex has such a flag, but neither renderer is responsible
for the child process's actual working directory.

Fields are read with `generic-lens` labels, for example `request ^. #workingDir`, which works
because the records derive `Generic`. You do not import field selectors to read them. This is
how the existing interactive renderers are written.

### The two existing vendor modules to imitate

`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` is 110 lines and you should read all
of it. Its shape is:

```haskell
data ClaudeInteractiveConfig = ClaudeInteractiveConfig
  { executable :: !FilePath, extraArgs :: ![Text] }
  deriving stock (Eq, Show, Generic)

defaultClaudeInteractiveConfig :: ClaudeInteractiveConfig

claudeInteractiveCommand ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])
claudeInteractiveCommand cfg req =
  ( cfg ^. #executable,
    modelArgs req <> effortArgs req <> systemPromptArgs req <> extraDirArgs req
      <> safetyArgs req
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> fmap Text.unpack (req ^. #extraArgs)
      <> ["--", Text.unpack (req ^. #userPrompt)] )
```

Each concern is a small helper returning `[String]`, and the whole vector is their concatenation
in a fixed order. Copy that style.
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` is the Codex equivalent.

Note the ordering convention: configuration-level `extraArgs` come before request-level ones,
and both come after every structured flag, so raw arguments are the last override. Preserve that
ordering, because the existing tests document it and callers rely on it.

### The defect this plan must not reproduce

Look at the end of `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`:

```haskell
safetyArgs :: InteractiveLaunchRequest -> [String]
safetyArgs req = case req ^. #safety of
  ClaudeAllowedTools [] -> []
  ClaudeAllowedTools tools -> ["--allowedTools", Text.unpack (Text.intercalate "," tools)]
  DefaultSafety -> []
  CodexSandbox _ _ -> []
```

That last line silently discards a caller's sandbox policy and returns an unrestricted command.
The Codex module has the mirror-image bug for `ClaudeAllowedTools`. Both are silent downgrades:
the caller asked for a restriction and got none, with no error. Your renderers must return
`Left` in the equivalent situations. The interactive modules are repaired separately by
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`; do not edit them here.

### Verified flag facts

Every fact below was checked against the tools installed on the machine where this plan was
written: **Claude Code 2.1.220** and **codex-cli 0.146.0**. Milestone 1 re-verifies them,
because these tools update frequently and a changed flag silently invalidates a mapping.

Claude Code, from `claude --help`:

```text
-p, --print                    Print response and exit (useful for pipes).
--permission-mode <mode>       Permission mode to use for the session (choices:
                               "acceptEdits", "auto", "bypassPermissions",
                               "manual", "dontAsk", "plan")
--allowedTools, --allowed-tools <tools...>
                               Comma or space-separated list of tool names to allow
--add-dir <directories...>     Additional directories to allow tool access to
--model <model>                Model for the current session
--effort <level>               Effort level for the current session (low, medium,
                               high, xhigh, max)
--no-session-persistence       Disable session persistence (only works with --print)
--input-format <format>        Input format (only works with --print): "text"
                               (default), or "stream-json"
```

Claude Code has **no** working-directory flag. `--allowedTools` and `--add-dir` are both
variadic, which is why the existing code joins tool names with commas into a single argument and
repeats `--add-dir` once per directory rather than passing several values to one flag.

Codex, from `codex exec --help`:

```text
Usage: codex exec [OPTIONS] [PROMPT]

[PROMPT]  Initial instructions for the agent. If not provided as an argument (or if
          `-` is used), instructions are read from stdin. If stdin is piped and a
          prompt is also provided, stdin is appended as a `<stdin>` block
-c, --config <key=value>      Override a configuration value
-m, --model <MODEL>           Model the agent should use
-s, --sandbox <SANDBOX_MODE>  [possible values: read-only, workspace-write,
                              danger-full-access]
--dangerously-bypass-approvals-and-sandbox
-C, --cd <DIR>                Tell the agent to use the specified directory as its
                              working root
--add-dir <DIR>               Additional directories that should be writable alongside
                              the primary workspace
--skip-git-repo-check         Allow running Codex outside a Git repository
--ephemeral                   Run without persisting session files to disk
--json                        Print events to stdout as JSONL
-o, --output-last-message <FILE>
```

Three consequences. `codex exec` has **no** `--ask-for-approval` flag; that flag exists only on
the interactive top-level `codex` command. This is why the shared vocabulary has no approval
field and why any approval intent must go through `-c approval_policy=<value>` as a raw provider
argument. `codex exec` has **no** tool allow-list flag, which is the refusal case in Milestone 3.
And the `<stdin>` block behavior means a renderer must never emit both a positional prompt and
standard-input content.

The two `--add-dir` flags differ in meaning: Claude grants tool *access*, Codex grants *write*
access. Say so in the Haddock comments of both renderers.

### Repository conventions

Every package sets `default-extensions: DeriveAnyClass, DuplicateRecordFields, OverloadedLabels,
OverloadedStrings` and `default-language: GHC2024`, so unprefixed field names across different
records are legal. Field names carry no type prefix: write `executable`, not `claudeExecutable`.
Warning flags include `-Wall`, which includes `-Wincomplete-patterns`, and
`-Wmissing-export-lists`. There is no `-Werror`, so read the build output rather than trusting a
zero exit status. Formatting is `nix fmt`, which runs `fourmolu` with `fourmolu.yaml`.

Tests use `tasty` with `tasty-hunit`. Each vendor package has a single `test/Main.hs` that both
defines its own test cases and lists imported spec modules. `baikai-claude/test/Main.hs` already
contains `commandRenderingTest` for the interactive renderer and `batchCommandRenderingTest` for
the batch renderer; both compare the **entire** rendered vector with `@?=` rather than checking
that individual flags are present. That is the standard this plan's tests must meet, because a
membership check cannot catch a flag rendered in the wrong order or an extra flag appearing.


## Plan of Work

Five milestones. Milestone 1 is verification with no code changes. Milestones 2 and 3 add one
module each and are verifiable by building. Milestone 4 makes the behavior observable.
Milestone 5 documents and validates.

### Milestone 1 — Re-verify the flags before writing any mapping

Scope: confirm the flag table in Context and Orientation still matches the installed tools.
Nothing is edited unless a flag has changed. At the end of this milestone the Surprises &
Discoveries section either records "no drift" or records exactly what moved.

These commands read help text and version numbers only. They do not authenticate, do not contact
a provider, and do not start a model request:

```bash
claude --version
claude --help | rg -- '--permission-mode' -A 3
claude --help | rg -- '--allowedTools' -A 2
claude --help | rg -- '--add-dir|--input-format|--no-session-persistence' -A 2
codex --version
codex exec --help | rg -- '--sandbox' -A 4
codex exec --help | rg -- '--add-dir|--cd|--skip-git-repo-check|--ephemeral' -A 2
codex exec --help | rg -- 'ask-for-approval'
```

The last command must print nothing. If it prints a flag, then `codex exec` has gained an
approval option since this plan was written; record that in Surprises & Discoveries and note
that a future plan may add approval to the shared vocabulary — but do **not** add it in this
plan, because the shared request type has no field for it and widening core is out of scope here.

If `--permission-mode` has lost `plan` or `acceptEdits`, stop and record it: the capability
mapping in Milestone 2 depends on both existing, and inventing a substitute silently is exactly
what this plan forbids.

Do not run `claude -p` or `codex exec` with a real prompt as a check. Both cross the
authenticated provider boundary and would make a billable request. The pure tests in Milestone 4
are this plan's evidence.

### Milestone 2 — The Claude renderer

Scope: create `baikai-claude/src/Baikai/Provider/Claude/Agent.hs`. At the end of this milestone
`cabal build baikai-claude` succeeds and the module is part of the library.

Create the file with a module header explaining, in the voice of the neighbouring
`Baikai/Provider/Claude/Interactive.hs`, that this module renders the argument vector for an
**unattended** Claude Code run; that it is deliberately separate from
`Baikai.Provider.Claude.Cli`, which drives `claude -p` as a batch completion provider returning
a parsed response, and from `Baikai.Provider.Claude.Interactive`, which starts a terminal
session; and that it spawns nothing.

Define the configuration record, following `ClaudeInteractiveConfig` in shape:

```haskell
data ClaudeAgentConfig = ClaudeAgentConfig
  { executable :: !FilePath,
    extraArgs :: ![Text],
    persistSession :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeAgentConfig :: ClaudeAgentConfig
defaultClaudeAgentConfig =
  ClaudeAgentConfig
    { executable = "claude",
      extraArgs = mempty,
      persistSession = False
    }
```

`persistSession` defaults to `False`, meaning the renderer emits `--no-session-persistence`.
Automation runs are one-shot and a resumable session on disk is state nobody will clean up. This
mirrors `ephemeral = True` in `defaultCodexCliConfig` in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` and `--no-session-persistence` in
`claudeCliCommand` in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`. Note in the Haddock
comment that the flag only works together with `-p`, which this renderer always emits.

Now the renderer:

```haskell
claudeAgentCommand ::
  ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand
```

Its first action is the provider guard: if `req ^. #provider` is not `AgentClaude`, return
`Left (ProviderMismatch AgentClaude (req ^. #provider))`.

Then compute the permission mode from the capability. Write this as a function returning
`Either AgentRenderError [String]` so a future unsupported capability has somewhere to fail:

```haskell
permissionModeArgs :: AgentCapability -> Either AgentRenderError [String]
permissionModeArgs = \case
  -- Claude has no exact read-only mode. `plan` is the only mode that reliably
  -- does not modify the tree, at the cost of also framing the task as planning.
  AgentReadOnly -> Right ["--permission-mode", "plan"]
  AgentEditWorkspace -> Right ["--permission-mode", "acceptEdits"]
  AgentFullAccess -> Right ["--permission-mode", "bypassPermissions"]
```

All three map, so no branch fails today. Keep the `Either` anyway: the type is the promise that
an unmappable capability would be refused rather than approximated, and a later contributor
adding a fourth capability gets a compile error pointing at the decision instead of a silently
missing flag.

Assemble the vector, placing structured flags first, then configuration raw arguments, then
request raw arguments, matching the existing modules:

```haskell
claudeAgentCommand cfg req
  | req ^. #provider /= AgentClaude =
      Left (ProviderMismatch AgentClaude (req ^. #provider))
  | otherwise = do
      permission <- permissionModeArgs (req ^. #safety ^. #capability)
      pure
        AgentCommand
          { executable = cfg ^. #executable,
            arguments =
              ["-p"]
                <> sessionArgs cfg
                <> modelArgs req
                <> effortArgs req
                <> permission
                <> allowedToolArgs req
                <> extraDirArgs req
                <> fmap Text.unpack (cfg ^. #extraArgs)
                <> fmap Text.unpack (req ^. #safety ^. #providerArgs),
            promptTransport = PromptOnStdin,
            promptText = req ^. #prompt
          }
```

The helpers are small and each mirrors an existing one.

`sessionArgs` yields `["--no-session-persistence"]` when `persistSession` is `False` and `[]`
otherwise.

`modelArgs` copies the existing implementation exactly, including its treatment of a blank
string: `case Text.strip <$> req ^. #modelId of Nothing -> []; Just "" -> []; Just mid ->
["--model", Text.unpack mid]`. A configuration file with an empty model value must not produce
`--model ""`, which Claude would reject.

`effortArgs` copies the existing Claude effort mapping, including the one vendor quirk: Claude's
`--effort` accepts `low`, `medium`, `high`, `xhigh`, and `max` but **not** `minimal`, so
`ThinkingMinimal` maps up to `"low"` and every other level uses
`Baikai.ThinkingLevel.renderThinkingLevel`. Do not re-derive this; copy it from
`Baikai/Provider/Claude/Interactive.hs` so the two surfaces cannot drift.

`allowedToolArgs` yields `[]` for an empty list and otherwise
`["--allowedTools", Text.unpack (Text.intercalate "," tools)]`. Join with commas into one
argument rather than passing several, because the flag is variadic and separate values could
absorb a following flag.

`extraDirArgs` yields `concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)`. Note in a
comment that on Claude this grants tool access, whereas the identically named Codex flag grants
write access.

Note what is deliberately absent. There is no working-directory flag, because Claude has none;
the runner sets the child's working directory from `req ^. #workingDir`. There is no
`--output-format` flag, so Claude uses its documented default of plain text and standard output
carries the final assistant message, which is what a calling shell script wants to capture.
There is no system-prompt handling, because `AgentRunRequest` has no system-prompt field: an
unattended run's instructions are its prompt, and the tool's own project configuration supplies
standing context. If a future consumer needs a system prompt, that is a core vocabulary change
and belongs in a new plan, not in `providerArgs`.

Add `Baikai.Provider.Claude.Agent` to `exposed-modules` in the `library` stanza of
`baikai-claude/baikai-claude.cabal`, keeping the list alphabetical: it goes immediately after
`Baikai.Provider.Claude.Api`. No new dependency is needed; `baikai`, `text`, `lens`, and
`generic-lens` are already present.

Verify with `cabal build baikai-claude`.

### Milestone 3 — The Codex renderer

Scope: create `baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs`. At the end of this milestone
`cabal build baikai-openai` succeeds.

Create the file with an analogous module header, distinguishing it from
`Baikai.Provider.OpenAI.Cli`, which drives `codex exec --json` as a batch completion provider,
and from `Baikai.Provider.OpenAI.Interactive`, which starts a terminal session.

The configuration record follows `CodexCliConfig` in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, which already has the two Codex-specific
booleans:

```haskell
data CodexAgentConfig = CodexAgentConfig
  { executable :: !FilePath,
    extraArgs :: ![Text],
    skipGitRepoCheck :: !Bool,
    ephemeral :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultCodexAgentConfig :: CodexAgentConfig
defaultCodexAgentConfig =
  CodexAgentConfig
    { executable = "codex",
      extraArgs = mempty,
      skipGitRepoCheck = True,
      ephemeral = True
    }
```

Both booleans default to `True`, matching `defaultCodexCliConfig`, so an unattended run works
outside a Git repository and leaves no session files behind.

The renderer performs the provider guard, then the tool-allow-list refusal that makes this
plan's contract real, then the sandbox mapping:

```haskell
codexAgentCommand ::
  CodexAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand

sandboxArgs :: AgentCapability -> Either AgentRenderError [String]
sandboxArgs = \case
  AgentReadOnly -> Right ["--sandbox", "read-only"]
  AgentEditWorkspace -> Right ["--sandbox", "workspace-write"]
  AgentFullAccess -> Right ["--sandbox", "danger-full-access"]

toolRestrictionGuard :: AgentRunRequest -> Either AgentRenderError ()
toolRestrictionGuard req = case req ^. #safety ^. #allowedTools of
  [] -> Right ()
  _ ->
    Left
      ( UnsupportedToolRestriction
          AgentCodex
          "codex exec has no tool allow-list flag; restrict Codex with a narrower \
          \sandbox mode, or pass an explicit provider argument if your operator \
          \policy permits raw arguments"
      )
```

Use the long spellings `--sandbox` and `--cd` rather than `-s` and `-C`. The rendered vector is
printed to operators by `agent show`, and a long flag is self-describing where a single letter is
not. The refusal message must name the alternative, not merely state the problem: an operator
reading it should know what to do next.

Assemble:

```haskell
codexAgentCommand cfg req
  | req ^. #provider /= AgentCodex =
      Left (ProviderMismatch AgentCodex (req ^. #provider))
  | otherwise = do
      toolRestrictionGuard req
      sandbox <- sandboxArgs (req ^. #safety ^. #capability)
      pure
        AgentCommand
          { executable = cfg ^. #executable,
            arguments =
              ["exec"]
                <> modelArgs req
                <> effortArgs req
                <> sandbox
                <> ["--cd", req ^. #workingDir]
                <> extraDirArgs req
                <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
                <> ["--ephemeral" | cfg ^. #ephemeral]
                <> fmap Text.unpack (cfg ^. #extraArgs)
                <> fmap Text.unpack (req ^. #safety ^. #providerArgs),
            promptTransport = PromptOnStdin,
            promptText = req ^. #prompt
          }
```

`modelArgs` uses `--model` with the same blank-string guard as the Claude renderer. `effortArgs`
uses Codex's config-override form, copied from
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`:
`["-c", "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel lvl)]`. Codex accepts all
six canonical levels, so there is no clamp here — unlike Claude.

Note what is absent and why. No `--json` flag: the batch completion provider needs
machine-readable events because it must reconstruct a response value, but an unattended run's
deliverable is the changed working tree, and plain output keeps standard output human-readable
and directly capturable by a shell script. No `-o`/`--output-last-message`: writing the final
message to a file is a genuinely useful capability, but it needs a place in the shared vocabulary
to say where the file goes, so it belongs in a later plan rather than being smuggled in as a
Codex-only behavior. Record both as Decision Log entries when you implement this, so the next
reader knows they were considered.

Add `Baikai.Provider.OpenAI.Agent` to `exposed-modules` in `baikai-openai/baikai-openai.cabal`,
alphabetically after `Baikai.Provider.OpenAI.Api`.

Verify with `cabal build baikai-openai`.

### Milestone 4 — Exact argument-vector tests

Scope: add test cases to both vendor test suites. At the end of this milestone
`cabal test baikai-claude-test baikai-openai-test` passes and every mapping and refusal is
pinned by a test that compares whole vectors.

Both packages keep their tests in a single `test/Main.hs` that defines cases inline and lists
them in a `testGroup`. Add your cases as new top-level `TestTree` values and add them to the
existing root group list. Follow `commandRenderingTest` in `baikai-claude/test/Main.hs` as the
model: build a request with `agentRunRequest` plus lens updates, then compare the result with
`@?=` against a fully written-out expected value.

For `baikai-claude/test/Main.hs`, add the following.

A full-render test using a non-default configuration and a request that exercises every field at
once — a model, an effort level, the edit-workspace capability, a tool list, two extra
directories, configuration raw arguments, and request raw arguments. Assert the complete
`AgentCommand`, including that `promptTransport` is `PromptOnStdin` and that `promptText` holds
the prompt. For `executable = "/bin/claude"`, `extraArgs = ["--debug"]`, model `"sonnet"`, effort
`ThinkingHigh`, tools `["Read", "Write"]`, extra directories `["/work/shared", "/work/docs"]`,
and request raw arguments `["--betas", "context-1m"]`, the expected vector is:

```haskell
[ "-p", "--no-session-persistence", "--model", "sonnet", "--effort", "high",
  "--permission-mode", "acceptEdits", "--allowedTools", "Read,Write",
  "--add-dir", "/work/shared", "--add-dir", "/work/docs",
  "--debug", "--betas", "context-1m" ]
```

A capability table test asserting the permission mode for all three capabilities:
`AgentReadOnly` gives `plan`, `AgentEditWorkspace` gives `acceptEdits`, `AgentFullAccess` gives
`bypassPermissions`.

A prompt-absence test, which is the safety property this plan's transport decision buys. Build a
request whose prompt is `"-rm -rf /"` — a string that both begins with a dash and looks like a
command — and assert that the rendered `arguments` list contains no element equal to that string,
and that `promptText` equals it exactly. Then do the same for a working directory and an extra
directory beginning with a dash, asserting they appear as ordinary arguments after their flags.
This directly discharges the improvement request's acceptance criterion about prompts and paths
beginning with a dash.

A session-persistence test asserting that `persistSession = True` omits
`--no-session-persistence` and that the default includes it.

A provider-guard test asserting that a request built with `agentRunRequest AgentCodex ...` handed
to `claudeAgentCommand` returns `Left (ProviderMismatch AgentClaude AgentCodex)`.

A fixture test named for the initiative's first real consumer. Build the request corresponding to
the launch currently embedded in `scripts/sync-keiro-dsl.sh` in the `shinzui/keiro-syntax`
repository — the edit-workspace capability, one extra directory, and the tool list
`["Read", "Write", "Edit", "Glob", "Grep", "Bash", "Skill", "TodoWrite"]` — and assert the full
rendered vector. This is the plan's contribution to the improvement request's acceptance criterion
that the fixture's launch be expressible without Claude-specific flags in the script; the
end-to-end half is discharged by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`.

For `baikai-openai/test/Main.hs`, add the mirror-image set.

A full-render test asserting the complete vector. For `executable = "/bin/codex"`,
`extraArgs = ["--color", "never"]`, model `"gpt-5.6-terra"`, effort `ThinkingMedium`,
edit-workspace capability, working directory `"/work/project"`, and extra directories
`["/work/shared"]`:

```haskell
[ "exec", "--model", "gpt-5.6-terra", "-c", "model_reasoning_effort=medium",
  "--sandbox", "workspace-write", "--cd", "/work/project",
  "--add-dir", "/work/shared", "--skip-git-repo-check", "--ephemeral",
  "--color", "never" ]
```

A capability table test asserting `read-only`, `workspace-write`, and `danger-full-access`.

A tool-restriction refusal test: a request with any non-empty `allowedTools` returns
`Left (UnsupportedToolRestriction AgentCodex msg)`, and the message mentions the sandbox
alternative. Assert the constructor exactly, and use `assertBool` with
`Text.isInfixOf "sandbox"` for the message so wording stays editable.

An effort table test covering all six `ThinkingLevel` values, asserting Codex passes each
canonical name through unchanged with no clamp. This is the counterpart to Claude's
minimal-becomes-low quirk, and pinning both prevents someone later "unifying" them.

A configuration-boolean test asserting that `skipGitRepoCheck = False` and `ephemeral = False`
each omit their flag.

A provider-guard test asserting `codexAgentCommand` refuses an `AgentClaude` request with
`Left (ProviderMismatch AgentCodex AgentClaude)`.

Verify with:

```bash
cabal test baikai-claude-test baikai-openai-test
```

### Milestone 5 — Documentation, changelog, and validation

Scope: publish the mapping tables so an operator can predict what a policy becomes, record the
change, and prove the workspace is green offline.

The mapping tables are the documentation that matters most, because a capability profile is only
trustworthy if a reader can see exactly what it turns into. Add them to
`docs/user/interactive-launches.md`, in the section that
`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` added describing the third
surface. Give one table per provider mapping each capability to its rendered flag, state the
plan-mode caveat for Claude read-only runs in prose beneath the Claude table, state that Codex
refuses a tool allow-list and why, and state that `--add-dir` grants tool access on Claude and
write access on Codex. Note that the full user guide for this surface arrives in
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`; keep this addition
focused on the mapping.

Add bullets under `[Unreleased]` in the single root `CHANGELOG.md`, scoped to `baikai-claude` and
`baikai-openai` separately. This repository has one changelog for every package and no
per-package changelog files; do not create dated release headings during feature work.

Consider the version implication but perform no release. Both changes are purely additive — one
new exposed module per package, no existing signature touched — so each provider package needs a
minor bump from its in-tree `0.4.0.0`, not a major one. The release runs separately through
`agents/skills/release/SKILL.md`, coordinated for the whole initiative by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`. Do not hand-edit
versions or dependency bounds here.

Update the parent MasterPlan
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: set EP-2 to
`Complete` in the Exec-Plan Registry, check off its four Progress lines, and add anything found in
Milestone 1 to its Surprises & Discoveries section. If a capability turned out not to be
expressible for a provider, that is a cross-plan fact the configuration and CLI plans need.

Then run the full validation in Concrete Steps.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, unless stated
otherwise.

Milestone 1's verification commands are listed in that milestone. They read help text only.

Build after Milestones 2 and 3:

```bash
cabal build baikai-claude
cabal build baikai-openai
```

Expect clean builds. A `Variable not in scope` error naming a field accessor usually means you
tried to import selectors from `Baikai.Agent`; read fields with `req ^. #field` instead, and make
sure `Data.Generics.Labels ()` is imported for its instance.

Test after Milestone 4:

```bash
cabal test baikai-claude-test baikai-openai-test
```

Expect both suites to pass with totals higher than their current baselines.

To see a rendered vector and a refusal without writing a test, use the interactive interpreter.
Everything here is pure and contacts nothing:

```bash
cabal repl baikai-claude
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Baikai.Provider.Claude.Agent
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
let req = (agentRunRequest AgentClaude "/work/project" "reconcile the grammar")
            & #safety .~ (agentSafety AgentEditWorkspace) { allowedTools = ["Read", "Edit"] }
fmap (^. #arguments) (claudeAgentCommand defaultClaudeAgentConfig req)
-- expect: Right ["-p","--no-session-persistence","--permission-mode","acceptEdits","--allowedTools","Read,Edit"]
fmap (^. #promptTransport) (claudeAgentCommand defaultClaudeAgentConfig req)
-- expect: Right PromptOnStdin
:quit
```

```bash
cabal repl baikai-openai
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Baikai.Provider.OpenAI.Agent
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
let ok = (agentRunRequest AgentCodex "/work/project" "reconcile the grammar")
           & #safety .~ agentSafety AgentEditWorkspace
fmap (^. #arguments) (codexAgentCommand defaultCodexAgentConfig ok)
-- expect: Right ["exec","--sandbox","workspace-write","--cd","/work/project","--skip-git-repo-check","--ephemeral"]
let restricted = ok & #safety .~ (agentSafety AgentEditWorkspace) { allowedTools = ["Read"] }
either renderAgentRenderError (const "rendered") (codexAgentCommand defaultCodexAgentConfig restricted)
-- expect a message containing: codex exec has no tool allow-list flag
:quit
```

That last transcript is the plan's headline behavior: the same neutral request that renders
successfully for Claude is refused for Codex, with an actionable reason, before any process would
be created.

Full validation after Milestone 5. Two independent gates cause the `baikai-smoke` suite to make
real billable calls and both must be closed: provider API-key environment variables, and —
discovered during the work recorded in
`docs/plans/44-add-reasoning-effort-control-to-interactive-cli-launches.md` — the mere presence of
the `claude` or `codex` binary on `PATH`, because `baikai-smoke/test/Smoke.hs` gates its batch CLI
cases on `findExecutable` alone. This `zsh` command closes both while keeping the active
toolchain:

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

Expect no unintended formatting diff, nothing from `git diff --check`, a clean build, every suite
passing, the smoke suite reporting both binaries and all keys unavailable and skipping every live
case, and a successful flake check.

Commit with all three trailers:

```text
feat(agent): render Claude and Codex unattended agent commands

Add pure argv renderers for unattended runs in both vendor packages.
Unsupported policy is refused before process creation: Codex rejects a
tool allow-list it cannot express, and each renderer rejects a request
naming the other provider.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/46-render-claude-and-codex-unattended-agent-commands.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan is accepted when all of the following hold.

Both packages build with no incomplete-pattern warning, which proves the capability mappings are
total over the closed capability set.

For Claude, a request with the edit-workspace capability and the tool list `["Read","Write"]`
renders exactly
`["-p","--no-session-persistence","--permission-mode","acceptEdits","--allowedTools","Read,Write"]`
under the default configuration, with `promptTransport = PromptOnStdin` and `promptText` equal to
the request's prompt. The three capabilities render `plan`, `acceptEdits`, and
`bypassPermissions` respectively.

For Codex, the same capability renders a vector containing `exec`, `--sandbox workspace-write`,
and `--cd` with the request's working directory, and the three capabilities render `read-only`,
`workspace-write`, and `danger-full-access`. A request carrying any non-empty tool allow-list
returns `Left (UnsupportedToolRestriction AgentCodex msg)` whose message names the sandbox
alternative.

Neither renderer places the prompt anywhere in the argument vector. A prompt of `"-rm -rf /"`
appears only in `promptText`, and a working directory or extra directory beginning with a dash
appears as an ordinary argument following its flag.

Each renderer refuses a request naming the other provider with `ProviderMismatch`, whose first
field is the renderer's own provider.

Effort renders through Claude's `--effort` with `ThinkingMinimal` clamped up to `low`, and through
Codex's `-c model_reasoning_effort=` with all six canonical levels unclamped. A blank model string
produces no `--model` flag on either provider.

Raw provider arguments from both the configuration and the request appear verbatim, after every
structured flag, and are neither inspected nor rewritten.

`cabal test baikai-claude-test baikai-openai-test` passes with whole-vector assertions rather than
membership checks.

`docs/user/interactive-launches.md` contains both mapping tables, the Claude plan-mode caveat, the
Codex tool-allow-list refusal, and the `--add-dir` semantic divergence. The root `CHANGELOG.md`
has bullets for both provider packages under `[Unreleased]`. The parent MasterPlan shows EP-2
complete.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`, and
`nix flake check` all succeed. No acceptance step invokes a live model or runs an installed
coding-agent binary with a prompt.


## Idempotence and Recovery

Every change is additive: two new modules, two `exposed-modules` lines, new test cases, one
documentation section, and changelog bullets. No existing module is modified, so every existing
test must keep passing. In particular you must not touch
`baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` or
`baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`; their silent-downgrade defect is
repaired by `docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`, and changing
them here would collide with that plan.

All commands are safe to repeat. The help-text commands in Milestone 1 are read-only. The
`cabal repl` transcripts are pure. Nothing contacts a provider, mutates remote state, or writes
outside the repository.

Milestones 2 and 3 are independent of each other: either can be committed alone and the workspace
stays green, because neither module is imported by anything yet. If you need to abandon one, the
other still builds and tests.

To roll back, revert the commit. No package depends on either new module at the end of this plan,
so removal cannot break anything else.


## Interfaces and Dependencies

No new dependencies in either package. `baikai-claude` already depends on `baikai`, `text`,
`lens`, and `generic-lens`; so does `baikai-openai`. Neither renderer needs `cradle` or `process`,
because neither spawns anything.

At completion the following interfaces exist. The plans in
`docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md` and
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` depend on these
exact names and signatures.

```haskell
-- baikai-claude/src/Baikai/Provider/Claude/Agent.hs
data ClaudeAgentConfig = ClaudeAgentConfig
  { executable :: !FilePath, extraArgs :: ![Text], persistSession :: !Bool }
defaultClaudeAgentConfig :: ClaudeAgentConfig     -- "claude", [], False
claudeAgentCommand :: ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand

-- baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs
data CodexAgentConfig = CodexAgentConfig
  { executable :: !FilePath, extraArgs :: ![Text]
  , skipGitRepoCheck :: !Bool, ephemeral :: !Bool }
defaultCodexAgentConfig :: CodexAgentConfig       -- "codex", [], True, True
codexAgentCommand :: CodexAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand
```

Export both configuration types as bare type names with their field accessors listed
individually, plus the default value and the renderer, matching how
`Baikai.Provider.Claude.Interactive` exports `ClaudeInteractiveConfig`, `executable`,
`extraArgs`, `defaultClaudeInteractiveConfig`, and `claudeInteractiveCommand`. Because the two
configuration records live in different packages, their shared field names cannot conflict.

The capability mapping tables, restated as the contract later plans document to users:

```text
capability         Claude Code                          codex exec
read-only          --permission-mode plan               --sandbox read-only
edit-workspace     --permission-mode acceptEdits        --sandbox workspace-write
full-access        --permission-mode bypassPermissions  --sandbox danger-full-access

allowedTools       --allowedTools a,b,c                 refused: no such flag
extraDirs          --add-dir <d>  (tool access)         --add-dir <d>  (write access)
workingDir         process working directory only       --cd <d> and process working directory
prompt             standard input                       standard input
```

Downstream impact: additive minor releases for `baikai-claude` and `baikai-openai`. No existing
exported signature changes in this plan, so no dependent needs a bound change on account of it.
The provider-package **major** bumps that this initiative also requires come from
`docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md`, which changes the
interactive renderers' return types; the release coordinated by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` carries both.
