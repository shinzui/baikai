---
id: 8
slug: api-tag-model-record-and-provider-registry
title: "Api tag, Model record, and provider registry"
kind: exec-plan
created_at: 2026-05-14T15:04:23Z
intention: "intention_01krkfnkhfehf9zr6np86jagqg"
master_plan: "docs/masterplans/2-streaming-content-blocks-and-tool-calls.md"
---

# Api tag, Model record, and provider registry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, baikai no longer asks the caller to construct a typeclass instance
to use a provider. The caller picks a `Model` record (carrying everything baikai needs
to know up front — the API tag, the base URL, per-million-token costs, context window,
max output tokens, and a per-API compatibility record), and a single top-level
`completeRequest :: Model -> Context -> Options -> IO Response` looks up the right
handler in a registry keyed by the model's `Api` tag and dispatches.

The user-visible payoff is that adding a new provider that already speaks a known API
becomes data: a new `Model` value with `api = AnthropicMessages, baseUrl =
"https://fireworks.ai/...", cost = ..., compat = CompatAnthropicMessages defaultCompat`
re-uses the existing Anthropic Messages handler without any code change. The same
move lets a future plan add multi-host coverage (EP-5) without per-host code
duplication.

A consumer of `baikai` can see this working immediately after this plan: the existing
smoke tests in `baikai-smoke/test/Smoke.hs` are migrated from constructing
`claudeApi (ApiKeyEnv "ANTHROPIC_KEY")` and calling `runRequest` on the result, to
declaring a `Model` (hand-rolled here, generated later in EP-6), pulling an API key
from the environment in `Options.apiKey`, and calling `completeRequest model context
options`. The trace bridge (`Baikai.Trace.withTrace`) and the call log
(`Baikai.Cost.Log.runRequestWithLog`) are updated to take a `Model` + `Context` pair
instead of `p` + `Request`.

This plan does **not** introduce streaming — the registry's primary method stays
`complete`. EP-3 (`docs/plans/9-streaming-event-protocol-with-streamly.md`) makes
streaming the primary method and reduces `complete` to a draining wrapper. This plan
also does **not** introduce tools — `Context` carries `systemPrompt` and `messages`
only. EP-4 adds `tools`.


## Progress

- [x] Milestone 1: introduce `Baikai.Api` (the closed-sum-with-escape-hatch tag) and
      `Baikai.Model` (the data record replacing the `newtype Model = Model Text`).
      Pricing rate fields move into `Model.cost`. (2026-05-14)
- [x] Milestone 2: introduce `Baikai.Context` and `Baikai.Options`. `Baikai.Request`
      is deleted outright (no parallel surface or shim — baikai is pre-1.0). (2026-05-14)
- [x] Milestone 3: introduce `Baikai.Provider.Registry` with `registerApiProvider`,
      `lookupApiProvider`, `completeRequest`. The `Provider` typeclass and
      `SomeProvider` existential are removed; `Baikai.Provider` is now a thin
      re-export shim of the registry surface. (2026-05-14)
- [x] Milestone 4: rewrite each provider (`Baikai.Provider.Claude.Api`,
      `Baikai.Provider.OpenAI.Api`, and both CLI providers) to expose a
      `register :: IO ()` function. API providers consult `Options.apiKey`,
      defaulting to `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` via
      `Auth.resolveApiKey`. CLI providers also gain a `registerWith` overload
      taking a per-package config record. (2026-05-14)
- [x] Milestone 5: rewrite `Baikai.Cost.Pricing`, `Baikai.Trace`, and
      `Baikai.Cost.Log` to consume `Model` and `Context` directly. The pricing
      `Map Text PricingRate` is gone; `computeCost :: Model -> Usage -> Cost`
      and `attachCost :: Model -> Response -> Response` replace it.
      `withTrace` / `runRequestWith` take `Model -> Context -> Options`. (2026-05-14)
- [x] Milestone 6: every test target migrated. `cabal test all` is green;
      `cabal test baikai-smoke` ran live against OpenAI Chat Completions
      (`gpt-4o-mini`), the `claude` CLI, and the `codex` CLI in this session;
      Anthropic API and the image smoke skipped (no `ANTHROPIC_*` env var set
      during the run, but the code path is identical to OpenAI). (2026-05-14)


## Surprises & Discoveries

- `Baikai.Prelude` re-exports `module Control.Lens`, which brings the
  `Context` name from `Control.Lens.Internal.Context` into scope of every
  module that imports the project Prelude. With the new
  `Baikai.Context.Context` type, `Baikai.Trace` (which imports both) hit a
  GHC-87543 ambiguous-occurrence error. Fix: `Baikai.Prelude` now imports
  `Control.Lens hiding (Context)`. EP-3 and EP-4 should remember this shadow
  exists when they extend the Prelude or any module that imports both
  surfaces.
- `claude` and `openai`'s `getClientEnv` take `Text`, not `String` — the
  prior providers passed string literals via `OverloadedStrings`, so this
  was invisible until the new dispatch path wired `Text.unpack` in by
  reflex. The Decision Log captures the fix; the lesson is to grep the
  actual SDK signatures rather than mirror old code shape when threading
  values across module boundaries.
- Tasty runs `testCase`s in parallel by default, and the process-global
  registry IORef does not tolerate two tests writing the same `Api` tag.
  An initial run had the OTel failure test see the success handler. Fix:
  every test uses a unique `Custom "test-name"` tag. EP-3 and later
  plans whose stub providers register handlers should follow the same
  per-test-tag convention.
- GHC's `-Wambiguous-fields` (under `-XDuplicateRecordFields`) warns on
  record updates when multiple data declarations share the field name
  being updated, even when the expression's overall type would
  disambiguate. The `_Options {maxTokens = Just 16}` form silently
  resolved to `TraceEvent.CallStarted` until I switched to
  `_Options & #maxTokens .~ Just 16`. EP-3's streaming event protocol
  introduces more record types with shared field names — anticipate the
  same warning class and prefer the lens-based update form there.


## Decision Log

- Decision: The `Api` tag is a closed sum with an open `Custom !Text` escape hatch.
  Rationale: A closed sum lets baikai's exhaustiveness checker call out missing
  handler registrations at compile time when a new API is added internally, and
  the `Custom !Text` constructor preserves the open-world property so third-party
  callers can register handlers under any tag without modifying baikai itself. A
  pure `Text` tag would lose exhaustiveness; a pure closed sum would lock callers
  out. The masterplan's Decision Log endorses this choice.
  Date: 2026-05-14

- Decision: The registry is implemented as a top-level `IORef (Map Api ApiProvider)`
  mutated by `registerApiProvider`. Each provider package exports a
  `register :: IO ()` function; the caller calls each `register` once in `main`.
  Rationale: A static `Map` would force every provider into a single module and
  defeat the per-vendor package split. A typeclass-based registry (the existing
  `Provider`) is what we're escaping. A top-level `IORef` mirrors pi-mono's
  pattern and matches what `Baikai.Trace` already does for its event counter
  (`unsafePerformIO (newIORef 0)` in `Baikai.Trace`). The masterplan's Integration
  Points section spells out the shape.
  Date: 2026-05-14

- Decision: API key resolution moves from provider construction time to per-call
  time, via `Options.apiKey :: Maybe Text`. When `Nothing`, the registered handler
  consults an env var (`ANTHROPIC_API_KEY` for Anthropic, `OPENAI_API_KEY` for
  OpenAI, etc.) using the existing `Baikai.Auth.ApiKeySource` machinery.
  Rationale: Provider construction time made sense when a provider was a record
  containing a `ClientEnv`. With the registry, the handler is stateless — it
  builds the upstream client at call time. Resolving the key at call time means
  a caller can swap keys mid-process (useful for multi-tenant orchestration) and
  removes the asymmetry where `claudeApi` was `IO`-bound but the rest of the API
  surface was pure.
  Date: 2026-05-14

- Decision: The pricing `Map Text PricingRate` in `Baikai.Cost.Pricing` is
  removed. `Model.cost` carries the per-million-token rates directly; cost
  computation becomes `computeCost :: Model -> Usage -> Cost`.
  Rationale: The map served two purposes — central storage of known model
  pricing, and lookup by model id. The first is replaced by `Baikai.Models.Generated`
  (EP-6). The second collapses to a record field access once the
  `Model` is in hand. Removing the map removes a footgun (a missing entry
  silently returned `Nothing`) and brings the API in line with pi-mono.
  Date: 2026-05-14


## Outcomes & Retrospective

EP-2 landed: `baikai`'s dispatch surface is now data-driven. The caller
picks a `Model` record (carrying an `Api` tag, base URL, pricing, context
window, max-tokens, headers, and a `Compat` placeholder), constructs a
`Context` and an `Options`, and calls `completeRequest`. Adding a new
provider that speaks a known API is now a data change: a new `Model`
value plus the existing handler.

What ships:

- `Baikai.Api` — a closed sum (`OpenAIChatCompletions`,
  `AnthropicMessages`, `OpenAICompletionsCli`, `AnthropicMessagesCli`)
  with a `Custom !Text` escape hatch, plus `renderApi`/`parseApi` for
  wire round-trips.
- `Baikai.Model` — a data record carrying the dispatch metadata; the
  prior `newtype Model = Model Text` is retired (`unModel` remains as a
  convenience accessor over `modelId`). `ModelCost` holds the
  per-million-token rates. `Compat = CompatNone` is the placeholder
  EP-5 will extend.
- `Baikai.Context` and `Baikai.Options` — the per-call records. The
  old `Baikai.Request` module is deleted outright (pre-1.0, no parallel
  surface).
- `Baikai.Provider.Registry` — `ApiProvider { apiTag, complete }`
  values keyed by `Api` tag in a process-global `IORef (Map Api ApiProvider)`.
  `registerApiProvider`, `lookupApiProvider`, and `completeRequest` are
  the top-level surface.
- `Baikai.Provider` — now a thin re-export shim of the registry.
- `Baikai.Cost.Pricing` — `computeCost :: Model -> Usage -> Cost` and
  `attachCost :: Model -> Response -> Response`. The
  `Map Text PricingRate` is gone.
- `Baikai.Trace.withTrace` and `Baikai.Cost.Log.runRequestWithLog` —
  both now take `Model -> Context -> Options`. `withTrace` calls
  `completeRequest` directly; the trace bridge no longer needs a
  `Provider` instance argument.
- Vendor packages: each provider module exposes `register :: IO ()`
  (CLI providers additionally `registerWith :: Config -> IO ()`).
  `baikai-claude` registers `AnthropicMessages` and
  `AnthropicMessagesCli`; `baikai-openai` registers
  `OpenAIChatCompletions` and `OpenAICompletionsCli`.

What is verified end to end:

- `cabal test all` is green: 18 tests in `baikai`, 2 in
  `baikai-trace-otel`, 1 (skipping/dispatching) in `baikai-smoke`.
- `cabal test baikai-smoke` ran live against:
  - OpenAI Chat Completions (`gpt-4o-mini` via `OPENAI_API_KEY`)
  - `claude` CLI (`claude -p` with model alias `sonnet`)
  - `codex` CLI (`codex exec --json` with the CLI's built-in default)
- The Anthropic API path and the image smoke skipped because no
  `ANTHROPIC_*` env var was set; the code path is identical to OpenAI's
  and exercised by the unit tests.
- `ghci> :t completeRequest` reports
  `Model -> Context -> Options -> IO Response`.
- `ghci> :t withTrace` reports
  `MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response`.
- `Provider` typeclass and `SomeProvider` no longer appear in
  `Baikai.Provider`'s export list.

What remains for later plans:

- EP-3 will promote `stream` to the primary `ApiProvider` method and
  derive `complete` from `Stream.fold`. The synchronous shape we ship
  here is what EP-3 retains for non-streaming callers.
- EP-5 will extend `Compat` with `CompatOpenAICompletions` and
  `CompatAnthropicMessages` constructors so multi-host deployments can
  describe their wire differences. The `compat` field on `Model` is
  already in place.
- EP-6 will generate `Baikai.Models.Generated`. The `Model` record
  shape it generates is the one this plan defines; `ModelCost` and
  `InputModality` are the JSON fields the catalog will emit.

Lessons:

- Splitting the work into six narrative milestones helped the design
  thinking but did not survive contact with the GHC type checker:
  every consumer of `Model`, `Provider`, `Request`, and `Cost.Pricing`
  breaks simultaneously when the data shape changes. EP-1's
  Surprises & Discoveries called this out for the M2+M4 case; the same
  pattern held here. The library only compiled cleanly once every
  module was updated; intermediate commits would not have been buildable.
  The work landed as a single commit instead. EP-3's streaming
  protocol switch will likely show the same pattern — plan its
  milestone narrative around what keeps the library compiling.
- The process-global registry has tasty-parallel hazard: any test
  whose behaviour depends on the registered handler must use a unique
  `Api` tag. The test files for `Baikai.Trace`,
  `Baikai.Trace.Sink.OpenTelemetry`, and the test provider in
  `baikai/test/Main.hs` now follow this convention. EP-3's streaming
  tests should adopt the same pattern.


## Context and Orientation

`baikai` is a Haskell cabal multi-package workspace at
`/Users/shinzui/Keikaku/bokuno/baikai`. The relevant packages for this plan are
`baikai` (the library), `baikai-claude`, `baikai-openai`, `baikai-trace-otel`,
and the test-only `baikai-smoke`.

Read this plan after `docs/plans/7-typed-content-blocks-richer-usage-and-stopreason.md`
has been implemented. EP-1 (plan 7) introduces typed content blocks
(`AssistantContent`, `UserContent`, `ToolResultContent`), a richer `Usage` shape
(with `cacheReadTokens`, `cacheWriteTokens`, an in-place `Cost`), and a
`StopReason` enum. This plan consumes those types and restructures dispatch.

The current dispatch surface lives in:

- `baikai/src/Baikai/Provider.hs` — the `Provider` typeclass:

  ```haskell
  class Provider p where
    providerName :: p -> Text
    runRequest :: MonadIO m => p -> Request -> m Response

  data SomeProvider = forall p. Provider p => SomeProvider p
  ```

- `baikai-claude/src/Baikai/Provider/Claude/Api.hs` — the `ClaudeApi` record
  carrying `methods :: Claude.Methods` (built from a `ClientEnv` and an API key)
  and `pricing :: Map Text PricingRate`. Built via
  `claudeApi :: MonadIO m => Auth.ApiKeySource -> m ClaudeApi`. Implements
  `Provider` with `providerName _ = "anthropic.claude.api"` and `runRequest`
  performing the upstream call.

- `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` — symmetric `OpenAIApi`
  record built via `openaiApi`. Provider name `"openai.chat.api"`.

- `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
  `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` — CLI providers. Same
  shape, different upstream commands.

The cost/pricing surface lives in `baikai/src/Baikai/Cost/Pricing.hs`:

```haskell
data PricingRate = PricingRate
  { inputRate, outputRate, cachedInputRate :: !Rational }

defaultPricing :: Map Text PricingRate

compute :: Map Text PricingRate -> Model -> Usage -> Cost
attachCost :: Map Text PricingRate -> Response -> Response
```

After EP-1, the input to `compute` is the new `Usage` (with cache-read/write
split) and the output is always a `Cost` (never `Nothing`). After this plan,
the map disappears and the pricing rates live on `Model.cost`.

The trace bridge in `baikai/src/Baikai/Trace.hs` currently has:

```haskell
withTrace :: (Provider p, MonadUnliftIO m) => TraceSink -> p -> Request -> m Response
runRequestWith :: (Provider p, MonadUnliftIO m) => TraceSink -> CallLogHandle -> p -> Request -> m Response
```

This plan replaces both signatures with:

```haskell
withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
runRequestWith :: MonadUnliftIO m => TraceSink -> CallLogHandle -> Model -> Context -> Options -> m Response
```

The internals fork a worker thread that drains a `Chan (Maybe TraceEvent)` into the
sink's fold — same pattern, fewer record dereferences (no more
`providerName p` because the provider name comes from `Model.provider`).

The auth shim in `baikai/src/Baikai/Auth.hs`:

```haskell
data ApiKeySource = ApiKeyLiteral !Text | ApiKeyEnv !Text
resolveApiKey :: MonadIO m => ApiKeySource -> m Text
```

…stays. The registered handlers call it with the appropriate env var when
`Options.apiKey == Nothing`.


## Plan of Work

### Milestone 1: introduce `Baikai.Api` and `Baikai.Model`

**New file:** `baikai/src/Baikai/Api.hs`:

```haskell
data Api
  = OpenAIChatCompletions
  | AnthropicMessages
  | OpenAICompletionsCli      -- the codex exec CLI
  | AnthropicMessagesCli      -- the claude -p CLI
  | Custom !Text              -- escape hatch for third-party APIs
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

renderApi :: Api -> Text
renderApi = \case
  OpenAIChatCompletions -> "openai-chat-completions"
  AnthropicMessages -> "anthropic-messages"
  OpenAICompletionsCli -> "openai-completions-cli"
  AnthropicMessagesCli -> "anthropic-messages-cli"
  Custom t -> t

parseApi :: Text -> Api
parseApi = \case
  "openai-chat-completions" -> OpenAIChatCompletions
  "anthropic-messages" -> AnthropicMessages
  "openai-completions-cli" -> OpenAICompletionsCli
  "anthropic-messages-cli" -> AnthropicMessagesCli
  t -> Custom t
```

The constructor names follow pi-mono's wire format (`anthropic-messages`,
`openai-completions`) but with explicit suffixes for the CLI variants because
baikai supports them.

**Modified file:** `baikai/src/Baikai/Model.hs`. Replace
`newtype Model = Model { unModel :: Text }` with a data record:

```haskell
data InputModality = InputText | InputImage
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ModelCost = ModelCost
  { inputCost :: !Rational         -- $/million tokens
  , outputCost :: !Rational
  , cacheReadCost :: !Rational
  , cacheWriteCost :: !Rational
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Model = Model
  { modelId :: !Text                       -- e.g. "claude-sonnet-4-6"
  , name :: !Text                          -- display name
  , api :: !Api
  , provider :: !Text                      -- e.g. "anthropic"
  , baseUrl :: !Text
  , reasoning :: !Bool
  , input :: ![InputModality]
  , cost :: !ModelCost
  , contextWindow :: !Natural
  , maxOutputTokens :: !Natural
  , headers :: !(Map Text Text)
  , compat :: !Compat                      -- see Milestone 4 + EP-5
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

_Model :: Model
_Model = Model "" "" (Custom "") "" "" False [InputText] _ModelCost 0 0 Map.empty CompatNone

_ModelCost :: ModelCost
_ModelCost = ModelCost 0 0 0 0
```

The previous `newtype Model = Model Text` is retired. Add a `data Compat =
CompatNone` placeholder; EP-5 introduces `CompatOpenAICompletions` and
`CompatAnthropicMessages` constructors.

Add a backwards-compatible accessor `unModel :: Model -> Text; unModel = modelId`
that downstream code can keep using during the transition. Mark it
`{-# DEPRECATED unModel "Use modelId instead" #-}` and remove it at the end of
the plan.

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.Api` to `exposed-modules`.
No new dependencies.

**Acceptance.** `cabal build baikai` is green. `cabal repl baikai`:

```haskell
ghci> :t (_Model { modelId = "claude-sonnet-4-6", api = AnthropicMessages })
_Model { ... } :: Model
```

### Milestone 2: introduce `Baikai.Context` and `Baikai.Options`

**New file:** `baikai/src/Baikai/Context.hs`:

```haskell
data Context = Context
  { systemPrompt :: !(Maybe Text)
  , messages :: !(Vector Message)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

_Context :: Context
_Context = Context Nothing V.empty
```

`Context.tools :: Vector Tool` is added by EP-4. This plan leaves the field
out so EP-4's diff is small and obvious.

**New file:** `baikai/src/Baikai/Options.hs`:

```haskell
data Options = Options
  { maxTokens :: !(Maybe Natural)
  , temperature :: !(Maybe Double)
  , apiKey :: !(Maybe Text)              -- defaults via env var when Nothing
  , timeoutMs :: !(Maybe Int)
  , headers :: !(Map Text Text)          -- per-call override; merges into Model.headers
  , metadata :: !(Map Text Value)        -- provider-specific extension bag
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

_Options :: Options
_Options = Options Nothing Nothing Nothing Nothing Map.empty Map.empty
```

EP-3 adds `cacheRetention :: Maybe CacheRetention`, `sessionId :: Maybe Text`.
EP-4 adds `toolChoice :: Maybe ToolChoice`. EP-5 adds `thinking :: Maybe ThinkingLevel`.
This plan ships the four core fields above.

**Modified file:** `baikai/src/Baikai/Request.hs`. Delete the existing
`data Request {...}` record and its `_Request` default. Since baikai is pre-1.0
with no external consumers (per the masterplan's Decision Log), delete the
module outright in this milestone. Update `baikai/baikai.cabal` to drop
`Baikai.Request` from `exposed-modules` and add `Baikai.Context`,
`Baikai.Options`.

**Modified file:** `baikai/src/Baikai/Prelude.hs` and `baikai/src/Baikai.hs`.
Update the re-exports to expose `Baikai.Api`, `Baikai.Context`, `Baikai.Model`,
`Baikai.Options`. Remove the `Baikai.Request` re-export.

**Acceptance.** `cabal build baikai` is green. The vendor packages
(`baikai-claude`, `baikai-openai`) will fail to build at this point — Milestone
3 and Milestone 4 fix them.

### Milestone 3: introduce `Baikai.Provider.Registry`

**New file:** `baikai/src/Baikai/Provider/Registry.hs`:

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , complete :: Model -> Context -> Options -> IO Response
  }

registry :: IORef (Map Api ApiProvider)
registry = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE registry #-}

registerApiProvider :: ApiProvider -> IO ()
registerApiProvider p = modifyIORef' registry (Map.insert (apiTag p) p)

lookupApiProvider :: Api -> IO (Maybe ApiProvider)
lookupApiProvider tag = Map.lookup tag <$> readIORef registry

completeRequest :: Model -> Context -> Options -> IO Response
completeRequest m ctx opts = do
  mProvider <- lookupApiProvider (api m)
  case mProvider of
    Just p -> complete p m ctx opts
    Nothing -> throwIO $
      BaikaiError ("No provider registered for API: " <> renderApi (api m))
```

The `IORef + unsafePerformIO` pattern is borrowed from `Baikai.Trace`'s
`eventCounter` and is documented in this plan's Decision Log. The `BaikaiError`
constructor (`Baikai.Error`) gains a `ProviderNotRegistered` variant if a more
specific shape proves useful during implementation; the simple wrapping above
suffices for the smoke tests.

**Modified file:** `baikai/src/Baikai/Provider.hs`. **Remove** the `Provider`
typeclass and the `SomeProvider` existential. Reduce the module to a re-export
shim around `Baikai.Provider.Registry`. Update the haddock to explain the
migration.

**Modified file:** `baikai/baikai.cabal`. Add `Baikai.Provider.Registry` to
`exposed-modules`. `Baikai.Provider` stays exposed (as the shim).

**Acceptance.** `cabal build baikai` is green. `Baikai` re-exports
`completeRequest`, `registerApiProvider`, `lookupApiProvider`.

### Milestone 4: rewrite each provider

**Modified file:** `baikai-claude/src/Baikai/Provider/Claude/Api.hs`. Replace
the `ClaudeApi` record and the `Provider` instance with a single registration
function:

```haskell
module Baikai.Provider.Claude.Api (register) where

import Baikai.Api (Api (..))
import Baikai.Auth qualified as Auth
import Baikai.Context (Context (..))
import Baikai.Model (Model (..))
import Baikai.Options (Options (..))
import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..))
import Claude.V1 qualified as Claude
import Claude.V1.Messages qualified as Messages

register :: IO ()
register = registerApiProvider $ ApiProvider
  { apiTag = AnthropicMessages
  , complete = runClaudeMessages
  }

runClaudeMessages :: Model -> Context -> Options -> IO Response
runClaudeMessages m ctx opts = do
  apiKey <- resolveKey opts "ANTHROPIC_API_KEY"
  env <- Claude.getClientEnv (baseUrl m)
  let methods = Claude.makeMethods env apiKey (Just "2023-06-01")
  -- ... map ctx into a CreateMessage, call methods.createMessage, map response back ...

resolveKey :: Options -> Text -> IO Text
resolveKey opts envVar = case apiKey opts of
  Just k -> pure k
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv envVar)
```

The `mapRequest` and `mapResponse` helpers from EP-1 are reused; their bodies
now read `model = modelId m` instead of `model = unModel (req ^. #model)`.

**Modified file:** `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`. Symmetric:
exposes `register :: IO ()` that registers `OpenAIChatCompletions`. Reads
`OPENAI_API_KEY` when `Options.apiKey == Nothing`.

**Modified files:** `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. Each exposes `register`
that registers `AnthropicMessagesCli` / `OpenAICompletionsCli` respectively.
The CLI invocations stay the same; only the dispatch entry point and the
arg-marshalling source (`Context.messages` rather than `Request.messages`)
change. CLI providers ignore `Options.apiKey` and rely on the user's existing
CLI authentication (the CLI binaries handle their own auth).

**Acceptance.** `cabal build all` is green.

### Milestone 5: rewrite cost, trace, call log

**Modified file:** `baikai/src/Baikai/Cost/Pricing.hs`. Delete `defaultPricing`,
`PricingRate`, the `Map`-based `compute` and `attachCost`. Replace with:

```haskell
computeCost :: Model -> Usage -> Cost
computeCost m u = Cost
  { usd = inputUsd + outputUsd + cachedInputUsd + cachedWriteUsd
  , breakdown = CostBreakdown { inputUsd, outputUsd, cachedInputUsd, cachedWriteUsd }
  }
  where
    rates = cost m
    inputUsd       = fromIntegral (inputTokens u) * (inputCost rates / 1_000_000)
    outputUsd      = fromIntegral (outputTokens u) * (outputCost rates / 1_000_000)
    cachedInputUsd = fromIntegral (cacheReadTokens u) * (cacheReadCost rates / 1_000_000)
    cachedWriteUsd = fromIntegral (cacheWriteTokens u) * (cacheWriteCost rates / 1_000_000)

attachCost :: Model -> Response -> Response
attachCost m r = r { message = (message r) { usage = (usage (message r)) { cost = computed } } }
  where computed = computeCost m (usage (message r))
```

Each registered handler calls `attachCost model` before returning. The trace
bridge no longer needs to thread pricing through call sites.

**Modified file:** `baikai/src/Baikai/Trace.hs`. Replace the `withTrace`
signature with:

```haskell
withTrace :: MonadUnliftIO m
  => TraceSink -> Model -> Context -> Options -> m Response
withTrace (TraceSink sinkFold) m ctx opts = withRunInIO $ \_run -> do
  -- ... fork worker; emit CallStarted using:
  writeChan chan $ Just CallStarted
    { eventId = eid
    , timestamp = start
    , provider = provider m
    , model = modelId m
    , maxTokens = fromMaybe (maxOutputTokens m) (maxTokens opts)
    , promptSummary = summarizeContext ctx
    }
  -- ... call completeRequest m ctx opts inside try ...
```

`summarizeContext :: Context -> Text` walks the `Context.messages` vector for
the last `UserMessage` and flattens its `UserText` content into a 200-character
preview (this is the EP-1 implementation, moved from `Baikai.Trace`'s
`summarizePrompt`).

**Modified file:** `baikai/src/Baikai/Cost/Log.hs`. Update `runRequestWithLog`
and the `Trace.runRequestWith` wrapper to take `Model + Context + Options`.
JSON output is unchanged.

**Acceptance.** `cabal build all` is green. `cabal test baikai` is green:
`CostSpec.hs` passes with the new `computeCost` shape (the spec is rewritten
to construct `Model { cost = ModelCost ... }` directly and assert
`computeCost m _Usage { inputTokens = N, ... }` returns the expected `Cost`).

### Milestone 6: migrate tests and smoke runner

**Modified files:** `baikai/test/Main.hs`, `CostSpec.hs`, `TraceSpec.hs` are
updated to pass `Model` records (built with `_Model { modelId = "...", api = ...,
cost = ModelCost ... }`) and `Context` values (built with `_Context { messages
= ... }`). Calls to `runRequest` are replaced with `completeRequest` (or
`withTrace` for the trace specs).

**Modified file:** `baikai-trace-otel/test/Main.hs`. The OTel in-memory test
adapts to the new `withTrace` signature. Assertion: the produced span has
attributes `gen_ai.system = provider model`, `gen_ai.request.model = modelId model`,
`gen_ai.usage.input_tokens = inputTokens (usage (message resp))`, and so on.
The OTel sink itself (`Baikai.Trace.Sink.OpenTelemetry`) does not change —
only the test harness.

**Modified file:** `baikai-smoke/test/Smoke.hs`. The smoke runner:

```haskell
import Baikai
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi

main :: IO ()
main = do
  ClaudeApi.register
  OpenAIApi.register
  -- ...
  let claudeModel = _Model
        { modelId = "claude-sonnet-4-6"
        , name = "Claude Sonnet 4.6"
        , api = AnthropicMessages
        , provider = "anthropic"
        , baseUrl = "https://api.anthropic.com"
        , reasoning = False
        , input = [InputText]
        , cost = ModelCost 3 15 0.3 3.75   -- $/million tokens
        , contextWindow = 200_000
        , maxOutputTokens = 8_192
        }
  resp <- completeRequest claudeModel
    (_Context { messages = V.singleton (user "what is 2+2?") })
    (_Options { maxTokens = Just 256 })
  -- assert resp.message.content has at least one AssistantText block
```

Both API smoke cases use the same shape against different `Model` records.
CLI smoke cases register the CLI providers and dispatch through
`completeRequest` the same way.

**Acceptance.** `cabal test all` is green. With `ANTHROPIC_API_KEY` and
`OPENAI_API_KEY` set, the live smoke suite passes — proving the registry
dispatch works end-to-end.


## Concrete Steps

Run all commands from `/Users/shinzui/Keikaku/bokuno/baikai`. Enter the Nix
devshell first:

```bash
nix develop      # or direnv allow
```

Per milestone:

```bash
# Milestone 1: types compile in isolation
cabal build baikai

# Milestone 2: context/options compile; vendor packages temporarily broken
cabal build baikai

# Milestone 3: registry compiles; vendor packages still broken
cabal build baikai

# Milestone 4: vendor packages rebuilt against the registry
cabal build all

# Milestone 5: cost + trace propagate
cabal test baikai

# Milestone 6: full library + smoke tests
cabal test all
ANTHROPIC_API_KEY=... OPENAI_API_KEY=... cabal test baikai-smoke
```


## Validation and Acceptance

The plan is accepted when every item below holds:

- `cabal build all` is green.
- `cabal test all` is green with no API keys set.
- With API keys present, `cabal test baikai-smoke` runs all four providers
  (Claude API, OpenAI API, claude-p CLI, codex-exec CLI) through
  `completeRequest` and asserts each returns a `Response` with at least one
  `AssistantText` block.
- `cabal repl baikai` shows the new top-level signature:

  ```haskell
  ghci> :t completeRequest
  completeRequest :: Model -> Context -> Options -> IO Response
  ghci> :t withTrace
  withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
  ```

- The `Provider` typeclass and the `SomeProvider` existential no longer exist
  in the public surface (`cabal haddock baikai` produces no docs for either).
- `Baikai.Cost.Pricing` no longer exports `defaultPricing` or `PricingRate`;
  it exports `computeCost :: Model -> Usage -> Cost` and `attachCost :: Model
  -> Response -> Response`.


## Idempotence and Recovery

The registry's `registerApiProvider` is idempotent for the same `Api` tag (it
overwrites the existing entry). Running a provider's `register :: IO ()`
multiple times is safe but pointless. A future plan may add
`registerApiProvider`'s sibling `unregisterApiProvider :: Api -> IO ()` if a
test target needs to reset state; the smoke tests do not.

Rollback is by reverting commits. The `Provider` typeclass removal is the
largest single diff in this plan and is concentrated in Milestone 3; if a
real consumer outside the repository discovers a dependency on the typeclass
during review, the fallback is to keep `Provider` as a deprecated re-export
that builds an `ApiProvider` for any `Provider p => p`. That fallback is
documented here but not implemented unless requested.

If the `unsafePerformIO` IORef pattern produces unexpected behaviour under
GHC's `-O2` (e.g. CSE of the IORef thunk), the fallback is to use a
`MVar` instead. The pattern already works in `Baikai.Trace`'s `eventCounter`
under the same GHC version, so the risk is low.


## Interfaces and Dependencies

**External dependencies.** No new Hackage / vendored dependencies.

**Module surface at end of plan.**

From `Baikai` (top-level re-exports):

```haskell
data Api = OpenAIChatCompletions | AnthropicMessages | OpenAICompletionsCli | AnthropicMessagesCli | Custom !Text
data Model = Model { modelId, name, provider, baseUrl :: !Text, api :: !Api, reasoning :: !Bool, input :: ![InputModality], cost :: !ModelCost, contextWindow, maxOutputTokens :: !Natural, headers :: !(Map Text Text), compat :: !Compat }
data Compat = CompatNone   -- EP-5 extends
data ModelCost = ModelCost { inputCost, outputCost, cacheReadCost, cacheWriteCost :: !Rational }
data Context = Context { systemPrompt :: !(Maybe Text), messages :: !(Vector Message) }
data Options = Options { maxTokens :: !(Maybe Natural), temperature :: !(Maybe Double), apiKey :: !(Maybe Text), timeoutMs :: !(Maybe Int), headers :: !(Map Text Text), metadata :: !(Map Text Value) }
data ApiProvider = ApiProvider { apiTag :: !Api, complete :: Model -> Context -> Options -> IO Response }

registerApiProvider :: ApiProvider -> IO ()
lookupApiProvider :: Api -> IO (Maybe ApiProvider)
completeRequest :: Model -> Context -> Options -> IO Response
```

From each vendor provider module:

```haskell
register :: IO ()        -- installs the API handler into the registry
```

**Trace and call log contract.** The new shapes:

```haskell
withTrace :: MonadUnliftIO m => TraceSink -> Model -> Context -> Options -> m Response
runRequestWith :: MonadUnliftIO m => TraceSink -> CallLogHandle -> Model -> Context -> Options -> m Response
```

EP-3 (`docs/plans/9-streaming-event-protocol-with-streamly.md`) consumes this
plan's `ApiProvider`/registry surface and adds a `stream` field. The
`complete` field becomes a draining wrapper around `Stream.fold` after EP-3.
EP-5 (`docs/plans/11-compat-shims-cache-retention-and-multi-host-providers.md`)
extends the `Compat` sum with `CompatOpenAICompletions` and
`CompatAnthropicMessages` constructors. EP-6 generates `Model` records into
`Baikai.Models.Generated`.
