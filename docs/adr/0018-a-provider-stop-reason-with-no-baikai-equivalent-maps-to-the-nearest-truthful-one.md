---
title: A provider stop reason with no baikai equivalent maps to the nearest truthful one, and the sum does not widen to hold it
status: accepted
date: 2026-08-27
---

# A provider stop reason with no baikai equivalent maps to the nearest truthful one, and the sum does not widen to hold it

## Context

`Baikai.StopReason` is a closed sum of four constructors — `Stop`,
`Length`, `ToolUse`, `ErrorReason` — exported with `(..)` and
re-exported from `Baikai`. Every API provider maps its vendor's stop
reason onto it, and the CLI providers populate `Stop` on success and
`ErrorReason` when the subprocess reports an error. It is the field a
caller reads to learn why generation ended, and it is provider-neutral
by construction: four words that mean the same thing whichever backend
answered.

Providers keep adding stop reasons. Upgrading `claude` from 1.4.0 to
1.5.0 added `Pause_Turn` to `Claude.V1.Messages.StopReason`: Anthropic
suspends a turn mid-flight while a long-running server-side tool runs,
and expects the caller to send the message back to continue it. Because
`mapStopReason` in
[`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs`](../../baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs)
matches that type with no wildcard, and `baikai-claude` compiles under
`-Werror=incomplete-patterns`, the bump could not build until somebody
decided what a paused turn is. That is the pattern working as intended —
the compiler refuses to let a new provider concept pass unnoticed — but
it means the question arrives as a build failure in the middle of a
dependency upgrade, when the cheap answers are attractive.

There are three cheap answers and each is wrong in a different way.
Adding a wildcard branch retires the compiler's warning and guarantees
the next new stop reason is mapped by accident. Widening
`Baikai.StopReason` breaks every consumer whose `case` is exhaustive
without a wildcard, and does it for a concept only one provider has.
Mapping anything unfamiliar to `ErrorReason` tells a caller that a call
failed when nothing failed, which is worse than a coarse answer: it is a
false one, and `ErrorReason` is the constructor callers branch on to
decide whether to surface a failure.

Nothing in the repository had said which answer was right, though two
places had already chosen. `Model_Context_Window_Exceeded` — a distinct
Anthropic reason with no baikai twin — maps to `Length`, because running
out of context and running out of output budget are the same thing to a
caller who has to shorten something and retry. And `mapFinishReason` in
[`baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs`](../../baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs)
maps an *unrecognized* `finish_reason` to `Stop` and carries the
provider's own word into the message's `errorMessage` as a note.

## Decision

A provider stop reason that has no `Baikai.StopReason` equivalent maps
to the constructor that is **truthful about whether the call failed**.
`ErrorReason` means the call failed and the caller has a failure to
handle; it is never the destination for a reason that merely has no
neat translation. A reason meaning "generation ended and nothing went
wrong" maps to `Stop` even when it carries more meaning than `Stop`
does. A reason meaning "the model ran out of room" maps to `Length`.

`Baikai.StopReason` widens only when a caller must branch on the
distinction **and baikai would do something different because of it**.
That second clause is the whole test. Baikai does not own retries or
continuation loops —
[ADR 0005](0005-what-baikai-deliberately-does-not-do.md) — so a stop
reason that means "send this back to me and I will continue" asks for a
loop baikai has already decided not to have. Until baikai grows one,
there is no behaviour a fifth constructor would change, and the plan
that grows it owns widening the sum, announcing the break, and updating
every provider's mapping in the same change.

Applying the rule: **`Pause_Turn` maps to `Stop`**, at
`baikai-claude/src/Baikai/Provider/Claude/Internal/Stream.hs:981`, with
the reasoning in a comment beside it. The `Message_Stop` branch treats it
exactly as it treats an ordinary end of turn — an `EventDone`, no
`errorMessage` — and a named test, "a paused turn ends the stream as a
stop, not an error", holds that shape.

No wildcard branch is added to `mapStopReason`. The exhaustiveness error
on the next SDK bump is the mechanism that brings the next one of these
questions to a person, and it is worth the interruption it causes.

The counter-example is on the record too, so the rule is not read as
"never widen". `Baikai.Error.ErrorCategory` grew `ContentFiltered` in
this same cycle, and the changelog calls it breaking. That widening
earned itself: a filtered response is a failure a caller genuinely
handles differently from any other non-retryable one, and without the
constructor the only way to detect it was matching on message text.
`Pause_Turn` has no such caller today.

## Consequences

A caller cannot distinguish a paused turn from a completed one. That is
a real loss, and it lands on exactly the people most likely to hit it:
anyone driving Anthropic's long-running server-side tools, for whom the
difference is whether there is more to come. They can still see it — the
assistant turn ends without the content a finished answer would have —
but not from `stopReason`, and baikai does not tell them.

The provider's own word is dropped rather than recorded. This is the
uncomfortable part, because
[ADR 0002](0002-requested-translated-observed-are-never-collapsed.md)
says an observed fact is kept separate from baikai's translation of it,
and `stop_reason` is the one place a provider's observation is
translated into baikai's vocabulary and the original discarded. The
OpenAI provider's `finishNote` was considered as the channel and
rejected here: it lands in `Msg.errorMessage`, which on a healthy call
is a misleading place to put a note, and a consumer that treats a
non-`Nothing` `errorMessage` as failure would be wrong in a new way.
Carrying the raw stop reason properly means a field on the assistant
payload or a fact in the evidence record, which is a change to a public
shape and deserves its own plan rather than a rider on a dependency
bump. Until then the honest statement is that baikai keeps the
translation and not the observation, and this record exists partly so
that gap is written down instead of discovered.

The evidence record inherits the coarseness. `responseEnvelope` commits
to `stopReason` as the mapped value, so two Anthropic responses that
differed only in whether the turn was paused produce the same commitment
digest. A verifier holding the raw response can still tell them apart;
baikai's digest cannot.

The cost of the rule is that each new provider stop reason costs a
person a decision, and the decision arrives at the least convenient
moment — mid-upgrade, as a build failure. That is the intended trade.
The alternative is a wildcard that makes the same decision silently and
always the same way, which is how a stop reason that should have widened
the sum gets quietly mapped to `Stop` and stays there.
