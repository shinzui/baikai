---
title: "Cross-provider reasoning-effort control"
type: Capability
description: "Set one canonical ThinkingLevel — none through max — and have each transport translate it into its own primitive: an Anthropic thinking budget, one of seven OpenAI-compatible wire shapes, a claude --effort flag, or a codex model_reasoning_effort override, with every clamp and drop recorded rather than silent."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-11
provider: mori://shinzui/baikai
status: shipped
stability: stable
since: "0.1.0.0"
packages:
  - baikai
  - baikai-claude
  - baikai-openai
interface:
  - Baikai.ThinkingLevel
  - Baikai.Compat
requires:
  - CAP-1
evidence:
  - kind: test
    resource: baikai/test/ThinkingLevelSpec.hs
    proves: "The canonical seven-level vocabulary and its rendering."
  - kind: test
    resource: baikai-claude/test/ThinkingSpec.hs
    proves: "How a level becomes an Anthropic thinking budget, including the manual-versus-adaptive model split and the budget-versus-output-ceiling interaction."
  - kind: test
    resource: baikai-openai/test/ShapeSpec.hs
    proves: "A forty-nine-row table pinning the translation and the shaped request body for every one of the seven OpenAI-compatible wire shapes at every one of the seven levels."
  - kind: test
    resource: baikai-openai/test/ShapeSpec.hs
    proves: "Two named cases assert the OpenAI-native shape sends the canonical level verbatim and is deliberately excluded from the compatibleEffort clamp that governs the other six shapes."
  - kind: example
    resource: baikai-smoke/test/ThinkingSmoke.hs
    proves: "A live call at a reasoning level against real providers."
---

# Cross-provider reasoning-effort control

`Options.thinking` takes a canonical `ThinkingLevel` — `none`, `minimal`, `low`,
`medium`, `high`, `xhigh`, `max` — and each transport maps it to whatever its
backend actually accepts. Anthropic gets a token budget sized against the
resolved output ceiling; the OpenAI-native shape respects its catalog effort policy; other
OpenAI-compatible shapes use their documented effort or toggle mapping; `claude -p`
gets `--effort`; `codex exec` gets `-c model_reasoning_effort=…`. `none` asks
for no reasoning at all: Anthropic sends `thinking: {"type": "disabled"}` to
the generations that accept it, and `Nothing` still sends nothing.

The translations are lossy in ways that used to be invisible. A level whose
budget will not fit under `maxTokens` is dropped; `minimal` on an
adaptive-thinking Anthropic model is sent as `low`; Z.ai and Qwen accept only a bare
`enable_thinking` toggle, so every positive level collapses to the same request
there, while `none` sends `false`. None
of that is hidden any more — each adapter emits a `ThinkingTranslation`
describing what actually happened, which is what
[CAP-19 — verifiable model-call evidence](model-call-evidence.md) records.

This builds on [CAP-1 — provider-neutral model calls with registry
dispatch](unified-provider-calls.md).

## Shape

```haskell
let opts = emptyOptions & #thinking .~ Just ThinkingHigh
completeRequest model ctx opts
```

## Limits

- `ThinkingNone` and `supportsThinkingDisabled` ship in `baikai 0.10.0.0`.
  Explicit off is [CAP-31](explicit-reasoning-off.md); this capability's `since`
  remains the first release of reasoning control.
- Strict evidence refuses a substituted or dropped off request before dispatch.
  A host without controls is not proof that reasoning is disabled. An explicit
  wire setting is translation evidence, not a server observation.

- **The level is a request, not a guarantee.** Two of the seven OpenAI-compatible
  shapes cannot express depth at all, so a caller asking for `max` and a caller
  asking for `low` produce byte-identical requests on those hosts. Only the
  evidence record distinguishes them.
- `none` cannot turn thinking off on Claude Opus 5.5, Sonnet 5.5, Fable 5 or
  Fable 5.1, which reject `disabled`; there it is sent as adaptive `low` and
  reports as `effort_clamped`. It also collapses to `low` on `claude -p` and on
  the non-native effort-word shapes. Z.ai and Qwen express it exactly, as
  `enable_thinking: false`.
- `minimal` does not survive everywhere: it collapses to `low` on the `claude`
  CLI's `--effort` flag and on the four non-native effort-word shapes, and
  reports as `effort_clamped` on adaptive Anthropic models.
- `xhigh` and `max` clamp to `high` on every non-native OpenAI-compatible shape.
  Native OpenAI applies catalog effort restrictions; the Codex CLI forwards the
  requested word and leaves model validation to Codex.
- Asking for thinking on a model that does not advertise `reasoning` drops the
  option — on **both** API providers, and before the host's wire shape is
  consulted — and lowering `maxTokens` alone is enough to make an Anthropic
  thinking budget stop fitting. Both are silent on the wire and visible only in
  evidence.
- Which extended-thinking shape an Anthropic generation accepts is a field of
  its generated catalog record, not a guess from the model id. A **hand-rolled**
  Anthropic model naming an adaptive-era id gets the budget shape unless it
  carries its own `CompatAnthropicMessages`.
- The adaptive-era Anthropic generations reject `temperature`, `top_p` and
  `top_k`, so baikai omits them and records `sampling_dropped_unsupported_model`.
  A caller who set `temperature` and asked for thinking on such a model gets
  neither on the wire and two adjustments in the record.
- `ThinkingXHigh` and `ThinkingMax` arrived in `baikai` 0.4.0.0. A consumer
  pinned below that has four levels rather than six, but still has this
  capability — which is why the record keeps `since` at 0.1.0.0 rather than
  advancing it.
