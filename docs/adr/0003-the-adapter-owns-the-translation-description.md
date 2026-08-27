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

**Where no adapter built a request, the description is obtained rather
than invented.** Two cases arise, and the core re-derives nothing in
either:

- A provider *is* registered and did run — the consumer-abort path in
  `Baikai.Trace` — so the core calls that provider's own
  `describeThinking`. Asking the adapter is exactly what this record
  requires; the adapter's answer is the truthful one.
- No provider is registered, or a `complete` handler threw before
  returning, so there is nothing to ask. The record then says
  `not_translated` (see
  [0002](0002-requested-translated-observed-are-never-collapsed.md)),
  which states the caller's level and claims nothing about a wire shape
  that was never built.

Each adapter's own `immediateError` — the path where `prepareCall` failed
— calls its own describer, for the same reason.

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

The cost lands on `ApiProvider`, which now carries **two declarations a
provider alone can make**, and both broke every registration site across
three packages when they were added:

- `describeThinking :: Model -> Options -> ThinkingTranslation`, so the
  strictness gate can ask what a provider *would* do before any request
  exists. The evidence *channel* did not need it, which is why the plan
  that built the channel deliberately left the type alone; the
  pre-dispatch *gate* does, because it must answer before there is a
  request to inspect.
- `strengthCeiling :: EvidenceStrength`, the highest strength this
  provider's evidence can reach. The gate compared against a tag-keyed
  table, `declaredStrength`, which necessarily answered
  `EvidenceRequestedOnly` for every `Custom` transport — so a gateway
  that genuinely observes a model could never satisfy a strict caller
  who required that it did. Only the provider knows.

`declaredStrength` remains, but as a source rather than an authority: the
four built-in providers fill their `strengthCeiling` from it, and the
unattended-agent surface still consults it by tool. Declaring more than
the transport delivers is the one way left to make strict mode lie, so a
declaration above `EvidenceRequestedOnly` needs a test that drives the
provider to it.

Related: [0002](0002-requested-translated-observed-are-never-collapsed.md)
covers the two facts on either side of this one, and
[0014](0014-strict-evidence-means-a-record-exists.md) is why the ceiling
must be the provider's own declaration.

## Revisions

- 2026-08-27, `docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md`:
  stated how a path with no adapter obtains its description, and recorded
  `ApiProvider.strengthCeiling` as the second provider-owned declaration.
