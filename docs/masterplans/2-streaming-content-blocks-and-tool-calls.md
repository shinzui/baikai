---
id: 2
slug: streaming-content-blocks-and-tool-calls
title: "Streaming, Content Blocks, and Tool Calls"
kind: master-plan
created_at: 2026-05-14T14:57:37Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
---

# Streaming, Content Blocks, and Tool Calls

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, baikai's provider surface evolves from a single-turn, plain-text
abstraction into a streaming, typed, tool-aware one. Five user-visible capabilities
appear that did not exist before:

1. **Typed content blocks.** Assistant responses carry a sequence of typed blocks
   (`Text`, `Thinking`, `ToolCall`) instead of a single `Text`. User messages can carry
   text and images. A new `ToolResult` role lets a caller feed a tool's output back into
   the model. This unlocks reasoning models, vision, and multi-turn tool conversations
   without bolting on side channels.

2. **Streaming as the primary interface.** Providers expose `stream :: Model -> Context
   -> Options -> Stream IO AssistantMessageEvent` returning a `streamly` stream of typed
   events (`Start`, `TextDelta`, `ThinkingDelta`, `ToolCallDelta`, `Done`, `Error`).
   The existing synchronous shape becomes `complete = drain . stream`, so any caller
   that does not care about deltas gets the same single-shot ergonomics with no new
   ceremony. Errors flow through the stream as a terminal `Error` event carrying the
   partial assistant message — never thrown — so partial output is always recoverable.

3. **Provider as a registry, model as data.** The current `class Provider p` plus
   `SomeProvider` existential is replaced by a small registry of API handlers
   (`Map Api ApiProvider`) and a `Model` data record carrying everything callers need
   to know up front: the API tag, the provider name, the base URL, per-million-token
   costs, the context window, the max output token cap, and a per-API compatibility
   record. Adding a new provider becomes "fill out a `Model` record and (if its API tag
   is new) register one handler" — not "write a new typeclass instance."

4. **Tool calling.** The API providers can encode caller-supplied tool definitions and
   decode tool calls from the model. Tool calls appear as `ToolCall` content blocks in
   the assistant message; the caller dispatches them and threads `ToolResult` messages
   back into the next request. A round-trip example in `baikai-smoke` proves Claude and
   OpenAI can be used interchangeably for the same tool-using conversation.

5. **Generated model catalog.** A build-time generator produces a `Baikai.Models.Generated`
   module exposing a typed registry indexed by provider and model id. Consumers write
   `getModel @"anthropic" @"claude-sonnet-4-6"` and get a `Model` record with full
   compile-time guarantees that the model exists, populated with up-to-date costs and
   limits. The generator's input is a small set of provider catalog JSON files
   maintained in this repository; the output is a single auto-generated `.hs` module.

After the initiative someone can write:

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Streamly.Data.Stream qualified as Stream

main :: IO ()
main = do
  let model = Models.anthropic_claude_sonnet_4_6
      context = _Context
        { systemPrompt = Just "You are a helpful assistant."
        , messages = [user "What is 2 + 2?"]
        , tools = []
        }
  stream model context defaultOptions
    & Stream.fold printEvents
```

…and the equivalent streaming flow against OpenAI by swapping `Models.anthropic_*` for
`Models.openai_*`, with the same event types emitted, the same `Usage`/`Cost`
populated on the terminal `Done` event, the same trace events flowing into whichever
sink was wired in. A blocking caller writes `result <- complete model context` instead
and gets a single `AssistantMessage` with the full content block sequence.

**In scope.** Six work streams, summarised:

- Typed content blocks for user, assistant, and tool-result messages; richer `Usage`
  with separate cache-read and cache-write counters; a `StopReason` enum on the
  response.
- A new `Api` tag and `Model` data record; replacement of the `Provider` typeclass with
  a registry of API handlers keyed by `Api`.
- A streaming event protocol (`AssistantMessageEvent`) and a `streamly`-backed event
  stream produced by every API provider; CLI providers wrap their batch output in a
  one-shot stream (one `TextDelta` then `Done`).
- A `Tool` type with JSON-schema-typed parameters; tool round-tripping in API providers;
  a tool-using smoke test against Claude and OpenAI.
- Compatibility shim records (`OpenAICompletionsCompat`, `AnthropicMessagesCompat`),
  a `CacheRetention` option, and a `ThinkingLevel` option that providers map to their
  own primitives. Demonstrated by adding a second host (e.g. DeepSeek or OpenRouter)
  on the existing `openai-completions` API tag with no per-host code duplication.
- A generated `Baikai.Models.Generated` module driven by JSON catalog files checked
  into the repository, with a `cabal run baikai-gen-models` executable that produces
  the module.

**Out of scope.** Image generation as a first-class API (pi-mono's `ImagesContext`),
embeddings, audio, batch APIs, fine-tuning, OAuth providers, browser usage, OpenAI
Responses API support (we stay on Chat Completions for the OpenAI side), Vertex AI,
Bedrock, MCP, structured outputs beyond what tool-call JSON schemas already provide,
and prompt-cache-affinity headers. Each is a substantial vertical that can layer on
later without redesigning the abstraction.

**Backward compatibility.** This is a breaking rewrite. The existing
`Baikai.Request`, `Baikai.Response`, `Baikai.Message`, and `Baikai.Provider` modules
are replaced; smoke tests and example code in this repository are migrated to the new
surface as part of EP-1. baikai is pre-1.0 with no external consumers, so a clean
break is cheaper than maintaining two parallel surfaces. The decision is recorded in
the Decision Log below.

**CLI provider scope.** CLI providers (`claude -p`, `codex exec`) gain the new
content-block response shape and the new streaming interface, but each emits a single
synthetic event stream — `Start`, one `TextDelta` with the whole response, `Done`.
They do not participate in tool calling: the CLIs do not expose a way to round-trip
tool calls back from an external orchestrator, and pretending otherwise would mislead
callers. The limitation is documented on the CLI provider modules and recorded in the
Decision Log.

**Package layout.** No new cabal packages are introduced. The five existing packages
(`baikai`, `baikai-claude`, `baikai-openai`, `baikai-smoke`, `baikai-trace-otel`)
absorb the changes:

- `baikai` gains the new content-block types, the `Api`/`Model`/registry surface, the
  streaming event protocol, the `Tool` type, and the compat records. The generated
  model catalog module lives here as `Baikai.Models.Generated`.
- `baikai-claude` and `baikai-openai` each replace their provider modules with the
  streaming + content-block versions and gain a single registration call wired into
  the new `Baikai.Provider.Registry`.
- `baikai-trace-otel` adapts to consume the new terminal `Done`/`Error` events but
  keeps the `Fold IO TraceEvent ()` sink shape unchanged. EP-3's revised trace bridge
  is documented in this masterplan's Integration Points section.
- A new `baikai-gen-models` executable target lives under the `baikai` package's
  cabal file (or as a sibling `baikai-gen` package if the build closure proves
  inconvenient — EP-6 decides). The executable consumes JSON catalog files committed
  under `baikai/data/models/` and writes `baikai/src/Baikai/Models/Generated.hs`.

**Streamly.** Continues to be the streaming primitive. The new `AssistantMessageEvent`
stream is a `Streamly.Data.Stream.Stream IO AssistantMessageEvent`. The bridge from
the upstream SDKs' callback-based `createMessageStreamTyped` / `createChatCompletion-
StreamTyped` to a `Stream` reuses the `Chan (Maybe a)` + `Stream.unfoldrM` pattern
already established by `Baikai.Trace.withTrace` and `Baikai.Cost.Log`. `TraceSink`
stays a `Fold IO TraceEvent ()`. The `complete` wrapper is implemented as
`Stream.fold` over the event stream.


## Decomposition Strategy

The work decomposes into six child plans organised by functional concern. The driving
principle is the same as the first masterplan: every plan after EP-1 must end in
something a contributor can demonstrate from a `cabal repl` or a small example
program — typically by running the existing `baikai-smoke` test suite against real
provider endpoints. The new content-block and streaming work both have natural
"prove it works" moments (a smoke test that prints the deltas; a tool-using
conversation between Claude and OpenAI).

The principles applied:

- **Data model first.** EP-1 replaces the plain-`Text` content with typed content
  blocks, adds `StopReason`, and splits `Usage` into the cache-read / cache-write
  shape pi-mono uses. Every later plan consumes EP-1's types, so EP-1 is a hard
  dependency of EP-2, EP-3, and EP-4 (and a transitive ancestor of EP-5 and EP-6).
  EP-1 deliberately keeps the existing `Provider` typeclass and `runRequest`
  synchronous shape so it can land as a self-contained, demo-able milestone without
  bundling the dispatch refactor.

- **Dispatch refactor as its own plan.** EP-2 replaces the `Provider` typeclass with
  the `Api`/`Model`/registry split. This is a substantial cross-cutting refactor —
  every existing provider implementation changes shape — but it does not introduce
  new behaviour, only restructures dispatch. Keeping it separate from EP-1's data-
  model overhaul means each plan has one reason to fail.

- **Streaming after dispatch.** EP-3 adds the streaming event protocol. It needs
  EP-1's content blocks (because the deltas carry typed content) and EP-2's registry
  shape (because the per-API stream functions register through the same mechanism as
  the synchronous handler). It also rewrites the API provider implementations to
  consume the upstream SDKs' callback-based `createMessageStreamTyped` /
  `createChatCompletionStreamTyped` and emit `AssistantMessageEvent`s through a
  streamly stream. The trace bridge in `baikai/src/Baikai/Trace.hs` is reworked to
  consume terminal events from the stream rather than wrap a synchronous call.

- **Tools after streaming.** EP-4 adds `Tool`, the `ToolResult` message role, and
  tool round-tripping through the API providers. It needs EP-1 (the `ToolCall`
  content block) and EP-3 (the `toolcall_*` event variants and the streaming JSON-
  argument delivery from the upstream SDKs). The user-visible artifact is a
  tool-using smoke test that calls a `get_time` tool and asserts both Claude and
  OpenAI complete the round-trip. CLI providers explicitly do not participate.

- **Compat shims as their own plan.** EP-5 adds the per-API compatibility records,
  the `CacheRetention` option, and the `ThinkingLevel` option. It needs EP-2 (the
  `Model` record has a `compat` field) and EP-3 (cache retention is a stream
  option that the provider consumes when building the request). The user-visible
  artifact is a second host added to the existing `openai-completions` API tag
  without per-host code duplication — concretely, a DeepSeek or OpenRouter `Model`
  record in the smoke test that exercises the same provider implementation.

- **Generated model catalog last.** EP-6 ships the build-time generator. It needs
  EP-2 (the `Model` record shape it generates) and EP-5 (the compat records, which
  the catalog populates per host). It deliberately follows the dispatch/compat
  work so that the generator's output schema is stable when it is first written.
  The user-visible artifact is `cabal run baikai-gen-models` re-generating the
  module against a checked-in JSON catalog and a smoke test that imports
  `Baikai.Models.Generated` and uses a typed model from it.

Alternatives considered and rejected:

- **Fold streaming and content blocks into a single plan.** Rejected: the
  data-model overhaul (EP-1) is locally complete — every provider can map its
  existing response into the new typed blocks without changing dispatch — and
  splitting it from the streaming work lets EP-1 land while EP-3 is still being
  designed. The pi-mono codebase grew the two together because of language
  ergonomics; we have the option of doing them in sequence and it costs nothing.

- **Skip the `Api`/`Model`/registry split and keep the `Provider` typeclass.**
  Rejected: every later plan suffers because adding a streaming method and a
  tools field forces editing every existing instance, and the multi-host work in
  EP-5 has nowhere natural to put a compat record. The registry shape is the
  small structural change that unlocks the rest.

- **One plan per provider for the streaming rewrite (Claude streaming, OpenAI
  streaming).** Rejected: the work is parallel and the integration point is a
  single event-stream contract. Splitting it would produce two near-identical
  plans whose only differences are the field-mapping table and the SDK type names.

- **Defer EP-6 (generated catalog) to a follow-up initiative.** Considered, then
  rejected after the user asked for it explicitly. The generator is bounded in
  scope (one executable target, one JSON catalog, one output module) and locking
  it down inside this initiative means the catalog shape evolves alongside the
  rest of the surface rather than being retrofitted later.

- **Drop EP-5 (compat shims) entirely.** Rejected: without compat records the
  multi-host work has nowhere to live, and the existing OpenAI provider already
  has a hidden compat assumption (it hard-codes `api.openai.com`). EP-5 makes
  the assumption explicit and tested.


## Exec-Plan Registry

| #    | Title                                                              | Path                                                                          | Hard Deps        | Soft Deps  | Status      |
|------|--------------------------------------------------------------------|-------------------------------------------------------------------------------|------------------|------------|-------------|
| EP-1 | Typed content blocks, richer Usage, and StopReason                 | docs/plans/7-typed-content-blocks-richer-usage-and-stopreason.md              | None             | None       | Complete    |
| EP-2 | Api tag, Model record, and provider registry                       | docs/plans/8-api-tag-model-record-and-provider-registry.md                    | EP-1             | None       | Complete    |
| EP-3 | Streaming event protocol with streamly                             | docs/plans/9-streaming-event-protocol-with-streamly.md                        | EP-1, EP-2       | None       | Complete    |
| EP-4 | Tools and Context overhaul                                         | docs/plans/10-tools-and-context-overhaul.md                                   | EP-1, EP-3       | EP-2       | Complete    |
| EP-5 | Compat shims, cache retention, and multi-host providers            | docs/plans/11-compat-shims-cache-retention-and-multi-host-providers.md        | EP-2, EP-3       | EP-4       | Not Started |
| EP-6 | Generated model catalog                                            | docs/plans/12-generated-model-catalog.md                                      | EP-2, EP-5       | EP-4       | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their EP- prefix.


## Dependency Graph

EP-1 is the foundation. It defines the typed content-block shapes (`TextContent`,
`ThinkingContent`, `ToolCall`, `ImageContent`), the new `UserMessage` / `AssistantMessage`
/ `ToolResultMessage` constructors, the richer `Usage` (with `cacheReadTokens` and
`cacheWriteTokens` split out, plus a `cost` breakdown nested inside), and the
`StopReason` enum on the response. Every other plan consumes EP-1's types; EP-1
stands alone and can start immediately.

EP-2 replaces the `Provider` typeclass with the `Api` tag + `Model` data record +
registry trio. It hard-depends on EP-1 because the registry's `ApiProvider` value
references the content-block types EP-1 introduces (an `ApiProvider`'s synchronous
handler returns an `AssistantMessage`, which carries the new content blocks).
EP-2 also moves cost metadata out of `Baikai.Cost.Pricing`'s `Map Text PricingRate`
and into the `Model.cost` field, so the pricing computation becomes a function of
`Model` rather than a lookup against a separate table.

EP-3 adds the streaming event protocol. It hard-depends on EP-1 (events carry the
content blocks) and EP-2 (the per-API stream function is registered through the same
registry as the synchronous handler — in fact, EP-3 promotes the stream to the
primary handler and reduces the synchronous one to a `Stream.fold`-based drain).
The trace bridge in `baikai/src/Baikai/Trace.hs` is reworked to subscribe to the
event stream and emit `CallStarted` / `CallFinished` / `CallFailed` events from the
terminal `Done` / `Error` events — this is a non-trivial change to existing code
that EP-3 owns end to end.

EP-4 adds tools. It hard-depends on EP-1 (the `ToolCall` content block) and EP-3
(the `toolcall_start` / `toolcall_delta` / `toolcall_end` event variants and the
upstream SDKs' streaming JSON-argument delivery — `Delta_Input_Json_Delta` for
Claude, `tool_calls` deltas for OpenAI). It is soft-dependent on EP-2 because the
`Context` record (replacing `Request`) carries an optional `tools` field that the
registry-aware handler consumes; once EP-2 lands EP-4 has a clean home for the
field.

EP-5 adds compat shims and the `CacheRetention` / `ThinkingLevel` options. It hard-
depends on EP-2 (the `Model` record gains the `compat` field) and EP-3 (the
options are consumed when the per-API stream function builds the upstream request).
It is soft-dependent on EP-4 because tool definitions can be cached under
Anthropic's `cache_control` markers (i.e. the `cacheControlFormat` compat record
field affects tool encoding), so having EP-4 in place first makes the compat work
more meaningful — but EP-5 is implementable against EP-3 alone with tool-side
cache control deferred to an extension.

EP-6 ships the generated catalog. It hard-depends on EP-2 (the `Model` record
shape it generates) and EP-5 (the compat records the catalog populates per host).
It is soft-dependent on EP-4 because tool-bearing models in the catalog need to
advertise their max tool count, but this is a documentation-grade field rather
than a correctness one — EP-6 can land before EP-4 if scheduling demands it.

Implementable in parallel after EP-1: nothing trivially. EP-2 is the bottleneck;
all other plans wait for it. After EP-2 is done, EP-3 can start, and EP-5/EP-6
can be sketched against EP-2's `Model` shape but their implementations need
EP-3 in place. After EP-3, EP-4 and EP-5 can run in parallel because they
modify different parts of each API provider (EP-4 adds tool encoding/decoding;
EP-5 adds compat-record-driven request shaping). EP-6 must follow EP-5.

The recommended waterfall, for a single contributor implementing sequentially,
is **EP-1 → EP-2 → EP-3 → EP-4 → EP-5 → EP-6**.


## Integration Points

Several types and modules are shared across multiple child plans. EP-1 and EP-2
between them own the foundational definitions; later plans consume them and must
not redefine them.

**`Baikai.Message` (typed content blocks and the message ADT)** — defined by EP-1.
The data shape is roughly:

```haskell
data TextContent      = TextContent { text :: !Text }
data ThinkingContent  = ThinkingContent { thinking :: !Text, signature :: !(Maybe Text) }
data ToolCall         = ToolCall { id_ :: !Text, name :: !Text, arguments :: !Value }
data ImageContent     = ImageContent { data_ :: !ByteString, mimeType :: !Text }

data UserContent      = UserText TextContent | UserImage ImageContent
data AssistantContent = AssistantText TextContent | AssistantThinking ThinkingContent | AssistantToolCall ToolCall
data ToolResultContent = ToolResultText TextContent | ToolResultImage ImageContent

data Message
  = User       { content :: !(Vector UserContent), timestamp :: !UTCTime }
  | Assistant  { content :: !(Vector AssistantContent), usage :: !Usage, stopReason :: !StopReason, ... }
  | ToolResult { toolCallId :: !Text, toolName :: !Text, content :: !(Vector ToolResultContent), isError :: !Bool, ... }
```

EP-1 owns the precise shape; EP-3 fills in the streaming deltas keyed off block indices;
EP-4 produces `AssistantToolCall` blocks and accepts `ToolResult` messages in the
request `Context`. The exact field names may shift during EP-1 implementation —
the masterplan does not commit to e.g. `id_` vs `id`; that decision lives in EP-1's
Decision Log.

**`Baikai.Usage`** — defined by EP-1. The new shape splits cache-related counters:

```haskell
data Usage = Usage
  { inputTokens       :: !Natural
  , outputTokens      :: !Natural
  , cacheReadTokens   :: !Natural
  , cacheWriteTokens  :: !Natural
  , reasoningTokens   :: !(Maybe Natural)
  , totalTokens       :: !Natural
  , cost              :: !Cost
  }
```

`cost` is a `Cost` (no longer wrapped in `Maybe`) computed from the model's per-million-
token rates. CLI providers populate everything but `cost` with zero. EP-2 reworks
`Baikai.Cost.Pricing` to compute cost from `Model.cost` rather than a separate `Map`.
EP-3 fills the usage from the terminal `Message_Delta` / OpenAI usage chunk.

**`Baikai.StopReason`** — defined by EP-1. The enum is
`Stop | Length | ToolUse | ErrorReason | Aborted`. Every provider's response shape
includes one. EP-3 emits a terminal `Done { reason :: StopReason, message :: AssistantMessage }`
event with the reason, or `Error { reason :: StopReason, error :: AssistantMessage }`
where the reason is `ErrorReason` or `Aborted`.

**`Baikai.Api` (the API tag)** — defined by EP-2. Initially a closed sum of
`OpenAIChatCompletions | AnthropicMessages | OpenAICompletionsCli | AnthropicMessagesCli`
plus an open `Custom !Text` escape hatch. EP-5 may extend the closed sum (e.g.
adding a `DeepseekChat` constructor if needed), but the open escape hatch lets a
caller register a handler under any custom tag without modifying baikai itself.
The decision between closed-sum + escape hatch versus pure `Text` is itself a
sub-decision recorded in EP-2's Decision Log; this masterplan does not commit to
either.

**`Baikai.Model`** — defined by EP-2, populated by EP-6 (generated) or by hand for
custom hosts. The shape:

```haskell
data Model = Model
  { id_           :: !Text   -- e.g. "claude-sonnet-4-6"
  , name          :: !Text   -- human-readable display name
  , api           :: !Api
  , provider      :: !Text   -- e.g. "anthropic", "openai", "deepseek"
  , baseUrl       :: !Text
  , reasoning     :: !Bool
  , input         :: ![InputModality]   -- {Text, Image}
  , cost          :: !ModelCost         -- per-million-token rates
  , contextWindow :: !Natural
  , maxTokens     :: !Natural
  , headers       :: !(Map Text Text)
  , compat        :: !Compat            -- per-API compatibility record
  }
```

`Compat` is defined by EP-5 as a sum of per-API records:

```haskell
data Compat
  = CompatOpenAICompletions !OpenAICompletionsCompat
  | CompatAnthropicMessages !AnthropicMessagesCompat
  | CompatNone
```

EP-3 consumes `compat = CompatNone` until EP-5 lands. EP-6 emits typed compat
values into the generated catalog.

**`Baikai.Provider.Registry`** — defined by EP-2. Replaces the `Provider` typeclass
and `SomeProvider` existential. The shape:

```haskell
data ApiProvider = ApiProvider
  { apiTag      :: !Api
  , stream      :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  , complete    :: Model -> Context -> Options -> IO AssistantMessage
  }

registerApiProvider :: Api -> ApiProvider -> IO ()
lookupApiProvider   :: Api -> IO (Maybe ApiProvider)
streamRequest       :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
completeRequest     :: Model -> Context -> Options -> IO AssistantMessage
```

EP-2 ships the synchronous `complete` field; EP-3 makes `stream` the primary field
and derives `complete` from `Stream.fold`. EP-4 and EP-5 do not modify the
registry shape — they extend the `Options` and `Context` records consumed by the
registered handlers. The registry uses a top-level `IORef (Map Api ApiProvider)` for
mutation; providers register themselves via a `Baikai.Provider.<X>.register :: IO ()`
function called from the caller's `main`. EP-2 documents the rationale (avoids
overlapping instances, avoids ordering-dependent imports, mirrors the pi-mono
pattern).

**`Baikai.Stream.Event` (`AssistantMessageEvent`)** — defined by EP-3. The event
algebra mirrors pi-mono's `AssistantMessageEvent` but emits one event per typed
content block kind:

```haskell
data AssistantMessageEvent
  = EventStart        { partial :: !AssistantMessage }
  | TextStart         { contentIndex :: !Int }
  | TextDelta         { contentIndex :: !Int, delta :: !Text }
  | TextEnd           { contentIndex :: !Int, content :: !Text }
  | ThinkingStart     { contentIndex :: !Int }
  | ThinkingDelta     { contentIndex :: !Int, delta :: !Text }
  | ThinkingEnd       { contentIndex :: !Int, content :: !Text }
  | ToolCallStart     { contentIndex :: !Int }
  | ToolCallDelta     { contentIndex :: !Int, delta :: !Text }
  | ToolCallEnd       { contentIndex :: !Int, toolCall :: !ToolCall }
  | EventDone         { reason :: !StopReason, message :: !AssistantMessage }
  | EventError        { reason :: !StopReason, error :: !AssistantMessage }
```

The stream MUST emit exactly one terminal `EventDone` or `EventError`. EP-4 consumes
`ToolCallStart/Delta/End`; EP-5 does not modify the algebra (cache retention is an
input, not an event); EP-6 does not touch the algebra at all. The trace bridge
in `Baikai.Trace.withTrace` subscribes to the terminal event and emits the
existing `CallFinished` / `CallFailed` events derived from the terminal message.

**`Baikai.Context`** — defined by EP-2, extended by EP-4. The shape after EP-2:

```haskell
data Context = Context
  { systemPrompt :: !(Maybe Text)
  , messages     :: !(Vector Message)
  }
```

EP-4 extends it with `tools :: !(Vector Tool)`. EP-4 documents whether tools belong
on `Context` (matching pi-mono) or on `Options` (mirroring how max-tokens is
threaded). The masterplan commits to **`Context`** because tools are part of the
conversation contract — different conversations expose different tool sets — not a
per-call knob.

**`Baikai.Options`** — defined by EP-2 (initially carrying `maxTokens`, `temperature`,
`signal :: Maybe SomeAbortHandle`, `apiKey :: Maybe Text`). EP-3 adds
`cacheRetention :: Maybe CacheRetention` (the field exists but is no-op until EP-5
lands), `sessionId :: Maybe Text`, and `headers :: Map Text Text`. EP-5 wires
`cacheRetention` into the upstream request shape via the per-API compat record.
EP-4 adds `toolChoice :: Maybe ToolChoice`. EP-5 also adds
`thinking :: Maybe ThinkingLevel`.

**`Baikai.Tool`** — defined by EP-4. The shape:

```haskell
data Tool = Tool
  { name        :: !Text
  , description :: !Text
  , parameters  :: !Value   -- JSON Schema, validated at request time
  }
```

The parameters field is a `Data.Aeson.Value` rather than a higher-kinded
schema type. This matches the existing baikai approach (we already use `Value`
for upstream JSON payloads) and avoids the typebox / `aeson-schemas` dependency
choice mid-initiative. EP-4 documents this in its Decision Log.

**`Baikai.Models.Generated`** — defined by EP-6. The module exports one
`Model`-shaped value per (provider, model id) pair derived from JSON catalog files
under `baikai/data/models/*.json`. The generator is a single executable target
`baikai-gen-models`; the output module is committed to source control (it is
auto-generated but not gitignored, so users do not need to run the generator
unless they change a catalog file). EP-6 also adds a CI check that re-running the
generator produces no diff.

**`baikai/src/Baikai/Trace.hs` (the trace bridge)** — EP-1's data-model overhaul
touches it only to update field accesses (`req ^. #model` becomes
`ctx ^. #...`). EP-3 reworks it substantially: the bridge becomes a stream
combinator that subscribes to the event stream and emits `CallStarted` /
`CallFinished` / `CallFailed` to the `TraceSink` fold based on terminal events.
The `TraceSink` shape (`Fold IO TraceEvent ()`) is unchanged. EP-3 documents
the rework end-to-end; later plans do not modify the bridge.

**`baikai/test/` and `baikai-smoke/`** — the smoke tests are the
demonstration vehicle for every plan. EP-1 migrates the existing two test
modules to the new types but does not add new coverage. EP-3 adds a streaming
smoke test that asserts at least one `TextDelta` is emitted for each API
provider. EP-4 adds a tool-using smoke test that round-trips a `get_time` tool
against both Claude and OpenAI. EP-5 adds a multi-host smoke test that runs the
same conversation against OpenAI and a second host (DeepSeek or OpenRouter) on
the shared `openai-completions` API. EP-6 adds a smoke test that imports
`Baikai.Models.Generated` and uses a typed model from it. Every later plan
preserves the earlier smoke tests.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Introduce `Baikai.Content`, `Baikai.StopReason`, and the richer `Usage`
- [x] EP-1: Replace `Baikai.Message` and `Baikai.Response` with typed shapes
- [x] EP-1: Migrate API and CLI providers to produce typed content blocks
- [x] EP-1: Migrate `Baikai.Cost`, `Baikai.Cost.Log`, and `Baikai.Trace` to the new `Usage`
- [x] EP-1: Migrate every test target and add content-block smoke coverage
- [x] EP-2: Introduce `Baikai.Api` and the `Model` data record (replaces newtype)
- [x] EP-2: Introduce `Baikai.Context` and `Baikai.Options`; delete `Baikai.Request`
- [x] EP-2: Introduce `Baikai.Provider.Registry`; remove `Provider` typeclass
- [x] EP-2: Rewrite each vendor provider to expose `register :: IO ()`
- [x] EP-2: Rewrite `Baikai.Cost.Pricing`, `Baikai.Trace`, `Baikai.Cost.Log` for `Model`/`Context`
- [x] EP-2: Migrate every test target and live smoke through the registry
- [x] EP-3: Define `AssistantMessageEvent`, the streaming entry point, and `streamingComplete`
- [x] EP-3: Implement the Anthropic streaming producer via `createMessageStreamTyped`
- [x] EP-3: Implement the OpenAI streaming producer (raw stream, not typed — see EP-3 plan Decision Log)
- [x] EP-3: Wrap CLI providers in synthetic one-shot streams (via `liftCompleteToStream`)
- [x] EP-3: Rebuild `Baikai.Trace.withTrace` around the event stream
- [x] EP-3: Add streaming smoke coverage in `baikai-smoke`
- [x] EP-4: Introduce `Baikai.Tool`; extend `Context.tools`, `Options.toolChoice`
- [x] EP-4: Anthropic tool encoding/decoding wired in
- [x] EP-4: OpenAI tool encoding/decoding wired in
- [x] EP-4: Tool round-trip smoke test passes on both providers
      (live-verified against OpenAI; Anthropic verified by build
      only, no key in session — see EP-4 Outcomes & Retrospective)
- [ ] EP-5: Introduce compat records + auto-detection from `baseUrl`
- [ ] EP-5: Introduce `CacheRetention` and `ThinkingLevel`; thread through `Options`
- [ ] EP-5: Wire compat into the OpenAI provider request builder + stream transformer
- [ ] EP-5: Wire compat into the Anthropic provider request builder
- [ ] EP-5: Multi-host smoke test passes against OpenAI + DeepSeek/OpenRouter
- [ ] EP-6: Author the model catalog JSON files under `baikai/data/models/`
- [ ] EP-6: Implement `baikai-gen-models` executable and emit `Baikai.Models.Generated`
- [ ] EP-6: Add `CatalogSpec` regeneration check to `cabal test all`
- [ ] EP-6: Migrate smoke tests to generated model identifiers


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-1: GHC rejects a single data declaration whose constructors give a
  shared field name different types — `DuplicateRecordFields` only
  permits the collision *across* data declarations, not within one. The
  masterplan's Integration Points sketch of a `Message` sum with a
  shared `content` field accordingly does not compile. EP-1 chose the
  least-friction workaround (rename to `userContent`,
  `assistantContent`, `toolResultContent`); EP-3 should refer to the
  renamed fields when it documents the streaming-event payloads.
- EP-1: The plan's milestone sequencing assumed M2 (replace Message +
  Response) and M4 (migrate cost/trace/log) could be separate
  commits with a green build in between. They cannot — the moment
  `Response.usage` / `Response.cost` become nested in the embedded
  `AssistantMessage.usage.cost`, every reader of those fields stops
  compiling. M2 and M4 therefore landed as a single commit. EP-3 may
  hit the same pattern when promoting the streaming event protocol;
  plan its milestones around what keeps the library buildable.
- EP-1: `FromJSON Usage` was dropped because reusing the generic
  derivation now requires a `FromJSON Cost` that round-trips with the
  hand-rolled `ToJSON Cost` (Scientific-emitting). No call site
  exercises `FromJSON Usage` today; EP-5 or EP-6 (whichever first
  needs to deserialise a `Cost`) should re-introduce the symmetric
  instances.
- EP-2: `Baikai.Prelude` re-exports `module Control.Lens`, which
  bleeds `Context` from `Control.Lens.Internal.Context` into every
  module that imports the project Prelude. The new
  `Baikai.Context.Context` collides. Fix: `Baikai.Prelude` now imports
  `Control.Lens hiding (Context)`. EP-3 and EP-4 must remember this
  shadow when extending the Prelude or adding modules that import
  both surfaces.
- EP-2: The same compilation-coupling shape EP-1 observed (M2 and M4
  inseparable) recurred here at the dispatch boundary. The moment
  `Model` stops being a `newtype Text`, every reader of
  `Request.model`, `Response.model`, `Cost.Pricing.compute`, and the
  `Provider` typeclass fails simultaneously. EP-2 landed as a single
  end-to-end commit rather than the six narrative milestones the plan
  sketched. EP-3's promotion of `stream` to the primary
  `ApiProvider` method will almost certainly show the same pattern —
  plan its milestone narrative around what keeps the library
  compiling, not around the conceptual decomposition.
- EP-2: Tasty runs `testCase`s in parallel by default and the
  process-global registry IORef tolerates exactly zero races on the
  same `Api` tag. Every test whose behaviour depends on the
  registered handler must use a unique `Api` tag — the OTel test
  silently passed once on a lucky run, then failed deterministically
  when scheduling shifted. EP-3 and EP-4's streaming/tool stub
  providers should adopt the per-test-tag convention from the start.
- EP-3 M1: Adding the `stream` field to `ApiProvider` as a required
  field would break every existing `register` call simultaneously
  (the EP-1/EP-2 milestone-coupling pattern). The mitigation was a
  `Baikai.Stream.liftCompleteToStream` helper landed in M1: every
  vendor's `register` sets `stream = liftCompleteToStream complete`
  initially, and the library stays green while M2/M3/M4 replace
  each provider one at a time with a native producer. CLI providers
  already match the plan's "synthetic one-shot stream" shape via
  this default — M4 is mostly identity. EP-4 and EP-5 should adopt
  the same pattern (add a fresh optional field, wire a default,
  swap providers one at a time) rather than landing breaking
  registry-shape changes wholesale.
- EP-3 M1: The plan and masterplan sketches name the
  `AssistantMessageEvent.EventError` payload field `error`. That
  shadows `Prelude.error`, and with baikai's `-Wall` configuration
  every importer would emit a warning. Renamed to `errorPartial`
  in the actual algebra. EP-4 must use the renamed field when
  documenting tool-error flows.
- EP-4 M1: The masterplan's Integration Points section sketches a
  `Baikai.Tool` module that owns both the `Tool` data type and an
  `appendToolResult` helper. Implementing it that way creates an
  unavoidable module cycle because `Baikai.Context.Context.tools ::
  Vector Tool` forces `Baikai.Context` to import `Baikai.Tool`,
  while the helper itself must return a `Context`. The fix
  (`Baikai.Tool` is types-only; `appendToolResult` lives in
  `Baikai.Context`) is now reflected in EP-4's Decision Log. EP-5
  and EP-6 should keep `Baikai.Tool` types-only when adding cache-
  control / strict-mode / catalog metadata; helper functions go in
  the consuming modules.
- EP-4 M2: `Tool.ToolChoiceNone` is not a first-class Anthropic
  value. The provider realises it by suppressing both `tools` and
  `tool_choice` in the upstream request. EP-5's compat work
  should leave this lowering intact (and may need to suppress
  cache-controlled tool definitions the same way when @None@ is
  set).
- EP-4 M4: A deterministic tool-use smoke test requires *different*
  `toolChoice` values on each turn. Turn 1 forces a tool call
  (`Required`); turn 2 must not (`Nothing` or `Auto`) — otherwise
  the model is locked into another tool call and never produces a
  final answer. EP-5/EP-6 smoke tests that exercise tool calling
  should adopt the same split-options pattern.
- EP-4 M4: Natural-language assertions on tool-result text must
  not depend on the model preserving exact substrings supplied to
  the tool. `gpt-4o-mini` rewrote a supplied ISO-8601 timestamp
  into prose. The smoke now accepts any of several substring
  markers (year, time, date fragment); EP-5/EP-6 should use the
  same pattern.


## Decision Log

- Decision: Replace the existing `Request` / `Response` / `Provider` typeclass surface
  with the new content-block / `Context` / registry surface in place; do not maintain
  a parallel `Baikai.V2.*` module hierarchy or a long-lived bridge layer.
  Rationale: baikai is pre-1.0, has no external consumers, and lives in this
  repository alongside its only callers (`baikai-smoke`, the trace bridge,
  `baikai-trace-otel`). Maintaining two surfaces costs duplicated effort in every
  later plan (EP-3 through EP-6 each touch the provider surface); a parallel API
  also pollutes the autocomplete namespace for new contributors. The first
  masterplan's surface is documented in its Outcomes & Retrospective section and
  remains reachable via git history.
  Date: 2026-05-14

- Decision: CLI providers (`claude -p`, `codex exec`) participate in the new
  streaming and content-block surface by wrapping their batch output in a one-shot
  event stream — `EventStart`, one `TextDelta` carrying the entire response,
  `EventDone`. They do not participate in tool calling.
  Rationale: The CLIs do not expose a way for an external orchestrator to feed
  tool results back into an in-progress turn. Faking the round-trip by re-invoking
  the CLI with synthesised messages would lose the CLI's internal state (e.g. its
  session memory, its plan-mode toggle). Documenting "CLI providers are batch-only
  and do not support tools" is more honest than a partial implementation. EP-4
  explicitly limits its scope to the API providers; the masterplan's
  Vision & Scope and Integration Points sections call this out.
  Date: 2026-05-14

- Decision: The generated model catalog (EP-6) is in scope for this initiative
  rather than deferred.
  Rationale: User asked for it explicitly during decomposition. Bounded scope
  (one executable, one input directory, one output module). Locking the
  generator's output schema down inside this initiative means the catalog
  evolves alongside the rest of the surface and is exercised by smoke tests
  from the moment it ships. A follow-up initiative would risk drift between
  the catalog schema and the `Model` record shape EP-2 defines.
  Date: 2026-05-14

- Decision: No new cabal packages are introduced. Changes land inside the five
  existing packages (`baikai`, `baikai-claude`, `baikai-openai`, `baikai-smoke`,
  `baikai-trace-otel`). The generator (`baikai-gen-models`) ships as a new
  executable target inside `baikai.cabal`.
  Rationale: The existing package split already isolates the heavy vendor
  closures (`claude`, `openai`, `hs-opentelemetry-*`). Adding more packages for
  the same code would balloon the cabal solver's work without buying isolation.
  EP-6 will revisit if the generator's build closure proves inconvenient
  (e.g. if it needs `aeson-typescript` or other heavy dev-time deps the library
  user should not pay for); in that case EP-6 may split into `baikai-gen` as a
  sibling exe-only package.
  Date: 2026-05-14

- Decision: Streamly remains the streaming primitive. The new event stream is a
  `Streamly.Data.Stream.Stream IO AssistantMessageEvent`. The callback-to-stream
  bridge reuses the `Chan (Maybe a)` + `Stream.unfoldrM` pattern already
  established by `Baikai.Trace.withTrace` and `Baikai.Cost.Log`.
  Rationale: User explicitly named streamly as the streaming package. The
  pattern is proven in the existing codebase; introducing a second streaming
  library (e.g. `conduit`, `pipes`) would fragment the project's streaming
  vocabulary and force callers to learn two libraries. Streamly's
  `Fold` combinators already plug into `TraceSink`, so the trace bridge in EP-3
  is a natural extension rather than a rewrite.
  Date: 2026-05-14

- Decision: Tools live on `Context`, not on `Options`.
  Rationale: A tool set is part of the conversation contract — the same
  `(systemPrompt, messages, tools)` triple defines what the model can do for a
  given thread. Putting tools on `Options` would imply they vary per call within
  a thread, which is rare and harmful (forgetting to thread the tools through
  drops them silently). pi-mono makes the same choice. EP-4 documents the trade-
  off in its own Decision Log.
  Date: 2026-05-14

- Decision: Tool parameter schemas are `Data.Aeson.Value` (raw JSON Schema), not a
  higher-kinded schema type.
  Rationale: baikai already passes upstream JSON payloads as `Value` in several
  places; introducing `aeson-schemas` or hand-rolling a `TSchema`-style GADT
  midway through the initiative would distract from the structural work and
  pull in a new dependency. Callers who want a typed front-end can layer their
  preferred schema library on top and `toJSON` the result. EP-4 documents this.
  Date: 2026-05-14

- Decision: The `Api` tag is a closed sum with an open `Custom !Text` escape
  hatch, not a pure `Text`.
  Rationale: A closed sum enables exhaustiveness checking in the registry
  (`registerApiProvider` can call out a missing handler at compile time for
  known APIs), and the `Custom !Text` constructor preserves the open-world
  property so callers can register handlers for new APIs without modifying
  baikai itself. Pure `Text` would lose the exhaustiveness check; pure closed
  sum would lock callers out. EP-2's Decision Log records the implementation
  details.
  Date: 2026-05-14


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
