---
title: Baikai does not sign, does not hold sanctioning policy, does not claim provider internals, and does not own retries
status: accepted
date: 2026-09-08
---

# Baikai does not sign, does not hold sanctioning policy, does not claim provider internals, and does not own retries

## Context

A record called "evidence" attracts responsibilities. Once baikai emits
one, it is a short step to asking it to sign the record, to decide
whether the model that ran was permitted, to describe what the provider
did internally, and to own the retry loop whose attempts the record
correlates.

Each of those is a real need. None of them belongs here, and leaving the
boundary unstated is how a library acquires them one plausible pull
request at a time.

## Decision

Baikai reports **what it requested, what it translated, and what it
observed at its own boundary**. Four things are outside that line and
stay outside.

**Baikai does not sign anything.** No run-level attestation, no
signature over an evidence record, no key material. Correlating calls
into a run, binding a run to a reviewed artifact, and signing the
resulting statement belong to `mori://shinzui/shikigami`, which consumes
these records.

**Baikai holds no sanctioning policy.** It has no opinion about which
models are permitted. It reports the model it requested and, separately,
the model the provider said it ran; deciding whether that is acceptable
is the consumer's job. The unattended agent surface's `AgentCeiling` is
not a counter-example — that is an operator ceiling on *filesystem
authority for a run baikai spawns*, not a judgement about models.

**Baikai does not claim knowledge of provider internals.** `strength`
tops out at what a provider actually reported. No transport reaches
`EvidenceFullyObserved`, because no provider echoes the reasoning
configuration it applied — and a reasoning-token count is not that echo,
since it corroborates output volume and says nothing about which effort
setting was in force. A successful HTTP status or a zero process exit
never raises the strength.

**Baikai does not own retries.** It has no retry or fallback loop:
`Baikai.Error` classifies whether an error is retryable and nothing acts
on it. The evidence therefore models a retry relationship as
caller-supplied provenance — an `attempt` ordinal and an optional
`supersedes` call id — not as something baikai observes.

**Baikai does not enable Anthropic server-side fallbacks.** Forwarding a
provider-owned loop would not itself violate the no-local-retries boundary,
but forwarding this field without modelling its result would violate the
boundary on truthful reporting. The adapter leaves `fallbacks` absent.
A caller may choose a subsequent call explicitly; baikai does not act on a
refusal category or choose a substitute model.

The current adapter calculates cost from the requested model's catalog and
records a single observed model from `message_start`. It does not interpret
fallback handoff blocks or per-iteration usage. Supporting this feature would
require an explicit design for requested versus served model identity,
per-attempt usage and pricing (including refusal billing and fallback credit),
compatibility validation for each target, and replay of cross-model content.
Those are prerequisites for reconsideration, not promised follow-on work.
This is a deliberate exclusion, not a judgment about which models are allowed.

The provider's [refusal and fallback contract](https://platform.claude.com/docs/en/build-with-claude/refusals-and-fallback)
was consulted on 2026-09-08; SDK types were inspected through
`mori://MercuryTechnologies/claude/packages/claude`.

## Consequences

The exclusions have teeth in the code rather than only in prose. There
is no signing API to reach for. `declaredStrength` has no
`EvidenceFullyObserved` entry, and a test asserts the value stays
unreachable until a provider earns it. `attempt` and `supersedes` are
fields of the caller's `EvidenceRequest`, so a reader can see they came
from outside.

The honest framing to keep: a trace record is evidence in the sense that
a well-kept logbook is evidence — a contemporaneous record by a party
with no independent knowledge of the other side. Anyone presenting it as
more than that is misrepresenting it. Provider-signed receipts and
confidential-computing attestation are strictly stronger and need
provider support baikai does not have.

The cost is that a consumer wanting a signed, sanctioned, run-level
statement has to build the layer above. That is the correct division: a
provider-abstraction library that also held signing keys and a model
allow-list would be two products sharing a package boundary, and the
second would constrain the first.

Refusal detail remains useful without automatic fallback: callers can branch
on the provider's category and decide their own next action. Request-shape
coverage asserts that baikai does not enable the excluded fallback feature.
