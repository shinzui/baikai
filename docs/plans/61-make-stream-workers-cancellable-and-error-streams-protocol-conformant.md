---
id: 61
slug: make-stream-workers-cancellable-and-error-streams-protocol-conformant
title: "Make stream workers cancellable and error streams protocol-conformant"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Make stream workers cancellable and error streams protocol-conformant

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

baikai exposes every model call as a stream of typed events (`AssistantMessageEvent`
in `baikai/src/Baikai/Stream/Event.hs`). The two HTTP providers produce that stream
from a worker thread that reads Server-Sent Events off a socket and hands each decoded
frame to the consumer through a channel. Today that worker is fire-and-forget: its
`ThreadId` is thrown away, the channel is unbounded, and nothing stops it when the
consumer stops reading, so a caller who takes the first three events of a long answer
leaves a worker reading the *entire* generation into a channel nobody will drain — the
provider bills the full response and the pooled connection stays busy until the last
frame. The Claude provider also emits `EventStart` only when Anthropic's
`message_start` arrives, so every failure before that frame violates the documented
protocol, and both providers close a tool call cut off by the output cap as a
well-formed call with empty arguments, which a tool loop will happily execute.

After this plan, the following are true and demonstrable with the offline test
suites. A consumer that stops reading — by cancellation, by timeout, or by simply
abandoning the stream — causes the worker to stop reading the socket within a bounded
number of frames and to release the HTTP connection; cancellation by exception releases
it immediately, abandonment releases it at the next major garbage collection, and the
plan says exactly which is which. Every error stream from both providers begins with
`EventStart` and ends with exactly one `EventError` carrying structured `errorInfo`,
and every error-producing test asserts that shape. A tool call cut off by the output
cap is closed with its raw argument text (`arguments = Aeson.String rawText`) and a
`stopReason` of `Length`, and neither `runToolLoop` nor `appendToolResult` dispatches
it. A transport failure mid-stream closes the blocks that were open before the terminal
fires, on both providers; reasoning that arrives after visible text closes the text
block first; an SSE frame whose type baikai does not know is skipped instead of ending
a healthy stream; `[DONE]` with trailing whitespace and empty `data:` heartbeats are
ignored. Core reassembly measures latency from its own clock when a provider stamps no
timestamps, keeps the first skeleton when a start event is duplicated, and ignores
events after the terminal.

This plan is EP-4 of the MasterPlan at
`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`. It
owns both provider `Api.hs` modules and lands before EP-5 (which later edits only the
OpenAI `parseChunk` region) and EP-8 (which later edits only the evidence content of
`immediateError`). It continues the streaming work of
`docs/plans/38-carry-full-fidelity-through-the-streaming-event-protocol.md`, whose
Decision Log delegated the Claude `EventStart` gap to a plan that closed without doing
it.


## Progress

- [x] M1: `Baikai.Provider.Internal.StreamWorker` (bounded `FrameQueue`, `forkFrameWorker`,
      `withFrameWorker`) added to `baikai`, with `baikai/test/StreamWorkerSpec.hs`
- [x] M1: Claude worker on the frame queue under `Stream.bracketIO`; `killThread` cleanup
- [x] M1: OpenAI worker on the frame queue under `Stream.bracketIO`; `killThread` cleanup
- [x] M1: `LifecycleSpec.hs` in both provider suites (four tests each) green
- [x] M1: ADR `docs/adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md`
      written and listed in `docs/adr/README.md`
- [ ] M2: Claude pre-seeds `EventStart`; `message_start` updates the skeleton only
- [ ] M2: `Event.hs` "temporary gap" note retired; `StartPayload.responseId` Haddock corrected
- [ ] M2: `assertErrorContract` strengthened in both suites and applied to every error stream
- [ ] M2: pre-`message_start` failure shapes pinned in `baikai-claude/test/SseSpec.hs`
- [ ] M3: `toolArgumentsFromText` and `isCutOffToolCall` in `Baikai.Content`; both assemblers
      and `danglingBlocks` use them; `runToolLoop`/`appendToolResult` never dispatch a cut-off call
- [ ] M3: Claude `closeOpenBlocks` on every failure path; OpenAI mid-stream `Left` closes blocks
- [ ] M3: OpenAI interleaved reasoning closes the open text block first
- [ ] M3: Claude `decodeFrame` skips unknown event and delta types; both transports ignore
      empty `data:` and trim `[DONE]`
- [ ] M3: SseSpec cases added in both packages
- [ ] M4: reassembly fallbacks (wall-clock latency, duplicate `EventStart`, post-terminal
      events) with the six new `StreamSpec` cases
- [ ] M4: Haddock, `docs/user/streaming.md`, `docs/user/tools.md`,
      `docs/capabilities/typed-streaming.md`, `CHANGELOG.md` updated
- [ ] M4: keyless `cabal test all` gate green; masterplan Progress rows EP-4 M1–M4 ticked;
      living sections finalized


## Surprises & Discoveries

Planning-time findings, recorded on 2026-08-27 while drafting against `5411947`:

- The workspace resolves `streamly-core-0.3.1` (from `dist-newstyle/cache/plan.json`).
  Its `Streamly.Data.Stream` exports `bracketIO`, `bracketIO3` and `finallyIO`, and the
  source of `Streamly.Internal.Data.Stream.Exception` documents the exact caveat
  masterplan 7 discovered: cleanup is immediate when the stream is consumed completely
  or an exception occurs *inside the bracketed part of the pipeline*, and "deferred to
  GC" when the bracketed stream is partially consumed and abandoned or the pipeline is
  aborted by an exception outside the bracket. The same module also offers
  `bracketIO'`, which guarantees release at the end of a monad-level
  `Streamly.Control.Exception.withAcquireIO` scope even on abandonment — but it needs
  an `AcquireIO` handle threaded into the stream, and `ApiProvider.stream` has no slot
  for one. Recorded as a deferred alternative in the Decision Log.
- The MercuryTechnologies `claude` SDK (`claude-1.4.0`, `Claude/V1/Messages.hs`)
  decodes `MessageStreamEvent` and `ContentBlockDelta` with aeson's generic
  `TaggedObject` encoding on the `type` field and no fallback constructor; only
  `ContentBlock` has `ContentBlock_Unknown`. So an unknown *event* type or an unknown
  *delta* type fails to decode, which `Sse.hs:176-180` turns into a terminal error.
- `runToolLoopWith.shouldStop` (`baikai/src/Baikai/Provider/Registry.hs:271-275`)
  already stops when the stop reason is not `ToolUse`, and a cut-off tool call arrives
  with `Length`, so REV-2 B.2's "runToolLoop then executes the tool" happens only
  through the documented direct round-trip `appendToolResult`, or when a compatible
  host reports `finish_reason: tool_calls` for truncated arguments. Both paths are
  guarded below.
- REV-2 B.3 names only the OpenAI mid-stream `Left` path, but the Claude twin has the
  same defect: `translate (Left be)` and `unexpectedEoS` build their terminal from
  `blocksInOrder` (closed blocks only) and never close `textBuf`, `thinkBuf`,
  `redactedBuf` or `toolArgsBuf`. Fixed for both providers in M3.


## Decision Log

- Decision: cancellation mechanism. Each provider forks its worker inside
  `Stream.bracketIO` whose acquire action is the fork (returning the `ThreadId`) and
  whose release action is `killThread`; the worker's body runs under
  `Control.Exception.finally` that closes the frame queue; and the channel between
  worker and consumer is a bounded `TBQueue` of capacity 64 plus a `TVar Bool`
  closed flag (`Baikai.Provider.Internal.StreamWorker`).
  Rationale: three guarantees with three different strengths, stated honestly.
  (1) When the consumer stops by exception — Ctrl-C, `System.Timeout.timeout`,
  `cancel` — the exception lands while the consumer thread is blocked in `pullFrame`
  inside the stream's own step, which is inside the bracket, so streamly runs the
  release synchronously: the worker is killed, `HTTP.withResponse`'s `bracket` runs
  `responseClose`, and the connection is back in the pool before the exception
  reaches the caller. (2) When the consumer abandons the stream (`Stream.take 3` and
  moves on), no code runs at that moment; the bounded queue guarantees the worker
  reads at most 64 more frames and then parks in an interruptible STM wait, so the
  socket read stops without any GC, deterministically. (3) The parked worker is
  released when streamly's GC finaliser fires at the next major collection and runs
  the same `killThread`; this is eventual, exactly as masterplan 7's Surprises &
  Discoveries recorded for `finallyIO`, and the ADR says so. A "consumer alive"
  flag was rejected because nothing sets it to false on abandonment — only GC can
  answer "will anyone pull again". A stall deadline on the blocked write (treat the
  consumer as gone after N seconds on a full queue) was rejected because a slow but
  live consumer — `streamRequestEach` with a callback that takes minutes — would be
  cut off; correctness must never depend on consumer speed. Threading streamly's
  `AcquireIO` through `ApiProvider.stream` so that core's own drivers release
  deterministically at the end of their fold was noted for EP-10's Decision Log; it
  changes the provider interface, which this plan may not.
  Date: 2026-08-27
- Decision: the queue, fork and bracket helpers live in one new core module,
  `baikai/src/Baikai/Provider/Internal/StreamWorker.hs`, exposed like
  `Baikai.Provider.Cli.Internal` (outside the PVP promise), rather than being
  duplicated in the two `Api.hs` modules.
  Rationale: identical concurrency code in two files diverges; one module is tested
  once (`StreamWorkerSpec`) and can be adopted by EP-9's trace worker. EP-10 is told
  in its Decision Log that this `.Internal` module exists.
  Date: 2026-08-27
- Decision: the worker never writes a sentinel value into the queue. The queue's
  closed flag is set by `forkFrameWorker`'s `finally`, and `pullFrame` returns
  `Nothing` only when the queue is empty *and* closed.
  Rationale: a sentinel write in a `finally` could block on a full queue and defeat
  the very cleanup it is in; a `TVar` write never blocks. This also closes REV-1's
  Theme 10.1 residual (an async exception to the worker skipped `writeChan ch Nothing`
  and left the consumer blocked forever).
  Date: 2026-08-27
- Decision: the Claude producer pre-seeds `EventStart` in `pending` before the first
  wire read, mirroring the OpenAI producer, and `Message_Start` updates the assembler
  (`responseId`, `observedModel`, `usage`) without emitting a second `EventStart`.
  Consequently `StartPayload.responseId` is `Nothing` on both HTTP providers and the
  message id rides `TerminalPayload.responseId`, which `reassembleResponse` already
  prefers.
  Rationale: the first event reaches the consumer immediately and carries the
  request-start timestamp, every failure path is `EventStart`-first without
  per-path bookkeeping, and consumers already tolerate a start with no id on OpenAI.
  The alternative — a "started" flag that prepends a synthetic start only on failure
  paths — keeps the id on the start payload but adds a branch to five paths, and the
  id is not lost, only moved.
  Date: 2026-08-27
- Decision: cut-off tool-call contract. A tool call whose accumulated argument text
  is non-empty and does not decode as JSON closes with `arguments = Aeson.String
  rawText`; empty text closes with `Aeson.Object mempty` (Anthropic opens `tool_use`
  blocks with no input and streams no delta). The rule is one function,
  `Baikai.Content.toolArgumentsFromText`, used by both assemblers and by core's
  `danglingBlocks`. `Baikai.Content.isCutOffToolCall` is true exactly when
  `arguments` is a `String`. `runToolLoopWith` stops (returns the response, tool
  calls intact, `stopReason = Length`) when any tool call is cut off;
  `appendToolResult` never calls the dispatcher for a cut-off call and appends a
  `ToolResultMessage` with `isError = True` explaining why.
  Rationale: core's recovery path already chose `Aeson.String rawText` in plan 38;
  the three layers must agree. The loop stops rather than reporting a tool-result
  error because the model asked for something it could not finish and the only
  useful next step — raise `maxTokens` and retry — is the caller's; the round-trip
  helper reports an error because a caller driving the exchange by hand expects a
  result message per call and must not silently lose the turn.
  Date: 2026-08-27
- Decision: on the OpenAI assembler, opening a thinking block closes an open text
  block and opening a text block closes an open thinking block; each open takes the
  next `contentIndex` and no index is reused. Tool-call blocks are not closed when
  text opens and text is not closed when a tool call opens.
  Rationale: REV-2 B.4 is the text/thinking case; hosts emit `content` and
  `tool_calls` in one chunk and closing text early would split a block the host meant
  as one. Reassembly is index-ordered either way.
  Date: 2026-08-27
- Decision: unknown SSE frames on the Claude transport are skipped, not fatal.
  `Sse.hs` decodes each frame to an `Aeson.Value`, peeks at `type` (and, for
  `content_block_delta`, at `delta.type`), skips frames whose type is not in the
  SDK's constructor list, and runs the SDK decoder only for known types, where a
  decode failure is still a `decodeError` terminal.
  Rationale: the SDK types have no fallback and cannot be changed here; a malformed
  *known* frame is a real fault, a *new* frame type is not.
  Date: 2026-08-27
- Decision: `latencyMs` uses provider timestamps when both the skeleton and the
  terminal carry one, and the reassembler's `wallStart` otherwise; a duplicate
  `EventStart` keeps the first skeleton and merges `responseId` with `<|>` (a later
  `Nothing` never erases an earlier id); events after the first terminal are ignored.
  Rationale: `wallStart` was captured and never read (REV-2 B.7); timestamps stay
  primary because lifted streams stamp the true provider window. First-wins matches
  the OpenAI assembler's `firstObserved` discipline.
  Date: 2026-08-27
- Decision: ADR. This plan creates
  `docs/adr/000N-a-stream-consumer-that-stops-owns-cancelling-the-producer.md`, with
  `N` the next free number at implementation time (currently `0006`), slug
  `a-stream-consumer-that-stops-owns-cancelling-the-producer`, and adds its row to
  `docs/adr/README.md`. The local corpus is the plain-file convention of
  `docs/adr/0001-architecture-decision-record-convention.md`; no OKF handle applies.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

baikai is a multi-package Haskell workspace at the repository root. The packages this
plan touches: `baikai/` (the core: event algebra, reassembly, registry, tool loop),
`baikai-claude/` (the Anthropic Messages API provider), `baikai-openai/` (the OpenAI
Chat Completions provider). All commands run from the repository root,
`/Users/shinzui/Keikaku/bokuno/baikai`. Line numbers below are as of `5411947`, which
is identical to `c3753c5` (the commit REV-2 reviewed) for every source file named.

Terms used throughout, defined once here:

- **SSE frame**: Server-Sent Events is the wire format both providers stream in — a
  text body of lines, where `data: <json>` lines followed by a blank line form one
  frame. `baikai-claude/src/Baikai/Provider/Claude/Sse.hs` and
  `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs` split the body into frames and
  decode each frame's JSON (`sseFromResponse`).
- **Worker**: the thread each provider forks per call to read frames off the socket
  and push them to the consumer (`worker` in both `Api.hs`).
- **Driver** (`SseDriver`): the function that physically performs the HTTP request
  and feeds frames to two callbacks. Production uses `liveSseDriver`; tests pass one
  that serves a recorded `HTTP.Response` through the same `sseFromResponse`.
- **Assembler**: the per-call state record (`Assembler` in both `Api.hs`) that
  `translate` threads through every frame, accumulating open blocks and closed
  content; `translate` is pure and returns the events to emit plus the new state.
- **Terminal event**: `EventDone` or `EventError`; exactly one ends every stream.
- **Skeleton**: the empty-content `AssistantMessage` carried by `EventStart`.
- **Bounded queue**: a `Control.Concurrent.STM.TBQueue` with a fixed capacity; a
  writer blocks when it is full.
- **GC-driven finaliser**: an action attached to a heap object via a weak pointer
  that the runtime runs when the object is found unreachable during garbage
  collection. streamly's `bracketIO`/`finallyIO` cleanup runs this way when a stream
  is partially consumed and abandoned.
- **Asynchronous exception**: one thrown *into* a thread from outside (`throwTo`,
  `killThread`, `System.Timeout.timeout`, Ctrl-C); `trySync` in both `Api.hs` and in
  `Baikai.Stream` rethrows these and catches only synchronous ones.

How a streaming call flows today. `claudeMessagesStreamWith`
(`baikai-claude/src/Baikai/Provider/Claude/Api.hs:174-210`) runs `prepareCall` under
`trySync` inside `Stream.concatEffect`; on failure it returns `immediateError` (already
`[EventStart, EventError]`); on success it creates an unbounded `Chan` (line 183),
`forkIO`s the worker and discards the `ThreadId` (line 186), and returns
`Stream.unfoldrM step initialState` with `pending = []` (line 203). `step` (300-351)
blocks in `readChan`, folds `translate` over each frame, and seals the terminal with
evidence. The worker (259-277) runs the driver under `trySync` and `runWithTimeout`,
then writes `Nothing` — but not under `finally`, so an async exception to the worker
skips the sentinel. `translate` (584-649) emits `EventStart` only on `Message_Start`
(602-615); `Left be` (590-592), the in-band `Error` branch (644-649) and
`unexpectedEoS` (517-522) emit a lone `EventError` built from `blocksInOrder` — closed
blocks only. `handleBlockStop`'s tool branch (755-781) decodes the accumulated
arguments and falls back to `Aeson.Object mempty` on *any* failure (761-768), the
comment conflating "no deltas" with malformed JSON. The OpenAI producer
(`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:194-230`) has the same worker shape
(316-340, `forkIO` at 206) but pre-seeds `EventStart` (223); its `translate (Left be)`
(910-913) emits the terminal without closing open blocks, unlike `closeOpenStream`
(1214-1246); `applyReasoningDelta` (955-972) opens a thinking block while text stays
open; `closeOpenTools` (1186-1212) has the same `{}` fallback (1194-1197).
`Sse.hs` on the Claude side turns any decode failure into `Left (decodeError …)`
(176-180); on the OpenAI side `[DONE]` is compared exactly after stripping leading
spaces only (174, 187).

Core: `baikai/src/Baikai/Stream.hs` folds events into a `Response`
(`reassembleResponse`, 174-178; `step`, 226-280; `finalizeState`, 282-317). `wallStart`
is captured (186, 217) and never read; latency comes from message timestamps
(304-306); a duplicate `EventStart` overwrites `responseId` with `.~` (228-229) while
terminals merge with `<|>`; `danglingBlocks` (329-359) already keeps undecodable tool
arguments as `Aeson.String raw`. `baikai/src/Baikai/Stream/Event.hs:14-17` still calls
the Claude gap "temporary … until the EP-7 Claude streaming rewrite pre-seeds its
skeleton". `Baikai.Content.ToolCall` (`baikai/src/Baikai/Content.hs:87-95`) documents
nothing about a `String` argument value. `runToolLoopWith`
(`baikai/src/Baikai/Provider/Registry.hs:253-276`) and `appendToolResult`
(`baikai/src/Baikai/Context.hs:109-131`) dispatch whatever tool calls the response
carries.

Tracing interacts with the worker in one place: `withTraceStreamWith`
(`baikai/src/Baikai/Trace.hs:115-160`) wraps the provider stream in
`Stream.finallyIO (finalizeTrace …)`. Masterplan 7 (Surprises & Discoveries in
`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`)
discovered while drafting its EP-1 that this cleanup runs synchronously only when the
stream stops normally or a step throws, and from a GC hook when the consumer abandons
the stream — and, while implementing it, that the trace worker blocked in `readChan`
could be killed with `BlockedIndefinitelyOnMVar` before that hook fired, which is why
`newTraceState` roots each state with a `StablePtr` (`Trace.hs:213-222`) and why
`TraceSpec`'s abandoned-stream tests poll with `performMajorGC` (`awaitEvents`,
`baikai/test/TraceSpec.hs:251-262`). This plan's worker wants the *opposite* of a
root: a parked worker that the runtime reclaims is a released connection. Nothing in
this plan changes `Trace.hs`; EP-8 and EP-9 own it.

The findings this plan fixes, from `docs/reviews/correctness-and-api-review-follow-up.md`:
A.4 (Claude failures before `message_start` lack `EventStart`), A.8 (`[DONE]`
variants), B.1 (worker not cancellable), B.2 (cut-off tool calls), B.3 (mid-stream
`Left` leaves blocks open), B.4 (interleaved reasoning ordering), B.5 (unknown SSE
types are fatal), B.7 (`wallStart` unused, duplicate-start precedence), Theme I item 5
(missing `StreamSpec` cases), plus the REV-1 residuals recorded under Theme 1 item 1.1
(Claude HTTP-level failure stream is `[EventError]` only; the `Event.hs:14-17` note)
and Theme 10 item 10.1 (worker `trySync` without `finally`).

Tests you will extend: `baikai-claude/test/Main.hs` (`assertErrorContract` 750-757,
`rejectsImageToolResultsTest` 674-705, `noKeyStreamTest` 707-720),
`baikai-claude/test/SseSpec.hs` (`replay`/`mkResponse` harness 126-166),
`baikai-claude/test/EvidenceSpec.hs` (`rateLimitEvidenceTest` 118-146, `replay`
183-201, `replayDriver` 209-212), `baikai-openai/test/Main.hs` (`assertErrorContract`
919-926, `noKeyStreamTest` 833-847, `finishReasonTests` 867-900),
`baikai-openai/test/SseSpec.hs`, `baikai-openai/test/ReasoningSpec.hs` (`emptyChunk`,
`runChunks`, `eventShape` 204-241), `baikai/test/StreamSpec.hs`.

ADR context. `docs/adr/` is the plain-file convention of
`docs/adr/0001-architecture-decision-record-convention.md` (`NNNN-slug.md`, YAML
`title`/`status`/`date`, Context/Decision/Consequences); it is not a profiled OKF
bundle, so no handle allocation applies. No existing record governs stream lifecycle
or cancellation; `docs/adr/0005-what-baikai-deliberately-does-not-do.md` is not
relevant here. Masterplan 7's discoveries are context, not ADRs. This plan creates the
ADR named in the Decision Log. No cross-repository ADR applies.


## Plan of Work

Four milestones, in the order the MasterPlan fixes. Each leaves
`cabal build all --enable-tests` and the three affected suites green, and each ends in
one commit carrying the trailers shown in Concrete Steps.


### Milestone 1 — stream workers cancelled when the consumer stops, connection released

Scope: the worker lifecycle in both providers. At the end, a consumer that cancels by
exception releases the connection immediately, a consumer that abandons the stream
stops the socket read within 64 frames and releases the connection at the next major
GC, and an asynchronous exception delivered to the worker can no longer strand the
consumer. Acceptance: the four `LifecycleSpec` tests in each provider suite and the
three `StreamWorkerSpec` tests in core pass.

Create `baikai/src/Baikai/Provider/Internal/StreamWorker.hs` and add it to
`exposed-modules` in `baikai/baikai.cabal` (the library already depends on `stm`;
confirm with `grep -n stm baikai/baikai.cabal` and add it to the library's
`build-depends` if only the test suite lists it). Its Haddock states it is an internal
module outside the PVP promise, like `Baikai.Provider.Cli.Internal`. Contents:

```haskell
module Baikai.Provider.Internal.StreamWorker
  ( FrameQueue,
    frameQueueCapacity,
    newFrameQueue,
    pushFrame,
    closeFrames,
    pullFrame,
    forkFrameWorker,
    withFrameWorker,
  )
where

-- | The hand-off between a provider's worker thread and the consumer,
-- bounded so a worker whose consumer has stopped pulling parks in an
-- interruptible STM wait after 'frameQueueCapacity' more frames.
data FrameQueue a = FrameQueue
  { frames :: !(TBQueue a),
    closed :: !(TVar Bool)
  }

frameQueueCapacity :: Natural
frameQueueCapacity = 64

newFrameQueue :: IO (FrameQueue a)
newFrameQueue = FrameQueue <$> newTBQueueIO frameQueueCapacity <*> newTVarIO False

-- | Blocks while the queue is full.
pushFrame :: FrameQueue a -> a -> IO ()
pushFrame q a = atomically (writeTBQueue (frames q) a)

-- | Never blocks; safe inside a 'finally'.
closeFrames :: FrameQueue a -> IO ()
closeFrames q = atomically (writeTVar (closed q) True)

-- | The next frame, or 'Nothing' once the queue is empty *and* closed.
-- Frames pushed before the close are always delivered first.
pullFrame :: FrameQueue a -> IO (Maybe a)
pullFrame q =
  atomically $
    (Just <$> readTBQueue (frames q))
      `orElse` (readTVar (closed q) >>= check >> pure Nothing)

-- | Fork the worker body so that its 'ThreadId' cannot be lost to an
-- asynchronous exception and the queue is closed however the body ends.
forkFrameWorker :: FrameQueue a -> IO () -> IO ThreadId
forkFrameWorker q body =
  mask_ $ forkIOWithUnmask $ \unmask -> unmask body `finally` closeFrames q

-- | Run the consumer stream with the worker alive, killing the worker
-- when the stream stops, throws, or is collected. See the module
-- Haddock for which of those is immediate and which is eventual.
withFrameWorker :: FrameQueue a -> IO () -> Stream IO b -> Stream IO b
withFrameWorker q body consumer =
  Stream.bracketIO (forkFrameWorker q body) killThread (const consumer)
```

The module Haddock must reproduce the three-strength statement from the Decision Log
in plain words, because it is the one place a reader of either provider will look:
immediate on normal end and on an exception raised inside the stream's step (which is
where the consumer thread sits while blocked in `pullFrame`), bounded read then
eventual release on abandonment, and the reason a sentinel is not used.

Add `baikai/test/StreamWorkerSpec.hs` (register in `baikai/test/Main.hs` and the
`other-modules` of `test-suite baikai-test` in `baikai/baikai.cabal`) with three
tests: "pullFrame delivers every frame pushed before close" (push 1..10, close, pull
until `Nothing`, expect the ten in order); "pushFrame blocks when the queue is full and
is interruptible" (a forked thread fills the queue, pushes one more, then sets an
`MVar`; the `MVar` stays empty for 100 ms; `killThread` lands and the thread's
`finally` sets a flag); "forkFrameWorker closes the queue when the body is killed" (a
body that blocks forever; `killThread`; `pullFrame` returns `Nothing` within
`timeout 1000000`).

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`: replace the `Control.Concurrent`
and `Control.Concurrent.Chan` imports with `Baikai.Provider.Internal.StreamWorker`;
change `ProducerState.chan` to `FrameQueue (Either BaikaiError Messages.MessageStreamEvent)`;
in `step` replace `readChan (s ^. #chan)` with `pullFrame (s ^. #chan)`; rewrite the
worker so it pushes with `pushFrame` and writes no sentinel:

```haskell
worker driver call metaRef q = do
  r <-
    trySync $
      Transport.runWithTimeout (call ^. #timeoutMs) $
        driver call (writeIORef metaRef . Just) (pushFrame q)
  case r of
    Right Nothing -> pure ()
    Right (Just be) -> pushFrame q (Left be)
    Left e -> pushFrame q (Left (exceptionToError e))
```

and build the stream under the bracket in `claudeMessagesStreamWith`:

```haskell
Right call -> do
  q <- newFrameQueue
  -- tref, mref, startTime, mkEvidence and initialState exactly as today, with chan = q
  pure (withFrameWorker q (worker driver call mref q) (Stream.unfoldrM step initialState))
```

Rewrite the `claudeMessagesStream` Haddock (137-148): it currently promises a "bounded
`Chan`" that does not exist; after this milestone it should describe the frame queue,
the bracket, and the three cancellation strengths in one paragraph each. Make the
identical edits in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` (`worker` at
316-340, the stream construction at 202-230, the Haddock at 155-163 which also wrongly
says the worker drives `OpenAI.createChatCompletionStream`).

Add `baikai-claude/test/LifecycleSpec.hs` and `baikai-openai/test/LifecycleSpec.hs`,
registered in each `test/Main.hs` group and each cabal `other-modules`. Both use a
driver shaped like `EvidenceSpec.replayDriver` but wrapped in the real close bracket,
so that `killThread` reaching the worker provably closes the response:

```haskell
-- | A driver whose body reader is generated on demand and whose close
-- hook is observable. The bracket is the shape 'HTTP.withResponse' has,
-- so a worker killed mid-read closes the response as production would.
countingDriver :: IORef Int -> IORef Bool -> Maybe (MVar ()) -> SseDriver
countingDriver reads closedRef gate _call onMetadata onEvent =
  bracket (pure response) HTTP.responseClose $ \resp ->
    sseFromResponse resp onMetadata onEvent
  where
    response = (mkResponse 200 [] []) {HTTP.responseBody = bodyReader,
                                       HTTP.responseClose' = HTTP.ResponseClose (writeIORef closedRef True)}
    bodyReader = do
      n <- atomicModifyIORef' reads (\k -> (k + 1, k))
      case gate of
        Just g | n >= 3 -> takeMVar g   -- block: the consumer will be cancelled
        _ -> pure (frameAt n)           -- 0: message_start, 1: text block start, then text deltas
```

(`mkResponse` is `SseSpec`'s existing fake-response builder — make it pure or copy it;
`HTTP.responseClose` and the record fields come from `Network.HTTP.Client.Internal`.
The OpenAI twin serves `data: {"choices":[{"index":0,"delta":{"content":"x"}}]}`
chunks.) The four tests, with these exact names:

1. "a consumer that stops after three events stops the body reader within the queue
   bound": run `Stream.toList (Stream.take 3 (claudeMessagesStreamWith driver model
   ctx opts))`; then poll `reads` every 50 ms until it has not changed for four
   consecutive polls; assert `reads <= fromIntegral frameQueueCapacity + 8`. Before
   this milestone the counter never settles because the worker drains an endless
   body into an unbounded `Chan`.
2. "an abandoned stream releases its connection after a major GC": same run; then
   loop up to 100 times: `performMajorGC`, read `closedRef`, `threadDelay 50000`;
   assert it became `True`. This is the eventual guarantee, tested the way
   `TraceSpec.awaitEvents` tests the trace finaliser.
3. "cancelling the consumer releases the connection without a GC": driver with a
   gate; fork a thread running `Stream.toList (stream …)` and writing its outcome to
   an `MVar`; `threadDelay 100000`; `throwTo tid ThreadKilled`; poll `closedRef`
   every 10 ms for up to one second **without** calling `performMajorGC`; assert
   `True`, and assert the forked thread's outcome is `Left ThreadKilled`.
4. "an asynchronous exception in the worker still closes the channel": a driver whose
   body is `throwIO ThreadKilled` (an `AsyncException`, which `trySync` rethrows);
   `timeout 2000000 (Stream.toList (stream …))` must return `Just events` whose last
   event is an `EventError` with message `claude stream ended without message_stop`
   (`openai stream ended without finish_reason` on the OpenAI side). Before this
   milestone the consumer blocks until the runtime's deadlock detector fires.

Write the ADR in this milestone (`docs/adr/000N-…`, next free number), with the
Decision Log's three strengths as its Decision section, the rejected alternatives as
its Context, and one Consequences paragraph telling callers how to stop
deterministically: cancel the draining thread, or wrap the drain in `timeout`; a bare
`Stream.take` is legal and releases at the next major GC. Add its row to the table in
`docs/adr/README.md`.


### Milestone 2 — `EventStart` first on every Claude failure path; `assertErrorContract` on every error stream

Scope: the Claude producer's start event and the test contract in both packages. At
the end, every stream either provider produces begins with exactly one `EventStart`,
and every test that drains an error stream asserts it. Acceptance: the new SseSpec
cases and the strengthened `assertErrorContract` pass in both suites.

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, set the initial `pending` to
`[EventStart StartPayload {partial = skeletonMessage (emptyAssembler m startTime) startTime, responseId = Nothing}]`
(the existing `skeletonMessage` at 786-795 builds the right empty message from an
assembler's `usage` and `start`). Change `translateEvent`'s `Message_Start` branch
(602-615) to return `([], ass')` — the assembler still records `responseId`,
`observedModel`, `usage` and `usageReported`; only the event disappears. `translate
(Left be)`, the `Error` branch and `unexpectedEoS` are untouched here; the pre-seeded
start already precedes them. Check `ThinkingSpec.runClaudeEvents` (490-497), which
folds `translate` directly and asserts on `thinkingEnds` and the terminal, not on a
start event; it needs no change.

In `baikai/src/Baikai/Stream/Event.hs`: delete the sentence at 14-17 beginning "One
temporary provider-side gap remains" and state the invariant without exception; change
the `StartPayload.responseId` Haddock (119-121) to say the id is carried here only by
providers that know it before their first event — neither HTTP provider does, both
carry it on `TerminalPayload.responseId`, and `reassembleResponse` prefers the
terminal's value. In `baikai/src/Baikai/Stream.hs`, fix the two Haddocks that still
say "one-event error stream" (97 and 578) while you are there.

Strengthen `assertErrorContract` in both `test/Main.hs` files to the full protocol:

```haskell
assertErrorContract :: [AssistantMessageEvent] -> Assertion
assertErrorContract events = do
  case events of
    EventStart StartPayload {} : _ -> pure ()
    other -> assertFailure ("stream must begin with EventStart, got: " <> show (take 1 other))
  length [() | EventStart {} <- events] @?= 1
  length (filter isTerminal events) @?= 1
  case last events of
    EventError TerminalPayload {errorInfo = Just _} -> pure ()
    EventError TerminalPayload {errorInfo = Nothing} -> assertFailure "terminal EventError omitted errorInfo"
    other -> assertFailure ("stream must end with EventError, got: " <> show other)
```

Keep the old body under the name `assertOneErrorTerminal` for translator-level
fragments that never carried a start event, and switch the two `finishReasonTests`
cases in `baikai-openai/test/Main.hs` (884) to it. Every test that drains a whole
stream keeps `assertErrorContract`: `rejectsImageToolResultsTest` and
`noKeyStreamTest` in both packages, and the new cases below. In both `EvidenceSpec`s,
add `replayEvents`, a sibling of `replay` that returns `Stream.toList` of the provider
stream instead of trace events, and make `rateLimitEvidenceTest` call
`assertErrorContract` on it in addition to its evidence assertions.

Add to `baikai-claude/test/SseSpec.hs` a `replayDriver` (copy the eleven lines from
`EvidenceSpec.hs:209-212`, or move it into a shared `test/Replay.hs` if you prefer one
copy — either is acceptable; record which) and a group "failure streams are
protocol-conformant" with these cases, each draining
`claudeMessagesStreamWith (replayDriver status headers chunks) model emptyContext opts`
and calling `assertErrorContract`:

- "an HTTP 401 before message_start is EventStart then one EventError" — status 401,
  body `{"type":"error","error":{"type":"authentication_error","message":"bad key"}}`;
  the terminal's `errorInfo` category is `AuthError`.
- "an HTTP 429 before message_start keeps EventStart first and Retry-After on the
  terminal" — status 429, `Retry-After: 7`; category `RateLimited`,
  `retryAfterSeconds = Just 7`.
- "an in-band error event before message_start is EventStart then one EventError" —
  status 200, one frame `data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}`.
- "EOF before message_start is EventStart then one EventError" — status 200, no
  frames; the terminal's message is `claude stream ended without message_stop`.
- "message_start updates the skeleton and emits no second EventStart" — the
  `successBody` fixture already in the file; exactly one `EventStart`, an `EventDone`
  whose `responseId` is `Just "msg_observed"`, and reassembling the events yields
  `Response.responseId = Just "msg_observed"`.

The model for these is the file's `anthropic_claude_haiku_4_5` with
`#apiKey .~ Just (ApiKeyLiteral "test-key")` on the options so `prepareCall` does
not consult the environment. On the OpenAI side add one full-stream case to
`baikai-openai/test/SseSpec.hs`, "an HTTP 401 stream is EventStart then one
EventError", through `openaiChatStreamWith` with the `replayDriver` shape from
`baikai-openai/test/EvidenceSpec.hs:258-263` (it takes a body `IORef`; pass a throwaway).


### Milestone 3 — block-closing fidelity (cut-off tool calls, mid-stream `Left`, interleaved reasoning, unknown frames, `[DONE]` variants)

Scope: how blocks close under every abnormal condition, on both providers, and the
cut-off tool-call contract in core. At the end, partial output on an error terminal is
the same whether a consumer reads raw events or reassembles, a cut-off tool call is
inspectable and never executed, and transports tolerate frames they were not written
for. Acceptance: the SseSpec cases listed below and the tool-loop case in
`StreamSpec` pass.

In `baikai/src/Baikai/Content.hs`, next to `ToolCall`, add and export:

```haskell
-- | Turn a tool call's accumulated argument text into its 'arguments'
-- value. Empty text is an empty object (Anthropic opens a @tool_use@
-- block with no input and streams no delta). Non-empty text that does
-- not decode is kept verbatim as a 'Aeson.String': the call was cut
-- off and no byte is dropped. Both assemblers and core's recovery path
-- use this one rule, so 'isCutOffToolCall' means the same everywhere.
toolArgumentsFromText :: Text -> Aeson.Value
toolArgumentsFromText raw
  | Text.null (Text.strip raw) = Aeson.Object mempty
  | otherwise = case Aeson.eitherDecodeStrict (Text.encodeUtf8 raw) of
      Right v -> v
      Left _ -> Aeson.String raw

-- | 'True' when the call's argument stream was cut off: 'arguments' is
-- the raw text rather than a decoded value. Such a call must not be
-- dispatched; 'Baikai.Provider.Registry.runToolLoop' stops on it and
-- 'Baikai.Context.appendToolResult' reports it as a tool-result error.
isCutOffToolCall :: ToolCall -> Bool
isCutOffToolCall ToolCall {arguments = Aeson.String _} = True
isCutOffToolCall _ = False
```

and extend the `ToolCall` Haddock: `arguments` is the decoded JSON value, and a
`String` value is the cut-off marker just described (`isCutOffToolCall`). Use
`toolArgumentsFromText` in `handleBlockStop`'s tool branch (Claude, replacing 760-768),
in `closeOpenTools` (OpenAI, replacing 1194-1197), and in `danglingBlocks.toolBlock`
(`Stream.hs:346-359`; keep its "empty buffer yields no block" guard). In
`baikai/src/Baikai/Provider/Registry.hs` add `|| Vector.any isCutOffToolCall
(responseToolCalls resp)` to `shouldStop`. In `baikai/src/Baikai/Context.hs`, inside
`appendToolResult`'s `traverse`, branch on `isCutOffToolCall tc`: when true, do not
call `dispatcher`; use `toolResultErrorText "tool call arguments were cut off by the
output limit; the call was not dispatched — raise maxTokens and retry"` as the result.
Update `appendToolResult`'s Haddock accordingly.

Claude, `baikai-claude/src/Baikai/Provider/Claude/Api.hs`: add

```haskell
-- | Close every still-open block in ascending index order, exactly as a
-- 'Content_Block_Stop' for each would. Used on every failure path so the
-- terminal message and the raw events agree about partial output.
closeOpenBlocks :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenBlocks ass = foldl' close ([], ass) openIndices
  where
    openIndices =
      IntSet.toAscList . IntSet.unions $
        map IntMap.keysSet [ass ^. #textBuf, ass ^. #thinkBuf, ass ^. #redactedBuf, ass ^. #toolArgsBuf]
    close (acc, a) i = let (evs, a') = handleBlockStop i a in (acc <> evs, a')
```

(`IntMap.keysSet` returns an `IntSet`; import `Data.IntSet qualified as IntSet`.)
Use it in `translate (Left be)`, in the `Messages.Error` branch, and in
`unexpectedEoS`, which changes to return `([AssistantMessageEvent], Assembler)` — the
close events followed by the terminal built from the *closed* assembler — so `step`'s
`Nothing` branch must handle a list exactly as the OpenAI `step` (516-535) does:
first event yielded, the rest into `pending`, `finished = True`.

OpenAI, `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`: make `translate (Left be)`
return `closeOpenStream now (Just be) ass`, and in `closeOpenStream`'s `finishSeen`
branch compute `terminalErr = mErr <|> (ass ^. #pendingError) <|> …` so a classified
error arriving after `finish_reason` is not discarded (the channel-close call site
passes `Nothing` and is unaffected). In `applyReasoningDelta`'s `Nothing` branch, close
the open text block first:

```haskell
Nothing ->
  let (textEvents, ass0) = closeOpenText ass
      i = ass0 ^. #nextContentIndex
   in ( textEvents <> [ThinkingStart IndexPayload {contentIndex = i}, ThinkingDelta DeltaPayload {contentIndex = i, delta = d}],
        ass0 & #reasoningOpen .~ Just i & #reasoningAccum .~ d & #nextContentIndex .~ (i + 1)
      )
```

`applyVisibleTextDelta` already closes reasoning before opening or appending text, so
after this change at most one of text and thinking is open at a time and every open
takes a fresh index. State the index-allocation rule in the `Assembler` Haddock.

Claude transport, `baikai-claude/src/Baikai/Provider/Claude/Sse.hs`: replace lines
176-180 (the `eitherDecodeStrict`/`fromJSON` pair inside `flushEvent`) with a call to
a new exported `decodeFrame`, and make `flushEvent` ignore an empty payload:

```haskell
-- | Decode one SSE frame. 'Right Nothing' is a frame this transport
-- deliberately skips: an event @type@, or a @content_block_delta@ whose
-- @delta.type@, the SDK has no constructor for. The SDK's decoders have
-- no unknown-tag fallback, and a new frame type from Anthropic must not
-- end a healthy stream. A frame of a known type that still fails to
-- decode is a genuine fault and stays a 'decodeError'.
decodeFrame :: SBS.ByteString -> Either BaikaiError (Maybe Messages.MessageStreamEvent)
decodeFrame payload = case Aeson.eitherDecodeStrict payload of
  Left err -> Left (decodeError (Text.pack err))
  Right val
    | frameIsUnknown val -> Right Nothing
    | otherwise -> case Aeson.fromJSON val of
        Aeson.Error err -> Left (decodeError (Text.pack err))
        Aeson.Success ev -> Right (Just ev)

```

`frameIsUnknown` reads the object's `type` string: a `content_block_delta` is unknown
when its `delta.type` is not one of `text_delta`, `input_json_delta`,
`thinking_delta`, `signature_delta`; any other frame is unknown when its `type` is not
one of `message_start`, `content_block_start`, `content_block_delta`,
`content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`. Both lists are
copied from the SDK's `constructorTagModifier` tables in `Claude/V1/Messages.hs` (find
the file with `mori registry show MercuryTechnologies/claude --full`); a frame with no
`type` field is *not* unknown and still fails as before. `flushEvent` becomes: trim the
payload with `S8.dropWhileEnd isSpace`; if empty, `pure False`; otherwise `decodeFrame`
and dispatch `Left` → `onEvent (Left e)`, `Right Nothing` → nothing, `Right (Just ev)`
→ `onEvent (Right ev)`.

OpenAI transport, `baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs`: in `flushEvent`
(168-178) compute `trimmed = S8.dropWhileEnd isSpace payload`; an empty `trimmed` is
skipped (`pure False`), `trimmed == "[DONE]"` halts (`pure True`), otherwise decode
`trimmed`. EP-5 will later add in-band error-frame detection in `parseChunk`; nothing
in `Sse.hs` should anticipate it.

Tests, with these exact names. In `baikai-claude/test/SseSpec.hs`, a group "block
closing under failure" using the file's `replay` harness (which folds `translate` over
the transport's output) extended to also return the events:

- "a tool call cut off by max_tokens closes with its raw argument text" — frames:
  `message_start`, `content_block_start` (`tool_use`, id `toolu_1`, name `search`),
  one `input_json_delta` with `partial_json` `{"query":"hel`, `content_block_stop`,
  `message_delta` with `stop_reason: max_tokens`, `message_stop`. Expect a
  `ToolCallEnd` whose `toolCall.arguments == Aeson.String "{\"query\":\"hel"`,
  `isCutOffToolCall` true, and an `EventDone` with `reason = Length` whose message
  content holds that same call.
- "a mid-stream transport error closes open blocks before the terminal" — frames:
  `message_start`, `content_block_start` text, one `text_delta` `partial`, then the
  transport's `Left (timeoutError 50)` injected by the test's `onEvent` sequence
  (call `translate (Left …)` after the replayed frames). Expect `TextEnd 0 "partial"`
  immediately before the `EventError`, and the terminal's content `[AssistantText
  "partial"]`.
- "an unknown event type is skipped without ending the stream" — a frame
  `data: {"type":"message_checkpoint","checkpoint":"abc"}` between two known frames;
  `sseFromResponse` yields exactly the two known events and no `Left`.
- "an unknown delta type is skipped without ending the stream" — a
  `content_block_delta` whose `delta.type` is `citations_delta`; same assertion.
- "an empty data heartbeat is ignored" — a frame consisting of `data:` alone; no
  `Left`.

In `baikai-openai/test/SseSpec.hs`:

- "[DONE] with trailing whitespace terminates without a decode error" — the file's
  `successBody` with its last frame replaced by `data: [DONE] \n\n`; exactly the
  three JSON events and no `Left`.
- "an empty data heartbeat is ignored".
- "a tool call cut off by finish_reason length closes with its raw argument text" —
  tool deltas totalling `{"query":"hel`, then `finish_reason: length`; assert as on
  the Claude side, with `stopReason = Length` on the terminal from `closeOpenStream`.
- "a mid-stream transport error closes open blocks before the terminal" — via
  `translate (Left (timeoutError 50))` after a content delta; expect `TextEnd` before
  `EventError` and the partial text on the terminal.
- "reasoning after visible text closes the text block first" — in
  `ReasoningSpec.hs` next to its sibling, using `emptyChunk`/`runChunks`/`eventShape`:
  chunks `contentDelta "a"`, `reasoningDelta "r"`, `contentDelta "b"`, `finishReason
  "stop"`; expect the shape `TextStart:0, TextDelta:0:a, TextEnd:0:a, ThinkingStart:1,
  ThinkingDelta:1:r, ThinkingEnd:1:r, TextStart:2, TextDelta:2:b, TextEnd:2:b,
  EventDone`.

In `baikai/test/StreamSpec.hs`: "a cut-off tool call is never dispatched" — register in
a fresh registry a `Custom "baikai-stream-spec-cutoff"` provider whose `complete`
returns a response with `stopReason = Length` and one `AssistantToolCall` whose
`arguments = Aeson.String "{\"a\":1"`; a dispatcher that records every call in an
`IORef`; `runToolLoopWith reg 4 dispatcher …` returns that response and the `IORef`
is empty; `appendToolResult` on the same response appends a `ToolResultMessage` with
`isError = True` and still does not invoke the dispatcher. Also assert, in the
existing "dangling buffers keep contentIndex order; tool args flushed" case, that
`isCutOffToolCall` is true for the flushed call.


### Milestone 4 — core reassembly fallbacks and the missing `StreamSpec` cases

Scope: `baikai/src/Baikai/Stream.hs`, the documentation this plan owes, and the final
validation. At the end, `reassembleResponse` is total under duplicated, late and
timestamp-less input, the guides and the capability record describe the shipped
behaviour, and the keyless gate is green.

In `Stream.hs`: guard `step` so that once `terminal` is `Just` every further event
returns the state unchanged (first terminal wins, later events ignored); make the
`EventStart` branch `s & #skeleton %~ (\old -> old <|> Just sk) & #responseId %~
(\old -> rid <|> old)`; in `finalizeState` replace the latency computation with the
timestamp-first, wall-clock-fallback rule from the Decision Log
(`millisBetween (s ^. #wallStart) now` when either timestamp is absent). Update the
`ReassemblyState.wallStart` Haddock to say when it is used. Leave `finalContent`'s
failed-terminal branch (line 301, append dangling blocks after the terminal's content)
as it is — plan 38's Decision Log explains why appending is safe (open indices are
always greater than closed ones) — and pin it.

Add to `baikai/test/StreamSpec.hs`, in the existing group:

- "a duplicate EventStart keeps the first skeleton and merges responseId" — two start
  events, the second with an older timestamp and `responseId = Nothing`, after the
  first carried `Just "msg_1"`; expect `responseId = Just "msg_1"` and a latency
  measured from the first skeleton.
- "events after the terminal are ignored" — `EventDone` with content `[text "final"]`
  followed by `TextStart 5`, `TextDelta 5 "late"` and a second `EventError`; expect
  content `[text "final"]`, `stopReason = Stop`, `errorInfo = Nothing`.
- "a failed terminal appends dangling blocks after its content" — closed text at 0,
  dangling thinking at 1, `EventError` whose message content is `[text "closed"]`;
  expect `[text "closed", thinking "…"]`.
- "a successful terminal with empty content falls back to the assembled blocks" —
  closed text at 0 and an `EventDone` with empty content; expect the assembled text.
- "latencyMs falls back to the wall clock when timestamps are absent" — a start
  skeleton and terminal both with `timestamp = Nothing`, a `threadDelay 20000`
  inserted via `Stream.mapM` before the terminal; expect `latencyMs >= 20`.
- the cut-off dispatch case from M3, if not already added there.

Documentation this plan owns. `docs/user/streaming.md`: add a short section "Stopping
early" under Patterns stating the three strengths in caller terms (cancel the draining
thread or wrap it in `timeout` to release the connection immediately; `Stream.take`
releases at the next major GC; the worker never reads more than 64 frames past the
last one you pulled), and fix the `ThinkingEnd` payload row (`ThinkingEndPayload`,
`content :: ThinkingContent`) since the table is being edited. `docs/user/tools.md`:
after "Inspecting tool calls", one paragraph on cut-off calls (`isCutOffToolCall`,
`stopReason = Length`, `runToolLoop` stops, `appendToolResult` reports an error) and
the `arguments` comment in the `ToolCall` listing.
`docs/capabilities/typed-streaming.md`: rewrite the last Limits bullet to the new
guarantee and add `baikai-claude/test/LifecycleSpec.hs` as an `evidence` entry; add a
dated entry to `docs/capabilities/log.md`; run the bundle validation from Concrete
Steps. `CHANGELOG.md` under `[Unreleased]`: one `Added` entry (`toolArgumentsFromText`,
`isCutOffToolCall`, `Baikai.Provider.Internal.StreamWorker`), one `Changed` entry
(cancellation semantics, Claude `EventStart` pre-seeding, cut-off representation,
`runToolLoop`/`appendToolResult` behaviour), one `Fixed` entry (B.3, B.4, B.5, A.8,
B.7). Do not bump versions; EP-10 owns that.

Finally run the keyless gate, tick EP-4 M1–M4 in the masterplan's Progress section and
set its registry row to Complete, and fill this plan's living sections.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai`.

Locate dependency sources with `mori registry show composewell/streamly --full`,
`mori registry show snoyberg/http-client --full` and `mori registry show
MercuryTechnologies/claude --full`; the versions actually compiled against are in
`dist-newstyle/cache/plan.json` (`streamly-core-0.3.1`, `http-client-0.7.19`,
`claude-1.4.0` at planning time).

Build after every milestone:

```bash
cabal build all --enable-tests
```

Run the three affected suites while iterating:

```bash
cabal test baikai baikai-claude baikai-openai --test-show-details=direct
```

Expected shape after M1 (counts vary; what matters is the new groups and PASS):

```text
Test suite baikai-test: RUNNING...
  Baikai.Provider.Internal.StreamWorker
    pullFrame delivers every frame pushed before close:                  OK
    ...
Test suite baikai-test: PASS
Test suite baikai-claude-test: RUNNING...
  Baikai.Provider.Claude lifecycle
    a consumer that stops after three events stops the body reader within the queue bound: OK
    an abandoned stream releases its connection after a major GC:        OK
    cancelling the consumer releases the connection without a GC:        OK
    an asynchronous exception in the worker still closes the channel:    OK
Test suite baikai-claude-test: PASS
Test suite baikai-openai-test: PASS
```

To iterate on one group, filter by name, for example
`cabal test baikai-claude --test-options='-p "lifecycle"'` or
`cabal test baikai --test-options='-p "Baikai.Stream reassembly"'`. A useful
before/after probe: run the M1 lifecycle tests against the pre-plan `Api.hs` and watch
"a consumer that stops after three events" never settle.

The ADR file: find the next number and create it.

```bash
ls docs/adr
# 0001-… 0005-… README.md  → the next free number is 0006 at planning time
$EDITOR docs/adr/0006-a-stream-consumer-that-stops-owns-cancelling-the-producer.md
```

Validate the capability bundle after editing `docs/capabilities/typed-streaming.md`
and `docs/capabilities/log.md`:

```bash
okf validate docs/capabilities --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf graph docs/capabilities
```

Expected: no errors; the graph still shows the `requires: CAP-1` edge for CAP-2.

Before the final commit, run the release skill's keyless gate exactly as
`agents/skills/release/SKILL.md` gives it (the two `baikai_test_path` lines drop the
directories where the `claude` and `codex` binaries live, because `baikai-smoke` gates
its CLI cases on `findExecutable` alone; adjust them to this machine):

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

Every suite must pass, not merely skip; a suite reporting zero tests means something
was filtered that should not have been.

Commit at each milestone boundary. Each message carries the three trailers; for
example:

```text
feat(stream): bounded frame queue and cancellable stream workers

Both HTTP providers fork their SSE worker under Stream.bracketIO, hand
frames through a 64-slot TBQueue with a closed flag set in the worker's
finally, and kill the worker when the stream stops or throws. A consumer
that cancels releases the connection immediately; one that abandons the
stream stops the socket read within 64 frames and releases at the next
major GC. Records the decision in ADR 0006.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(claude): pre-seed EventStart on every failure path

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(stream): close blocks faithfully at cut-offs, mid-stream errors and unknown frames

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(stream): reassembly fallbacks for duplicate starts, late events and missing timestamps

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

Every file this plan edits is named in Plan of Work at the point it is edited; the new
files are `baikai/src/Baikai/Provider/Internal/StreamWorker.hs`,
`baikai/test/StreamWorkerSpec.hs`, `baikai-claude/test/LifecycleSpec.hs`,
`baikai-openai/test/LifecycleSpec.hs` and the ADR, each registered where its
milestone says.


## Validation and Acceptance

Acceptance is behavioural, all of it demonstrable offline from the repository root
with `cabal test baikai baikai-claude baikai-openai --test-show-details=direct` and
finally the keyless `cabal test all` gate.

1. **Bounded read on abandonment.** After `Stream.toList (Stream.take 3 stream)`
   against an endless body, the body reader's call count settles at or below
   `frameQueueCapacity + 8` (both `LifecycleSpec`s, test 1); before this plan it grows
   without bound.
2. **Release on cancellation, no GC.** A consumer thread killed while blocked
   mid-stream sees the response's close hook run within one second with no
   `performMajorGC` (test 3); the killed thread's outcome is `ThreadKilled`.
3. **Release on abandonment, eventual.** The same close hook runs under
   `performMajorGC` polling on an abandoned stream (test 2).
4. **Worker death cannot strand the consumer.** A driver that dies by asynchronous
   exception yields a stream ending in `EventError` inside two seconds (test 4).
5. **`EventStart` first, everywhere.** A 401, a 429 with `Retry-After`, an in-band
   error event before `message_start`, and EOF before `message_start` each produce
   exactly `[EventStart, EventError]` with structured `errorInfo` (Claude SseSpec
   "failure streams are protocol-conformant"); the strengthened `assertErrorContract`
   passes on `rejectsImageToolResultsTest`, `noKeyStreamTest` and
   `rateLimitEvidenceTest` in both packages; a successful Claude stream carries exactly
   one `EventStart` and the id on its terminal.
6. **Cut-off tool calls.** Argument text `{"query":"hel` cut off by `max_tokens` /
   `finish_reason: length` closes as `arguments = Aeson.String "{\"query\":\"hel"`
   with `stopReason = Length` on both providers; `runToolLoopWith` returns without
   calling the dispatcher and `appendToolResult` appends an error result without
   calling it (`StreamSpec` "a cut-off tool call is never dispatched").
7. **Mid-stream failure fidelity.** A `Left` after text deltas emits `TextEnd` before
   `EventError` and the terminal's content holds the partial text, on both providers;
   reassembling those events and reading the raw events now agree.
8. **Interleaved reasoning.** Text, then reasoning, then text yields indices 0, 1, 2
   with every `End` preceding the next `Start` (`ReasoningSpec` "reasoning after
   visible text closes the text block first").
9. **Tolerant transports.** An unknown event type, an unknown delta type, an empty
   `data:` line, and `data: [DONE] ` with a trailing space each leave a healthy
   stream healthy (both `SseSpec`s).
10. **Reassembly fallbacks.** The five new `StreamSpec` cases pass; in particular
    `latencyMs >= 20` when no timestamps are present and a delay of 20 ms sits before
    the terminal.

Live, with a key (optional; none is assumed): `Stream.take 2` on a real call followed
by `performMajorGC` shows the truncated call billed for a few hundred output tokens
rather than the full answer.


## Idempotence and Recovery

Every step is an ordinary source edit under git; builds and tests are side-effect
free (no migrations, no generated files; the cabal edits are plain text). Milestones
leave the tree green, so commit at each boundary and `git restore --source=HEAD --
<files>` to re-approach a milestone that goes sideways. M1 is the only milestone whose
type change (`ProducerState.chan`) fans out inside a file; the compiler's error list is
the remaining-work list. The lifecycle tests are timing-sensitive by nature; every
wait is a bounded poll with a generous ceiling (one second for the no-GC case, five
seconds of GC polling for the eventual case), and a flaky failure is a signal to
re-read the Decision Log's three strengths, not to widen the bound. The new test
modules use per-test `Custom` api tags where they touch a registry, so re-running the
suite in one process cannot collide. If `okf validate` rejects the capability edit,
the usual cause is a missing `log.md` entry; add it and re-run.


## Interfaces and Dependencies

No new package dependencies: `stm` (already a dependency of every test suite and, if
not of the `baikai` library, added there), `streamly-core` (`Streamly.Data.Stream`:
`bracketIO`, `unfoldrM`, `concatEffect`), `base` (`Control.Concurrent.forkIOWithUnmask`,
`killThread`, `Control.Exception.mask_`, `finally`), `aeson`, `http-client` (test-side
`Network.HTTP.Client.Internal` for the fake `Response`, as `SseSpec` already uses).

Final shapes at the end of the plan; EP-5, EP-8 and EP-10 code against these.

In `baikai/src/Baikai/Provider/Internal/StreamWorker.hs` (exposed, outside PVP):

```haskell
data FrameQueue a
frameQueueCapacity :: Natural                                   -- 64
newFrameQueue :: IO (FrameQueue a)
pushFrame :: FrameQueue a -> a -> IO ()                         -- blocks when full
closeFrames :: FrameQueue a -> IO ()                            -- never blocks
pullFrame :: FrameQueue a -> IO (Maybe a)                       -- Nothing iff empty and closed
forkFrameWorker :: FrameQueue a -> IO () -> IO ThreadId         -- body `finally` closeFrames
withFrameWorker :: FrameQueue a -> IO () -> Stream IO b -> Stream IO b
```

In `baikai/src/Baikai/Content.hs`:

```haskell
toolArgumentsFromText :: Text -> Aeson.Value
isCutOffToolCall :: ToolCall -> Bool
-- ToolCall is unchanged in shape; its Haddock defines a String 'arguments' as cut off.
```

In both provider `Api.hs` modules the exported surface is unchanged
(`claudeMessagesStreamWith`, `openaiChatStreamWith`, `SseDriver`, `Assembler (..)`,
`emptyAssembler`, `translate`, and on OpenAI `closeOpenStream`), with these documented
semantics: the stream returned is `Stream.bracketIO`-wrapped; `pending` begins with one
`EventStart` whose `responseId` is `Nothing`; `translate (Left be)` closes open blocks
before its terminal; a cut-off tool call closes via `toolArgumentsFromText`. Claude's
`unexpectedEoS :: UTCTime -> Assembler -> ([AssistantMessageEvent], Assembler)` and
new `closeOpenBlocks :: Assembler -> ([AssistantMessageEvent], Assembler)` are
module-internal. `Baikai.Provider.Claude.Sse` additionally exports
`decodeFrame :: ByteString -> Either BaikaiError (Maybe Messages.MessageStreamEvent)`.
EP-5's `parseChunk` region (OpenAI `Api.hs:343-385`) is untouched by this plan; EP-8's
`immediateError` evidence content is untouched (the event shape it returns is already
`[EventStart, EventError]`).

In `baikai/src/Baikai/Stream.hs` the exported surface is unchanged;
`reassembleResponse` additionally guarantees: first `EventStart` wins for the skeleton,
`responseId` merges with `<|>` on every event that carries one, events after the first
terminal are ignored, and `latencyMs` falls back to the reassembler's wall clock. In
`baikai/src/Baikai/Provider/Registry.hs`, `runToolLoopWith` stops when any tool call is
cut off; in `baikai/src/Baikai/Context.hs`, `appendToolResult` never dispatches a
cut-off call.

Protocol invariant for dependent plans, now without exceptions: exactly one
`EventStart` (first), per-block `_Start`/`_Delta`/`_End`, then exactly one `EventDone`
or `EventError` (last). `docs/user/streaming.md`'s Notes still permit interleaving
across indices for third-party providers; EP-11 reconciles that wording with
`Event.hs:57-61`.
