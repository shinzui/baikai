---
id: 34
slug: harden-trace-and-call-log-workers
title: "Harden trace and call-log workers"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Harden trace and call-log workers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Today, a broken observability sink can break the request it is observing. If a
`TraceSink` throws (an unwritable `fileSink` path, an OpenTelemetry exporter error), the
background worker thread that drains trace events dies before signalling completion, and
the caller's own request path hangs forever inside `withTrace` waiting for that signal —
or dies with `BlockedIndefinitelyOnMVar`. The JSONL call log in `Baikai.Cost.Log` has
the identical defect: `closeCallLog` hangs and pending entries vanish. Two smaller
defects compound this: trace event ids repeat after 65,536 calls (so the OpenTelemetry
sink's id-keyed span map closes the wrong live span), and a consumer that abandons a
traced stream early never produces a terminal trace event, leaving spans permanently
open in correlating sinks.

After this plan, a throwing sink or an unwritable log path can never hang or crash a
caller: the request completes normally, the sink failure is reported once on stderr, and
`withCallLog`/`withTrace` always return. Event ids are collision-free for the life of
any real process (2^32 ids per process). An abandoned traced stream emits a synthetic
`CallFailed` terminal so every `CallStarted` is eventually paired and no OpenTelemetry
span is left open without a status. You can see all of this working by running the
`baikai` and `baikai-trace-otel` test suites, which gain deterministic regression tests
that hang or fail before the fix and pass after it.

These are review findings Theme 7 (items 1–3) plus the OpenTelemetry defensive-drop note
from `docs/reviews/2026-07-01-correctness-and-api-review.md`; this plan is EP-1 of the
MasterPlan at `docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`.
It has no dependencies on any sibling plan and touches only
`baikai/src/Baikai/Trace.hs`, `baikai/src/Baikai/Cost/Log.hs`,
`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`, their tests, and one
test-suite stanza in `baikai-trace-otel/baikai-trace-otel.cabal`.


## Progress

- [x] M1: capture sink exceptions in `Baikai.Trace`'s drain worker (`try` + unconditional `putMVar`), report once on stderr at cleanup. Completed 2026-07-03T14:29:13Z.
- [x] M1: same restructure for the `Baikai.Cost.Log` worker; `closeCallLog` reports the captured exception and never hangs. Completed 2026-07-03T14:29:13Z.
- [x] M1: regression test in `baikai/test/TraceSpec.hs` — a throwing in-memory sink cannot hang `withTrace` (guarded by `timeout`). Completed 2026-07-03T14:29:13Z.
- [x] M1: regression test in `baikai/test/CostSpec.hs` — `withCallLog` on an unwritable path returns (guarded by `timeout`). Completed 2026-07-03T14:29:13Z.
- [x] M2: widen `newEventId` to a 64-bit id (32-bit epoch base, 32-bit counter; 16 hex chars). Completed 2026-07-03T14:29:13Z.
- [x] M2: uniqueness test in `baikai/test/TraceSpec.hs` — 70,000 generated ids are pairwise distinct and 16 chars long. Completed 2026-07-03T14:29:13Z.
- [x] M3: add `terminalSent` tracking and a synthetic `CallFailed` in the stream finalizer (`finalizeTrace`) on early abort. Completed 2026-07-03T14:29:13Z.
- [x] M3: early-abort test in `baikai/test/TraceSpec.hs` (GC-driven, bounded poll). Completed 2026-07-03T14:29:13Z.
- [x] M3: early-abort span-closure test in `baikai-trace-otel/test/Main.hs`; add `streamly-core` to that test suite's `build-depends`. Completed 2026-07-03T14:29:13Z.
- [x] M3: comment in `stepEvent` documenting the deliberate silent drop of unknown-eventId terminals. Completed 2026-07-03T14:29:13Z.
- [x] Update module haddocks in `Baikai.Trace` and `Baikai.Cost.Log` to describe the new failure semantics. Completed 2026-07-03T14:29:13Z.
- [x] Full validation: `cabal build all --enable-tests` and `cabal test baikai baikai-trace-otel` pass from the repo root. Completed 2026-07-03T14:29:13Z.
- [x] Tick the EP-1 checkboxes in `docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`. Completed 2026-07-03T14:29:13Z.


## Surprises & Discoveries

- During the first implementation of the early-abort test, the trace worker could be
  killed by the RTS with `BlockedIndefinitelyOnMVar` before streamly's GC-driven
  `finallyIO` action wrote the synthetic `CallFailed`. Evidence: the new
  `Baikai.Trace` test initially timed out after recording only `CallStarted`, and the
  warning path reported `thread blocked indefinitely in an MVar operation`. The fix is
  to keep each active `TraceState` alive through a `StablePtr` until `finalizeTrace`
  completes, preventing the worker's blocking `readChan` from being considered
  unreachable before finalization. (2026-07-03)


## Decision Log

- Decision: Sink and log-worker exceptions never propagate into the caller's request
  path. The worker captures the first exception in an `IORef (Maybe SomeException)`
  carried on the per-call state (`TraceState.sinkError` /
  `CallLogHandle.workerError`), always fills the `done` MVar, and the close path
  (`finalizeTrace` / `closeCallLog`) reports the captured exception as a single
  warning line on stderr. It is not rethrown.
  Rationale: tracing and logging are observability; a broken sink must not turn a
  successful provider call into an exception. Rethrowing is also structurally wrong
  here: the trace cleanup runs inside `Stream.finallyIO` (throwing there would mask
  the stream's own terminal semantics and violate the in-band error contract this
  module documents), and `closeCallLog` runs as a `bracket` release action (throwing
  there would mask body exceptions). The stderr line keeps the failure observable —
  the review's complaint was silence, not in-band-ness. A programmatic accessor can
  be added later without disturbing this design.
  Date: 2026-07-01
- Decision: When the sink throws, the worker stops draining; trace events / log
  entries enqueued after the failure for that call are dropped, and the stderr
  warning says so.
  Rationale: the streamly fold's state is gone after the throw, and per-event retry
  against a sink that just failed (e.g. a missing directory) would spin. Dropping
  with an explicit warning is honest and simple; a call produces at most three trace
  events, so the loss is bounded and reported.
  Date: 2026-07-01
- Decision: `newEventId` widens from 32 bits (16-bit epoch base + 16-bit counter) to
  64 bits (low 32 bits of process-start POSIX seconds, shifted left 32, OR'd with the
  low 32 bits of the counter), rendered as 16 zero-padded lowercase hex characters.
  Rationale: ids must not repeat within a process (2^32 calls is unreachable in
  practice, 2^16 is not) and should differ across process restarts more than a second
  apart. The id is an opaque `Text` in `TraceEvent`, so widening from 8 to 16
  characters breaks no API or JSON consumer. No new dependency (no UUID lib) needed.
  Date: 2026-07-01
- Decision: On early abort (consumer stops or dies before the stream's terminal
  event) the finalizer emits a synthetic `CallFailed` — not `CallFinished` — with
  `errorMessage = "aborted: stream consumer stopped before the terminal event"`,
  measured latency, and the call's original `eventId`.
  Rationale: `CallFinished` semantically claims the provider reported completion and
  carries usage/cost, neither of which exists on abort. `CallFailed` maps to
  OpenTelemetry span status `Error`, which is the conventional encoding of a
  cancelled operation, and the distinctive message lets log readers separate aborts
  from provider failures.
  Date: 2026-07-01
- Decision: Synthetic-terminal delivery on abort is eventual, not synchronous.
  Verified against the streamly source (`Streamly.Internal.Data.Stream.Exception`):
  `Stream.finallyIO` runs its action synchronously only when the stream stops
  normally or one of the stream's own steps throws; when a *consumer* abandons the
  stream (e.g. `Stream.take`, or an exception in the driving fold), the action runs
  from a GC finalizer hook. We accept this (it is inherent to streamly's model, and
  the alternative — restructuring the trace bridge away from `finallyIO` — is out of
  scope and riskier than the bug), document it, and write the abort tests with
  `performMajorGC` plus a bounded poll loop.
  Date: 2026-07-01
- Decision: The OpenTelemetry sink keeps silently dropping `CallFinished`/`CallFailed`
  events whose `eventId` has no live span, but the branch gains a comment explaining
  why. No stderr logging there.
  Rationale: each `withTraceStream` call drives its own fresh fold instance, so
  within one instance a terminal always follows its own `CallStarted`; the branch is
  unreachable in normal operation and exists only so hand-fed or replayed event
  streams cannot crash the sink. Logging from that branch would add noise with no
  actionable signal. With M2's collision-free ids the "clobbered span" variant of
  this hazard is gone.
  Date: 2026-07-01
- Decision: Add `streamly-core` to the `baikai-trace-otel-test` suite's
  `build-depends` (test-only; the library stanza is untouched).
  Rationale: the early-abort span test must drive `withTraceStream` with
  `Stream.take`/`Stream.toList`, which live in streamly-core. The `baikai` test suite
  already depends on it.
  Date: 2026-07-01
- Decision: Keep active trace states rooted with a `StablePtr` until `finalizeTrace`
  completes, then free the stable pointer.
  Rationale: abandoned stream cleanup is GC-driven. Without an independent root, the
  worker blocked in `readChan` can be considered unreachable and receive
  `BlockedIndefinitelyOnMVar` before the finalizer writes the synthetic terminal,
  causing the exact abort-pairing regression this plan is meant to fix. The stable
  root is internal, is released on normal terminal and abort finalization, and keeps
  public APIs unchanged.
  Date: 2026-07-03


## Outcomes & Retrospective

Implemented EP-1 completely. `Baikai.Trace` now captures sink exceptions in the drain
worker, always signals completion, warns once on stderr, emits 16-character
collision-resistant event ids, and records a synthetic `CallFailed` when a traced
stream is abandoned before a terminal event. `Baikai.Cost.Log` now captures worker
exceptions, always lets `closeCallLog` return, and reports dropped pending entries on
stderr. The OpenTelemetry sink now has an explicit comment for the deliberate
unknown-terminal drop, and regression tests cover throwing trace sinks, unwritable
call-log paths, 70,000 distinct event ids, core abort pairing, and abort span status.

Validation passed on 2026-07-03:

```text
cabal build all --enable-tests
exit 0

cabal test baikai baikai-trace-otel
baikai-trace-otel-test: all 3 tests passed
baikai-test: all 95 tests passed
exit 0
```


## Context and Orientation

baikai is a Haskell multi-provider LLM client library organized as a cabal
multi-package project (run `cabal build all` from the repo root). This plan concerns
its observability layer, which lives in three places:

- `baikai/src/Baikai/Trace/Event.hs` defines `TraceEvent`, a three-case sum:
  `CallStarted` (a provider call began), `CallFinished` (it returned a response), and
  `CallFailed` (it errored). Every case carries an `eventId :: Text` that correlates a
  start with its terminal within one process run.
- `baikai/src/Baikai/Trace/Sink.hs` defines `TraceSink`, a newtype over a streamly
  `Fold IO TraceEvent ()`. A "fold" here is streamly's consumer abstraction: a step
  function plus state that is fed one event at a time. Built-in sinks include
  `silent`, `stdoutSink`, and `fileSink` (which opens the file per write and therefore
  throws on every event if the path is unwritable).
- `baikai/src/Baikai/Trace.hs` is the bridge. `withTraceStream` wraps a streaming
  provider call: it creates a `TraceState` holding a `Chan (Maybe TraceEvent)` (the
  event queue; `Nothing` is the shutdown sentinel), a `done :: MVar ()` (the worker's
  completion signal), a `closed :: IORef Bool` (idempotence guard for cleanup),
  `sinkError`, `terminalSent`, and `stableRoot`. The stable root is a `StablePtr`
  kept until finalization completes so the worker blocked in `readChan` is not killed
  by the RTS before GC-driven abort cleanup can write the synthetic terminal. The
  function forks a worker thread with `forkIO` that drains the channel through the
  sink's fold, pushes `CallStarted` eagerly, and returns the provider's event stream
  wrapped in `Stream.mapM (traceEvent …)` — which pushes
  `CallFinished`/`CallFailed` when it sees the stream's terminal event — inside
  `Stream.finallyIO (finalizeTrace state eid start model)`. `finalizeTrace` writes a
  synthetic `CallFailed` when no terminal was sent, then writes the `Nothing` sentinel,
  waits for `done`, reports any captured sink error, and releases the stable root.
  `withTrace` is the blocking wrapper that folds this stream into a `Response`.

`baikai/src/Baikai/Cost/Log.hs` is a structurally identical worker for an opt-in JSONL
call log: `openCallLog` forks a worker that drains a `Chan (Maybe CallLogEntry)` to
disk via `withFile … AppendMode`, `appendEntry` is a non-blocking channel push, and
`closeCallLog` writes the sentinel and blocks in `takeMVar (done h)`. `withCallLog`
brackets open/close.

`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` adapts an OpenTelemetry
`Tracer` into a `TraceSink`. Its fold state is a `Map Text Otel.Span` keyed by
`eventId`: `CallStarted` opens a span and inserts it; a matching terminal closes the
span (setting status `Ok` or `Error msg`) and deletes the entry; a fold finalizer
(`Fold.rmapM`) closes any still-open spans at end-of-stream — but without setting any
status, so a span closed only by the finalizer reports status Unset.

The four findings this plan fixes, with their failure scenarios:

1. Worker death hangs the caller (review Theme 7.1, major; found independently by two
   reviewers). In `baikai/src/Baikai/Trace.hs` lines 117–124 the forked worker's body
   is the fold drain followed by `putMVar d ()` with no exception handling. If the
   sink's fold step throws — `fileSink` pointed at an unwritable path, an OTel
   exporter error — the exception kills the worker thread before `putMVar`. The next
   `cleanupTrace` (lines 194–200) then blocks forever in `takeMVar (s ^. #done)`.
   Because `cleanupTrace` runs on the caller's thread (via `Stream.finallyIO` or the
   terminal branch of `traceEvent`), the *request path* hangs; if the RTS's deadlock
   detector notices, the caller instead dies with `BlockedIndefinitelyOnMVar`. Either
   way a broken trace sink takes down the traced call.
2. Same disease in the call log. In `baikai/src/Baikai/Cost/Log.hs` lines 188–200 the
   worker wraps its whole drain loop (including `putMVar d ()`) in
   `withFile p AppendMode`. If the open fails (missing directory, permissions) or any
   write throws, the worker dies without filling `done`; `closeCallLog` hangs in
   `takeMVar`, and every entry pushed by `appendEntry` is silently dropped with no
   diagnostic.
3. Event-id collisions (Theme 7.2, minor). `newEventId` in
   `baikai/src/Baikai/Trace.hs` lines 334–341 builds
   `(eventBase .&. 0xFFFF) << 16 .|. (counter .&. 0xFFFF)` — only 16 bits of counter —
   so ids repeat every 65,536 calls within a process. The OpenTelemetry sink keys live
   spans by id, so on a collision `Map.insert` clobbers a live span (it leaks, never
   closed) and the next terminal closes the *wrong* span with the wrong status,
   latency, and usage.
4. No terminal on early abort (Theme 7.3, minor). If the consumer of
   `withTraceStream` stops early (`Stream.take`) or throws mid-stream, only
   `cleanupTrace` runs (line 138–140's `finallyIO`); no `CallFailed`/`CallFinished` is
   pushed. Sinks that correlate start/terminal never pair the `CallStarted`: a memory
   or file sink records a start with no end forever, and the OTel sink's span is
   closed only by the end-of-stream finalizer with no status (Unset — indistinguishable
   from an instrumentation bug in a tracing backend).

   A verified constraint shapes this fix: streamly's `Stream.finallyIO` (see
   `Streamly.Internal.Data.Stream.Exception` in the streamly source; baikai depends on
   streamly-core >= 0.3 && < 0.5) runs its action synchronously only when the wrapped
   stream stops normally or a *stream step* throws. When the consumer abandons the
   stream — precisely the abort case — the action runs from a garbage-collection
   finalizer hook. So the synthetic terminal is delivered *eventually* (at the next
   major GC after the stream becomes unreachable), not at the moment of abort. Tests
   must force a GC and poll.

Related but out of scope here: `closeCallLog` is not idempotent (a second call would
block), but its only in-tree caller is the single-shot `bracket` in `withCallLog`, and
the review did not flag it — leave it. The `Stream.hs` items from the review (Themes
1, 2, 10) belong to sibling plans (`docs/plans/38-…`, `docs/plans/39-…`); this plan
must not edit `baikai/src/Baikai/Stream.hs`.


## Plan of Work

### Milestone 1 — Workers that always signal, sink failures reported once

Scope: findings 1 and 2. At the end of this milestone, a throwing sink or unwritable
log path cannot hang or crash any caller: the worker always fills its `done` MVar, the
first exception is captured, and the close path prints one stderr warning. Two new
tests prove no-hang deterministically; they hang (and are failed by a `timeout` guard)
against the unfixed code.

In `baikai/src/Baikai/Trace.hs`:

- Extend `TraceState` with a field `sinkError :: !(IORef (Maybe SomeException))`,
  initialized to `Nothing` in `newTraceState`.
- In `withTraceStreamWith`, wrap the worker's drain in `try @SomeException`; on
  `Left e` write it to `sinkError`; then `putMVar d ()` unconditionally. Nothing in
  the program throws *to* this worker thread, so catching `SomeException` here cannot
  swallow a cancellation aimed at anyone.
- In the cleanup path, after `takeMVar (s ^. #done)`, read `sinkError` and, when
  present, print one line to stderr:
  `baikai: trace sink failed; trace events for this call were dropped: <displayException e>`.
- Re-add the `Control.Exception` import (the module currently carries a comment saying
  it is no longer needed — delete that comment) for `SomeException`, `displayException`,
  and `try`; add `readIORef`/`writeIORef` to the `Data.IORef` import and
  `import System.IO (hPutStrLn, stderr)`.
- Update the module haddock's "Per-call plumbing" paragraph: the worker never dies
  silently; sink exceptions are captured and warned about at cleanup.

In `baikai/src/Baikai/Cost/Log.hs`:

- Extend `CallLogHandle` with `workerError :: !(IORef (Maybe SomeException))`,
  created in `openCallLog` (in both the enabled and disabled branches, so the record
  is total) and passed to the worker.
- Restructure `worker` so `putMVar d ()` sits *outside* the `withFile` scope and runs
  unconditionally: `try @SomeException` around the whole open-and-drain body, record a
  `Left` into `workerError`, then `putMVar`. This covers both a failing open and a
  failing write.
- In `closeCallLog`, after `takeMVar (done h)`, read `workerError` and warn on stderr:
  `baikai: call log worker failed; pending entries were dropped: <displayException e>`.
- Imports: add `SomeException`, `displayException`, `try` to the `Control.Exception`
  import (which currently only brings `bracket`); `import Data.IORef (IORef, newIORef,
  readIORef, writeIORef)`; `import Control.Monad (forM_)`; extend the `System.IO`
  import with `hPutStrLn` and `stderr`. Update the module haddock similarly.

Tests: in `baikai/test/TraceSpec.hs` add a `throwingSink` (a `Fold.drainMapM` that
`throwIO`s a `providerError` on every event) and a test asserting
`timeout 5000000 (withTrace throwingSink …)` returns `Just resp` with
`stopReason = Stop` — the sink failure must not perturb the response. In
`baikai/test/CostSpec.hs` add a test that opens `withCallLog` on a path inside a
directory that does not exist, appends one entry, and asserts the whole bracket
returns within a 5-second `timeout`. Both suites already depend on everything needed
(`timeout` is in base's `System.Timeout`); `CostSpec` must change its import to
`CallLogEntry (..)` to construct an entry, and import `appendEntry` and
`Data.Time (getCurrentTime)`.

Acceptance: `cabal test baikai` passes; reverting only the `Trace.hs`/`Cost/Log.hs`
changes makes exactly the two new tests fail (by timeout or
`BlockedIndefinitelyOnMVar`), proving they pin the bug.

### Milestone 2 — Collision-free event ids

Scope: finding 3. At the end, `newEventId` produces 16-hex-character ids that cannot
repeat within a process before 2^32 calls, and a test generates 70,000 ids (past the
old 65,536 wrap point) and asserts they are pairwise distinct.

In `baikai/src/Baikai/Trace.hs`, rewrite the body of `newEventId` (keeping its
exported `IO Text` signature, and keeping `eventCounter`/`eventBase` as they are):

```haskell
newEventId :: IO Text
newEventId = do
  n <- atomicModifyIORef' eventCounter (\k -> (k + 1, k))
  let raw :: Word64
      raw =
        (fromIntegral eventBase .&. 0xFFFFFFFF) `unsafeShiftL` 32
          .|. (fromIntegral n .&. 0xFFFFFFFF)
      hex = showHex raw ""
      padded = replicate (16 - length hex) '0' <> hex
  pure (Text.pack padded)
```

Add `import Data.Word (Word64)`. The high 32 bits are the process-start POSIX seconds
(distinct across restarts more than a second apart until 2106), the low 32 bits the
per-process counter. The id is opaque `Text` everywhere it is consumed (`TraceEvent`
JSON, the OTel map key), so no other code changes. Update `newEventId`'s haddock to
state the format and the uniqueness guarantee.

Test: in `baikai/test/TraceSpec.hs`, `replicateM 70000 newEventId`, assert
`Set.size (Set.fromList ids) == 70000` and every id has `Text.length == 16`. This is
deterministic regardless of the global counter's starting value (uniqueness of a fresh
batch does not depend on where the counter starts). Against the old code the set
collapses to at most 65,536 elements, so the test fails before and passes after.

Acceptance: `cabal test baikai` passes including the new uniqueness test.

### Milestone 3 — Synthetic terminal on early abort; OTel drop documented

Scope: finding 4 plus the OpenTelemetry defensive-drop note. At the end, abandoning a
traced stream produces a synthetic `CallFailed` (same `eventId`, measured latency,
message `aborted: stream consumer stopped before the terminal event`) once the stream's
finalizer fires, every `CallStarted` is eventually paired, and the OTel sink closes the
abandoned call's span with status `Error`. The unknown-eventId drop in the OTel sink is
documented in place as deliberate.

In `baikai/src/Baikai/Trace.hs`:

- Extend `TraceState` with `terminalSent :: !(IORef Bool)` (initialized `False`).
- Extend `TraceState` with a `stableRoot :: !(IORef (Maybe (StablePtr TraceState)))`
  and initialize it in `newTraceState` by allocating a `StablePtr` to the constructed
  state. `finalizeTrace` releases it through `releaseStableRoot` after the worker has
  signalled `done`.
- Replace `cleanupTrace :: TraceState -> IO ()` with
  `finalizeTrace :: TraceState -> Text -> UTCTime -> Model -> IO ()` (the extra
  arguments — eventId, call start time, model — are all in scope at both call sites).
  Behavior: atomically claim `closed` exactly as today; if not already closed, read
  `terminalSent`, and when it is `False` push the synthetic `CallFailed` built from the
  arguments (`latencyMs = millisBetween start now`) before the `Nothing` sentinel; then
  sentinel, `takeMVar`, and the M1 stderr report.
- In `traceEvent`'s `EventDone` and `EventError` branches: after writing the real
  terminal event to the channel, `writeIORef (state ^. #terminalSent) True`, then call
  `finalizeTrace state eid start m` (which will skip the synthetic because the flag is
  set).
- In `withTraceStreamWith`, the `Stream.finallyIO` action becomes
  `finalizeTrace state eid start m`.
- Update the module haddock: on a normal terminal the finalizer is a no-op (the
  `closed` guard); on abort it emits the synthetic `CallFailed`, and — per the
  Decision Log — this delivery is GC-driven, hence eventual.

In `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`, add a comment above the
two `Nothing -> pure m` branches in `stepEvent` (finding: lines 108–124 silently drop
terminals for unknown eventIds): each `withTraceStream` call drives a fresh fold
instance, so a terminal without a live span is unreachable in normal operation; the
branch exists so hand-fed or replayed event streams cannot crash the sink, and it drops
silently by design. No behavior change.

Tests:

- `baikai/test/TraceSpec.hs`: register a canned-success provider, drive
  `Stream.toList (Stream.take 1 (withTraceStream sink …))` against the in-memory sink
  (the lifted stub stream emits `EventStart`, three text-block events, `EventDone`, so
  `take 1` abandons it before the terminal), then poll with a helper that calls
  `System.Mem.performMajorGC`, reads the sink's `TVar`, and sleeps 50 ms per iteration
  for at most 100 iterations (~5 s). Assert the recorded sequence is exactly
  `[CallStarted, CallFailed]` with matching eventIds and an `errorMessage` containing
  `aborted`. New imports: `Streamly.Data.Stream qualified as Stream`, `withTraceStream`
  from `Baikai.Trace`, `System.Mem (performMajorGC)`,
  `Control.Concurrent (threadDelay)`.
- `baikai-trace-otel/test/Main.hs`: same drive against `otelSink` with the in-memory
  exporter; poll (same GC-plus-sleep helper, using the exporter's span getter) until
  one span appears; assert its status is `Otel.Error _`. Before the fix this span is
  closed by the fold finalizer with status Unset, so the assertion fails before and
  passes after. This requires `Stream.take`/`Stream.toList`: add `streamly-core >=0.3
  && <0.5` to the `build-depends` of the `test-suite baikai-trace-otel-test` stanza in
  `baikai-trace-otel/baikai-trace-otel.cabal` (test-only dependency).

Acceptance: `cabal test baikai baikai-trace-otel` passes; the two abort tests fail
against the unfixed `Trace.hs`.


## Concrete Steps

All commands run from the repository root, `/…/baikai` (the directory containing
`cabal.project`). Plain `cabal` works in this environment.

1. Baseline (optional but recommended): confirm the tree builds and tests pass before
   editing.

   ```bash
   cabal build all --enable-tests
   cabal test baikai baikai-trace-otel
   ```

2. Milestone 1 edits. In `baikai/src/Baikai/Trace.hs`, the worker fork inside
   `withTraceStreamWith` becomes:

   ```haskell
   _ <-
     forkIO $ do
       let stepDrain () = do
             msg <- readChan c
             pure (fmap (\e -> (e, ())) msg)
       r <-
         try @SomeException
           ( Stream.unfoldrM stepDrain ()
               & Stream.fold sinkFold
           )
       case r of
         Left e -> writeIORef (state ^. #sinkError) (Just e)
         Right () -> pure ()
       putMVar d ()
   ```

   with `TraceState` gaining `sinkError :: !(IORef (Maybe SomeException))` and a
   reporting helper used from the cleanup path:

   ```haskell
   reportSinkError :: TraceState -> IO ()
   reportSinkError s = do
     merr <- readIORef (s ^. #sinkError)
     forM_ merr $ \e ->
       hPutStrLn
         stderr
         ("baikai: trace sink failed; trace events for this call were dropped: "
            <> displayException e)
   ```

   In `baikai/src/Baikai/Cost/Log.hs`, the worker becomes:

   ```haskell
   worker ::
     FilePath ->
     Chan (Maybe CallLogEntry) ->
     MVar () ->
     IORef (Maybe SomeException) ->
     IO ()
   worker p ch d errRef = do
     r <- try @SomeException drainToFile
     case r of
       Left e -> writeIORef errRef (Just e)
       Right () -> pure ()
     putMVar d ()
     where
       drainToFile =
         withFile p AppendMode $ \fh -> do
           hSetBuffering fh LineBuffering
           let step :: () -> IO (Maybe (CallLogEntry, ()))
               step () = do
                 msg <- readChan ch
                 case msg of
                   Nothing -> pure Nothing
                   Just e -> pure (Just (e, ()))
           Stream.unfoldrM step ()
             & Stream.fold (Fold.drainMapM (writeEntry fh))
       writeEntry fh entry =
         BSL.hPut fh (Aeson.encode entry <> "\n")
   ```

   and `closeCallLog` gains, after its `takeMVar (done h)`:

   ```haskell
   merr <- readIORef (workerError h)
   forM_ merr $ \e ->
     hPutStrLn
       stderr
       ("baikai: call log worker failed; pending entries were dropped: "
          <> displayException e)
   ```

3. Milestone 1 tests. In `baikai/test/TraceSpec.hs` (add the new trees to the `tests`
   group):

   ```haskell
   throwingSink :: TraceSink
   throwingSink =
     TraceSink (Fold.drainMapM (\_ -> throwIO (providerError "sink exploded")))

   throwingSinkTest :: TestTree
   throwingSinkTest =
     testCase "a throwing sink cannot hang withTrace" $ do
       let a = Custom "baikai-trace-throwing-sink"
       registerOk a
       r <- timeout 5000000 (withTrace throwingSink (stubModel a) stubContext stubOptions)
       case r of
         Nothing -> assertFailure "withTrace hung on a throwing sink"
         Just resp -> do
           let AssistantPayload {stopReason = sr} = resp ^. #message
           sr @?= Stop
   ```

   In `baikai/test/CostSpec.hs` (inside `callLogTests`; switch the import to
   `CallLogEntry (..)`, and import `appendEntry`, `System.Timeout (timeout)`, and
   `Data.Time (getCurrentTime)`):

   ```haskell
   testCase "closeCallLog returns even when the log path is unwritable" $ do
     tmp <- getTemporaryDirectory
     let missing = tmp </> "baikai-costspec-no-such-dir" </> "entries.jsonl"
         cfg = CallLogConfig {path = missing, enabled = True}
     now <- getCurrentTime
     let entry =
           CallLogEntry
             { timestamp = now,
               provider = "test",
               model = "m",
               inputTokens = Nothing,
               outputTokens = Nothing,
               cachedInputTokens = Nothing,
               reasoningTokens = Nothing,
               usd = Nothing,
               latencyMs = 0,
               promptSummary = ""
             }
     r <- timeout 5000000 (withCallLog cfg (\h -> appendEntry h entry))
     r @?= Just ()
   ```

4. Milestone 2: apply the `newEventId` rewrite shown in Plan of Work and add to
   `baikai/test/TraceSpec.hs` (imports: `Control.Monad (replicateM)`,
   `Data.Set qualified as Set`; `newEventId` is already exported by `Baikai.Trace`):

   ```haskell
   eventIdUniquenessTest :: TestTree
   eventIdUniquenessTest =
     testCase "newEventId yields 70000 distinct 16-char ids" $ do
       ids <- replicateM 70000 newEventId
       Set.size (Set.fromList ids) @?= 70000
       assertBool "every id is 16 chars" (all ((== 16) . Text.length) ids)
   ```

5. Milestone 3: apply the `terminalSent`/`finalizeTrace` restructure shown in Plan of
   Work. The finalizer:

   ```haskell
   finalizeTrace :: TraceState -> Text -> UTCTime -> Model -> IO ()
   finalizeTrace s eid start m = do
     alreadyClosed <-
       atomicModifyIORef' (s ^. #closed) (\b -> (True, b))
     unless alreadyClosed $ do
       sent <- readIORef (s ^. #terminalSent)
       unless sent $ do
         now <- getCurrentTime
         writeChan (s ^. #chan) $
           Just
             CallFailed
               { eventId = eid,
                 timestamp = now,
                 provider = m ^. #provider,
                 model = m ^. #modelId,
                 latencyMs = millisBetween start now,
                 errorMessage = "aborted: stream consumer stopped before the terminal event"
               }
       writeChan (s ^. #chan) Nothing
       takeMVar (s ^. #done)
       reportSinkError s
       releaseStableRoot s
   ```

   Abort test in `baikai/test/TraceSpec.hs`:

   ```haskell
   earlyAbortTest :: TestTree
   earlyAbortTest =
     testCase "early abort pushes a synthetic CallFailed" $ do
       let a = Custom "baikai-trace-abort"
       registerOk a
       (ref, sink) <- memorySink
       evs <-
         Stream.toList
           (Stream.take 1 (withTraceStream sink (stubModel a) stubContext stubOptions))
       length evs @?= 1
       events <- awaitEvents ref 2
       case events of
         [s@CallStarted {}, f@CallFailed {errorMessage = msg}] -> do
           (s ^. #eventId :: Text) @?= (f ^. #eventId :: Text)
           assertBool
             ("expected abort message, got: " <> show msg)
             ("aborted" `Text.isInfixOf` msg)
         _ -> assertFailure ("unexpected event sequence: " <> show events)

   -- The trace finalizer on an abandoned stream runs from streamly's GC
   -- hook, so force major GCs and poll with a ~5 s deadline.
   awaitEvents :: TVar [TraceEvent] -> Int -> IO [TraceEvent]
   awaitEvents ref n = go (100 :: Int)
     where
       go 0 = do
         evs <- readTVarIO ref
         assertFailure ("timed out waiting for trace events; got: " <> show (reverse evs))
       go k = do
         performMajorGC
         evs <- readTVarIO ref
         if length evs >= n
           then pure (reverse evs)
           else threadDelay 50000 >> go (k - 1)
   ```

   In `baikai-trace-otel/test/Main.hs`, an analogous `abortSpanTest` drives the same
   `take 1` shape against `otelSink`, uses an `awaitSpans` twin of `awaitEvents` over
   the in-memory exporter's getter, and asserts the single recorded span's
   `Otel.hotStatus` is `Otel.Error _`. Register it in the `testGroup`. Add
   `streamly-core >=0.3 && <0.5` to the test-suite stanza of
   `baikai-trace-otel/baikai-trace-otel.cabal`.

6. Validate after each milestone and at the end:

   ```bash
   cabal build all --enable-tests
   cabal test baikai baikai-trace-otel
   ```

   Expected shape of a passing run (counts will differ):

   ```text
   Test suite baikai-test: RUNNING...
   ...
   Baikai.Trace
     a throwing sink cannot hang withTrace:            OK
     newEventId yields 70000 distinct 16-char ids:     OK
     early abort pushes a synthetic CallFailed:        OK
   ...
   Test suite baikai-test: PASS
   Test suite baikai-trace-otel-test: PASS
   ```

7. Update the living sections of this plan and tick the EP-1 boxes in the
   MasterPlan's Progress list
   (`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`).
   Commit per milestone with conventional-commit messages, e.g.
   `fix(trace): capture sink exceptions so workers always signal done`.


## Validation and Acceptance

Run, from the repo root:

```bash
cabal build all --enable-tests
cabal test baikai baikai-trace-otel
```

Both commands must exit 0 with all suites reporting PASS. Beyond compilation, the
change is demonstrated by behavior:

- Throwing sink, no hang: the `TraceSpec` test wraps `withTrace` with a throwing sink
  in `timeout 5000000` and requires a `Just` result carrying `stopReason = Stop`.
  Against the unfixed `Trace.hs` this test fails — either the timeout fires
  (`Nothing`) or the RTS raises `BlockedIndefinitelyOnMVar`. You will also see one
  `baikai: trace sink failed; …` line on the test run's stderr, which is the new
  warning working.
- Unwritable log path, no hang: the `CostSpec` test requires
  `timeout 5000000 (withCallLog …)` to return `Just ()`; unfixed, `closeCallLog`
  hangs the bracket and the test fails. A `baikai: call log worker failed; …` stderr
  line accompanies the pass.
- Id uniqueness: 70,000 fresh ids form a 70,000-element set of 16-character strings.
  Unfixed, the counter wraps at 65,536 and the set is smaller, failing the test.
- Abort pairing: after `Stream.take 1` abandons a traced stream, the memory sink ends
  up with exactly `[CallStarted, CallFailed]` sharing one `eventId`, the failure
  message containing `aborted`; the OTel in-memory exporter ends up with exactly one
  span whose status is `Error`. Unfixed, the memory sink holds only `CallStarted`
  forever and the OTel span's status is Unset, failing both tests.

To watch a failing-before/passing-after demonstration explicitly, stash the source
changes but keep the test changes (`git stash push -- baikai/src baikai-trace-otel/src
baikai-trace-otel/baikai-trace-otel.cabal` will not split cleanly because of the cabal
test dep — simpler: check out the tests-only state mid-review, or temporarily revert
the `Trace.hs` hunks) and run `cabal test baikai`; the four new tests fail, everything
else passes.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build/test cycle; all are safe to repeat.
No migrations, no destructive operations, no generated files. The milestones are
independent: M1, M2, and M3 each stand alone against the baseline tree, so if one
milestone goes wrong you can `git checkout -- <file>` its hunks without disturbing the
others (M3 builds on M1's `reportSinkError` helper and `sinkError` field; if you must
land M3 first for some reason, inline a no-op in its place — but the intended order is
M1, M2, M3).

If a new test hangs during development (the exact bug this plan fixes), the `timeout`
guards and the bounded poll loops turn the hang into a test failure within ~5 seconds;
`cabal test` will not wedge. The GC-driven abort tests are the only timing-sensitive
pieces: they force `performMajorGC` up to 100 times at 50 ms intervals. If they ever
flake on a loaded machine, raise the iteration count — do not remove the GC forcing,
because without it streamly's finalizer hook may not run within the test's lifetime.
The 70,000-id test allocates ~70k small `Text` values and runs in well under a second;
it is safe to re-run indefinitely (the global counter only grows, and uniqueness of a
fresh batch never depends on its starting value).


## Interfaces and Dependencies

No new library dependencies. One test-only cabal change: `streamly-core >=0.3 && <0.5`
added to `build-depends` of `test-suite baikai-trace-otel-test` in
`baikai-trace-otel/baikai-trace-otel.cabal`. Everything else uses base
(`Control.Exception`, `Data.IORef`, `System.Timeout`, `System.Mem`, `Data.Word`),
containers (`Data.Set`, already a test dep of `baikai`), and the streamly-core already
in scope.

Public API is unchanged in name and type. At the end of the plan these signatures hold:

- `Baikai.Trace.newEventId :: IO Text` (in `baikai/src/Baikai/Trace.hs`) — now
  documented to return 16 lowercase hex characters, unique within a process for 2^32
  calls.
- `Baikai.Trace.withTrace`, `withTraceWith`, `withTraceStream`, `withTraceStreamWith` —
  unchanged types; new documented semantics: sink exceptions never propagate, one
  stderr warning at cleanup, synthetic `CallFailed` on abort (GC-eventual).
- `Baikai.Cost.Log.openCallLog / closeCallLog / withCallLog / appendEntry` — unchanged
  types; `closeCallLog` now always returns and warns on stderr if the worker died.

Internal (non-exported) shapes that must exist at the end:

- `TraceState` in `baikai/src/Baikai/Trace.hs` with fields `chan`, `done`, `closed`,
  `sinkError :: IORef (Maybe SomeException)`, `terminalSent :: IORef Bool`, and
  `stableRoot :: IORef (Maybe (StablePtr TraceState))`.
- `finalizeTrace :: TraceState -> Text -> UTCTime -> Model -> IO ()` replacing
  `cleanupTrace`, plus `reportSinkError :: TraceState -> IO ()` and
  `releaseStableRoot :: TraceState -> IO ()`.
- `CallLogHandle` in `baikai/src/Baikai/Cost/Log.hs` with the additional field
  `workerError :: IORef (Maybe SomeException)`; `worker` takes that `IORef` as a
  fourth argument.

Per the repo's field-naming rule, none of the new record fields carry prefixes.

Sibling plans that later touch adjacent code: `docs/plans/38-…` and `docs/plans/39-…`
rewrite parts of `baikai/src/Baikai/Stream.hs`; this plan deliberately does not touch
that module, and nothing here constrains them beyond the existing "exactly one terminal
event" contract, which the synthetic trace terminal complements (it is a *trace* event,
not an `AssistantMessageEvent`).
