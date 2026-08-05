---
id: 48
slug: build-the-baikai-agent-package-and-unattended-process-runner
title: "Build the baikai-agent package and unattended process runner"
kind: exec-plan
created_at: 2026-07-30T04:35:45Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
master_plan: "docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md"
---

# Build the baikai-agent package and unattended process runner

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

An earlier plan, `docs/plans/45-add-the-unattended-agent-run-core-abstraction.md`, added a way to
*describe* an **unattended coding-agent run**: starting the `claude` or `codex` command-line tool
with no human present and no terminal, letting it edit files inside directories it was explicitly
authorized to touch, and collecting a process result. Another plan,
`docs/plans/46-render-claude-and-codex-unattended-agent-commands.md`, turns such a description
into a concrete executable name and argument list. Neither of them starts a process. Nothing in
the repository can actually run one.

This plan builds the thing that runs it. After this plan, a Haskell programmer can hand a
description and a rendered command to one function and get back an exit code, the captured output,
and how long it took — or a structured failure saying the tool could not be started, or that it
ran past its deadline and was killed.

Running an unattended coding agent correctly is more delicate than it sounds, and the four hard
parts are why this is its own plan. The prompt has to reach the tool on **standard input**, because
that is what keeps a prompt beginning with a dash from being read as a flag. Output has to be
**drained while the process runs**, because a pipe has a fixed-size buffer and a coding agent that
prints more than that will block forever if nobody is reading. A **timeout has to kill the whole
process group**, not just the tool, because a coding agent spawns its own child processes and
killing the parent alone leaves them running. And **captured output has to be bounded**, because
an agent stuck in a loop can print without limit and must not be able to exhaust the calling
process's memory.

This plan also creates the new `baikai-agent` package that holds this code and the two plans that
follow it. That package is where every dependency the core library refuses to take — process
spawning, filesystem access, configuration parsing, command-line parsing — is allowed to live.

**The observable outcome**, verifiable by running one test command: after this plan,
`cabal test baikai-agent-test` passes with cases driven by small shell scripts written into a
temporary directory. One proves a prompt written to standard input comes back on standard output.
One proves a script that sleeps past its deadline is killed and reported as a timeout rather than
hanging the suite. One proves a script that exits non-zero produces a successful result carrying
that exit code, not a failure. One proves a script printing a megabyte is truncated at a
configured byte limit and flagged as truncated. No coding-agent binary and no model is involved in
any of them.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 (2026-08-05): Created the `baikai-agent` package skeleton — directory, `LICENSE`,
      `baikai-agent.cabal`, a placeholder module, and a `tasty` test suite — and registered it in
      `cabal.project` and `agents/skills/release/SKILL.md` as the seventh publishable package.
      Committed on its own as the checkpoint that unblocks
      `docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`.
- [x] Milestones 2 through 4 (2026-08-05): Implemented `runAgentCommand` — preconditions,
      standard-input prompt delivery, the three output disciplines with concurrent draining and
      byte limits, and the timeout with process-group termination. Written as one module rather
      than three checkpoints because the three concerns are one function's control flow; each is
      pinned separately by Milestone 5's cases, which is where the independent verification
      actually lives.
- [x] Milestone 5 (2026-08-05): Added the fake-executable suite. `cabal test baikai-agent-test`:
      all 17 tests passed, including the grandchild-termination case and the timeout conversion
      unit tests. No coding-agent binary and no model is involved in any of them.
- [x] Milestone 6 (2026-08-05): Documented `runAgentCommand` and its four caller-visible behaviors
      in `docs/user/interactive-launches.md`, added the package to the root `README.md` table and
      a `baikai-agent` bullet to the root `CHANGELOG.md`, and ran the full offline validation.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (Milestone 5, 2026-08-05): **an interrupt to the process group does not kill a coding
  agent's shell-spawned children.** The grandchild test failed on its first run — the background
  child survived and touched its marker file:

  ```text
  kills grandchildren when the group is terminated:  FAIL (7.42s)
    test/Main.hs:226:
    the grandchild was terminated with its group
  ```

  The cause is POSIX shell semantics, not a bug in the signal code. A non-interactive shell is
  required to set `SIGINT` to *ignored* in the background commands it starts, so
  `interruptProcessGroupOf` — the only group-wide signal the `process` package offers — reaches the
  agent and not the children it backgrounded. Worse, the interrupt *succeeds* at killing the agent,
  so the leader exits inside the grace period and the plan's escalation to `terminateProcess` never
  runs; the grandchild outlives everything and keeps writing to the working tree a script is about
  to inspect and commit.

  The fix is to escalate to a group-wide `SIGTERM` **whether or not the leader stopped**, which
  needs `System.Posix.Signals.signalProcessGroup` because `process` has no group-wide terminate.
  One ordering detail is load-bearing: `P.getPid` returns `Nothing` once a process has been reaped,
  so the group's identifier must be read *before* the grace-period wait, not after. With that in
  place the test passes in about 5 seconds.

- Discovery (Milestone 3, 2026-08-05): the plan's draining shape — standard error on a forked
  thread, standard output on the waiting thread — is correct for the no-timeout case but makes the
  timeout unreachable whenever output is captured. A drain on the waiting thread blocks until the
  child closes the pipe, so a sleeping child would never let the code reach `waitWithTimeout` at
  all. Both drains are therefore forked and the wait happens on this thread. The plan's deadlock
  warning still governs the *ordering* — draining must start before the wait — and only the
  question of which thread does the reading changed.

- Discovery (Milestone 5, 2026-08-05): the `PromptAsArgument` transport gives the child no standard
  input at all, and a fixture that reads standard input therefore *fails* rather than reading
  nothing. `cat` under that transport exits 1 with a bad-file-descriptor error. That failure is
  itself the evidence the transport is honored, so the fixture tolerates it with
  `cat 2>/dev/null || true` and asserts the captured output is exactly the argument. This is the
  only place the two-sided contract can be observed, since no shipped vendor renderer selects the
  transport.

- Discovery (Milestone 5, 2026-08-05): a test comparing the child's `pwd` against the request's
  working directory must compare basenames on macOS. `withSystemTempDirectory` returns a path under
  `/var/folders/…`, which the child resolves to `/private/var/folders/…` — the same directory by a
  different path. Comparing the full strings fails for a reason that has nothing to do with the
  behavior under test.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `System.Process` directly rather than the `cradle` library, and put the `process`
  dependency in this new package rather than in core `baikai`.
  Rationale: `cradle` cannot express what this plan needs. Its configuration surface, in the
  dependency source at `/Users/shinzui/Keikaku/hub/haskell/cradle-project`, offers
  `setStdinHandle :: Handle`, `setNoStdin`, `addStdoutHandle`, `silenceStdout`, `setWorkingDir`,
  and `modifyEnvVar` — but no timeout, no way to write a `ByteString` to a child's standard input,
  no output-size bound, and no process-group control. `baikai-openai` already uses `System.Process`
  directly for its Codex batch provider, so this is an established pattern rather than a new one.
  Core `baikai` deliberately depends on none of `process`, `directory`, or `filepath`, and
  `Baikai.Interactive` and `Baikai.Agent` are both pure vocabulary; keeping it that way is why
  this package exists.
  Date: 2026-07-30

- Decision: Drain standard output and standard error on separate threads started before waiting on
  the process.
  Rationale: an operating-system pipe holds a bounded amount of data, typically 64 kilobytes. If
  the parent waits for the child to exit before reading, and the child writes more than the buffer
  holds, the child blocks on write while the parent blocks on wait, and neither ever proceeds. A
  coding agent easily prints more than 64 kilobytes. `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`
  already solves the same problem with `forkIO` plus an `MVar`, and this plan reuses that shape
  rather than adding an `async` dependency for two threads.
  Date: 2026-07-30

- Decision: On timeout, signal the child's **process group**, not just the child, and spawn with
  `create_group = True` so a group exists to signal.
  Rationale: a coding agent runs shell commands as its own children. Terminating only the agent
  leaves those grandchildren running, holding the working tree open and possibly still writing to
  it — which for an unattended run that a script is about to inspect and commit is a correctness
  problem, not just untidiness. Escalate rather than going straight to a hard kill: interrupt the
  group first so the tool can clean up, then terminate. This is safe here because unattended runs
  never inherit standard input, so putting the child in its own process group cannot detach it from
  a terminal it needed.
  Date: 2026-07-30

- Decision: A non-zero exit code is a **successful** run, reported in `AgentRunResult`, not an
  `AgentRunFailure`.
  Rationale: a coding agent that attempts its task and fails has run. The distinction the caller
  needs is between "the tool never started or never finished" and "the tool ran and this is what
  happened", and collapsing them would force every caller to re-derive it. The consuming shell
  script decides what a non-zero code means for its workflow; the first consumer treats it as
  fatal, but that is the script's policy, not the library's.
  Date: 2026-07-30

- Decision: When output exceeds the byte limit, keep reading and discard the excess rather than
  closing the pipe early.
  Rationale: closing the read end early makes the child's next write fail, which for a coding agent
  usually means a crash and a confusing error attributed to the tool rather than to the limit. Read
  to the end, retain the first N bytes, and report `OutputTruncated` so the caller knows the value
  is partial.
  Date: 2026-07-30

- Decision: Fork **both** drain threads and wait for the process on the calling thread, rather than
  draining standard output on the calling thread as this plan originally specified.
  Rationale: a drain on the waiting thread blocks until the child closes the pipe, which means the
  timeout is never reached whenever output is captured — a sleeping child would hang the caller
  forever despite having a deadline. The plan's real requirement, that draining start before the
  wait so a full pipe cannot deadlock, is satisfied either way. The cost is one extra thread; the
  benefit is that the timeout works in all three output modes rather than only in `InheritOutput`.
  Date: 2026-08-05

- Decision: Escalate a timed-out run to a group-wide `SIGTERM` unconditionally, using
  `System.Posix.Signals.signalProcessGroup` behind a non-Windows Cabal conditional, rather than
  stopping at this plan's interrupt-then-`terminateProcess` sequence.
  Rationale: POSIX requires a non-interactive shell to ignore `SIGINT` in the background commands
  it starts, so the group interrupt kills the agent while leaving exactly the grandchildren it was
  meant to reach. Because the interrupt succeeds against the leader, the leader exits inside the
  grace period and the planned `terminateProcess` escalation never runs at all. The `process`
  package offers a group-wide interrupt but no group-wide terminate, so reaching the survivors
  requires the POSIX signal API. It is added under `if !os(windows)` with a CPP guard so the
  package still builds on Windows, where `interruptProcessGroupOf` sends `CTRL_BREAK` to the group
  and is the platform's own group mechanism. Evidence is in Surprises & Discoveries: the
  grandchild test fails without this and passes with it.
  Date: 2026-08-05

- Decision: `RunTimedOut` reports `0` when a run times out under a request whose `timeout` is
  somehow absent.
  Rationale: unreachable in practice, since a run only times out when a limit was converted
  successfully, but the failure constructor requires a duration and inventing a measured one would
  contradict this plan's own rule that the *configured* limit is what gets reported. Zero reads as
  "no limit was configured", which is the honest description of that impossible state.
  Date: 2026-08-05

- Decision: The child inherits the parent's full environment; `envPassthrough` is validated as a
  precondition rather than used to filter.
  Rationale: both tools need `HOME`, `PATH`, and their own credential files to authenticate, so
  restricting the child's environment to an allow-list would break them. What the declared list
  buys is a clear error — `MissingEnvironment` naming every declared variable that is unset or
  empty — instead of an agent that starts and then fails for reasons the operator has to guess.
  Date: 2026-07-30


## Outcomes & Retrospective

This section was missing from the plan as authored; the ExecPlan specification requires it, so it
was added during implementation on 2026-08-05 in its skeleton position between the Decision Log and
Context and Orientation.

Completed 2026-08-05. The repository can now actually run an unattended coding agent, which nothing
in it could do before. `baikai-agent` exists as the eighth workspace package and the seventh
publishable one, depends on `baikai` and on neither provider package, and exports
`runAgentCommand :: AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)`.

The observable outcome the Purpose section promised holds. `cabal test baikai-agent-test` passes
with 17 cases driven by shell scripts written into temporary directories: a non-ASCII prompt
round-trips through `cat` on standard input, a script sleeping five seconds under a one-second
timeout is killed and reported as a timeout in about a second rather than hanging the suite, a
script exiting 3 produces a successful result carrying that code, and a script printing 20
kilobytes is truncated at exactly 1024 bytes and still reports success. No coding-agent binary and
no model is involved in any of them. By hand, in the REPL:

```text
Right (ExitSuccess,Just "hello from stdin")
```

The full offline validation is green: `nix fmt`, `git diff --check`, `cabal build all`, the key- and
CLI-scrubbed `cabal test all` (168 core, 174 Claude, 81 Codex, 29 kit, 17 agent, and the rest, with
the smoke suite reporting no keys or binaries and skipping every live case), and `nix flake check`.

Two designs in this plan turned out to be wrong in the same direction, and both were caught by
tests rather than by review. Draining standard output on the waiting thread makes the timeout
unreachable whenever output is captured. Interrupting the process group does not kill a coding
agent's shell-spawned children, because POSIX requires a non-interactive shell to ignore `SIGINT` in
background commands — and because the interrupt does kill the agent, the planned escalation never
runs. Both are recorded in Surprises & Discoveries with the failing output, and both fixes are in
the Decision Log. The lesson is the plan's own: the grandchild test is the most valuable one here
and the easiest to omit, and it is the only reason the second defect was found at all. A reviewer
reading the signal code would have seen a group interrupt followed by an escalation and concluded,
reasonably and wrongly, that grandchildren die.

What remains is the rest of the initiative rather than a gap in this plan. Nothing imports
`Baikai.Agent.Run` yet;
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` adds configuration
modules alongside it in this package, and
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` is its first caller
and adds the `executable baikai` stanza. One constraint this plan introduces for them: the package
now carries a non-Windows Cabal conditional and a CPP guard, so a module added later that needs
POSIX signals should reuse `BAIKAI_POSIX_SIGNALS` rather than introducing a second spelling.


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository.

Baikai is a multi-package Cabal workspace. Cabal is the Haskell build tool; a package is a
directory containing a `.cabal` file that describes what to build. The packages that exist before
this plan are listed in `cabal.project` at the repository root:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-smoke
  baikai-trace-otel
  baikai-effectful
  baikai-kit
```

This plan adds an eighth, `baikai-agent`. It is the first package in the workspace whose purpose is
to *do* things rather than describe them, and it is where two later plans add their code as well:
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` adds configuration
loading, and `docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` adds the
command-line executable. You are creating the skeleton all three share, so follow the file layout
below exactly.

### What earlier plans produced that you consume

`docs/plans/45-add-the-unattended-agent-run-core-abstraction.md` created
`baikai/src/Baikai/Agent.hs`. Read it before starting. The names this plan uses:

```haskell
data AgentProvider = AgentClaude | AgentCodex

data AgentRunRequest = AgentRunRequest
  { provider :: !AgentProvider, prompt :: !Text, modelId :: !(Maybe Text)
  , effort :: !(Maybe ThinkingLevel), workingDir :: !FilePath, extraDirs :: ![FilePath]
  , safety :: !AgentSafety, timeout :: !(Maybe NominalDiffTime)
  , output :: !AgentOutputMode, outputLimit :: !(Maybe Int), envPassthrough :: ![Text] }
agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest

data AgentOutputMode = InheritOutput | CaptureOutput | TeeOutput
data AgentCapturedOutput = OutputNotCaptured | OutputCaptured !ByteString | OutputTruncated !ByteString

data AgentPromptTransport = PromptOnStdin | PromptAsArgument
data AgentCommand = AgentCommand
  { executable :: !FilePath, arguments :: ![String]
  , promptTransport :: !AgentPromptTransport, promptText :: !Text }

data AgentRunResult = AgentRunResult
  { provider :: !AgentProvider, exitCode :: !ExitCode
  , stdout :: !AgentCapturedOutput, stderr :: !AgentCapturedOutput
  , duration :: !NominalDiffTime }
agentRunResult :: AgentProvider -> ExitCode -> NominalDiffTime -> AgentRunResult

data AgentRunFailure
  = SpawnFailed !FilePath !Text
  | RunTimedOut !NominalDiffTime
  | MissingEnvironment ![Text]
  | WorkingDirMissing !FilePath
  | OutputMalformed !Text
renderAgentRunFailure :: AgentRunFailure -> Text
```

Two things about that module matter here. It is **not** re-exported from the umbrella module
`baikai/src/Baikai.hs`, because its field accessor names would conflict with
`Baikai.Interactive`'s, so you must `import Baikai.Agent` explicitly. And `AgentCommand` carries
no working directory on purpose: Claude Code has no working-directory flag, so the working
directory is a process-level setting. That is why this plan's entry point takes **both** the
request and the command.

You do **not** need `docs/plans/46-render-claude-and-codex-unattended-agent-commands.md` to be
complete before starting. The runner accepts an already-rendered `AgentCommand` and never imports
a vendor renderer, so you can build and test everything here with hand-written argument vectors
pointing at shell scripts. That decoupling is deliberate and lets the two plans proceed in
parallel.

### The existing code that solves half your problem

`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` spawns `codex exec` with `System.Process` and
drains its output concurrently. Read its `runCodexCli` and `consume` functions; they are the closest
working example in the repository:

```haskell
runCodexCli cfg m ctx opts = do
  let (exe, args) = codexCliCommand cfg m ctx opts
      procSpec = (P.proc exe args)
        { P.std_in = P.NoStream, P.std_out = P.CreatePipe
        , P.std_err = P.CreatePipe, P.cwd = cfg ^. #workingDir }
  start <- getCurrentTime
  result <- trySync (P.withCreateProcess procSpec (consume start m))
  ...

consume start m _ mOut mErr ph = do
  ...
  errVar <- newEmptyMVar
  _ <- forkIO $ do
        result <- try (BS.hGetContents hErr) :: IO (Either SomeException BS.ByteString)
        putMVar errVar (either (const BS.empty) id result)
  body <- Internal.parseCodexJsonlStream (handleStream hOut)
  errBytes <- takeMVar errVar
  exitCode <- P.waitForProcess ph
  ...
```

Note the pattern: standard error is drained on a forked thread whose result arrives through an
`MVar`, standard output is drained on the calling thread, and only after both are finished does the
code wait for the process. Reuse that structure. Also note `trySync`, defined at the bottom of that
file, which catches synchronous exceptions while re-throwing asynchronous ones — copy it, because
swallowing an asynchronous exception would break the timeout you are about to build.

What that code does **not** do, and you must: write to standard input, enforce a timeout, bound the
captured bytes, tee output to the parent, or control the process group.

### Package conventions you must follow

Every package in this workspace uses the same `.cabal` preamble. Copy it from
`baikai-kit/baikai-kit.cabal`, which is the newest and smallest package and therefore the cleanest
template. The parts that must match:

```cabal
cabal-version: 3.4
build-type:    Simple
category:      AI
license:       BSD-3-Clause
license-file:  LICENSE
author:        Nadeem Bitar
maintainer:    nadeem@gmail.com
copyright:     (c) 2026 Nadeem Bitar

common common-options
  ghc-options:
    -Wall -Wcompat -Widentities -Wincomplete-uni-patterns
    -Wincomplete-record-updates -Wredundant-constraints
    -fhide-source-paths -Wmissing-export-lists -Wpartial-fields
    -Wmissing-deriving-strategies

  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings
```

Every package needs its own `LICENSE` file; copy `baikai-kit/LICENSE`. Note that `baikai-kit` has
`license-file: LICENSE` but no `extra-doc-files`, while `baikai/baikai.cabal` has
`extra-doc-files: CHANGELOG.md`. There is exactly one changelog in this repository, at the root, so
follow `baikai-kit` and omit `extra-doc-files`.

Field names carry no type prefix anywhere in this repository — write `executable`, not
`runnerExecutable`. This applies to internal helper records too. `-Wall` includes
`-Wincomplete-patterns`, and `-Wmissing-export-lists` requires an explicit export list on every
module. There is no `-Werror`, so read build output rather than trusting a zero exit status.
Formatting is `nix fmt`, which runs `fourmolu` using `fourmolu.yaml`.

The release workflow at `agents/skills/release/SKILL.md` enumerates the publishable packages in
dependency order and states that this repository must publish packages resolving **from Hackage
only**. Adding a package means adding it to that enumeration, which Milestone 1 does. The
`baikai-smoke` package is the one exception: it is internal and never published.

The repository's Nix setup does not need changing. `flake.nix` imports `./nix/haskell.nix`,
`./nix/treefmt.nix`, and `./nix/pre-commit.nix`, and a comment in `flake.nix` states that the
project builds via `cabal` in the dev shell and exposes no Nix package output. Adding a Cabal
package therefore requires no Nix edit.


## Plan of Work

Six milestones. Milestone 1 creates a package that builds and tests but does nothing. Milestones 2
through 4 build up the runner, each independently verifiable. Milestone 5 adds the integration
tests that make it all observable. Milestone 6 documents and validates.

### Milestone 1 — A package skeleton that builds

Scope: create the `baikai-agent` package with a placeholder module and a working test suite, and
register it everywhere it must appear. At the end of this milestone `cabal build baikai-agent` and
`cabal test baikai-agent-test` both succeed and the package appears in the release workflow.

Create this file layout:

```text
baikai-agent/
  LICENSE                        (copied from baikai-kit/LICENSE)
  baikai-agent.cabal
  src/Baikai/Agent/Run.hs
  test/Main.hs
```

Write `baikai-agent/baikai-agent.cabal` using the preamble from Context and Orientation, with:

```cabal
name:      baikai-agent
version:   0.1.0.0
synopsis:  Unattended coding-agent runs for the Baikai abstraction
```

Give the library stanza `hs-source-dirs: src`, `exposed-modules: Baikai.Agent.Run`, and these
`build-depends`, each with the same version bound the rest of the workspace uses so the whole
build plan stays consistent:

```cabal
  build-depends:
    , baikai      ^>=0.4.1
    , base        >=4.20  && <5
    , bytestring  ^>=0.12
    , directory   ^>=1.3
    , generic-lens ^>=2.3
    , lens        ^>=5.3
    , process     ^>=1.6
    , text        ^>=2.1
    , time        ^>=1.14
```

Check the exact `baikai` version currently in `baikai/baikai.cabal` and match its major series;
at the time of writing it is `0.4.1.0`. Do **not** add `baikai-claude` or `baikai-openai` here.
The runner never imports a vendor renderer, and adding those dependencies now would create a
coupling that the next two plans would inherit for no reason;
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` adds them when the
executable needs to dispatch on provider.

Give the test suite stanza `type: exitcode-stdio-1.0`, `hs-source-dirs: test`, `main-is: Main.hs`,
and `ghc-options: -threaded -with-rtsopts=-N`. The `-threaded` flag is **not optional** in this
package: this plan forks threads to drain pipes and relies on `System.Timeout.timeout` interrupting
a blocking wait, and both behave differently without the threaded runtime.
`baikai-kit/baikai-kit.cabal` shows the same options on its test suite. Test dependencies:

```cabal
  build-depends:
    , baikai
    , baikai-agent
    , base
    , bytestring
    , directory
    , filepath
    , process
    , tasty
    , tasty-hunit
    , temporary
    , text
    , time
```

Write a placeholder `baikai-agent/src/Baikai/Agent/Run.hs` with a module header, an explicit export
list, and one trivial exported value so the module is not empty. Write
`baikai-agent/test/Main.hs` as a `tasty` entry point with one passing placeholder case, following
`baikai-kit/test/Main.hs` for shape.

Add `baikai-agent` to `cabal.project`, after `baikai-kit`.

Add `baikai-agent` to `agents/skills/release/SKILL.md`. Read its "Publishable packages (in
dependency order)" section first: it currently lists six numbered packages, states the dependency
ordering rule that `baikai` publishes first, and lists the `baikai ^>=` bound that every dependent
carries. Add `baikai-agent` as a seventh entry, note that it depends on `baikai` and — after
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` — on both provider
packages, so it publishes after all three. Also add its tag prefix to the list of per-package git
tag prefixes. Doing this now, rather than at release time, means the enumeration is never silently
wrong.

Verify:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

Commit this milestone on its own. A package skeleton that builds is a clean, revertible checkpoint,
and it unblocks
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`, which hard-depends
on this package existing.

### Milestone 2 — Preconditions, spawn, and the prompt on standard input

Scope: implement the checks that run before spawning and the simplest working spawn path. At the
end of this milestone a test can run `/bin/cat` with a prompt on standard input and get the prompt
back.

Replace the placeholder `baikai-agent/src/Baikai/Agent/Run.hs`. Its module header should state that
this module spawns an unattended coding-agent process from a request and an already-rendered
command; that it never renders flags itself, because vendor packages own that; and that a non-zero
exit code is a successful result rather than a failure.

The entry point:

```haskell
runAgentCommand ::
  AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
```

Begin with the preconditions, in this order, so the cheapest and most informative checks come
first.

Check the working directory with `System.Directory.doesDirectoryExist`. If it does not exist,
return `Left (WorkingDirMissing (req ^. #workingDir))` without spawning. Without this check a
missing directory surfaces as an opaque spawn failure that appears to blame the coding-agent
binary.

Check the declared environment variables. For every name in `req ^. #envPassthrough`, look it up
with `System.Environment.lookupEnv` and treat both an absent variable and one whose value is empty
as missing. Collect **all** missing names and return
`Left (MissingEnvironment missing)` if the list is non-empty. Collect rather than
short-circuit, so an operator fixing a job configuration sees every problem in one run.

Then build the process specification:

```haskell
let spec =
      (P.proc (cmd ^. #executable) (cmd ^. #arguments))
        { P.cwd = Just (req ^. #workingDir),
          P.std_in = stdinSpec,
          P.std_out = outSpec,
          P.std_err = outSpec,
          P.create_group = True,
          P.env = Nothing
        }
```

`P.env = Nothing` means the child inherits the parent's environment, which both tools need for
authentication; the Decision Log explains why this is not filtered. `create_group = True` creates a
process group so the timeout in Milestone 4 has something to signal; introduce it now so you are
not changing the spawn specification later.

`stdinSpec` follows the prompt transport, and getting this wrong is the one mistake that silently
corrupts a run:

```haskell
stdinSpec = case cmd ^. #promptTransport of
  PromptOnStdin -> P.CreatePipe
  PromptAsArgument -> P.NoStream
```

For `PromptAsArgument` the prompt is already the last element of `arguments`, so the child must get
no standard input at all. Supplying both is specifically harmful for Codex, which documents that
piped standard input alongside a positional prompt is appended as a separate `<stdin>` block — the
agent would receive the prompt twice.

For this milestone set `outSpec = P.Inherit` unconditionally; Milestone 3 makes it depend on the
output mode.

Spawn with `P.withCreateProcess`, which guarantees the handles are closed and the process is
reaped even if an exception passes through. Wrap the whole spawn in the `trySync` helper copied
from `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, and convert a caught exception to
`Left (SpawnFailed (cmd ^. #executable) (Text.pack (displayException e)))`. Copy `trySync` rather
than using a plain `try`: it re-throws asynchronous exceptions, which is what lets Milestone 4's
timeout work, and a plain `try` would swallow the timeout's own exception and hang.

When the transport is `PromptOnStdin`, write the prompt and **close the handle**:

```haskell
writePrompt :: Handle -> Text -> IO ()
writePrompt h promptBody = do
  BS.hPut h (Text.encodeUtf8 promptBody)
  hClose h
```

Closing is what signals end-of-input. Without it both tools wait for more prompt text and the run
hangs until its timeout — a failure that looks like a slow model rather than a bug. Encode as
UTF-8 explicitly with `Data.Text.Encoding.encodeUtf8` rather than using `hPutStr`, whose behavior
depends on the handle's locale encoding and would corrupt non-ASCII prompts on a machine with a
non-UTF-8 locale.

Measure the duration with `Data.Time.Clock.getCurrentTime` before spawning and after
`waitForProcess` returns, and compute it with `diffUTCTime`, matching how
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` measures latency. Build the result with
`agentRunResult (req ^. #provider) code elapsed`.

Verify with a temporary test case that runs `/bin/cat` with no arguments, `PromptOnStdin`, and a
known prompt, asserting a zero exit code. Output capture does not exist yet, so assert only the
exit code for now; Milestone 3 turns this into the real round-trip test.

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

### Milestone 3 — The three output disciplines, drained concurrently and bounded

Scope: implement `InheritOutput`, `CaptureOutput`, and `TeeOutput` with concurrent draining and a
byte limit. At the end of this milestone a test can prove a prompt round-trips through `/bin/cat`
and that a large output is truncated.

Make `outSpec` depend on the mode:

```haskell
outSpec = case req ^. #output of
  InheritOutput -> P.Inherit
  CaptureOutput -> P.CreatePipe
  TeeOutput -> P.CreatePipe
```

With `InheritOutput` there are no pipes and no draining: the child writes straight to the parent's
own streams, and both result fields are `OutputNotCaptured`. This is the default and what the first
consumer wants, because its log is the terminal it inherited.

For the two capturing modes, write one reader used for both streams:

```haskell
drain :: Maybe Int -> Maybe Handle -> Handle -> IO AgentCapturedOutput
```

The first argument is the byte limit, the second is an optional handle to echo to — `Just stdout`
for `TeeOutput`, `Nothing` for `CaptureOutput` — and the third is the pipe to read.

Read in fixed-size chunks with `BS.hGetSome h 4096`, the same chunk size
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` uses in its `handleStream`, looping until it
returns an empty result. For each chunk, echo it immediately when teeing, then accumulate. Track
the total bytes read separately from the bytes retained. Once the retained bytes reach the limit,
**keep reading and discard** — the Decision Log explains why closing early is worse — and remember
that truncation happened. Return `OutputCaptured` when nothing was dropped and `OutputTruncated`
carrying exactly the retained prefix when something was.

With `Nothing` as the limit, retain everything. Note in a comment that this is unbounded by
request, and that the configuration layer in
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` supplies a default
limit so an operator who says nothing still gets a bound.

Accumulate with a strict builder or a reversed list of chunks concatenated at the end, not by
repeatedly appending to a `ByteString`. Appending in a loop is quadratic and a coding agent printing
a few megabytes would make it visibly slow.

Now the concurrency, which is the part that deadlocks if you get it wrong. Start draining **both**
streams before waiting for the process. Follow the shape in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`: drain standard error on a forked thread that
delivers its result through an `MVar`, drain standard output on the calling thread, take the
`MVar`, and only then call `waitForProcess`:

```haskell
errVar <- newEmptyMVar
_ <- forkIO $ do
  r <- trySync (drain limit teeErr hErr)
  putMVar errVar (either (const OutputNotCaptured) id r)
outBytes <- drain limit teeOut hOut
errBytes <- takeMVar errVar
code <- P.waitForProcess ph
```

Do not reorder this. Calling `waitForProcess` first is the classic deadlock: the child fills the
64-kilobyte pipe buffer and blocks writing while the parent blocks waiting, forever. Add a comment
saying so, because the wrong order looks more natural and someone will try to "simplify" it.

When teeing, echo to the parent's real handles — `System.IO.stdout` and `System.IO.stderr` — and
consider whether to flush per chunk. Flush, and note why in a comment: an unattended run can take
many minutes, and an operator watching a log wants to see progress rather than a silent block that
appears at the end.

Turn the temporary case from Milestone 2 into the real round trip: run `/bin/cat` with
`CaptureOutput`, a prompt on standard input, and assert
`capturedBytes (result ^. #stdout) == Just (Text.encodeUtf8 prompt)`. That single assertion proves
the prompt was delivered, the handle was closed, and the output was captured.

```bash
cabal test baikai-agent-test
```

### Milestone 4 — Timeout with process-group termination

Scope: enforce the request's timeout and kill the whole process group when it expires. At the end
of this milestone a test can run a sleeping script with a short timeout and see it reported as a
timeout in about that much time, with no lingering process.

Convert the timeout, which is a `NominalDiffTime` measured in seconds, to the microseconds
`System.Timeout.timeout` expects. Guard the conversion: a very large timeout can overflow an `Int`,
and a zero or negative value should be treated as no timeout rather than as "expire immediately",
because a configuration file with `timeout = 0` almost certainly means "unset" and immediately
killing every run would be a baffling failure. Write a small helper and unit-test it.

Wrap the wait, not the whole spawn:

```haskell
waitWithTimeout :: Maybe Int -> P.ProcessHandle -> IO (Maybe ExitCode)
waitWithTimeout Nothing ph = Just <$> P.waitForProcess ph
waitWithTimeout (Just micros) ph = System.Timeout.timeout micros (P.waitForProcess ph)
```

Wrapping only the wait matters: if you wrapped the whole `withCreateProcess` block, the timeout's
asynchronous exception could fire while you were mid-drain and you would lose the output collected
so far and the chance to terminate cleanly.

On `Nothing` — meaning the timeout expired — escalate:

```haskell
terminateGroup :: P.ProcessHandle -> IO ()
terminateGroup ph = do
  _ <- trySync (P.interruptProcessGroupOf ph)
  outcome <- System.Timeout.timeout gracePeriodMicros (P.waitForProcess ph)
  case outcome of
    Just _ -> pure ()
    Nothing -> do
      _ <- trySync (P.terminateProcess ph)
      _ <- trySync (P.waitForProcess ph)
      pure ()
```

`interruptProcessGroupOf` sends an interrupt to the whole group, which exists because you set
`create_group = True` in Milestone 2. That reaches the agent's own child processes — the shell
commands it started — which a bare `terminateProcess` on the agent would leave running. Give a
short grace period, a couple of seconds, defined as a named top-level constant with a comment
explaining the choice, then terminate. Wrap each signal in `trySync`: a process that has already
exited makes these throw, and a race between the timeout firing and the process exiting on its own
is normal rather than exceptional.

Always `waitForProcess` at the end so the child is reaped and does not linger as a zombie.

Return `Left (RunTimedOut t)` with the configured timeout, not the measured elapsed time. The
caller asked for a limit and wants to be told which limit was hit; the elapsed time will be
slightly larger because of the grace period, and reporting that invites confusion about whether the
limit was respected.

There is an interaction to be careful about. The drain threads may still be blocked reading when the
timeout fires. Because `withCreateProcess` closes the handles on the way out, a blocked read will
fail rather than hang — which is why every drain is wrapped in `trySync` and a failed drain yields
`OutputNotCaptured` rather than propagating. Verify this rather than assuming it: if a timeout test
hangs instead of failing, this interaction is where to look, and record what you find in Surprises
& Discoveries.

Write the timeout test in Milestone 5 rather than here, because it needs the fake-executable
harness.

```bash
cabal build baikai-agent
```

### Milestone 5 — The fake-executable test suite

Scope: build a test harness that writes small shell scripts into a temporary directory and runs
them through `runAgentCommand`. At the end of this milestone every behavior this plan implements is
pinned by a test, and none of them involves a coding-agent binary or a model.

Using fake executables is what makes this testable at all. The real `claude` and `codex` binaries
require authentication, cost money, and take minutes. A three-line shell script can reproduce every
process-level behavior that matters: reading standard input, writing to both streams, exiting with
a chosen code, sleeping, and spawning a child that outlives it.

Build the harness in `baikai-agent/test/Main.hs`. There is a working precedent for writing an
executable script in a test: `baikai-claude/test/Main.hs` already does it, importing
`System.Directory (getPermissions, setOwnerExecutable, setPermissions)` and
`System.IO.Temp`-style temporary directories. Read that code before writing yours.

```haskell
withFakeExecutable :: String -> String -> (FilePath -> IO a) -> IO a
withFakeExecutable name body action =
  withSystemTempDirectory "baikai-agent-test" $ \dir -> do
    let path = dir </> name
    writeFile path body
    perms <- getPermissions path
    setPermissions path (setOwnerExecutable True perms)
    action path
```

Each script begins with `#!/bin/sh` and is deliberately tiny. Write these cases.

A prompt round trip: a script that runs `cat`, with `PromptOnStdin` and `CaptureOutput`, asserting
the captured standard output equals the prompt's UTF-8 bytes and the exit code is `ExitSuccess`.
Include a non-ASCII prompt so the explicit UTF-8 encoding from Milestone 2 is actually exercised;
a locale-dependent write would fail here.

Stream separation: a script that writes a known line to standard output and a different known line
to standard error, asserting each lands in the correct result field. Without this test a swapped
pair of handles is invisible.

Working directory: a script that runs `pwd`, asserting the captured output is the request's
working directory. This proves the working directory is honored even though `AgentCommand` does not
carry it.

Non-zero exit: a script that exits 3, asserting the call returns `Right` with
`exitCode == ExitFailure 3`. This is the behavior most likely to be "fixed" into a `Left` by someone
who has not read the Decision Log, so name the test to say it is intentional.

Spawn failure: a path inside the temporary directory that does not exist, asserting
`Left (SpawnFailed path _)`.

Working-directory precondition: a request whose working directory does not exist, asserting
`Left (WorkingDirMissing path)` and — importantly — that this happens with an executable path that
would also have failed, so the test proves the precondition ran *first* rather than the spawn
failing.

Missing environment: a request declaring two environment variables, neither set, asserting
`Left (MissingEnvironment names)` with both names present. Use variable names unlikely to exist,
such as `BAIKAI_AGENT_TEST_ABSENT_ONE`. Do not call `setEnv` to create them and forget to unset
it; if you must set one, use `bracket` to restore the previous value, as
`baikai-claude/test/Main.hs` does around its environment manipulation.

Timeout: a script that sleeps for five seconds, with a one-second timeout, asserting
`Left (RunTimedOut _)`. Also assert the wall-clock time was well under five seconds — measure
around the call and assert it took less than, say, four — because a test that passes by waiting for
the script to finish anyway proves nothing about termination. Keep the sleep short enough that the
suite stays fast.

Process-group termination: a script that starts a background child which writes to a file after a
delay, then sleeps. Run with a short timeout, wait past the child's delay, and assert the file was
**not** created. This is the test that proves grandchildren die with the group; it is the most
valuable test in this plan and the easiest to omit. If it proves flaky on the machine you are
working on, do not delete it — record the flakiness in Surprises & Discoveries and make the timing
margins generous.

Output limit: a script printing far more than the limit, with `outputLimit = Just 1024`, asserting
the result is `OutputTruncated` with exactly 1024 bytes retained. Then assert the exit code is
still `ExitSuccess`, which proves discarding the excess did not break the child's writes.

Inherit mode: a script printing a line, with `InheritOutput`, asserting both result fields are
`OutputNotCaptured` and the exit code is success. The printed line goes to the test runner's own
output, which is expected and harmless.

Prompt-as-argument transport: a script that echoes its first argument, with `PromptAsArgument` and
the prompt already appended to `arguments`, asserting the output is the prompt and that no standard
input was supplied. This keeps the fallback transport working, since no vendor renderer uses it by
default.

Add a unit test for the timeout conversion helper from Milestone 4: a zero or negative
`NominalDiffTime` yields no timeout, and an ordinary value converts to the expected microseconds.

```bash
cabal test baikai-agent-test
```

### Milestone 6 — Documentation, changelog, and validation

Scope: document the new package and its runner, record the change, and prove the workspace is
green offline.

Documentation for this surface is mostly written by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`, which owns the new
user guide. Keep this milestone's documentation focused on what a *library* caller needs. Add a
section to `docs/user/interactive-launches.md`, in the part describing the third surface, naming the
`baikai-agent` package and `runAgentCommand`, and stating the four behaviors a caller must
understand: a non-zero exit code is a `Right`, not a `Left`; `InheritOutput` captures nothing by
design; the byte limit truncates rather than failing; and a timeout kills the whole process group,
so a coding agent's own child processes are terminated too.

Also update the root `README.md`. It lists the packages in the workspace; add `baikai-agent` with a
one-line description.

Add bullets under `[Unreleased]` in the single root `CHANGELOG.md`, scoped to `baikai-agent` as a
new package. This repository has one changelog covering every package; do not create a
`baikai-agent/CHANGELOG.md` and do not add dated release headings during feature work.

Confirm the release workflow edit from Milestone 1 is still accurate now that the package's
dependencies are settled, and note in `agents/skills/release/SKILL.md` that `baikai-agent` starts at
`0.1.0.0` and is a new first release rather than a bump.

Update the parent MasterPlan
`docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md`: set EP-4 to
`Complete`, check off its three Progress lines, and record in Surprises & Discoveries anything you
learned about process groups, pipe buffering, or timeout interaction —
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` will be wiring this
runner into a command-line tool and needs to know.

Then run the full validation in Concrete Steps.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`, unless stated
otherwise.

After Milestone 1:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

Expect the placeholder suite to pass. If Cabal reports it cannot find the package, the
`cabal.project` edit is missing or misindented — its `packages:` entries are indented two spaces.

After Milestones 2 through 4:

```bash
cabal build baikai-agent
cabal test baikai-agent-test
```

After Milestone 5, the full suite. Expect output similar to:

```text
baikai-agent
  Baikai.Agent.Run
    delivers the prompt on stdin and captures stdout:      OK
    separates stdout from stderr:                          OK
    honors the request working directory:                  OK
    reports a non-zero exit as a successful run:           OK
    reports a missing executable as SpawnFailed:           OK
    checks the working directory before spawning:          OK
    reports every missing declared variable at once:       OK
    times out and terminates the process group:            OK (1.05s)
    kills grandchildren when the group is terminated:      OK (1.52s)
    truncates captured output at the byte limit:           OK
    captures nothing in inherit mode:                      OK
    supports the prompt-as-argument transport:             OK

All 12 tests passed
```

To watch a run by hand, use the interactive interpreter. This spawns `/bin/cat`, not a coding
agent, so it costs nothing:

```bash
cabal repl baikai-agent
```

```haskell
:set -XOverloadedStrings
:set -XOverloadedLabels
import Baikai.Agent
import Baikai.Agent.Run
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
let req = (agentRunRequest AgentClaude "/tmp" "hello from stdin") & #output .~ CaptureOutput
let cmd = AgentCommand { executable = "/bin/cat", arguments = [], promptTransport = PromptOnStdin, promptText = "hello from stdin" }
r <- runAgentCommand req cmd
fmap (\x -> (x ^. #exitCode, capturedBytes (x ^. #stdout))) r
-- expect: Right (ExitSuccess,Just "hello from stdin")
:quit
```

Note that `promptText` in the command and `prompt` in the request are both present; the runner uses
the command's copy, because the vendor renderer may have transformed it. Keep them consistent in
hand-written examples.

Full validation after Milestone 6. Two independent gates cause the `baikai-smoke` suite to make
real billable calls and both must be closed: provider API-key environment variables, and — as
discovered during the work recorded in
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

Note that filtering `PATH` does not affect this plan's own tests, because they invoke absolute paths
to scripts in a temporary directory rather than resolving names through `PATH`. That is deliberate:
the suite must behave identically whether or not a coding agent is installed.

Expect no unintended formatting diff, nothing from `git diff --check`, a clean build, every suite
passing, the smoke suite skipping every live case, and a successful flake check.

Commit at least twice — the skeleton, then the runner:

```text
feat(agent): add the baikai-agent package skeleton

Create the baikai-agent package with a library and test suite, register
it in cabal.project, and add it to the release workflow's publishable
package list.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```

```text
feat(agent): run unattended coding-agent processes

Add Baikai.Agent.Run, which delivers the prompt on standard input,
drains both output streams concurrently within a byte limit, and on
timeout terminates the child's whole process group. Verified against
fake executables with no model involved.

MasterPlan: docs/masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md
ExecPlan: docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md
Intention: intention_01kyrmt8wjeyyaygk69s6r0s7d
```


## Validation and Acceptance

This plan is accepted when all of the following hold.

`baikai-agent` exists as a package, is listed in `cabal.project`, appears in the publishable-package
enumeration in `agents/skills/release/SKILL.md`, and depends on `baikai` but on neither provider
package.

A prompt containing non-ASCII characters, delivered with `PromptOnStdin` to a script that runs
`cat`, comes back byte-identical in the result's captured standard output, proving delivery,
explicit UTF-8 encoding, and handle closing all work.

Standard output and standard error arrive in their own result fields and are not swapped. A script
running `pwd` reports the request's working directory.

A script exiting 3 produces `Right` with `exitCode == ExitFailure 3`. A missing executable produces
`Left (SpawnFailed path _)`. A missing working directory produces `Left (WorkingDirMissing path)`
before any spawn is attempted. Declared-but-unset environment variables produce
`Left (MissingEnvironment names)` listing every one of them.

A script sleeping five seconds under a one-second timeout produces `Left (RunTimedOut _)`, and the
call returns in well under five seconds — proving the process was terminated rather than waited
out. A background grandchild started by that script does not write its file after the group is
terminated.

A script printing far more than `outputLimit` yields `OutputTruncated` with exactly the limit's
worth of bytes and still reports `ExitSuccess`, proving the excess was discarded rather than the
pipe closed. `InheritOutput` yields `OutputNotCaptured` for both streams.

The `PromptAsArgument` transport works and supplies no standard input.

The timeout conversion helper treats zero and negative durations as no timeout.

`cabal test baikai-agent-test` passes with the test suite built using `-threaded`. No test invokes
`claude`, `codex`, or any model.

`docs/user/interactive-launches.md` documents the four caller-visible behaviors, the root
`README.md` lists the new package, and the root `CHANGELOG.md` has `baikai-agent` bullets under
`[Unreleased]`. The parent MasterPlan shows EP-4 complete.

`nix fmt`, `git diff --check`, `cabal build all`, the key- and CLI-scrubbed `cabal test all`, and
`nix flake check` all succeed.


## Idempotence and Recovery

Milestone 1 is additive and self-contained: a new directory, one `cabal.project` line, and one
edit to the release workflow document. Nothing existing changes behavior. Commit it separately,
because it is the checkpoint that unblocks
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`.

Milestones 2 through 5 only touch files inside `baikai-agent/`, so the rest of the workspace cannot
break. Every existing test must keep passing; if one starts failing you have edited outside this
plan's scope.

All commands are safe to repeat. The tests write only into temporary directories created by
`withSystemTempDirectory`, which removes them afterward even on failure. Nothing contacts a
provider or mutates remote state.

Two recovery notes specific to process work. If a test **hangs** rather than failing, the most
likely cause is draining order: `waitForProcess` must not be called before both streams are
drained. Interrupt the suite, re-read the deadlock warning in Milestone 3, and check the ordering.
If a test leaves a stray process behind, the timeout path did not reach `waitForProcess`; check
that every signal is wrapped in `trySync` so an already-exited process does not throw past the
final wait. You can look for strays with `pgrep -f baikai-agent-test` between runs.

To roll back, revert the commits and delete the `baikai-agent` directory, the `cabal.project` line,
and the release-workflow entry. Nothing else depends on the package at the end of this plan.


## Interfaces and Dependencies

New package `baikai-agent` at version `0.1.0.0`, depending on `baikai`, `base`, `bytestring`,
`directory`, `generic-lens`, `lens`, `process`, `text`, and `time`. Every one of these is already
used elsewhere in the workspace at the bounds given in Milestone 1, so the build plan does not
change for any existing package. No new dependency is introduced to the workspace as a whole.

Deliberately **not** dependencies of this package after this plan: `baikai-claude` and
`baikai-openai`, added later by
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md`; the four `settei`
packages, added by
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md`;
`optparse-applicative`, added by the executable plan; and `async`, which two `forkIO` calls do not
justify.

At completion, `baikai-agent/src/Baikai/Agent/Run.hs` exports:

```haskell
runAgentCommand ::
  AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
```

Both arguments are required and neither is redundant: the request supplies every process-level
setting — working directory, timeout, output discipline, output limit, and declared environment
variables — while the command supplies the executable, the argument vector, and the prompt
transport. `AgentCommand` deliberately carries no working directory, because Claude Code has no
working-directory flag and duplicating the value would let two copies disagree, which would be a
sandbox escape rather than a cosmetic bug.

Export any helper you want to unit-test directly, in particular the timeout conversion. Keep the
draining helper internal unless a test needs it.

The behavior contract that later plans and the user guide document:

```text
output mode      child streams          result stdout/stderr
inherit          parent's own streams   OutputNotCaptured
capture          pipes, parent silent   OutputCaptured / OutputTruncated
tee              pipes, echoed onward   OutputCaptured / OutputTruncated

outcome                                 return value
ran, exit 0                             Right, exitCode ExitSuccess
ran, exit non-zero                      Right, exitCode ExitFailure n
working directory absent                Left WorkingDirMissing
declared variable unset or empty        Left MissingEnvironment
executable not startable                Left SpawnFailed
still running at the deadline           Left RunTimedOut, process group terminated
```

Downstream impact: none yet. Nothing imports `Baikai.Agent.Run` at the end of this plan.
`docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md` adds modules
alongside it in the same package, and
`docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md` is the first caller.
When adding to `baikai-agent/baikai-agent.cabal`, later plans must add only their own modules and
dependencies without reordering or removing the entries this plan created.
