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
  - kind: test
    resource: baikai/test/CliProcessSpec.hs
    proves: "Unreleased shared ownership regression: group escalation, early leader reaping with an unreaped anchor, joined readers, repeated cancellation, successful-callback cleanup cancellation, and version-probe timeout."
  - kind: test
    resource: baikai-claude/test/CliCancellationSpec.hs
    proves: "Unreleased public Claude batch adapter: descendant cleanup precedes acknowledged cancellation for complete, active synthetic streams, and evidence probes."
  - kind: test
    resource: baikai-openai/test/CliCancellationSpec.hs
    proves: "Unreleased public Codex batch adapter: descendant cleanup precedes acknowledged cancellation, including repeated cancellation, active streams, version probes, and schema lifetime through termination."
  - kind: guide
    resource: docs/user/cli-providers.md
    proves: "When to reach for a CLI provider instead of an API provider, how to configure each, the response shape they produce, and their limitations."
  - kind: module
    resource: baikai/src/Baikai/Provider/Cli/Internal.hs
    proves: "The shared subprocess vocabulary: ClaudeCliReport, CodexRunReport, the structured-output parsers, and the cached ExecutableIdentity probe."
timestamp: "2026-10-06T17:38:18Z"
reviews:
  - kind: model
    reviewer: codex-cli
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    scope: content-and-metadata
    outcome: commented
    reviewed_at: "2026-10-06T17:38:18Z"
    document_timestamp: "2026-10-06T17:38:18Z"
    context: "Implementation self-check of the unreleased batch cancellation scope and positive real-process regressions; this does not assert that released adapters contain the fix."
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

- **Text in, text out.** No tools and no images. Those features belong to the
  API providers; a coding-agent CLI runs its own tool loop internally and does
  not expose one. The one exception is a `JsonSchema` response format, which
  since `baikai-claude` 0.7.1.0 / `baikai-openai` 0.7.1.0 reaches `claude -p` as
  `--json-schema` and `codex exec` as `--output-schema <temporary file>`; see
  [CAP-5](structured-output.md). A tool too old for the flag yields an
  `InvalidRequest` error, not unconstrained text.
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

## Unreleased cancellation fix

The positive regressions above verify the working-tree fix for
[BUG-1](../bug-reports/batch-cli-cancellation-leaves-child-alive.md), implemented in
[plan 90](../plans/90-terminate-owned-batch-cli-process-groups-before-acknowledging-cancellation.md).
They add no claim about released adapters: a fixed release is still required.
On Darwin and Linux the shared scope stops inherited process-group members,
joins pipe readers, reaps the CLI and ownership anchor, and preserves the first
asynchronous exception before completing cancellation. The version evidence
probe uses the same scope, including on its five-second timeout. Codex removes
its schema file only after cleanup.

Processes deliberately leaving the group/session are outside this lifecycle
scope. Adopted descendant zombies have stopped but must be reaped elsewhere.
Uninterruptible kernel I/O precludes an unconditional reaping time bound.
Windows cleans up only the direct child. The POSIX implementation requires
`/bin/ps` and the threaded runtime. See the user guide and
[the ownership decision](../adr/0026-batch-cli-cancellation-owns-process-groups-and-reader-workers.md)
for the contract and its limits.
