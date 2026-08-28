---
type: Reference
title: Streaming
description: Reference the streaming event algebra, fold patterns, and failure semantics.
docId: DOC-9
tags: [streaming, events, folds, errors, streamly]
generated:
  by: human:nadeem
  at: 2026-08-27T23:29:56Z
---

# Streaming

baikai's primary entry point is a stream of typed events.
`completeRequest` is implemented on top of it (it folds the stream
into a single `Response`), so any provider that supports streaming
supports blocking, and vice versa.

```haskell
streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequestWith :: ProviderRegistry -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
completeRequest :: Model -> Context -> Options -> IO Response
completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
```

The stream is a `streamly` `Stream IO AssistantMessageEvent`, and the
fold patterns below assume:

```haskell
import qualified Streamly.Data.Stream as Stream
import qualified Streamly.Data.Fold as Fold
```

You do not have to depend on `streamly` to stream. Two helpers give you
the same events without naming the type:

```haskell
streamRequestEach :: (AssistantMessageEvent -> IO ()) -> Model -> Context -> Options -> IO Response
streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]
```

`streamRequestEach` invokes the callback once per event, in order, as
each arrives — incrementality is preserved — and returns the same
reassembled `Response` `completeRequest` would have returned, so you get
the deltas *and* the final usage, stop reason and evidence from one call.
`streamRequestList` collects the events into a list, which is the
`Stream.toList` pattern without the import. Both have `…With` variants
taking a `ProviderRegistry` first: `streamRequestEachWith`,
`streamRequestListWith`.

## The event algebra

Every call emits a sequence of `AssistantMessageEvent` values
(defined in `Baikai.Stream.Event`). The shape is fixed:

```text
EventStart   -- exactly once, first
  ⤷ TextStart / ThinkingStart / ToolCallStart      ⎫
  ⤷ TextDelta / ThinkingDelta / ToolCallDelta …    ⎬ zero or more
  ⤷ TextEnd / ThinkingEnd / ToolCallEnd            ⎭
EventDone | EventError   -- exactly once, last
```

Content blocks are identified by an integer `contentIndex` so
deltas of different kinds can interleave across indices. Each event
constructor carries a payload record:

| Constructor      | Payload type         | Important fields                         | When                                                                          |
|------------------|----------------------|------------------------------------------|-------------------------------------------------------------------------------|
| `EventStart`     | `StartPayload`       | `partial :: Message`                     | First event. `partial` is an `AssistantMessage` skeleton with empty content.  |
| `TextStart`      | `IndexPayload`       | `contentIndex`                           | A new text block opens.                                                       |
| `TextDelta`      | `DeltaPayload`       | `contentIndex`, `delta`                  | A chunk of text appended to the open block at this index.                     |
| `TextEnd`        | `BlockEndPayload`    | `contentIndex`, `content`                | The text block closes. `content` is the concatenation of every delta.         |
| `ThinkingStart`  | `IndexPayload`       | `contentIndex`                           | A reasoning block opens (reasoning models only).                              |
| `ThinkingDelta`  | `DeltaPayload`       | `contentIndex`, `delta`                  | Reasoning chunk.                                                              |
| `ThinkingEnd`    | `ThinkingEndPayload` | `contentIndex`, `content :: ThinkingContent` | Reasoning block closes. `content` carries the signature and the redacted flag. |
| `ToolCallStart`  | `IndexPayload`       | `contentIndex`                           | A tool-call block opens.                                                      |
| `ToolCallDelta`  | `DeltaPayload`       | `contentIndex`, `delta`                  | A chunk of the tool call's argument JSON.                                     |
| `ToolCallEnd`    | `ToolCallEndPayload` | `contentIndex`, `toolCall :: ToolCall`   | Tool-call block closes; arguments are parsed, or kept as raw text if cut off (see [tools.md](tools.md)). |
| `EventDone`      | `TerminalPayload`    | `reason :: StopReason`, `message :: Message`, `evidence :: Maybe ModelCallEvidence` | Terminal success. `message` is the fully assembled `AssistantMessage`.    |
| `EventError`     | `TerminalPayload`    | `reason :: StopReason`, `message :: Message`, `errorInfo :: Maybe BaikaiError`, `evidence :: Maybe ModelCallEvidence` | Terminal failure. `message` carries whatever content closed before the failure plus a populated `errorMessage`. |

`isTerminal :: AssistantMessageEvent -> Bool` returns `True` on
`EventDone` / `EventError` and `False` everywhere else.

The terminal `Message` always carries the final `Usage` (token
counts plus `Cost`) and the resolved `StopReason`
(`Stop | Length | ToolUse | ErrorReason`).

## Patterns

### Collect to a list

The simplest fold:

```haskell
events <- Stream.toList (streamRequest model ctx opts)
```

### Print deltas as they arrive

```haskell
import Data.Text.IO qualified as TIO

events <- Stream.toList $
  Stream.mapM
    ( \e -> do
        case e of
          TextDelta DeltaPayload {delta = d} -> TIO.putStr d
          _ -> pure ()
        pure e
    )
    (streamRequest model ctx opts)
```

### Print deltas as they arrive, without streamly

The same thing, for a program that would rather not depend on `streamly`.
The callback runs on each event as it arrives, and the `Response` you get
back is the one `completeRequest` would have returned:

```haskell
import Data.Text.IO qualified as TIO

resp <-
  streamRequestEach
    ( \e -> case e of
        TextDelta DeltaPayload {delta = d} -> TIO.putStr d
        _ -> pure ()
    )
    model
    ctx
    opts
print (responseError resp, resp ^. #message . #usage)
```

### Extract just the final message

```haskell
import qualified Streamly.Data.Fold as Fold

mMsg <- Stream.fold Fold.last (streamRequest model ctx opts)
case mMsg of
  Just (EventDone TerminalPayload {message = msg}) -> handleSuccess msg
  Just (EventError TerminalPayload {reason = r, message = partial}) -> handleFailure r partial
  _ -> error "stream ended without a terminal event"  -- never happens
```

In practice you don't need to write this fold yourself —
`completeRequest` already does it and packages the result as a
`Response`:

```haskell
data Response = Response
  { message :: !AssistantPayload  -- assistant-only success or failure payload
  , latencyMs :: !Int
  , …
  }
```

### Recover partial output on failure

`EventError` is not an exception. The terminal event is delivered
through the stream, and its `message` carries every content block
that closed before the failure. A network drop mid-response still
gives you whatever text the model had already streamed, and the
terminal's `errorInfo` classifies such a drop as `TransientError`, so
`isRetryable` is true:

```haskell
events <- Stream.toList (streamRequest model ctx opts)
case last events of
  EventDone TerminalPayload {message = msg} ->
    putStrLn $ "ok: " <> render msg
  EventError TerminalPayload {reason = reason, message = partial} ->
    putStrLn $ "failed (" <> show reason <> "): partial = " <> render partial
```

This is the inverse of how most SDKs handle streaming errors
(throwing mid-stream and losing partial state). `completeRequest`
wraps the same flow into a single `Response` whose `stopReason` is
`ErrorReason` on failure; the partial content is on the response's
message. On that `Response`, `responseError` is the one question to ask —
it is `Just` exactly when the call failed, and it synthesises an
`OtherError` from `errorMessage` when a nonconforming provider set
`ErrorReason` without the structured detail. See
[Getting Started](getting-started.md#did-it-fail).

### Stopping early

Nothing forces you to drain a stream. What differs is *when* the HTTP
connection goes back to the pool.

```haskell
-- The first three events, then walk away.
events <- Stream.toList (Stream.take 3 (streamRequest model ctx opts))
```

The provider's worker stops reading the socket within 64 frames of the
last one you pulled — the queue between the worker and you is bounded, so
the model stops being generated and billed almost at once. The connection
itself is released at the next major garbage collection.

If you need the connection back at a known moment, **cancel the thread
doing the draining**, or wrap the drain in a timeout:

```haskell
-- Releases the connection immediately when the deadline passes.
result <- timeout 5_000_000 (Stream.toList (streamRequest model ctx opts))
```

An exception reaching the draining thread — `Ctrl-C`, `timeout`,
`cancel` — lands inside the stream's own step, and the provider kills its
worker and closes the response synchronously before the exception
reaches you.

The reasoning behind the three different strengths is in
[ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md).

## Event stability policy

`AssistantMessageEvent` is a closed API. The constructors listed above
are the complete event set every provider must use; providers do not
emit raw provider-specific or unknown-event values. Adding a new
constructor is therefore a breaking API change for consumers who
pattern-match exhaustively.

If you want compiler help when the event set changes, match every
constructor explicitly. If you prefer source resilience across future
minor versions, add a wildcard branch after the cases you care about:

```haskell
case event of
  TextDelta DeltaPayload {delta = d} -> TIO.putStr d
  EventDone TerminalPayload {message = msg} -> handleSuccess msg
  EventError TerminalPayload {reason = r, message = partial} -> handleFailure r partial
  _ -> pure ()
```

## CLI providers

`baikai-claude` and `baikai-openai` each register both an API
provider and a CLI provider. The CLI providers wrap `claude -p` and
`codex exec` respectively. Their event streams are synthetic:

```text
EventStart   { partial = … }
TextStart    { contentIndex = 0 }
TextDelta    { contentIndex = 0, delta = "<entire response>" }
TextEnd      { contentIndex = 0, content = "<entire response>" }
EventDone    { reason = Stop, message = … }
```

You get one big text delta containing the complete response, not
incremental output. The CLIs do not expose a streaming interface
and do not participate in tool calling (see [Tools](tools.md));
the synthetic stream exists so `streamRequest` works uniformly
across every `Api` tag. For the full CLI provider surface
(configuration, response shape, limitations) see
[CLI Providers](cli-providers.md).

## Failure modes

| `stopReason`   | What happened                                                                              |
|----------------|--------------------------------------------------------------------------------------------|
| `Stop`         | Normal completion.                                                                         |
| `Length`       | Hit the `maxTokens` cap or the model's `maxOutputTokens`.                                  |
| `ToolUse`      | Model emitted tool calls and expects you to dispatch them. See [Tools](tools.md).          |
| `ErrorReason`  | Provider returned an error (auth, rate limit, malformed input, …). `errorMessage` and structured `errorInfo` are set. |

## Notes

- Payloads. Event constructors carry payload records such as
  `DeltaPayload` and `TerminalPayload`; terminal payloads use the
  field name `message` for both success and failure.
- Block ordering. The stream guarantees `_Start` < `_Delta`* <
  `_End` per `contentIndex`, and an index is never revisited once its
  `_End` has been sent. Reasoning that arrives after visible text closes
  the open text block first, so on the shipped providers at most one text
  or thinking block is open at a time.
- One terminal. Exactly one `EventDone` or `EventError` is emitted
  per call. There is no other way for the stream to end.
