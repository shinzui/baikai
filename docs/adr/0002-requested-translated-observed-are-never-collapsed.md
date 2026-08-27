---
title: Requested, translated, and observed are three separate facts and are never collapsed
status: accepted
date: 2026-08-05
---

# Requested, translated, and observed are three separate facts and are never collapsed

## Context

Before the evidence work, baikai could show what its own process was
*configured* to ask a model for, and nothing about what actually crossed
the boundary. The gap was total in one place in particular: both API
providers built the assistant message skeleton from the caller's own
`Model` record, so `Response.model` was the request's model *by
construction* and the model the provider echoed back was read by nobody.

That is not a missing feature so much as a category error waiting to
happen. A caller reading `Response.model` would reasonably believe they
were reading what ran. They were reading what they asked for.

## Decision

`Baikai.Evidence.ModelCallEvidence` keeps three things in separate,
non-collapsible fields:

- what the caller **requested** — `requestedModel`, and the level inside
  `thinking.requested`;
- what baikai **translated** that into for one specific provider — the
  rest of `ThinkingTranslation`;
- what the provider was **observed** to report — `observedModel`,
  `observedThinking`, `responseId`, `providerRequestId`, `usage`.

Every observed field is typed `Observed a`, **not** `Maybe a`. A field
the provider did not report is `Unobserved`, which is a positive
statement about the provider's silence rather than a missing value.

The type deliberately provides no way to supply a default: no `Monoid`
instance, no `fromObserved`, no `withDefault`. `observedValue` exists
and its own documentation says to use it to *report* absence, never to
*fill* it.

**The caller's request is recorded on every path, including the paths
where no adapter ran to translate it.** A call that was refused, never
dispatched, or abandoned before the adapter could describe what it did
still has a caller who asked for something, and that is the caller's own
fact. Such a path spells its translation `ThinkingModeNotTranslated`
(`"not_translated"`) — the request is recorded, the translation is
unknown — and never `ThinkingModeAbsent`, which means the caller asked
for nothing.

## Consequences

`Maybe` was the obvious choice and is the wrong one, for a reason that
is entirely about what the type invites. `fromMaybe requestedModel
observedModel` is a natural line of Haskell, it type-checks, it looks
like defensive programming, and it produces a record claiming the
provider corroborated something it never mentioned. Every reviewer would
have to catch it every time. A type with no default function cannot be
misused that way by accident.

The cost is real and is paid at every construction site: `Observed` has
no `Applicative`, so combining observations is manual, and adapters
write `maybe Unobserved Observed` where `Maybe` would have been silent.
That verbosity is the point.

The rule has consequences that surprised the plans that implemented it.
A provider's assembler initialises its usage to zeroes, so reporting
that usage unconditionally would tell a reader the provider said the
call consumed nothing — a fabrication for a call that failed before any
usage arrived. Each transport therefore tracks whether a usage figure
was actually *reported*, separately from what it holds. `codex exec`
names no model anywhere in its event stream, so no Codex CLI call can
ever report one, and the honest consequence is that this transport's
ceiling is lower than its sibling's rather than that it should borrow
the `--model` flag baikai passed.

Four core paths and both providers' `immediateError` had collapsed the
request into "absent" for a year, and the fixtures hid it: every stub
provider's `describeThinking` answered `noThinkingRequested` whatever the
caller set, so a path that lost the caller's level and a path that kept
it produced identical records. A fixture that cannot distinguish the two
outcomes cannot test the rule.

**"Never collapsed" binds consumers too, not only the record.** The
OpenTelemetry sink set `gen_ai.response.model` — an observation — from
`TraceEvent.model`, which is the requested id on every constructor. A
sink that presents a request under an observation's key has collapsed
the two just as surely as a record would, and with less chance of anyone
noticing.

Related: [0003](0003-the-adapter-owns-the-translation-description.md)
covers the middle of the three, and
[0014](0014-strict-evidence-means-a-record-exists.md) covers the prior
question of whether any of the three was written down at all.

## Revisions

- 2026-08-27, `docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md`:
  extended the Decision to the paths where no adapter ran, added
  `not_translated`, and added the consumer-side rule after the
  OpenTelemetry sink was found labelling a requested id as a response
  model.
