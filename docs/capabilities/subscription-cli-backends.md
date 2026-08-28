---
title: "Subscription-backed batch CLI backends"
type: Capability
description: "Run claude -p and codex exec as subprocess providers behind the same completeRequest surface, so a program billed against a flat-rate Claude Max or ChatGPT subscription uses the same call sites as a per-token API caller — now carrying the token counts and session identifiers each tool reports about itself."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-15
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai-claude
  - baikai-openai
  - baikai
interface:
  - Baikai.Provider.Claude.Cli
  - Baikai.Provider.OpenAI.Cli
  - Baikai.Provider.Cli.Internal
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/CliInternalSpec.hs
    proves: "The shared subprocess helpers against trimmed recordings of real claude 2.1.222 and codex-cli 0.146.0 output, so the parsers are pinned to the exact field spellings and nesting those versions emit."
  - kind: test
    resource: baikai-claude/test/Main.hs
    proves: "The claude -p argument vector and that a missing binary or a failing subprocess becomes an error-shaped Response rather than an exception."
  - kind: test
    resource: baikai-openai/test/Main.hs
    proves: "The codex exec argument vector, including option termination before a dash-leading prompt and survival of a 1MiB stderr flood without deadlock."
  - kind: guide
    resource: docs/user/cli-providers.md
    proves: "When to reach for a CLI provider instead of an API provider, how to configure each, the response shape they produce, and their limitations."
  - kind: module
    resource: baikai/src/Baikai/Provider/Cli/Internal.hs
    proves: "The shared subprocess vocabulary: ClaudeCliReport, CodexRunReport, the structured-output parsers, and the cached ExecutableIdentity probe."
---

# Subscription-backed batch CLI backends

`Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli` register handlers
for the `AnthropicMessagesCli` and `OpenAICompletionsCli` tags. Dispatching to
one of those tags spawns `claude -p` or `codex exec` as a subprocess and returns
its answer as an ordinary `Response`. The value is billing, not features: a
program that pays a flat-rate subscription runs the same code as one paying per
token.

Both providers parse the tool's own structured output rather than scraping text.
`ClaudeCliReport` and `CodexRunReport` fold each tool's event stream into its
assistant text, its session or thread identifier, and its token counts. Every
field but the message text is optional, because both tools' schemas have shifted
across versions and an absent field is a genuine absence rather than a parse
failure.

Adopting either half is the same decision, so they are one record: the mechanism,
the shared internal module, the response shape, and the limits below are common
to both.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
import Baikai.Provider.Claude.Cli qualified as ClaudeCli

ClaudeCli.register
completeRequest modelWithCliTag ctx opts -- spawns `claude -p`
```

## Limits

- **Text in, text out.** No tools, no images, no structured output. Those
  features belong to the API providers; a coding-agent CLI runs its own tool loop
  internally and does not expose one.
- Streaming is **synthetic**. The subprocess runs to completion and the result is
  then replayed as start / one text block / done. The types match
  [CAP-2](typed-streaming.md); the latency behaviour does not.
- Before 0.5.0.0 both providers hardcoded zero usage, so every such call looked
  free. They now carry real token counts — Anthropic-shaped and already disjoint
  for `claude`, with `codex`'s inclusive prompt counts normalised by subtracting
  cached tokens out. `claude` also reports a real `total_cost_usd`. **Historical
  cost reports will not reconcile with new ones.**
- The tools must be on `PATH` and already authenticated. baikai does not install
  them, log them in, or check their version compatibility beyond a five-second
  `--version` probe used for evidence.
- `codex-cli 0.146.0` names no model anywhere in its event stream, so a Codex CLI
  run can never exceed `correlated` evidence strength. A zero exit status never
  raises strength on either tool.
- `Baikai.Provider.Cli.Internal` is shared and exposed but documented as outside
  the PVP contract; `parseCodexJsonlStream`'s result type changed in 0.5.0.0.
- The parsers are pinned to recordings of two specific tool versions. A future
  release of either tool can change its event schema, and the failure mode is
  fields quietly going absent.
