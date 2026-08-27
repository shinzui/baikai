---
title: "Unattended coding-agent runs"
type: Capability
description: "Run Claude Code or Codex with no terminal and no human from Haskell: a provider-neutral capability profile, a pure operator ceiling that refuses an over-broad request instead of quietly weakening it, and a runner that delivers the prompt on stdin, bounds captured output, and on timeout interrupts, terminates, then kills the whole process group while keeping what it drained."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-17
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - baikai-agent
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.Agent
  - Baikai.Agent.Run
  - Baikai.Provider.Claude.Agent
  - Baikai.Provider.OpenAI.Agent
evidence:
  - kind: test
    resource: baikai/test/AgentSpec.hs
    proves: "The pure policy algebra: the default ceiling accepts read-only and edit-workspace unchanged, refuses each closed channel with the exact violation, reports all three violations for a request that breaks three rules, treats an empty allowedProviders list as permitting no provider, and never clamps — violation text names both the requested and the permitted value."
  - kind: test
    resource: baikai-agent/test/Main.hs
    proves: "The runner against real subprocesses: the prompt is delivered on stdin, stdout and stderr stay separate, a non-zero exit is a successful run carrying that code, a missing working directory and unset declared variables are caught before any spawn, output truncates at the byte limit, inherit mode captures nothing, a timeout terminates the process group including grandchildren, a child that ignores INT and TERM is killed within the grace periods, a timed-out run reports the bytes it drained before the kill, and a pipe held open from outside the group is interrupted rather than waited on."
  - kind: test
    resource: baikai-agent/test/BinaryTests.hs
    proves: "The built executable rather than the test binary: it reports the threaded runtime, and `baikai agent run` against a stub agent that ignores INT and TERM exits 75 within the grace periods, leaves no process of the group alive, reports the output drained before the kill, and writes its result as UTF-8 under LANG=C."
  - kind: test
    resource: baikai-claude/test/Main.hs
    proves: "claudeAgentCommand's rendering: capability profile onto --permission-mode, one joined --allowedTools, repeated --add-dir, always -p, and a prompt that appears nowhere in the argument vector even when it starts with a dash."
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "codexAgentCommand's rendering, and that a request carrying a tool allow-list is refused with UnsupportedToolRestriction rather than run with unrestricted tools."
  - kind: guide
    resource: docs/user/unattended-agent-runs.md
    proves: "The whole unattended surface, including the capability mapping tables for both tools and how an unattended run differs from an interactive launch."
---

# Unattended coding-agent runs

An unattended run has no terminal and no human. The agent owns its own tool loop,
may change files inside directories the caller authorized, and returns a process
result rather than a `Response`. `Baikai.Agent` is the vocabulary:
`AgentRunRequest` with a required `workingDir`, the `AgentCapability` profile
(`read-only`, `edit-workspace`, `full-access`), `AgentSafety`, the output
discipline, and the render/run boundary.

Two properties carry the design. First, **the operator ceiling never clamps.**
`applyAgentCeiling` returns a request unchanged when it is within the ceiling and
reports *every* violation when it is not; it does not quietly downgrade
`full-access` to `edit-workspace`. Second, **a policy a provider cannot express
is refused before process creation** — Codex has no tool allow-list flag, so a
request carrying one is rejected rather than run with unrestricted tools.

The runner is deliberately blind to vendors. `runAgentCommand` consumes an
already-rendered `AgentCommand` and imports no vendor renderer, which is why it
can be exercised entirely with hand-written argument vectors. It delivers the
prompt on standard input and closes the handle, drains both streams concurrently
so a chatty agent cannot deadlock on a full pipe, retains at most `outputLimit`
bytes per stream, and on timeout interrupts the child's whole process group,
then terminates it, then kills it — each stage bounded by a grace period and
ended early once the leader is reaped and no group member is left, so the
agent's own children go with it and a grandchild gets the same grace the agent
does. `SIGKILL` is the last stage because it is the only signal a process
cannot ignore, and a coding agent that ignores the polite ones is exactly the
run a deadline exists for. What each stream drained before the kill travels
back in `RunTimedOut`'s `AgentTimedOut` record rather than being discarded.

`AgentRunOutcome` pairs the `Either AgentRunFailure AgentRunResult` with the
evidence built for the run. The evidence is a sibling of the outcome rather than
a field on the result, because the run that most needs a record is the one that
produced no result: a timeout reports `Left (RunTimedOut …)`, and a record
hanging off the `Right` would be unreachable exactly there. See
[CAP-19 — verifiable model-call evidence](model-call-evidence.md).

## Shape

```haskell
(cmd, thinking) <- either throwIO pure (claudeAgentCommand config request)
outcome <- runAgentCommand Nothing thinking request cmd
case outcome ^. #outcome of
  Right result -> exitWith (result ^. #exitCode)
  Left failure -> reportFailure failure
```

## Limits

- **A non-zero exit code is a successful run**, not a failure. `Left` is reserved
  for baikai's own failures — spawn, timeout, precondition, malformed output. A
  caller that treats `Left` and a non-zero exit as the same thing is wrong about
  both.
- The safety ceiling only constrains what baikai renders. Once the agent is
  running it is bounded by the tool's own enforcement, not by baikai.
- Capability profiles are not portable in substance. `read-only` maps to Claude's
  `plan` and Codex's `--sandbox read-only`; those are similar intentions with
  different enforcement, and baikai cannot equalise them.
- `runAgentCommand`'s signature gained two leading arguments in the 0.5.0.0 wave.
  A caller wanting the previous behaviour passes `Nothing` and
  `noThinkingRequested` and reads the `outcome` field; that path is byte-for-byte
  and cost-for-cost what it was.
- POSIX signal escalation on timeout is conditional on a non-Windows build.
  Without POSIX signals only the leader can be reached, so a survivor that
  ignored the interrupt is missed, as it always was on such a platform.
- `baikai-agent` is at 0.1.0.0. Its surface has not been through a compatibility
  cycle yet, which is why this capability is marked `experimental` while the core
  library's are not.
