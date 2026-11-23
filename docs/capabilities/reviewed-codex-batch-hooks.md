---
title: "Codex batch completion with reviewed hooks"
type: Capability
description: "Complete a Codex batch turn in a checked app-server thread and return the native PreToolUse denials reported for that turn."
generated:
  by: codex/gpt-6
  at: "2026-11-23T14:58:14Z"
capabilityId: CAP-34
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.7.4.0"
packages: [baikai-openai]
interface: [Baikai.Provider.OpenAI.Cli, Baikai.Provider.OpenAI.ReviewedHooks, Baikai.Provider.OpenAI.HookEvidence]
requires: [CAP-15]
evidence:
  - kind: test
    resource: baikai-openai/test/HookEvidenceSpec.hs
    proves: "Inventory checks require the exact reviewed executable handler, and structured outcomes distinguish reported denials, ordinary failures, and missing evidence."
  - kind: guide
    resource: docs/user/cli-providers.md
    proves: "The scoped Haskell API for a batch completion with reviewed hooks."
---

# Codex batch completion with reviewed hooks

For a Codex [batch completion](subscription-cli-backends.md), parse the
caller's native hook declarations with `parseCodexHooks`. Use
`withReviewedCodexCli` to open an ephemeral app-server thread and check
the effective inventory before the callback runs. Inside the callback,
`completeReviewedCodexCli` returns the final answer and reported denials
from that thread. The application decides how a reported denial affects
its operation.
