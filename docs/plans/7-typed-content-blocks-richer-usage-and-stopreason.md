---
id: 7
slug: typed-content-blocks-richer-usage-and-stopreason
title: "Typed content blocks, richer Usage, and StopReason"
kind: exec-plan
created_at: 2026-05-14T15:01:00Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Typed content blocks, richer Usage, and StopReason

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a baikai consumer no longer treats an LLM response as a single
opaque blob of text. Instead they receive a sequence of typed content blocks — a
`TextContent`, a `ThinkingContent` (for reasoning models that surface their chain of
thought), or a `ToolCall` (for models that decide to invoke a tool). User messages
gain the ability to carry image content alongside text, and a new "tool result"
message lets a caller feed the output of a tool back into the next request.

Three smaller data-model improvements ride along: a `StopReason` enum on the
response (`Stop | Length | ToolUse | ErrorReason | Aborted`), a `Usage` record that
distinguishes cache-read tokens from cache-write tokens (and carries an in-place
`Cost` instead of attaching one later via a separate map lookup), and a `cost`
field that is always present (not `Maybe Cost`) — providers without pricing
information populate it with zero.

A consumer of `baikai` can see this working immediately after this plan: existing
smoke tests in `baikai-smoke/test/Smoke.hs` are migrated to pattern-match on
`Vector AssistantContent` and assert that Claude / OpenAI responses contain at
least one `AssistantText` block; new unit tests in `baikai/test/CostSpec.hs`
assert that cache-read and cache-write tokens are populated separately from the
upstream provider response; a small `baikai-smoke/test/ContentBlocksSmoke.hs`
case sends a user message with an inline image to Anthropic's Claude and asserts
the round-trip succeeds.

This plan deliberately keeps the existing `Provider` typeclass and the
synchronous `runRequest :: p -> Request -> m Response` shape intact. Streaming
(EP-3) and the `Api`/registry refactor (EP-2) build on top of this plan. EP-1
ships when the data model has changed but dispatch has not. The next plan in
sequence (`docs/plans/8-api-tag-model-record-and-provider-registry.md`) consumes
EP-1's new types and replaces the `Provider` typeclass with a registry.


## Progress

- [x] Milestone 1: introduce `Baikai.Content`, `Baikai.StopReason`, and the new
      `Usage` record with cache-read/write split and an in-place `Cost`. Build is
      green; legacy modules still import the old types. (2026-05-14)
- [x] Milestone 2: replace `Baikai.Message` and `Baikai.Response` with the typed
      shapes (`UserMessage` / `AssistantMessage` / `ToolResultMessage` and a
      `Response` wrapping an `AssistantMessage`). Update the public re-exports
      in `Baikai`. Baikai.Trace, Baikai.Cost.Log, Baikai.Cost.Pricing, and
      Baikai.Provider.Cli.Internal were migrated to the new shape as part of
      this milestone to keep the library compiling; the larger M4 work (cost
      reporting redesign) is therefore folded into this milestone. (2026-05-14)
- [ ] Milestone 3: migrate `Baikai.Provider.Claude.Api` and
      `Baikai.Provider.OpenAI.Api` (both in their respective vendor packages) to
      produce the new shapes. CLI providers wrap their text output in a
      single `AssistantText` block.
- [x] Milestone 4: migrate `Baikai.Cost`, `Baikai.Cost.Pricing`, `Baikai.Cost.Log`,
      and `Baikai.Trace` to consume the new `Usage` and `Response` shapes. The
      trace bridge in `Baikai.Trace.withTrace` continues to emit `CallStarted` /
      `CallFinished` / `CallFailed` events with the same field names. Landed
      alongside M2 to keep the baikai library compiling. (2026-05-14)
- [ ] Milestone 5: migrate every test target — `baikai/test/Main.hs`,
      `baikai/test/CostSpec.hs`, `baikai/test/TraceSpec.hs`,
      `baikai-trace-otel/test/Main.hs`, `baikai-smoke/test/Smoke.hs` — to the
      new types. `cabal test all` is green. Add a content-block smoke test that
      asserts the typed content arrives intact from both API providers.


## Surprises & Discoveries

- The plan called out that `Baikai.Usage` previously did not import
  `Baikai.Cost` and warned of a possible cycle. In fact `Baikai.Cost` does
  not depend on anything from `Baikai.Usage`, so `import Baikai.Cost
  (Cost, _Cost)` from inside `Baikai.Usage` introduced no cycle and no
  module restructure was needed.
- The decoded `Usage` had a derived `FromJSON` instance before EP-1.
  `Cost` only has a hand-rolled `ToJSON` and no `FromJSON`, so reusing
  the generic `FromJSON` on the new `Usage` (which now embeds a `Cost`)
  no longer typechecks. No call site exercises `FromJSON Usage` in the
  workspace today, so the `FromJSON Usage` instance was dropped rather
  than handwriting a `FromJSON Cost`. EP-5 (or whichever plan first
  needs to deserialise a `Cost`) revisits.
- `Baikai.Cost.Pricing.compute` previously folded cache-read pricing
  through a `Maybe` rate; with the new `Usage`, `cacheReadTokens` and
  `cacheWriteTokens` are unconditional `Natural`s and `PricingRate`
  gained a `cacheWritePerMillion :: Maybe Rational` field. Existing
  Claude rates default to 25% of input price for cache writes (per
  Anthropic's published table); OpenAI rates leave it `Nothing` because
  Chat Completions does not surface cache-write billing today.


## Decision Log

- Decision: `Response` keeps its existing top-level shape (`model`, `provider`,
  `latencyMs`, `usage`, `cost`) and gains a `content :: Vector AssistantContent`
  in place of `content :: Text`, plus a `stopReason :: StopReason` field. The
  `Provider.runRequest` signature is unchanged.
  Rationale: Keeping `Response` lets the existing `Provider` typeclass survive
  the data-model overhaul. EP-2 may later consolidate `Response` into a single
  `AssistantMessage` record (matching pi-mono), but EP-1 deliberately does not
  do that refactor: bundling it would conflate two independent changes
  (typed content vs. dispatch shape) and make rollback harder.
  Date: 2026-05-14

- Decision: `Usage.cost` is always populated (no longer wrapped in `Maybe`).
  Providers that have no pricing information populate it with `_Cost`, i.e.
  zero across all rates and a zero total.
  Rationale: pi-mono does the same. A `Maybe Cost` field forces every caller
  reading cost to handle the `Nothing` case even when they know the model has
  pricing data (e.g. the trace bridge currently unwraps it via
  `fmap usdAsScientific`). A zero-valued `Cost` is the truthful signal for
  CLI providers and for models absent from the pricing table. The
  per-provider semantics are preserved by `Cost.usd = 0` rather than `Nothing`.
  Date: 2026-05-14

- Decision: Tool calls and the tool-result message role are introduced now,
  even though no provider exercises them until EP-4 lands.
  Rationale: Introducing the types now means EP-3's streaming event protocol
  can reference `ToolCall` and the `ToolResult` message role from day one, and
  callers building their own provider can implement tool support against
  baikai's API without waiting for EP-4. EP-4 only adds the encoding/decoding
  logic in the existing providers and the smoke test. The masterplan's
  Decomposition Strategy section spells this out.
  Date: 2026-05-14

- Decision: Per-constructor content fields on `Message` are named
  distinctly (`userContent`, `assistantContent`, `toolResultContent`),
  not all `content`.
  Rationale: GHC rejects a single data declaration whose constructors
  give the same field name different types — even with
  `DuplicateRecordFields`. The sum has three constructors carrying three
  different content types (`Vector UserContent`, `Vector AssistantContent`,
  `Vector ToolResultContent`), so a shared `content` field is impossible.
  Renaming is a small ergonomic cost paid once; the alternative (wrapping
  each constructor in its own data type) would force every pattern match
  to bracket through an extra layer. The masterplan's Integration Points
  sketch shows a shared `content`; this plan diverges from that sketch.
  Date: 2026-05-14

- Decision: `Baikai.Response.message` is a `Message`, not a typed
  `AssistantTurn` newtype or pattern synonym. A `flattenAssistantBlocks
  :: Response -> Vector AssistantContent` accessor pattern-matches and
  falls back to empty when the message constructor is not
  `AssistantMessage`; the test for "providers never construct another
  constructor" is a property of the provider code, not a type-level
  guarantee.
  Rationale: Wrapping in a newtype churns every construction site to
  build through `AssistantTurn (AssistantMessage {..})` without buying
  anything that downstream code actually uses. A pattern synonym hides
  the underlying constructor and complicates JSON derivation. The
  accessor approach matches the existing partial-field idiom already
  used by `Baikai.Trace.Event` and keeps the type surface flat. EP-2
  may revisit when collapsing `Response` into a single `AssistantMessage`
  envelope.
  Date: 2026-05-14

- Decision: `FromJSON` is dropped from `Usage` and `Message`. Only
  `ToJSON` is derived. `CallLogEntry` keeps both because it is the only
  type the test suite round-trips.
  Rationale: No call site in the workspace deserialises a `Usage` or
  `Message`. Re-introducing `FromJSON Usage` would force a `FromJSON Cost`
  that consistently round-trips with the hand-rolled `ToJSON Cost`
  (which emits `Scientific`, not `Rational`); writing that pair correctly
  is non-trivial busywork for a milestone whose theme is data-shape
  changes. A later plan (likely EP-5 or EP-6, when the generated catalog
  JSON enters the picture) can add the missing instances.
  Date: 2026-05-14

- Decision: Image content is restricted to base64 inline data with an explicit
  `mimeType`, not file paths or URLs.
  Rationale: Anthropic's SDK accepts both inline base64 and URL references, but
  OpenAI's Chat Completions accept inline only. Restricting to base64 means
  callers do the (small, reversible) work of base64-encoding once, and every
  provider can consume the same shape without a URL-fetch path that varies in
  failure modes. A future EP can add a URL variant if a real consumer needs it.
  Date: 2026-05-14


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`baikai` is a Haskell library at `/Users/shinzui/Keikaku/bokuno/baikai`
providing a unified provider abstraction for LLM APIs. The repository is a
cabal multi-package workspace listed in `cabal.project`:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-smoke
  baikai-trace-otel
  (plus three vendored upstream packages)
```

The `baikai` library package exposes the unified types and the `Provider`
typeclass. The `baikai-claude` and `baikai-openai` packages each contain two
provider implementations: an `*.Api` module that wraps the corresponding
Mercury Haskell SDK (`claude`, `openai`), and a `*.Cli` module that wraps the
vendor's CLI binary (`claude -p`, `codex exec`). The `baikai-smoke` package is
a test-only target that exercises the four providers against real services
when `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` are set. The `baikai-trace-otel`
package adapts baikai's trace sink to OpenTelemetry spans.

The current `baikai` data model lives in five modules:

- `baikai/src/Baikai/Model.hs` — `newtype Model = Model { unModel :: Text }`.
- `baikai/src/Baikai/Message.hs` — `data Role = User | Assistant | System` and
  `data Message = Message { role :: Role, content :: Text }`. Three helpers
  `user`, `assistant`, `system :: Text -> Message`.
- `baikai/src/Baikai/Request.hs` — `data Request { model, messages, maxTokens,
  temperature, systemPrompt }`. `_Request` is a default value.
- `baikai/src/Baikai/Response.hs` — `data Response { content :: Text, model,
  usage :: Maybe Usage, cost :: Maybe Cost, provider :: Text, latencyMs :: Integer }`.
- `baikai/src/Baikai/Usage.hs` — `data Usage { inputTokens, outputTokens,
  cachedInputTokens :: Maybe Natural, reasoningTokens :: Maybe Natural }`. Aeson
  options are `camelTo2 '_'`.

The cost types live in `baikai/src/Baikai/Cost.hs`:

```haskell
data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational
  , outputUsd :: !Rational
  , cachedInputUsd :: !Rational
  }

data Cost = Cost
  { usd :: !Rational
  , breakdown :: !CostBreakdown
  }
```

The pricing computation lives in `baikai/src/Baikai/Cost/Pricing.hs` and is
keyed by a `Map Text PricingRate`. Each provider holds its own `pricing` field
of that type and calls `Pricing.attachCost` on the response.

The provider typeclass lives in `baikai/src/Baikai/Provider.hs`:

```haskell
class Provider p where
  providerName :: p -> Text
  runRequest :: MonadIO m => p -> Request -> m Response

data SomeProvider = forall p. Provider p => SomeProvider p
runSome :: MonadIO m => SomeProvider -> Request -> m Response
```

The trace bridge `Baikai.Trace.withTrace` (in `baikai/src/Baikai/Trace.hs`)
wraps any `Provider`'s `runRequest` and emits trace events through a streamly
`Fold IO TraceEvent ()` sink.

The upstream Claude Haskell SDK is vendored at
`/Users/shinzui/Keikaku/hub/haskell/claude-project/claude`. The relevant types
for this plan are in `claude/src/Claude/V1/Messages.hs`:

```haskell
data ContentBlock
  = ContentBlock_Text Text
  | ContentBlock_Image { source :: ImageSource }
  | ContentBlock_ToolUse { ... }
  | ContentBlock_ToolResult { ... }
  | ContentBlock_Thinking { thinking :: Text, signature :: Text }
  | ContentBlock_RedactedThinking { data_ :: Text }
  | ...
```

(There are several more variants — search-result blocks, code-execution
blocks, etc. EP-1 maps only the four kinds the masterplan declares in scope:
text, thinking, tool-use, image.)

The upstream OpenAI SDK is vendored at
`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai`. The Chat Completions
types in `openai/src/OpenAI/V1/Chat/Completions.hs` carry tool calls under
`Message.tool_calls :: Maybe (Vector ToolCall)` rather than as inline content
blocks. The image input shape uses `Content` variants with `Image_URL` carrying
a URL string (and base64 data URIs are accepted).

The cost log lives in `baikai/src/Baikai/Cost/Log.hs`:

```haskell
data CallLogEntry = CallLogEntry
  { timestamp :: !UTCTime
  , provider, model :: !Text
  , inputTokens, outputTokens :: !(Maybe Natural)
  , cachedInputTokens, reasoningTokens :: !(Maybe Natural)
  , usd :: !(Maybe Scientific)
  , latencyMs :: !Integer
  , promptSummary :: !Text
  }
```

This plan changes the shapes of `Usage` and `Response` but does not change the
JSON serialization of `CallLogEntry` directly — instead, the trace bridge and
the call log adapter (`Baikai.Cost.Log.runRequestWithLog`) are updated to
project the new `Usage` shape into the existing entry fields. `cachedInputTokens`
maps to the new `cacheReadTokens`. `usd` becomes a `Maybe Scientific` derived
from `_Cost.usd > 0 ? Just (usdAsScientific cost) : Nothing` so the JSONL stays
compact.


## Plan of Work

### Milestone 1: introduce typed content blocks and the new `Usage`

Add two new modules and replace `Baikai.Usage`.

**New file:** `baikai/src/Baikai/Content.hs`. Defines the typed content blocks
and the wrapper sums used by each role. Exports:

```haskell
data TextContent = TextContent { text :: !Text }
data ThinkingContent = ThinkingContent
  { thinking :: !Text
  , signature :: !(Maybe Text)   -- opaque continuation token from the provider
  , redacted :: !Bool             -- True when the provider hid the content
  }
data ToolCall = ToolCall
  { id_ :: !Text
  , name :: !Text
  , arguments :: !Aeson.Value     -- JSON object
  }
data ImageContent = ImageContent
  { imageData :: !ByteString      -- raw bytes (callers base64-encode at the boundary)
  , mimeType :: !Text             -- "image/png", "image/jpeg", ...
  }

data UserContent
  = UserText !TextContent
  | UserImage !ImageContent

data AssistantContent
  = AssistantText !TextContent
  | AssistantThinking !ThinkingContent
  | AssistantToolCall !ToolCall

data ToolResultContent
  = ToolResultText !TextContent
  | ToolResultImage !ImageContent
```

All records derive `Eq`, `Show`, `Generic`. Aeson instances are derived with
`camelTo2 '_'`. The `id_` and `imageData` fields are named with a trailing
underscore to dodge clashes with the `Prelude` `id` and the upstream `data`
keyword; the `aeson` field-label modifier strips the trailing underscore so
the JSON shape stays `{"id": "...", "data": "..."}`.

**New file:** `baikai/src/Baikai/StopReason.hs`:

```haskell
data StopReason
  = Stop
  | Length
  | ToolUse
  | ErrorReason
  | Aborted
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
```

Aeson encoding uses `defaultOptions { constructorTagModifier = camelTo2 '_' }`
so the wire form is `"stop" | "length" | "tool_use" | "error" | "aborted"`.

**Modified file:** `baikai/src/Baikai/Usage.hs`. Replace the existing
definition with:

```haskell
data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cacheReadTokens :: !Natural
  , cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural)
  , totalTokens :: !Natural
  , cost :: !Cost                  -- always populated, zero if unknown
  }

_Usage :: Usage
_Usage = Usage 0 0 0 0 Nothing 0 _Cost
```

Aeson options stay `camelTo2 '_'`. The `cost` field is the existing
`Baikai.Cost.Cost` record. Move `Cost` and `CostBreakdown` to a new module
`Baikai.Cost.Types` (or keep them in `Baikai.Cost` — EP-1's implementation
decides) so `Baikai.Usage` can import them without a cycle. The current
`Baikai.Usage` does not import `Baikai.Cost`; adding the import here forces
a small restructure. If `Baikai.Cost` already imports nothing from `Usage`,
the simplest move is to add `import Baikai.Cost (Cost (..), _Cost)`.

**Modified file:** `baikai/src/Baikai/Cost.hs`. The `Cost` and `CostBreakdown`
types stay as-is. Add a `_Cost :: Cost` smart default (already present) and
extend `CostBreakdown` if needed to track cache-write costs separately. The
current shape has `inputUsd`, `outputUsd`, `cachedInputUsd`. Add a fourth
field `cachedWriteUsd :: !Rational` and update `_CostBreakdown` to set it to
zero. Update the `ToJSON` instance to emit `"cached_write_usd"`.

**Modified file:** `baikai/baikai.cabal`. Add the two new modules
(`Baikai.Content`, `Baikai.StopReason`) to `exposed-modules`. Confirm
`baikai` already builds with `aeson`, `bytestring`, `containers`, `text`,
`time`, `vector` — all required; no new dependency.

**Acceptance.** Run `cabal build baikai` from
`/Users/shinzui/Keikaku/bokuno/baikai`. Build is green. Run
`cabal repl baikai` and evaluate:

```haskell
ghci> import Baikai.Content
ghci> import Baikai.Usage
ghci> _Usage
Usage {inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0, reasoningTokens = Nothing, totalTokens = 0, cost = Cost {usd = 0 % 1, breakdown = ...}}
```

### Milestone 2: replace `Message` and `Response`

**Modified file:** `baikai/src/Baikai/Message.hs`. Replace the existing
`Role` / `Message` definitions with:

```haskell
import Baikai.Content
import Baikai.StopReason
import Baikai.Usage

data Message
  = UserMessage
      { content :: !(Vector UserContent)
      , timestamp :: !UTCTime
      }
  | AssistantMessage
      { content :: !(Vector AssistantContent)
      , usage :: !Usage
      , stopReason :: !StopReason
      , errorMessage :: !(Maybe Text)
      , timestamp :: !UTCTime
      }
  | ToolResultMessage
      { toolCallId :: !Text
      , toolName :: !Text
      , content :: !(Vector ToolResultContent)
      , isError :: !Bool
      , timestamp :: !UTCTime
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- Smart constructors
user :: Text -> Message
user t = UserMessage
  { content = V.singleton (UserText (TextContent t))
  , timestamp = unsafePerformIO getCurrentTime  -- documented hazard, see below
  }

assistant :: Text -> Message
assistant t = AssistantMessage
  { content = V.singleton (AssistantText (TextContent t))
  , usage = _Usage
  , stopReason = Stop
  , errorMessage = Nothing
  , timestamp = unsafePerformIO getCurrentTime
  }
```

The `unsafePerformIO getCurrentTime` for the smart constructors is documented
as a convenience for tests and one-shot scripts; production callers should
build the record explicitly and set `timestamp` themselves. Add a
`{-# NOINLINE user #-}` and `{-# NOINLINE assistant #-}` pragma so the call
sites do not share a timestamp. An alternative — return `IO Message` from the
helpers — is rejected because it forces every test in the repo to use `do`
notation; EP-1's Decision Log records this.

The `system` helper from the current `Message.hs` is removed: system prompts
live on the request `Context.systemPrompt` field, not in the messages vector.
A migration note is added to the public `Baikai` module's haddock.

**Modified file:** `baikai/src/Baikai/Response.hs`. The new shape:

```haskell
data Response = Response
  { message :: !AssistantMessage     -- the assistant turn produced by the model
  , api :: !Text                     -- e.g. "anthropic-messages" (free text for now; EP-2 makes this an `Api` tag)
  , provider :: !Text                -- e.g. "anthropic.claude.api"
  , model :: !Text                   -- echoed back from the server
  , responseId :: !(Maybe Text)
  , latencyMs :: !Integer
  }
```

`Response.message` is a `Message` constrained to the `AssistantMessage`
constructor at the type level via a `newtype AssistantTurn = AssistantTurn
Message` or by exposing a pattern synonym; EP-1's implementation chooses one
and records the rationale. The simplest move is to expose an
`assistantTurn :: Response -> AssistantMessage` accessor that pattern-matches
and partial-throws if the underlying `Message` is the wrong constructor —
acceptable because the provider construction site always uses the
`AssistantMessage` constructor.

`_Response :: Response` builds a default with zero usage, `Stop` stop reason,
and empty content.

**Modified file:** `baikai/src/Baikai/Request.hs`. The new shape:

```haskell
data Request = Request
  { model :: !Model
  , messages :: !(Vector Message)
  , maxTokens :: !Natural
  , temperature :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  }
```

The `messages` vector now carries `Message` (the new ADT) so it can hold
`UserMessage`, `AssistantMessage`, and `ToolResultMessage` constructors.
`AssistantMessage` in the request is the model's previous turn being echoed
back; `ToolResultMessage` is a caller-provided tool output for the current
turn. EP-1 does not yet support tools at the provider mapping layer
(that lands in EP-4), but the request shape can already carry them so EP-4
does not need to revise the shape.

**Modified file:** `baikai/src/Baikai/Prelude.hs` and `baikai/src/Baikai.hs`.
Re-export the new modules and types. Remove the old `Role` re-export. Add
re-exports for `TextContent`, `ThinkingContent`, `ToolCall`, `ImageContent`,
`UserContent`, `AssistantContent`, `ToolResultContent`, `StopReason`, and
the renamed helpers.

**Acceptance.** `cabal build all` is green. The two changed modules
`Baikai.Message` and `Baikai.Response` survive `cabal repl baikai`:

```haskell
ghci> import Baikai
ghci> let m = user "hello"
ghci> m
UserMessage { content = [UserText (TextContent { text = "hello" })], timestamp = ... }
```

Tests built against the old shapes will fail to compile at this milestone —
that is expected; Milestone 5 migrates them.

### Milestone 3: migrate the API providers

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Update
`mapRequest` to translate the new `Message` ADT into Anthropic's
`Messages.Message` shape:

- `UserMessage { content }` → flatten each `UserContent` into a Claude
  `ContentBlock_Text` or `ContentBlock_Image` and emit a `Messages.Message`
  with `role = Messages.User`.
- `AssistantMessage { content }` → flatten each `AssistantContent` into a
  Claude content block. `AssistantText` → `ContentBlock_Text`, `AssistantThinking`
  → `ContentBlock_Thinking { thinking, signature = fromMaybe "" signature }`,
  `AssistantToolCall { id_, name, arguments }` → `ContentBlock_ToolUse { id,
  name, input = arguments }`. Emit with `role = Messages.Assistant`.
- `ToolResultMessage { toolCallId, content, isError }` → a single
  `Messages.Message` with `role = Messages.User` whose content is a single
  `ContentBlock_ToolResult { tool_use_id = toolCallId, content = ..., is_error
  = Just isError }`.

Update `mapResponse` to translate Claude's `MessageResponse` into the new
`Response`:

- `resp.content :: Vector ContentBlock` → map each block into the matching
  `AssistantContent`. Text → `AssistantText`, Thinking → `AssistantThinking`,
  ToolUse → `AssistantToolCall`. Other block kinds (search results, code
  execution, image generation) are dropped with a `Surprises & Discoveries`
  note if encountered.
- `resp.usage :: Messages.Usage` → the new `Usage`. Map
  `input_tokens` → `inputTokens`, `output_tokens` → `outputTokens`,
  `cache_read_input_tokens` → `cacheReadTokens` (default 0 when `Nothing`),
  `cache_creation_input_tokens` → `cacheWriteTokens` (default 0 when
  `Nothing`), `reasoningTokens = Nothing` (Anthropic does not surface this
  directly). `totalTokens = inputTokens + outputTokens + cacheReadTokens +
  cacheWriteTokens`. `cost = _Cost` initially (filled by `Pricing.attachCost`
  later in the pipeline).
- `resp.stop_reason :: Maybe Messages.StopReason` → `StopReason` via a small
  mapping table (`Just End_Turn` → `Stop`, `Just Max_Tokens` → `Length`,
  `Just Tool_Use` → `ToolUse`, otherwise `Stop`).

**Modified file:** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. Update
`mapRequest` to translate the new `Message` ADT into OpenAI Chat Completions
shapes (`Chat.User`, `Chat.Assistant`, `Chat.Tool`):

- `UserMessage { content }` → `Chat.User { content = vector of Chat.Text /
  Chat.Image_URL with base64 data URI }`.
- `AssistantMessage { content }` → `Chat.Assistant { assistant_content,
  tool_calls }`. `AssistantText` and `AssistantThinking` flatten into the
  content text (thinking is wrapped in `<thinking>...</thinking>` delimiters
  for OpenAI-compatible providers that don't natively understand the field;
  EP-5 makes this configurable). `AssistantToolCall` blocks are pulled into
  `tool_calls`.
- `ToolResultMessage { toolCallId, content, isError }` → `Chat.Tool
  { tool_call_id = toolCallId, content = ... }`. `isError` is currently
  ignored by OpenAI; record a Surprises entry if a provider behaves
  differently.

Update `mapResponse` to translate Chat completions into the new `Response`:

- `obj.choices[0].message` → an `AssistantMessage` with content blocks.
  Plain text → one `AssistantText`. Tool calls → one `AssistantToolCall` per
  `tool_call` entry, populated from `function.name` and `function.arguments`
  (the latter parsed as JSON).
- `obj.usage` → the new `Usage`. `prompt_tokens` → `inputTokens`,
  `completion_tokens` → `outputTokens`,
  `prompt_tokens_details.cached_tokens` → `cacheReadTokens` (default 0),
  OpenAI does not report cache-write tokens — `cacheWriteTokens = 0`.
  `completion_tokens_details.reasoning_tokens` → `reasoningTokens`.
- `obj.choices[0].finish_reason :: Maybe Text` → `StopReason` via mapping:
  `Just "stop"` → `Stop`, `Just "length"` → `Length`, `Just "tool_calls"` →
  `ToolUse`, otherwise `Stop`.

**Modified files:** `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. CLI providers wrap their
extracted text in a single `AssistantText` block:

```haskell
mapCliResponse :: UTCTime -> UTCTime -> Text -> Response
mapCliResponse start end body = Response
  { message = AssistantMessage
      { content = V.singleton (AssistantText (TextContent body))
      , usage = _Usage
      , stopReason = Stop
      , errorMessage = Nothing
      , timestamp = end
      }
  , api = "claude-p-cli"   -- or "codex-exec-cli"
  , provider = "anthropic.claude.cli"
  , model = "..."
  , responseId = Nothing
  , latencyMs = millisBetween start end
  }
```

When the CLI reports an error (e.g. claude's `is_error: true` in the typed
event array), `stopReason = ErrorReason` and `errorMessage = Just message`.

**Acceptance.** `cabal build all` is green. The smoke test from EP-2 (the
first masterplan) still passes for both API providers — i.e., when run with
real API keys, the new mapping returns a `Response` whose content has at
least one `AssistantText` block and whose usage has nonzero input/output
tokens.

### Milestone 4: migrate cost, trace, and call log

**Modified file:** `baikai/src/Baikai/Cost/Pricing.hs`. The `compute` and
`attachCost` functions now operate on the new `Usage`:

```haskell
compute :: Map Text PricingRate -> Model -> Usage -> Cost
compute rates m u = case Map.lookup (unModel m) rates of
  Nothing -> _Cost
  Just rate -> Cost
    { usd = inputUsd + outputUsd + cachedInputUsd + cachedWriteUsd
    , breakdown = CostBreakdown { inputUsd, outputUsd, cachedInputUsd, cachedWriteUsd }
    }
    where
      inputUsd       = (fromIntegral (inputTokens u) * inputRate rate) / 1_000_000
      outputUsd      = (fromIntegral (outputTokens u) * outputRate rate) / 1_000_000
      cachedInputUsd = (fromIntegral (cacheReadTokens u) * cacheReadRate rate) / 1_000_000
      cachedWriteUsd = (fromIntegral (cacheWriteTokens u) * cacheWriteRate rate) / 1_000_000

attachCost :: Map Text PricingRate -> Response -> Response
attachCost rates r = r { message = (message r) { usage = (usage (message r)) { cost = computed } } }
  where computed = compute rates (Model (model r)) (usage (message r))
```

The previous return type `Maybe Cost` is replaced by always returning a
`Cost` (zero if the model is unknown). `PricingRate` gains a `cacheWriteRate`
field; existing entries default the new rate to 0. EP-2 later folds the
pricing table into `Model.cost`, removing the `Map` entirely.

**Modified file:** `baikai/src/Baikai/Trace.hs`. The bridge unwraps the
`Response.message :: AssistantMessage` to project usage and cost into the
trace events:

```haskell
let u = usage (message resp)
    isCostMeaningful = usd (cost u) > 0
writeChan chan $ Just CallFinished
  { ...
  , inputTokens = Just (inputTokens u)
  , outputTokens = Just (outputTokens u)
  , usd = if isCostMeaningful then Just (usdAsScientific (cost u)) else Nothing
  }
```

The `summarizePrompt` helper now walks the `messages` vector looking for the
last `UserMessage`, then concatenates its `UserText` content into a 200-
character preview.

**Modified file:** `baikai/src/Baikai/Cost/Log.hs`. `runRequestWithLog`
projects the new `Usage` into the existing `CallLogEntry` shape:

```haskell
let u = usage (message resp)
    entry = CallLogEntry
      { ...
      , inputTokens = Just (inputTokens u)
      , outputTokens = Just (outputTokens u)
      , cachedInputTokens = if cacheReadTokens u > 0 then Just (cacheReadTokens u) else Nothing
      , reasoningTokens = reasoningTokens u
      , usd = if usd (cost u) > 0 then Just (usdAsScientific (cost u)) else Nothing
      , latencyMs = latencyMs resp
      , promptSummary = summarizePrompt req
      }
```

`CallLogEntry`'s JSON shape is unchanged — only the field-projection logic
moves. The masterplan's Integration Points section notes this stability is
intentional.

**Acceptance.** `cabal build all` is green. The unit-level cost specs in
`baikai/test/CostSpec.hs` are updated to use the new `Usage` constructors;
they assert that `compute` returns the same dollar amounts for the same
input as before (cache-read tokens contribute via `cacheReadRate`, which
equals the old `cachedInputRate`).

### Milestone 5: migrate every test target

**Modified files:**

- `baikai/test/Main.hs`, `CostSpec.hs`, `TraceSpec.hs`: replace
  `Message {role = User, content = "..."}` with `user "..."`; replace
  `Response {content = "...", ...}` with `_Response { message = ... }`.
  Add cost-spec cases that exercise non-zero `cacheReadTokens` and
  `cacheWriteTokens`.
- `baikai-smoke/test/Smoke.hs`: replace `(resp ^. #content)` reads with a
  helper that flattens the assistant content blocks into a single text
  string (`flattenAssistantText :: Response -> Text`). Assert that the
  flattened text is non-empty and that `length (content (message resp)) >= 1`.
- `baikai-trace-otel/test/Main.hs`: the in-memory exporter test continues
  to pass; only the `assertSpanAttributes` helper changes to read tokens
  from `usage (message resp)`.
- New file `baikai-smoke/test/ContentBlocksSmoke.hs` (or extend
  `Smoke.hs`): send a user message containing one `UserImage` against
  Anthropic Claude and assert the response succeeds with at least one
  `AssistantText` block. Skip the test when `ANTHROPIC_API_KEY` is not set
  or when the test image cannot be located. Use a small (≤ 50KB) PNG
  committed under `baikai-smoke/data/dot.png`.

**Acceptance.** `cabal test all` is green:

```text
baikai-test                                     Total tests: 15+, passed
baikai-trace-otel-test                          Total tests: 2, passed
baikai-smoke (skipped without env vars)         Total tests: 1, passed
```

With `ANTHROPIC_API_KEY` set, the new content-blocks smoke test passes
end-to-end against the real API.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/baikai`. The Nix
devshell is the assumed environment:

```bash
nix develop      # or direnv allow if direnv is enabled
```

Per milestone:

```bash
# Milestone 1: types compile in isolation
cabal build baikai
cabal repl baikai --repl-no-load <<'EOF'
:l Baikai.Content
:l Baikai.Usage
_Usage
EOF

# Milestone 2: data shapes propagate; vendor packages may not yet build
cabal build baikai
# (baikai-claude / baikai-openai will fail until Milestone 3)

# Milestone 3: full library build
cabal build all

# Milestone 4: cost + trace propagate
cabal build all
cabal test baikai

# Milestone 5: full test pass
cabal test all
# With keys present:
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... cabal test baikai-smoke
```

Expected `cabal test all` summary lines (paraphrased; counts may shift as
new content-block specs land):

```text
All N tests passed (X.XXs)
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green.
- `cabal test all` is green with no API keys set (smoke tests skip).
- With `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` set,
  `cabal test baikai-smoke` runs the live API smoke tests and reports
  success. The Anthropic content-blocks smoke test sends an image and
  receives a non-empty `AssistantText` block back.
- `cabal repl baikai` can construct and pattern-match values of every
  new type (`Message` constructors, `AssistantContent` variants, `StopReason`,
  `Usage`).
- The `baikai/test/CostSpec.hs` suite includes at least one case that
  populates `cacheReadTokens` and at least one that populates
  `cacheWriteTokens`, and asserts the resulting `Cost` is non-zero for both.

The plan is also accepted only when the existing `Provider` typeclass and
`runRequest` shape are unchanged: a `cabal repl baikai` evaluation of
`:t runRequest` still shows
`runRequest :: (Provider p, MonadIO m) => p -> Request -> m Response`. EP-2
is the plan that changes this.


## Idempotence and Recovery

Every step is additive at the type level; rolling back means reverting the
relevant commits and rebuilding. The smoke tests are idempotent — they
make API calls but do not mutate any provider-side state — so they can be
re-run after a partial change.

If a vendor SDK shape proves incompatible (e.g. a thinking-block field is
not exported from the upstream module), record the discovery in the
`Surprises & Discoveries` section and adjust the mapping. The map-and-drop
approach for unknown block kinds (Milestone 3) means an unknown variant
does not break the build; it just gets dropped from the response.

If the `unsafePerformIO getCurrentTime` smart constructors prove
controversial during review, the fallback is to either (a) accept an
explicit `timestamp :: UTCTime` argument in the helpers and require
callers to thread `getCurrentTime` themselves, or (b) return
`IO Message` from the helpers. The choice is documented in the
Decision Log if reached.


## Interfaces and Dependencies

**External dependencies.** No new Hackage / vendored dependencies. The
plan uses only `aeson`, `bytestring`, `containers`, `text`, `time`,
`vector`, `scientific` — all already in `baikai.cabal`.

**Module surface at end of plan.** From `Baikai`:

```haskell
data Message = UserMessage {..} | AssistantMessage {..} | ToolResultMessage {..}
data TextContent = TextContent { text :: !Text }
data ThinkingContent = ThinkingContent { thinking :: !Text, signature :: !(Maybe Text), redacted :: !Bool }
data ToolCall = ToolCall { id_ :: !Text, name :: !Text, arguments :: !Aeson.Value }
data ImageContent = ImageContent { imageData :: !ByteString, mimeType :: !Text }
data UserContent = UserText !TextContent | UserImage !ImageContent
data AssistantContent = AssistantText !TextContent | AssistantThinking !ThinkingContent | AssistantToolCall !ToolCall
data ToolResultContent = ToolResultText !TextContent | ToolResultImage !ImageContent
data StopReason = Stop | Length | ToolUse | ErrorReason | Aborted
data Usage = Usage { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens :: !Natural, reasoningTokens :: !(Maybe Natural), cost :: !Cost }
data Cost = Cost { usd :: !Rational, breakdown :: !CostBreakdown }
data CostBreakdown = CostBreakdown { inputUsd, outputUsd, cachedInputUsd, cachedWriteUsd :: !Rational }
data Response = Response { message :: !AssistantMessage, api, provider, model :: !Text, responseId :: !(Maybe Text), latencyMs :: !Integer }
data Request = Request { model :: !Model, messages :: !(Vector Message), maxTokens :: !Natural, temperature :: !(Maybe Double), systemPrompt :: !(Maybe Text) }

user, assistant :: Text -> Message       -- convenience constructors
_Response :: Response                     -- default value
_Request :: Request
_Usage :: Usage
_Cost :: Cost
```

The `Provider` typeclass and `runRequest` shape are unchanged. EP-2
(`docs/plans/8-api-tag-model-record-and-provider-registry.md`) consumes
these types and replaces the typeclass with a registry. EP-3 builds the
streaming event protocol on top of `AssistantContent` and `StopReason`.
EP-4 adds tool support by populating `AssistantToolCall` blocks and
accepting `ToolResultMessage` in requests.

**Trace bridge contract.** `Baikai.Trace.withTrace`'s public signature is
unchanged. Its internal event projection is updated to read from
`usage (message resp)` and `cost (usage (message resp))`. EP-3 will revise
the bridge again when it switches to the streaming event protocol.
