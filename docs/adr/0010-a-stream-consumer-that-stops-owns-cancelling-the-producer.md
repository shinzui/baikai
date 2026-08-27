---
title: A stream consumer that stops owns cancelling the producer
status: accepted
date: 2026-08-27
---

# A stream consumer that stops owns cancelling the producer

## Context

Every baikai model call is a `Stream IO AssistantMessageEvent`. Both HTTP
providers produce that stream from a worker thread that reads Server-Sent
Events off a socket and hands each decoded frame to the consumer through
a channel.

Until this record the worker was fire-and-forget. Its `ThreadId` was
discarded at the `forkIO`, the channel between it and the consumer was an
unbounded `Chan`, and nothing anywhere stopped it. A caller who took the
first three events of a long answer and moved on therefore left a worker
reading the **entire** generation into a channel nobody would drain: the
provider billed the full response, the pooled connection stayed busy
until the last frame, and the whole answer sat in memory. The worker also
wrote its end-of-frames sentinel outside any `finally`, so an
asynchronous exception delivered to it skipped the sentinel and left the
consumer blocked in `readChan` until the runtime's deadlock detector
noticed.

Two mechanisms that look plausible were rejected.

A **"consumer still alive" flag** — the consumer sets it false when it
stops, the worker checks it — cannot work, because nothing runs at the
moment a consumer abandons a stream. `Stream.take 3` and carrying on
executes no code on the consumer's behalf. Only the garbage collector can
answer "will anyone pull from this queue again".

A **stall deadline on a blocked write** — treat the consumer as gone
after N seconds on a full queue — was rejected because a slow but live
consumer is indistinguishable from a dead one by that test.
`streamRequestEach` with a callback that takes minutes per event is a
supported use, and cutting it off would make correctness depend on
consumer speed.

A third mechanism remains available but not usable here. streamly's
`bracketIO'` releases at the end of a monad-level
`Streamly.Control.Exception.withAcquireIO` scope even on abandonment, but
it needs an `AcquireIO` handle threaded into the stream, and
`ApiProvider.stream` has no slot for one. Adding one changes the provider
interface, which is a separate decision.

## Decision

**A consumer that stops reading owns cancelling the producer, and the
provider makes that possible by construction.** Concretely, in
`baikai/src/Baikai/Provider/Internal/StreamWorker.hs`:

- The hand-off is a **bounded** queue (`FrameQueue`): a `TBQueue` of
  `frameQueueCapacity` slots plus a `TVar Bool` closed flag.
- The worker is forked by `forkFrameWorker`, which masks around the fork
  so the `ThreadId` cannot be lost, and runs the body under `finally
  closeFrames` so the queue is closed however the body ends.
- The consumer stream is wrapped by `withFrameWorker`, which is
  `Stream.bracketIO` with the fork as acquire and `killThread` as
  release.
- End-of-frames is the closed flag, never a sentinel value pushed onto
  the queue. A sentinel write can block on a full queue and so defeat the
  very cleanup it is part of; a `TVar` write never blocks.

Cleanup then has **three strengths, and they are not the same**. Stating
them separately is part of the decision, because a single sentence
covering all three would have to be either false or useless.

1. **Immediate on cancellation.** An exception thrown into the draining
   thread — `Ctrl-C`, `System.Timeout.timeout`, `cancel` — lands while
   that thread sits inside the stream's own step, which is inside the
   bracket. streamly runs the release synchronously: the worker is
   killed, the transport's `bracket` around the HTTP response runs, and
   the connection is back in the pool before the exception reaches the
   caller.
2. **Bounded read, then eventual release, on abandonment.** Nothing runs
   at the moment a consumer walks away, but the bound alone stops the
   socket read: the worker pushes at most `frameQueueCapacity` more
   frames and then parks in an interruptible STM wait. No GC and no timer
   is involved in *that* part. The connection itself is released when
   streamly's GC finaliser fires at the next major collection and runs
   the same `killThread`.
3. **Immediate on normal end**, for the same reason as (1).

## Consequences

Callers who need the connection back at a known moment **cancel the
draining thread, or wrap the drain in `System.Timeout.timeout`**. A bare
`Stream.take` is entirely legal — the socket read stops at once and the
provider stops generating — but the connection returns at the next major
garbage collection rather than at the `take`. `docs/user/streaming.md`
says this in caller terms.

`frameQueueCapacity` is a real bound on producer read-ahead, so a
consumer doing slow per-event work now applies backpressure to the
socket. That is intended: it is what stops an abandoned generation. It is
not a memory limit — 64 SSE frames is small — and it must never be
lowered to the point where an ordinary consumer becomes the bottleneck.

The three strengths are pinned by `LifecycleSpec.hs` in both provider
suites, four cases each: the bounded read, the eventual release under
`performMajorGC` polling, the immediate release with **no** `performMajorGC`
call, and a worker that dies by asynchronous exception still ending the
stream in an `EventError`. A flaky failure there is a signal to re-read
the three strengths above, not to widen a bound.

`Baikai.Provider.Internal.StreamWorker` is exposed, like
`Baikai.Provider.Cli.Internal`, so the two provider packages share one
implementation. It is outside baikai's PVP promise.

This record does not say anything about *retries*: baikai classifies
transport failures and does not own retry policy
([0005](0005-what-baikai-deliberately-does-not-do.md)). Cancelling a
producer is cleanup, not a retry decision.
