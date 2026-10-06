---
type: Bug Report
bugId: BUG-1
title: "Cancelling a batch CLI provider leaves its child process alive"
description: "Both released batch CLI adapters leave an owned fake executable's five-second child alive after cancellation is requested."
status: in-progress
severity: degraded
origin: mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai
affects: mori://shinzui/baikai
capability: mori://shinzui/baikai/okf/capabilities/concepts/CAP-15
affectedVersion: "0.7.1.0"
environment: "aarch64-darwin, GHC 9.12.4, baikai 0.7.2.0, baikai-claude and baikai-openai 0.7.1.0; fake /bin/sh executable, no vendor login or API keys"
observed: "For both public adapters, kill -0 succeeds for the recorded child PID 200 ms after killThread is requested on the provider worker."
expected: "Before acknowledging cancellation, stop the owned process group, reap the direct child, join pipe readers, and preserve asynchronous cancellation; descendant exit statuses belong to their parent or the operating system."
workaround: "Shikigami refuses both background CLI selections and uses HTTP responses or the separately governed foreground launch surfaces; the reproduction explicitly cleans up only its recorded fixture PIDs."
reproduction:
  - "Use the exact released adapters and core versions listed in Environment and the Shikigami reproduction at code revision 9ce65b23daed965e62db61d0145cfd5006bcfd81."
  - "Configure each public claudeCliProvider/codexCliProvider with the fake shell executable and its private temporary working directory."
  - "Have that executable start sleep 5 in the background, record the child and parent PIDs, and wait."
  - "Fork provider.complete with empty context/options, wait up to two seconds for the child PID file, and request killThread on the worker."
  - "After 200 ms, run /bin/kill -0 on the recorded child PID; both adapters return ExitSuccess."
  - "In finally, terminate only recorded child/parent fixture PIDs and wait at most six seconds for worker completion."
timestamp: "2026-10-06T17:38:18Z"
generated:
  by: codex-cli/gpt-6.1-sol
  at: "2026-10-06T16:37:08Z"
reviews:
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-06T16:37:08Z"
    document_timestamp: "2026-10-06T16:37:08Z"
    context: "Author self-check against the released public adapter source, CAP-15, the bug-report profile, and two rerun consumer probes; not an independent confirmation."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-06T16:56:01Z"
    document_timestamp: "2026-10-06T16:56:01Z"
    context: "Owning-repository session reproduced both in-place adapters, verified matching release source, reran both published-package consumer gap tests, corrected the test filter, and validated the strict bug-report profile. This is execution evidence, not an independent model review."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-06T17:12:17Z"
    document_timestamp: "2026-10-06T17:12:17Z"
    context: "Reflect ExecPlan 90's first self-review: require ownership protected against process-group identifier reuse and explicit Darwin/Linux live-versus-zombie completion checks before implementing the proposed fix. The reproduced defect remains confirmed; the plan remains changes-requested."
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-06T17:38:18Z"
    document_timestamp: "2026-10-06T17:38:18Z"
    context: "Implement shared ownership anchored against group-ID reuse and positive cancellation regressions. This is an implementation self-check; publication and consumer release qualification remain separate work."
---

# Cancelling a batch CLI provider leaves its child process alive

## Scope and impact

The existing batch subprocess calls provided by [CAP-15](../capabilities/subscription-cli-backends.md)
continue to leave a descendant running after their caller requests asynchronous
cancellation. This is a lifecycle defect in the already shipped response surface.
Normal uncancelled decoding works. A consumer supervising durable workflows cannot
promote these adapters while cancelled model work can outlive its caller.

This report covers one common symptom and one parameterized reproduction for both
`baikai-claude` and `baikai-openai` 0.7.1.0. Core is `baikai` 0.7.2.0. These three
release tags peel to `7dd44f96e5bba1a0dfa6a693a6c4858d81ab9831`.
There is no established last-working version or fix yet. On 2026-10-06 the
owning repository reproduced the gap against its in-place packages, and reran
the consumer tests against the published packages. Status is therefore `confirmed`.

The observation is deliberately narrow: the child is alive 200 ms after a
cancellation request. The probe does not prove that cancellation was already
acknowledged, that the child lives forever, or that a real authenticated vendor
session behaves identically. It proves that the selected public adapter lifecycle
does not stop this owned descendant within the tested cancellation window.

## Reproduction and evidence

Consumer: `mori://shinzui/shikigami`, project-relative source
`shikigami-core/test/Shikigami/BehaviorProviderSpec.hs`, functions
`cancellationGap` and `withFake`. Artifact-level source URI is pending. The code
revision is `9ce65b23daed965e62db61d0145cfd5006bcfd81`; subsequent consumer
commits only record qualification. Its test names are:

- `released Codex cancellation gap keeps background CLI disabled`
- `released Claude cancellation gap keeps background CLI disabled`

Run from that Mori-resolved project, using its isolated committed dependency solve:

```bash
cd "$(mori path mori://shinzui/shikigami)"
qualification_project=$(python3 tools/qualification/prepare-project.py)
nix develop --command cabal test shikigami-core-test \
  --project-file="$qualification_project" \
  --test-show-details=direct --test-options='--pattern gap'
```

Both tests intentionally assert the surviving-child defect, so PASS is evidence of
the gap, not a successful cancellation contract. They call public provider values
directly, before Shikigami's promotion gate. The executable's essential body is:

```sh
sleep 5 &
echo $! > child
echo $$ > parent
wait
```

The fixture supplies a private directory and executable, waits for its own child
PID file, cancels the Haskell worker, then probes that exact PID with `kill -0`.
Cleanup is in `finally` and only signals the two recorded fixture PIDs. It does
not inspect login files, call a remote model, or stop other vendor sessions.

Consumer probes were rerun on 2026-10-06 at 16:37 UTC using the previously built
qualified test binary. Output:

```text
released Codex cancellation gap keeps background CLI disabled:  OK (0.42s)
released Claude cancellation gap keeps background CLI disabled: OK (0.56s)
All 2 tests passed (0.56s)
```

## Source observations

- `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` uses `withCreateProcess`
  without an explicit process-group creation/termination strategy.
- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` delegates execution to Cradle.
- The shared `trySync` rethrows asynchronous exceptions; propagating cancellation
  alone does not establish cleanup of a spawned executable's descendants.

These observations explain why process ownership needs investigation. They are
not a claim that an upstream Cradle defect has been established.

## Fix acceptance

A released fix should add positive adapter-level cancellation tests for both
providers, using a fake executable that starts a descendant. Before cancellation
is acknowledged, owned process-group members should be stopped, the direct child
reaped, and pipe-reader workers joined. Tests should also check repeated
cancellation and synchronous spawn/nonzero/decode failures.
Preserve asynchronous exceptions rather than turning cancellation into a normal
error-shaped response. Cleanup must never signal unrelated sessions.

Shikigami must then rerun positive no-survivor probes against the released fix
before removing its `BatchCancellationReleaseRequired` guard. The consumer's
remaining deadline, output-bound and native-tool confinement qualifications are
separate prerequisites; this report does not claim those features were previously
promised by the batch adapters or that fixing cancellation completes them.

## Owning-repository validation and fix plan

On 2026-10-06, baikai validated the report's release tags and CAP-15 references,
read both adapter implementations and Cradle's process configuration, and reran
the released-package consumer tests. The consumer checkout was
`mori://shinzui/shikigami` at `9b5803d6d869e799d0674465254cbf076ae57236`;
its isolated solve selected Hackage core 0.7.2.0 and both adapters 0.7.1.0.
The two gap tests passed (Codex 0.63s, Claude 0.48s; suite 0.63s), again
demonstrating the defect. The test filter above
selects the word `gap` without whitespace because Cabal splits the original
`-p /cancellation gap/` into separate arguments and the test executable rejects it.

Baikai also ran [a standalone offline probe](../../scripts/reproduce-batch-cli-cancellation.hs)
from this repository with GHC 9.12.4 and `-threaded`. The compiled interface
confirmed direct dependencies on the in-place core 0.7.2.0 and adapter 0.7.1.0
packages. Both adapter source files match their released tags. Run from the
baikai repository root:

```bash
reproduction_dir=$(mktemp -d)
cabal exec -- ghc -threaded \
  -package baikai -package baikai-claude -package baikai-openai \
  -odir "$reproduction_dir" -hidir "$reproduction_dir" \
  scripts/reproduce-batch-cli-cancellation.hs \
  -o "$reproduction_dir/reproduce-batch-cli-cancellation"
"$reproduction_dir/reproduce-batch-cli-cancellation"
```

Observed output:

```text
AnthropicMessagesCli child_alive_200ms=True worker_pending=True
AnthropicMessagesCli worker_after_fixture_cleanup=Just "async"
OpenAICompletionsCli child_alive_200ms=True worker_pending=True
OpenAICompletionsCli worker_after_fixture_cleanup=Just "async"
```

At the 200-ms observation point the provider workers were still pending.
After the fixture explicitly terminated its recorded child and parent, both
workers finished with asynchronous exceptions. This confirms the cancellation
request gap; it does not prove a descendant survives an acknowledged cancellation.
The script exits successfully when it reproduces that gap.

Dependency inspection also found that `process` 1.6.26.1's `cleanupProcess` forks
`waitForProcess` after terminating the direct child and closing pipes. It does
not synchronously reap before returning or terminate the whole group. The latest
released 1.6.30.0 retains that behavior. The fix must explicitly own group
termination and join reader workers before closing their handles. A group member
that is a zombie has stopped running but may still satisfy `kill -0`; Baikai can
reap its direct child, while orphaned descendants are reaped by their adoptive
parent or the operating system. Positive tests must distinguish these states.

[ExecPlan 90](../plans/90-terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation.md)
defines the shared ownership scope, adapter integration, and positive regression
acceptance. No implementation or fixed release is claimed by this validation.

## Historical proposed-fix self-review: changes required before implementation

ExecPlan 90's first recorded review on 2026-10-06 has verdict
`changes-requested`. It was a self-review by the same `gpt-6.1-sol` model that
authored the plan, not an independent review. The shared process scope,
group-wide signal escalation, joined reader workers, and preserved cancellation
are the proposed foundation. Two design gaps must be resolved before that plan
is ready for implementation.

The process-group ownership mechanism must remain valid until the final group
signal. Capturing a numeric group identifier at spawn does not by itself establish
continued ownership after the leader is reaped and the last group member exits;
the operating system can subsequently reuse that identifier. The plan currently
allows early leader reaping and retained-identifier signalling. That creates a
potential risk of signalling an unrelated group, particularly if evidence
collection delays finalization after a normal exit. Choose and verify an ownership
anchor that prevents reuse throughout signalling, revise the callback's reaping
permissions accordingly, and replace any acceptance case that assumes a saved
number alone is sufficient ownership. An unrelated sentinel surviving an ordinary
cancellation test does not prove this identifier-reuse case safe.

The implementation must also define concrete Darwin and Linux checks for live
group members and cleanup completion. A null signal such as `kill -0` checks
existence and permission, and may still succeed for a zombie; it cannot implement
a live-versus-zombie distinction by itself. Specify the platform mechanisms,
bounded settling interval, and behavior when a survivor or observation failure
remains. Positive tests must prove that no descendant is still running when
cancellation finishes, while distinguishing stopped descendants awaiting reaping
by an adoptive parent. Test fixtures must not interpret a successful null signal
as proof of continued execution or wait indefinitely for an adopted zombie.

These are findings about the proposed fix, not new observations established by
the existing five-second reproduction. BUG-1 remains `confirmed`; there is no
implementation or fixed release yet. The reviewed plan remains
`changes-requested` until those ownership and completion mechanisms are specified
and verified.

## Working-tree implementation; fixed release still pending

[Plan 90](../plans/90-terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation.md)
now implements a shared owned-process scope for both batch adapters and the
executable-version evidence probe. Before callbacks can reap the leader, the
parent attaches an unreaped anchor to the invocation's new process group. That
membership reserves the group identifier until the last group signal and state
check, even when the anchor itself becomes a zombie. Darwin/Linux `ps` state
checks distinguish stopped zombies from live survivors, with a one-second
settling allowance after SIGKILL. The scope joins owned readers before closing
pipes and synchronously reaps both direct children. Repeated cancellation cannot
abandon cleanup, and the first asynchronous exception remains asynchronous.

The new `CliCancellationSpec` simple-descendant tests failed on both original
adapters before integration: descendants were sleeping at 200 ms and workers
could not acknowledge cancellation in three seconds. They now require an
asynchronous worker result followed immediately by proof that the direct child
is gone and its 30-second descendant is stopped. Tests also cover signal-resistant
children, repeated cancellation, active stream consumption, and evidence-probe
cancellation. Core tests cover early leader reaping, ownership-anchor reaping,
normal and failing callbacks, reader cleanup, unrelated-group isolation, and
probe timeout. Codex tests retain the schema through termination and verify its
removal after cancellation.

Validation counts and platform evidence are maintained in plan 90. The design
findings in the earlier changes-requested self-review are addressed by this
implementation and its regressions; the historical review remains recorded.
BUG-1 stays `in-progress`, without a `fixedVersion`, until a fixed release is
published. The consumer's `BatchCancellationReleaseRequired` guard remains in
place and requires positive probes against that release before removal.
