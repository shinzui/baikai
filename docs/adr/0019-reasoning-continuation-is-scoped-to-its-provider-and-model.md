---
title: Reasoning continuation is scoped to its provider API and originating model
status: accepted
date: 2026-09-07
---

# Reasoning continuation is scoped to its provider API and originating model

## Context

OpenAI Responses has its own protocol and carries reasoning items with item IDs,
encrypted continuation and ordered summaries. An empty visible summary can
still carry essential continuation. Anthropic thinking signatures have different
semantics. Putting a Responses item ID into the signature field would make the
next provider treat unrelated data as an Anthropic signature; flattening it into
text would destroy the continuation.

## Decision

Responses has a separate `OpenAIResponses` dispatch tag and compatibility record.
`ThinkingContent.replayState` carries a `ThinkingReplay` with API, model and
ordered JSON items. It is separate from Anthropic `signature` and `redacted`
fields. A consuming adapter must verify the API/model scope and item shape
before replay. Adapters that cannot replay these items reject the request
explicitly; the Chat and Claude mappers already enforce that boundary.

JSON persistence preserves the items exactly. Legacy thinking JSON decodes with
no replay state and re-encodes without a new null field. `Show` hides the opaque
items, and visible text rendering ignores them. The response commitment includes
replay state through the content encoding, so editing the continuation changes
the digest. Evidence schema 2.1 records the additive extension; previous content
digests remain valid.

## Consequences

The public API and compatibility sums gain constructors, and constructing
`ThinkingContent` directly requires the new field. These changes need PVP review
before a release. Applications can use `emptyThinkingContent` and record updates.
Moving a conversation across APIs or models requires an explicit application
history decision; Baikai does not silently drop or reinterpret continuation.

The Responses mapper uses `store=false` and requests encrypted reasoning items.
It checks API/model provenance and requires a reasoning item ID, encrypted
content and summary array before forwarding the original ordered JSON. Empty
summaries are valid. Function results use the tool's `call_id`, independently
of the reasoning item ID. An SDK projection is not used for opaque items,
because it could discard unknown continuation fields.

The Responses assembler retains the entire final reasoning item on ThinkingEnd,
including an empty summary and unknown continuation fields. Summary deltas
contain only visible text. Ordered item assembly buffers parallel later items
to preserve Baikai's one-open-block event contract.

Explicit Responses registration now exposes the bounded worker and the same
stream for completion. A scripted public two-turn tool loop proves the
continuation reaches the next wire request unchanged.

The Astra binding now selects Responses through an explicit catalog override.
Strict/lifecycle and pricing acceptance is complete in
[plan 74](../plans/74-add-an-openai-responses-provider-with-tool-and-reasoning-replay.md).
The default change is backed by the public two-turn replay fixture. Live access
is a separate acceptance concern tracked by
[plan 77](../plans/77-prove-new-model-compatibility-with-focused-offline-and-live-checks.md);
a live response without reasoning items cannot prove encrypted replay.

A successful Responses terminal validates reasoning snapshots with the same
minimum item contract as the next-request mapper. A completed response missing
required continuation is an error, rather than a successful response that the
next turn cannot replay. Output item IDs and function `call_id` values must each
be unique across their respective output items.
