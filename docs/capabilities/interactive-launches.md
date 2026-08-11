---
title: "Interactive agent-session launches"
type: Capability
description: "Hand the terminal to a real Claude Code or Codex session from Haskell with provider-neutral model, reasoning-effort, directory, and safety settings — where a safety policy the chosen tool cannot express is refused before launch instead of being silently dropped."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
capabilityId: CAP-16
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.Interactive
  - Baikai.Provider.Claude.Interactive
  - Baikai.Provider.OpenAI.Interactive
evidence:
  - kind: test
    resource: baikai/test/InteractiveSpec.hs
    proves: "The provider-neutral vocabulary: an interactiveLaunchRequest leaves optional settings empty, provider and scope render to stable names, Codex sandbox and approval values render to CLI-ready names, and a launch result records provider identity plus process status."
  - kind: test
    resource: baikai-claude/test/Main.hs
    proves: "The Claude Code argument vector — model, prompt, directories, allowed tools, extra args — and that a CodexSandbox policy is refused with SafetyNotExpressible rather than launching an unrestricted session."
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "The Codex argument vector — model, working directory, extra dirs, sandbox, approval, extra args — and that a Claude tool allow-list is refused rather than launching with Codex's default sandbox; DefaultSafety and an empty allow-list still render no safety flag."
  - kind: example
    resource: baikai-smoke/test/InteractiveSmoke.hs
    proves: "An actual launch of a local interactive session when the tool is on PATH."
  - kind: guide
    resource: docs/user/interactive-launches.md
    proves: "What an interactive launch is, how it differs from the batch CLI providers and from an unattended run, and how each safety policy maps onto each tool."
---

# Interactive agent-session launches

`launchClaudeInteractive` and `launchCodexInteractive` start a real coding-agent
session that owns the terminal, its own tool loop, its own approvals, and its own
exit code. This is not a model call: nothing comes back as a `Response`, and the
registry is not involved. What baikai provides is the provider-neutral request
vocabulary — model id, reasoning effort, working directory, extra directories,
safety policy — and each vendor package's renderer from that vocabulary to an
argument vector.

The load-bearing behaviour is the **refusal**. Since 0.5.0.0, a request carrying
a safety policy the chosen tool cannot express — a Codex sandbox on Claude Code,
a Claude tool allow-list on Codex — returns
`Left (SafetyNotExpressible provider)`, naming what was rejected and suggesting
the expressible alternative. Before that the policy was discarded and an
*unrestricted* session was started and reported as a success. A caller who asks
to be constrained is now either constrained or told no.

`Left` means no process was started. `Right` with a non-zero exit code means the
session ran and exited non-zero. `DefaultSafety` and an empty allow-list render
no safety flag and are never refused.

## Shape

```haskell
import Baikai.Provider.Claude.Interactive (launchClaudeInteractive)

result <- launchClaudeInteractive config
  (interactiveLaunchRequest & #modelId .~ "claude-opus-5"
                            & #safety  .~ ClaudeAllowedTools ["Read", "Grep"])
case result of
  Left refusal -> reportRefusal refusal   -- nothing was started
  Right done   -> exitWith (done ^. #exitCode)
```

## Limits

- **Attended by definition.** A human is at the terminal. For a run with no
  terminal and no human, see
  [CAP-17 — unattended coding-agent runs](unattended-agent-runs.md).
- The two tools' safety vocabularies do not overlap, and baikai does not
  translate between them. It refuses instead, which is safe but means a
  provider-neutral safety policy is not actually portable.
- Return types changed in the 0.5.0.0 wave: `claudeInteractiveCommand` and
  `codexInteractiveCommand` now return `Either AgentRenderError …`. Callers must
  handle the refusal branch — the known downstream consumer is
  `mori://shinzui/seihou`. No previously rendered argument vector changed.
- baikai neither installs nor authenticates the tools; they must be on `PATH`
  with their own credentials.
- Everything except `InteractiveSmoke` is a pure argument-vector assertion. That
  a session behaves correctly once launched is outside what this repository can
  prove.
