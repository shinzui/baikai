---
id: 9
slug: streaming-event-protocol-with-streamly
title: "Streaming event protocol with streamly"
kind: exec-plan
created_at: 2026-05-14T15:08:41Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Streaming event protocol with streamly

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, baikai exposes streaming as the primary provider interface. Every
API provider produces a `Streamly.Data.Stream.Stream IO AssistantMessageEvent` —
a sequence of typed events `EventStart, TextStart, TextDelta, TextEnd,
ThinkingStart, ThinkingDelta, ThinkingEnd, ToolCallStart, ToolCallDelta,
ToolCallEnd, EventDone, EventError` — that a caller can fold over, transform, or
consume eagerly. Synchronous callers continue to write
`completeRequest model context options` and get a single `Response`, but the
implementation is now `Stream.fold reassembleResponse (streamRequest model context
options)` — completion is draining, not a separate code path.

The user-visible payoff is twofold:

1. **Live partial output.** A caller building an interactive UI (terminal,
   web, TUI) can render text deltas as they arrive instead of waiting for the
   model to finish. The `baikai-smoke` package gains a streaming smoke test
   (`StreamingSmoke.hs`) that prints each `TextDelta`'s payload to stdout and
   asserts at least one delta was received before the terminal event.

2. **Error recovery without throws.** When a request fails partway, the stream
   terminates with `EventError { reason :: StopReason, error :: AssistantMessage }`
   carrying whatever content was already produced. The caller pattern-matches on
   the terminal event and decides whether to retry, fall back, or accept the
   partial result. No exception crosses the provider boundary; existing
   `bracket`-style cleanup in the trace bridge stays correct.

This plan also rebuilds the trace bridge in `baikai/src/Baikai/Trace.hs` to
subscribe to the event stream. The bridge becomes a stream combinator that emits
`CallStarted` from the first non-event setup, then `CallFinished` from the
terminal `EventDone`, or `CallFailed` from the terminal `EventError`. The
existing `TraceSink :: Fold IO TraceEvent ()` shape is unchanged. The OTel sink
in `baikai-trace-otel` is unaffected.

CLI providers (`Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Cli`) wrap
their existing batch output in a one-shot stream: `EventStart`, one synthetic
`TextStart` + `TextDelta` (with the whole response) + `TextEnd`, then `EventDone`.
They do not produce real deltas because the CLI binaries do not expose
intra-response streaming.

A consumer can see streaming working immediately after this plan with:

```haskell
import Baikai
import Baikai.Provider.Claude.Api qualified as Claude
import Streamly.Data.Stream qualified as Stream

main :: IO ()
main = do
  Claude.register
  let model = _Model { modelId = "claude-sonnet-4-6", ... }
      ctx = _Context { messages = V.singleton (user "tell me a haiku") }
  streamRequest model ctx _Options
    & Stream.fold (Fold.foldlM' renderEvent ())
  where
    renderEvent () (TextDelta _ delta) = T.putStr delta
    renderEvent () _ = pure ()
```


## Progress

- [ ] Milestone 1: introduce `Baikai.Stream.Event` (the `AssistantMessageEvent`
      algebra) and `Baikai.Stream` exposing `streamRequest :: Model -> Context
      -> Options -> Stream IO AssistantMessageEvent`. The registry's
      `ApiProvider` gains a `stream` field; `complete` becomes a draining
      wrapper.
- [ ] Milestone 2: rewrite `Baikai.Provider.Claude.Api.runClaudeMessages` as a
      streamly stream producer. The producer bridges the upstream SDK's
      callback-based `Claude.V1.createMessageStreamTyped` via the
      `Chan (Maybe MessageStreamEvent) + Stream.unfoldrM` pattern, maps each
      raw event to one or more `AssistantMessageEvent`s, and terminates with
      a single `EventDone` or `EventError`.
- [ ] Milestone 3: rewrite `Baikai.Provider.OpenAI.Api.runOpenAIChat` as a
      streamly stream producer using
      `OpenAI.V1.createChatCompletionStreamTyped`. The OpenAI Chat Completions
      stream delivers chunks with `choices[0].delta.{content, tool_calls}`;
      map each chunk's text-content delta to a `TextDelta`, each tool-call
      argument delta to a `ToolCallDelta`, and the final usage chunk to the
      terminal `EventDone`.
- [ ] Milestone 4: wrap CLI providers in one-shot synthetic streams.
      `Baikai.Provider.Claude.Cli` and `Baikai.Provider.OpenAI.Cli` register
      streaming handlers that produce four events:
      `EventStart`, `TextStart 0`, `TextDelta 0 wholeBody`, `TextEnd 0`,
      `EventDone`. The existing batch execution path runs to completion before
      the first event is emitted; the stream is just a wrapper.
- [ ] Milestone 5: rebuild `Baikai.Trace.withTrace` around the event stream.
      The new shape is:
      `withTrace :: TraceSink -> Model -> Context -> Options
        -> Stream IO AssistantMessageEvent`. The bridge subscribes a stream
      transformer that side-effects `CallStarted` / `CallFinished` /
      `CallFailed` events into the sink's `Fold`. The `completeWithTrace`
      helper (was `Trace.withTrace`'s previous shape returning a `Response`)
      becomes a `Stream.fold` over the bridged stream.
- [ ] Milestone 6: add streaming smoke coverage in `baikai-smoke`. The new
      `StreamingSmoke.hs` runs against both API providers (skipping without
      keys) and asserts (a) the stream emits at least one `TextDelta` event,
      (b) the terminal event is `EventDone`, (c) the usage on the terminal
      `EventDone`'s `message` is non-zero. Existing batch smoke tests
      continue to pass through the draining `completeRequest`.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The streaming stream type is
  `Streamly.Data.Stream.Stream IO AssistantMessageEvent` (concrete `IO`), not
  a polymorphic `Stream m a`.
  Rationale: The producer side reads from a `Chan` filled by an upstream SDK
  callback that lives in `IO`. The trace bridge subscribes via `Stream.fold`
  which already lives in `IO`. Making the stream polymorphic would force the
  channel-bridge logic to thread `MonadUnliftIO m` through every event
  producer with no observable payoff. The earlier first masterplan adopted
  the same logic for `Fold IO TraceEvent ()` and stayed at `IO`; this plan
  follows the precedent.
  Date: 2026-05-14

- Decision: The terminal event is exactly one of `EventDone` or `EventError`,
  and the producer guarantees the partial `AssistantMessage` is consistent up
  to that point (i.e. content blocks the consumer saw via `_Start` /
  `_Delta` / `_End` events are concatenated into the terminal message's
  `content` vector).
  Rationale: pi-mono uses the same invariant. A consumer that pattern-matches
  only on the terminal event gets the same `AssistantMessage` shape as a
  consumer that consumed every delta. The producer's correctness is the
  invariant under test in the streaming smoke.
  Date: 2026-05-14

- Decision: Errors flow through the stream as a terminal `EventError`; the
  producer does not throw across the stream boundary.
  Rationale: A throw across the boundary defeats the "partial output is
  always recoverable" property the masterplan's Vision & Scope section
  promises. Providers wrap their upstream SDK calls in
  `try @SomeException` and convert the exception into an `EventError`
  whose `error :: AssistantMessage` carries whatever content was already
  emitted plus `stopReason = ErrorReason` and `errorMessage = Just
  (displayException e)`. Background failures inside the streamly fold
  (e.g. an exception inside a downstream `Stream.fold` consumer) still
  propagate to the caller — only producer-side failures are
  re-encoded into events.
  Date: 2026-05-14

- Decision: `Baikai.Stream.Event` lives in the `baikai` library; the
  algebra is one closed sum. Adding a new event variant is a breaking
  change to baikai's public surface.
  Rationale: Open extensibility is unnecessary — pi-mono's event set has
  been stable across many provider additions, and an open polymorphic
  shape would force every consumer to write a default match. EP-4 adds
  no new constructors (only refines `ToolCallDelta` semantics); EP-5 adds
  none either. EP-6 does not touch the algebra.
  Date: 2026-05-14

- Decision: The OpenAI Chat Completions stream's `<thinking>...</thinking>`
  delimiter convention (used by some non-OpenAI hosts) is decoded into
  `ThinkingDelta` events at the provider boundary.
  Rationale: OpenAI's Chat Completions schema does not have a native
  reasoning field; non-OpenAI providers (DeepSeek, Together, etc.)
  smuggle reasoning text in `<thinking>` tags. EP-5's compat record
  decides whether to enable this conversion per host. The decoding logic
  is implemented in this plan as a stream transformer
  (`stripThinkingTags`) that lives next to the OpenAI provider in
  `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`; EP-5 wires it on or
  off via `OpenAICompletionsCompat.requiresThinkingAsText`.
  Date: 2026-05-14


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is the third in the `Streaming, Content Blocks, and Tool Calls`
initiative defined in `docs/masterplans/2-streaming-content-blocks-and-tool-calls.md`.
It depends on EP-1 (`docs/plans/7-typed-content-blocks-richer-usage-and-stopreason.md`)
for the `AssistantContent`, `Usage`, and `StopReason` shapes, and on EP-2
(`docs/plans/8-api-tag-model-record-and-provider-registry.md`) for the
`Model`, `Context`, `Options`, and `ApiProvider` shapes. Both must be
implemented before starting this plan.

After EP-2 the registry shape is:

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , complete :: Model -> Context -> Options -> IO Response
  }
```

This plan adds a `stream` field to `ApiProvider`:

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , stream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  , complete :: Model -> Context -> Options -> IO Response
  }
```

The default implementation of `complete` becomes
`complete = streamingComplete . stream` where `streamingComplete` folds the
event stream into a `Response`.

The upstream Mercury Haskell SDKs already expose typed streaming primitives.
The Claude SDK at `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude`
exposes (from `Claude.V1`):

```haskell
createMessageStream
  :: CreateMessage
  -> (Either Text Aeson.Value -> IO ())  -- raw SSE callback
  -> IO ()

createMessageStreamTyped
  :: CreateMessage
  -> (Either Text MessageStreamEvent -> IO ())   -- typed callback
  -> IO ()
```

Both internally call `ssePostJSON` against `/v1/messages` with `stream = true`.
The typed variant parses each `Aeson.Value` chunk into `MessageStreamEvent`,
whose constructors mirror Anthropic's SSE event types:

```haskell
data MessageStreamEvent
  = Message_Start       { message :: MessageResponse }
  | Content_Block_Start { index :: Natural, content_block :: ContentBlock }
  | Content_Block_Delta { index :: Natural, delta :: ContentBlockDelta }
  | Content_Block_Stop  { index :: Natural }
  | Message_Delta       { message_delta :: MessageDelta, usage :: StreamUsage }
  | Message_Stop
  | Ping
  | Error               { error :: Aeson.Value }
```

`ContentBlockDelta` carries `Delta_Text_Delta { text :: Text }`,
`Delta_Input_Json_Delta { partial_json :: Text }` (for tool argument
streaming), `Delta_Thinking_Delta { thinking :: Text }`, and
`Delta_Signature_Delta { signature :: Text }`.

The OpenAI SDK at `/Users/shinzui/Keikaku/hub/haskell/openai-project/openai`
exposes (from `OpenAI.V1`):

```haskell
createChatCompletionStream
  :: CreateChatCompletion
  -> (Either Text Aeson.Value -> IO ())
  -> IO ()

createChatCompletionStreamTyped
  :: CreateChatCompletion
  -> (Either Text ChatCompletionChunk -> IO ())
  -> IO ()
```

A `ChatCompletionChunk` carries `choices[0].delta` with optional `content :: Text`
and `tool_calls :: Maybe (Vector ToolCallDelta)`. The final chunk has
`finish_reason :: Maybe Text` and an optional `usage` chunk when
`stream_options = ChatCompletionStreamOptions { include_usage = True }`.

The streamly callback-to-stream bridge pattern already used in
`baikai/src/Baikai/Trace.hs` (lines 73–96) is:

```haskell
chan <- newChan :: IO (Chan (Maybe a))
_ <- forkIO (callbackProducer chan)
Stream.unfoldrM step ()
  where
    step :: () -> IO (Maybe (a, ()))
    step () = do
      m <- readChan chan
      pure (fmap (\e -> (e, ())) m)
```

A `Nothing` sentinel on the channel terminates the stream. This plan reuses the
pattern for every event producer.

The trace bridge in `baikai/src/Baikai/Trace.hs` after EP-2 looks like:

```haskell
withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
withTrace (TraceSink sinkFold) m ctx opts = withRunInIO $ \_run -> do
  chan <- newChan :: IO (Chan (Maybe TraceEvent))
  done <- newEmptyMVar
  _ <- forkIO $ do
    let step () = do
          m' <- readChan chan
          pure (fmap (\e -> (e, ())) m')
    Stream.unfoldrM step ()
      & Stream.fold sinkFold
    putMVar done ()
  -- ... emit CallStarted, call completeRequest, emit CallFinished or CallFailed,
  -- write Nothing sentinel, takeMVar done ...
```

This plan rebuilds the bridge so it consumes the event stream directly. The
new bridge maps `EventStart` to `CallStarted` and the terminal `EventDone` /
`EventError` to `CallFinished` / `CallFailed`. Intermediate delta events are
not emitted to the sink — they would explode trace volume — but a future plan
may add an opt-in "stream-trace" sink that does.

`Baikai.Cost.Pricing.attachCost` after EP-2 has signature
`attachCost :: Model -> Response -> Response`. The streaming reassembler
`streamingComplete` calls `attachCost` on the synthesized `Response` before
returning.


## Plan of Work

### Milestone 1: define the event algebra and the stream surface

**New file:** `baikai/src/Baikai/Stream/Event.hs`:

```haskell
data AssistantMessageEvent
  = EventStart
      { partial :: !AssistantMessage   -- always empty content; carries api/provider/model
      }
  | TextStart
      { contentIndex :: !Int
      }
  | TextDelta
      { contentIndex :: !Int
      , delta :: !Text
      }
  | TextEnd
      { contentIndex :: !Int
      , content :: !Text                -- the fully assembled text block
      }
  | ThinkingStart
      { contentIndex :: !Int
      }
  | ThinkingDelta
      { contentIndex :: !Int
      , delta :: !Text
      }
  | ThinkingEnd
      { contentIndex :: !Int
      , content :: !Text
      }
  | ToolCallStart
      { contentIndex :: !Int
      }
  | ToolCallDelta
      { contentIndex :: !Int
      , delta :: !Text                  -- partial JSON arguments
      }
  | ToolCallEnd
      { contentIndex :: !Int
      , toolCall :: !ToolCall           -- fully parsed
      }
  | EventDone
      { reason :: !StopReason           -- Stop, Length, or ToolUse
      , message :: !AssistantMessage    -- final assembled message
      }
  | EventError
      { reason :: !StopReason           -- ErrorReason or Aborted
      , error :: !AssistantMessage      -- partial message with errorMessage set
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

The `contentIndex :: Int` field identifies which content block the event
applies to. Providers MUST emit `_Start`, then zero or more `_Delta`, then
`_End` events for each block in increasing index order. The reassembler
maintains a `Map Int AssistantContent` and folds events into it.

**New file:** `baikai/src/Baikai/Stream.hs`. The streaming entry point:

```haskell
streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequest m ctx opts = Stream.unfoldrM step (Left initialThunk)
  where
    initialThunk = do
      mProvider <- lookupApiProvider (api m)
      case mProvider of
        Just p -> pure (stream p m ctx opts)
        Nothing -> ... -- emit a one-event "no provider" error stream
```

The implementation uses an immediate fall-back stream when no provider is
registered: a singleton `EventError` carrying an `AssistantMessage` with
`stopReason = ErrorReason` and `errorMessage = Just "No provider registered
for API: ..."`. This means a caller iterating the stream always gets at
least one event.

**Modified file:** `baikai/src/Baikai/Provider/Registry.hs`. Add the `stream`
field:

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , stream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  , complete :: Model -> Context -> Options -> IO Response
  }

-- The default complete implementation drains the stream.
streamingComplete
  :: (Model -> Context -> Options -> Stream IO AssistantMessageEvent)
  -> Model -> Context -> Options -> IO Response
streamingComplete f m ctx opts = do
  let s = f m ctx opts
  Stream.fold reassembleResponse s
  where
    reassembleResponse :: Fold IO AssistantMessageEvent Response
    reassembleResponse = ...
```

`reassembleResponse` folds events into a `Response` by:

1. Latching the initial `EventStart`'s `partial` field as the response skeleton.
2. Accumulating `_End` events into a `Vector AssistantContent` ordered by
   `contentIndex`.
3. On `EventDone` or `EventError`, building the final `AssistantMessage`
   with the accumulated content and the event's `reason` / `errorMessage`.

The reassembler defends against missing `_End` events (a producer bug) by
treating any `_Delta` events seen without a closing `_End` as a flushed
`AssistantText` block — but this should never happen with the providers
this plan implements.

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.Stream.Event`,
`Baikai.Stream` to `exposed-modules`. No new dependencies (streamly is
already in `baikai`'s `build-depends` from the first masterplan).

**Acceptance.** `cabal build baikai` is green. `cabal repl baikai` can
import `Baikai.Stream` and evaluate
`streamRequest _Model _Context _Options` (which will produce a one-event
error stream because no provider is registered).

### Milestone 2: Anthropic streaming producer

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Replace
the synchronous `runClaudeMessages` with a streaming `claudeMessagesStream`:

```haskell
claudeMessagesStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStream m ctx opts = Stream.unfoldrM step =<< setup
  where
    setup = do
      apiKey <- resolveKey opts "ANTHROPIC_API_KEY"
      env <- Claude.getClientEnv (baseUrl m)
      let methods = Claude.makeMethods env apiKey (Just "2023-06-01")
          createReq = mapContextToCreateMessage m ctx opts
      chan <- newChan :: IO (Chan (Maybe MessageStreamEvent))
      _ <- forkIO $ do
        result <- try @SomeException $
          Claude.createMessageStreamTyped methods createReq $ \case
            Left err -> writeChan chan (Just (Error { error = Aeson.toJSON err }))
            Right ev -> writeChan chan (Just ev)
        case result of
          Left e ->
            writeChan chan (Just (Error { error = Aeson.toJSON (displayException e) }))
          Right () -> pure ()
        writeChan chan Nothing
      ... initialState carrying the partial message skeleton ...
    step = ...    -- emits events derived from each raw MessageStreamEvent
```

The mapping table (raw → baikai events):

| Raw event                                                | Emitted events                                                                 |
|----------------------------------------------------------|--------------------------------------------------------------------------------|
| `Message_Start { message }`                              | `EventStart { partial = skeleton from message }`                               |
| `Content_Block_Start { index, content_block = Text }`    | `TextStart { contentIndex = fromIntegral index }`                              |
| `Content_Block_Start { index, content_block = Thinking}` | `ThinkingStart { ... }`                                                        |
| `Content_Block_Start { index, content_block = ToolUse}`  | `ToolCallStart { ... }`                                                        |
| `Content_Block_Delta { index, Delta_Text_Delta text }`   | `TextDelta { contentIndex = fromIntegral index, delta = text }`                |
| `Content_Block_Delta { index, Delta_Thinking_Delta t }`  | `ThinkingDelta { ... }`                                                        |
| `Content_Block_Delta { index, Delta_Input_Json_Delta j}` | `ToolCallDelta { contentIndex = fromIntegral index, delta = j }`               |
| `Content_Block_Delta { index, Delta_Signature_Delta s}`  | (buffered; attached to the closing `ThinkingEnd`)                              |
| `Content_Block_Stop { index }`                           | `TextEnd` / `ThinkingEnd` / `ToolCallEnd` depending on the block kind          |
| `Message_Delta { delta = MessageDelta { stop_reason }, usage }` | (buffered; consumed by the terminal step to build `EventDone`)           |
| `Message_Stop`                                           | `EventDone { reason, message }` built from buffered state                      |
| `Ping`                                                   | (no event emitted)                                                             |
| `Error { error }`                                        | `EventError { reason = ErrorReason, error = AssistantMessage with errorMessage }` |

The producer maintains per-`contentIndex` accumulators for partial text /
thinking / tool-call-arguments so it can populate the closing `_End`
events' `content` / `toolCall` fields. The terminal `EventDone` carries an
`AssistantMessage` whose `content :: Vector AssistantContent` is the
accumulated blocks in index order, `usage` is computed from the upstream
`Message_Delta.usage` (plus the initial token counts on `Message_Start`),
`stopReason` is mapped from the upstream `Messages.StopReason`, and
`timestamp` is the local `getCurrentTime` at terminal-event emission.

`mapContextToCreateMessage` is moved out of the existing `mapRequest` helper
from EP-1 and adjusted to consume `Context`/`Options` instead of `Request`.

**Modified file:** `baikai-claude/baikai-claude.cabal`. Add `streamly ^>=0.12`,
`streamly-core ^>=0.4` to `build-depends`. No other new deps.

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs` (the
`register` function):

```haskell
register :: IO ()
register = registerApiProvider $ ApiProvider
  { apiTag = AnthropicMessages
  , stream = claudeMessagesStream
  , complete = streamingComplete claudeMessagesStream
  }
```

**Acceptance.** `cabal build all` is green. `cabal repl baikai-claude`
can demonstrate the stream against a real `ANTHROPIC_API_KEY`:

```haskell
ghci> Claude.register
ghci> streamRequest (anthropicModel "claude-haiku-4-5") (_Context { messages = V.singleton (user "say hi") }) _Options
   & Stream.toList
[EventStart {...}, TextStart 0, TextDelta 0 "H", TextDelta 0 "i", ..., TextEnd 0 "Hi there!", EventDone {...}]
```

### Milestone 3: OpenAI streaming producer

**Modified file:** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`.
Replace the synchronous `runOpenAIChat` with `openaiChatStream`:

```haskell
openaiChatStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiChatStream m ctx opts = Stream.unfoldrM step =<< setup
  where
    setup = do
      apiKey <- resolveKey opts "OPENAI_API_KEY"
      env <- OpenAI.getClientEnv (baseUrl m)
      let methods = OpenAI.makeMethods env apiKey Nothing Nothing
          createReq = (mapContextToCreateChatCompletion m ctx opts)
            { Chat.stream = Just True
            , Chat.stream_options = Just Chat._ChatCompletionStreamOptions { Chat.include_usage = Just True }
            }
      chan <- newChan :: IO (Chan (Maybe ChatCompletionChunk))
      _ <- forkIO $ do
        result <- try @SomeException $
          OpenAI.createChatCompletionStreamTyped methods createReq $ \case
            Left err -> ...
            Right chunk -> writeChan chan (Just chunk)
        ...
      ...
```

The mapping for OpenAI Chat Completions chunks is more involved because
OpenAI emits text content directly on `choices[0].delta.content :: Text` and
tool calls on `choices[0].delta.tool_calls :: Vector ToolCallDelta` keyed by
`index :: Int`. The producer maintains:

- A `Maybe Int` "current text content index" — `Just 0` is opened on the
  first text chunk (emitting `TextStart 0`), held while subsequent text
  chunks emit `TextDelta 0 delta`, and closed (emitting `TextEnd 0 acc`) when
  the chunk has no text content (or on terminal).
- A `Map Int ToolCallAccumulator` keyed by the OpenAI tool-call delta index.
  Each accumulator carries the partial JSON string plus the tool-call id and
  name (which arrive in the first delta for that index). When the terminal
  chunk arrives, accumulators are closed in index order, each emitting
  `ToolCallStart, ToolCallDelta*, ToolCallEnd` events.
- A token usage accumulator from the final usage chunk.

OpenAI's content indices are independent of baikai's `contentIndex`. The
producer re-indexes: text block (if present) takes `contentIndex = 0`;
tool calls take `1..n` in the order they appeared. The reassembler in EP-1's
content-block ordering does not care about gaps as long as indices are
monotonic.

**OpenAI thinking content.** Some OpenAI-compatible providers (DeepSeek,
Together, etc.) smuggle reasoning text in `<thinking>...</thinking>` tags
inside the regular `delta.content` stream. The plan adds a transformer
`stripThinkingTags :: Stream IO ChatCompletionChunk -> Stream IO
ChatCompletionChunk` that:

- Buffers content chunks until a `<thinking>` open tag is seen.
- After an open tag, redirects subsequent text into `ThinkingDelta` events
  (re-emitted as `ChatCompletionChunk` with a synthetic `reasoning_content`
  field — or, more simply, the transformer emits `AssistantMessageEvent`
  values directly into the stream when it crosses a tag boundary).
- The transformer is wired in only when `Model.compat` is
  `CompatOpenAICompletions { requiresThinkingAsText = True }` — EP-5 lands
  that compat field. This plan implements the transformer but the wiring is
  unconditional (always off) until EP-5 enables it.

**Modified file:** `baikai-openai/baikai-openai.cabal`. `streamly` and
`streamly-core` are already in `build-depends`; no change.

**Acceptance.** `cabal build all` is green. With `OPENAI_API_KEY` set,
`cabal repl baikai-openai` can stream a response from GPT-5 mini and observe
deltas.

### Milestone 4: CLI providers as one-shot streams

**Modified files:** `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. Each replaces its
synchronous handler with:

```haskell
claudeCliStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeCliStream m ctx opts = Stream.fromEffect (claudeCliBatch m ctx opts) >>= eventsFor
  where
    eventsFor (Right (text, latencyMs)) = Stream.fromList
      [ EventStart partialSkeleton
      , TextStart 0
      , TextDelta 0 text
      , TextEnd 0 text
      , EventDone Stop finalMessage
      ]
    eventsFor (Left errMsg) = Stream.fromList
      [ EventStart partialSkeleton
      , EventError ErrorReason errorMessageRecord
      ]
```

`claudeCliBatch` is the existing CLI invocation (refactored to return an
`Either Text (Text, Integer)` carrying either the assistant body or the
error message). The handler registers both `stream = claudeCliStream` and
`complete = streamingComplete claudeCliStream`.

The synthetic stream emits all events from a single `Stream.fromList`,
which `streamly` represents as an in-memory list — there is no true
streaming for the CLI providers, just protocol conformance.

**Acceptance.** `cabal test baikai-smoke` (with `claude -p` and `codex`
installed) passes all four providers — both the new live streaming smoke
and the existing batch smoke (which now drains the stream).

### Milestone 5: rebuild the trace bridge around the event stream

**Modified file:** `baikai/src/Baikai/Trace.hs`. Replace `withTrace` with
two functions: a stream-shaped tracing combinator and a draining wrapper:

```haskell
withTraceStream :: TraceSink -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
withTraceStream sink m ctx opts =
  let inner = streamRequest m ctx opts
  in Stream.mapM (sideEffectTrace sink m ctx opts) inner
  where
    sideEffectTrace = ...  -- emits CallStarted on the first event, CallFinished/CallFailed on terminal events

withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
withTrace sink m ctx opts = withRunInIO $ \_ ->
  Stream.fold reassembleResponse (withTraceStream sink m ctx opts)
```

`sideEffectTrace` is a side-effecting `IO`-returning function called on
every event. It maintains its own `IORef` of "did I emit `CallStarted`
yet?" so the bridge can fire `CallStarted` on the first non-skip event and
fire `CallFinished` / `CallFailed` on the terminal event. The same
`Chan + forkIO` worker pattern used in the existing `withTrace`
(`baikai/src/Baikai/Trace.hs:73-96`) drains the trace events through the
sink's fold; the only change is that the source of `TraceEvent` values is
the event stream's lifecycle, not a one-shot before/after wrap.

`reassembleResponse` is the same fold used by `streamingComplete`
(Milestone 1) — extracted into a public helper in `Baikai.Stream` so the
trace bridge does not duplicate the reassembly logic.

**Modified file:** `baikai/src/Baikai/Cost/Log.hs`. `runRequestWithLog`
becomes:

```haskell
runRequestWithLog :: MonadUnliftIO m
  => CallLogHandle -> Model -> Context -> Options -> m Response
runRequestWithLog h m ctx opts = do
  resp <- liftIO (completeRequest m ctx opts)
  appendEntry h (entryFor m ctx resp)
  pure resp

runRequestWith :: MonadUnliftIO m
  => TraceSink -> CallLogHandle -> Model -> Context -> Options -> m Response
runRequestWith sink h m ctx opts = do
  resp <- withTrace sink m ctx opts
  appendEntry h (entryFor m ctx resp)
  pure resp
```

The cost log writes to the same `CallLogEntry` JSON shape — only the input
sourcing changes (the `Context` provides the summary, the `Model` provides
the provider/model labels).

**Acceptance.** `cabal test baikai` is green. The trace specs in
`TraceSpec.hs` continue to assert one `CallStarted` and one
`CallFinished` per request; new assertions cover the stream-side path
(`withTraceStream` produces the same `TraceEvent`s when drained via
`Stream.toList`).

### Milestone 6: streaming smoke coverage

**New file:** `baikai-smoke/test/StreamingSmoke.hs`. The test:

```haskell
testStreaming :: TestTree
testStreaming = testCase "Anthropic streams text deltas" $ do
  Claude.register
  let model = anthropicSmokeModel "claude-haiku-4-5"
  events <- Stream.toList (streamRequest model (_Context { messages = V.singleton (user "hi") }) _Options)
  let textDeltas = [ d | TextDelta _ d <- events ]
  assertBool "at least one TextDelta" (not (null textDeltas))
  case last events of
    EventDone Stop msg -> assertBool "non-zero usage" (inputTokens (usage msg) > 0)
    other -> assertFailure $ "expected EventDone Stop, got: " <> show other
```

A symmetric `testCase` covers the OpenAI provider. Both skip when the
respective API key env var is absent.

**Modified file:** `baikai-smoke/baikai-smoke.cabal`. Add the new module
to the test-suite's `other-modules` (or `main-is` if running as a separate
target). No new deps.

**Acceptance.** With both API keys set,
`cabal test baikai-smoke --test-options=-p '/Streaming/'` reports both
streaming cases passing. The existing batch smoke cases continue to pass
through the draining `completeRequest`.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/baikai` in the Nix devshell:

```bash
nix develop

# Milestone 1: event algebra + stream surface
cabal build baikai

# Milestone 2: anthropic stream producer
cabal build baikai-claude

# Milestone 3: openai stream producer
cabal build baikai-openai

# Milestone 4: CLI providers
cabal build all

# Milestone 5: trace bridge
cabal test baikai
cabal test baikai-trace-otel

# Milestone 6: streaming smoke
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... cabal test baikai-smoke
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green.
- `cabal test all` is green with no API keys set (live cases skip).
- With API keys set, `cabal test baikai-smoke` runs both streaming cases
  (Anthropic and OpenAI) and reports success. Each emits at least one
  `TextDelta` event and terminates with `EventDone Stop` carrying non-zero
  usage.
- `cabal repl baikai` shows the new signatures:

  ```haskell
  ghci> :t streamRequest
  streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  ghci> :t withTraceStream
  withTraceStream :: TraceSink -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
  ghci> :t completeRequest
  completeRequest :: Model -> Context -> Options -> IO Response   -- unchanged shape; new impl
  ```

- The synchronous `completeRequest` produces a `Response` with identical
  semantics to the pre-streaming implementation (modulo content blocks).
  The existing batch smoke tests pass without modification beyond the
  assertion helper updates from EP-1.


## Idempotence and Recovery

Each provider's stream producer forks one worker thread per call and uses a
`Nothing` sentinel on the channel to terminate. Producer-side exceptions are
caught with `try @SomeException` and converted into `EventError`. Consumer-
side exceptions (inside a downstream `Stream.fold`) propagate to the caller
unchanged — that is the expected behaviour for streamly folds.

Re-running a streaming call is safe; the upstream APIs are idempotent for
the same `Context`. There is no shared mutable state across calls except
the global registry, which is unaffected by stream lifecycle.

If a smoke test runs against a real provider and hits a rate limit, the
upstream SDK returns an HTTP error that surfaces as `EventError ErrorReason
...` with `errorMessage` carrying the upstream message. The smoke test
catches this and reports a skip, not a failure, to avoid CI flakiness.

If the channel-bridge produces a deadlock (a stuck worker thread), the
fallback is to add a `bracket` around the `forkIO` that kills the worker
on early exit. This is not necessary in normal operation because the
worker always reaches `writeChan chan Nothing` whether it succeeds or
throws, but it is a recovery path documented here.


## Interfaces and Dependencies

**External dependencies.** No new Hackage / vendored dependencies. The
`baikai-claude` package gains a `streamly`/`streamly-core` build-dep
mirroring `baikai-openai`'s existing entries.

**Module surface at end of plan.**

From `Baikai`:

```haskell
data AssistantMessageEvent = EventStart | TextStart | TextDelta | TextEnd | ThinkingStart | ThinkingDelta | ThinkingEnd | ToolCallStart | ToolCallDelta | ToolCallEnd | EventDone | EventError

streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
completeRequest :: Model -> Context -> Options -> IO Response   -- unchanged shape

reassembleResponse :: Fold IO AssistantMessageEvent Response    -- exposed for re-use
streamingComplete  :: (Model -> Context -> Options -> Stream IO AssistantMessageEvent)
                   -> Model -> Context -> Options -> IO Response
```

From `Baikai.Trace`:

```haskell
withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
withTraceStream :: TraceSink -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
runRequestWith :: MonadUnliftIO m => TraceSink -> CallLogHandle -> Model -> Context -> Options -> m Response
```

From each vendor provider:

```haskell
register :: IO ()    -- installs both stream + complete (the latter as streamingComplete . stream)
```

EP-4 (`docs/plans/10-tools-and-context-overhaul.md`) consumes the
`ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` events and adds the tool
encoding to the request side. EP-5 wires `CacheRetention` and
`ThinkingLevel` through the stream options into each provider's request
builder. EP-6 generates `Model` records but does not touch the stream
algebra.
