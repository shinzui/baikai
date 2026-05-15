# Streaming

baikai's primary entry point is a stream of typed events.
`completeRequest` is implemented on top of it (it folds the stream
into a single `Response`), so any provider that supports streaming
supports blocking, and vice versa.

```haskell
streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
completeRequest :: Model -> Context -> Options -> IO Response
```

The stream comes from `streamly`. Everything in this guide assumes:

```haskell
import qualified Streamly.Data.Stream as Stream
import qualified Streamly.Data.Fold as Fold
```

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
deltas of different kinds can interleave across indices. The
constructors:

| Constructor      | Fields                                          | When                                                                          |
|------------------|-------------------------------------------------|-------------------------------------------------------------------------------|
| `EventStart`     | `partial :: Message`                            | First event. `partial` is an `AssistantMessage` skeleton with empty content.  |
| `TextStart`      | `contentIndex`                                  | A new text block opens.                                                       |
| `TextDelta`      | `contentIndex`, `delta`                         | A chunk of text appended to the open block at this index.                     |
| `TextEnd`        | `contentIndex`, `content`                       | The text block closes. `content` is the concatenation of every delta.         |
| `ThinkingStart`  | `contentIndex`                                  | A reasoning block opens (reasoning models only).                              |
| `ThinkingDelta`  | `contentIndex`, `delta`                         | Reasoning chunk.                                                              |
| `ThinkingEnd`    | `contentIndex`, `content`                       | Reasoning block closes.                                                       |
| `ToolCallStart`  | `contentIndex`                                  | A tool-call block opens.                                                      |
| `ToolCallDelta`  | `contentIndex`, `delta`                         | A chunk of the tool call's argument JSON.                                     |
| `ToolCallEnd`    | `contentIndex`, `toolCall :: ToolCall`          | Tool-call block closes; arguments are parsed.                                 |
| `EventDone`      | `reason :: StopReason`, `message :: Message`    | Terminal success. `message` is the fully assembled `AssistantMessage`.        |
| `EventError`     | `reason :: StopReason`, `errorPartial :: Message` | Terminal failure. `errorPartial` carries whatever content closed before the failure plus a populated `errorMessage`. |

`isTerminal :: AssistantMessageEvent -> Bool` returns `True` on
`EventDone` / `EventError` and `False` everywhere else.

The terminal `Message` always carries the final `Usage` (token
counts plus `Cost`) and the resolved `StopReason`
(`Stop | Length | ToolUse | ErrorReason | Aborted`).

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
          TextDelta _ d -> TIO.putStr d
          _ -> pure ()
        pure e
    )
    (streamRequest model ctx opts)
```

### Extract just the final message

```haskell
import qualified Streamly.Data.Fold as Fold

mMsg <- Stream.fold Fold.last (streamRequest model ctx opts)
case mMsg of
  Just (EventDone _ msg) -> handleSuccess msg
  Just (EventError r partial) -> handleFailure r partial
  _ -> error "stream ended without a terminal event"  -- never happens
```

In practice you don't need to write this fold yourself —
`completeRequest` already does it and packages the result as a
`Response`:

```haskell
data Response = Response
  { message :: !Message      -- always AssistantMessage; success or failure
  , latencyMs :: !Int
  , …
  }
```

### Recover partial output on failure

`EventError` is not an exception. The terminal event is delivered
through the stream, and `errorPartial` carries every content block
that closed before the failure. A network drop mid-response still
gives you whatever text the model had already streamed:

```haskell
events <- Stream.toList (streamRequest model ctx opts)
case last events of
  EventDone _ msg ->
    putStrLn $ "ok: " <> render msg
  EventError reason partial ->
    putStrLn $ "failed (" <> show reason <> "): partial = " <> render partial
```

This is the inverse of how most SDKs handle streaming errors
(throwing mid-stream and losing partial state). `completeRequest`
wraps the same flow into a single `Response` whose `stopReason` is
`ErrorReason` or `Aborted` on failure; the partial content is on
the response's message.

## CLI providers

`baikai-claude` and `baikai-openai` each register both an API
provider and a CLI provider. The CLI providers wrap `claude -p` and
`codex exec` respectively. Their event streams are synthetic:

```text
EventStart   { partial = … }
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
| `ErrorReason`  | Provider returned an error (auth, rate limit, malformed input, …). `errorMessage` is set.  |
| `Aborted`      | The caller cancelled via signal/timeout. `errorPartial` carries whatever streamed first.   |

## Notes

- Field name. The `EventError` payload field is `errorPartial`, not
  `error` (which would shadow `Prelude.error`).
- Block ordering. The stream guarantees `_Start` < `_Delta`* <
  `_End` per `contentIndex`, but indices can interleave: a
  `ThinkingStart` for index 0 can be followed by a `TextStart` for
  index 1 before `ThinkingEnd 0` arrives.
- One terminal. Exactly one `EventDone` or `EventError` is emitted
  per call. There is no other way for the stream to end.
