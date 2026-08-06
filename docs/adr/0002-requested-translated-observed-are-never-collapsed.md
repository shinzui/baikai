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

Related: [0003](0003-the-adapter-owns-the-translation-description.md)
covers the middle of the three.
