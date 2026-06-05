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
| `ThinkingEnd`    | `BlockEndPayload`    | `contentIndex`, `content`                | Reasoning block closes.                                                       |
| `ToolCallStart`  | `IndexPayload`       | `contentIndex`                           | A tool-call block opens.                                                      |
| `ToolCallDelta`  | `DeltaPayload`       | `contentIndex`, `delta`                  | A chunk of the tool call's argument JSON.                                     |
| `ToolCallEnd`    | `ToolCallEndPayload` | `contentIndex`, `toolCall :: ToolCall`   | Tool-call block closes; arguments are parsed.                                 |
| `EventDone`      | `TerminalPayload`    | `reason :: StopReason`, `message :: Message` | Terminal success. `message` is the fully assembled `AssistantMessage`.    |
| `EventError`     | `TerminalPayload`    | `reason :: StopReason`, `message :: Message` | Terminal failure. `message` carries whatever content closed before the failure plus a populated `errorMessage`. |

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
          TextDelta DeltaPayload {delta = d} -> TIO.putStr d
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
gives you whatever text the model had already streamed:

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
`ErrorReason` or `Aborted` on failure; the partial content is on
the response's message.

## Event stability policy

`AssistantMessageEvent` is a closed 0.1 API. The constructors listed
above are the complete event set every provider must use; providers
do not emit raw provider-specific or unknown-event values. Adding a
new constructor is therefore a breaking API change for consumers who
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
| `Aborted`      | The caller cancelled via signal/timeout. The terminal `message` carries whatever streamed first. |

## Notes

- Payloads. Event constructors carry payload records such as
  `DeltaPayload` and `TerminalPayload`; terminal payloads use the
  field name `message` for both success and failure.
- Block ordering. The stream guarantees `_Start` < `_Delta`* <
  `_End` per `contentIndex`, but indices can interleave: a
  `ThinkingStart` for index 0 can be followed by a `TextStart` for
  index 1 before `ThinkingEnd 0` arrives.
- One terminal. Exactly one `EventDone` or `EventError` is emitted
  per call. There is no other way for the stream to end.
