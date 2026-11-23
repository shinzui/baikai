---
type: Improvement Request
title: Carry caller-supplied tool policy and refusal evidence on unattended runs
description: >-
  Let a caller hand an unattended Claude Code or Codex run its own policy files (a Claude
  settings file, Codex hooks and rules) through a typed field, and report the tool calls the
  provider refused, so consumers stop rendering vendor policy flags and parsing vendor
  refusal output themselves.
timestamp: 2026-11-23T14:30:00Z
requestId: IR-14
status: in-progress
origin: mori://shinzui/seihou
---

# Improvement Request: Carry Caller-Supplied Tool Policy and Refusal Evidence on Unattended Runs

## Status

The Baikai source tree has a native standalone review command, a policy-bearing
unattended command and a scoped batch completion API for reviewed Codex hooks.
The local Codex 0.171.0 fixture exercises first-use confirmation, a repeated
denial, changed-policy rejection and a command exiting 7. Claude adoption and
publication of the provider API remain open.
[Consumer plan](mori://shinzui/seihou/plans/127-let-callers-supply-tool-policy-for-batch-blueprint-runs-and-migrations)

## Context

An orchestrator that already approves commands wants to give an unattended run its own gate.
`mori://shinzui/shikigami` approves each command through a Claude `PreToolUse` hook and writes
a settings file for every attempt. Seihou's batch blueprint runs need to pass that file through,
and need to know afterwards whether the provider refused anything.

Baikai has two surfaces that launch an unattended coding agent, and neither covers this.

The batch completion providers, `Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli`,
take policy only as raw `extraArgs`. Their responses carry the assistant text and drop what the
provider said about refusals. Claude Code lists refused tool calls in the `permission_denials`
array of its JSON result. Baikai reads `result` and `is_error` and discards that array. Seihou
therefore registers its own adapter in place of the stock provider, runs `claude` and `codex`
itself, and parses their output. `registerValidatedCli` in Seihou's
`seihou-cli/src/Seihou/CLI/AgentCompletion.hs` is that adapter. It costs the run its usage
figures and the subprocess evidence Baikai would have recorded.

The unattended-run surface, `Baikai.Agent` with the renderers `Baikai.Provider.Claude.Agent`
and `Baikai.Provider.OpenAI.Agent`, has a typed safety request. `AgentSafety` carries a
capability, `allowedTools` and raw `providerArgs`. It has no field for a policy file. The Codex
renderer refuses any `allowedTools` with `UnsupportedToolRestriction`, because `codex exec` has
no allow-list flag. A caller who wants a gate on Codex has only `providerArgs`, which an
operator ceiling permits or forbids as a whole.

The two vendors differ, and a single neutral field would misstate what the caller gets:

- **Claude Code** takes `--settings FILE`. The file can hold permission rules and hooks, and
  rules in it are anchored at the file's own directory. A `PreToolUse` hook can allow or deny
  a tool call.
- **Codex CLI** (0.171.0) takes an execpolicy rules file and a hooks file, and documents only
  fixed locations for them: the user's `$CODEX_HOME` and a trusted project's `.codex/`
  directory. A rule's `allow` decision runs the command outside the sandbox. A `PreToolUse`
  hook can block a command and cannot approve one. Codex skips a hook nobody has reviewed
  unless the run passes `--dangerously-bypass-hook-trust`.

## Native provider observations (2026-11-21)

Claude Code 2.1.330 ran a local marker command when a supplied settings
file's PreToolUse hook allowed it. When the hook denied the same command despite
a matching static grant, the marker stayed unchanged. The final result event
reported success and included the command in `permission_denials`. Passing
each static rule as a separate argument also admitted an exact Bash pattern
containing a comma.

Codex CLI 0.171.0 loaded a per-run hook from a configuration override in an
isolated, ephemeral workspace-write session. The hook denied the marker
command. Codex exited 0 and emitted no command or refusal event for it in
JSONL. The denial appeared in stderr. With the same trust switch, a control
command that actually exited 1 emitted a failed command item. Both streams
contained the same trust warnings as error items. The trust switch applies to
every enabled hook in the invocation. The rules checker evaluated a caller file,
but the exec subcommand rejected its rules-file flag.

These observations come from
`mori://shinzui/seihou/plans/127-let-callers-supply-tool-policy-for-batch-blueprint-runs-and-migrations`
and `mori://shinzui/seihou/okf/friction-log/concepts/FRIC-21`.

## Codex app-server integration

From this checkout on POSIX, run the following with Python 3 and Codex on PATH. The probe
uses the installed app-server, a loopback Responses fixture, two temporary configurations
and a disposable workspace. It needs no account or live model. The positive fixture contains
a pre-existing review of a fixed, literal deny handler. It exercises enforcement after review.
Operator enrollment through the normal Baikai interface remains an open deliverable.

```bash
python3 scripts/probe-codex-hook-policy.py
```

On 0.171.0 the v2 protocol worked without experimental options. A thread-specific
`thread/start.config.hooks.PreToolUse` populated the `sessionFlags` layer. Before
`turn/start`, `hooks/list` for that thread distinguished an unreviewed handler, the exact
reviewed handler, and a modified handler at the same key. The probe withheld the model
request in both cases needing review. The reviewed user hook still ran and the unrelated
unreviewed user hook stayed untrusted. A second thread in the same process had no caller
hook. The test compared the fixture configuration before and after each process.

A synchronous deny produced `hook/completed` with `eventName=preToolUse` and
`status=blocked`. The marker stayed absent even though the turn completed successfully.
The control wrote the marker and exited 7. The control's command item reported failure
and only the operator's ordinary hook completion appeared. In `Baikai.Provider.OpenAI.HookEvidence`, use `requireReviewedPreToolUseHook` on the
active thread's inventory for each expected key and reviewed hash. Use
`parsePreToolUseCompletion` to decode individual
notifications with Aeson's `parseEither`. Its result carries the thread, turn, opaque
hook run ID and provider outcome. A missing event alone cannot attest to enforcement.

The stable completion carries no command, arguments or separate tool-call ID. In a
separate probe, opting into experimental raw items exposed the model's function call,
its arguments and its call ID. The release source appends that ID to the hook run ID.
That spelling is an implementation detail. Keep a denial actionable even when its call
cannot be attributed and never persist the raw model transcript as policy evidence.

Codex's normal review binds the handler key to a hash of its normalized configuration.
The hash identifies the command declaration and does not fingerprint an external script
it invokes. Provide a first-use review workflow that presents the exact native handler
and preserves the operator's authority. Reject unreviewed, modified, disabled, asynchronous
or missing required gates before the turn. Constrain accepted caller input to supported
hook declarations. Treat a failed hook, lost stream or malformed evidence as incomplete
coverage. Keep provider trust state out of ordinary runs. Prove concurrent threads,
cancellation and retry through both Baikai entry points before promoting a Seihou flag.

The released execpolicy loader discovers rules under enabled configuration layers that
have a directory. Session flags have none. Defer a caller-owned rules file until Codex
can load it for one invocation while preserving inherited policy. The standalone
`execpolicy check` only evaluates a file for a supplied command.

## Requested contract

Two additions. Their public shape may follow Baikai conventions.

**Caller policy inputs.** A typed way to attach vendor-native policy files to an unattended
run, distinct per provider, equivalent to:

```haskell
data AgentPolicyInput
  = ClaudeSettingsFile FilePath
  | CodexHooksFile FilePath
```

carried by the unattended-run request and accepted by the batch CLI provider configurations.
Claude passes the named settings path because its location has permission meaning.
Codex uses a reviewed app-server hook for this path. Refuse unsupported inputs before
launch. An operator ceiling gates the requested inputs. Ordinary runs never grant trust
or enable the invocation-wide bypass.

**Refusal evidence.** The result of an unattended run, and the response of a batch CLI
completion, report the tool calls the provider refused: the tool name and its command or file
path for each. An empty list and "this provider cannot report refusals" are distinct values.
Baikai reports the evidence and leaves the decision to fail the run with the caller.

## Acceptance

This request is complete when:

1. A caller can attach a Claude settings file to an unattended Claude run, and reviewed Codex hooks
   to an unattended Codex run without raw provider arguments. Tests pin the Claude argv
   and exercise the Codex preflight and event stream against the real app-server.
2. An input for the other provider is refused before a process starts, with an error naming
   the provider and the input.
3. A run whose provider refused a tool call returns evidence naming that call, on both the
   unattended-run surface and the batch completion surface, demonstrated against recorded
   Claude and Codex output without a live model.
4. A provider or output shape that cannot report refusals says so in the type, and is not
   reported as an empty list.
5. Seihou can replace `registerValidatedCli` with the stock providers and keep its two rules:
   an ordinary batch run fails on any reported refusal, and a migration requires positive
   completion evidence.
6. The user documentation states, per provider, what each input can do, including the review
   required for a synchronous Codex PreToolUse hook and the limits on command attribution.

## Non-goals

This request does not ask Baikai to translate one vendor's rules into the other's. A Claude
rule permits a tool call and a Codex `allow` rule removes the sandbox for a command, so a
translation would widen access silently.

It does not cover the HTTP API providers, which run no tools.

It does not ask Baikai to hash, validate or record the policy files. Seihou's receipt and the
file digests in it stay in Seihou.

It does not ask for a way to load a Codex rules file for one run if Codex itself offers none.
That would be a request to Codex.

## Related observation

`allowedToolArgs` in `Baikai.Provider.Claude.Agent` joins tool grants with commas into one
`--allowedTools` value. Seihou now passes
one argument per grant and verified a rule containing a comma with Claude 2.1.330.
Preserve the same argument boundaries when adopting the shared path.

## References

- `mori://shinzui/baikai/packages/baikai` — `Baikai.Agent.AgentSafety`,
  `Baikai.Agent.AgentRenderError`
- `mori://shinzui/baikai/packages/baikai-claude` — `Baikai.Provider.Claude.Agent`,
  `Baikai.Provider.Claude.Cli`
- `mori://shinzui/baikai/packages/baikai-openai` — `Baikai.Provider.OpenAI.Agent`,
  `Baikai.Provider.OpenAI.Cli`
- `mori://shinzui/seihou/plans/127-let-callers-supply-tool-policy-for-batch-blueprint-runs-and-migrations`
  — the consumer, its probes, and the interim rendering
- `mori://shinzui/seihou/okf/improvement-requests/concepts/IR-23` — the originating request
- `mori://shinzui/seihou`, `docs/adr/0026-a-batch-blueprint-run-fails-on-reported-tool-refusals.md`
  (artifact-level URI pending) — why Seihou bypasses the stock Claude provider
- `docs/improvement-requests/add-configurable-cli-for-unattended-coding-agent-runs.md` — IR-1,
  which introduced the unattended-run surface
