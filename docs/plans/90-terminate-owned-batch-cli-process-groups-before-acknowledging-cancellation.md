---
id: 90
slug: terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation
title: "Terminate owned batch CLI process groups before acknowledging cancellation"
kind: exec-plan
intention: intention_01m493n88me3ssvz3qtqgv42ns
created_at: 2026-10-06T16:47:40Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-06T16:47:40Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T16:54:27Z
      mode: "other"
      note: "Ground the new fix plan in owner and published-package cancellation probes, dependency source, and ADR context."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T17:19:56Z
      mode: "implement"
      note: "Implement shared process-group ownership, integrate batch adapters and version probes, and verify cancellation regressions."
  reviews:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-06T17:06:53Z
      verdict: "changes-requested"
      note: "Self-review: require a process-group ownership mechanism safe from identifier reuse after reaping, and concrete Darwin/Linux live-versus-zombie detection and settling semantics."
---


# Terminate owned batch CLI process groups before acknowledging cancellation

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. Distill durable process
ownership decisions into docs/adr/ before declaring implementation complete.


## Purpose / Big Picture


A caller cancelling `claudeCliProvider` or `codexCliProvider` must be able to
continue knowing that the batch call's owned subprocesses have stopped. Today a
fake vendor executable can start a background child that remains alive after
cancellation is requested. Fix [BUG-1](../bug-reports/batch-cli-cancellation-leaves-child-alive.md)
by owning a separate process group for each batch invocation, terminating its
members, joining local reader workers, and reaping the direct child before the
provider finishes cancellation. Preserve the asynchronous exception: cancellation
must not become an ordinary error-shaped `Response`.

The visible proof is an offline regression suite using real shell subprocesses
and recorded process identifiers, with no vendor binary, login, or API key. Both
public adapters must pass, including cancellation during synthetic stream
consumption and during their optional executable-version evidence probe.


## Progress


- [x] Milestone 1 (2026-10-06): shared scope verified before integration with 10 Darwin tests passing in 1.65s; strengthened final scope suite has 15 positive regressions, including explicit anchor reaping and cancellation during successful-callback cleanup.
- [x] Milestone 2 (2026-10-06): both adapters and evidence probes use shared ownership. Darwin focused coverage passes 15 core, 5 Claude, and 6 Codex cases; full affected suites pass 809 core, 413 Claude, 294 OpenAI, and 116 agent tests (1,632 total), including existing response, schema, evidence, argument, missing-binary, and stderr-flood cases.
- [x] Milestone 3 (2026-10-06): all 26 focused cases and all 1,632 affected tests pass on Darwin and Linux. User guide, CAP-15, BUG-1, shared changelog, and ADR 0026 document the contract and limits; BUG-1 remains in-progress pending publication.

Implementation is committed as `87996dd`. Before integration, both adapter
regressions observed live 30-second descendants at 200 ms and failed to receive
cancellation acknowledgement within three seconds. After integration, all 26
focused cases and the full affected suites pass on both platforms. Publishing a
release and changing the consumer's promotion gate remain subsequent work.


## Surprises & Discoveries


The process package has no option for joining an existing process group;
`child_group` means the Unix credential group, not a process group. The Unix
Haskell `forkProcess` documentation warns against multiple runtime capabilities.
A minimal C anchor avoids running Haskell or allocating after fork.

Darwin returns EPERM when signalling a zombie-only group. A redundant final
SIGKILL initially prevented direct-child reaping in the resistant-group test.
After verified termination the scope now reaps the anchor without signalling
that dead group again; ordinary permission and observation failures still fail
cleanup.

Running several Cabal suites and every fixture in parallel under concurrent
compiler load exceeded the two-second readiness bound. Qualification commands
now select one Cabal job and one Tasty test thread, preserving the two-second
readiness and three-second cancellation bounds. The anchor's membership is
established synchronously by the parent; it needs no readiness pipe or blocking
acquisition handshake.

Linux's Cabal 3.14.1.1 preserves the invocation directory. An initial root-level
full core run failed 27 relative fixture/source reads even though the files were
present. Running from the package directory fixes those failures without source
changes. GHC's ticker emits interrupted-poll diagnostics under x86_64 Rosetta;
the qualified suites still complete successfully. The container's PID 1 does
not reap adopted grandchildren, so tests report retained, stopped zombies while
requiring both directly owned children to be reaped.

Linux qualification exposed three pre-existing agent-test assumptions. A
three-second delayed grandchild marker raced the runner's one-second timeout
plus two-second SIGINT grace; that test now records a 30-second child and checks
its state immediately after return. The binary test's null-signal liveness check
counted adopted zombies as running; it now checks `ps` states. Rosetta can retain
an ELF descriptor on closed stdin, so the argument-transport fixture now tests
for duplicate prompt text and includes a positive control proving it detects
incorrect stdin delivery. These changes strengthen qualification without changing
the agent runner's production lifecycle.


## Decision Log


Decision (2026-10-06): put process ownership in one shared internal core module and
use it from both adapters, rather than fixing only the Codex path or depending on
Cradle cleanup. The adapters currently use different runners; a shared scope makes
the cancellation guarantee the same. Do not introduce a dependency from either
adapter to `baikai-agent`, which already depends on the adapters.

Decision (2026-10-06): target POSIX process groups on the supported Darwin/Linux
platforms, preserve existing APIs and synchronous error responses, and include
subprocesses launched for evidence within the call's ownership. This fixes shipped
lifecycle behavior; new public deadline/output-limit settings, native-tool
confinement, foreground launch changes, Windows job objects, release publication,
and consumer-gate removal are outside this plan.


Decision (2026-10-06): retain an unreaped group-member anchor through all signals
and final observations, and use portable POSIX `ps` state checks with a one-second
post-SIGKILL settling limit. This resolves the first review’s identifier-reuse
and zombie-observation findings while preserving early callback reaping.


## Outcomes & Retrospective


Both public batch adapters and version probes now share exception-safe process
and reader ownership. The original reproductions failed before integration;
positive regressions verify that cleanup precedes asynchronous acknowledgement,
including resistant children, early leader reaping, repeated cancellation,
streams, probes, and schema lifetime. The anchor resolves group identifier reuse
without restricting callbacks from reaping the leader. Durable constraints are
recorded in [ADR 0026](../adr/0026-batch-cli-cancellation-owns-process-groups-and-reader-workers.md).

Qualification used GHC 9.12.4, process 1.6.26.1, unix 2.8.8.0,
cradle 0.0.0.0, streamly 0.11.1, and streamly-core 0.3.1 on both platforms.
Darwin is native arm64; Linux is Debian x86_64, kernel 6.18.15, through Rosetta.
All focused cases pass with the original two-second readiness and three-second
cancellation bounds:

| Suite | Count | Darwin duration | Linux duration |
| --- | ---: | ---: | ---: |
| Core ownership/probe focused | 15 | 12.01s | 15.66s |
| Claude cancellation focused | 5 | 3.92s | 6.06s |
| Codex cancellation focused | 6 | 4.22s | 6.90s |
| Core full | 809 | 28.31s | 33.03s |
| Claude full | 413 | 8.44s | 8.81s |
| OpenAI full | 294 | 11.21s | 10.91s |
| Agent full | 116 | 44.96s | 44.04s |

Both full sets contain 1,632 passing tests. The argument-transport positive
control also passes in a separate one-case Linux run (0.26s). The agent
qualification changes are described in Surprises & Discoveries. Source distributions include all fixture
modules and the C helper. Formatting, Windows CPP type-checking, and enforced OKF
validation pass. Windows type-checking does not establish native runtime behavior.

The fix is unreleased. A subsequent release must publish the core package with
the new internal module before the adapters and raise their minimum core bounds
to that released version. BUG-1 remains `in-progress`, without `fixedVersion`;
the consumer must rerun positive released-package probes before removing its
promotion guard. Native Windows runtime qualification and containment of escaped
groups remain outside this plan.


## Context and Orientation


The adapter descriptions below describe the baseline at plan creation. The
completed implementation replaces those batch runners and the probe with
`Baikai.Provider.Cli.Process.Internal`; foreground runners remain separate.

A process group is an operating-system collection of processes that can receive a
signal together. A newly spawned group is normally identified by its leader's
process identifier (PID). Children inherit the group unless they deliberately
leave it. Reaping means collecting a terminated direct child's exit status with
`waitForProcess`; it removes that child's zombie entry. Baikai cannot directly
reap grandchildren after they are adopted by the operating system. Require those
descendants to stop, and distinguish a non-running zombie awaiting its adoptive
parent from a live process. This scope is lifecycle cleanup, not a sandbox against
programs that deliberately create a new session or group.

`baikai-claude/src/Baikai/Provider/Claude/Cli.hs` constructs the public provider in
`claudeCliProvider`. Its `runClaudeCli` uses Cradle `run`, captures raw stdout and
stderr, then decodes with `Internal.decodeClaudeCliResult`. The batch path has no
separate process group. `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` constructs
`codexCliProvider`; `runCodexCli` uses `System.Process.withCreateProcess`, and
`consume` parses stdout while a discarded `forkIO` thread drains stderr. Its
`CreateProcess` also lacks `create_group`. Closing stderr from a finalizer can
block on the reader's handle lock. `withSchemaFile` owns Codex's temporary schema;
its outer lifetime must encompass process cleanup on every exit.

`baikai/src/Baikai/Provider/Cli/Internal.hs` owns `trySync`, which rethrows
`SomeAsyncException` and returns synchronous exceptions for conversion into
error-shaped responses. Retain that distinction. Its `probeVersion` uses
`readProcessWithExitCode` under a five-second `timeout` when evidence is requested;
that is another subprocess within a batch call and must use the same ownership
scope. Keep identity caching and the evidence opt-out behavior unchanged.

`baikai-agent/src/Baikai/Agent/Run.hs` provides a useful local example:
`terminateGroup` escalates SIGINT, SIGTERM, then SIGKILL and polls the group rather
than only its leader. It is reached on the runner's deadline path; do not assume
it already establishes exception-safe cancellation for these batch providers.
Its captured leader can also disappear if retrieved only after reaping. Use its
signal rationale, not an unexamined copy of its lifecycle.

The older [pipe-handling plan](36-harden-cli-subprocess-argument-and-pipe-handling.md)
fixed concurrent stderr draining but described `cleanupProcess` as synchronously
reaping. The actual solved dependency is `process` 1.6.26.1: `cleanupProcess`
terminates the direct child, closes handles, and forks `waitForProcess`. It does
not terminate descendants or wait for that reaper before returning. The released
1.6.30.0 implementation retains this behavior. Do not treat a dependency update
alone as the fix.

The relevant local decisions are [the threaded-runtime requirement](../adr/0006-a-process-spawning-executable-ships-on-the-threaded-runtime.md),
[explicit UTF-8 at process boundaries](../adr/0007-text-crossing-a-process-boundary-is-encoded-explicitly.md),
and [cancellation ownership for stream producers](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md).
They require a threaded test executable, byte-oriented pipe operations, and cleanup
before an asynchronous exception reaches a caller actively consuming a stream.
The last ADR covers HTTP producer workers, so extend durable context with a batch
process ownership record at completion rather than claiming it already covers
POSIX subprocess groups. The local ADR corpus uses plain Markdown metadata,
verified through `mori show --full`. The completed decision is recorded in
[ADR 0026](../adr/0026-batch-cli-cancellation-owns-process-groups-and-reader-workers.md).

Existing adapter fixtures and assertions live in
`baikai-claude/test/Main.hs`, `baikai-openai/test/Main.hs`, both packages'
`test/CliEvidenceSpec.hs`, and both packages' `test/StructuredCliSpec.hs`. Core tests
are registered in `baikai/test/Main.hs` and `baikai/baikai.cabal`. Provider tests
already use `-threaded`. The bug-report bundle is governed by
`mori/bug-reports-profile.dhall`; its log is `docs/bug-reports/log.md`.

The consumer is `mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai`.
Its project-relative `shikigami-core/test/Shikigami/BehaviorProviderSpec.hs`
functions `withFake` and `cancellationGap` contain the original probe (source
artifact URI pending). The released core 0.7.2.0 and adapter 0.7.1.0 tags all peel
to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`; the two adapter source files still
match those tags at plan creation. Its current negative tests intentionally assert
that a five-second child survives 200 ms after requesting cancellation. Passing
those tests proves the reported gap, not the desired contract or acknowledgement.


## Plan of Work


### Milestone 1: establish a shared owned-process scope


Create `baikai/src/Baikai/Provider/Cli/Process/Internal.hs`, exposed for use by the
adapter packages and documented as internal, like the existing CLI internal
module. Declare it in `baikai/baikai.cabal`. Keep the library's existing `process`
bound and add a non-Windows `unix ^>=2.8` dependency with conditional compilation,
following the established platform pattern in `baikai-agent/baikai-agent.cabal`.
Windows must still compile and retain explicit direct-child-only cleanup; do not
claim equivalent descendant guarantees there.

Implement `withOwnedProcess` with the callback shape specified below. Force a new
process group, mask asynchronous exceptions across acquisition and ownership
registration, and capture the leader PID immediately after spawn, before any
wait can reap it. Run the callback with normal interruptibility. One finalizer
owns the pipes, the retained group identity, and the direct child, on success,
synchronous failure, and asynchronous cancellation. Before unmasking the
callback, attach an unreaped direct-child anchor to the new group. A small POSIX
C helper uses only async-signal-safe operations after fork, closes inherited descriptors, and ignores SIGINT/SIGTERM. The parent
establishes anchor membership with `setpgid` before returning acquisition; no
pipe handshake or interruptible acquisition wait is needed. If the anchor dies
during startup or escalation, its unreaped membership still reserves the group.
Keep that anchor unreaped through the last group observation and signal,
including after SIGKILL; its group membership prevents identifier reuse even when the callback has reaped the CLI leader.
Reap the anchor only after signalling is complete. This adds a private helper
process per scope without changing the callback interface. Do not compose this
with an outer `withCreateProcess` finalizer that can close handles first or fork
a second reaper. Handle partial acquisition failures without leaking a successfully
created child.

Use group-wide SIGINT, then SIGTERM, then SIGKILL. Give the first two stages at
most 100 ms and 500 ms respectively, polling at 10 ms and ending a grace stage
early only when the leader has exited and no running group member remains. Use
elapsed monotonic time for the deadlines. Always reach surviving group members
even if the leader exits at the first signal, and collect the direct child's exit
status before returning. Treat only an already-absent group/process as a benign
signal race; do not silently interpret permission errors as successful cleanup.
On Darwin and Linux, inspect `/bin/ps -axo pid=,pgid=,stat=` using byte
readers, exclude the anchor, and count every non-zombie group member as live.
A process with `Z` status is stopped, not running. Observation or permission
failures are cleanup failures. Use a one-second settling allowance after
SIGKILL, report unexpected live survivors, and do not wait forever for adopted
descendant zombie entries to disappear. Capture all ordinary-path cleanup evidence in tests.

Repeated cancellation must not abandon cleanup. Run the finalizer in an owned,
masked worker and join its completion before leaving the process scope. While the
caller waits for that completion, catch additional asynchronous exceptions and
continue waiting without restarting escalation; retain and rethrow the first
cancellation exception. Finalizer exceptions must always publish completion,
including a cleanup failure, so the join cannot wait on an unwritten cell. If the
callback succeeded but cancellation arrived during cleanup, propagate that
cancellation after cleanup. Do not mask the whole callback or put an arbitrary
blocking pipe read under `uninterruptibleMask`. A kernel process stuck in
uninterruptible operating-system I/O cannot have an unconditional wall-clock
reaping guarantee; the bounded regression contract concerns ordinary and
signal-resistant fixture processes.

Also implement an owned reader-worker scope, `withOwnedWorker`, whose callback
receives a join action. Its acquisition records the thread before unmasking,
publishes either a value or exception on every exit, and its release cancels and
joins an unfinished worker before outer pipe closure. Use it for all forked pipe
readers introduced or retained here. A reader error must not become silent empty
stderr. This worker scope and process scope must cooperate under repeated
cancellation without leaving a worker holding a pipe lock.

Add `baikai/test/CliProcessSpec.hs`, registered in core's Main and Cabal module
list, with shell fixtures proving these behaviors directly. This milestone is
accepted when its focused tests pass without changing adapter behavior yet.


### Milestone 2: route both batch providers and evidence probes through ownership


First add `baikai-claude/test/CliCancellationSpec.hs` and
`baikai-openai/test/CliCancellationSpec.hs`, register them in the respective
`test/Main.hs` and Cabal files, and run the simple descendant case before changing
production code. It must fail because a recorded child survives or cancellation
fails to finish in the bounded interval. Fixtures must clean up their own PIDs in
`finally` even in this expected failing run.

Replace only Claude's batch Cradle invocation in `runClaudeCli` with the shared
owned process scope. Preserve `claudeCliCommand`, working directory, `NoStream`
stdin, raw byte capture, concurrent stdout/stderr drains, decoding, synchronous
error classification, response IDs, timings, schema handling, and evidence
construction. Cradle remains for foreground interactive launches. Add `process`
to `baikai-claude/baikai-claude.cabal` for the process-spec types, using the same
existing `^>=1.6` convention; do not remove Cradle from unrelated modules.

Replace Codex's `withCreateProcess` with the shared scope and its discarded stderr
thread with `withOwnedWorker`. Keep stdout JSONL parsing incremental and preserve
`codexCliCommandWith`, schema lifetime, nonzero exit classification, and evidence.
On cancellation, readers must stop before handles are closed and the schema file
must be removed only after subprocess cleanup completes.

Route `probeVersion` in `baikai/src/Baikai/Provider/Cli/Internal.hs` through the
shared scope with owned concurrent byte readers. Keep its five-second deadline,
`--version` argument, first nonblank-line result, absence on synchronous probe
failure, cache behavior, and no-probe-when-evidence-is-disabled behavior. Timeout
and caller cancellation must stop the probe's descendants before the call exits.
Use explicit UTF-8 decoding rather than new locale-dependent `String` pipe reads.

Exercise public `ApiProvider.complete` and active consumption of
`ApiProvider.stream`, which wraps completion through `liftCompleteToStream`.
Cancellation during the blocking batch portion must clean up before the consuming
worker finishes. Do not equate abandoning an unevaluated stream with actively
cancelling a running call. Acceptance is positive cancellation tests for both
adapters plus unchanged existing structured-output, evidence, argument-vector,
missing-binary, and stderr-flood tests.


### Milestone 3: verify and document the contract


Run the focused tests and full affected suites on Darwin and Linux. Record exact
counts, durations, platform, and dependency solve with concise evidence. Update
`docs/user/cli-providers.md`,
`docs/capabilities/subscription-cli-backends.md`, `baikai/CHANGELOG.md`,
`baikai-claude/CHANGELOG.md`, and `baikai-openai/CHANGELOG.md` with the behavior and
its process-group/platform limits. Add regression evidence to CAP-15 without
claiming escaped-session containment or adding new deadline/output-limit APIs.

Update BUG-1 with the implementation and validation evidence and a local link to
this plan, maintaining `docs/bug-reports/log.md`. Use `in-progress` until a fixed
release version exists; do not invent `fixedVersion` or mark the released defect
fixed merely because working-tree tests pass. Distill the shared ownership,
repeated cancellation, and direct-child-versus-descendant reaping rules into an
ADR using the repository's then-current convention. This milestone is accepted
when the suites pass and the documentation describes exactly their demonstrated
contract. Publish through the release workflow only under a separate release
request. The consumer must rerun positive probes against those released versions
before lifting its `BatchCancellationReleaseRequired` guard; this plan leaves
that gate intact.


## Concrete Steps


Linux qualification uses a local Debian container with
GHC 9.12.4 (`docker.io/library/haskell:9.12.4`, x86_64 through Rosetta on this
Darwin host). Its minimal image requires `procps` to provide `/bin/ps`; install
that before running fixtures. Run each full suite from its package directory: the
container's Cabal 3.14.1.1 retains the caller's directory, and core's relative
fixture/source paths otherwise fail. Darwin Cabal 3.16.1.0 runs these suites from
the package directory automatically. Use a private writable copy of the repository,
excluding host `dist-newstyle`, `.git`, and `.direnv`, and retain the source and
Cabal files exactly as tested on Darwin. The installed `process` and `unix`
versions are 1.6.26.1 and 2.8.8.0 on both platforms. A Windows CPP branch type-check
on Darwin passed, but this is not Windows runtime qualification.

Run implementation commands from the baikai repository root. If the toolchain is
not already on PATH, prefix each Cabal command with `nix develop --command`. The
expected compiler is GHC 9.12.4 and executables must use the threaded runtime.

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-test --test-show-details=direct -j1 --test-options='--pattern CliProcessSpec --num-threads=1'
```

After adding adapter tests, record the failing simple descendant test before
routing through the shared scope. After integration, run the same command and
require both suites to report a nonzero selected test count and PASS:

```bash
cabal test baikai-claude-test baikai-openai-test \
  --test-show-details=direct -j1 --test-options='--pattern CliCancellationSpec --num-threads=1'
```

Then verify response compatibility and affected dependents:

```bash
cabal build baikai baikai-claude baikai-openai baikai-agent --enable-tests -j1
cabal test baikai-test baikai-claude-test baikai-openai-test baikai-agent-test \
  --test-show-details=direct -j1 --test-options='--num-threads=1'
okf validate docs/bug-reports --strict \
  --profile mori/bug-reports-profile.dhall --profile-enforce --log-enforce
okf validate docs/capabilities \
  --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Expected tails include `All N tests passed` with N greater than zero, each named
suite's `PASS`, and successful OKF validation. Capability validation intentionally
omits `--strict`: at plan creation its strict baseline fails on 24 existing
records missing recommended `reviews` metadata. This plan does not backfill
unrelated provenance; add accurate review metadata to CAP-15 when changing it,
and require the ordinary enforced-profile command above to pass. The bug-report
bundle's strict validation already passes. Core tests must include the version
probe cancellation/timeout cases; focused adapter tests must select both newly
registered modules. Do not accept a zero-test run.

For the Linux full suites, run these commands inside the private `/work` copy:

```bash
for package in baikai baikai-claude baikai-openai baikai-agent; do
  (cd "/work/$package" && cabal test "$package-test" \
    --test-show-details=direct -j1 --test-options='--num-threads=1') || exit 1
done
```

The original released-package negative reproduction can be rerun from its
Mori-resolved consumer project. It is validation of the report only and is
expected to continue passing while it selects the old releases:

```bash
cd "$(mori path mori://shinzui/shikigami)"
qualification_project=$(python3 tools/qualification/prepare-project.py)
cabal test shikigami-core-test --project-file="$qualification_project" \
  --test-show-details=direct --test-options='--pattern gap'
```

Do not edit that consumer as part of this implementation. Record one plan
provenance revision per implementing session with
`agents/skills/exec-plan/record-provenance.ts`, using the current agent's verified
runtime identity. Commits use Conventional Commits and the trailer:

```text
ExecPlan: docs/plans/90-terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation.md
```


## Validation and Acceptance


Each fixture uses a unique temporary directory and records its own parent/child
PIDs before the test requests cancellation. Use a 30-second sleeping child, not
one that could expire naturally during the test. Wait up to two seconds for a
readiness record; launch `killThread` from another worker because it can block;
await the provider worker's terminal result for at most three seconds. That result
must be an asynchronous exception, never a `Response` or synchronous provider
error. Only after receiving it, inspect the recorded PIDs immediately: the direct
child must be gone and no descendant may be running. Poll eventual removal of a
non-running adopted zombie separately with a short bound and report that state;
`kill -0` alone does not distinguish a live process from a zombie. Also retain the
original 200-ms observation as diagnostic evidence, not as the cleanup contract.

The core suite must cover a normal sleeping descendant, a leader that exits while
its descendant still holds a pipe open, a group that ignores SIGINT and SIGTERM
and requires SIGKILL, repeated cancellation during grace stages, normal process
exit, synchronous callback failure, and failed spawn. Have a callback explicitly
reap the leader before cancellation in one case to prove that retained group
identity still reaches the descendant. The worker-scope test uses a blocked reader
and a completion marker to prove no local reader survives its scope. A separate
sentinel process in a different group must remain alive throughout the tested
cancellation, then be cleaned up by the test itself.

Both adapter suites must prove the simple descendant, resistant descendant,
repeated cancellation, and active synthetic-stream cases. A Codex schema fixture
records the `--output-schema` path and proves its removal after cancellation.
Run the adapters with evidence enabled and a fake executable whose normal
invocation succeeds but whose `--version` branch starts a descendant and hangs;
cancellation during that branch must have the same outcome. A core test of
`executableIdentity` with a fresh executable path also proves version-probe
timeout cleanup without returning a version, avoiding any need to expose the
private `probeVersion` function or reuse a cached result.

Preserve existing successful text/usage/response-ID and schema results, missing
executable and nonzero-exit error categories, Claude malformed-JSON decode errors,
and concurrent stderr-flood completion. Codex's parser currently ignores malformed
JSONL lines; do not introduce a new decode-failure contract there as a side effect.
On platforms without POSIX groups, test direct-child cleanup separately and state
that group tests and descendant guarantees apply to Darwin/Linux. Fixtures never
signal processes by executable name, scan sessions, or use a global `pkill`.


## Idempotence and Recovery


All fixtures allocate fresh temporary directories and own their recorded processes.
Their emergency `finally` cleanup must work even against the old buggy adapters:
signal only fixture-owned PIDs or a verified fixture-owned group, escalate as
needed, and bound waits so a deliberately failing test does not strand the suite.
If readiness never arrives, cancel the provider worker and join it before deleting
its directory. Capture ownership data before teardown; never signal a reused PID
from a stale fixture file. Reruns must not depend on fixed temporary filenames.

Implementation is ordinary source and documentation editing. Keep milestone
commits separately reviewable; revert a completed milestone's commit if recovery
is needed rather than resetting unrelated work. No credentials, releases, or
consumer gates are changed by these steps. If repeated-cancellation tests fail,
keep the milestone unfinished and repair ownership before documenting success.


## Interfaces and Dependencies


The shared internal module must provide these interfaces, or update this plan
before implementation if a materially different ownership boundary is required:

```haskell
withOwnedProcess ::
  System.Process.CreateProcess ->
  (Maybe System.IO.Handle -> Maybe System.IO.Handle -> Maybe System.IO.Handle ->
   System.Process.ProcessHandle -> IO a) ->
  IO a

withOwnedWorker :: IO a -> (IO a -> IO b) -> IO b
```

`withOwnedProcess` owns spawned process groups and pipe handles; callbacks own
reader workers through `withOwnedWorker`. The latter's supplied `IO a` waits for
and returns the worker result or rethrows its exception. Both scopes finish their
cleanup before returning or rethrowing. The public provider configs, command
renderers, `ApiProvider` shape, and error response types remain unchanged.

Mori lookup located Cradle at `mori://garnix-io/cradle/packages/cradle` and its guide
at `mori://garnix-io/cradle/docs/when-to-use-cradle`. Its project-relative
`cradle/src/Cradle/ProcessConfiguration.hs` uses direct-child `cleanupProcess`
(source artifact URI pending). The solved version and Hackage's latest release
are both 0.0.0.0; the upstream repository exposes no release tags. No Cradle
compatibility workaround or version change is proposed.

Mori's current registry has no `process` or `unix` project entry. The intended
project references are `mori://haskell/process` and `mori://haskell/unix`; source
artifact URIs are pending. Research used upstream release-tagged
`System/Process.hs` and `System/Posix/Signals.hsc`, respectively, after Mori lookup.
Hackage and upstream tag checks on 2026-10-06 show latest releases of process
1.6.30.0 and unix 2.8.8.0; the current local solve uses process 1.6.26.1 and unix
2.8.8.0. The existing `process ^>=1.6` bound admits both process versions; retain
it, and test the new scope against the solved version. Use the established
`unix ^>=2.8` bound for POSIX signals. Before changing bounds later, repeat the
Mori, authoritative registry, and upstream tag checks. Do not search `/nix/store`
for dependency sources.

Revision note (2026-10-06): resolved the first review's ownership and observation
findings with an unreaped C anchor, portable process-state checks, and explicit
anchor-reaping tests. Qualification uses serial suite/test scheduling to keep
fixture readiness independent of parallel compiler contention. All three package
CHANGELOG paths are symlinks to the root CHANGELOG, so the shared unreleased entry
updates them together. Core, both adapters, and the agent test suite ship
identical copies of the fixture module so their source distributions contain every test dependency.
