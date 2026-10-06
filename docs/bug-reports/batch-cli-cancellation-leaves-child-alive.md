---
type: Bug Report
bugId: BUG-1
title: "Cancelling a batch CLI provider leaves its child process alive"
description: "Both released batch CLI adapters leave an owned fake executable's five-second child alive after cancellation is requested."
status: reported
severity: degraded
origin: mori://shinzui/shikigami/plans/80-configure-model-providers-and-agent-launches-through-baikai
affects: mori://shinzui/baikai
capability: mori://shinzui/baikai/okf/capabilities/concepts/CAP-15
affectedVersion: "0.7.1.0"
environment: "aarch64-darwin, GHC 9.12.4, baikai 0.7.2.0, baikai-claude and baikai-openai 0.7.1.0; fake /bin/sh executable, no vendor login or API keys"
observed: "For both public adapters, kill -0 succeeds for the recorded child PID 200 ms after killThread is requested on the provider worker."
expected: "Cancelling the existing batch subprocess call should terminate and reap its owned process group and preserve asynchronous cancellation, rather than leave work running outside the cancelled call."
workaround: "Shikigami refuses both background CLI selections and uses HTTP responses or the separately governed foreground launch surfaces; the reproduction explicitly cleans up only its recorded fixture PIDs."
reproduction:
  - "Use the exact released adapters and core versions listed in Environment and the Shikigami reproduction at code revision 9ce65b23daed965e62db61d0145cfd5006bcfd81."
  - "Configure each public claudeCliProvider/codexCliProvider with the fake shell executable and its private temporary working directory."
  - "Have that executable start sleep 5 in the background, record the child and parent PIDs, and wait."
  - "Fork provider.complete with empty context/options, wait up to two seconds for the child PID file, and request killThread on the worker."
  - "After 200 ms, run /bin/kill -0 on the recorded child PID; both adapters return ExitSuccess."
  - "In finally, terminate only recorded child/parent fixture PIDs and wait at most six seconds for worker completion."
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
There is no established last-working version and no owning-repository confirmation
or fix yet. Status is therefore `reported`.

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
  --test-show-details=direct --test-options='-p /cancellation gap/'
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
is acknowledged, all owned processes should be stopped and reaped; tests should
also check repeated cancellation and synchronous spawn/nonzero/decode failures.
Preserve asynchronous exceptions rather than turning cancellation into a normal
error-shaped response. Cleanup must never signal unrelated sessions.

Shikigami must then rerun positive no-survivor probes against the released fix
before removing its `BatchCancellationReleaseRequired` guard. The consumer's
remaining deadline, output-bound and native-tool confinement qualifications are
separate prerequisites; this report does not claim those features were previously
promised by the batch adapters or that fixing cancellation completes them.
