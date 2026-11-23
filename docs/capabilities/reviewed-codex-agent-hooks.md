---
title: "Reviewed Codex hooks for unattended jobs"
type: Capability
description: "Review a native Codex PreToolUse configuration and collect reported denials in the JSON result of an unattended job."
generated:
  by: codex/gpt-6
  at: "2026-11-23T14:58:14Z"
capabilityId: CAP-35
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.3.0.0"
packages: [baikai-agent, baikai-openai]
interface: [Baikai.Agent.Cli]
requires: [CAP-18, CAP-34]
evidence:
  - kind: module
    resource: baikai-agent/src/Baikai/Agent/Cli.hs
    proves: "The review command, invocation-only hook selection, and serialization of the reported blocked hooks."
  - kind: guide
    resource: docs/user/unattended-agent-runs.md
    proves: "How to review a hooks file and interpret denials from an unattended run."
---

# Reviewed Codex hooks for unattended jobs

From the job's working directory, run `baikai agent review-codex-hooks FILE`
to review and confirm the native declarations. Use `baikai agent run JOB
--codex-hooks FILE --json` to apply them to a named job from the
[layered configuration](baikai-agent-command.md). The
[reviewed Codex transport](reviewed-codex-batch-hooks.md) checks the
thread's inventory before sending the prompt. The JSON result's
`blockedHooks` field carries reported denials with thread, turn, and hook run IDs.

Review again when the declarations change.
