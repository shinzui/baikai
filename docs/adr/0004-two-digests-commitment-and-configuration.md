---
title: Emit two digests, because a commitment and a configuration fingerprint are different values
status: accepted
date: 2026-08-05
---

# Emit two digests, because a commitment and a configuration fingerprint are different values

## Context

The improvement request behind this work asked for "a hash of the
redacted request envelope", and its own two paragraphs about that hash
wanted incompatible things. The privacy section implied hashing *after*
redaction, which yields a value that commits to configuration and says
nothing about content. The stated purpose was to let a downstream system
bind a run to a reviewed artifact, which requires a value that commits
to content.

Both are useful. They are not the same number, and no single digest is
both.

## Decision

Every evidence record carries two digests over the request, plus one
over the response.

`requestCommitment` is SHA-256 over the canonicalized request envelope
with **nothing removed**, prompt included. It leaks nothing on its own —
publishing it does not disclose the prompt — and anyone who
independently holds the request can recompute it and confirm that a
record describes that request.

`requestConfiguration` is SHA-256 over the same envelope reduced by
`configurationProjection`, an **allow-list** of fields that describe how
a call is configured rather than what it says. Two calls that ask the
same model the same way about different subjects share this value, which
is the point: it is safe to compare across runs that legitimately differ
in content.

`responseCommitment` is the same idea over what came back — the
assembled content, the stop reason, and the **provider-reported token
counts** — and is `Unobserved` when no complete response arrived.

It deliberately excludes the **computed cost**. The cost is derived here
from the caller's own catalog rates rather than reported by the provider,
so a digest covering it changed whenever a price was edited, and a
verifier holding only the response could not recompute it — which defeats
the one thing a commitment is for. `Baikai.Evidence.usageEnvelope` lists
the six count fields through record selectors, so a field added to
`Usage` later does not silently join the digest.

Canonical encoding is written out in `Baikai.Evidence` rather than
borrowed from aeson: keys sorted by UTF-8 bytes, no insignificant
whitespace, one spelling per numeric value, minimal string escaping with
lowercase hex. Changing any of those rules is a **major bump of
`evidenceSchemaVersion`**, not a bug fix, because it invalidates every
digest an earlier build recorded.

## Consequences

The projection is an allow-list and never a denylist, and this is the
load-bearing detail. A denylist over request bodies from the Anthropic
Messages API and seven OpenAI-compatible hosts misses a field the first
time any of them adds one, and the failure mode is prompt content
leaking into a digest callers were told is content-free. An allow-list
fails the other way: a genuinely new configuration field is silently
omitted until someone adds it, which loses fidelity rather than leaking.
Choosing which way a mechanism fails is the decision; both directions
have a cost and only one of them is recoverable.

Five keys are kept but replaced with structural summaries rather than
dropped, because their shape is configuration even though their contents
are not: `messages` becomes one object per message carrying role, block
count, and total character length; `system` becomes a character count;
`tools` becomes each tool's name and nothing else; `output_config` keeps
its effort and reduces its `format` to a type and a character count; and
`response_format` keeps its type and reduces its `json_schema` to a name,
a strictness flag and a character count.

The rule the last three share is worth stating on its own: **a JSON
schema is content wherever it appears.** A structured-output schema
carries author-written `description` strings that describe the caller's
domain as freely as a prompt does. `tools[].input_schema` was stripped on
that ground from the start, while the same kind of schema reached through
`output_config.format.schema` or `response_format.json_schema` survived
verbatim into a digest callers were told is content-free — and the
fixture planted no marker in either, so the redaction test was blind to
it. A summariser added for a new key must come with a marker in the
fixture, or it is untested by construction.

The allow-list admits *named fields from an object*, so a subprocess
transport — whose request envelope is an argument vector — projects to
nothing and every subprocess call shares one configuration digest. That
is the allow-list failing in the safe direction and it is documented
rather than hidden, but it means the field is currently near-useless on
three of baikai's five transports. Teaching the projection about
argument vectors is a real improvement and a real risk: the unattended
agent surface can put the prompt *in* the vector, so any such change
must keep the prompt out by construction. The agent surface already
builds its configuration envelope prompt-free for that reason.

Neither digest is a signature and neither is presented as one. See
[0005](0005-what-baikai-deliberately-does-not-do.md).

## Revisions

- 2026-08-27, `docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md`:
  took the computed cost out of `responseCommitment` and added the
  `output_config` and `response_format` summaries. Both change what a
  verifier must hash, which is the major bump this record's Decision
  section anticipates: records now say
  `baikai.model-call-evidence/2.0`, and a verifier selects its rules by
  `schema_version`.
