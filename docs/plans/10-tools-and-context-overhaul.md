---
id: 10
slug: tools-and-context-overhaul
title: "Tools and Context overhaul"
kind: exec-plan
created_at: 2026-05-14T15:09:00Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Tools and Context overhaul

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a baikai consumer can declare a `Tool` with a JSON-schema-typed
parameters object, thread it through `Context.tools`, and complete a multi-turn
conversation in which the model invokes the tool and the consumer feeds the result
back into the next request. Tool calls appear as `AssistantToolCall` content blocks
in the assistant message and stream as `ToolCallStart` / `ToolCallDelta` /
`ToolCallEnd` events. Tool results enter the next request as `ToolResultMessage`
entries in `Context.messages`.

The user-visible payoff is a two-turn smoke test in `baikai-smoke` that runs the
same `get_time` tool-using conversation against Anthropic Claude and OpenAI Chat
Completions and asserts both:

1. produce an `AssistantToolCall` block in the first turn whose name is
   `"get_time"`, and
2. produce a final-answer `AssistantText` block in the second turn that incorporates
   the tool's output (the current timestamp).

CLI providers (`Baikai.Provider.Claude.Cli`, `Baikai.Provider.OpenAI.Cli`) do not
participate in this plan — they remain text-only (`AssistantText` blocks only),
documented in the masterplan's Decision Log. The smoke test only runs against the
two API providers.

A consumer can write, after this plan:

```haskell
import Baikai
import Baikai.Provider.Claude.Api qualified as Claude
import Data.Aeson qualified as Aeson

main :: IO ()
main = do
  Claude.register
  let model = anthropicModel "claude-sonnet-4-6"
      getTime = Tool
        { name = "get_time"
        , description = "Get the current ISO-8601 timestamp."
        , parameters = Aeson.object
            [ "type"       .= ("object" :: Text)
            , "properties" .= Aeson.object []
            , "required"   .= ([] :: [Text])
            ]
        }
      ctx0 = _Context
        { messages = V.singleton (user "What time is it?")
        , tools = V.singleton getTime
        }
  resp1 <- completeRequest model ctx0 _Options
  -- pattern-match on resp1.message.content for the tool call
  -- execute the tool, then send the result back
  ctx1 <- appendToolResult ctx0 resp1 (\_ -> pure "2026-05-14T15:09:00Z")
  resp2 <- completeRequest model ctx1 _Options
  -- resp2.message.content should be an AssistantText answering the question
```


## Progress

- [x] Milestone 1: introduce `Baikai.Tool`. Extend `Baikai.Context` with
      `tools :: Vector Tool`. Extend `Baikai.Options` with `toolChoice :: Maybe
      ToolChoice`. No provider exercises tools yet at the end of this milestone.
      Landed 2026-05-14: `Tool`, `ToolChoice`, `_Tool` ship in
      `baikai/src/Baikai/Tool.hs`; `tools :: Vector Tool` added to
      `Baikai.Context`; `toolChoice :: Maybe ToolChoice` added to
      `Baikai.Options`. `appendToolResult` lives in `Baikai.Context` (not
      `Baikai.Tool`) to break the cycle — see Decision Log. `cabal test
      baikai baikai-trace-otel` is green (20/20).
- [ ] Milestone 2: implement tool encoding/decoding in
      `Baikai.Provider.Claude.Api`. Map `Context.tools` into Anthropic
      `ToolDefinition`s; decode `Content_Block_Start { content_block =
      ToolUse }` into `AssistantToolCall` and `Content_Block_Delta {
      Delta_Input_Json_Delta }` into `ToolCallDelta`. Decode
      `ToolResultMessage` entries into Anthropic `ContentBlock_ToolResult`
      blocks on the request side.
- [ ] Milestone 3: implement tool encoding/decoding in
      `Baikai.Provider.OpenAI.Api`. Map `Context.tools` into OpenAI Chat
      Completions `Tool` definitions; decode `tool_calls` deltas into
      `ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` events; decode
      `ToolResultMessage` entries into `Chat.Tool` request messages.
- [ ] Milestone 4: add the tool-using smoke test
      `baikai-smoke/test/ToolsSmoke.hs`. Both providers complete the
      two-turn conversation and produce the expected output.


## Surprises & Discoveries

- M1: The plan's sketch of an `appendToolResult` living in
  `Baikai.Tool` creates an unavoidable module cycle. `Baikai.Context`
  must import `Baikai.Tool` for the `tools :: Vector Tool` field
  type, but `appendToolResult :: Context -> Response -> ...` needs
  `Baikai.Context` and `Baikai.Response`. The fix landed:
  `Baikai.Tool` exports just `Tool`, `ToolChoice`, `_Tool` (no
  baikai-internal imports); `appendToolResult` was moved into
  `Baikai.Context`, where the cycle does not exist. Future plans
  that add helper combinators around tools should follow the same
  layering — keep `Baikai.Tool` types-only, hang operations off
  the consuming modules (`Context` for conversation building,
  later `Response` for tool-call extraction).
- M1: GHC's `-Wpartial-fields` is happy with the new `tools` field
  on `Context` because `Context` is a record-type, not a sum. The
  same pattern (adding a field) on `Message` would warn since the
  `tools` field would not exist on every constructor.


## Decision Log

- Decision: `Tool.parameters` is a `Data.Aeson.Value` carrying raw JSON Schema,
  not a typed schema GADT.
  Rationale: Callers who want a typed schema layer can use `aeson-schemas` or
  hand-write a JSON Schema and `toJSON` the result. Introducing a typed
  parameters representation mid-initiative would force every caller into one
  schema library and balloon EP-4's scope. The masterplan's Decision Log
  endorses this trade-off.
  Date: 2026-05-14

- Decision: Tools live on `Context.tools`, not on `Options.tools`.
  Rationale: A tool set is part of the conversation contract — the same
  `(systemPrompt, messages, tools)` triple defines what the model can do for a
  given thread. Putting tools on `Options` would imply they vary per call
  within a thread, which is rare and harmful. pi-mono makes the same choice.
  The masterplan's Decision Log endorses this.
  Date: 2026-05-14

- Decision: Tool call IDs are normalized to `[a-zA-Z0-9_-]+` and capped at 64
  characters before being sent to Anthropic.
  Rationale: Anthropic's API enforces this pattern; OpenAI is more permissive.
  Normalizing on the request side means callers can use any naming convention
  and the provider boundary handles compatibility. This mirrors pi-mono's
  `normalizeToolCallId` helper in `packages/ai/src/providers/anthropic.ts`.
  Date: 2026-05-14

- Decision: Tool execution itself is not implemented inside baikai. Callers
  dispatch tool calls in their own code; baikai only handles encoding,
  decoding, and the message-shape round-trip.
  Rationale: Tool execution is wildly application-specific (sandboxing,
  permission model, async fan-out, RPC to external services). baikai's role
  is the provider adapter, not the agent runtime. A future package
  (`baikai-tools` or similar) could ship a typeclass-based dispatcher, but it
  is out of scope here. pi-mono makes the same choice — callers execute the
  tool themselves and shove the result into the next request's `Context`.
  Date: 2026-05-14

- Decision: A helper `appendToolResult :: Context -> Response -> (ToolCall ->
  IO Text) -> IO Context` lives in `Baikai.Context` (not `Baikai.Tool` as
  the plan originally sketched) for the common case where every tool call
  in the previous response produces a single text result.
  Rationale: Most callers want the obvious helper. Power users build the
  `ToolResultMessage` records by hand. The helper is a thin wrapper that
  finds every `AssistantToolCall` in `Response.message.assistantContent`,
  calls the caller-supplied dispatcher to produce a result text per call,
  builds a `ToolResultMessage` per call, appends the assistant message and
  the tool-result messages to the context, and returns the updated
  `Context`. The home-module choice (`Baikai.Context` rather than
  `Baikai.Tool`) avoids a module cycle: `Baikai.Tool` exports `Tool`, which
  `Baikai.Context.Context.tools` references, so `Baikai.Tool` cannot itself
  depend on `Baikai.Context`. Keeping the helper next to `Context` is also
  the most natural layering since the helper's sole job is building a new
  `Context`. The plan's original suggestion that the helper lives in
  `Baikai.Tool` is superseded by this entry.
  Date: 2026-05-14

- Decision: `Baikai.Tool` exports just `Tool`, `ToolChoice`, and `_Tool`
  — no operations.
  Rationale: Cycle avoidance (see the previous entry). Future combinator
  work can either extend `Baikai.Context` (when the operation produces a
  `Context`) or introduce a new sibling module (`Baikai.Tool.Combinators`
  or similar) without revising this decision.
  Date: 2026-05-14

- Decision: The existing `Baikai.Message.toolResult :: Text -> Text ->
  Text -> Bool -> Message` helper (introduced by EP-1) is reused by
  `appendToolResult` rather than introducing a new `mkToolResult`.
  Rationale: The plan's sketched `mkToolResult` is functionally identical
  to the existing `toolResult` modulo a `UTCTime` parameter. The existing
  helper samples the clock via `unsafePerformIO getCurrentTime` with a
  `NOINLINE` pragma, which is what `appendToolResult` would do anyway.
  No new public surface is added.
  Date: 2026-05-14


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is the fourth in the `Streaming, Content Blocks, and Tool Calls`
initiative defined in `docs/masterplans/2-streaming-content-blocks-and-tool-calls.md`.
It depends hard on:

- EP-1 (`docs/plans/7-typed-content-blocks-richer-usage-and-stopreason.md`)
  for the `ToolCall` and `AssistantToolCall` content-block shapes and the
  `ToolResultMessage` message constructor.
- EP-2 (`docs/plans/8-api-tag-model-record-and-provider-registry.md`) for
  the `Context` and `Options` records.
- EP-3 (`docs/plans/9-streaming-event-protocol-with-streamly.md`) for the
  `ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` event variants and for
  the streaming JSON-argument delivery from the upstream SDKs.

After EP-3 the streaming infrastructure already produces the
`ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` events when an upstream
event includes a tool-use content block (Anthropic) or a tool_call delta
(OpenAI). What is missing — and what this plan adds — is the request-side
encoding (`Context.tools → upstream tool definitions`) and the
`ToolResultMessage → upstream tool-result message` mapping.

The upstream Anthropic SDK at
`/Users/shinzui/Keikaku/hub/haskell/claude-project/claude` exposes tool types
in `Claude.V1.Tool`:

```haskell
data Tool
  = FunctionTool ToolDefinition
  | InlineTool ...
  | DeferredTool ...
  | ...

data ToolDefinition = ToolDefinition
  { name :: !Text
  , description :: !(Maybe Text)
  , input_schema :: !InputSchema     -- JSON Schema or a typed schema
  , cache_control :: !(Maybe CacheControl)
  }

data InputSchema = InputSchema { schema :: !Aeson.Value }
```

Anthropic's content blocks include `ContentBlock_ToolUse { id, name, input }`
on the response side and `ContentBlock_ToolResult { tool_use_id, content,
is_error }` on the request side.

The upstream OpenAI SDK at
`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai` exposes tool types
in `OpenAI.V1.Tool`:

```haskell
data Tool = Tool
  { type_ :: !Text                  -- always "function" for our purposes
  , function :: !FunctionTool
  }

data FunctionTool = FunctionTool
  { name :: !Text
  , description :: !(Maybe Text)
  , parameters :: !(Maybe Aeson.Value)
  , strict :: !(Maybe Bool)
  }
```

OpenAI Chat Completions carries tool calls under `Message.tool_calls :: Maybe
(Vector ToolCall)` where:

```haskell
data ToolCall = ToolCall
  { id :: !Text
  , type_ :: !Text
  , function :: !FunctionCall
  }

data FunctionCall = FunctionCall
  { name :: !Text
  , arguments :: !Text             -- JSON-encoded string
  }
```

And tool results enter the conversation as a `Chat.Tool` message:

```haskell
Chat.Tool
  { tool_call_id :: !Text
  , content :: !Text
  }
```

After EP-3, the streaming producer for Claude (in
`baikai-claude/src/Baikai/Provider/Claude/Api.hs`) already maps
`Content_Block_Start { content_block = ContentBlock_ToolUse {..} }` to
`ToolCallStart` and `Content_Block_Delta { Delta_Input_Json_Delta partial_json }`
to `ToolCallDelta`. The closing `Content_Block_Stop` already builds a
`ToolCall` and emits `ToolCallEnd`. This plan adds the matching request-side
encoding.

After EP-3, the streaming producer for OpenAI (in
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`) already keeps a per-
tool-call-index accumulator that maps OpenAI `tool_calls` deltas to baikai
events. This plan adds the request-side encoding.


## Plan of Work

### Milestone 1: introduce `Baikai.Tool` and extend `Context` + `Options`

**New file:** `baikai/src/Baikai/Tool.hs`:

```haskell
data Tool = Tool
  { name :: !Text
  , description :: !Text
  , parameters :: !Aeson.Value      -- JSON Schema
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ToolChoice
  = ToolChoiceAuto                  -- model decides
  | ToolChoiceNone                  -- never call tools
  | ToolChoiceRequired              -- must call some tool
  | ToolChoiceSpecific !Text        -- must call this tool by name
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- Helper: build a ToolResult message from a string body.
mkToolResult
  :: Text       -- ^ tool call id
  -> Text       -- ^ tool name
  -> Text       -- ^ body text
  -> Bool       -- ^ isError
  -> UTCTime
  -> Message
mkToolResult callId toolName body isError ts = ToolResultMessage
  { toolCallId = callId
  , toolName = toolName
  , content = V.singleton (ToolResultText (TextContent body))
  , isError = isError
  , timestamp = ts
  }

-- Common-case helper.
appendToolResult
  :: Context
  -> Response
  -> (ToolCall -> IO Text)        -- caller's dispatcher; returns the textual result
  -> IO Context
appendToolResult ctx resp dispatcher = do
  let toolCalls = [ tc | AssistantToolCall tc <- V.toList (content (message resp)) ]
  now <- getCurrentTime
  results <- forM toolCalls $ \tc -> do
    body <- dispatcher tc
    pure (mkToolResult (id_ tc) (name tc) body False now)
  pure ctx
    { messages = messages ctx
        <> V.singleton (asMessage (message resp))
        <> V.fromList results
    }

asMessage :: AssistantMessage -> Message
asMessage = ...  -- EP-1 chooses whether AssistantMessage is itself a constructor or wrapped via pattern synonym
```

**Modified file:** `baikai/src/Baikai/Context.hs`. Extend the record:

```haskell
data Context = Context
  { systemPrompt :: !(Maybe Text)
  , messages :: !(Vector Message)
  , tools :: !(Vector Tool)
  }

_Context :: Context
_Context = Context Nothing V.empty V.empty
```

**Modified file:** `baikai/src/Baikai/Options.hs`. Add `toolChoice`:

```haskell
data Options = Options
  { maxTokens :: !(Maybe Natural)
  , temperature :: !(Maybe Double)
  , apiKey :: !(Maybe Text)
  , timeoutMs :: !(Maybe Int)
  , headers :: !(Map Text Text)
  , metadata :: !(Map Text Value)
  , cacheRetention :: !(Maybe CacheRetention)   -- defined by EP-5; placeholder OK here
  , sessionId :: !(Maybe Text)
  , toolChoice :: !(Maybe ToolChoice)
  }
```

If EP-5 has not yet shipped `CacheRetention`, define a placeholder
`data CacheRetention = CacheRetentionNone` here; EP-5 expands the type. This
plan only consumes `toolChoice`.

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.Tool` to `exposed-modules`.

**Acceptance.** `cabal build all` is green. `cabal repl baikai`:

```haskell
ghci> :t Tool
Tool :: Text -> Text -> Aeson.Value -> Tool
ghci> :t appendToolResult
appendToolResult :: Context -> Response -> (ToolCall -> IO Text) -> IO Context
```

### Milestone 2: Anthropic tool encoding/decoding

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. The
existing `mapContextToCreateMessage` already maps `Context.systemPrompt` and
`Context.messages`. Extend it:

```haskell
mapContextToCreateMessage :: Model -> Context -> Options -> Messages.CreateMessage
mapContextToCreateMessage m ctx opts = Messages._CreateMessage
  { Messages.model = modelId m
  , Messages.messages = V.fromList (concatMap (mapMessage m) (V.toList (messages ctx)))
  , Messages.max_tokens = fromMaybe (maxOutputTokens m) (maxTokens opts)
  , Messages.system = fmap Messages.SystemPromptText (systemPrompt ctx)
  , Messages.temperature = temperature opts
  , Messages.tools = if V.null (tools ctx)
                       then Nothing
                       else Just (V.map mkAnthropicTool (tools ctx))
  , Messages.tool_choice = fmap mkAnthropicToolChoice (toolChoice opts)
  }

mkAnthropicTool :: Tool -> Claude.ToolDefinition
mkAnthropicTool t = Claude.functionTool (name t)
  & Claude.withToolDescription (description t)
  & Claude.withToolInputSchema (Claude.InputSchema { schema = parameters t })

mkAnthropicToolChoice :: ToolChoice -> Claude.ToolChoice
mkAnthropicToolChoice = \case
  ToolChoiceAuto -> Claude.ToolChoiceAuto
  ToolChoiceNone -> Claude.ToolChoiceNone
  ToolChoiceRequired -> Claude.ToolChoiceAny
  ToolChoiceSpecific name -> Claude.toolChoiceTool name
```

(Exact constructor / helper names depend on what `Claude.V1.Tool` exports;
the plan refers to the upstream module for ground truth.)

`mapMessage` now handles three message constructors:

```haskell
mapMessage :: Model -> Message -> [Messages.Message]
mapMessage _ (UserMessage { content }) = [mkUserMessage (mapUserContent content)]
mapMessage _ (AssistantMessage { content }) = [mkAssistantMessage (mapAssistantContent content)]
mapMessage _ (ToolResultMessage { toolCallId, content, isError }) =
  [ mkMessage Messages.User
      (V.singleton (Messages.ContentBlock_ToolResult
        { Messages.tool_use_id = normalizeToolCallId toolCallId
        , Messages.content = mapToolResultContent content
        , Messages.is_error = Just isError
        }))
  ]

mapAssistantContent :: Vector AssistantContent -> Vector Messages.ContentBlock
mapAssistantContent = V.map $ \case
  AssistantText (TextContent t) -> Messages.ContentBlock_Text t
  AssistantThinking (ThinkingContent { thinking, signature }) ->
    Messages.ContentBlock_Thinking { thinking, signature = fromMaybe "" signature }
  AssistantToolCall (ToolCall { id_, name, arguments }) ->
    Messages.ContentBlock_ToolUse
      { Messages.id = normalizeToolCallId id_
      , Messages.name = name
      , Messages.input = arguments
      }

normalizeToolCallId :: Text -> Text
normalizeToolCallId =
  Text.take 64 . Text.map (\c -> if isOkChar c then c else '_')
  where isOkChar c = isAsciiAlphaNum c || c == '_' || c == '-'
```

**Acceptance.** `cabal build all` is green. A REPL session with
`ANTHROPIC_API_KEY` set can run:

```haskell
ghci> Claude.register
ghci> let getTime = Tool "get_time" "Get the current time" (Aeson.object ["type" .= ("object" :: Text)])
ghci> resp <- completeRequest claudeModel (_Context { messages = V.singleton (user "what time is it?"), tools = V.singleton getTime }) _Options
ghci> V.toList (content (message resp))
[AssistantToolCall (ToolCall { id_ = "toolu_...", name = "get_time", arguments = Object [] })]
```

### Milestone 3: OpenAI tool encoding/decoding

**Modified file:** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. The
existing `mapContextToCreateChatCompletion` is extended:

```haskell
mapContextToCreateChatCompletion :: Model -> Context -> Options -> Chat.CreateChatCompletion
mapContextToCreateChatCompletion m ctx opts = Chat._CreateChatCompletion
  { Chat.model = OpenAIModels.Model (modelId m)
  , Chat.messages = V.fromList (concatMap (mapMessageOpenAI m) (V.toList (messages ctx)))
  , Chat.max_completion_tokens = maxTokens opts
  , Chat.temperature = temperature opts
  , Chat.tools = if V.null (tools ctx)
                   then Nothing
                   else Just (V.map mkOpenAITool (tools ctx))
  , Chat.tool_choice = fmap mkOpenAIToolChoice (toolChoice opts)
  , Chat.stream = Just True
  , Chat.stream_options = Just _ChatCompletionStreamOptions { include_usage = Just True }
  }

mkOpenAITool :: Tool -> OpenAITool.Tool
mkOpenAITool t = OpenAITool.Tool
  { type_ = "function"
  , function = OpenAITool.FunctionTool
      { name = name t
      , description = Just (description t)
      , parameters = Just (parameters t)
      , strict = Just False        -- strict mode off by default; EP-5 makes this compat-driven
      }
  }

mkOpenAIToolChoice :: ToolChoice -> OpenAITool.ToolChoice
mkOpenAIToolChoice = \case
  ToolChoiceAuto -> OpenAITool.ToolChoiceAuto
  ToolChoiceNone -> OpenAITool.ToolChoiceNone
  ToolChoiceRequired -> OpenAITool.ToolChoiceRequired
  ToolChoiceSpecific name -> OpenAITool.ToolChoiceTool { type_ = "function", function = OpenAITool.ToolChoiceFunction { name } }
```

`mapMessageOpenAI` handles the three message constructors:

```haskell
mapMessageOpenAI :: Model -> Message -> [Chat.Message (Vector Chat.Content)]
mapMessageOpenAI _ (UserMessage { content }) =
  [Chat.User { Chat.content = mapUserContentOpenAI content, Chat.name = Nothing }]
mapMessageOpenAI _ (AssistantMessage { content }) =
  let (textBits, toolCalls) = partitionAssistant content
      assistantContent = if Text.null textBits then Nothing
                           else Just (V.singleton Chat.Text { Chat.text = textBits })
  in [Chat.Assistant
        { Chat.assistant_content = assistantContent
        , Chat.tool_calls = if V.null toolCalls then Nothing else Just toolCalls
        , Chat.refusal = Nothing
        , Chat.name = Nothing
        , Chat.assistant_audio = Nothing
        }]
mapMessageOpenAI _ (ToolResultMessage { toolCallId, content, isError }) =
  [Chat.Tool
      { Chat.tool_call_id = toolCallId
      , Chat.content = flattenToolResultText content
      }]

partitionAssistant :: Vector AssistantContent -> (Text, Vector Chat.ToolCall)
partitionAssistant = ...
```

OpenAI does not have a native isError signal for tool results; the smoke
test sets `isError = False` for the success path and ignores the error
path for now. The masterplan records that the discrepancy is provider-
specific.

The streaming producer from EP-3 already decodes OpenAI tool-call deltas
into `ToolCallStart` / `ToolCallDelta` / `ToolCallEnd` events.

**Acceptance.** `cabal build all` is green. The same REPL invocation as
Milestone 2 but with the OpenAI model returns an `AssistantToolCall` block.

### Milestone 4: tool-using smoke test

**New file:** `baikai-smoke/test/ToolsSmoke.hs`:

```haskell
testToolRoundTrip :: TestTree
testToolRoundTrip = testGroup "Tool round-trip"
  [ testCase "Anthropic" (toolRoundTrip claudeModel)
  , testCase "OpenAI"    (toolRoundTrip openaiModel)
  ]

toolRoundTrip :: Model -> IO ()
toolRoundTrip model = do
  let getTime = Tool
        { name = "get_time"
        , description = "Return the current UTC ISO-8601 timestamp."
        , parameters = Aeson.object
            [ "type"       .= ("object" :: Text)
            , "properties" .= Aeson.object []
            , "required"   .= ([] :: [Text])
            ]
        }
      ctx0 = _Context
        { messages = V.singleton (user "What time is it? Use the get_time tool to find out.")
        , tools = V.singleton getTime
        }
  resp1 <- completeRequest model ctx0 _Options { maxTokens = Just 1024 }
  let toolCalls = [ tc | AssistantToolCall tc <- V.toList (content (message resp1)) ]
  case toolCalls of
    [tc] -> do
      assertEqual "tool call name" "get_time" (name tc)
      ctx1 <- appendToolResult ctx0 resp1 (\_ -> pure "2026-05-14T15:09:00Z")
      resp2 <- completeRequest model ctx1 _Options { maxTokens = Just 1024 }
      let texts = [ t | AssistantText (TextContent t) <- V.toList (content (message resp2)) ]
      assertBool "final answer mentions timestamp" (any (Text.isInfixOf "2026-05-14") texts)
    _ -> assertFailure $ "expected exactly one tool call; got: " <> show toolCalls
```

The test skips when the respective API key is not set, matching the
pattern in the existing `Smoke.hs`.

**Modified file:** `baikai-smoke/baikai-smoke.cabal`. Add the new module to
the test-suite's `other-modules`. No new deps.

**Acceptance.** With both API keys set, `cabal test baikai-smoke
--test-options=-p '/Tool round-trip/'` reports both cases passing.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/baikai` in the Nix devshell:

```bash
nix develop

# Milestone 1: tool types + context/options extensions
cabal build baikai

# Milestone 2: anthropic tool encoding
cabal build baikai-claude

# Milestone 3: openai tool encoding
cabal build baikai-openai

# Milestone 4: smoke
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... cabal test baikai-smoke
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green.
- `cabal test all` is green with no API keys set (live cases skip).
- With both API keys set, the tool round-trip smoke completes for both
  Anthropic Claude and OpenAI Chat Completions. Each provider produces an
  `AssistantToolCall` block in the first turn and an `AssistantText` block
  in the second turn that references the timestamp supplied as the tool's
  result.
- `cabal repl baikai` shows the new types:

  ```haskell
  ghci> :t Tool
  Tool :: Text -> Text -> Aeson.Value -> Tool
  ghci> :i Context
  data Context = Context { systemPrompt :: Maybe Text, messages :: Vector Message, tools :: Vector Tool }
  ```


## Idempotence and Recovery

The smoke test is idempotent — calling it repeatedly costs API tokens but
does not mutate any provider-side state.

If a smoke test reveals a schema mismatch (e.g. Anthropic rejects a
tool definition because the JSON Schema is malformed), record the
discovery in `Surprises & Discoveries` and tighten the encoder. The
`Tool.parameters :: Aeson.Value` field gives callers full control over
the schema, so encoder bugs are unlikely.

If the model fails to call the tool (e.g. it answers directly without a
`AssistantToolCall` block), the test prints the response and fails. The
prompt is engineered to nudge the model to use the tool ("Use the
get_time tool to find out") but is not guaranteed. If the test proves
flaky in CI, the fallback is to mark it `flaky` and run it only when
explicitly requested.


## Interfaces and Dependencies

**External dependencies.** No new Hackage / vendored dependencies. The
Anthropic SDK's tool types in `Claude.V1.Tool` and the OpenAI SDK's tool
types in `OpenAI.V1.Tool` cover everything needed.

**Module surface at end of plan.**

From `Baikai`:

```haskell
data Tool = Tool { name, description :: !Text, parameters :: !Aeson.Value }
data ToolChoice = ToolChoiceAuto | ToolChoiceNone | ToolChoiceRequired | ToolChoiceSpecific !Text

data Context = Context { systemPrompt :: !(Maybe Text), messages :: !(Vector Message), tools :: !(Vector Tool) }
data Options = Options { ..., toolChoice :: !(Maybe ToolChoice) }

mkToolResult :: Text -> Text -> Text -> Bool -> UTCTime -> Message
appendToolResult :: Context -> Response -> (ToolCall -> IO Text) -> IO Context
```

EP-5 (`docs/plans/11-compat-shims-cache-retention-and-multi-host-providers.md`)
adds compat-driven tool encoding (e.g. setting `strict = True` on OpenAI tool
definitions when the host supports strict-mode tools). EP-6
(`docs/plans/12-generated-model-catalog.md`) annotates generated `Model`
records with tool support metadata but does not change `Tool` or
`ToolChoice`.
