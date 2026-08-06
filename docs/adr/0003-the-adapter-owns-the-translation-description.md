---
title: The provider adapter owns the description of what it translated, and no layer re-derives it
status: accepted
date: 2026-08-05
---

# The provider adapter owns the description of what it translated, and no layer re-derives it

## Context

Baikai offers callers six canonical reasoning levels and hides the fact
that no two providers accept the same vocabulary. Hiding it is the
library's job. Hiding it *silently* is a defect, and baikai weakened a
caller's request without telling anyone in six distinct places:

- a model that does not advertise reasoning drops the configuration
  entirely;
- a thinking budget that does not fit the resolved output-token ceiling
  discards the whole plan — which fires when a caller lowers
  `maxTokens`, and is the least discoverable of the six;
- a host with no reasoning controls drops the option;
- the compatibility table clamps `minimal` up to `low` and both `xhigh`
  and `max` down to `high`;
- Z.ai and Qwen accept a bare on/off flag with no depth, so every level
  is wire-identical there;
- Anthropic's adaptive style sends no effort field for `high`, making
  that request indistinguishable on the wire from the provider default.

Only four of those are effort mappings at all. Two are capability and
token-budget interactions that a caller reading their own request would
never spot.

## Decision

The `ThinkingTranslation` describing what a request became is built
**by the provider adapter that built the request**, travels back with
the response, and is re-derived by nobody.

Each adapter derives its adjustment list from the same function that
builds the wire value, rather than from a table written beside it. The
Anthropic max-tokens interaction is extracted into `planThinking` for
exactly this reason: `mapRequest` and the pre-dispatch strictness gate
call the same function. The OpenAI-compatible description runs the real
`injectThinkingShape` over an empty body and keeps only its description.
The CLI translations compare the word that reaches the flag against the
canonical level name.

## Consequences

The rule exists because the alternative is concretely worse, not as a
matter of taste. A trace sink asked to describe what a call sent would
have to reimplement `computeThinking`, the max-tokens arithmetic,
`injectThinkingShape`, and the per-host compatibility lookup — and would
diverge from the real behaviour the first time any of them changed,
silently, in the one record whose entire purpose is to be trustworthy.

"Derive from the mapping function, never from a table beside it" is the
sharper half of the rule and is the one most likely to be eroded. A
hand-written table is easier to read and looks equivalent. It is
equivalent exactly until someone changes the mapping and not the table,
which is the failure this whole initiative exists to eliminate.

The cost lands on `ApiProvider`, which gained a fourth field —
`describeThinking :: Model -> Options -> ThinkingTranslation` — so the
strictness gate can ask what a provider *would* do before any request
exists. That broke every registration site across three packages. The
evidence *channel* did not need it, which is why the plan that built the
channel deliberately left the type alone; the pre-dispatch *gate* does,
because it must answer before there is a request to inspect.

Related: [0002](0002-requested-translated-observed-are-never-collapsed.md)
covers the two facts on either side of this one.
