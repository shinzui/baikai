---
id: 38
slug: carry-full-fidelity-through-the-streaming-event-protocol
title: "Carry full fidelity through the streaming event protocol"
kind: exec-plan
created_at: 2026-07-02T04:11:52Z
intention: "intention_01kwjgavf8e3ps2c49sn1qjr1m"
master_plan: "docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md"
---

# Carry full fidelity through the streaming event protocol

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

baikai exposes every model call as a stream of typed events (`AssistantMessageEvent` in
`baikai/src/Baikai/Stream/Event.hs`), and the synchronous `Response` a caller gets from
`completeRequest` is produced by folding that stream back together
(`reassembleResponse` in `baikai/src/Baikai/Stream.hs`). Today that fold is lossy: it
rebuilds thinking blocks with `signature = Nothing, redacted = False` and throws away
the terminal event's correct message, so **every blocking call through an API provider
loses thinking signatures** — replaying such a turn sends `signature: ""` to Anthropic
and gets an HTTP 400. The event algebra also cannot carry the provider's message id
(`Response.responseId` is hardcoded `Nothing`), asynchronous exceptions (Ctrl-C,
`timeout`, `cancel`) are swallowed into `EventError` terminals, error-only streams
violate the documented "the stream begins with a single `EventStart`" protocol, the
missing-`End` recovery path loses block ordering and silently drops partial tool-call
arguments, and `latencyMs` can go hugely negative because it trusts provider-supplied
timestamps.

After this plan, the event algebra carries full fidelity end to end. Concretely, a
caller can:

- call `completeRequest` against a thinking-capable model and replay the returned
  assistant turn with its signature and redacted flag intact (observable today via the
  round-trip unit tests this plan adds; observable live once EP-7,
  `docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md`, wires the
  providers);
- read `Response.responseId` and get the provider's message id (Anthropic's
  `message_start.id` already flows on the streaming path after this plan; the CLI
  `session_id` gains a conduit that EP-7/EP-3 follow-ups can fill);
- press Ctrl-C or wrap a call in `System.Timeout.timeout` and have cancellation
  actually cancel instead of yielding a bogus `EventError` response;
- rely on the invariant that *every* stream — including error-only streams — starts
  with `EventStart` and ends with exactly one terminal event;
- trust that `latencyMs >= 0` always, and that a stream that dies mid-block still
  yields all partial content in the right order, including partial tool-call
  arguments.

This is the keystone plan of the masterplan's wave 1: EP-6
(`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`) and EP-7
(`docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md`) hard-depend
on the payload shapes fixed here. The exact final type definitions are in the
Interfaces and Dependencies section so those plans can code against them without
reading this plan's diff.


## Progress

- [x] M1: `ThinkingEndPayload` added; `ThinkingEnd` carries `ThinkingContent`
      (`baikai/src/Baikai/Stream/Event.hs`) (2026-07-03)
- [x] M1: `responseId :: Maybe Text` added to `StartPayload` and `TerminalPayload`;
      `doneTerminal`/`errorTerminal` take it as their first argument
      (2026-07-03)
- [x] M1: mechanical compile-through of `baikai/src/Baikai/Stream.hs` (step, blockEvent,
      eventsFor) against the new payloads
      (2026-07-03)
- [x] M1: mechanical compile-through of `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
      (populates `responseId` and full `ThinkingContent` — values already at hand)
      (2026-07-03)
- [x] M1: mechanical compile-through of `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`
      (passes `Nothing` for `responseId`)
      (2026-07-03)
- [x] M1: mechanical compile-through of `baikai-effectful/test/StubProvider.hs` and
      `baikai/test/ErrorInfoSpec.hs`
      (2026-07-03)
- [x] M1: `cabal build all --enable-tests` and all four test suites green
      (2026-07-03)
- [x] M2: `ReassemblyState` reworked (wall-clock start, `responseId`, terminal record
      with done/error discriminator)
      (2026-07-03)
- [x] M2: terminal-authoritative content resolution in `finalizeState`
      (2026-07-03)
- [x] M2: `Response.responseId` populated from events
      (2026-07-03)
- [x] M2: dangling buffers merged in `contentIndex` order; partial tool-call arguments
      flushed as a `ToolCall`
      (2026-07-03)
- [x] M2: `latencyMs` measured on the reassembler's own wall clock and clamped at zero
      (2026-07-03)
- [x] M2: new `baikai/test/StreamSpec.hs` covering signature round-trip,
      terminal-authoritative content, responseId carriage, dangling ordering, latency
      clamp; registered in `baikai/baikai.cabal` and `baikai/test/Main.hs`
      (2026-07-03)
- [x] M3: `tryAny` replaced with sync-only `trySync` in `baikai/src/Baikai/Stream.hs`
      (2026-07-03)
- [x] M3: `EventStart`-first on the no-provider stream and `liftCompleteToStream`'s
      exception path
      (2026-07-03)
- [x] M3: `EventStart`-first in both providers' `immediateError`; both provider tests
      updated
      (2026-07-03)
- [x] M3: protocol haddock in `baikai/src/Baikai/Stream/Event.hs` and
      `liftCompleteToStream`'s haddock updated to the strengthened invariant
      (2026-07-03)
- [x] M3: async-passthrough and EventStart-first tests in `baikai/test/StreamSpec.hs`
      (2026-07-03)
- [x] M4: full validation matrix run and recorded; Interfaces section verified against
      the compiled code; masterplan Progress updated; living sections finalized
      (2026-07-03)


## Surprises & Discoveries

- The M1 compile-through exposed one extra direct `TerminalPayload` positional pattern
  in `baikai-smoke/test/Smoke.hs`, outside the four-suite checklist. It was converted
  to a record pattern in the M1 commit so future terminal-payload field additions are
  less brittle. (2026-07-03)
- The local Streamly source confirmed `Streamly.Data.Fold.foldlM'` accepts a monadic
  initial state (`m b`), even though the curated fold docs summary showed a pure
  initial value. The implementation therefore captures `wallStart` in the fold's
  initial action as planned. (2026-07-03)


## Decision Log

- Decision: `ThinkingEnd` gets a dedicated payload type `ThinkingEndPayload` carrying
  the full `Baikai.Content.ThinkingContent` (text, signature, redacted flag) instead of
  the bare-text `BlockEndPayload`, AND the reassembler treats the terminal event's
  message content as authoritative when non-empty. The masterplan's Integration Points
  recommend both halves; both are adopted.
  Rationale: the payload change fixes fidelity for consumers that fold per-block events
  (including the reassembler's recovery path and third-party stream consumers); the
  terminal-authoritative change fixes fidelity even for provider event streams that
  predate the new payload, and removes the absurdity of discarding the one message the
  provider assembled correctly. Either alone leaves a lossy path. `TextEnd` keeps
  `BlockEndPayload` — plain text has no metadata to lose.
  Date: 2026-07-02
- Decision: the provider message id travels as `responseId :: Maybe Text` on **both**
  `StartPayload` and `TerminalPayload`; the reassembler prefers the terminal's value
  and falls back to the start's. `doneTerminal` and `errorTerminal` take it as a new
  first parameter rather than defaulting it.
  Rationale: Anthropic learns the id at `message_start` (the Claude assembler already
  parses `mr ^. #id`, write-only today), so the start payload must carry it; the CLI
  providers and `liftCompleteToStream` only know it when the resolved `Response` exists
  (the claude CLI parses a `session_id` it currently drops), so the terminal must carry
  it too. Making it a positional parameter of the smart constructors (instead of a
  defaulted field) forces every current and future emitter — EP-6's and EP-7's new
  construction sites included — to make an explicit choice; that is the whole point of
  the smart constructors per their haddock.
  Date: 2026-07-02
- Decision: EP-6 tightened `errorTerminal`'s final argument from `Maybe BaikaiError`
  to `BaikaiError`; the response-id argument added by this plan remains first, so the
  final signature is `Maybe Text -> StopReason -> Message -> BaikaiError ->
  TerminalPayload`.
  Rationale: this is an EP-6-owned invariant change, but it changes the event algebra
  hand-off contract this plan created. Recording it here keeps the contract copyable for
  EP-7 and later providers.
  Date: 2026-07-03
- Decision: content resolution in `finalizeState` is: (1) terminal missing → use the
  event-assembled blocks (recovery); (2) `EventDone` terminal → use the terminal
  message's content when non-empty, else the event-assembled blocks; (3) `EventError`
  terminal → use the terminal message's content when non-empty **and append any
  dangling (never-closed) buffers after it in `contentIndex` order**, else the
  event-assembled blocks.
  Rationale: for success terminals the provider's assembled message is strictly more
  correct than the event fold (it carries signatures today and anything the algebra
  learns to carry later). For error terminals, providers only include blocks that
  *closed* before the failure (`finalMessageOnError` in the Claude provider), so the
  reassembler's dangling buffers hold partial content the terminal cannot have;
  appending them preserves masterplan 4's "partial output is always recoverable"
  promise. Appending (rather than index-merging into the terminal's vector) is safe
  because blocks open and close in increasing `contentIndex` order, so unclosed indices
  are always greater than every closed index. There is no duplication risk: a block
  that any event closed is not dangling, and the OpenAI provider force-closes open
  blocks (emitting their `End` events) before its error terminal.
  Date: 2026-07-02
- Decision: error-only streams gain a synthetic `EventStart` rather than amending the
  documented protocol to permit `EventStart`-less streams. Applies to the no-provider
  stream and `liftCompleteToStream`'s exception path in `baikai/src/Baikai/Stream.hs`,
  and to `immediateError` in both `baikai-claude/src/Baikai/Provider/Claude/Api.hs` and
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` (identical shape, identical
  two-line fix; the openai and claude package tests asserting the deviant one-event
  shape are updated).
  Rationale: consumer simplicity — every consumer can unconditionally read the first
  event as `EventStart` (the `baikai-effectful` stub tests already assert this) instead
  of special-casing error-only streams. The reassembler tolerates both shapes either
  way, so the cost is two extra construction sites, not a redesign.
  Date: 2026-07-02
- Decision: one known deviation remains out of scope: the Claude provider's *mid-call*
  failure paths (`unexpectedEoS`, and an SDK `Error` frame arriving before
  `message_start`) can still emit a lone `EventError`, because that provider only emits
  `EventStart` upon `message_start` (unlike the OpenAI provider, which pre-seeds it).
  Restructuring the Claude producer to pre-seed `EventStart` without double-emitting it
  is real provider work, not a mechanical update, and is delegated to EP-7
  (`docs/plans/40-...`) with this Decision Log entry as the pointer. The strengthened
  haddock in `Baikai.Stream.Event` therefore names this as a known, temporary
  provider-side gap.
  Date: 2026-07-02
- Decision: an unclosed tool-call argument buffer is flushed (recovery path only) as an
  `AssistantToolCall` with `id_ = ""`, `name = ""`, and `arguments` set to the decoded
  JSON when the accumulated text parses, otherwise `Aeson.String <raw accumulated
  text>` so no bytes are silently dropped.
  Rationale: the reassembler cannot know the tool's id or name — `ToolCallStart`
  carries only the index (id/name live in provider assemblers) — and inventing a new
  content constructor for "partial tool call" would be a breaking algebra change out of
  proportion to a recovery path. Preserving the raw text inside `Aeson.String` is
  lossless and inspectable; a consumer that sees an empty-id `ToolCall` after an error
  terminal knows it is partial.
  Date: 2026-07-02
- Decision: `latencyMs` is measured on the reassembler's own wall clock — captured when
  the fold initializes (via `Fold.foldlM'`'s monadic initial action) and again in
  `finalizeState` — and clamped at zero. Provider-supplied message timestamps are no
  longer used for latency.
  Rationale: provider/fixture timestamps are data, not clocks; `TraceSpec`'s
  `stubResponse` (fixture timestamp `2026-05-14`) currently produces a latency of
  roughly minus four billion milliseconds. Wall-clock capture inside the fold measures
  what the caller actually waited through the reassembling consumer, and the clamp
  guards against clock adjustments.
  Date: 2026-07-02
- Decision: `tryAny` (which catches `SomeException`, async included) is replaced by
  `trySync`, which rethrows anything wrapped in `SomeAsyncException` and returns `Left`
  only for synchronous exceptions. The same-shaped `try @SomeException` calls inside
  the two providers' worker threads are *not* touched here (worker threads are not the
  caller's thread, so cancellation of the consumer is not defeated by them; their error
  handling belongs to EP-6/EP-7).
  Date: 2026-07-02
- Decision: the following Claude-provider edits are classified as trivial mechanical
  updates and included here, even though provider work generally belongs to EP-7:
  populating `StartPayload.responseId` from `mr ^. #id` at `Message_Start`, passing
  `ass ^. #responseId` to `doneTerminal`/`errorTerminal`, emitting the
  already-constructed `ThinkingContent` value in the new `ThinkingEndPayload`, and
  prepending the synthetic `EventStart` in `immediateError`.
  Rationale: every one of these values already exists at the construction site the type
  change forces us to edit anyway; leaving them `Nothing`/empty would mean writing
  deliberately worse code during the mechanical pass. Anything requiring new parsing
  (OpenAI chunk `id`, redacted-thinking `data_` payloads, CLI `session_id` into
  `mkResponse`) stays with EP-7.
  Date: 2026-07-02


## Outcomes & Retrospective

Implemented on 2026-07-03 across three commits:

- `696e8c4` reshaped the event algebra: `ThinkingEndPayload` carries full
  `ThinkingContent`, `StartPayload` and `TerminalPayload` carry `responseId`, and
  Claude emits the id/signature values already available at its construction sites.
- `849afa5` made reassembly full-fidelity: terminal content wins when present,
  `Response.responseId` is populated from terminal-then-start payloads, dangling
  buffers are recovered in `contentIndex` order including partial tool-call arguments,
  and latency is measured from the reassembler wall clock with a zero clamp.
- `7d4edb1` restored protocol and cancellation invariants: lifted blocking handlers
  rethrow async exceptions, core synthetic errors and provider request-preparation
  errors now begin with `EventStart`, and tests cover both cases.

The compiled payload definitions in `baikai/src/Baikai/Stream/Event.hs` match the
Interfaces and Dependencies section: `ThinkingEnd ThinkingEndPayload`,
`StartPayload { partial, responseId }`,
`TerminalPayload { reason, message, responseId, errorInfo }`,
`doneTerminal :: Maybe Text -> StopReason -> Message -> TerminalPayload`, and
`errorTerminal :: Maybe Text -> StopReason -> Message -> BaikaiError ->
TerminalPayload`.

Validation completed:

- `cabal build all --enable-tests` — passed (`Up to date` on final M4 run).
- `cabal test baikai baikai-claude baikai-openai baikai-effectful --test-show-details=direct`
  — passed; `baikai` reported `All 108 tests passed`, `baikai-claude` `All 20 tests
  passed`, `baikai-openai` `All 23 tests passed`, and `baikai-effectful` `All 4 tests
  passed`.

Known hand-off: the protocol haddock intentionally records the remaining Claude
mid-call pre-`message_start` EventStart gap for EP-7. EP-6 and EP-7 can now rely on
the final payload shapes and the reassembler semantics described in this plan.


## Context and Orientation

baikai is a multi-package Haskell workspace (root: this repository) that gives one
vocabulary for calling LLM providers. The packages touched here:

- `baikai/` — the core. `baikai/src/Baikai/Stream/Event.hs` defines the streaming
  "event algebra": the sum type `AssistantMessageEvent` whose values a provider emits
  one by one while a model call is in flight, plus one small payload record per event
  shape. `baikai/src/Baikai/Stream.hs` defines the consumer side: `streamRequest`
  dispatches to a registered provider's stream; `reassembleResponse` is a streamly
  `Fold` that replays events into a synchronous `Response`
  (`baikai/src/Baikai/Response.hs`); `streamingComplete` runs that fold;
  `liftCompleteToStream` wraps a blocking handler as a synthetic event stream so every
  provider can populate its `stream` field.
- `baikai-claude/` — the Anthropic Messages API provider
  (`baikai-claude/src/Baikai/Provider/Claude/Api.hs`) and a claude-CLI provider
  (`baikai-claude/src/Baikai/Provider/Claude/Cli.hs`).
- `baikai-openai/` — the OpenAI Chat Completions provider
  (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`).
- `baikai-effectful/` — an effectful-effects binding whose test stub
  (`baikai-effectful/test/StubProvider.hs`) constructs event payloads directly.

Terms used below:

- **Event algebra**: the closed sum `AssistantMessageEvent`. A conforming stream is
  `EventStart`, then per-content-block `_Start`/`_Delta`/`_End` trios keyed by an
  integer `contentIndex`, then exactly one terminal event: `EventDone` (success) or
  `EventError` (failure). Both terminals carry a `TerminalPayload` holding the fully
  assembled assistant `Message`.
- **Reassembly**: `reassembleResponse` folds events into a `ReassemblyState` (buffers
  of open text/thinking/tool-argument accumulators plus closed blocks keyed by
  `contentIndex`) and `finalizeState` turns that state into a `Response`.
- **Dangling buffer**: an accumulator whose `_End` event never arrived (producer died
  mid-block). Flushing them is the recovery path.
- **Thinking block**: `Baikai.Content.ThinkingContent` — reasoning text plus an opaque
  provider `signature` (must be replayed verbatim or Anthropic rejects the turn) and a
  `redacted` flag.
- **Synchronous vs asynchronous exceptions**: a synchronous exception is raised by the
  action itself (HTTP failure, decode error); an asynchronous one is thrown *into* the
  thread from outside (`throwTo`, `System.Timeout.timeout`, Ctrl-C) and is wrapped in
  `Control.Exception.SomeAsyncException` by standard throwers. Catching async
  exceptions and continuing defeats cancellation.

The six defects this plan fixes, all verified in the current source (line numbers as of
commit `759ddc9`; the review is `docs/reviews/correctness-and-api-review.md`,
Theme 2 item 3 and Theme 10 items 1–4):

1. **Thinking fidelity lost in reassembly** (`baikai/src/Baikai/Stream.hs:172-179` and
   `:199-202`). `step`'s `ThinkingEnd` branch rebuilds the block as
   `ThinkingContent {thinking = body, signature = Nothing, redacted = False}` because
   `BlockEndPayload` only carries text. Then `finalizeState` calls
   `overrideBlocksAndReason`, which **replaces** the terminal message's content — the
   one copy that still has the signature (the Claude provider's `handleBlockStop`
   builds a correct `ThinkingContent` into its `closed` map and its `Message_Stop`
   terminal carries it) — with the lossy event-assembled blocks. Failure scenario:
   `complete = streamingComplete claudeMessagesStream` for the API provider, so every
   *blocking* thinking call returns signature-less blocks; replaying that turn maps
   through `assistantContentToBlock` (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:762-767`)
   as `signature = fromMaybe "" …` → Anthropic returns HTTP 400 and multi-turn
   thinking conversations are impossible.
2. **`responseId` cannot travel** (`baikai/src/Baikai/Stream.hs:214`). `finalizeState`
   hardcodes `responseId = Nothing`; no event payload has a slot for it. The Claude
   assembler already parses `message_start.id` into `Assembler.responseId`
   (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:327`) but nothing reads it; the
   claude CLI parses `session_id` (`baikai-claude/src/Baikai/Provider/Claude/Cli.hs:127`)
   and `mkResponse` drops it. No caller ever sees a provider message id, so log
   correlation and Anthropic support requests have nothing to reference.
3. **Async exceptions swallowed** (`baikai/src/Baikai/Stream.hs:305-307`).
   `tryAny = Control.Exception.try @SomeException` inside `liftCompleteToStream`
   catches `ThreadKilled`/`Timeout`/`UserInterrupt` too. Failure scenario: a caller
   wraps `completeRequest` (CLI provider, or any lifted handler) in `timeout`; the
   timeout's async exception is converted into an `EventError` terminal, the stream
   "succeeds", and `timeout` returns `Just` a bogus error response — cancellation is
   defeated, Ctrl-C during a hung CLI call produces a garbage response instead of
   stopping.
4. **Error-only streams skip `EventStart`** (`baikai/src/Baikai/Stream.hs:100` and
   `:303`). The no-provider stream and `liftCompleteToStream`'s exception path emit a
   lone `EventError`, contradicting the haddock in `baikai/src/Baikai/Stream/Event.hs`
   ("The stream begins with a single 'EventStart'"). Both providers' `immediateError`
   (`baikai-claude/src/Baikai/Provider/Claude/Api.hs:511-523`,
   `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs:703-715`) have the same shape, and
   both packages' `rejectsImageToolResultsTest` assert the deviant single-event list.
   Consumers written against the documented protocol (first event is the skeleton)
   crash or misbehave on exactly the calls that failed.
5. **Missing-`End` recovery is lossy** (`baikai/src/Baikai/Stream.hs:222-236`).
   `assembleBlocks` appends dangling text/thinking buffers *after* all closed blocks
   (a dangling block at index 1 sorts after a closed block at index 2, so replaying the
   turn reorders the conversation) and does not flush `toolArgsBuf` at all — a stream
   that dies mid-tool-call silently loses the accumulated argument JSON.
6. **`latencyMs` unclamped and clock-free** (`baikai/src/Baikai/Stream.hs:203-207`).
   Latency is `terminal message timestamp − EventStart message timestamp`; both are
   provider-supplied data. `TraceSpec`'s `stubResponse`
   (`baikai/test/TraceSpec.hs:57-74`, fixture timestamp `2026-05-14`) makes this hugely
   negative on today's date; any provider clock skew does the same in production.

Provider emission patterns you must understand before editing (read, but do not
redesign — EP-7 owns provider behavior):

- Claude (`baikai-claude/src/Baikai/Provider/Claude/Api.hs`): a worker thread feeds SDK
  events through a `Chan`; `translate` maps `Message_Start` → `EventStart` (this is
  where the id is parsed), `Content_Block_Start/Delta/Stop` →
  `handleBlockStart`/`handleBlockDelta`/`handleBlockStop` (the `Stop` handler already
  builds the full `ThinkingContent` with signature from its `thinkSig` accumulator),
  `Message_Stop` → `EventDone (doneTerminal …)`. Signature deltas
  (`Delta_Signature_Delta`) emit no public event; they accumulate into `thinkSig`.
- OpenAI (`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`): pre-seeds
  `pending = [EventStart …]` before any chunk; `parseChunk` reads only
  content/finish/tool/usage fields (not the chunk `id`); `closeOnFinish` closes blocks
  on `finish_reason` and defers the terminal to channel close (`closeOpenStream`) so
  the trailing usage chunk lands.

Everything this plan changes is additive-or-mechanical from the providers' point of
view: new payload fields/types they must construct (values already at hand or
`Nothing`), and two-line `immediateError` fixes. All behavioral provider work
(emitting redacted blocks, parsing OpenAI ids, reasoning extraction) stays in EP-7.


## Plan of Work

The work is four milestones. M1 reshapes the algebra and mechanically compiles the
workspace through it; M2 rewrites reassembly for fidelity; M3 enforces the protocol and
exception invariants; M4 is the validation and hand-off pass. Each milestone leaves
`cabal build all --enable-tests` and the four test suites green.


### Milestone 1 — Reshape the event algebra and compile the workspace through it

Scope: the payload type changes in `baikai/src/Baikai/Stream/Event.hs` and every
mechanical edit needed to compile against them, with no behavior change beyond
carrying the new data. At the end, the algebra can express a thinking block's
signature/redacted flag and a provider message id, and the Claude provider already
emits both (because the values sit at the exact construction sites the type change
forces us to edit). Acceptance: full build and all existing tests pass (two suites
need the mechanical updates described below).

In `baikai/src/Baikai/Stream/Event.hs`:

- Import `ThinkingContent` from `Baikai.Content` (alongside the existing `ToolCall`
  import).
- Change the `ThinkingEnd` constructor from `ThinkingEnd BlockEndPayload` to
  `ThinkingEnd ThinkingEndPayload` and add the new payload record (exact definition in
  Interfaces and Dependencies). Update the constructor's haddock: the payload's
  `content` is the full closed `ThinkingContent` — concatenated reasoning text plus the
  provider `signature` and `redacted` flag; the concatenation of the preceding
  `ThinkingDelta`s equals `content`'s `thinking` field.
- Change `StartPayload` from a newtype to a data record adding
  `responseId :: !(Maybe Text)` — the provider's message id when known this early
  (Anthropic's `message_start.id`), `Nothing` otherwise.
- Add `responseId :: !(Maybe Text)` to `TerminalPayload` — the provider's message id
  when known by stream end (this is where lifted blocking responses and CLI session
  ids travel). Document that a consumer should prefer the terminal's value, falling
  back to the start's, which is exactly what `reassembleResponse` does after M2.
- Change the smart constructors to take the id as their first argument (exact
  signatures in Interfaces and Dependencies) and export `ThinkingEndPayload (..)`.
  Update the module's payload-list haddock sentence to mention `ThinkingEndPayload`.

In `baikai/src/Baikai/Stream.hs` (mechanical only in this milestone; behavioral
changes are M2/M3):

- `step`'s `EventStart` pattern: bind the new field
  (`EventStart StartPayload {partial = sk}` still compiles as a record pattern, so the
  only required change is in M2 when the field is consumed; no edit needed if record
  patterns are used — verify).
- `step`'s `ThinkingEnd` branch: match `ThinkingEndPayload {contentIndex = i, content = tc}`
  and insert `AssistantThinking tc` into `blocks` (this is a one-line fidelity fix that
  falls out of the type change; keep it here rather than M2 because the old code no
  longer typechecks).
- `blockEvent`'s thinking branch: emit the full block —

  ```haskell
  AssistantThinking th@ThinkingContent {thinking = t} ->
    [ ThinkingStart IndexPayload {contentIndex = i},
      ThinkingDelta DeltaPayload {contentIndex = i, delta = t},
      ThinkingEnd ThinkingEndPayload {contentIndex = i, content = th}
    ]
  ```

- `eventsFor`: construct `StartPayload {partial = skeleton, responseId = resp ^. #responseId}`
  and `EventDone (doneTerminal (resp ^. #responseId) reason msg)`. This is the conduit
  that lets a CLI provider's `session_id` (once EP-7 puts it on `Response.responseId`
  in `mkResponse`) survive the lift-then-reassemble round trip.
- `errorEvent` and `noProviderEvent`: pass `Nothing` as the new first argument of
  `errorTerminal` (their `EventStart` treatment is M3).

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (all values already at hand):

- `translate`'s `Message_Start` branch: `EventStart StartPayload {partial = skeleton,
  responseId = Just (mr ^. #id)}` — the id the assembler already stores.
- `translate`'s `Message_Stop` branch: `doneTerminal (ass ^. #responseId) (ass ^. #stopReason) msg`.
- `translate`'s `Error` branch and `unexpectedEoS`: `errorTerminal (ass ^. #responseId) …`.
- `handleBlockStop`'s thinking case: it already builds
  `block = Content.AssistantThinking thinkingContent`; emit
  `ThinkingEnd ThinkingEndPayload {contentIndex = i, content = <that ThinkingContent>}`
  (name the intermediate value so both the `closed` map and the event share it). This
  single mechanical change is what makes signatures flow on the Claude streaming path.
- `immediateError`: pass `Nothing` for the id (its `EventStart` treatment is M3).

In `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`: add `responseId = Nothing` to the
pre-seeded `StartPayload` and pass `Nothing` at the four `doneTerminal`/`errorTerminal`
sites (`translate`'s error branch, `closeOpenStream`'s two terminals, `immediateError`).
The OpenAI chunk `id` is not parsed today; parsing it is EP-7's work, not a mechanical
update.

Mechanical test/fixture updates: `baikai-effectful/test/StubProvider.hs` (add
`responseId = Nothing` to its `StartPayload`; `doneTerminal Nothing Stop …`) and
`baikai/test/ErrorInfoSpec.hs` (`errorTerminal Nothing ErrorReason …`).

`Baikai.Trace` (`baikai/src/Baikai/Trace.hs`) matches `TerminalPayload {message = msg}`
with record patterns and needs no edit; confirm by building.

Verification: from the repository root,
`cabal build all --enable-tests && cabal test baikai baikai-claude baikai-openai baikai-effectful`
— everything green, no behavior assertions changed yet.


### Milestone 2 — Full-fidelity reassembly

Scope: rewrite the consumer side in `baikai/src/Baikai/Stream.hs` so nothing the
algebra now carries is dropped, and add the test module that locks it in. At the end,
`streamingComplete`/`completeRequest` preserve thinking signatures and redacted flags,
populate `Response.responseId`, recover partial streams in order (including partial
tool arguments), and report a clamped wall-clock latency.

Edits, all in `baikai/src/Baikai/Stream.hs`:

- **State**: rework `ReassemblyState` — drop `startTime` (was only used for latency),
  add `wallStart :: !UTCTime` (the reassembler's own clock at fold start),
  `responseId :: !(Maybe Text)`, and replace the terminal triple with a small internal
  record that remembers whether the terminal was `EventDone` or `EventError`:

  ```haskell
  -- | What the terminal event told us, plus which terminal it was.
  data TerminalSeen = TerminalSeen
    { reason :: !StopReason,
      message :: !Message,
      errorInfo :: !(Maybe BaikaiError),
      failed :: !Bool
    }
    deriving stock (Show, Generic)
  ```

  `initialState` becomes `initialState :: Model -> UTCTime -> ReassemblyState`.
- **Fold construction**: capture the wall clock in the fold's monadic initial action:

  ```haskell
  reassembleResponse :: Model -> Fold IO AssistantMessageEvent Response
  reassembleResponse m =
    Fold.rmapM
      finalizeState
      (Fold.foldlM' (\s e -> pure (step s e)) (initialState m <$> getCurrentTime))
  ```

  (`Fold.foldlM' :: Monad m => (b -> a -> m b) -> m b -> Fold m a b` from
  `Streamly.Data.Fold`; the initial action runs when the fold starts driving, which is
  when the caller's wait begins.)
- **`step`**: `EventStart StartPayload {partial = sk, responseId = rid}` sets
  `#skeleton` and `#responseId .~ rid`. `EventDone`/`EventError` store `TerminalSeen`
  (with `failed = False`/`True`) and merge the id:
  `#responseId %~ (\old -> rid <|> old)` (import `Control.Applicative ((<|>))`).
- **`assembleBlocks`**: split into two pieces so the terminal-authoritative rule can
  address them separately. `danglingBlocks :: ReassemblyState -> IntMap AssistantContent`
  converts every non-empty open buffer: text buffers to `AssistantText`, thinking
  buffers to `AssistantThinking ThinkingContent {thinking = t, signature = Nothing,
  redacted = False}` (the reassembler has no signature for an unclosed block — that is
  correct, not lossy), and tool-argument buffers to the recovery `ToolCall` from the
  Decision Log (`id_ = ""`, `name = ""`, `arguments` = decoded JSON or
  `Aeson.String raw`). The merged event-assembled view is
  `IntMap.elems (IntMap.union (s ^. #blocks) (danglingBlocks s))` — `IntMap.union` is
  left-biased so a closed block always wins, and `elems` yields ascending
  `contentIndex` order, which fixes the ordering defect. Import
  `ToolCall (..)` from `Baikai.Content`.
- **`finalizeState`**: implement the content-resolution rule from the Decision Log:

  ```haskell
  -- inside finalizeState, sketch:
  let assembled = ...            -- merged closed+dangling, ascending index
      dangling  = ...            -- dangling only, ascending index
      terminalContent = case terminalMsg of
        AssistantMessage AssistantPayload {content = c} -> c
        _ -> Vector.empty
      finalContent
        | Vector.null terminalContent = assembled
        | failed = terminalContent <> Vector.fromList (IntMap.elems dangling)
        | otherwise = terminalContent
  ```

  where the no-terminal case keeps today's `synthesizeTerminal` (whose blocks are now
  the merged `assembled`). `overrideBlocksAndReason` keeps its role — reason, usage,
  errorMessage, timestamp from the terminal message — but receives `finalContent`.
  Populate `responseId = s ^. #responseId` in the built `Response`, and compute

  ```haskell
  latency = max 0 (round (realToFrac (Data.Time.Clock.diffUTCTime now (s ^. #wallStart)) * (1000 :: Double)))
  ```

  with `now` the `getCurrentTime` already sampled at the top of `finalizeState`.
- Update the haddocks on `reassembleResponse`, `assembleBlocks`' replacement, and
  `finalizeState`-adjacent comments to describe terminal-authoritative resolution and
  the recovery semantics, so EP-6 edits the right mental model.

New test module `baikai/test/StreamSpec.hs`, registered in `baikai/test/Main.hs`
(import and add to the `testGroup`) and in the `other-modules` list of the
`test-suite baikai-test` stanza in `baikai/baikai.cabal`. Build the events by hand
(`Stream.fromList` + `Stream.fold (reassembleResponse model)`) or through
`liftCompleteToStream`; use a `Custom "baikai-stream-spec…"` api tag pattern like the
other specs to stay registry-safe. Tests (M2's half; M3 adds two more):

1. *Signature round-trip through lift + reassembly*: a `complete` handler returns a
   `Response` whose content is `[AssistantThinking ThinkingContent {thinking = "t",
   signature = Just "sig-abc", redacted = True}, AssistantText (TextContent "answer")]`;
   `streamingComplete (liftCompleteToStream handler) …` must return exactly those
   blocks. This fails before this milestone (signature `Nothing`, redacted `False`)
   and is the regression test for review Theme 2 item 3.
2. *Event-level `ThinkingEnd` fidelity*: hand-built stream — `EventStart`,
   `ThinkingStart 0`, `ThinkingDelta 0 "t"`, `ThinkingEnd` carrying a signed
   `ThinkingContent`, then an `EventDone` whose terminal message has **empty** content
   — reassembles to the signed block (proves the event path alone, independent of the
   terminal-authoritative rule).
3. *Terminal content is authoritative*: deltas assemble the text `"partial"`, but the
   `EventDone` terminal message carries `"the real full text"` → the response contains
   the terminal's content.
4. *`responseId` carriage*: `EventStart` with `responseId = Just "msg_123"` and a
   terminal with `Nothing` → `Response.responseId = Just "msg_123"`; a terminal with
   `Just "msg_456"` overrides the start's value.
5. *Dangling-buffer ordering and tool-argument flush*: events close a text block at
   index 0 (`"first"`) and index 2 (`"last"`), leave a thinking buffer dangling at
   index 1 (`"partial-think"`) and a tool-argument buffer dangling at index 3
   (deltas totalling the non-JSON prefix `{"a":1`), and the stream ends with **no
   terminal**. Expect content order `[text "first", thinking "partial-think",
   text "last", toolCall]` with the tool call's `arguments == Aeson.String "{\"a\":1"`,
   `stopReason = Stop`, and `errorMessage = Just "stream ended without terminal event"`.
6. *Latency clamp*: `streamingComplete (liftCompleteToStream handler) …` where the
   handler's response message carries the ancient fixture timestamp
   (`2000-01-01 00:00:00 UTC`, as `Baikai.Message.assistant` produces) →
   `latencyMs >= 0`. Before this milestone this is a large negative number (the exact
   failure `TraceSpec`'s `stubResponse` exhibits).

Verification: `cabal test baikai` — new tests pass; `cabal test baikai-claude
baikai-openai baikai-effectful` still green (the Claude live/offline suites do not
assert the old lossy behavior).


### Milestone 3 — Protocol and exception invariants

Scope: make the documented protocol true on every core-owned path and stop swallowing
cancellation. At the end, the first event of *any* stream produced by
`Baikai.Stream` or by the providers' request-preparation failures is `EventStart`, and
`throwTo`/`timeout`/Ctrl-C propagate out of lifted blocking calls.

Edits:

- `baikai/src/Baikai/Stream.hs`: replace `tryAny` with

  ```haskell
  -- | 'try' for synchronous exceptions only. Anything delivered
  -- asynchronously (wrapped in 'SomeAsyncException' by 'throwTo',
  -- 'System.Timeout.timeout', Ctrl-C) is rethrown so cancellation
  -- works; converting it into an 'EventError' would defeat it.
  trySync :: IO a -> IO (Either Control.Exception.SomeException a)
  trySync action = do
    r <- Control.Exception.try action
    case r of
      Left e
        | Just (Control.Exception.SomeAsyncException _) <- fromException e ->
            Control.Exception.throwIO e
        | otherwise -> pure (Left e)
      Right a -> pure (Right a)
  ```

  and call it from `liftCompleteToStream`.
- `baikai/src/Baikai/Stream.hs`: `liftCompleteToStream`'s exception arm becomes a
  two-event stream — a synthetic `EventStart` whose skeleton is the same
  empty-content/`ErrorReason` assistant message the terminal carries (timestamp `now`,
  `responseId = Nothing`), then the existing `EventError`. Rework `errorEvent` to
  return `[AssistantMessageEvent]` (or a sibling `errorEvents`) and use
  `Stream.fromList`. Do the same for `noProviderEvent` → `noProviderEvents`. Update
  `liftCompleteToStream`'s haddock (currently promises "a single-'EventError' stream")
  and the `streamRequest` module/function haddocks (currently promise a "one-event
  error stream").
- `baikai/src/Baikai/Stream/Event.hs`: strengthen the module haddock — the
  `EventStart`-first guarantee now explicitly covers error-only streams (a synthetic
  skeleton precedes the terminal), and note the one known temporary gap (Claude
  provider mid-call failures before `message_start`; see Decision Log) that EP-7
  closes.
- `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` `immediateError`: return both
  events — reuse the already-built error message as the `EventStart` skeleton
  (`StartPayload {partial = msg, responseId = Nothing}`, content is already empty)
  followed by the existing terminal; the call site swaps `Stream.fromEffect` for
  `Stream.fromList`-over-`IO` (e.g. `Stream.concatEffect` already wraps it — return
  `pure (Stream.fromList events)`).
- `baikai-claude/src/Baikai/Provider/Claude/Api.hs` `immediateError`: the identical
  two-line change.
- Test updates (mechanical, sanctioned): `rejectsImageToolResultsTest` in
  `baikai-openai/test/Main.hs:146-152` and `baikai-claude/test/Main.hs:133-139` now
  match `[EventStart StartPayload {}, EventError TerminalPayload {…}]`.

New tests in `baikai/test/StreamSpec.hs`:

7. *Async exceptions pass through* (regression for review Theme 10 item 1): a handler
   that blocks (`threadDelay (10 * 1000 * 1000)`); fork a consumer thread that drains
   `liftCompleteToStream handler …` under `try @SomeException` and writes the outcome
   to an `MVar`; after a short delay, `throwTo` it `ThreadKilled`; the outcome must be
   `Left` with `fromException == Just ThreadKilled` — **not** `Right` an
   `EventError`-terminated event list (which is what today's `tryAny` produces).
8. *Error-only streams begin with `EventStart`*: (a) `streamRequestWith` on a fresh
   empty registry yields exactly `[EventStart …, EventError …]` with the
   `ProviderUnavailable`-classified `errorInfo` still on the terminal; (b)
   `liftCompleteToStream` over a throwing handler yields `EventStart` first and
   `EventError` last, and reassembling it still surfaces the thrown `BaikaiError`
   structurally (guards the `ErrorInfoSpec` behavior against the shape change).

Verification: `cabal test baikai baikai-claude baikai-openai baikai-effectful` — all
green, including the two updated provider tests and `baikai-effectful`'s existing
"first event is EventStart" assertion.


### Milestone 4 — Validation, hand-off contract, living sections

Scope: prove the whole matrix, freeze the hand-off contract for EP-6/EP-7, and bring
this document to its living-document obligations. No production edits are expected in
this milestone; if any fix is needed, loop back through the relevant milestone and
record it.

Work: run the full validation matrix (commands and expected transcripts in Concrete
Steps); diff the type definitions in Interfaces and Dependencies against the compiled
`baikai/src/Baikai/Stream/Event.hs` and fix the *document* if they drifted (the
document is the contract EP-6 and EP-7 code against — it must be exact); tick the two
EP-5 entries in the masterplan's Progress section
(`docs/masterplans/7-correctness-and-api-hardening-from-the-2026-07-review.md`) and set
the registry row's Status; fill in Surprises & Discoveries, Outcomes & Retrospective,
and any Decision Log additions made along the way. Acceptance: the transcripts in
Concrete Steps match reality, and a reader of EP-6/EP-7 can copy the payload
definitions from this file verbatim.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Build the whole workspace with test components after each milestone:

```bash
cabal build all --enable-tests
```

Expected tail of output (module counts vary):

```text
...
[ 9 of 12] Compiling Baikai.Stream
...
Linking .../baikai-test ...
```

Run the four affected suites:

```bash
cabal test baikai baikai-claude baikai-openai baikai-effectful
```

Expected shape of the result (counts will differ; what matters is four passes and the
new group showing up under baikai):

```text
Test suite baikai-test: RUNNING...
baikai
  ...
  Baikai.Stream reassembly
    thinking signature and redacted flag survive lift + reassembly: OK
    ThinkingEnd carries the full ThinkingContent:                   OK
    terminal message content is authoritative:                      OK
    responseId flows from events to Response:                       OK
    dangling buffers keep contentIndex order; tool args flushed:    OK
    latencyMs is clamped at zero:                                   OK
    async exceptions pass through liftCompleteToStream:             OK
    error-only streams begin with EventStart:                       OK
All ... tests passed
Test suite baikai-test: PASS
Test suite baikai-claude-test: PASS
Test suite baikai-openai-test: PASS
Test suite baikai-effectful-test: PASS
```

To iterate on just the new spec while developing M2/M3:

```bash
cabal test baikai --test-options='-p "Baikai.Stream reassembly"'
```

A useful before/after probe for the latency defect (fails before M2, passes after):

```bash
cabal test baikai --test-options='-p "latencyMs"'
```

File-by-file checklist of edit locations (see Plan of Work for the substance):

- `baikai/src/Baikai/Stream/Event.hs` — types, smart constructors, exports, haddock.
- `baikai/src/Baikai/Stream.hs` — `step`, `ReassemblyState`/`TerminalSeen`,
  `reassembleResponse`, `finalizeState`, dangling-block helpers, `trySync`,
  `errorEvents`, `noProviderEvents`, `eventsFor`, `blockEvent`, haddocks.
- `baikai-claude/src/Baikai/Provider/Claude/Api.hs` — `translate` (`Message_Start`,
  `Message_Stop`, `Error`), `unexpectedEoS`, `handleBlockStop`, `immediateError`.
- `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` — pre-seeded `StartPayload`,
  `translate` error branch, `closeOpenStream`, `immediateError`.
- `baikai/test/StreamSpec.hs` — new; `baikai/test/Main.hs` and `baikai/baikai.cabal`
  (`other-modules`) — registration.
- `baikai/test/ErrorInfoSpec.hs`, `baikai-effectful/test/StubProvider.hs`,
  `baikai-openai/test/Main.hs`, `baikai-claude/test/Main.hs` — mechanical updates.

Commit after each milestone with conventional-commit messages, for example:

```text
feat(stream)!: carry ThinkingContent and responseId through the event algebra
fix(stream): terminal-authoritative reassembly, ordered recovery, clamped latency
fix(stream): sync-only catch and EventStart-first error streams
```


## Validation and Acceptance

Acceptance is behavioral, all of it demonstrable via
`cabal test baikai baikai-claude baikai-openai baikai-effectful` from the repository
root:

1. **Signature preservation**: a blocking call through a lifted stream whose response
   contains `ThinkingContent {signature = Just "sig-abc", redacted = True}` returns
   those exact blocks (StreamSpec test 1). Before this plan, the same scenario
   returns `signature = Nothing, redacted = False`; you can prove the "before" by
   running the new test on the pre-plan `Baikai/Stream.hs` and watching it fail.
2. **Terminal-authoritative content**: when deltas and the terminal message disagree,
   the terminal wins (test 3); when the terminal has no content, the event-assembled
   blocks are used (test 2 exercises the empty-terminal path with the signed block
   coming from the events).
3. **responseId carriage**: `Response.responseId` equals the terminal payload's id,
   falling back to the start payload's (test 4). On the live Claude streaming path
   the id is Anthropic's `msg_…` — verifiable manually with a real key by printing
   `responseId` after `completeRequest` on an `AnthropicMessages` model, but the unit
   test does not require network.
4. **Async passthrough**: `throwTo` on a consumer draining a lifted blocked handler
   delivers `ThreadKilled` to the consumer instead of a fabricated `EventError`
   response (test 7). Equivalent user-visible effect: `timeout` over a hung CLI call
   returns `Nothing` instead of `Just` a garbage error response.
5. **EventStart-first**: dispatching on an unregistered tag and lifting a throwing
   handler both yield streams whose first event is `EventStart` and whose last is the
   sole `EventError`, with structured `errorInfo` intact (test 8); both providers'
   request-mapping-failure streams do the same (updated
   `rejectsImageToolResultsTest` in both provider suites).
6. **Ordered recovery**: a stream dying mid-block yields blocks in `contentIndex`
   order with partial tool arguments preserved as `Aeson.String` raw text (test 5).
7. **Latency**: `latencyMs >= 0` even with fixture/skewed message timestamps
   (test 6); the pre-existing `TraceSpec` fixtures stop exercising the negative-latency
   path by construction.

Beyond the suites, the effect is visible in `baikai-effectful`'s unchanged tests (its
stub asserts `EventStart`-first and terminal-carried content — both invariants this
plan strengthens rather than breaks) and, live, in any thinking-enabled multi-turn
conversation once EP-7 lands provider emission — this plan is what makes that plan's
acceptance possible.


## Idempotence and Recovery

Every step is an ordinary source edit under git; re-running builds and tests is safe
and free of side effects (no migrations, no generated files — `baikai/baikai.cabal`'s
`other-modules` edit is plain text). Milestones are designed to leave the tree green,
so commit at each milestone boundary; if a milestone goes sideways, `git restore
--source=HEAD -- <files>` (or reset to the last milestone commit) and re-approach.
M1 is the only milestone whose type changes fan out across packages; if the fan-out
stalls, the compiler's error list *is* the remaining-work list — every red site is one
of the mechanical edits enumerated in Plan of Work, and there are no runtime-only
breakages (all changes are type-visible). The new `StreamSpec` tests use per-test
`Custom` api tags (like existing specs) so re-running the suite in one process cannot
collide in the global registry.


## Interfaces and Dependencies

No new package dependencies. Everything uses what the workspace already builds
against: `streamly-core` (`Streamly.Data.Fold.foldlM'`, `Streamly.Data.Stream`),
`aeson`, `time`, `base`'s `Control.Exception` (`SomeAsyncException`), and the existing
baikai modules. The `ToJSON` instance for `ThinkingEndPayload` derives generically;
`Baikai.Content.ThinkingContent` already has `ToJSON` (snake-cased). The umbrella
module `baikai/src/Baikai.hs` re-exports `module Baikai.Stream.Event`, so the new
export `ThinkingEndPayload (..)` surfaces automatically.

The following are the **final shapes** at the end of M1. EP-6
(`docs/plans/39-unify-the-error-contract-and-revive-error-classification.md`) and EP-7
(`docs/plans/40-fix-extended-thinking-and-reasoning-across-providers.md`) must code
against exactly these; any further change must be recorded in this Decision Log and in
the masterplan's Integration Points, not made silently.

In `baikai/src/Baikai/Stream/Event.hs`:

```haskell
-- The constructor list of AssistantMessageEvent is unchanged except:
--   ThinkingEnd ThinkingEndPayload   -- was: ThinkingEnd BlockEndPayload
-- TextEnd keeps BlockEndPayload. All other constructors are untouched.

-- | Payload of 'EventStart': the message skeleton observed up front,
-- plus the provider's message id when the provider learns it this
-- early (Anthropic's @message_start.id@). 'Nothing' otherwise.
data StartPayload = StartPayload
  { partial :: !Message,
    responseId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of 'ThinkingEnd': the closed thinking block in full —
-- concatenated reasoning text plus the provider 'signature' and
-- 'redacted' flag. The concatenation of the preceding 'ThinkingDelta's
-- equals the payload's @content.thinking@.
data ThinkingEndPayload = ThinkingEndPayload
  { contentIndex :: !Int,
    content :: !ThinkingContent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of the terminal events 'EventDone' and 'EventError'.
data TerminalPayload = TerminalPayload
  { reason :: !StopReason,
    message :: !Message,
    -- | The provider's message id when known by stream end. Consumers
    -- should prefer this over 'StartPayload.responseId'.
    responseId :: !(Maybe Text),
    errorInfo :: !(Maybe BaikaiError)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

doneTerminal :: Maybe Text -> StopReason -> Message -> TerminalPayload
errorTerminal :: Maybe Text -> StopReason -> Message -> BaikaiError -> TerminalPayload
```

(`IndexPayload`, `DeltaPayload`, `BlockEndPayload`, `ToolCallEndPayload`, and
`isTerminal` are unchanged. `ThinkingContent` is
`Baikai.Content.ThinkingContent { thinking :: Text, signature :: Maybe Text,
redacted :: Bool }`, unchanged by this plan.)

In `baikai/src/Baikai/Stream.hs`, the exported surface is unchanged
(`streamRequest`, `streamRequestWith`, `streamingComplete`, `reassembleResponse ::
Model -> Fold IO AssistantMessageEvent Response`, `liftCompleteToStream`), with these
strengthened, documented semantics that EP-6/EP-7 may rely on:

- `reassembleResponse` resolves content terminal-authoritatively (Decision Log rule),
  sets `Response.responseId` from terminal-then-start payloads, flushes dangling
  buffers in `contentIndex` order (partial tool arguments as an empty-id `ToolCall`
  whose `arguments` is decoded JSON or `Aeson.String` raw text), and reports
  `latencyMs` as its own wall-clock measurement clamped at zero.
- `liftCompleteToStream` propagates `Response.responseId` through both `StartPayload`
  and the `EventDone` terminal, rethrows asynchronous exceptions, and its synchronous
  exception path emits `EventStart` then `EventError`.
- Every stream `Baikai.Stream` itself produces begins with `EventStart`; provider
  request-preparation failures (`immediateError` in both API providers) do too. The
  single known deviation (Claude mid-call failure before `message_start`) is EP-7's to
  close.

Protocol invariant summary for dependent plans: a conforming stream is
`EventStart` (exactly one, first), then per-block `_Start`/`_Delta`/`_End` in
non-decreasing `contentIndex` order, then exactly one `EventDone` or `EventError`
(last). EP-6 changes *which* terminal fires for error-shaped responses; it does not
change these payload types. EP-7 fills `ThinkingEndPayload.content` with real
signatures/redacted payloads from both providers and `responseId` on the OpenAI and
CLI paths; the slots are defined here.
