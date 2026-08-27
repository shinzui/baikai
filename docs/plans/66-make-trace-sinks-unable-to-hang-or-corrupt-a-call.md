---
id: 66
slug: make-trace-sinks-unable-to-hang-or-corrupt-a-call
title: "Make trace sinks unable to hang or corrupt a call"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Make trace sinks unable to hang or corrupt a call

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

A trace sink is the thing baikai hands its call-lifecycle events to: `CallStarted` when
a provider call begins, `CallEvidence` when the caller asked for an evidence record, and
exactly one `CallFinished` or `CallFailed` when the call ends. The July hardening
(`docs/plans/34-harden-trace-and-call-log-workers.md`) made a sink that *throws*
harmless to the call it observes. The August review
(`docs/reviews/correctness-and-api-review-follow-up.md`, findings D.4, D.5, D.6, D.9,
two minor items, and the Theme 7 residual) found what remains: a sink that *blocks*
still hangs the call forever and swallows the first attempt to cancel it; an
asynchronous exception in a window a few instructions wide makes the trace record a
second evidence record and a contradictory second terminal; one throwing `multiSink`
member silences its siblings and skips their cleanup, so an OpenTelemetry span paired
with an unwritable file sink is never ended; and the OpenTelemetry sink cannot nest a
call under the caller's own span.

After this plan, `withTrace` and `withTraceStream` return within a bounded time no
matter what a sink does: a sink that blocks forever costs the call at most one second,
after which the call proceeds, one stderr line reports the stall, and a caller who
required evidence gets a failed call rather than an answer whose record was never
confirmed. The evidence record and the terminal are pushed exactly once under any
asynchronous exception. `multiSink` delivers every event to every member that can take
it, runs every member's cleanup, and names failed members by index. `otelSinkWith`
accepts a parent `Context`. The abort-terminal timing — a synthetic terminal delivered
from a garbage-collection hook, not at the moment of abort — is stated in the user
guide, the capability record and the module documentation, with the pattern callers use
when they need the record before their process exits. `TraceSpec` pins that
`CallEvidence` precedes the terminal, which the capability record already claims. The
`baikai`, `baikai-trace-otel` and `baikai-effectful` suites show it working: the new
tests hang (and are failed by `timeout` guards), record duplicates, or leave a span
un-ended against the unfixed code, and pass after the fix.

This is EP-9 of the MasterPlan at
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`. It
soft-depends on EP-8 (`docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md`),
which owns the evidence semantics in `baikai/src/Baikai/Trace.hs` — what is pushed and
when strict mode fails a call — while this plan owns the worker protocol,
`terminalSent`, `finalizeTrace`'s blocking, `multiSink`, the OpenTelemetry sink options
and the abort-delivery documentation. Land it after EP-8, or rebase and record the
rebase in both Decision Logs.


## Progress

- [x] M1: `commitTerminal` helper; the three terminal-path writes run under `uninterruptibleMask_` with `terminalSent` set first, on both terminal branches and the abort path.
- [x] M1: `terminalPathAtomicityTest` and `throwToAroundTerminalTest` in `baikai/test/TraceSpec.hs`; widened-window demonstration recorded in Surprises & Discoveries.
- [x] M2: `sinkDrainBoundMicros`, `awaitWorker`, `TraceSinkStalled`; `finalizeTrace` waits at most one second, abandons the worker, records the stall, releases the `StablePtr` root; `reportSinkError` prints the stall line.
- [x] M2: `multiSink` rebuilt as one drain thread per member with an aggregate `TraceSinkFailure`.
- [x] M2: `closeCallLog` idempotent; `appendEntry` after close is a no-op.
- [x] M2: blocking-sink (best-effort and strict), throwing/blocking `multiSink` member, strict member-naming, and `closeCallLog`-twice tests in `TraceSpec.hs`, `CostSpec.hs`, `baikai-trace-otel/test/Main.hs`.
- [x] M3: `OtelSinkOptions.parentContext`; `strengthText` replaced by `renderEvidenceStrength`; `parentContextTest` and the strength-spelling assertion.
- [x] M3: `baikai-effectful.cabal` no longer depends on `streamly`.
- [ ] M4: `exactlyOneEvidence` asserts `CallEvidence` precedes the terminal.
- [ ] M4: abort-delivery semantics in `docs/capabilities/call-tracing.md`, `docs/user/model-call-evidence.md`, `Trace.hs`'s module doc, `Trace/Event.hs`'s Haddock and the otel test comment; `docs/capabilities/opentelemetry-span-export.md` gains the parent-context limit; `docs/capabilities/log.md` entry.
- [ ] M4: ADR `docs/adr/0006-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md` (next free number at implementation time).
- [ ] `CHANGELOG.md` entries under `[Unreleased]` for `baikai`, `baikai-trace-otel`, `baikai-effectful`.
- [ ] Keyless test gate and `okf validate docs/capabilities` pass; EP-9 boxes ticked in the MasterPlan.


## Surprises & Discoveries

Planning-time discoveries, each verified in the source on disk (dependency checkouts
located with `mori registry search streamly-core` and
`mori registry search hs-opentelemetry-api`):

- The local streamly corpus is `streamly-core 0.4.0` (unreleased) and its
  `Streamly.Internal.Data.Fold.Type` carries a commented-out redesign of the fold
  `Step` type (`Consume | Produce | Stop` replacing `Partial | Done`). Per-member
  isolation built on the internal `Fold` constructor would be at the mercy of that
  change inside baikai's `>=0.3 && <0.5` bound, so `multiSink` is rebuilt from the
  public API only, with one drain thread per member. (2026-08-27)
- streamly's `gbracket` (under `finallyIO`, in `Streamly/Internal/Data/Stream/Exception.hs`)
  wraps every stream step in `try` for `SomeException`, so an asynchronous exception
  thrown *at the consumer while it is inside a step* runs the cleanup synchronously
  (via `clearingIOFinalizer`, under `mask_`) and rethrows; only abandonment *between*
  steps leaves cleanup to the GC hook. Hence the `throwTo` tests in M1 see the
  finaliser promptly while the `Stream.take 1` abort tests must force
  `performMajorGC`. (2026-08-27)
- `baikai/baikai.cabal`'s library stanza also depends on `streamly` while nothing
  under `baikai/src` imports a module outside `streamly-core`. The review flagged only
  `baikai-effectful`; the `baikai` twin is left for EP-10, which owns release
  metadata. (2026-08-27)
- `test-suite baikai-test` has no `-threaded`; `System.Timeout.timeout`, `throwTo` and
  blocking `MVar` operations are green-thread operations and work on the non-threaded
  runtime, so the new tests need no cabal change. (2026-08-27)

Implementation-time:

- __The widened-window demonstration, run.__ With `commitTerminal`'s body written in
  the pre-fix order and unmasked — `pushEvidence`, `writeChan` the terminal,
  `threadDelay 100000`, `writeIORef terminalSent True` —
  `throwToAroundTerminalTest` fails on its first iteration:

  ```text
  baikai
    Baikai.Trace
      fifty exceptions aimed at the terminal push never duplicate terminal or evidence: FAIL (0.21s)
        test/TraceSpec.hs:302:
        expected: 1
         but got: 2
  ```

  Line 302 is the `CallEvidence` count: the finaliser saw `terminalSent = False` and
  pushed a second record and an `aborted` `CallFailed` after the real `CallFinished`.
  The same `threadDelay 100000` moved *inside* the fixed `uninterruptibleMask_` block
  is harmless — the fifty iterations pass in 15.52s against 10.18s without it — which
  is the point of the mask: the delay is now a window the exception cannot land in.
  (2026-08-27)
- __EP-8 did not adopt the "not confirmed written" wording, so this plan made the
  edit__, as its Decision Log said it would. `Build.sinkFailureError` now reads "so its
  record was not confirmed written". No test asserted the old phrase; the two strict
  sink cases match on `trace sink failed`, which is unchanged. Recorded in both
  Decision Logs. (2026-08-27)
- __The pre-fix demonstrations for M2, run.__ With `awaitWorker` reduced to an
  unbounded `readMVar`, `blockingSinkTest` reports `withTrace hung on a blocking sink`
  after its two-second guard. With `multiSink` restored to the `Fold.tee` fold,
  `multiSinkThrowingMemberTest` and `multiSinkBlockingMemberTest` both fail with
  `the sibling missed events: []` — the sibling received /nothing/, not merely a
  truncated sequence — `multiSinkStrictNamesMemberTest` gets an error naming no member,
  and the OpenTelemetry sibling test fails with `exactly one span recorded expected: 1
  but got: 0`: under `tee` the span was opened and never ended, so the in-memory
  exporter never saw it at all. The review said the span "is never ended"; the visible
  consequence is that it is never exported either. (2026-08-27)
- __A `TraceSinkStalled` needs its own stderr line, not `Build.onSinkFailure`'s.__
  That line says the call's trace events "were dropped", which is the one thing an
  abandoned worker's events were not — they are still queued behind the blocked sink
  and may yet be delivered. `reportSinkError` now branches on `fromException` and
  prints the stall's own text; the fatality decision below it is identical for both.
  (2026-08-27)


## Decision Log

- Decision: The terminal-path writes — `terminalSent := True`, the `CallEvidence` push,
  the terminal push — run inside one `uninterruptibleMask_` block with the flag set
  *first*, through a helper `commitTerminal` used by both terminal branches of
  `traceEvent` and by the abort branch of `finalizeTrace`.
  Rationale: the defect (D.4) is an asynchronous exception between the terminal push
  and the flag write, after which the finaliser sees `sent = False` and pushes a second
  evidence record and an `aborted` `CallFailed` after a `CallFinished`. Plain `mask_`
  closes the window everywhere except inside `writeChan`, whose internal `takeMVar` on
  the channel's write lock is interruptible; it never blocks in practice (the worker
  only reads), but "never in practice" is what this fix exists to remove. The writes
  are non-blocking pushes to an unbounded `Chan` and one `IORef` write, so the
  uninterruptible block holds for microseconds and cannot become an un-cancellable
  hang. The flag first means a synchronous failure inside the block yields a missing
  terminal — which the abort machinery tolerates — rather than a duplicated one. The
  wait for the worker is outside the block.
  Date: 2026-08-27
- Decision: `finalizeTrace` keeps waiting for the worker on the calling thread but
  bounds the wait: `timeout sinkDrainBoundMicros (readMVar done)` with
  `sinkDrainBoundMicros = 1_000_000` (one second), a module constant in `Trace.hs`,
  not a public option. On expiry the worker is abandoned (not killed), a
  `TraceSinkStalled` exception is recorded in `sinkError` if nothing is there yet,
  `reportSinkError` prints one stderr line, and the `StablePtr` root is released as on
  the normal path.
  Rationale: moving finalisation off the calling thread was rejected because every
  existing test, `runRequestWith` and every documented usage rely on "when `withTrace`
  returns, the sink has processed this call's events" (the file line is on disk, the
  memory sink's `TVar` is populated). Bounding the wait keeps that contract for every
  healthy sink and turns a pathological one into a one-second cost plus a report. One
  second: a call produces at most four events, the wait covers only their delivery and
  the sink's end-of-stream action, and a sink whose per-call latency approaches a
  second is mis-configured for per-call tracing (an OpenTelemetry exporter belongs
  behind the non-blocking batch processor). Not configurable because EP-10 owns the
  surface; if the bound proves tight, the follow-up is an `Options` field, named for
  EP-10 as `traceDrainTimeoutMs`. Abandoned rather than killed because killing would
  abort the sink's fold mid-step and lose its `final`; see `awaitWorker`'s Haddock.
  Date: 2026-08-27
- Decision: A strict caller (`EvidenceRequired _`) whose wait expires gets a failed
  call, through the existing mechanism: `TraceSinkStalled` sits in `sinkError` as a
  `SomeException`, so EP-8's `Build.sinkFailureIsFatal` and `Build.sinkFailureError`
  apply unchanged and `failTerminal` rewrites the terminal as for a throwing sink. The
  message is `sinkFailureError`'s prefix plus `TraceSinkStalled`'s text: "the trace
  sink did not confirm delivery within 1000 ms; its worker was abandoned, and events
  already queued may still be delivered later".
  Rationale: strict mode means a record exists (EP-8's principle); a record whose
  delivery was not confirmed before the call returned is not one the caller can
  account for. Coordination with EP-8: `sinkFailureError`'s wording "so its record was
  not written" is inaccurate for a stall; EP-8 is asked to word it "not confirmed
  written", failing which this plan makes the edit and records it in both Decision Logs.
  Date: 2026-08-27
- Decision: `multiSink` runs each member on its own drain thread behind its own
  unbounded `Chan`; the outer step fans one event to every member and never blocks;
  the outer `final` sends every member the sentinel, waits for every outcome, and
  throws one aggregate `TraceSinkFailure` naming each failed member by zero-based
  index when any failed. The member wait is unbounded; the drain bound covers it.
  Rationale: `Fold.tee` (streamly `teeWith`, verified in
  `Streamly/Internal/Data/Fold/Type.hs`) runs the left step then the right and lets
  either's exception escape, so one throwing member stops delivery to all and skips
  every `final` (D.6). Isolating members inside one thread would need the internal
  `Fold` constructor (see Surprises) and would still let a *blocking* member starve
  its siblings, which M2's title forbids. Accepted caveat: if one member blocks forever
  the aggregate is never thrown, so a *throwing* sibling's message does not reach
  stderr in that combination; the stall line names the actionable fact, and the
  sibling's events were delivered regardless. `sinkError` reports several failures
  through `TraceSinkFailure`'s `displayException` — `2 of 3 member sinks failed:
  member 0: <message>; member 2: <message>` — and neither `TraceSinkFailure` nor
  `TraceSinkStalled` is exported, because both render as text and an exported type is
  a name EP-10 must freeze.
  Date: 2026-08-27
- Decision: `OtelSinkOptions` gains `parentContext :: !(Maybe Context)`
  (`OpenTelemetry.Context.Context`), default `Nothing`, passed to `Otel.createSpan` in
  place of the hard-coded `Context.empty`. It is a value fixed at sink construction.
  Rationale: hs-opentelemetry's `createSpan` takes its parent from the `Context`
  argument (verified in `api/src/OpenTelemetry/Trace/Core.hs`); the thread-local
  `getContext` cannot help because the fold runs on the trace worker thread, and a
  per-call `IO Context` option was rejected for the same reason. Callers capture
  `ctx <- getContext` (or `Context.insertSpan mySpan Context.empty`) on their own
  thread and build the sink per request. Adding a field to a record whose constructor
  is exported breaks positional construction; the documented path is a record update
  on `defaultOtelSinkOptions`, and EP-10 is told.
  Date: 2026-08-27
- Decision: `strengthText` is deleted in favour of `Ev.renderEvidenceStrength`, the
  function the JSON encoding uses (`baikai/src/Baikai/Evidence.hs:518-526`); and
  `baikai-effectful.cabal` drops `streamly` from both stanzas, keeping `streamly-core`.
  Rationale: a second spelling can drift; `Baikai.Effectful` and `test/StubProvider.hs`
  import only `Streamly.Data.Fold` and `Streamly.Data.Stream`, both `streamly-core`
  modules.
  Date: 2026-08-27
- Decision: The worker's `try` stays `try @SomeException`, and the per-member `try` in
  `multiSink` matches it.
  Rationale: plan 34's reason holds — nothing throws *to* a worker, so the catch cannot
  swallow a cancellation aimed at anyone — and this plan adds one: an abandoned worker
  whose sink blocks on something that later becomes unreachable receives
  `BlockedIndefinitelyOnMVar`, and catching it lets the worker record the cause, fill
  `done` and exit instead of dying with the runtime's own message. A sync-only catch
  with `finally` for the `putMVar` would fill `done` but lose the recorded cause.
  Date: 2026-08-27
- Decision: `closeCallLog` becomes idempotent through `closed :: IORef Bool` on
  `CallLogHandle` claimed with `atomicModifyIORef'`; `appendEntry` after close returns
  without enqueuing. The close wait stays unbounded.
  Rationale: the Theme 7 residual asks for a decision; the fix is a few lines and
  removes a hang a future second caller would hit. The wait is not bounded because
  the call log's purpose is durability, its close runs once per process rather than
  once per call, and its writer is a local file the operator chose, not a third-party
  fold.
  Date: 2026-08-27
- Decision: Synthetic-terminal delivery on consumer abort is documented as GC-driven
  and not guaranteed before process exit in `docs/capabilities/call-tracing.md`,
  `docs/user/model-call-evidence.md` and the `Baikai.Trace` module doc, with the
  recommended patterns; that fact, the `StablePtr` root invariant and the
  bounded-wait rule are promoted to
  `docs/adr/0006-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md`.
  Rationale: "no plan may rely on `finallyIO` for prompt cleanup on early stop" is a
  durable constraint that lives only in plan 34's Decision Log and masterplan 7's
  Surprises. EP-4 may change the provider stream's abort path; this plan says how to
  verify after EP-4 rather than predicting.
  Date: 2026-08-27
- Decision: D.4 is pinned by a deterministic test (exception delivered while the
  consumer waits for a parked sink; the finaliser's second run must duplicate nothing)
  and a fifty-iteration test (the sink throws at the consumer the instant
  `CallEvidence` arrives), plus a widened-window demonstration — `threadDelay` between
  the terminal push and the flag write in the unfixed code fails the second test every
  iteration, while the same delay inside the fixed block is harmless.
  Rationale: no scheduling hook lands an exception deterministically in a window a
  few instructions wide, and a production hook for a test is worse than the bug.
  Date: 2026-08-27
- Decision: Accepted caveats carried forward from plan 34, restated so the reader
  does not need it: the synthetic abort terminal is delivered when streamly's GC hook
  fires, not at abort time; each active `TraceState` is rooted by a `StablePtr` until
  finalisation completes so the worker blocked in `readChan` is not reaped early. Both
  remain true. `closeCallLog`'s non-idempotence, which plan 34 left, is fixed here.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

baikai is a Haskell multi-package cabal project (`cabal build all` from the repository
root, the directory containing `cabal.project`). This plan concerns its observability
layer. The terms below are used throughout.

A **trace sink** (`TraceSink`, `baikai/src/Baikai/Trace/Sink.hs`) is a newtype over a
streamly **fold**, `Fold IO TraceEvent ()`: an initial action producing a state, a step
function fed one input at a time, and a final action run at end of input. A **tee**
(`Fold.tee`) feeds one input to two folds. Four sinks ship: `silent`, `stdoutSink`,
`fileSink` (opens the file per write, so it throws on every event if the path is
unwritable) and `multiSink`, today a `Fold.tee` folded across a list. A **trace event**
(`TraceEvent`, `baikai/src/Baikai/Trace/Event.hs`) is one of `CallStarted`,
`CallFinished`, `CallFailed` or `CallEvidence`, each carrying an `eventId` that
correlates the four kinds of one call.

`baikai/src/Baikai/Trace.hs` bridges a provider call and a sink. `withTraceStreamWith`
(lines 115–161 at HEAD `5411947`) creates a per-call `TraceState`: a
`Chan (Maybe TraceEvent)` — the event queue, `Nothing` being the shutdown sentinel — a
`done :: MVar ()` the worker fills when it finishes, a `closed :: IORef Bool` so cleanup
runs once, `sinkError :: IORef (Maybe SomeException)` for the first exception the sink
threw, `terminalSent :: IORef Bool`, and `stableRoot`. It forks a **worker** that drains
the channel through the sink's fold inside `try @SomeException` and then fills `done`;
pushes `CallStarted` eagerly; and returns the provider's stream wrapped in
`Stream.mapM (traceEvent …)` — which, on the terminal `EventDone`/`EventError`, pushes
`CallEvidence` (when there is a record) then `CallFinished`/`CallFailed`, sets
`terminalSent`, and calls `finalizeTrace` — inside `Stream.finallyIO (finalizeTrace …)`.
`finalizeTrace` (lines 237–287) claims `closed`, pushes a synthetic `CallFailed`
(`aborted: stream consumer stopped before the terminal event`) and an `aborted` evidence
record when `terminalSent` is `False`, writes the sentinel, blocks in `takeMVar done`,
reports a recorded sink error through `reportSinkError` (printing via
`Build.onSinkFailure`; returning a `BaikaiError` when `Build.sinkFailureIsFatal` says the
caller's strictness demands it), and releases the stable root. `withTrace` folds the
stream into a `Response`; `runRequestWith` adds a call-log entry.

An **asynchronous exception** is one thrown *at* a thread from outside it — by
`throwTo`, `killThread`, `System.Timeout.timeout`, or the runtime
(`BlockedIndefinitelyOnMVar`, thrown at a thread blocked on an `MVar` nothing else can
reach) — and can arrive at almost any point. A **mask** (`Control.Exception.mask_`)
defers delivery until the block ends except at *interruptible* operations such as
blocking `MVar` operations; `uninterruptibleMask_` defers it even there, which is safe
only around code that cannot block for long. A **finaliser** here is streamly's cleanup
for a stream: `Stream.finallyIO action stream` runs `action` when the stream stops or a
step throws, and otherwise from a garbage-collection hook when the stream becomes
unreachable. A **StablePtr** (`Foreign.StablePtr`) is a reference the garbage collector
treats as a root until `freeStablePtr`.

Two facts about that finaliser shape this plan, re-verified in the streamly source
(`Streamly/Internal/Data/Stream/Exception.hs` and `…/IOFinalizer.hs` in the checkout
`mori registry search streamly-core` names; unchanged across baikai's `>=0.3 && <0.5`).
First, `finallyIO` is `bracketIO3` over `gbracket`, which runs cleanup synchronously on
`Stop` or on an exception thrown *inside a step* (asynchronous ones included); when the
*consumer* stops pulling between steps (`Stream.take`, a fold that finishes early), no
step sees `Stop`, and cleanup runs from an `IOFinalizer` attached with `mkWeakIORef` —
at some major GC after the stream state becomes unreachable. Second, that GC-hook run
goes through `clearingIOFinalizer`, under `mask_`. Plan 34 found that before the hook
fires the worker blocked in `readChan` could be reaped with `BlockedIndefinitelyOnMVar`,
and rooted each `TraceState` with a `StablePtr` until `finalizeTrace` completes; that
invariant survives this plan.

`baikai/src/Baikai/Cost/Log.hs` is a structurally identical worker for the opt-in JSONL
call log; `closeCallLog` writes the sentinel and blocks in `takeMVar (done h)`, so a
second call on the same handle blocks forever.

`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` adapts an OpenTelemetry
`Tracer` into a `TraceSink`. A **span** is OpenTelemetry's unit of traced work; a
**span context** identifies one (trace id, span id); a `Context` carries the current
span between operations. The sink's fold state is a `Map Text Span` keyed by
`eventId`: `CallStarted` opens a span with `Otel.createSpan tracer Context.empty …`
(line 108 — every span a root), `CallEvidence` adds attributes, the terminal sets
status and ends the span, and the `Fold.rmapM` finaliser ends any span still open.
`strengthText` (lines 213–218) re-spells the strength names
`Baikai.Evidence.renderEvidenceStrength` renders. hs-opentelemetry-api `1.0.0.0`'s
`createSpan` reads the parent from `lookupSpan` on the `Context` argument.
`baikai-effectful/src/Baikai/Effectful.hs` imports only `streamly-core` modules while
its cabal file lists `streamly` in both `build-depends`.

The findings, with line references at `5411947`:

1. Duplicate terminal and evidence under an asynchronous exception (D.4, minor).
   `Trace.hs:396-398` and `420-422` push evidence, push the terminal, then write
   `terminalSent`. An exception between the last two makes `finalizeTrace` (from the
   `finallyIO` cleanup, synchronous because the exception landed inside a step) read
   `sent = False` and push a second `CallEvidence` and an `aborted` `CallFailed` after
   the real `CallFinished`. Nothing masks the writes.
2. A blocking sink hangs the call (D.5, minor). `Trace.hs:284` blocks in
   `takeMVar done` on the calling thread at every terminal and, on abort, inside the
   GC hook under `mask_`, so a sink whose step never returns holds the call forever
   and the first cancellation is deferred until a `takeMVar` that never returns.
   `throwingSinkTest` covers throwing only.
3. One throwing `multiSink` member silences its siblings (D.6, minor).
   `Trace/Sink.hs:60-64` is `Fold.tee`; one member's exception stops delivery to all
   for the rest of the call and skips their `final`.
4. No parent-context option (D.9, design). `OpenTelemetry.hs:108` hard-codes
   `Context.empty`; thread-local context cannot help on the worker thread.
5. `strengthText` re-spells the strength names; `baikai-effectful` depends on
   `streamly` while importing only `streamly-core` (both minor).
6. Theme I item 2: `exactlyOneEvidence` (`TraceSpec.hs:449-458`) ignores order, while
   `docs/capabilities/model-call-evidence.md:35` claims an ordering assertion exists.
7. Theme 7 residual: abort delivery is GC-driven and undocumented in
   `docs/capabilities/call-tracing.md:50-51` and `docs/user/model-call-evidence.md`
   (7.3); the worker's `try` catches asynchronous exceptions (7.1 — kept);
   `closeCallLog` is not idempotent (fixed).

ADRs under `docs/adr/` follow the plain-file convention of
`docs/adr/0001-architecture-decision-record-convention.md` (no profiled bundle, no
handle allocation). `docs/adr/0002-requested-translated-observed-are-never-collapsed.md`
bears on this work only in that the re-pushed abort record keeps
`observed_model = "unobserved"`; `docs/adr/0005-what-baikai-deliberately-does-not-do.md`
in that a stalled sink is reported, never retried. No other local or cross-repository
ADR applies.

Sibling coordination: EP-8 edits `traceEvent`'s terminal branches and `Build.hs`'s
sink-failure helpers, which this plan wraps and consumes; EP-4 owns the provider
workers, and this plan does not touch `baikai/src/Baikai/Stream.hs` or either provider
`Api.hs`; EP-10 must learn of `OtelSinkOptions.parentContext`; EP-11 reconciles the
guides this plan edits.


## Plan of Work

### Milestone 1 — terminal and evidence exactly once under asynchronous exceptions

Scope: finding 1. At the end, the flag write and the two pushes on every terminal path
are one atomic unit against asynchronous exceptions, so `finalizeTrace` can never see a
half-committed terminal. Two tests guard the invariant and a widened-window
demonstration shows the second detects the defect.

In `baikai/src/Baikai/Trace.hs`, add next to `pushEvidence`:

```haskell
-- | Commit a call's terminal to the sink: mark the terminal as sent, push
-- the evidence record (when there is one), then push the terminal event.
-- One unit with respect to asynchronous exceptions: an exception between
-- the terminal push and the flag write made 'finalizeTrace' read the flag
-- as unset and push a second evidence record and an @aborted@ terminal
-- after the real one. Every write is a non-blocking channel push or an
-- 'IORef' write, so the uninterruptible mask holds for microseconds. The
-- flag goes first so a synchronous failure inside the block yields a
-- missing terminal, which the abort machinery tolerates, not a duplicate.
commitTerminal ::
  TraceState -> Text -> UTCTime -> Model -> Maybe ModelCallEvidence -> TraceEvent -> IO ()
commitTerminal s eid now m mev terminal =
  uninterruptibleMask_ $ do
    writeIORef (s ^. #terminalSent) True
    pushEvidence s eid now m mev
    writeChan (s ^. #chan) (Just terminal)
```

In `traceEvent`, the `EventDone` branch's three lines

```haskell
      pushEvidence state eid now m mev
      writeChan (state ^. #chan) (Just finished)
      writeIORef (state ^. #terminalSent) True
```

become `commitTerminal state eid now m mev finished` (keep the comment above them
about evidence going out before the terminal); the `EventError` branch's three lines
become `commitTerminal state eid now m mev failed`; in `finalizeTrace`'s `unless sent`
block, `pushEvidence s eid now m mev` followed by `writeChan (s ^. #chan) (Just aborted)`
becomes `commitTerminal s eid now m mev aborted`. Add `uninterruptibleMask_` to the
`Control.Exception` import. If EP-8 changed what the branches push, keep EP-8's logic
and wrap only the writes.

Tests in `baikai/test/TraceSpec.hs` (Concrete Steps): the deterministic one parks the
sink on the terminal, kills the consumer while it waits, and asserts nothing was
duplicated once the sink is released; the stochastic one throws at the consumer from
the sink the instant `CallEvidence` arrives, fifty times.

Acceptance: `cabal test baikai` passes. Demonstration: in the *unfixed* code insert
`threadDelay 100000` between `writeChan (state ^. #chan) (Just finished)` and
`writeIORef (state ^. #terminalSent) True`; `throwToAroundTerminalTest` fails on its
first iteration with two `CallEvidence` events and a `CallFailed` after the
`CallFinished`; with the fix, the same delay inside `commitTerminal`'s block is
harmless. Remove the delay and record the transcript in Surprises & Discoveries.

### Milestone 2 — a blocking or throwing sink cannot hang the call or starve sibling sinks

Scope: findings 2 and 3 plus the `closeCallLog` residual. At the end, `finalizeTrace`
waits at most one second; `multiSink` isolates members; `closeCallLog` can be called
twice. Tests with `timeout` guards fail the unfixed code.

In `baikai/src/Baikai/Trace.hs`, add `sinkDrainBoundMicros :: Int` equal to
`1_000_000`, with a Haddock saying it is how long `finalizeTrace` waits for the worker
after the sentinel and that on expiry the worker is abandoned, not killed; and
`newtype TraceSinkStalled = TraceSinkStalled Int` (`deriving stock (Show)`) whose
`Exception` instance renders `displayException (TraceSinkStalled us)` as
`"the trace sink did not confirm delivery within " <> show (us `div` 1000) <> " ms; its worker was abandoned, and events already queued may still be delivered later"`,
with a Haddock saying it is stored in `sinkError` as a plain exception so the
strict-mode decision in `Baikai.Evidence.Build` applies to it exactly as to a sink that
threw. Then rewrite `finalizeTrace` from the sentinel onward and put the whole function
under `mask $ \restore ->`, so the claim-through-sentinel region cannot be interrupted
while the wait can:

```haskell
finalizeTrace ::
  TraceState -> Text -> UTCTime -> Model -> Options -> IO (Maybe BaikaiError)
finalizeTrace s eid start m opts = mask $ \restore -> do
  alreadyClosed <-
    atomicModifyIORef' (s ^. #closed) (\b -> (True, b))
  if alreadyClosed
    then pure Nothing
    else do
      sent <- readIORef (s ^. #terminalSent)
      unless sent $ do
        -- (unchanged: build `aborted` and `mev`, then)
        commitTerminal s eid now m mev aborted
      writeChan (s ^. #chan) Nothing
      drained <- restore (awaitWorker s) `onException` releaseStableRoot s
      unless drained $
        atomicModifyIORef' (s ^. #sinkError) $ \old ->
          (Just (fromMaybe (toException (TraceSinkStalled sinkDrainBoundMicros)) old), ())
      fatal <- reportSinkError s opts
      releaseStableRoot s
      pure fatal

-- | Wait for the worker to signal completion, for at most
-- 'sinkDrainBoundMicros'. 'True' when it did. On 'False' the worker is
-- left running: killing it would abort the sink's fold mid-step and lose
-- its end-of-stream action; an abandoned worker finishes when the sink
-- unblocks, or is reaped with 'BlockedIndefinitelyOnMVar' — which its
-- 'try' catches — when whatever it blocks on becomes unreachable.
-- 'readMVar', not 'takeMVar', so its eventual 'putMVar' can never block.
awaitWorker :: TraceState -> IO Bool
awaitWorker s = isJust <$> timeout sinkDrainBoundMicros (readMVar (s ^. #done))
```

The GC-hook path enters already under `mask_`; `restore` then restores that state, in
which a blocking `readMVar` is still interruptible, so `timeout`'s exception is
delivered either way. The `onException` releases the root if the wait is interrupted:
the sentinel is already queued, so the worker cannot block on the channel again and
needs no root.

Restructure `reportSinkError` so a stall prints its own line —
`hPutStrLn stderr ("baikai: " <> displayException stalled)` when `fromException e`
yields a `TraceSinkStalled` — and every other exception goes through EP-8's
`Build.onSinkFailure` unchanged; the fatality decision
(`Build.sinkFailureIsFatal` → `Build.sinkFailureError e`) is identical for both.
Imports: `Control.Exception (Exception (..), SomeException, mask, onException,
toException, try, uninterruptibleMask_)`, `readMVar` in place of `takeMVar`,
`Data.Maybe (fromMaybe, isJust)`, `System.IO (hPutStrLn, stderr)`,
`System.Timeout (timeout)`.

In `baikai/src/Baikai/Trace/Sink.hs`, replace `multiSink`:

```haskell
-- | Fan every event out to every sink in the list.
--
-- Each member runs on its own drain thread behind its own unbounded
-- channel, so a member that throws or blocks cannot stop delivery to the
-- others or skip their end-of-stream action. This fold's step never
-- blocks. Its final action sends every member the sentinel, waits for
-- every member, and throws one 'TraceSinkFailure' naming each failed
-- member by index when any failed — which the trace worker records like
-- any other sink failure. The wait for a member is unbounded here;
-- "Baikai.Trace" bounds the whole drain.
multiSink :: [TraceSink] -> TraceSink
multiSink sinks =
  TraceSink (Fold.rmapM finish (Fold.foldlM' deliver start))
  where
    start :: IO [Member]
    start = mapM startMember sinks

    deliver :: [Member] -> TraceEvent -> IO [Member]
    deliver members e = do
      forM_ members $ \member -> writeChan (chan member) (Just e)
      pure members

    finish :: [Member] -> IO ()
    finish members = do
      forM_ members $ \member -> writeChan (chan member) Nothing
      outcomes <- mapM (readMVar . outcome) members
      let failures = [(i, e) | (i, Just e) <- zip [0 :: Int ..] outcomes]
      unless (null failures) $
        throwIO (TraceSinkFailure (length members) failures)

data Member = Member
  { chan :: !(Chan (Maybe TraceEvent)),
    outcome :: !(MVar (Maybe SomeException))
  }

startMember :: TraceSink -> IO Member
startMember (TraceSink f) = do
  c <- newChan
  o <- newEmptyMVar
  _ <- forkIO $ do
    let step () = fmap (fmap (\e -> (e, ()))) (readChan c)
    r <- try (Stream.fold f (Stream.unfoldrM step ())) :: IO (Either SomeException ())
    putMVar o (either Just (const Nothing) r)
  pure Member {chan = c, outcome = o}

-- | One or more members of a 'multiSink' failed. Not exported: the
-- strict-mode error and the stderr line both render its text.
data TraceSinkFailure = TraceSinkFailure Int [(Int, SomeException)]
  deriving stock (Show)

instance Exception TraceSinkFailure where
  displayException (TraceSinkFailure total failures) =
    show (length failures) <> " of " <> show total <> " member sinks failed: "
      <> intercalate "; " ["member " <> show i <> ": " <> displayException e | (i, e) <- failures]
```

Imports for `Sink.hs`: `Control.Concurrent (forkIO)`, `Control.Concurrent.Chan`,
`Control.Concurrent.MVar`, `Control.Exception (Exception (..), SomeException, throwIO,
try)`, `Control.Monad (forM_, unless)`, `Data.List (intercalate)` and
`Streamly.Data.Stream qualified as Stream`. Update the `multiSink` sentence in the
module header.

In `baikai/src/Baikai/Cost/Log.hs`: add `closed :: !(IORef Bool)` to `CallLogHandle`,
created `False` in `openCallLog` on both branches; `closeCallLog` claims it with
`atomicModifyIORef'` and returns immediately when already claimed, and uses `readMVar`
in place of `takeMVar`; `appendEntry` reads `closed` and returns without enqueuing
when set. Add `atomicModifyIORef'` to the `Data.IORef` import, `unless` to
`Control.Monad`, `readMVar` to the `MVar` import; update the module doc's last
paragraph.

Tests are in Concrete Steps. Acceptance: `cabal test baikai baikai-trace-otel` passes;
against the unfixed `Trace.hs`, `blockingSinkTest` reports `withTrace hung on a
blocking sink` after two seconds, and against the unfixed `Sink.hs`,
`multiSinkThrowingMemberTest` finds the memory sibling empty and
`multiSinkSiblingSpanTest` finds no span with status `Ok`.

### Milestone 3 — OTel parent-context option; strength rendering shared

Scope: findings 4 and 5. At the end, `otelSinkWith tracer defaultOtelSinkOptions
{parentContext = Just ctx}` opens every call span as a child of the span in `ctx`; the
strength attribute is rendered by the function the JSON uses; `baikai-effectful`
declares only the streamly package it imports.

In `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`, add to
`OtelSinkOptions` after `includePromptSummary` the field
`parentContext :: !(Maybe Context.Context)` with a Haddock saying: the context whose
span becomes the parent of every span this sink opens; `Nothing`, the default, makes
each call span a root as before; it is a value fixed when the sink is built, not an
action run per call, because the fold runs on baikai's trace worker thread where the
caller's thread-local context is invisible; to nest a call under your own span,
capture the context on your thread (`ctx <- getContext`, or
`Context.insertSpan mySpan Context.empty`) and build the sink for that request. Set
`parentContext = Nothing` in `defaultOtelSinkOptions`; bind it in `stepEvent`'s record
pattern; replace line 108 with
`sp <- Otel.createSpan tracer (fromMaybe Context.empty parentContext) spanName sargs`;
import `Data.Maybe (fromMaybe)`. Delete `strengthText` and its Haddock; in
`evidenceAttributes` use `Attr.toAttribute (Ev.renderEvidenceStrength strength)`.

In `baikai-effectful/baikai-effectful.cabal`, delete `    , streamly        >=0.11   && <0.13`
from the library stanza and `    , streamly` from the test-suite stanza.

Tests: `parentContextTest` in `baikai-trace-otel/test/Main.hs` (Concrete Steps), and in
the existing `evidenceSpanTest`, after the attribute-presence loop, add
`HashMap.lookup "baikai.evidence.strength" attrs @?= Just (Attr.toAttribute ("requested_only" :: Text))`.

Acceptance: `cabal build baikai-effectful --enable-tests` succeeds with `streamly` gone
from its plan; `cabal test baikai-trace-otel baikai-effectful` passes.

### Milestone 4 — abort-terminal delivery semantics documented; evidence-order pinned in `TraceSpec`

Scope: findings 6 and 7, the ADR, the changelog. At the end, every place a reader might
look states when the abort terminal is delivered and what to do about it, and the
ordering claim in the capability record is true.

In `baikai/test/TraceSpec.hs`, change `exactlyOneEvidence` — currently

```haskell
exactlyOneEvidence :: [TraceEvent] -> IO ModelCallEvidence
exactlyOneEvidence events = case evidencesIn events of
  [ev] -> do
    let ids = Set.fromList [e ^. #eventId :: Text | e <- events]
    Set.size ids @?= 1
    assertMinimalShape ev
    pure ev
```

— by inserting `assertEvidencePrecedesTerminal events` after `assertMinimalShape ev`,
with the helper from Concrete Steps. Every evidence test then pins the order on its own
path (success, failure, abort, unregistered provider).

Documentation, in one commit with the ADR. In `baikai/src/Baikai/Trace.hs`'s module
doc, replace the sentence beginning "Cleanup ('Nothing' sentinel on the channel +
'takeMVar' on the worker) is idempotent…" with a paragraph saying: cleanup runs once;
on a normal terminal it runs on the calling thread; when the consumer abandons the
stream it runs from streamly's GC hook, so the synthetic `CallFailed` and `aborted`
evidence are delivered at the next major GC after the stream becomes unreachable and
are not guaranteed before process exit; the sink wait is bounded by
`sinkDrainBoundMicros`; sink exceptions are reported once on stderr and fail the call
only under `EvidenceRequired` (replacing "they do not propagate into the provider
call", no longer true). In `baikai/src/Baikai/Trace/Event.hs` lines 87–95, "immediately
*after* the matching 'CallFinished' or 'CallFailed'" becomes "immediately *before*",
with the reason (a sink keyed on the started/terminal pair must still have the call
open). In `baikai-trace-otel/test/Main.hs` lines 241–248, the stale paragraph saying
evidence is pushed after the terminal is rewritten: the hand-fed test isolates the
sink's behaviour, and `liveEvidenceSpanTest` covers the live order.

In `docs/capabilities/call-tracing.md`, the paragraph at lines 48–51 becomes: sink
exceptions are caught on the worker and reported once on stderr; a sink that blocks
holds the call for at most one second, after which the call proceeds and the stall is
reported; under `EvidenceRequired` either failure fails the call; `multiSink` isolates
its members and reports failures by index; a consumer who abandons a stream still
produces a synthetic `CallFailed` and an `aborted` evidence record, *delivered from a
garbage-collection hook* — at the next major GC after the abandoned stream becomes
unreachable — so a short-lived process that abandons a stream and exits may never
record it. Add a Limits bullet with the pattern: to have the record before you exit,
drain the stream to its terminal (`withTrace`, or `Stream.fold` with a fold that keeps
consuming after you have what you need) instead of `Stream.take`, and the terminal is
pushed synchronously before the terminal event reaches you; `performMajorGC` after
abandoning is a last resort, not a guarantee. Extend the frontmatter `description` to
"a throwing or blocking sink cannot hang the call", name the new tests in the
`TraceSpec` evidence entry's `proves`, and set `generated.at` to the edit time. In
`docs/user/model-call-evidence.md`, after the strict-mode paragraph on sink failures
(lines 219–225), add a paragraph on the bounded wait and the stall error, and a short
subsection "When the record is written" stating the abort caveat in the same words and
the drain-to-terminal pattern. In `docs/capabilities/opentelemetry-span-export.md`, the
Limits bullet on the consumer's own spans gains: `parentContext` on `OtelSinkOptions`
nests the call span under a span you supply, fixed per sink because the fold runs on
the worker thread; update its `proves` and `generated.at`. Add a dated entry to
`docs/capabilities/log.md` recording both record edits.

The ADR `docs/adr/0006-trace-cleanup-is-bounded-and-abort-cleanup-is-gc-eventual.md`
(frontmatter `title`, `status: accepted`, `date`; next unused number if a sibling plan
took `0006`): Context — streamly `finallyIO` semantics as verified, the July
`BlockedIndefinitelyOnMVar` discovery and the `StablePtr` root, the August
blocking-sink finding; Decision — the trace bridge waits for a sink for a bounded time
and never unboundedly, abort cleanup is GC-eventual and the worker stays rooted until
finalisation, strict evidence means confirmed delivery, and no plan may rely on
`finallyIO` for prompt cleanup on early stop; Consequences — tests force GC and poll,
callers needing the record drain to the terminal, an `Options` bound is the escape
hatch if one second proves tight.

`CHANGELOG.md` under `[Unreleased]`: `baikai` — Changed: `withTrace`/`withTraceStream`
wait at most one second for a trace sink and report a stall; a strict call whose sink
did not confirm delivery fails; `multiSink` isolates its members; Fixed: the terminal
and evidence events are pushed exactly once under asynchronous exceptions;
`closeCallLog` is idempotent. `baikai-trace-otel` — Added: `OtelSinkOptions.parentContext`
(breaking for positional construction). `baikai-effectful` — Changed: no longer depends
on `streamly`.

After EP-4 lands (consumer-side cancellation of provider workers), verify whether the
abort path became synchronous for provider streams: temporarily replace
`performMajorGC` with `pure ()` in `awaitEvents` (`TraceSpec.hs`) and `awaitSpans`
(otel `Main.hs`) and run `earlyAbortTest`, `abortEvidenceTest` and `abortSpanTest`
twenty times (`cabal test baikai --test-options='-p abort'` in a shell loop). If all
pass without forcing GC, delivery is synchronous on that path and the caveat can be
narrowed to "streams not produced by a registered provider"; if any fails, it stands.
Restore the GC forcing either way and record the result here and in the ADR.

Acceptance: `cabal test baikai baikai-trace-otel` passes with the ordering assertion
active; `okf validate docs/capabilities --profile docs/capabilities/profile.dhall
--profile-enforce --log-enforce` exits 0; the documents state the caveat.


## Concrete Steps

All commands run from the repository root. Plain `cabal` works in this environment.
Read EP-8's plan file first and rebase this plan's `Trace.hs` edits onto EP-8's if it
has landed.

1. Baseline:

   ```bash
   git log -1 --oneline
   cabal build all --enable-tests
   cabal test baikai baikai-trace-otel baikai-effectful
   ```

   All three suites report `PASS`.

2. Milestone 1 edits in `baikai/src/Baikai/Trace.hs` as shown. Then add to
   `baikai/test/TraceSpec.hs` (imports: `Control.Concurrent (forkIO, threadDelay,
   throwTo)`, `Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar,
   takeMVar)`, `Control.Exception (AsyncException (ThreadKilled), SomeException,
   throwIO, try)`, `Control.Monad (forM_, replicateM)`, `Data.Either (isLeft)`):

   `terminalPathAtomicityTest` ("an async exception on the terminal path leaves one
   terminal and one evidence") uses a `gatedSink` — a `Fold.foldlM'` memory sink
   whose step, on `CallFinished`, does `putMVar parked ()` then `readMVar release` —
   and a provider from `registerOkWithEvidence`. It runs `withTrace sink … evidenceOptions`
   on a `forkIO`'d consumer whose `try`-wrapped result lands in an `MVar`; `takeMVar
   parked` (the terminal is in the sink, so the consumer has committed it and is
   waiting for the worker); `throwTo consumer ThreadKilled` (the finaliser runs again
   from streamly's exception path and must find nothing to do); asserts `isLeft` on
   the consumer's result; `putMVar release ()`; then `awaitEvents ref 3` and asserts
   exactly one `CallEvidence`, one `CallFinished` and no `CallFailed`. The second test
   is the one aimed at the defect:

   ```haskell
   -- | Aim an asynchronous exception at the consumer the instant the
   -- evidence event reaches the sink — while the consumer is pushing the
   -- terminal and setting the flag. Fifty times, because the window is a
   -- few instructions wide and no scheduling hook can hit it
   -- deterministically; the plan's widened-window demonstration shows the
   -- test detects the defect.
   throwToAroundTerminalTest :: TestTree
   throwToAroundTerminalTest =
     testCase "fifty exceptions aimed at the terminal push never duplicate terminal or evidence" $
       forM_ [1 .. 50 :: Int] $ \i -> do
         let a = Custom ("baikai-trace-throwto-" <> Text.pack (show i))
         registerOkWithEvidence a
         ref <- newTVarIO []
         consumerVar <- newEmptyMVar
         let step () e = do
               atomically (modifyTVar' ref (e :))
               case e of
                 CallEvidence {} -> readMVar consumerVar >>= \tid -> throwTo tid ThreadKilled
                 _ -> pure ()
             sink = TraceSink (Fold.foldlM' step (pure ()))
         outcome <- newEmptyMVar
         tid <- forkIO $ do
           r <- try (withTrace sink (stubModel a) stubContext evidenceOptions)
           putMVar outcome (r :: Either SomeException Response)
         putMVar consumerVar tid
         _ <- takeMVar outcome
         _ <- awaitEvents ref 3
         -- Let anything the finaliser might still push arrive before counting.
         threadDelay 200000
         performMajorGC
         settled <- reverse <$> readTVarIO ref
         length [e | e@CallEvidence {} <- settled] @?= 1
         length [e | e@CallFinished {} <- settled] + length [e | e@CallFailed {} <- settled] @?= 1
   ```

   Register both in `tests`. Run `cabal test baikai --test-options='-p Trace'`, perform
   the widened-window demonstration from Milestone 1, and paste the failing iteration's
   output into Surprises & Discoveries. Commit:

   ```text
   fix(trace): commit the terminal and its evidence atomically under async exceptions

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/66-make-trace-sinks-unable-to-hang-or-corrupt-a-call.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

3. Milestone 2 edits in `Trace.hs`, `Trace/Sink.hs` and `Cost/Log.hs` as shown. Add to
   `TraceSpec.hs` (import `multiSink` from `Baikai.Trace.Sink`):

   ```haskell
   -- | A sink that never returns from its first step until released.
   blockingSink :: IO (MVar (), TraceSink)
   blockingSink = do
     release <- newEmptyMVar
     pure (release, TraceSink (Fold.drainMapM (\_ -> readMVar release)))

   blockingSinkTest :: TestTree
   blockingSinkTest =
     testCase "a sink that blocks forever cannot hold withTrace past the drain bound" $ do
       let a = Custom "baikai-trace-blocking-sink"
       registerOk a
       (release, sink) <- blockingSink
       result <- timeout 2000000 (withTrace sink (stubModel a) stubContext stubOptions)
       case result of
         Nothing -> assertFailure "withTrace hung on a blocking sink"
         Just resp -> do
           let AssistantPayload {stopReason = sr} = resp ^. #message
           sr @?= Stop
       putMVar release ()
   ```

   Four more tests are small variations. `blockingSinkStrictTest` ("a strict call
   whose sink never confirms delivery fails") is `blockingSinkTest` with
   `strictOptions`, asserting `stopReason = ErrorReason` and that `responseError resp`
   carries a message containing `did not confirm delivery`.
   `multiSinkThrowingMemberTest` ("a throwing multiSink member does not starve its
   sibling") runs `withTrace (multiSink [throwingSink, memory]) … stubOptions` under a
   `timeout 5000000` guard with `memory` from `memorySink`, asserts `stopReason = Stop`,
   and asserts the memory sibling's reversed `TVar` is exactly
   `[CallStarted {}, CallFinished {}]`. `multiSinkBlockingMemberTest` ("a blocking
   multiSink member does not starve its sibling") is the same with `blockingSink`'s
   sink as the first member, a `timeout 2000000` guard, and the release filled at the
   end. `multiSinkStrictNamesMemberTest` ("a strict call names the multiSink member
   that failed") runs `multiSink [throwingSink, memory]` under `strictOptions` and
   asserts the `responseError` message contains both `member 0` and `sink exploded`.
   Register all five in `tests`.

   In `baikai/test/CostSpec.hs` (import `closeCallLog` and `openCallLog`), add to
   `callLogTests` the case "closeCallLog twice returns and appendEntry after close is
   a no-op": create an empty file under `getTemporaryDirectory`, `openCallLog` an
   enabled config on it, assert `timeout 5000000 (closeCallLog h >> closeCallLog h)`
   is `Just ()`, then `appendEntry h` the entry literal the unwritable-path test
   already builds (lift it to a top-level `sampleEntry :: UTCTime -> CallLogEntry`),
   read the file back and assert `BSL.length raw @?= 0`, and remove the file.

   In `baikai-trace-otel/test/Main.hs`, `multiSinkSiblingSpanTest` ("a throwing
   multiSink member still lets the OTel sibling end its span") is `successSpanTest`'s
   shape with the sink `multiSink [throwingSink, otelSink tracer]` (define
   `throwingSink` as in `TraceSpec`, import `multiSink`), asserting exactly one span
   with `Otel.hotStatus` equal to `Otel.Ok`. Run `cabal test baikai baikai-trace-otel`;
   expect one `baikai: the trace sink did not confirm delivery within 1000 ms; …` line
   per blocking test and one `baikai: trace sink failed; …` line per throwing test on
   stderr. Commit as `fix(trace): bound the sink wait and isolate multiSink members`
   with the same three trailers as step 2.

4. Milestone 3 edits as shown. In `baikai-trace-otel/test/Main.hs` (import
   `OtelSinkOptions (..)`, `defaultOtelSinkOptions` and `otelSinkWith` from the sink
   module and `OpenTelemetry.Context qualified as Context`; `traceId`, `spanContext`
   and `spanParent` are record fields re-exported by `OpenTelemetry.Trace.Core` —
   check its export list in the checkout if a name does not resolve):

   ```haskell
   parentContextTest :: TestTree
   parentContextTest =
     testCase "parentContext nests the call span under the caller's span" $ do
       let a = Custom "baikai-otel-parent-context"
       registerOk a
       (tracer, getSpans) <- newTracerWithInMemory
       parent <- Otel.createSpan tracer Context.empty "caller.request" Otel.defaultSpanArguments
       let sink =
             otelSinkWith
               tracer
               defaultOtelSinkOptions {parentContext = Just (Context.insertSpan parent Context.empty)}
       _ <- withTrace sink (stubModel a) stubContext stubOptions
       Otel.endSpan parent Nothing
       parentCtx <- Otel.getSpanContext parent
       spans <- getSpans
       named <- mapM (\sp -> (,) sp . Otel.hotName <$> spanHotSnapshot sp) spans
       case [sp | (sp, n) <- named, n == "baikai.call"] of
         [sp] -> do
           Otel.traceId (Otel.spanContext sp) @?= Otel.traceId parentCtx
           assertBool "the call span records a parent" (maybe False (const True) (Otel.spanParent sp))
         other -> assertFailure ("expected one baikai.call span, got " <> show (length other))
   ```

   Then the `evidenceSpanTest` strength assertion and the cabal edit. Run
   `cabal test baikai-trace-otel baikai-effectful`. Commit as
   `feat(trace-otel): parent-context option; share the strength spelling; trim effectful deps`
   with the same three trailers as step 2.

5. Milestone 4. The ordering helper for `TraceSpec.hs` (import `Data.List (findIndex)`):

   ```haskell
   -- | The record must reach the sink while the call is still open there.
   -- "Baikai.Trace" pushes CallEvidence before the terminal since commit
   -- 1717694; this is the assertion the capability record says exists.
   assertEvidencePrecedesTerminal :: [TraceEvent] -> IO ()
   assertEvidencePrecedesTerminal events =
     case (findIndex isEvidence events, findIndex isTerminal events) of
       (Just i, Just j) ->
         assertBool ("CallEvidence at " <> show i <> " must precede the terminal at " <> show j) (i < j)
       (Just _, Nothing) -> assertFailure "an evidence event without a terminal"
       _ -> assertFailure "no evidence event to order"
     where
       isEvidence = \case CallEvidence {} -> True; _ -> False
       isTerminal = \case CallFinished {} -> True; CallFailed {} -> True; _ -> False
   ```

   Then the documentation edits, the ADR, the `log.md` entry and the changelog.
   Validate:

   ```bash
   cabal test baikai baikai-trace-otel
   okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
     --profile-enforce --log-enforce
   okf graph docs/capabilities
   ```

   If `okf validate` reports a log or timestamp mismatch for either record, the
   record's `generated.at` and the `log.md` entry date must agree; fix the date.
   Commit:

   ```text
   docs(trace): state that abort-terminal delivery is GC-eventual; pin evidence order

   MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
   ExecPlan: docs/plans/66-make-trace-sinks-unable-to-hang-or-corrupt-a-call.md
   Intention: intention_01m10p16mxedft15rjkk2w21g0
   ```

6. Final gate. The release skill's keyless test command
   (`agents/skills/release/SKILL.md`), run in `zsh` from the repository root, removes
   the directories holding key-bearing helpers from `PATH` and unsets every provider
   key so no live case can run:

   ```zsh
   baikai_test_path=(${path:#/Users/shinzui/.local/bin})
   baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
   env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
     -u OPENAI_KEY -u OPENAI_API_KEY \
     -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
     -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
     -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
     cabal test all
   ```

   Every suite must pass, not merely skip. Then tick the four EP-9 boxes in the
   MasterPlan's Progress list, update this plan's living sections, and commit as
   `docs(plans): record EP-9 outcomes` with the same three trailers.


## Validation and Acceptance

Run, from the repository root:

```bash
cabal build all --enable-tests
cabal test baikai baikai-trace-otel baikai-effectful
```

Expected shape of a passing run:

```text
Baikai.Trace
  a sink that blocks forever cannot hold withTrace past the drain bound:  OK (1.01s)
Test suite baikai-test: PASS
Test suite baikai-trace-otel-test: PASS
Test suite baikai-effectful-test: PASS
```

Beyond compilation, the change is demonstrated by behaviour:

- Exactly once: with the sink parked on the terminal and the consumer killed during
  the wait, the released sink ends with exactly `[CallStarted, CallEvidence,
  CallFinished]`; fifty sink-triggered `throwTo`s never produce a second evidence or a
  terminal after a terminal; the widened-window demonstration fails the
  fifty-iteration test on its first iteration with a five-event sequence.
- Blocking sink: `timeout 2000000 (withTrace blockingSink …)` returns `Just` with
  `stopReason = Stop` after about one second, and stderr shows
  `baikai: the trace sink did not confirm delivery within 1000 ms; its worker was abandoned, and events already queued may still be delivered later`;
  unfixed, the test reports `withTrace hung on a blocking sink`. The strict variant
  returns `ErrorReason` with a message containing `did not confirm delivery`.
- `multiSink`: the memory sibling of a throwing or blocking member records
  `[CallStarted, CallFinished]` and the call returns; the strict variant's error
  contains `member 0` and `sink exploded`; the OTel sibling exports one span with
  status `Ok`. Unfixed, the sibling is empty and the span is never ended.
- Parent context: the exported `baikai.call` span shares its trace id with
  `caller.request` and records a parent. Strength: `baikai.evidence.strength` equals
  `"requested_only"` with `strengthText` gone. Order: every evidence test passes
  `assertEvidencePrecedesTerminal`, and reordering the pushes in `commitTerminal` fails
  all four.
- `closeCallLog` twice returns within the guard and a later `appendEntry` leaves the
  file empty; unfixed, the second close hangs. `baikai-effectful` builds and passes
  with `streamly` removed from its cabal file.

Documentation acceptance: `docs/capabilities/call-tracing.md`,
`docs/user/model-call-evidence.md` and the `Baikai.Trace` module doc each mention the
garbage-collection hook in a sentence about the abort terminal, and
`okf validate docs/capabilities --profile docs/capabilities/profile.dhall
--profile-enforce --log-enforce` exits 0.


## Idempotence and Recovery

Every step is an ordinary source edit plus a build-and-test cycle; all are safe to
repeat. No migrations, no generated files, no destructive operations. M2 uses M1's
`commitTerminal`; M3 touches other packages; M4's assertion is independent. If a
milestone goes wrong, `git checkout -- <file>` its hunks without disturbing the others.

The timing-sensitive pieces are bounded by design. The blocking-sink tests wait one
second by construction and are guarded at two; if a loaded machine ever trips the
guard, raise the guard, never the bound, and never remove the guard — without it the
unfixed behaviour is an infinite hang. The GC-driven abort tests keep their
`performMajorGC` polling. The fifty-iteration test registers fifty provider tags in the
process-global registry, which is harmless on re-run. Every new test is guarded by
`timeout` or a bounded poll, so `cabal test` cannot wedge. If `okf validate` fails on
the capability bundle, the cause is almost always a `generated.at` that disagrees with
the `log.md` entry date. If EP-8 lands while this plan is in flight, rebase `Trace.hs`
first, re-run the `Trace` and `evidence` test groups, and record the rebase in both
Decision Logs.


## Interfaces and Dependencies

No new library dependencies; one removal (`streamly` from both stanzas of
`baikai-effectful/baikai-effectful.cabal`). Everything new uses base, the
`streamly-core` already in scope (`Streamly.Data.Fold`, `Streamly.Data.Stream`; no
`Streamly.Internal.*` module anywhere), and `hs-opentelemetry-api`'s public
`OpenTelemetry.Context`.

Public API at the end of the plan: `Baikai.Trace.withTrace`, `withTraceWith`,
`withTraceStream`, `withTraceStreamWith`, `runRequestWith`, `runRequestWithRegistry` —
unchanged types, with the documented semantics that the sink wait is bounded by one
second, a stall is reported on stderr and fails a strict call, terminal and evidence are
committed atomically, and abort cleanup is GC-eventual; `Baikai.Trace.Sink.multiSink ::
[TraceSink] -> TraceSink` — unchanged type, per-member isolation, aggregate failure
report by index; `Baikai.Cost.Log.closeCallLog` and `appendEntry` — unchanged types,
idempotent close, no-op append after close; and
`Baikai.Trace.Sink.OpenTelemetry.OtelSinkOptions` with the new field
`parentContext :: Maybe OpenTelemetry.Context.Context`, set to `Nothing` by
`defaultOtelSinkOptions` — the only surface addition, of which EP-10 is told.

Internal shapes that must exist at the end: in `baikai/src/Baikai/Trace.hs`,
`commitTerminal :: TraceState -> Text -> UTCTime -> Model -> Maybe ModelCallEvidence ->
TraceEvent -> IO ()`, `sinkDrainBoundMicros :: Int` (`1_000_000`), `awaitWorker ::
TraceState -> IO Bool`, `newtype TraceSinkStalled = TraceSinkStalled Int` with an
`Exception` instance, `finalizeTrace` with today's signature under `mask`, and
`reportSinkError` distinguishing a stall; in `baikai/src/Baikai/Trace/Sink.hs`,
`data Member` with fields `chan` and `outcome`, `startMember :: TraceSink -> IO Member`,
and `data TraceSinkFailure = TraceSinkFailure Int [(Int, SomeException)]` with an
`Exception` instance; in `baikai/src/Baikai/Cost/Log.hs`, `CallLogHandle` with the
additional field `closed :: IORef Bool`. Names EP-8 owns and this plan consumes
unchanged: `Build.onSinkFailure`, `Build.sinkFailureIsFatal`, `Build.sinkFailureError`,
`Build.minimalEvidence`, `Build.dispatchEnvelope`, `Build.transportForModel`; the one
wording change asked of `Build.sinkFailureError` is in the Decision Log. Per the
repository's field-naming rule, none of the new record fields carry prefixes.
