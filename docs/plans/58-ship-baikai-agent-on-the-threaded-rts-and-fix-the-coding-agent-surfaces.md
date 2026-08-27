---
id: 58
slug: ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces
title: "Ship baikai-agent on the threaded RTS and fix the coding-agent surfaces"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Ship baikai-agent on the threaded RTS and fix the coding-agent surfaces

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`cabal install baikai-agent` puts a `baikai` binary on a user's `PATH`. Its `agent run`
subcommand starts a coding agent — the locally installed `claude` or `codex` tool — with
no terminal and no human present, delivers the prompt on the child's standard input,
drains what the child prints, and enforces a configured `timeout` by terminating the
child's whole process group: the contract `docs/user/unattended-agent-runs.md` and
CAP-17/CAP-18 describe. The 2026-08-27 review (`docs/reviews/correctness-and-api-review-follow-up.md`,
REV-2, Theme F) found the shipped binary cannot keep it, plus four smaller defects:

1. **The binary is built without the threaded runtime (F.1, critical).** The Haskell
   runtime system ("RTS") schedules Haskell threads; in its default, non-threaded form a
   blocking operating-system call such as the `waitpid` inside
   `System.Process.waitForProcess` stops *every* Haskell thread until it returns.
   `Baikai.Agent.Run` wraps that wait in `System.Timeout.timeout` and forks threads to
   drain the child's pipes and write the prompt; none can run while the main thread is
   blocked. So in the installed binary `timeout "45m"` never fires and a child that
   writes more than one pipe buffer deadlocks against the parent. Only the test suite is
   compiled `-threaded`, so every runner test passes under a runtime the binary lacks.
2. **Timeout escalation has no SIGKILL and discards drained output (F.6).** A child that
   ignores SIGTERM, or a grandchild holding the output pipe, hangs the runner after the
   deadline, and the bytes drained before the deadline are thrown away.
3. **The binary writes its output through the locale (F.9).** Under `LANG=C` — cron,
   systemd, containers — a non-ASCII character in the agent's answer makes `hPutStr`
   throw `invalid argument` after the run finished; exit 1, answer lost.
4. **Two codex approval policies are rejected by the vendor (F.5).** `codex 0.149.1`
   accepts only `on-request` and `never` for `--ask-for-approval`; baikai also renders
   `untrusted` and `on-failure`, so those launches return `Right (ExitFailure n)` from a
   usage error instead of the `Left SafetyNotExpressible` commit `ab877cd` promised.
5. **JSONL line assembly is quadratic (F.7) and the TOML renderer is wrong (F.8).**
   `parseCodexJsonlStream` copies its accumulator once per byte, so one long codex event
   costs the square of its length; `tomlMultilineString` emits a TOML *basic* multi-line
   string escaping only `"""`, so any backslash in an agent body is an escape sequence
   and Codex refuses to load the file.

After this plan, `baikai agent run` on the installed binary stops a hung agent at its
deadline, escalates through SIGINT, SIGTERM and SIGKILL so even a signal-ignoring child
and its children die, keeps and reports the output drained before the kill, and writes
its result as UTF-8 under any locale. A codex interactive launch with an approval policy
the installed CLI rejects is refused before any process starts. A multi-megabyte codex
event parses in milliseconds, and a Codex custom-agent TOML file round-trips any body.
You see it working by running the `baikai-agent` suite — which now spawns the *built
binary* against a child that ignores termination — and by the transcript in Validation
and Acceptance.

Scope boundary. This plan owns the process-lifecycle half of
`baikai-agent/src/Baikai/Agent/Run.hs`, the executable stanza and `Main.hs`, the codex
JSONL assembler, the TOML renderer, and the interactive codex approval rendering. The
unattended policy ceiling (REV-2 F.2 to F.4) is owned by
`docs/plans/63-close-the-unattended-run-policy-ceiling.md` (EP-6), which also edits the
evidence `endpoint` and `errorInfo` region of `Run.hs`; the regions are disjoint and the
later plan rebases. Exports and version bumps are owned by
`docs/plans/67-freeze-the-public-surface.md` (EP-10).


## Progress

- [x] M1 (2026-08-27): `baikai-agent/baikai-agent.cabal`: `-threaded` on `executable
      baikai`; `build-tool-depends: baikai-agent:baikai` and `BinaryTests` on the test
      suite.
- [x] M1 (2026-08-27): wrote `baikai-agent/test/BinaryTests.hs` (`builtBaikai`,
      `runBaikai`, `reportsTheThreadedRuntimeTest`, `timesOutAHungAgentTest`); registered
      it in `test/Main.hs`; ran it against the unthreaded binary first and recorded both
      failures in Surprises & Discoveries.
- [x] M1 (2026-08-27): wrote
      `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md` and
      its row in `docs/adr/README.md`; `CHANGELOG.md` entry; commit.
- [x] M2 (2026-08-27): added `AgentTimedOut` to `baikai/src/Baikai/Agent.hs`;
      `RunTimedOut` carries it; `renderAgentRunFailure` reads `#limit`;
      `baikai/test/AgentSpec.hs` updated.
- [x] M2 (2026-08-27): rewrote `terminateGroup` (INT, TERM, KILL, each earlier stage
      bounded, group polled with the null signal through `groupAlive`, last resort
      `killGroupOrLeader`); `drain` keeps its bytes on a failed read; `forkDrain` returns
      the `ThreadId`; `consume`'s timeout branch collects both drains; `capturedBytes`
      reads the timed-out standard output.
- [x] M2 (2026-08-27): `interpret` in `baikai-agent/src/Baikai/Agent/Cli.hs` prints kept
      output on a timeout (`streamFields` lifted to top level); `emit` in
      `baikai-agent/app/Main.hs` writes UTF-8 bytes, `bytestring` added to the
      executable's `build-depends`.
- [x] M2 (2026-08-27): in-process tests in `baikai-agent/test/Main.hs`
      (`keepsDrainedOutputOnTimeoutTest`, `escalatesToKillTest`,
      `escapedPipeHolderTest`); the trap and the partial-output assertion in
      `BinaryTests.hs`, plus `writesUtf8UnderCLocaleTest`.
- [x] M2 (2026-08-27): `docs/user/unattended-agent-runs.md`, CAP-17, CAP-18,
      `docs/capabilities/log.md`, `CHANGELOG.md`; commit.
- [x] M3 (2026-08-27): refused `CodexApprovalUntrusted` and `CodexApprovalOnFailure` in
      `safetyArgs` of `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` through
      `approvalAccepted`; Haddock on both constructors in
      `baikai/src/Baikai/Interactive.hs`; `refusesRejectedApprovalPoliciesTest` in
      `baikai-openai/test/Main.hs`.
- [x] M3 (2026-08-27): `docs/user/interactive-launches.md` table and messages; CAP-16;
      log; `CHANGELOG.md`; commit.
- [x] M4 (2026-08-27): chunk-level line assembly in `parseCodexJsonlStream`; three new
      cases in `baikai/test/CliInternalSpec.hs`, including the bounded-time
      multi-megabyte line, which failed by its ten-second bound before the change and
      passes in 0.03 s after.
- [x] M4 (2026-08-27): literal-string rendering with an escaped fallback in
      `baikai/src/Baikai/AgentAssets.hs`; `tomlString` escapes every control character;
      `baikai/test/AgentAssetsSpec.hs`; `docs/user/agent-assets.md`; CAP-22; log;
      `CHANGELOG.md`; commit.
- [ ] Final: keyless `cabal test all` gate green; tick the four EP-1 lines in
      `docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`;
      Outcomes & Retrospective; ADR distillation pass.


## Surprises & Discoveries

Recorded during plan authoring (2026-08-27); keep appending during implementation.

- `codex --help` on the installed `codex-cli 0.149.1` lists exactly two approval values,
  which is the whole basis of M3:

  ```text
  -a, --ask-for-approval <APPROVAL_POLICY>
          Configure when the model requires human approval before executing a command

          Possible values:
          - on-request: The model decides when to ask the user for approval
          - never:      Never ask for user approval Execution failures are immediately
            returned to the model
  ```

- The `process` package (1.6.26.1 in the build plan; `mori` has no `process` project, so
  the source was read from `~/.cabal/packages/hackage.haskell.org/process/1.6.26.1/`)
  documents F.1 on `waitForProcess` itself: "GHC Note: in order to call `waitForProcess`
  without blocking all the other threads in the system, you must compile the program
  with `-threaded`."
- How the built binary reaches the test (M1's mechanism): cabal-install 3.14.2.0,
  `src/Distribution/Client/ProjectPlanning.hs` line 3866, runs a package's `Setup` with
  `useExtraPathEnv = elabExeDependencyPaths elab ++ elabProgramPathExtra`, which
  `SetupWrapper.hs` lines 568–575 turn into the `PATH` of `Setup test`, whose child the
  test binary is. So with `build-tool-depends: baikai-agent:baikai` on the suite,
  `findExecutable "baikai"` finds the freshly built executable, built before the suite.
- `nix/haskell.nix` and `flake.nix` define no test-running check; `nix flake check`
  builds and formats only, so the spawned-binary test runs only under `cabal test`.
- GHC's `hClose` takes the handle's internal lock, which a thread blocked in `hGetSome`
  holds for the whole read; closing a pipe handle from another thread to unblock a
  drain blocks the closer instead. M2 therefore unblocks a stuck drain with `killThread`,
  which interrupts the read, and the drain keeps the bytes it has when interrupted.
- macOS ships no `setsid` binary, so the one test needing a pipe holder outside the
  process group uses `perl -MPOSIX -e 'setsid(); …'` and is skipped with a printed note
  when `perl` is absent.
- `python3` here has `tomllib`, so a rendered Codex agent file can be checked against a
  real TOML parser by hand; no Haskell TOML parser is in the build plan and none is added.

Recorded during implementation.

- The pre-fix transcript M1 asked for. With `BinaryTests` wired in and the executable
  still lacking `-threaded`, `cabal test baikai-agent --test-show-details=direct
  --test-options='-p "the built baikai binary"'` gave both failures at once:

  ```text
    the built baikai binary
      baikai +RTS --info reports the threaded runtime:            FAIL (1.21s)
        ,("RTS way", "rts_v")
      agent run stops a child that outlives its timeout, exit 75: FAIL (30.01s)
        the run never returned: the configured timeout did not stop the child.
  ```

  The second case burned its whole thirty-second bound: the job's deadline was one
  second at that point and the stub sleeps for a hundred and twenty, so nothing but the
  test's own bound ended it. With `-threaded` the same case finishes in 3.09 s against
  the three-second deadline the next entry explains. (2026-08-27, M1)
- __cabal does not rebuild an executable when only its `ghc-options` change.__ After
  adding `-threaded`, `cabal build baikai-agent:exe:baikai` reported "Building
  executable" and the resulting binary still said `rts_v`; `cabal build -v3` passed no
  `-threaded` to GHC at all. Removing the component's build directory
  (`dist-newstyle/build/aarch64-osx/ghc-9.12.4/baikai-agent-0.1.0.0/x`) and rebuilding
  produced `rts_thr`. The `+RTS --info` assertion is what turns this from a mystery into
  a message, which is now part of what ADR 0006 says. (2026-08-27, M1)
- GHC 9.12.4 prints the pair with a space — `("RTS way", "rts_thr")` — not in the
  compact form the plan quoted. The assertion therefore matches the way name alone
  (`"rts_thr"`), which still separates it from `"rts_v"` and leaves the surrounding
  spacing GHC's to change. (2026-08-27, M1)
- __The spawned-binary deadline cannot be one second.__ With `timeout "1s"` the case
  passed when run alone and failed every time the whole suite ran, deterministically.
  The failure was not a signal race: the diagnostic showed the stub's process-id file
  had never been created at all —

  ```text
  the stub never recorded a process id. stdout:
  stderr:
  the run exceeded its timeout of 1s
  pidfile exists: False listing: [".","..","workspace","agents.kdl","hang.sh"]
  ```

  — so the stub's first line had not run when the group was killed, one second after
  the spawn. Starting `/bin/sh` takes longer than that while eighty other cases run in
  parallel under `-with-rtsopts=-N`. The job now uses `timeout "3s"`, still forty times
  shorter than the stub's own sleep, so what the case proves is unchanged. Three
  consecutive full-suite runs pass at 3.05–3.09 s. (2026-08-27, M1)
- The escalation is proved by removing it. With `killGroupOrLeader` temporarily
  reduced to the old last resort — `P.terminateProcess` on the leader followed by an
  unbounded wait — `escalatesToKillTest` waits out the stub in full:

  ```text
    a child that ignores INT and TERM is killed within the grace periods: FAIL (30.27s)
      killed rather than waited out; the run took 30.266253s
  ```

  With `SIGKILL` restored the same case finishes in about seven seconds: the deadline
  plus two grace periods. (2026-08-27, M2)
- __The locale defect (F.9) cannot be reproduced on macOS.__ GHC 9.12.4 on Darwin
  reports `Just UTF-8` for the standard handles under every locale tried — `C`,
  `POSIX`, `en_US.ISO8859-1`, `C.UTF-8` — so `Data.Text.IO.hPutStr` of
  `réconcilier — 文法` succeeds there and `writesUtf8UnderCLocaleTest` passes both
  before and after the fix on this machine. It was checked directly with a five-line
  probe rather than assumed. The fix is still right — it is what makes the claim
  platform-independent, and it mirrors the read side — and the case is still worth
  having, because it pins the exact bytes the command writes; it is simply a guard for
  the platforms where the locale encoding does follow `LANG`, which is where an
  unattended run under cron actually lives. The plan's predicted pre-fix transcript
  (`hPutChar: invalid argument`) is therefore not reproducible here and is not
  recorded. (2026-08-27, M2)
- Importing `AgentTimedOut (..)` into `baikai-agent/src/Baikai/Agent/Run.hs` brings its
  `stdout` and `stderr` field selectors into scope, which collide with
  `System.IO.stdout` and `System.IO.stderr` that the tee path uses. The handles are now
  reached through a qualified `SystemIO` import; the alternative — importing the
  constructor without its fields — would have meant giving up record syntax at the one
  place the record is built. (2026-08-27, M2)
- The in-process cases that assert on work the child actually did needed the same
  deadline treatment as the spawned-binary case: `keepsDrainedOutputOnTimeoutTest` and
  `escalatesToKillTest` run at three seconds, and `escapedPipeHolderTest` at five,
  because it has to start a second interpreter and let it leave the process group
  before the deadline. At one and three seconds respectively they failed in a
  full-suite run and passed in isolation. The pre-existing `timeoutTest` and
  `processGroupTest` keep their one-second deadlines: neither asserts anything about
  what the child printed, so neither is sensitive to how quickly it starts.
  (2026-08-27, M2)
- The vendor's rejection was re-verified rather than taken from the plan. `codex
  --version` reports `codex-cli 0.149.1`, `codex --help` lists exactly two possible
  values for `--ask-for-approval`, and the real invocation answers:

  ```text
  error: invalid value 'untrusted' for '--ask-for-approval <APPROVAL_POLICY>'
    [possible values: on-request, never]
  ```

  Exit code 2 — which, rendered rather than refused, is the `Right (ExitFailure 2)` a
  caller would have read as "the session ran and failed". (2026-08-27, M3)
- Both M4 defects were reproduced before they were fixed. The multi-megabyte case
  failed by its own bound —

  ```text
  a multi-megabyte event is assembled in linear time: FAIL (10.00s)
    assembling one two-megabyte event did not finish within ten seconds
  ```

  — and passes in 0.03 s afterwards. The TOML defect was confirmed against the system
  Python's parser: the old `"""` form of a body containing `\d+` raises
  `TOMLDecodeError: Unescaped '\' in a string (at line 2, column 9)`, while the new
  literal form round-trips the body byte for byte
  (`'Match \\d+ then \\ and stop.\nDone.\n'`). (2026-08-27, M4)


## Decision Log

- Decision: The spawned-binary test finds the executable through
  `build-tool-depends: baikai-agent:baikai` on `test-suite baikai-agent-test` and
  `System.Directory.findExecutable "baikai"`, with an environment override
  `BAIKAI_AGENT_TEST_EXECUTABLE` for a test binary run outside cabal, and a hard failure
  — never a silent skip — when neither yields a file.
  Rationale: cabal-install puts every `build-tool-depends` executable on the `PATH` of
  `Setup test` (Surprises & Discoveries), and the dependency makes cabal build the
  binary before the suite. Rejected: `cabal list-bin` from inside the test (spawns cabal
  under its own `dist-newstyle` lock); walking from `getExecutablePath` to
  `x/baikai/build/baikai/baikai` (one layout only); a `-threaded`-gated fixture (proves
  the fixture's RTS, not the shipped binary's). The `+RTS --info` assertion makes a
  stale binary fail loudly.
  Date: 2026-08-27
- Decision: The executable gains `-threaded` and nothing else: no `-N`, no `-rtsopts`.
  Rationale: one child needs no parallelism, and `+RTS --info` — the probe the test
  uses — is permitted under GHC's default `-rtsopts=some`.
  Date: 2026-08-27
- Decision: `CodexApprovalUntrusted` and `CodexApprovalOnFailure` are *refused* by the
  codex launcher with `SafetyNotExpressible AgentCodex …` in
  `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`; the constructors and the
  spellings `renderCodexApprovalPolicy` gives them stay.
  Rationale: the vendor rejects those values, and silently mapping them to `on-request`
  would change the policy the caller asked for — the failure `ab877cd` removed. Keeping
  the constructors keeps `CodexApprovalPolicy` stable and leaves deprecation to EP-10.
  What the installed binary accepts is the vendor adapter's knowledge
  (`docs/adr/0003-the-adapter-owns-the-translation-description.md`). The core test
  `codexSafetyRenderingTest` pinning the four spellings is a decision and stays.
  Date: 2026-08-27
- Decision: Codex custom-agent bodies render as TOML *literal* multi-line strings
  (`'''` … `'''`), falling back to a fully escaped *basic* multi-line string when the body
  contains `'''`, a bare carriage return, DEL, or any other control character a literal
  string may not hold. `tomlString` escapes every control character.
  Rationale: agent bodies are Markdown a human reviews in `.codex/agents/*.toml`; a
  literal string shows it verbatim. A literal string cannot contain `'''`, so a correct
  fallback is required rather than a refusal. Always-basic was rejected because it
  doubles every backslash in a body meant to be read.
  Date: 2026-08-27
- Decision: `parseCodexJsonlStream` assembles lines by splitting each `ByteString` chunk
  on the newline byte inside one `Fold.foldl'` over chunks, carrying the pieces of an
  unfinished line as a reversed list and concatenating them once at its newline.
  Rationale: linear, no per-byte allocation, and a chunk boundary mid-line is a plain
  test case. Folding each line into a `Data.ByteString.Builder` over the existing
  per-byte stream is also linear but still unpacks every chunk into a list of `Word8`
  and allocates a closure per byte.
  Date: 2026-08-27
- Decision: `Main.hs` writes both streams as UTF-8 bytes (`Data.ByteString.hPut` of
  `Data.Text.Encoding.encodeUtf8`) and flushes them. Invalid UTF-8 in captured child
  output is already U+FFFD by then (`Baikai.Agent.Cli.decoded` uses `decodeUtf8Lenient`),
  so the binary always emits valid UTF-8 and never throws on output.
  Rationale: mirrors the read side (`readPromptSource`) and the prompt write
  (`writePromptAsync`). `hSetEncoding stdout utf8` was rejected as staying on the
  locale-encoder path. Passing the child's raw bytes through would make
  `AgentCliRun.standardOutput` a `ByteString`; recorded as a possible EP-10 follow-up.
  Date: 2026-08-27
- Decision: A timed-out run carries what it drained: `RunTimedOut` holds a new record
  `AgentTimedOut { limit, stdout, stderr }` in `baikai/src/Baikai/Agent.hs`.
  Rationale: the runner already holds the bytes; discarding them contradicts the comment
  at `Run.hs` lines 686–689 and the guide's promise that a timed-out run is the one an
  operator most wants to know about. A single-constructor record does not trigger
  `-Wpartial-fields`. A PVP-major change to `baikai`; the bump is EP-10's.
  Date: 2026-08-27
- Decision: Escalation is SIGINT, then SIGTERM, then SIGKILL, each to the whole group;
  every stage is bounded by `gracePeriodMicros` (2 s) and ends early once the leader is
  reaped *and* the group is empty (polled with the null signal); the final wait after
  SIGKILL is unbounded because SIGKILL cannot be ignored. After the kill each drain is
  collected with a bounded wait, then interrupted with `killThread` if a holder outside
  the group still keeps the pipe open.
  Rationale: F.6 verbatim, plus the `hClose` lock behaviour above. Polling group
  emptiness gives grandchildren the same grace as the leader instead of three signals
  in a burst.
  Date: 2026-08-27
- Decision: This plan creates
  `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md`, the
  next free number in the plain-file corpus (`0001` … `0005` exist), in the M1 commit.
  Rationale: the MasterPlan names this decision as EP-1's to promote, and
  `docs/adr/0001-architecture-decision-record-convention.md` fixes the format (plain
  files, `title`/`status`/`date` frontmatter, Context / Decision / Consequences, a row
  in `docs/adr/README.md`).
  Date: 2026-08-27
- Decision: The spawned-binary timeout case gives its job a three-second deadline, not
  the one second the plan drafted.
  Rationale: one second is shorter than the time the operating system takes to start
  `/bin/sh` while the rest of the suite runs in parallel, so the case failed
  deterministically in a full-suite run having never let the stub run a line — a fact
  about process-start latency, not about the runner. Three seconds is still forty times
  shorter than the stub's own sleep and well inside the case's fifteen-second bound, so
  the case still proves that the deadline stopped the child rather than the child
  finishing. Rejected: marking the case sequential with tasty's `after`, which would
  hide the latency rather than accommodate it, and shortening the stub's sleep, which
  would weaken the very distinction being asserted.
  Date: 2026-08-27
- Decision: The runtime assertion matches the way name `"rts_thr"` rather than the whole
  printed pair.
  Rationale: GHC 9.12.4 prints `("RTS way", "rts_thr")` with a space, and the spacing of
  that list is GHC's to change; the way name is the fact under test and is already
  unambiguous against the non-threaded `"rts_v"`.
  Date: 2026-08-27
- Decision: The last escalation stage is one function, `killGroupOrLeader`, rather than
  the plan's `killProcessGroup` plus a separate platform fallback.
  Rationale: the plan's shape left a non-POSIX build with no stage that reaches the
  leader at all, because both group calls are no-ops there and the old
  `P.terminateProcess` fallback lived in the branch the rewrite replaced. One
  CPP-guarded definition — `SIGKILL` to the group where POSIX signals exist,
  `P.terminateProcess` on the leader where they do not — keeps the platform difference
  at the definition instead of inside `terminateGroup`. `groupAlive` is as the plan
  specified.
  Date: 2026-08-27
- Decision: `writesUtf8UnderCLocaleTest` ships even though it cannot fail on this
  platform.
  Rationale: GHC on Darwin uses UTF-8 as the locale encoding whatever `LANG` says
  (Surprises & Discoveries), so the defect it guards is unobservable here; it is
  observable on Linux, which is where cron entries and containers run. A case that
  pins the exact bytes the command writes is worth keeping on a platform where it is
  currently free, and deleting it would leave the fix unpinned everywhere.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

baikai is a multi-package Haskell cabal project at `/Users/shinzui/Keikaku/bokuno/baikai`
(HEAD `5411947`, branch `master`); every path below is repository-relative. The core
package `baikai` holds provider-neutral vocabulary; `baikai-openai` and `baikai-claude`
render it into each vendor's command line; `baikai-agent` holds the runner, the
configuration layer, and the `baikai` executable. Build and test with `cabal` from the
repository root inside the Nix dev shell.

Terms, in plain language. The **RTS** is the runtime system GHC links into every program;
the **threaded RTS** (`-threaded`) lets a blocking operating-system call proceed on its
own OS thread so other Haskell threads keep running, whereas the default non-threaded RTS
stops everything for the duration of such a call. A **process group** is a set of
processes the operating system signals together; `create_group = True` in `Run.hs` puts
the child and everything it spawns into a fresh group named by the child's own process
id. **SIGINT**, **SIGTERM** and **SIGKILL** are POSIX signals: the first two ask a process
to stop and can be caught or ignored; SIGKILL cannot be caught, ignored or delayed. A
**pipe** is the channel a child's output travels through; it holds about 64 KiB and a
writer blocks once it is full until a reader drains it. A **zombie** is a child that has
exited but whose status nobody collected with `waitForProcess`. **JSONL** is one JSON
object per line. **TOML** is the configuration format Codex reads: a *basic* string is
delimited by `"` (or `"""` multi-line) and interprets backslash escapes; a *literal*
string is delimited by `'` (or `'''`) and interprets nothing. A **locale** is the
environment's declared character encoding (`LANG`, `LC_ALL`), which GHC's text handles
encode through unless told otherwise. **UTF-8** is the byte encoding baikai commits to.

The files this plan changes, as they are at HEAD:

- `baikai-agent/baikai-agent.cabal`. The `executable baikai` stanza (line 85 onwards)
  has no `ghc-options` and no `bytestring` dependency; the test-suite stanza carries
  `ghc-options: -threaded -with-rtsopts=-N`. The library depends on `unix` behind
  `if !os(windows)` with `cpp-options: -DBAIKAI_POSIX_SIGNALS`.
- `baikai-agent/app/Main.hs`. `emit` (lines 41–44) is `TextIO.hPutStr stdout
  (finished ^. #standardOutput)` and the same for `stderr` — the locale write of F.9.
- `baikai-agent/src/Baikai/Agent/Run.hs`. `spawn` (487) builds a `CreateProcess` with
  `create_group = True` and runs `consume` under `P.withCreateProcess`. `consume`
  (528–579) forks the prompt writer, forks a drain per pipe with `forkDrain` (605–621),
  and calls `waitWithTimeout` (690–692), which is `Timeout.timeout micros
  (P.waitForProcess ph)`. On `Nothing` it calls `terminateGroup` (723–737) — SIGINT to
  the group, a 2-second bounded wait, SIGTERM to the group via `terminateProcessGroup`
  (746–753, POSIX only), then if the leader has not exited `P.terminateProcess` and an
  *unbounded* `P.waitForProcess` — and returns `Left (RunTimedOut limit)` without taking
  the drains' `MVar`s (556–562). `drain` (634–660) reads with `BS.hGetSome`, retains up
  to the limit, and returns `OutputCaptured` or `OutputTruncated` at end of file;
  `forkDrain` turns any exception into `OutputNotCaptured`. `evidenceStatus` (355–367)
  maps `RunTimedOut` to `CallAborted`; the local `capturedBytes` (471–477) is `Nothing`
  for every `Left`.
- `baikai-agent/src/Baikai/Agent/Cli.hs`. `interpret` (975–1030) turns the runner's
  `Either AgentRunFailure AgentRunResult` into an `AgentCliRun` — an exit code and two
  `Text` streams. On `Left` it prints only the failure message (or a three-field JSON
  envelope); on `Right` it prints the decoded captured stdout under `capture` and, with
  `--json`, `resultJson` (1126–1145), whose local `streamFields` adds `stdout`,
  `stdoutTruncated`, `stderr`, `stderrTruncated`. `decoded` (1120–1124) is
  `Text.decodeUtf8Lenient`; `failureExitCode` (1097–1108) maps `RunTimedOut _` to 75;
  `readPromptSource` (1152–1175) is the read-side precedent: bytes in, explicit decode.
- `baikai/src/Baikai/Agent.hs`. `AgentRunFailure` (572–599) has `RunTimedOut
  !NominalDiffTime`, rendered by `renderAgentRunFailure` (601–617); `AgentCapturedOutput`
  (202–209) is `OutputNotCaptured | OutputCaptured ByteString | OutputTruncated
  ByteString` with `capturedBytes` (212–215); `AgentRunResult` (461–473) has `provider`,
  `exitCode`, `stdout`, `stderr`, `duration`. The package enables `DuplicateRecordFields`
  and `OverloadedLabels`, so field names repeat across records and are read with `^. #f`.
- `baikai/src/Baikai/Provider/Cli/Internal.hs`. `parseCodexJsonlStream` (246–260)
  unpacks every chunk into a `Stream IO Word8`, then `Stream.foldMany` with
  `Fold.takeEndBy_ (== newlineByte) (Fold.foldl' BS.snoc BS.empty)` — the per-byte copy
  of F.7 — decodes each line with `Aeson.decodeStrict`, and folds events with
  `absorbCodexEvent` (271–283) into `CodexRunReport`. A non-JSON line is skipped; a last
  line without a newline is still parsed. The batch codex provider and
  `observeToolOutput` in `Run.hs` (431–437) both call it.
- `baikai/src/Baikai/AgentAssets.hs`. `codexCustomAgentToml` (118–124) renders three
  keys with `tomlString` (132–141, escaping `"`, `\`, `\n`, `\r`, `\t` only) and
  `tomlMultilineString` (143–145, `"""` + body + `"""`, replacing `"""` inside).
- `baikai/src/Baikai/Interactive.hs`. `CodexApprovalPolicy` (81–86) has four
  constructors; `renderCodexApprovalPolicy` (136–140) spells them `untrusted`,
  `on-failure`, `on-request`, `never`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`. `safetyArgs` (137–154)
  returns `Right (codexSafetyArgs sandbox approval)` for every `CodexSandbox` and refuses
  only a non-empty `ClaudeAllowedTools`; `codexSafetyArgs` (156–162) renders `--sandbox
  <mode> --ask-for-approval <policy>`; `launchCodexInteractive` (94–109) starts the
  process only on `Right`.

Tests as they stand. `baikai-agent/test/Main.hs` holds the in-process runner tests
(`timeoutTest`, `processGroupTest`, `outputLimitTest` …) around `withFakeExecutable`,
which writes a shell script into a temporary directory; every runner behaviour is a few
lines of `sh`. `baikai-agent/test/CliTests.hs` tests the command surface through
`runAgentCliWithPaths` without spawning the binary. `baikai/test/CliInternalSpec.hs`
parses `test/fixtures/codex-events.jsonl` through `parseCodex = parseCodexJsonlStream .
Stream.fromList`. `baikai/test/AgentAssetsSpec.hs` has `codexTomlTest` asserting the
`"""` form. `baikai/test/InteractiveSpec.hs` has `codexSafetyRenderingTest` pinning the
four approval spellings. `baikai-openai/test/Main.hs` has `safetyStillRendersTest` (a
`CodexApprovalNever` sandbox renders `--sandbox read-only --ask-for-approval never`) and
a refusal test for a Claude allow-list. `cabal test <package>` runs a package's suite.

Documentation touched: `docs/user/unattended-agent-runs.md` (exit-code table 271–283,
Streams 287–312), `docs/user/interactive-launches.md` (behaviour table 228–233 and the
refusal messages above it), `docs/user/agent-assets.md` (Codex Custom Agents, 53–70), and
the capability records CAP-17 `docs/capabilities/unattended-agent-runs.md`, CAP-18
`docs/capabilities/baikai-agent-command.md`, CAP-16 `docs/capabilities/interactive-launches.md`,
CAP-22 `docs/capabilities/agent-asset-layouts.md`, plus `docs/capabilities/log.md`, which
the bundle's profile enforces. Every code change updates the Haddock it touches and adds
`CHANGELOG.md` entries under `[Unreleased]`, scoped by package, so EP-11 reconciles
rather than discovers.

ADR context. The local corpus `docs/adr/` is plain files (see
`docs/adr/0001-architecture-decision-record-convention.md`; no profiled bundle, no
handle allocation). `docs/adr/0003-the-adapter-owns-the-translation-description.md`
bears on M3: what the installed `codex` binary accepts is the vendor adapter's
knowledge, so the refusal lives in `baikai-openai`. No other local ADR is relevant, no
cross-repository ADR applies (the MasterPlan's Mori search found nothing), and this plan
creates `docs/adr/0006-…` in M1.


## Plan of Work

Four milestones, fixed by the MasterPlan, each building and testing green on its own.
M1 makes the binary honest and proves it with a test that spawns it. M2 fixes what the
timeout does once it can fire, and the output encoding. M3 and M4 are independent of
the first two and of each other.

### Milestone 1 — `baikai` executable on the threaded RTS, proven by a spawned-binary timeout test

Scope: the shipped binary links the threaded RTS, and the suite proves it against the
built executable rather than against itself. At the end, `baikai +RTS --info` reports
`("RTS way","rts_thr")`, and `baikai agent run` against a child that sleeps two minutes
with a short `timeout` exits 75 in a few seconds instead of two minutes.

In `baikai-agent/baikai-agent.cabal`, add to the `executable baikai` stanza:

```cabal
  -- The runner waits on the child with waitForProcess under System.Timeout
  -- and drains the child's pipes on forked threads. Without the threaded
  -- runtime the wait blocks every Haskell thread, so the timeout can never
  -- fire and a chatty child deadlocks on a full pipe. BinaryTests proves it.
  ghc-options:    -threaded
```

In the `test-suite baikai-agent-test` stanza add `BinaryTests` to `other-modules` and,
after `build-depends`, `build-tool-depends: baikai-agent:baikai` with a comment: build the
shipped executable before this suite and put it on `PATH`, so `BinaryTests` exercises the
binary a user installs rather than the suite's own runtime.

Create `baikai-agent/test/BinaryTests.hs` exporting `binaryTests :: TestTree` and register
it in the top-level `testGroup` in `baikai-agent/test/Main.hs`; it needs only packages the
suite already lists. Its locator:

```haskell
-- | The built executable. Under `cabal test` the build-tool-depends entry
-- puts it on PATH; BAIKAI_AGENT_TEST_EXECUTABLE overrides that for a test
-- binary run by hand. Absence is a hard failure, never a skip.
builtBaikai :: IO FilePath
builtBaikai = do
  override <- lookupEnv "BAIKAI_AGENT_TEST_EXECUTABLE"
  found <- maybe (findExecutable "baikai") (pure . Just) override
  maybe (assertFailure "no baikai executable: run via `cabal test`, or set BAIKAI_AGENT_TEST_EXECUTABLE") pure found
```

`runBaikai :: FilePath -> [String] -> [(String, String)] -> FilePath -> IO (ExitCode,
ByteString, ByteString)` runs it under `P.withCreateProcess` with `std_in = NoStream`,
both output pipes read to end of file on forked threads through `MVar`s (the pattern in
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`), an explicit environment — `PATH`
from the test's own environment, `HOME` and `XDG_CONFIG_HOME` pointing at the temporary
directory so no real operator file is consulted, plus whatever a test adds — and the
working directory given. Two tests:

`reportsTheThreadedRuntimeTest` runs `baikai +RTS --info` and asserts the stdout contains
`("RTS way","rts_thr")`; a non-threaded (or stale) binary prints `rts_v`.

`timesOutAHungAgentTest` writes an operator-scope KDL file and a stub agent into a
temporary workspace, runs the binary, and asserts the observable contract. The stub
records its process ids; in M1 it dies on SIGINT, and M2 adds the `trap` line:

```sh
#!/bin/sh
echo "$$" > "$BAIKAI_TEST_PIDFILE"
printf 'partial output before the hang\n'
sleep 120 &
echo "$!" >> "$BAIKAI_TEST_PIDFILE"
wait
```

The job file, written to `<tmp>/agents.kdl` and passed with `--user-config` — the operator
scope, so the test is unaffected if EP-6 later refuses `executable` from the repository
scope:

```kdl
jobs { hang { provider "claude" executable "<tmp>/hang.sh" working-dir "<tmp>/workspace"
              output "capture" timeout "3s" safety { capability "read-only" } } }
```

Three seconds rather than one, for the reason recorded in Surprises & Discoveries: a
one-second deadline is shorter than the time the operating system takes to start
`/bin/sh` while the rest of the suite runs in parallel, so the case failed having never
let the stub run a line. Three seconds still leaves the stub's own hundred-and-twenty
second sleep as the only other thing that could end the run.

The test runs `baikai agent run hang --prompt go --user-config <tmp>/agents.kdl` with
`BAIKAI_TEST_PIDFILE=<tmp>/pids` in the environment, wrapped in `System.Timeout.timeout
30_000_000` so the pre-fix hang fails in thirty seconds rather than two minutes, and
asserts: the run returned (`Just`, not `Nothing`); the exit code is `ExitFailure 75`;
wall-clock time under fifteen seconds; and every pid in the pid file is gone, checked with
`readProcessWithExitCode "kill" ["-0", pid] ""` returning a failure exit (`kill -0` reports
whether a process exists). Write the test first and run it against the unthreaded binary
to watch it hang; record that transcript.

Write `docs/adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md` in
the corpus convention: frontmatter `title: A process-spawning executable ships on the
threaded runtime`, `status: accepted`, `date: 2026-08-27`; Context (why `waitForProcess`
under the non-threaded RTS blocks every thread; the suite was threaded, the binary was
not; REV-2 F.1); Decision (every executable in this repository that spawns and waits on
a child is compiled with `-threaded`, and its test suite spawns the built executable at
least once to prove the runtime it ships with — a suite's own `ghc-options` are never
evidence about a binary); Consequences (`build-tool-depends` on the suite, the `+RTS
--info` probe, what a future executable must do, `-N` deliberately not set). Add its row
to `docs/adr/README.md` and a `CHANGELOG.md` entry under `[Unreleased]` for `baikai-agent`
(Fixed: the `baikai` executable links the threaded runtime, so `timeout` fires and a
chatty child cannot deadlock the run).

Acceptance: `cabal test baikai-agent` builds the executable first and passes, including
both new tests; the pre-fix hang transcript is in Surprises & Discoveries;
`cabal run baikai-agent:exe:baikai -- +RTS --info` prints a line containing `rts_thr`.

### Milestone 2 — SIGKILL escalation, drained output kept on timeout, UTF-8 output regardless of locale

Scope: once the timeout can fire, it must finish the job. At the end, a child that ignores
SIGINT and SIGTERM is dead within two grace periods of the deadline together with its
group, the bytes drained before the kill are returned and printed, and the binary's own
output is UTF-8 under any locale.

In `baikai/src/Baikai/Agent.hs`, add above `AgentRunFailure`, and export `AgentTimedOut (..)`
beside `AgentRunFailure (..)`:

```haskell
-- | What a run that hit its deadline left behind: the configured limit
-- (not the slightly larger elapsed time) and whatever each stream drained
-- before the group was killed — 'OutputNotCaptured' when inherited.
data AgentTimedOut = AgentTimedOut
  { limit :: !NominalDiffTime,
    stdout :: !AgentCapturedOutput,
    stderr :: !AgentCapturedOutput
  }
  deriving stock (Eq, Show, Generic)
```

Change the constructor to `RunTimedOut !AgentTimedOut` (Haddock: the run exceeded the
limit and its process group was interrupted, terminated, then killed; carries what was
drained before the kill) and `renderAgentRunFailure (RunTimedOut timedOut)` to render
`timedOut ^. #limit`. `baikai/test/AgentSpec.hs` line 210 constructs `RunTimedOut 90,`
inside `failureRenderingTest`'s `runFailures`; change it to
`RunTimedOut (AgentTimedOut 90 OutputNotCaptured OutputNotCaptured),`.

In `baikai-agent/src/Baikai/Agent/Run.hs`, four changes. First, `drain` keeps its bytes
on any exception: wrap `BS.hGetSome h chunkSize` in `go` with `try :: … (Either
SomeException ByteString)` and on `Left` return `OutputTruncated (BS.concat (reverse
chunks))` — interrupted, or the handle went away; what was read is real and more may have
existed. `forkDrain`'s comment that "nothing delivers an asynchronous exception to this
thread" becomes false; say the timeout path may interrupt the drain, and make `forkDrain`
return `(ThreadId, MVar AgentCapturedOutput)` (for an inherited stream: the current
thread's id and an already-full `MVar`). Second, `terminateGroup` becomes three bounded
stages. Under `BAIKAI_POSIX_SIGNALS` define `groupAlive :: Maybe P.Pid -> IO Bool` as
`either (const False) (const True) <$> trySync (Signals.signalProcessGroup
Signals.nullSignal leader)` (the null signal delivers nothing and fails with `ESRCH` once
no member exists; `False` on other platforms) and `killProcessGroup` beside
`terminateProcessGroup`, sending `Signals.sigKILL`. Then:

```haskell
terminateGroup :: P.ProcessHandle -> IO ()
terminateGroup ph = do
  leader <- P.getPid ph
  _ <- trySync (P.interruptProcessGroupOf ph)
  settled <- awaitGroup leader
  unless settled $ do
    _ <- trySync (terminateProcessGroup leader)
    settled' <- awaitGroup leader
    unless settled' $ do
      _ <- trySync (killProcessGroup leader)
      void (trySync (P.waitForProcess ph)) -- unbounded: SIGKILL cannot be ignored
  where
    -- True once the leader is reaped and no group member remains; polled
    -- every 50 ms for at most one grace period.
    awaitGroup leader = go (gracePeriodMicros `div` 50000)
      where
        go 0 = pure False
        go n = do
          exited <- P.getProcessExitCode ph
          alive <- groupAlive leader
          if isJust exited && not alive then pure True else threadDelay 50000 >> go (n - 1)
```

Keep the existing Haddock's reasoning about POSIX shells ignoring SIGINT and add why
each stage is bounded, why SIGKILL is the last word, and that without POSIX signals the
fallback is `P.terminateProcess` on the leader followed by the wait. Third, `consume`'s
`Nothing` branch collects the drains:

```haskell
    Nothing -> do
      terminateGroup ph
      capturedOut <- collect outDrain
      capturedErr <- collect errDrain
      pure (Left (RunTimedOut AgentTimedOut
        { limit = fromMaybe 0 (req ^. #timeout), stdout = capturedOut, stderr = capturedErr }))
  where
    -- The group is dead, so the pipe closes and the drain reaches EOF —
    -- unless something outside the group still holds it. Wait one grace
    -- period, then interrupt the drain, which answers with what it has.
    -- Interrupt rather than hClose: the blocked reader holds the handle lock.
    collect (tid, var) =
      Timeout.timeout gracePeriodMicros (takeMVar var)
        >>= maybe (killThread tid >> takeMVar var) pure
```

(`outDrain`/`errDrain` are the renamed `forkDrain` results; `killThread`, `threadDelay`
from `Control.Concurrent`; `unless`, `void` from `Control.Monad`; `isJust` from
`Data.Maybe`.) Fourth, the evidence side reads the timed-out output: the local
`capturedBytes` gains a case `Left (RunTimedOut timedOut)` returning `Agent.capturedBytes`
of the record's `stdout` field, so a codex run killed mid-stream still yields its thread
id from the complete lines it printed, as the `observeToolOutput` Haddock promises;
`evidenceStatus` keeps `CallAborted`. Update the module Haddock bullet "still running at
the deadline" to "interrupted, terminated, then killed; drained output kept".

In `baikai-agent/src/Baikai/Agent/Cli.hs`, `failureExitCode` keeps `RunTimedOut _ ->
timeoutExitCode`. `interpret`'s `Left` branch gains a first case for `Left (RunTimedOut
timedOut)` with the same stream discipline as a finished run: with `--json`, the existing
three fields (`outcome`, `exitCode`, `message`) followed by `streamFields "stdout"` and
`streamFields "stderr"` applied to the record's two streams (lift `streamFields` out of
`resultJson` to top level so both call it); without it, `standardOutput` is the decoded
`stdout` when capturing and empty otherwise, and `standardError` is the warnings, the
evidence note, the decoded `stderr` when capturing, then `renderAgentRunFailure
(RunTimedOut timedOut) <> "\n"`. Under `capture`, `response=$(baikai agent run job)`
therefore receives the partial answer with `$?` 75; under `tee` the bytes were already
echoed and are not repeated; under `inherit` there is nothing to print. Say so in the
`AgentCliRun` module Haddock.

In `baikai-agent/app/Main.hs`, replace `emit`:

```haskell
-- | Write both streams as UTF-8 bytes. hPutStr would encode through the
-- locale, and under LANG=C a non-ASCII character in the agent's answer
-- would throw after the run finished. Invalid UTF-8 from the child is
-- already U+FFFD by now (Baikai.Agent.Cli.decoded).
emit :: AgentCliRun -> IO ()
emit finished = do
  BS.hPut stdout (Text.encodeUtf8 (finished ^. #standardOutput))
  BS.hPut stderr (Text.encodeUtf8 (finished ^. #standardError))
  hFlush stdout >> hFlush stderr
```

with `Data.ByteString` and `Data.Text.Encoding` imported qualified, `hFlush` from
`System.IO`, `bytestring ^>=0.12` in the executable's `build-depends`, and the
`Data.Text.IO` import dropped.

Tests. In `baikai-agent/test/Main.hs`: `timeoutTest`'s assertion `Left (RunTimedOut
limit) -> limit @?= 1` becomes `Left (RunTimedOut timedOut) -> timedOut ^. #limit @?= 1`;
`processGroupTest`'s `Left (RunTimedOut _) -> pure ()` stays. Add
`keepsDrainedOutputOnTimeoutTest` (stub `printf 'partial\n'; sleep 5`, timeout 1:
`capturedBytes (timedOut ^. #stdout) @?= Just "partial\n"`); `escalatesToKillTest` (stub
`trap '' INT TERM` then `sleep 30`, timeout 1: `RunTimedOut` within six seconds of wall
clock — the pre-fix code never returns, so run it first and see the hang); and
`escapedPipeHolderTest`, gated on `findExecutable "perl"` (prints "skipped: perl not
found" and passes otherwise): stub `perl -MPOSIX -e 'setsid(); sleep 30' &` then
`printf 'held\n'; sleep 30`, timeout 1: `RunTimedOut` within eight seconds with
`capturedBytes (timedOut ^. #stdout) @?= Just "held\n"` — the case only `killThread` on
the drain ends. In `BinaryTests.hs`: add `trap '' INT TERM` as the stub's second line
and assert the captured stdout equals `"partial output before the hang\n"`; add
`writesUtf8UnderCLocaleTest`, a `capture` job whose stub prints `réconcilier — 文法`,
run with `LANG=C`, `LC_ALL=C` and no other `LC_*` variable, asserting exit 0 and stdout
bytes `Text.encodeUtf8 "réconcilier — 文法\n"` (pre-fix: exit 1, `hPutChar: invalid
argument` on stderr; record it).

Docs. `docs/user/unattended-agent-runs.md`: exit-code row 75 becomes "the run exceeded
its timeout; its process group was interrupted, terminated, then killed, and the output
drained before the kill is reported"; Streams gains a paragraph that a timed-out
`capture` job still prints what it drained with `$?` 75, that `--json`'s failure
envelope then carries `stdout`/`stderr` and the `…Truncated` flags, and that the
command's own output is UTF-8 regardless of locale. CAP-17
`docs/capabilities/unattended-agent-runs.md`: the runner paragraph becomes "interrupts,
then terminates, then kills the child's whole process group, each stage bounded by a
grace period, and returns what it drained"; add a `baikai-agent/test/BinaryTests.hs`
evidence entry (the built binary, on its own runtime, stops a child that ignores INT and
TERM within the grace periods, exits 75, keeps the drained output, and writes UTF-8
under `LANG=C`), and the same entry to CAP-18 `docs/capabilities/baikai-agent-command.md`.
Dated entry in `docs/capabilities/log.md`. `CHANGELOG.md`: `baikai` Changed —
`RunTimedOut` carries `AgentTimedOut` (breaking); `baikai-agent` Fixed — escalation,
kept output, UTF-8.

Acceptance: `cabal test baikai baikai-agent` green; `escalatesToKillTest` completes in
under six seconds; afterwards `pgrep -f 'sleep (30|120)'` prints nothing; the manual
transcript in Validation and Acceptance matches.

### Milestone 3 — unexpressible codex approval policies refused as `SafetyNotExpressible`

Scope: the codex interactive launcher refuses the two approval values the installed CLI
rejects, before any process starts, with a message naming the alternative. Nothing else
about the type or its spellings changes.

In `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs`, change the `CodexSandbox`
case of `safetyArgs`:

```haskell
  CodexSandbox sandbox approval
    | approvalAccepted approval -> Right (codexSafetyArgs sandbox approval)
    | otherwise ->
        Left
          ( SafetyNotExpressible
              AgentCodex
              ( "the installed codex CLI accepts only on-request and never for \
                \--ask-for-approval (codex 0.149.1); it rejects "
                  <> renderCodexApprovalPolicy approval
                  <> ", so the session was not started; use CodexApprovalOnRequest or \
                     \CodexApprovalNever"
              )
          )
```

with a predicate whose Haddock states the verification date and transcript it rests on:

```haskell
-- | Whether the installed codex generation accepts this policy. `codex
-- --help` at 0.149.1 (verified 2026-08-27) lists only on-request and never;
-- untrusted and on-failure are older spellings the CLI rejects with a usage
-- error, which would surface as Right (ExitFailure n) — a session that ran —
-- not the refusal this module promises.
approvalAccepted :: CodexApprovalPolicy -> Bool
approvalAccepted = \case
  CodexApprovalOnRequest -> True
  CodexApprovalNever -> True
  CodexApprovalUntrusted -> False
  CodexApprovalOnFailure -> False
```

Import `CodexApprovalPolicy (..)` from `Baikai.Interactive` and extend the module
Haddock's list of refused policies. In `baikai/src/Baikai/Interactive.hs`, add a Haddock
to `CodexApprovalUntrusted` and `CodexApprovalOnFailure`: spelled `untrusted` /
`on-failure`, which current codex releases reject; the codex launcher refuses a request
carrying this with `SafetyNotExpressible`; kept so the type stays stable for callers that
match on it. `renderCodexApprovalPolicy` and `codexSafetyRenderingTest` in
`baikai/test/InteractiveSpec.hs` stay unchanged — the spelling is not the defect.

Tests in `baikai-openai/test/Main.hs`, beside `safetyStillRendersTest`: a group
`refusesRejectedApprovalPoliciesTest` with one case per refused value asserting
`codexInteractiveCommand defaultCodexInteractiveConfig req` is `Left (SafetyNotExpressible
AgentCodex _)` and that `renderAgentRenderError` of it contains `untrusted` (respectively
`on-failure`) and `CodexApprovalOnRequest`, in the style of the allow-list refusal test at
lines 629–638; plus one case that `CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest`
still renders `["--sandbox","workspace-write","--ask-for-approval","on-request","--","inspect"]`.

Docs. `docs/user/interactive-launches.md`: split the table's last row into
`CodexSandbox mode CodexApprovalOnRequest` / `… CodexApprovalNever` → `Right` and
`CodexSandbox mode CodexApprovalUntrusted` / `… CodexApprovalOnFailure` → `Left
SafetyNotExpressible` for the Codex launcher; add the new message to the refusal
messages; say the installed CLI generation is the reason. CAP-16
`docs/capabilities/interactive-launches.md`: extend the refusal paragraph and the
`baikai-openai/test/Main.hs` evidence line. Log entry. `CHANGELOG.md`: `baikai-openai`
Fixed.

Acceptance: `cabal test baikai-openai baikai` green with the new group; in `cabal repl
baikai-openai`, `codexInteractiveCommand defaultCodexInteractiveConfig
(interactiveLaunchRequest "x" & #safety .~ CodexSandbox CodexReadOnly
CodexApprovalUntrusted)` prints `Left (SafetyNotExpressible AgentCodex "...")`. With the
real binary, `codex --sandbox read-only --ask-for-approval untrusted -- hello` prints a
usage error naming the possible values — the outcome the refusal now prevents.

### Milestone 4 — linear-time JSONL line assembly and correct TOML escaping for agent assets

Scope: two pure functions in the core package. At the end, a two-megabyte codex event
parses in bounded time, and every Codex custom-agent body renders as TOML a real parser
accepts.

In `baikai/src/Baikai/Provider/Cli/Internal.hs`, replace the body of
`parseCodexJsonlStream`:

```haskell
parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport
parseCodexJsonlStream chunks = do
  (acc, pending) <- Stream.fold (Fold.foldl' step (emptyCodexAccumulator, [])) chunks
  let final = absorbLine acc (BS.concat (reverse pending))
  pure CodexRunReport { message = Text.concat (reverse (final ^. #messages)), ... }
  where
    -- Split each chunk on the newline byte. An unfinished line is carried
    -- as reversed pieces and concatenated once, when its newline arrives,
    -- so every byte is copied a bounded number of times whatever the line
    -- length. (The previous per-byte BS.snoc was quadratic in line length.)
    step (acc, pending) chunk = case BS.elemIndex newlineByte chunk of
      Nothing -> (acc, chunk : pending)
      Just i ->
        let (piece, rest) = BS.splitAt i chunk
            acc' = absorbLine acc (BS.concat (reverse (piece : pending)))
         in step (acc', []) (BS.drop 1 rest)
    absorbLine acc line = maybe acc (absorbCodexEvent acc) (Aeson.decodeStrict line)
```

`BS.splitAt` and `BS.drop` are constant-time slices; an empty final `pending` after a
trailing newline decodes `""` to `Nothing` and is skipped, preserving the "last line
without a newline is still parsed" behaviour. Remove the unused `Unfold` import and the
`Word8` stream; keep the Haddock's promise that a non-JSON line is skipped.

Tests in `baikai/test/CliInternalSpec.hs`, in `codexParserTests`: "a line spanning several
chunks is one event" — `parseCodex ["{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_mess", "age\",\"text\":\"split\"}}\n"]`
yields `message == "split"`; "a final line without a newline is still parsed" (an inline
event with no `\n`); and "a multi-megabyte event is assembled in linear time": one event
whose `text` is two million `a`s, run as `System.Timeout.timeout 10_000_000 (parseCodex
[event])`, asserting `Just` with `Text.length message == 2_000_000`. The current code
times out here (the per-byte copy is on the order of 10¹² byte moves); record it.

In `baikai/src/Baikai/AgentAssets.hs`, replace the two renderers:

```haskell
-- | A TOML basic string: quotation mark, backslash, and every control
-- character (U+0000–U+001F and U+007F) escaped, as TOML 1.0 requires.
tomlString :: Text -> Text
tomlString t = "\"" <> Text.concatMap escapeBasic t <> "\""

escapeBasic :: Char -> Text
escapeBasic = \case
  '"' -> "\\\""; '\\' -> "\\\\"; '\b' -> "\\b"; '\t' -> "\\t"
  '\n' -> "\\n"; '\f' -> "\\f"; '\r' -> "\\r"
  c | c < ' ' || c == '\DEL' -> Text.pack (printf "\\u%04X" (fromEnum c))
    | otherwise -> Text.singleton c

-- | The instructions body. A literal multi-line string shows the Markdown
-- verbatim, backslashes intact. A literal string cannot contain three
-- apostrophes, a bare carriage return, or a control character other than
-- tab and newline; such a body falls back to an escaped basic string.
tomlMultilineString :: Text -> Text
tomlMultilineString t
  | literalSafe t = "'''\n" <> t <> "\n'''"
  | otherwise = "\"\"\"\n" <> Text.concatMap escapeMultiline t <> "\n\"\"\""
  where
    literalSafe body = not ("'''" `Text.isInfixOf` body) && Text.all literalChar body
    literalChar c = c == '\t' || c == '\n' || (c >= ' ' && c /= '\DEL')
    escapeMultiline '\n' = "\n" -- a raw newline is allowed and keeps lines readable
    escapeMultiline c = escapeBasic c
```

(`printf` from `Text.Printf` in `base`; `LambdaCase` is on in the package.) Escaping
every `"` in the fallback guarantees `"""` cannot appear, and escaping every `\` means no
line-ending backslash can trim a following line.

Tests in `baikai/test/AgentAssetsSpec.hs`. `codexTomlTest` currently asserts the third
line as `"developer_instructions = \"\"\"\nRead first.\nAvoid triple quotes: \\\"\\\"\\\"\n\"\"\""`;
the body `"Read first.\nAvoid triple quotes: \"\"\""` is literal-safe, so the expected line
becomes `"developer_instructions = '''\nRead first.\nAvoid triple quotes: \"\"\"\n'''"`
(the `"""` inside is untouched in a literal string); rename the test to "Codex
custom-agent TOML uses a literal body and escapes basic strings". Add: "a body with
backslashes renders verbatim in a literal string" (`"match \\d+ then \\"` appears
byte-for-byte between `'''` delimiters); "a body containing three apostrophes falls back
to an escaped basic string" (`"say '''hi'''"` renders as `"""\nsay '''hi'''\n"""`, and
`"a\\b '''"` renders `a\\b '''`); "control characters in name and description are
escaped" (`"x\SOHy"` → `"xy"`, `"\DEL"` → `""`).

Docs. `docs/user/agent-assets.md`, Codex Custom Agents: replace "places instructions in a
multiline TOML string" with the literal-string rule and its fallback, noting that
backslashes in a body are no longer escape sequences. CAP-22
`docs/capabilities/agent-asset-layouts.md`: the description and the `AgentAssetsSpec.hs`
evidence line. Log entry. `CHANGELOG.md`: `baikai` Fixed — both.

Acceptance: `cabal test baikai` green including the bounded-time case; the manual TOML
check in Validation and Acceptance parses.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/baikai` inside
the Nix dev shell, after one `cabal build all --enable-tests` so later runs are
incremental.

1. **M1, test first.** Create `baikai-agent/test/BinaryTests.hs` with the non-trapping
   stub, wire it into `Main.hs` and `other-modules`, add `build-tool-depends`, but do
   *not* add `-threaded` yet. Run:

   ```bash
   cabal test baikai-agent --test-show-details=direct
   ```

   Expected: cabal builds the executable, then `timesOutAHungAgentTest` fails after
   thirty seconds and `reportsTheThreadedRuntimeTest` fails showing `("RTS
   way","rts_v")`; paste both into Surprises & Discoveries (a `sleep 120` may linger; it
   exits on its own). Add `ghc-options: -threaded` and rerun. Expected tail:

   ```text
   the built baikai binary
     baikai +RTS --info reports the threaded runtime:            OK
     agent run stops a child that outlives its timeout, exit 75: OK (2.1s)
   All N tests passed
   Test suite baikai-agent-test: PASS
   ```

   Write the ADR and its README row and the changelog entry; commit:

   ```text
   fix(agent)!: ship the baikai executable on the threaded runtime

   Without -threaded, waitForProcess blocked every Haskell thread, so the
   configured timeout never fired in the installed binary. The test suite
   now spawns the built binary against a child that outlives its timeout.

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/58-ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

2. **M2, test first.** Add `AgentTimedOut` (the tests do not compile without it), then
   `escalatesToKillTest` and `keepsDrainedOutputOnTimeoutTest` in
   `baikai-agent/test/Main.hs`, and run `cabal test baikai-agent`: the first hangs
   (Ctrl-C after thirty seconds; note the transcript), the second fails because the
   timed-out `Left` carries `OutputNotCaptured`. Apply the `Run.hs`, `Cli.hs`, `Main.hs`
   and cabal edits, the perl-gated test, the `trap` line and partial-output assertion in
   `BinaryTests.hs`, and `writesUtf8UnderCLocaleTest`. Run:

   ```bash
   cabal build all --enable-tests
   cabal test baikai baikai-agent
   pgrep -fl 'sleep (30|120)' || echo "no leftover children"
   ```

   Expected: both suites `PASS`; `escalatesToKillTest` reports four to six seconds;
   `no leftover children`. Update the guide, CAP-17, CAP-18, the log and the changelog;
   commit:

   ```text
   fix(agent)!: escalate a timed-out run to SIGKILL, keep its drained output, write UTF-8

   RunTimedOut now carries AgentTimedOut with the limit and both drained
   streams; escalation is INT, TERM, KILL to the whole group, each stage
   bounded by the grace period; the executable writes UTF-8 bytes.

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/58-ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

3. **M3.** Edit `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` and the two
   Haddocks in `baikai/src/Baikai/Interactive.hs`, add the test group, update the guide
   table, CAP-16, the log and the changelog; `cabal test baikai baikai-openai`; commit:

   ```text
   fix(interactive): refuse codex approval policies the installed CLI rejects

   codex 0.149.1 accepts only on-request and never for --ask-for-approval;
   CodexApprovalUntrusted and CodexApprovalOnFailure are now refused before
   launch with SafetyNotExpressible instead of failing after a process started.

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/58-ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

4. **M4, test first.** Add the three parser cases and the three TOML cases plus the
   changed `codexTomlTest` expectation; `cabal test baikai` fails the bounded-time case
   after ten seconds and the TOML cases on the `"""` form. Apply the two source edits and
   rerun (`PASS`, the linear-time case under one second); update
   `docs/user/agent-assets.md`, CAP-22, the log and the changelog; commit:

   ```text
   fix(core): assemble codex JSONL lines in linear time and render TOML bodies as literal strings

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/58-ship-baikai-agent-on-the-threaded-rts-and-fix-the-coding-agent-surfaces.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

5. **Wrap-up.** Run the keyless gate (Validation and Acceptance), tick the four EP-1
   lines and set the registry row to Complete in
   `docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`, fill
   Outcomes & Retrospective, and run the ADR distillation pass (the ADR exists from M1;
   add whatever M2 taught that is durable — for instance that a drain is interrupted,
   never closed). Commit as `docs(plans): complete EP-1 …` with the same trailers.


## Validation and Acceptance

Behavioural acceptance, each observable:

- **Runtime.** `cabal run baikai-agent:exe:baikai -- +RTS --info` prints a list that
  includes `("RTS way","rts_thr")` (a *package* is also named `baikai`, so `cabal run
  baikai` is ambiguous; use the qualified form).
- **Timeout on the installed binary.** With a temporary operator file and the trapping
  stub:

  ```bash
  tmp=$(mktemp -d); mkdir "$tmp/ws"
  cat > "$tmp/hang.sh" <<'EOF'
  #!/bin/sh
  trap '' INT TERM
  printf 'partial output before the hang\n'
  sleep 120 &
  wait
  EOF
  chmod +x "$tmp/hang.sh"
  cat > "$tmp/agents.kdl" <<EOF
  jobs { hang { provider "claude" executable "$tmp/hang.sh" working-dir "$tmp/ws"
                output "capture" timeout "1s" safety { capability "read-only" } } }
  EOF
  time cabal run baikai-agent:exe:baikai -- agent run hang --prompt go --user-config "$tmp/agents.kdl"
  echo "exit=$?"; pgrep -fl 'sleep 120' || echo "child gone"
  ```

  Expected: stdout `partial output before the hang`, stderr `the run exceeded its
  timeout of 1s`, `exit=75`, `real` under seven seconds (one second plus two 2-second
  grace periods plus start-up), and `child gone`. Before M1 the command returns after
  two minutes; before M2 it never returns while the trapping stub lives.
- **UTF-8 under a C locale.** With a stub `printf 'réconcilier — 文法\n'` in the same job
  shape: `env -i PATH="$PATH" HOME="$tmp" LANG=C LC_ALL=C cabal run
  baikai-agent:exe:baikai -- agent run say --prompt go --user-config "$tmp/agents.kdl" |
  od -c | head -2` shows the UTF-8 bytes (`303 251` for `é`) and the exit code is 0.
  On Linux before M2 this was exit 1 and `hPutChar: invalid argument (cannot encode
  character '\233')`. On macOS it was already 0, because GHC on Darwin uses UTF-8 as
  the locale encoding whatever `LANG` says (Surprises & Discoveries); the acceptance
  here is therefore the bytes, not a change in them.
- **Codex approval refusal.** `cabal test baikai-openai` runs
  `refusesRejectedApprovalPoliciesTest` green; the message names the rejected spelling
  and `CodexApprovalOnRequest`.
- **JSONL in linear time.** `cabal test baikai` runs "a multi-megabyte event is assembled
  in linear time" well under a second; the pre-M4 code fails it by its ten-second timeout.
- **TOML a parser accepts.** Render a body with backslashes and check it with the system
  Python's TOML parser:

  ```bash
  cabal repl baikai <<'EOF' | tail -n +2 > "$tmp/agent.toml"
  import Baikai.AgentAssets
  import qualified Data.Text.IO as T
  T.putStr (codexCustomAgentToml CodexCustomAgent { name = "reviewer", description = "Reviews\tchanges", developerInstructions = "Match \\d+ then \\ and stop.\nDone." })
  EOF
  python3 -c 'import tomllib,sys; d=tomllib.load(open(sys.argv[1],"rb")); print(repr(d["developer_instructions"]))' "$tmp/agent.toml"
  ```

  Expected: `'Match \\d+ then \\ and stop.\nDone.\n'` — the body verbatim plus the
  trailing newline the renderer has always added; pre-M4 output makes `tomllib` raise
  `TOMLDecodeError` on the unknown escape `\d`.
- **Whole-project health.** The release skill's keyless gate: a bare `cabal test all`
  makes real, billable provider calls, because `baikai-smoke` gates its API cases on the
  key variables and its CLI cases on `findExecutable` alone. Run exactly the command
  from `agents/skills/release/SKILL.md` (adjust the two filtered `PATH` entries to where
  `claude` and `codex` are installed):

  ```zsh
  baikai_test_path=(${path:#/Users/shinzui/.local/bin})
  baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
  env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
    -u OPENAI_KEY -u OPENAI_API_KEY \
    -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
    -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
    -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
    cabal test all
  ```

  Every suite must end with `All N tests passed` and `PASS`, not merely skip. The
  filtered `PATH` still contains `sh`, `kill`, `pgrep` and (optionally) `perl` under
  `/bin` and `/usr/bin`; the build-tool `PATH` entry for `BinaryTests` is prepended by
  cabal inside the run and is unaffected by the filtering.
- **Formatting and bundles**, as the release skill's gates require after capability
  edits:

  ```bash
  nix fmt && git diff --exit-code
  okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
  ```


## Idempotence and Recovery

Every step is a source edit plus a build-and-test cycle and can be repeated. The four
milestones land as four commits, each leaving the tree green, so `git revert` of any one
is a safe rollback; M2 depends on M1 (a SIGKILL the binary cannot reach is untestable
end to end), while M3 and M4 are independent of everything else. Tests create files only
under `withSystemTempDirectory`. A test interrupted mid-run may leave a `sleep 30`,
`sleep 120` or `perl … sleep 30` behind; they exit on their own, and `pkill -f 'sleep
(30|120)'` removes them sooner. If `cabal test baikai-agent` appears to hang during M1
or M2 work, that *is* the defect reproducing: Ctrl-C, finish the edit, rerun. If
`BinaryTests` fails with "no baikai executable", the suite was run outside cabal — run
it through `cabal test`, or set `BAIKAI_AGENT_TEST_EXECUTABLE=$(cabal list-bin
baikai-agent:exe:baikai)`. If it fails showing `rts_v`, a stale binary was found first;
`cabal build baikai-agent:exe:baikai` and check `which -a baikai`. The `--json` envelope
change on timeout is additive (stream fields appear only when a stream was captured), so
scripts reading `outcome` and `exitCode` keep working.


## Interfaces and Dependencies

No new package dependencies for library code. `baikai-agent`'s executable adds
`bytestring ^>=0.12` (already in the plan); its library uses two more names from
`System.Posix.Signals` behind `BAIKAI_POSIX_SIGNALS`, `sigKILL` and `nullSignal`.
`killThread`, `threadDelay`, `isJust` and `printf` are `base`. `streamly-core` stays at
`>=0.3 && <0.5`; the M4 fold uses only `Streamly.Data.Fold.foldl'` and
`Streamly.Data.Stream.fold`. The test suite adds `build-tool-depends: baikai-agent:baikai`.

Signatures that must exist at the end of each milestone, with full module paths:

M1 — no library signature changes. `baikai-agent/test/BinaryTests.hs` exports
`binaryTests :: Test.Tasty.TestTree`.

M2 — `Baikai.Agent.AgentTimedOut` (record with `limit :: NominalDiffTime`, `stdout ::
AgentCapturedOutput`, `stderr :: AgentCapturedOutput`, exported with its constructor);
`Baikai.Agent.AgentRunFailure` gains `RunTimedOut !AgentTimedOut` in place of `RunTimedOut
!NominalDiffTime`. Private, in `baikai-agent/src/Baikai/Agent/Run.hs`: `forkDrain ::
Maybe Int -> Maybe Handle -> Maybe Handle -> IO (ThreadId, MVar AgentCapturedOutput)`,
`killProcessGroup :: Maybe P.Pid -> IO ()`, `groupAlive :: Maybe P.Pid -> IO Bool`;
in `baikai-agent/src/Baikai/Agent/Cli.hs`: `streamFields :: Text -> AgentCapturedOutput
-> [(Text, Text)]` at top level. `terminateGroup`, `renderAgentRunFailure` and `emit`
keep their types.

M3 — `Baikai.Provider.OpenAI.Interactive.codexInteractiveCommand` and
`launchCodexInteractive` keep their signatures; private `approvalAccepted ::
CodexApprovalPolicy -> Bool`. `Baikai.Interactive` is unchanged in type.

M4 — `Baikai.Provider.Cli.Internal.parseCodexJsonlStream :: Stream IO ByteString -> IO
CodexRunReport`, `Baikai.AgentAssets.tomlString` and `tomlMultilineString :: Text ->
Text` unchanged in type; the last two stay private (EP-10 owns exports).

Cross-plan interfaces. EP-6 edits the evidence `endpoint` and `errorInfo` region of
`Run.hs` and may refuse `executable` from the repository scope; this plan's
spawned-binary test sets it from the operator scope for that reason, and EP-6 must keep
that path working or update `BinaryTests.hs` in its own change. EP-10 records the
`RunTimedOut` change as a `baikai` major and decides whether `CodexApprovalUntrusted`
and `CodexApprovalOnFailure` are deprecated; this plan touches neither versions nor
exports. EP-11 reconciles the guide wording this plan changes.

---

Revision note (2026-08-27): initial version, authored from REV-2 Theme F items F.1 and
F.5–F.9 and Theme I item 2 ("a test that spawns the built binary"), the MasterPlan's
milestone list for EP-1, and the source at HEAD `5411947`.
