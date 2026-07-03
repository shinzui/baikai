---
id: 36
slug: harden-cli-subprocess-argument-and-pipe-handling
title: "Harden CLI subprocess argument and pipe handling"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Harden CLI subprocess argument and pipe handling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

baikai can drive the locally installed `claude` and `codex` command-line binaries as
model providers: `claude -p` and `codex exec` run as subprocesses and their output is
returned through the same `completeRequest` / `streamRequest` surface as the HTTP API
providers. It can also launch full interactive Claude Code and Codex terminal sessions.
The 2026-07-01 correctness review (`docs/reviews/2026-07-01-correctness-and-api-review.md`,
Theme 6) found three defects in how those subprocesses are invoked and drained, all in
paths the existing tests never exercise:

1. None of the four command builders terminates option parsing before the positional
   prompt. A user prompt that begins with `-` makes the CLI error out
   (`error: unknown option '-hello'`, verified against the real binaries on
   2026-07-01), and — worse — claude's *variadic* flags (`--allowedTools`,
   `--add-dir`) swallow the following positional argument. Concretely: launching an
   interactive Claude session with `safety = ClaudeAllowedTools [...]` and no extra
   args places `--allowedTools Read,...` directly before the prompt, so the user's
   prompt is consumed as an extra allowed-tool name and the session starts with **no
   prompt at all**. The review verified this empirically against the installed
   `claude` binary.
2. The codex batch provider reads the child's stdout to end-of-file *before* touching
   stderr, with no concurrent reader. A pipe has a finite kernel buffer (64 KiB on
   Linux and macOS); if `codex exec` writes more than that to stderr before finishing
   stdout, the child blocks on its stderr write while the parent blocks reading
   stdout — parent and child deadlock permanently.
3. The codex batch provider silently drops `Context.systemPrompt`: it renders only
   `Context.messages` into the prompt. A caller who sets a system prompt (as the
   documented examples in `docs/user/cli-providers.md` do) gets a subprocess that
   never sees it.

After this plan, a prompt that starts with `-` round-trips through every launch site,
an allowed-tools-restricted interactive Claude launch actually receives its prompt, a
stderr-flooding codex subprocess can no longer hang the caller (proved by a regression
test that fails against the old code), the codex batch provider sends the system
prompt, and a subprocess that dies mid-call is always reaped instead of lingering as a
zombie. You can see it working by running the two provider test suites (new pure
argument-construction tests plus a stub-subprocess deadlock test) and, optionally, by
invoking the real binaries with a leading-dash prompt.

Scope boundary: this plan owns subprocess *mechanics* only — argv construction, pipe
draining, exit-code handling, and process cleanup. The *shape* in which CLI providers
report errors (today they `throwIO` a `BaikaiError`; the masterplan's in-band error
contract will change that) is owned by
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (EP-6) and
is deliberately untouched here. New tests in this plan assert success paths and the
absence of deadlock, not error shapes, so EP-6 can land without rebasing them.


## Progress

- [x] Milestone 1: insert `--` before the positional prompt in
      `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`,
      `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`,
      `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, and
      `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`. Completed 2026-07-03.
- [x] Milestone 1: extract and export the pure batch command builders
      `claudeCliCommand` and `codexCliCommand`. Completed 2026-07-03.
- [x] Milestone 1: update the two existing interactive argv tests for the new `--`
      element and add batch argv tests (leading-dash prompt, variadic-flag adjacency)
      in `baikai-claude/test/Main.hs` and `baikai-openai/test/Main.hs`. Completed 2026-07-03.
- [x] Milestone 1 (optional, needs binaries): manual verification that `claude` and
      `codex` accept `--` before the prompt. Skipped 2026-07-03 because the plan marks
      it optional and the verification commands perform real model calls.
- [x] Milestone 2: add `wrapSystemPrompt` to
      `baikai/src/Baikai/Provider/Cli/Internal.hs`; wire it into the codex batch
      provider via `codexCliPrompt`; refactor `codexInteractivePrompt` to share it.
      Completed 2026-07-03.
- [x] Milestone 2: add `baikai/test/CliInternalSpec.hs` (renderPrompt +
      wrapSystemPrompt unit tests) and a codex batch system-prompt argv test.
      Completed 2026-07-03.
- [x] Milestone 2: update `docs/user/cli-providers.md` and
      `docs/user/interactive-launches.md` for the new behavior. Completed 2026-07-03.
- [x] Milestone 3: concurrent stderr drain + `withCreateProcess` cleanup in
      `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`; `withCreateProcess` in
      `launchCodexInteractive`. Completed 2026-07-03.
- [x] Milestone 3: stub-script stderr-flood regression tests in both provider test
      suites (codex test covers the fixed no-deadlock behavior; claude test pins
      cradle's already-safe behavior). Completed 2026-07-03.
- [x] Final: `cabal build all --enable-tests` and
      `cabal test baikai baikai-claude baikai-openai` green; tick the EP-3 entry in
      `docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`.
      Completed 2026-07-03.


## Surprises & Discoveries

Recorded during plan authoring (2026-07-01); keep appending during implementation.

- The Claude batch provider is *already* deadlock-safe and zombie-safe, because it
  uses the `cradle` library rather than raw `System.Process`. Audited
  `cradle/src/Cradle/ProcessConfiguration.hs` (source at
  `/Users/shinzui/Keikaku/hub/haskell/cradle-project`, found via `mori`): `runProcess`
  starts a forked reader per captured pipe (`forkIO $ hGetContents handle >>= putMVar
  mvar`, strict `Data.ByteString.hGetContents`) *before* calling `waitForProcess`, and
  its `withCreateProcess` brackets with `cleanupProcess`, which terminates **and
  reaps** the child on exception. So only the codex batch provider needs the pipe and
  cleanup fixes; the claude side gets a regression test that pins this property.
- `codex exec --help` (run 2026-07-01 against the installed binary,
  `/opt/homebrew/bin/codex`) exposes **no system-prompt or instructions flag**, so the
  system prompt must be carried in the prompt text (Milestone 2). The same help output
  shows codex has its own variadic flag (`-i, --image <FILE>...`) and that a prompt of
  exactly `-` means "read instructions from stdin" — with the provider's
  `std_in = NoStream` that would yield empty instructions; noted as an inherent CLI
  edge, not fixed here.
- Empirical failure transcripts (planning-time, real binaries):

  ```text
  $ claude -p "-hello"
  error: unknown option '-hello'

  $ codex exec "-hello"
  Run Codex non-interactively

  Usage: codex exec [OPTIONS] [PROMPT]
  ...
  ```

  (codex rejects the dash-leading prompt as an unknown option and dumps its usage
  text instead of running.)
- During implementation, `cabal test baikai baikai-claude baikai-openai` first failed
  because the new OpenAI stderr-flood test imported `directory` and `filepath` but the
  dependencies had been added to the library stanza instead of the test stanza. Moving
  those packages to `test-suite baikai-openai-test` fixed the compile error. Evidence:
  the rerun passed all three target suites, including the new OpenAI flood test in
  0.19s. (2026-07-03)


## Decision Log

- Decision: Fix the leading-dash and variadic-swallow failures by inserting the
  standard end-of-options separator `--` immediately before the positional prompt in
  all four launch sites, rather than validating or escaping prompt text.
  Rationale: `--` is the POSIX/clap convention for "everything after this is
  positional"; both binaries are clap-style parsers and the review verified `claude`
  honors `--` against the real binary (`codex` is also clap-based — its help output
  format is clap's). Escaping cannot fix variadic swallowing: `--allowedTools Read
  <prompt>` consumes any following token no matter its content.
  Date: 2026-07-01
- Decision: Expose pure batch command builders `claudeCliCommand :: ClaudeCliConfig ->
  Model -> Context -> (FilePath, [String])` and `codexCliCommand :: CodexCliConfig ->
  Model -> Context -> (FilePath, [String])`, mirroring the existing interactive
  builders `claudeInteractiveCommand` / `codexInteractiveCommand`.
  Rationale: both provider test suites already assert rendered argv for the
  interactive builders; the batch argv is currently built inline inside the IO run
  functions and therefore untestable without spawning a process. A pure builder makes
  the `--` fix and future argv changes unit-testable.
  Date: 2026-07-01
- Decision: Carry the codex batch system prompt inside the prompt text, using the
  exact wrapper format the interactive launcher already uses ("System
  instructions:\n…\n\nUser request:\n…"), implemented once as
  `wrapSystemPrompt :: Maybe Text -> Text -> Text` in
  `baikai/src/Baikai/Provider/Cli/Internal.hs` and shared by
  `codexInteractivePrompt`.
  Rationale: `codex exec --help` (verified 2026-07-01) has no system-prompt flag. The
  `-c key=value` config-override flag was considered and rejected: there is no
  documented top-level instructions key for `codex exec`, and an undocumented key
  could silently no-op. Sharing one function prevents the batch and interactive
  formats from drifting. Alternative recorded: if a future codex release adds a
  native flag, switch `codexCliPrompt` to it and keep `wrapSystemPrompt` for older
  binaries behind config.
  Date: 2026-07-01
- Decision: Drain codex stderr concurrently with a `forkIO` + `MVar` + strict
  `Data.ByteString.hGetContents` reader, not by adding an `async` dependency.
  Rationale: base-only, mirrors the pattern `cradle` uses internally (audited, see
  Surprises & Discoveries), and `baikai-openai` does not currently depend on `async`.
  Date: 2026-07-01
- Decision: Replace the hand-rolled `bracket createProcess cleanup` in `runCodexCli`
  (and the bare `createProcess`/`waitForProcess` in `launchCodexInteractive`) with
  `System.Process.withCreateProcess`.
  Rationale: the current custom `cleanup` closes the pipes and calls
  `terminateProcess` but never calls `waitForProcess`, so on exception the SIGTERMed
  child is never reaped and stays a zombie until the parent exits.
  `withCreateProcess` uses `cleanupProcess`, which closes handles, terminates, *and*
  waits.
  Date: 2026-07-01
- Decision: Keep the CLI providers' error-reporting shape (`throwIO` of
  `Baikai.Error.BaikaiError`) exactly as it is.
  Rationale: the masterplan's in-band error contract (error-shaped `Response` instead
  of throwing) is owned by
  `docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`; this
  plan owns subprocess mechanics only. New tests here assert success paths and a
  bounded-time completion, not error shapes, so EP-6 can change the contract without
  touching them.
  Date: 2026-07-01
- Decision: Leave the Claude batch provider on `cradle` and make no pipe/cleanup
  change there; add only the `--` fix, the pure builder, and a stderr-flood
  regression test that passes both before and after.
  Rationale: the audit (Surprises & Discoveries) shows cradle already drains both
  pipes on forked threads and reaps via `cleanupProcess`. The test pins that property
  so a future switch away from cradle cannot silently reintroduce the deadlock.
  Date: 2026-07-01


## Outcomes & Retrospective

EP-3 is complete as of 2026-07-03. All four CLI launch sites now render `--` before
the positional prompt, the batch argv builders are exported and tested, codex batch
requests carry `Context.systemPrompt` through the shared wrapper used by the
interactive launcher, and the codex batch provider drains stderr concurrently under
`withCreateProcess` so chatty subprocesses cannot deadlock or leave unreaped children
on exception. The Claude stderr-flood test pins cradle's existing concurrent-drain
behavior.

Validation passed with:

```text
cabal test baikai baikai-claude baikai-openai
cabal build all --enable-tests
pgrep -fl stderr-flood || true
```

The targeted suite run reported `All 99 tests passed` for `baikai-test`, `All 20 tests
passed` for `baikai-claude-test`, and `All 19 tests passed` for `baikai-openai-test`.
The process check printed no leftover `stderr-flood` processes. Optional live
`claude`/`codex` commands were skipped because they perform real model calls.


## Context and Orientation

baikai is a multi-package Haskell cabal project (repository root
`/Users/shinzui/Keikaku/bokuno/baikai`, all paths below are repository-relative). The
core package `baikai` defines the provider-neutral vocabulary; the vendor packages
`baikai-claude` and `baikai-openai` implement providers. Four *launch sites* build a
subprocess command line whose final argument is a free-text prompt:

- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` — the **batch** Claude provider.
  `runClaudeCli` (lines 163–187) builds
  `["-p"] <> modelArgs <> ["--output-format","json","--no-session-persistence"] <>
  systemPromptArgs <> extraArgs <> [prompt]` inline and runs it via the `cradle`
  library (`run $ cmd … & addArgs … & setNoStdin`), capturing exit code, stdout, and
  stderr. cradle reads both pipes on forked threads and brackets the child with
  `cleanupProcess`, so this site has the argv defect only. A non-zero exit throws
  `processError n stderrText`; malformed JSON throws `decodeError`; a CLI-reported
  error throws `providerError` — that throwing shape is out of scope here (EP-6).
- `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` — the **interactive**
  Claude Code launcher. `claudeInteractiveCommand` (lines 46–57) is a pure builder
  ending in `[Text.unpack (req ^. #userPrompt)]` (line 56). Its `safetyArgs` renders
  `ClaudeAllowedTools` as `["--allowedTools", "tool1,tool2"]` — and `--allowedTools`
  is a *variadic* claude flag, meaning it keeps consuming following arguments until
  it hits another option or `--`. When config/request `extraArgs` are empty, the
  prompt sits directly after the tool list and is swallowed as a tool name: the
  session launches with no prompt. `--add-dir` is variadic too. `launchClaudeInteractive`
  runs the command through cradle with inherited stdio (no pipes, no deadlock risk).
- `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` — the **batch** codex provider.
  `runCodexCli` (lines 119–141) builds
  `["exec"] <> modelArgs <> ["--json"] <> conditional flags <> extraArgs <> [prompt]`
  (prompt at line 129) and spawns via `System.Process.createProcess` with
  `CreatePipe` for stdout and stderr, wrapped in
  `bracket (createProcess …) cleanup (consume …)`. Three defects live here:
  - Line 120: `prompt = Internal.renderPrompt ctx` renders only `ctx.messages`;
    `ctx.systemPrompt` is silently dropped (the interactive launcher handles it via
    `codexInteractivePrompt`; the batch provider does not).
  - Lines 157–159 (`consume`): `parseCodexJsonlStream` drains stdout to EOF, *then*
    `BS.hGetContents hErr` reads stderr, with no concurrent reader. More than one
    pipe buffer (~64 KiB) of stderr written before stdout closes deadlocks parent
    and child permanently.
  - Lines 143–147 (`cleanup`): closes the two pipes and calls `terminateProcess`,
    but never `waitForProcess`. On the happy path `consume` itself waits (line 159),
    so cleanup's terminate is a no-op on the already-reaped handle; but if an
    exception escapes `consume` (decode failure, async cancellation), the child is
    SIGTERMed and never reaped — a zombie until the parent process exits. Exit codes
    themselves are handled (ExitFailure → `throwIO processError`).
- `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` — the **interactive**
  codex launcher. `codexInteractiveCommand` (lines 50–61) ends in
  `[Text.unpack (codexInteractivePrompt req)]` (line 60). `codexInteractivePrompt`
  (lines 66–76) already wraps the system prompt into the initial prompt text —
  Milestone 2 reuses its exact format. `launchCodexInteractive` (lines 80–93) uses
  bare `createProcess` + `waitForProcess` with inherited stdio: no pipe risk, but an
  exception between the two calls leaks an unreaped child.

Shared helpers live in `baikai/src/Baikai/Provider/Cli/Internal.hs`:
`renderPrompt :: Context -> Text` flattens a `Context`'s messages into one prompt
string (a single user text message passes through verbatim; anything else becomes a
`[role]:`-tagged transcript), `parseCodexJsonlStream` folds codex's `--json` stdout
(one JSON object per line) into the concatenated `agent_message` text, and
`decodeUtf8Lenient` decodes stderr bytes for error messages. This module is exposed
from the core package specifically for the vendor packages.

Dispatch background you need for the tests: providers register an `ApiProvider`
record into a `ProviderRegistry`
(`baikai/src/Baikai/Provider/Registry.hs`). `newProviderRegistry :: IO
ProviderRegistry` creates an isolated registry and `completeRequestWith ::
ProviderRegistry -> Model -> Context -> Options -> IO Response` dispatches through
it — so a test can register a CLI provider whose `executable` points at a stub shell
script and call it without touching the process-global registry. Both CLI config
records (`ClaudeCliConfig`, `CodexCliConfig`) carry an `executable :: FilePath`
override for exactly this purpose.

Existing tests: `baikai-claude/test/Main.hs` (`commandRenderingTest`, lines 64–97)
and `baikai-openai/test/Main.hs` (`commandRenderingTest`, lines 70–104) assert the
full rendered argv of the two *interactive* builders — these expected lists must gain
the new `--` element. There are no tests for the *batch* argv (it is currently built
inline in IO) and no tests for `renderPrompt`. Cabal test-suite names are
`baikai-claude-test`, `baikai-openai-test`, and `baikai-test`; `cabal test <package>`
runs a package's suites. The smoke suite (`baikai-smoke/test/Smoke.hs`,
`baikai-smoke/test/InteractiveSmoke.hs`) runs real binaries when present and skips
otherwise; it needs no changes but should still pass.

User-facing docs affected: `docs/user/cli-providers.md` (batch providers; its
"Configuration" example even shows `extraArgs = ["--allowed-tools", "Bash,Read"]`,
which today would swallow the prompt) and `docs/user/interactive-launches.md`
(interactive builders; describes the argv order the tests assert).

Term definitions used above: a *variadic flag* is a command-line option that accepts
one or more following values (clap's `num_args(1..)`), stopping only at the next
option token or at `--`. The *end-of-options separator* `--` tells such a parser
that every remaining argument is positional. A *zombie* is a child process that has
exited but whose exit status has not been collected with `waitForProcess`; it holds a
process-table slot until reaped or until the parent dies.


## Plan of Work

The work is three milestones. Milestone 1 fixes argument construction everywhere and
makes it unit-testable. Milestone 2 makes the codex batch provider send the system
prompt. Milestone 3 fixes the codex pipe deadlock and process cleanup and adds the
deadlock regression tests. Each milestone builds and tests green on its own.

### Milestone 1 — Terminate option parsing with `--` at all four launch sites

Scope: every subprocess command line gains a `--` immediately before its positional
prompt; the two batch providers get exported pure command builders; the provider test
suites assert the new argv. At the end of this milestone, a prompt beginning with `-`
and a `ClaudeAllowedTools` safety setting both produce a command line the CLIs parse
correctly, and `cabal test baikai-claude baikai-openai` proves it without spawning
anything.

In `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`: extract the inline argv from
`runClaudeCli` into a new exported pure function

```haskell
claudeCliCommand :: ClaudeCliConfig -> Model -> Context -> (FilePath, [String])
claudeCliCommand cfg m ctx =
  ( cfg ^. #executable,
    ["-p"]
      <> modelArgs m
      <> ["--output-format", "json", "--no-session-persistence"]
      <> systemPromptArgs ctx
      <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
      <> ["--", Text.unpack (Internal.renderPrompt ctx)]
  )
```

Add `claudeCliCommand` to the module export list with a haddock noting it exists so
argv is inspectable and testable, and that the trailing `--` prevents leading-dash
prompts and variadic flags (`--allowedTools`, `--add-dir`, possibly present in
`extraArgs`) from eating the prompt. Rewrite `runClaudeCli` to call it:

```haskell
runClaudeCli cfg m ctx _opts = do
  let (exe, args) = claudeCliCommand cfg m ctx
  start <- getCurrentTime
  (exitCode, StdoutRaw out, StderrRaw err) <-
    run $
      cmd exe
        & addArgs args
        & setNoStdin
        & Internal.maybeApply (cfg ^. #workingDir) setWorkingDir
  ...
```

(the `case exitCode of …` body is unchanged).

In `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs`, change the last element
of `claudeInteractiveCommand` from `<> [Text.unpack (req ^. #userPrompt)]` to
`<> ["--", Text.unpack (req ^. #userPrompt)]` and extend the function's haddock: the
prompt is preceded by `--` because `--allowedTools` and `--add-dir` are variadic.

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`: extract `baseArgs` from
`runCodexCli` into a new exported pure function

```haskell
codexCliCommand :: CodexCliConfig -> Model -> Context -> (FilePath, [String])
codexCliCommand cfg m ctx =
  ( cfg ^. #executable,
    ["exec"]
      <> modelArgs m
      <> ["--json"]
      <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
      <> ["--ephemeral" | cfg ^. #ephemeral]
      <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
      <> ["--", Text.unpack (Internal.renderPrompt ctx)]
  )
```

(In Milestone 2 the final element switches from `Internal.renderPrompt ctx` to
`codexCliPrompt ctx`.) `runCodexCli` builds `procSpec` from the pair:

```haskell
let (exe, args) = codexCliCommand cfg m ctx
    procSpec = (P.proc exe args) { ... unchanged ... }
```

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, change the last element
of `codexInteractiveCommand` to `<> ["--", Text.unpack (codexInteractivePrompt req)]`.

Tests. In `baikai-claude/test/Main.hs`, update `commandRenderingTest`'s expected list
so `"--"` appears between `"plan"` and `"inspect the repo"`, and add a new
`batchCommandRenderingTest` to the test group asserting `claudeCliCommand` output for
a config whose `extraArgs` end in a variadic flag pair and a context whose single user
message begins with a dash — the two real failure scenarios:

```haskell
batchCommandRenderingTest :: TestTree
batchCommandRenderingTest =
  testCase "claude -p argv terminates options before a dash-leading prompt" $ do
    let cfg =
          defaultClaudeCliConfig
            { executable = "/bin/claude",
              extraArgs = Vector.fromList ["--allowedTools", "Read"]
            }
        model =
          _Model
            & #modelId .~ "sonnet"
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx =
          _Context
            & #systemPrompt .~ Just "Be terse."
            & #messages .~ Vector.singleton (user "-begin with a dash")
    claudeCliCommand cfg model ctx
      @?= ( "/bin/claude",
            [ "-p",
              "--model", "sonnet",
              "--output-format", "json", "--no-session-persistence",
              "--system-prompt", "Be terse.",
              "--allowedTools", "Read",
              "--",
              "-begin with a dash"
            ]
          )
```

This requires importing `Baikai.Provider.Claude.Cli` in the test module (currently
only the Interactive module is imported); `user` and `_Model`/`_Context` come from
the `Baikai` umbrella already imported. Mirror the same two changes in
`baikai-openai/test/Main.hs`: update `commandRenderingTest`'s expected list (insert
`"--"` before the `"System instructions:…"` prompt string) and add a
`batchCommandRenderingTest` asserting `codexCliCommand defaultCodexCliConfig …` for a
dash-leading prompt yields
`("codex", ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "--",
"-begin with a dash"])` (empty `modelId` renders no `--model`; import
`Baikai.Provider.OpenAI.Cli` in the test module).

Manual verification (optional — skip if the binaries are absent; each of the second
and third commands performs one real, subscription-billed model call): confirm both
binaries honor `--`. From any directory:

```bash
claude -p "-hello"
# expected (pre- and post-fix binary behavior, proves the failure mode is real):
#   error: unknown option '-hello'

claude -p --output-format json --no-session-persistence --allowedTools Read -- "Reply with the single word: pong."
# expected: a JSON object whose "result" contains "pong" — i.e. with `--` the
# prompt is NOT consumed by --allowedTools and the call succeeds.

codex exec --skip-git-repo-check --ephemeral --json -- "Reply with the single word: pong."
# expected: JSONL events ending with an agent_message containing "pong".
```

Acceptance: `cabal build all --enable-tests` succeeds;
`cabal test baikai-claude baikai-openai` passes with the four argv tests green; the
optional manual commands behave as transcribed.

### Milestone 2 — Send the system prompt through the codex batch provider

Scope: `Context.systemPrompt` reaches the `codex exec` subprocess. At the end of this
milestone, a batch codex call with `systemPrompt = Just "…"` produces a prompt
argument that carries the system text, in the same wrapper format the interactive
launcher already uses, and the format is defined in exactly one place.

In `baikai/src/Baikai/Provider/Cli/Internal.hs`, add and export:

```haskell
-- | Wrap a rendered prompt with a system-instruction preamble for
-- CLIs that expose no native system-prompt flag. 'Nothing' and
-- blank system prompts return the body unchanged. The textual
-- format is shared by the codex batch provider and the codex
-- interactive launcher; change it in both directions or not at all.
wrapSystemPrompt :: Maybe Text -> Text -> Text
wrapSystemPrompt msp body = case Text.strip <$> msp of
  Nothing -> body
  Just "" -> body
  Just sp ->
    Text.concat
      [ "System instructions:\n",
        sp,
        "\n\nUser request:\n",
        body
      ]
```

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, add and export a pure prompt
builder and use it in `codexCliCommand` (replacing `Internal.renderPrompt ctx` in the
final argv element):

```haskell
-- | The full prompt text passed to @codex exec@: the flattened
-- conversation, wrapped with the system prompt when one is set.
-- @codex exec --help@ exposes no system-prompt flag (verified
-- 2026-07-01), so the system prompt travels in the prompt text,
-- mirroring 'Baikai.Provider.OpenAI.Interactive.codexInteractivePrompt'.
codexCliPrompt :: Context -> Text
codexCliPrompt ctx =
  Internal.wrapSystemPrompt (ctx ^. #systemPrompt) (Internal.renderPrompt ctx)
```

This module currently imports `Context` non-record-style
(`import Baikai.Context (Context)`) and already has `Control.Lens ((^.))` and
`Data.Generics.Labels ()` for the `#systemPrompt` label; no import changes beyond
what Milestone 1 introduced.

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, rewrite
`codexInteractivePrompt` as a call to the shared helper so the two formats cannot
drift:

```haskell
codexInteractivePrompt :: InteractiveLaunchRequest -> Text
codexInteractivePrompt req =
  Internal.wrapSystemPrompt (req ^. #systemPrompt) (req ^. #userPrompt)
```

(add `import Baikai.Provider.Cli.Internal qualified as Internal`). The existing
`promptRenderingTest` and the interactive `commandRenderingTest` expectation string
`"System instructions:\nBe precise.\n\nUser request:\ninspect the repo"` must still
pass unchanged — that is the proof the refactor preserved the format.

Tests. Add `baikai/test/CliInternalSpec.hs` exporting `tests :: TestTree`, register
it in the `testGroup` in `baikai/test/Main.hs`, and add `CliInternalSpec` to
`other-modules` of `test-suite baikai-test` in `baikai/baikai.cabal` (line 131 area).
Cover: `renderPrompt` returns a single user text message verbatim; `renderPrompt`
tags a multi-message context (`[user]: …\n[assistant]: …`); `wrapSystemPrompt
Nothing body == body`; `wrapSystemPrompt (Just "  ") body == body`;
`wrapSystemPrompt (Just "Be terse.") "hi"` equals
`"System instructions:\nBe terse.\n\nUser request:\nhi"`. In
`baikai-openai/test/Main.hs`, add a batch system-prompt test: `codexCliCommand` for a
context with `#systemPrompt .~ Just "Be terse."` and one user message `"ping"` ends
in `["--", "System instructions:\nBe terse.\n\nUser request:\nping"]`.

Docs. In `docs/user/cli-providers.md`: state under "Multi-message contexts" (or a new
short "System prompts" subsection) that the claude batch provider forwards
`Context.systemPrompt` via `--system-prompt` while the codex batch provider prepends
it to the prompt text as `System instructions: … / User request: …` because
`codex exec` has no system-prompt flag; and in "Common gotchas" note that both
providers pass `--` before the prompt, so prompts starting with `-` are safe and
config `extraArgs` must all be genuine flags/values (they sit before the `--`). In
`docs/user/interactive-launches.md`: update the two builder descriptions and the
"Extra Arguments" paragraph to say the builders render config extra args, then
request extra args, then `--`, then the initial prompt.

Acceptance: `cabal test baikai baikai-claude baikai-openai` green, including the new
`CliInternalSpec` group and the codex system-prompt argv test; grepping the codex
provider for `renderPrompt` shows it flows through `codexCliPrompt`.

### Milestone 3 — Concurrent stderr drain and exception-safe cleanup for codex

Scope: the codex batch provider can no longer deadlock on chatty stderr and always
reaps its child; both provider suites gain a stub-subprocess stderr-flood test. At
the end of this milestone, a stub "codex" that writes 1 MiB to stderr before its
stdout completes within the test timeout — a test that hangs (and fails via timeout)
against the pre-milestone code.

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, delete the `cleanup` function
and the `bracket` import, and rewrite the spawn/consume pair around
`System.Process.withCreateProcess` (which brackets with `cleanupProcess`: closes the
pipe handles, terminates, and — unlike the old code — `waitForProcess`es, so no
zombie survives an exception):

```haskell
runCodexCli :: CodexCliConfig -> Model -> Context -> Options -> IO Resp.Response
runCodexCli cfg m ctx _opts = do
  let (exe, args) = codexCliCommand cfg m ctx
      procSpec =
        (P.proc exe args)
          { P.std_in = P.NoStream,
            P.std_out = P.CreatePipe,
            P.std_err = P.CreatePipe,
            P.cwd = cfg ^. #workingDir
          }
  start <- getCurrentTime
  P.withCreateProcess procSpec (consume start m)

consume ::
  UTCTime ->
  Model ->
  Maybe Handle ->
  Maybe Handle ->
  Maybe Handle ->
  P.ProcessHandle ->
  IO Resp.Response
consume start m _ mOut mErr ph = do
  hOut <- maybe (throwIO (providerError "codex: stdout handle missing")) pure mOut
  hErr <- maybe (throwIO (providerError "codex: stderr handle missing")) pure mErr
  -- Drain stderr on its own thread so a chatty child can never fill
  -- the stderr pipe buffer and deadlock against our stdout read.
  -- Strict ByteString hGetContents reads to EOF; the try keeps a
  -- reader failure from leaving takeMVar blocked forever.
  errVar <- newEmptyMVar
  _ <-
    forkIO $ do
      r <- try (BS.hGetContents hErr) :: IO (Either SomeException BS.ByteString)
      putMVar errVar (either (const BS.empty) id r)
  body <- Internal.parseCodexJsonlStream (handleStream hOut)
  errBytes <- takeMVar errVar
  exitCode <- P.waitForProcess ph
  end <- getCurrentTime
  case exitCode of
    ExitFailure n -> throwIO (processError n (Internal.decodeUtf8Lenient errBytes))
    ExitSuccess -> pure ... -- Response construction unchanged
```

Import changes in that module: add `Control.Concurrent (forkIO)`,
`Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)`, and swap
`Control.Exception (bracket, throwIO)` for
`Control.Exception (SomeException, throwIO, try)`. The `hClose` import can go if now
unused. Error values raised (`processError`, `providerError`) are unchanged — EP-6
owns any change to that shape.

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, make
`launchCodexInteractive` exception-safe the same way:

```haskell
launchCodexInteractive cfg req = do
  let (exe, args) = codexInteractiveCommand cfg req
      spec =
        (P.proc exe args)
          { P.std_in = P.Inherit,
            P.std_out = P.Inherit,
            P.std_err = P.Inherit,
            P.cwd = req ^. #workingDir
          }
  code <- P.withCreateProcess spec (\_ _ _ ph -> P.waitForProcess ph)
  pure (_InteractiveLaunchResult InteractiveCodex code)
```

The Claude batch provider needs no code change (see Surprises & Discoveries: cradle
already drains concurrently and reaps via `cleanupProcess`); its haddock in
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs` should gain one sentence recording
that fact so the next reader does not re-audit.

Regression tests. Both tests write a stub POSIX shell script that floods stderr with
1 MiB (sixteen times the 64 KiB pipe buffer) *before* finishing stdout, register the
CLI provider into a fresh isolated registry with `executable` pointing at the stub,
and require completion within a 30-second `System.Timeout.timeout`. The tests assume
`/bin/sh` exists (true on the supported dev/CI platforms; if a Windows port ever
matters, guard on `os /= "mingw32"`).

In `baikai-openai/test/Main.hs` add (and register in the test group):

```haskell
stderrFloodTest :: TestTree
stderrFloodTest =
  testCase "codex batch provider survives a 1MiB stderr flood without deadlock" $ do
    dir <- getTemporaryDirectory
    let script = dir </> "baikai-codex-stderr-flood.sh"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "head -c 1048576 /dev/zero | tr '\\0' 'e' >&2",
          "printf '{\"type\":\"agent_message\",\"message\":\"pong\"}\\n'"
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    reg <- newProviderRegistry
    registerWithRegistryAndConfig reg defaultCodexCliConfig {executable = script}
    let model =
          _Model & #modelId .~ "" & #api .~ OpenAICompletionsCli & #provider .~ "openai"
        ctx = _Context & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30_000_000 (completeRequestWith reg model ctx _Options)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"
```

where `assistantText` is a small local helper extracting the concatenated
`AssistantText` blocks from `resp ^. #message ^. #content` (the test module has no
such helper today; pattern-match `AssistantText (TextContent t)` as
`baikai-smoke/test/Smoke.hs` does). New imports for the test module:
`Baikai.Provider.OpenAI.Cli` (Milestone 1 already added it),
`Baikai.Provider.Registry (completeRequestWith, newProviderRegistry)`,
`System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable,
setPermissions)`, `System.FilePath ((</>))`, `System.Timeout (timeout)`; enable
`NumericUnderscores` or write `30000000`. Add `directory` and `filepath` to the
`build-depends` of `test-suite baikai-openai-test` in
`baikai-openai/baikai-openai.cabal`.

In `baikai-claude/test/Main.hs` add the twin test with a stub emitting the claude
JSON shape after the flood —
`printf '{"result":"pong","is_error":false}\n'` — registered via
`Baikai.Provider.Claude.Cli.registerWithRegistryAndConfig reg defaultClaudeCliConfig
{executable = script}` and a model with `#api .~ AnthropicMessagesCli`. This test is
expected to pass *before* the milestone too (cradle is already safe); it exists to
pin that property. Add `directory` and `filepath` to
`test-suite baikai-claude-test` in `baikai-claude/baikai-claude.cabal`.

To observe the codex test actually catching the bug, run it once against the
pre-milestone `consume` (e.g. implement the test first): it must fail with the
timeout `assertFailure` after ~30 s. Record that transcript in Surprises &
Discoveries when it happens.

Acceptance: `cabal test baikai-openai` runs the flood test in bounded time and green;
`cabal test baikai-claude` green; on a machine with `ps`, running the flood test
leaves no `<defunct>` stub process behind (`ps aux | grep stderr-flood` after the
suite).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai`.

1. Milestone 1 edits: `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`
   (`claudeCliCommand`, export, rewrite `runClaudeCli`),
   `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` (`"--"` before prompt),
   `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` (`codexCliCommand`, export,
   rewrite `runCodexCli`'s arg construction),
   `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` (`"--"` before prompt),
   plus the four test additions/updates in `baikai-claude/test/Main.hs` and
   `baikai-openai/test/Main.hs`. Then:

   ```bash
   cabal build all --enable-tests
   cabal test baikai-claude baikai-openai
   ```

   Expected tail of each test run:

   ```text
   All N tests passed (…s)
   Test suite baikai-claude-test: PASS
   ```

   Optional binary check (only if `command -v claude` / `command -v codex` succeed;
   the pong invocations bill one call each):

   ```bash
   claude -p "-hello"                     # must print: error: unknown option '-hello'
   claude -p --output-format json --no-session-persistence --allowedTools Read -- "Reply with the single word: pong."
   codex exec --skip-git-repo-check --ephemeral --json -- "Reply with the single word: pong."
   ```

2. Milestone 2 edits: `baikai/src/Baikai/Provider/Cli/Internal.hs`
   (`wrapSystemPrompt` + export), `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`
   (`codexCliPrompt`, use in `codexCliCommand`),
   `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`
   (`codexInteractivePrompt` delegates to `Internal.wrapSystemPrompt`), new
   `baikai/test/CliInternalSpec.hs` wired into `baikai/test/Main.hs` and
   `baikai/baikai.cabal`, the codex system-prompt argv test, and the two doc files.
   Then:

   ```bash
   cabal build all --enable-tests
   cabal test baikai baikai-claude baikai-openai
   ```

3. Milestone 3, test-first: add `stderrFloodTest` to `baikai-openai/test/Main.hs`
   (with the cabal `build-depends` additions) *before* changing `consume`, and run

   ```bash
   cabal test baikai-openai
   ```

   Expected: the suite fails, with the flood test reporting after ~30 s:

   ```text
   codex batch provider survives a 1MiB stderr flood without deadlock: FAIL
     deadlock: stderr was not drained concurrently
   ```

   Then apply the `withCreateProcess` + concurrent-drain rewrite in
   `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, the `launchCodexInteractive`
   change, the claude twin test, and the claude haddock note; rerun:

   ```bash
   cabal build all --enable-tests
   cabal test baikai baikai-claude baikai-openai
   ```

   Expected: all suites pass, and the flood tests complete in a few seconds, not 30.

4. Wrap-up: update this plan's Progress/Surprises/Decision Log/Outcomes sections;
   tick the EP-3 checklist line in
   `docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`;
   optionally run the live smoke suite if binaries/keys are present:

   ```bash
   cabal test baikai-smoke
   ```

   Commit per milestone with conventional messages, e.g.:

   ```text
   fix(cli): terminate option parsing with -- before the positional prompt
   feat(cli): send the system prompt through the codex batch provider
   fix(cli): drain codex stderr concurrently and reap the child on exception
   ```


## Validation and Acceptance

Behavioral acceptance, all observable:

- Argument safety: `claudeCliCommand`, `codexCliCommand`, `claudeInteractiveCommand`,
  and `codexInteractiveCommand` each render `--` as the second-to-last argument, with
  the prompt last — asserted exactly by unit tests in `baikai-claude/test/Main.hs`
  and `baikai-openai/test/Main.hs` covering a dash-leading prompt and (claude) a
  trailing variadic `--allowedTools` flag. With real binaries,
  `claude -p … --allowedTools Read -- "Reply with the single word: pong."` returns a
  JSON result containing "pong" instead of launching promptless.
- System prompt: `codexCliCommand` on a context with
  `systemPrompt = Just "Be terse."` and user message `"ping"` ends in
  `["--", "System instructions:\nBe terse.\n\nUser request:\nping"]`; the interactive
  wrapper test string is byte-identical to before the refactor, proving one shared
  format.
- Deadlock: `stderrFloodTest` in `baikai-openai-test` fails by 30-second timeout
  against the pre-fix `consume` (run it once before fixing to capture the failing
  transcript) and completes in seconds after; the twin test in `baikai-claude-test`
  passes both before and after, pinning cradle's concurrent drain.
- Cleanup: after the flood tests run, no `<defunct>` stub process remains
  (`ps aux | grep stderr-flood`); an exception escaping `consume` can no longer skip
  `waitForProcess` because `withCreateProcess`'s `cleanupProcess` waits.
- Whole-project health, from the repository root:

  ```bash
  cabal build all --enable-tests
  cabal test baikai baikai-claude baikai-openai
  ```

  Every suite ends with `All N tests passed` / `PASS`. The smoke suite
  (`cabal test baikai-smoke`) still passes or skips cleanly when binaries/keys are
  absent.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build/test cycle; all can be re-run
safely. The milestones are independent enough to land as three separate commits, and
each leaves the tree green, so `git revert` of any single milestone is a safe
rollback. The stub-script tests overwrite a fixed file name under the system temp
directory (`getTemporaryDirectory </> "baikai-…-stderr-flood.sh"`) on every run, so
reruns are idempotent; a leftover script is harmless. The optional manual binary
checks are read-only apart from one billed model call each and can be repeated or
skipped freely (they are verification, not setup). If the Milestone 3 test-first run
is interrupted mid-timeout, simply rerun `cabal test baikai-openai` — the deadlocked
stub child is killed when the test process exits. If `cabal test` ever appears hung
during Milestone 3 work, that *is* the bug reproducing; Ctrl-C, apply or finish the
`consume` rewrite, and rerun.


## Interfaces and Dependencies

No new package dependencies for library code. `baikai-openai`'s library already
depends on `process`; the concurrency primitives (`forkIO`, `MVar`,
`System.Timeout.timeout`) come from `base`, and strict `Data.ByteString.hGetContents`
from `bytestring`. Test suites `baikai-claude-test` and `baikai-openai-test` each add
`directory` and `filepath` to `build-depends` (both already in the build plan via the
core package). The `cradle` library (used by the claude batch and interactive paths)
is unchanged; its concurrency/cleanup behavior is documented in Surprises &
Discoveries.

Signatures that must exist at the end of each milestone, with full module paths:

Milestone 1 —
`Baikai.Provider.Claude.Cli.claudeCliCommand :: ClaudeCliConfig -> Model -> Context -> (FilePath, [String])`
(exported, in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`) and
`Baikai.Provider.OpenAI.Cli.codexCliCommand :: CodexCliConfig -> Model -> Context -> (FilePath, [String])`
(exported, in `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`); the existing
`claudeInteractiveCommand` and `codexInteractiveCommand` keep their signatures but
render the extra `"--"` element.

Milestone 2 —
`Baikai.Provider.Cli.Internal.wrapSystemPrompt :: Maybe Text -> Text -> Text`
(exported, in `baikai/src/Baikai/Provider/Cli/Internal.hs`) and
`Baikai.Provider.OpenAI.Cli.codexCliPrompt :: Context -> Text` (exported);
`Baikai.Provider.OpenAI.Interactive.codexInteractivePrompt` keeps its signature and
delegates to `wrapSystemPrompt`.

Milestone 3 — no new public signatures; `runCodexCli` and `launchCodexInteractive`
keep their signatures but route through `System.Process.withCreateProcess`, and the
private `consume` in `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` becomes
`UTCTime -> Model -> Maybe Handle -> Maybe Handle -> Maybe Handle -> P.ProcessHandle -> IO Resp.Response`
to match `withCreateProcess`'s callback shape. Tests use
`Baikai.Provider.Registry.newProviderRegistry :: IO ProviderRegistry` and
`Baikai.Provider.Registry.completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response`,
both already exported from `baikai/src/Baikai/Provider/Registry.hs`.

Cross-plan interfaces: error values raised by the CLI providers (`processError`,
`decodeError`, `providerError` from `baikai/src/Baikai/Error.hs`, delivered via
`throwIO`) are consumed as-is;
`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md` (EP-6)
will convert that reporting to the masterplan's in-band contract and must rebase on
this plan's reshaped `runCodexCli`/`consume`. Any change EP-6 needs in these
functions' error paths belongs in its plan, not silently here.
