# Tools

baikai supports tool calling against Anthropic and OpenAI APIs.
Tools are declared on the `Context` (so they're part of the
conversation contract, not a per-call knob), the model emits tool
calls as `AssistantToolCall` content blocks, and the caller feeds
results back as `ToolResultMessage` entries in the next turn.

> CLI providers (`claude -p`, `codex exec`) do **not** support
> tools — `Context.tools` and `Options.toolChoice` are silently
> ignored when dispatching under `AnthropicMessagesCli` /
> `OpenAICompletionsCli`. If you need tools, dispatch under
> `AnthropicMessages` or `OpenAIChatCompletions` instead. See
> [CLI Providers](cli-providers.md) for the full set of CLI
> limitations.

## Define a tool

```haskell
import Baikai
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Vector qualified as V

getTime :: Tool
getTime =
  _Tool
    { name = "get_time"
    , description = "Return the current UTC ISO-8601 timestamp."
    , parameters =
        Aeson.object
          [ "type" .= ("object" :: Text)
          , "properties" .= Aeson.object []
          , "required" .= ([] :: [Text])
          ]
    }
```

`parameters` is a JSON Schema, carried as `Data.Aeson.Value`. The
provider passes it through to the upstream API verbatim, so any
schema the upstream model accepts is fair game (nested objects,
unions via `oneOf`, descriptions, defaults, …).

## Wire tools into a Context

```haskell
ctx :: Context
ctx =
  _Context
    & #messages .~ V.singleton (user "What time is it? Use the tool.")
    & #tools .~ V.singleton getTime
```

The `tools` vector lives on `Context` because the same tool set
applies to every turn in a conversation. Forgetting to thread tools
through follow-up requests would silently drop them; keeping them
on the context makes that mistake impossible.

## Tool choice

`Options.toolChoice :: Maybe ToolChoice` controls how aggressively
the model picks a tool:

| `ToolChoice`              | Effect                                                                    |
|---------------------------|---------------------------------------------------------------------------|
| `Nothing` (default)       | Provider default (typically `auto`).                                      |
| `Just ToolChoiceAuto`     | Model decides whether to call a tool. Same as `Nothing` at most providers.|
| `Just ToolChoiceNone`     | Disable tool calling for this request. Anthropic: suppresses `tools` entirely. |
| `Just ToolChoiceRequired` | Model must call some tool.                                                |
| `Just (ToolChoiceSpecific "name")` | Model must call this specific tool.                              |

For a deterministic test or a "you must use this tool" turn, set
`ToolChoiceRequired` (or `ToolChoiceSpecific`). On the *follow-up*
turn — once you've fed the tool result back — set the choice to
`Nothing` or `ToolChoiceAuto` so the model can produce a final
answer instead of being forced into another tool call.

## The round-trip

The full pattern is two `completeRequest` calls with
`appendToolResult` between them:

```haskell
import Baikai
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as V

dispatcher :: ToolCall -> IO Text
dispatcher tc = case tc ^. #name of
  "get_time" -> do
    now <- getCurrentTime
    pure (Text.pack (iso8601Show now))
  other -> error $ "unknown tool: " <> Text.unpack other

runConversation :: IO Message
runConversation = do
  let model = Models.openai_gpt_4o_mini
      ctx0 =
        _Context
          & #messages .~ V.singleton (user "What time is it?")
          & #tools .~ V.singleton getTime
      base =
        _Options
          & #maxTokens .~ Just 1024
          & #temperature .~ Just 0.0
      turn1Opts = base & #toolChoice .~ Just ToolChoiceRequired
      turn2Opts = base & #toolChoice .~ Nothing

  -- Turn 1: model emits AssistantToolCall block(s).
  resp1 <- completeRequest model ctx0 turn1Opts

  -- Dispatch the tool calls, build the context for turn 2.
  ctx1 <- appendToolResult ctx0 resp1 dispatcher

  -- Turn 2: model speaks freely; should produce a final answer.
  resp2 <- completeRequest model ctx1 turn2Opts
  pure (resp2 ^. #message)
```

`appendToolResult` does three things:

1. Pulls every `AssistantToolCall` block out of `resp1`'s message.
2. Runs your `dispatcher` once per call, collecting the result text.
3. Returns a new `Context` with `resp1`'s message appended, then
   one `ToolResultMessage` per tool call.

The dispatcher's signature is `ToolCall -> IO Text` — any
exception handling, timeouts, or sandboxing is your responsibility.
If you want to report an error to the model rather than crash, set
`ToolResultMessage.isError = True`. (Build the message yourself
with `Baikai.Message.toolResult` and append it manually instead of
going through `appendToolResult`.)

## Inspecting tool calls

`AssistantToolCall` carries a `ToolCall`:

```haskell
data ToolCall = ToolCall
  { id_ :: !Text         -- provider-assigned call id; pair with toolCallId in the result
  , name :: !Text
  , arguments :: !Value  -- parsed JSON
  }
```

Pull them out of a response:

```haskell
let blocks = flattenAssistantBlocks resp
    toolCalls =
      [ tc | AssistantToolCall tc <- V.toList blocks ]
```

## Streaming tool calls

When you call `streamRequest`, tool calls show up as
`ToolCallStart` → `ToolCallDelta`* → `ToolCallEnd`. The argument
JSON arrives in chunks; concatenating every `ToolCallDelta.delta`
for a given `contentIndex` yields a syntactically valid JSON
value. The `ToolCallEnd.toolCall` field already has it parsed,
which is usually all you need.

## Caveats

- The model can rewrite tool-result text into prose. Don't assume
  the exact bytes you passed (`"2026-05-14T15:09:00Z"`) survive
  into the final answer — `gpt-4o-mini`, for example, may render
  it as "May 14, 2026 at 15:09 UTC". Assert on substring fragments
  if you need correctness checks.
- `ToolChoiceNone` is not a first-class Anthropic value; the
  Anthropic provider realises it by suppressing both `tools` and
  `tool_choice` in the upstream request.
- Tool-side `cache_control` for Anthropic is not currently wired
  through. Tool definitions are sent uncached even when the rest
  of the context is cached. See the EP-5 retrospective in the
  masterplan for the scope.
