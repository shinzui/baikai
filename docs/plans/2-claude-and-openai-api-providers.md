---
id: 2
slug: claude-and-openai-api-providers
title: "Claude and OpenAI API providers"
kind: exec-plan
created_at: 2026-05-13T23:39:20Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# Claude and OpenAI API providers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan delivers the first two concrete providers for the Baikai abstraction:
`ClaudeApi` (wrapping Anthropic's Messages API) and `OpenAIApi` (wrapping OpenAI's Chat
Completions API). Both are implemented as instances of the `Baikai.Provider.Provider`
typeclass that EP-1 introduced. After this plan lands, a user can choose between two real
upstream services by constructing the appropriate value, call `runRequest` on it with a
`Baikai.Request.Request`, and receive a uniformly-shaped `Baikai.Response.Response` that
carries the model echo, an optional `Usage` populated from the API's own token counters, a
latency measurement, and `cost = Nothing` (cost calculation lands in EP-4).

Each provider lives in its own cabal package so consumers only pay for the vendor SDK they
actually use. EP-2 creates two new sibling packages under the repository root:
`baikai-claude` (housing `Baikai.Provider.Claude.Api`) and `baikai-openai` (housing
`Baikai.Provider.OpenAI.Api`). Both depend on the existing `baikai` core package for the
shared types and the `Provider` typeclass. EP-2 also adds a single new shared module,
`Baikai.Auth`, to the core `baikai` package, because the `ApiKeySource` ADT is vendor-
neutral and is consumed by every provider package. A consumer who only needs Claude adds
`baikai` and `baikai-claude` to their `build-depends`; the OpenAI Servant client closure
never enters their dependency graph.

The user-visible win is that downstream code becomes provider-agnostic. A snippet like the
one below works the same way regardless of which provider value is bound, and the recorded
token counts are the exact numbers the upstream API reported — no estimation, no proxy,
no local accounting yet.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLabels #-}

module Main (main) where

import           Baikai.Auth                (ApiKeySource (..))
import           Baikai.Model               (Model (..))
import           Baikai.Provider            (runRequest)
import           Baikai.Provider.Claude.Api (claudeApi)
import           Baikai.Request             (Message (..), Request (..), Role (..))
import           Baikai.Response            (Response (..))
import           Baikai.Usage               (Usage (..))
import qualified Data.Text.IO               as Text
import qualified Data.Vector                as Vector
import           Control.Lens               ((^.))

main :: IO ()
main = do
  provider <- claudeApi (ApiKeyEnv "ANTHROPIC_KEY")
  let req = Request
        { model = Model "claude-haiku-4-5-20251001"
        , messages = Vector.singleton
            (Message { role = User, content = "Say hi in one short sentence." })
        , maxTokens = 64
        , temperature = Just 0.0
        , systemPrompt = Just "You are terse."
        }
  resp <- runRequest provider req
  Text.putStrLn (resp ^. #content)
  case resp ^. #usage of
    Just u  -> putStrLn $ "input=" <> show (u ^. #inputTokens)
                       <> " output=" <> show (u ^. #outputTokens)
    Nothing -> putStrLn "no usage reported"
```

Swapping `Baikai.Provider.Claude.Api.claudeApi` for `Baikai.Provider.OpenAI.Api.openaiApi`
and the model string for `gpt-4o-mini` produces an equivalent program that targets OpenAI
instead. The interpretation of `Request.systemPrompt`, the rejection of `Role = System`
inside `Request.messages` for Claude, and the normalization of upstream usage fields into
`Baikai.Usage.Usage` are all handled inside this plan's two `mapRequest` / `mapResponse`
pairs so callers never have to think about per-vendor shape differences.

This plan deliberately leaves cost computation, retries, rate limiting, and streaming for
later ExecPlans. The point is to establish a working real-network round-trip end-to-end so
that subsequent plans can layer on top with confidence.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-05-13 Confirm `claude` and `openai` packages resolve in the `ghc912` Nix-provided package set by running `cabal build` after the new packages are wired up; if either is missing, add a `source-repository-package` block in `cabal.project` pointing at the local `mori`-registered path. (Outcome: nixpkgs Haskell set does not provide these; resolved by adding them as siblings in `packages:` with absolute paths.)
- [x] 2026-05-13 Create `baikai-claude/baikai-claude.cabal` with a single `library` stanza exposing `Baikai.Provider.Claude.Api` and depending on `baikai`, `claude`, `http-client`, `http-client-tls`, `servant-client`, `text`, `time`, and `vector`. (Also added `generic-lens` and `lens ^>=5.3` because the provider module uses `^.` with `OverloadedLabels`.)
- [x] 2026-05-13 Create `baikai-openai/baikai-openai.cabal` with a single `library` stanza exposing `Baikai.Provider.OpenAI.Api` and depending on `baikai`, `openai`, `http-client`, `http-client-tls`, `servant-client`, `text`, `time`, and `vector`. (Also added `generic-lens` and `lens` as above.)
- [x] 2026-05-13 Update repository-root `cabal.project` to list `baikai`, `baikai-claude`, and `baikai-openai` under `packages:` (and the two upstream package paths inline because `source-repository-package`'s `file+noindex` type is rejected by cabal-install 3.16's project file parser — see Surprises).
- [x] 2026-05-13 Add `Baikai.Auth` to `baikai/baikai.cabal`'s `exposed-modules` (the core package owns this shared helper).
- [x] 2026-05-13 Create `baikai/src/Baikai/Auth.hs` defining `ApiKeySource` and `resolveApiKey`.
- [x] 2026-05-13 Create `baikai-claude/src/Baikai/Provider/Claude/Api.hs` with `ClaudeApi`, `claudeApi`, `mapRequest`, `mapResponse`, and the `Provider ClaudeApi` instance.
- [x] 2026-05-13 Create `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` with `OpenAIApi`, `openaiApi`, `mapRequest`, `mapResponse`, and the `Provider OpenAIApi` instance.
- [x] 2026-05-13 Map `Role = System` inside `Request.messages` to `RequestInvalid` for the Claude provider and document the contract in module Haddocks.
- [x] 2026-05-13 Prepend `Request.systemPrompt` as a `System` `Message` for the OpenAI provider.
- [x] 2026-05-13 Implement `mapResponse` for Claude, reading `input_tokens`, `output_tokens`, and `cache_read_input_tokens` from `Claude.V1.Messages.Usage`; reasoning tokens stay `Nothing`.
- [x] 2026-05-13 Implement `mapResponse` for OpenAI, reading `prompt_tokens`, `completion_tokens`, `prompt_tokens_details.cached_tokens`, and `completion_tokens_details.reasoning_tokens` from `OpenAI.V1.Usage.Usage`.
- [x] 2026-05-13 Measure latency around the upstream call using `Data.Time.Clock.getCurrentTime` and `diffUTCTime`, storing the result as an `Integer` milliseconds value.
- [ ] Add a smoke-test suite `baikai-smoke` (declared in `baikai/baikai.cabal`, depending on both `baikai-claude` and `baikai-openai`) gated on `ANTHROPIC_KEY` / `OPENAI_KEY`; when either is unset, the corresponding case is skipped, not failed.
- [ ] Run `cabal build all` and `cabal test all` (without keys set) and confirm everything compiles and skipped tests are reported as skipped.
- [ ] Run `ANTHROPIC_KEY=sk-... OPENAI_KEY=sk-... cabal test all` once against the live APIs and capture the transcript into Concrete Steps.
- [ ] Update Decision Log and Surprises & Discoveries as questions resolve.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-13: `cabal.project`'s `source-repository-package` block with `type: file+noindex`
  is rejected by the project-file parser in cabal-install 3.16.1.0 (Nix-provided), failing
  with `Error: [Cabal-7090] ... unexpected '+'`. Resolved by listing the two upstream
  packages as siblings under `packages:` with absolute paths to
  `/Users/shinzui/Keikaku/hub/haskell/claude-project/claude` and
  `/Users/shinzui/Keikaku/hub/haskell/openai-project/openai`. This is functionally
  equivalent for the local build but means the upstream packages are visible as part of the
  same project. If a future maintainer drops the mori-registered checkout, they will need
  to switch to a `git` source-repository-package block instead.
- 2026-05-13: The upstream `Claude.V1.Messages.SystemPrompt` constructor is
  `SystemPromptText` (no underscore between "Prompt" and "Text"), not the
  `SystemPrompt_Text` that the plan's example code showed. Fixed in `mapRequest` to use
  `Messages.SystemPromptText`. The `_Text` suffix convention is used on `ContentBlock_Text`
  but *not* on `SystemPrompt`.
- 2026-05-13: `Methods` for both upstream packages lives in `Claude.V1` /
  `OpenAI.V1`, *not* in `Claude.V1.Messages` / `OpenAI.V1.Chat.Completions`. The plan
  imported `Messages.Methods` and `Chat.Methods`; this fails because the inner modules do
  not re-export `Methods`. Adjusted both providers to keep the value as
  `Claude.Methods` / `OpenAI.Methods` and pattern-match the relevant field selector inside
  the instance method body.
- 2026-05-13: `CompletionTokensDetails` and `PromptTokensDetails` live in
  `OpenAI.V1.Usage`, not in `OpenAI.V1.Chat.Completions` (which only imports them
  internally). `mapUsage`'s signature on the OpenAI side names them via `OpenAIUsage.*`.
- 2026-05-13: `Claude.V1.Messages.Message` carries a `cache_control :: Maybe CacheControl`
  field that is not strictly required at the type level but is needed to silence
  `-Wmissing-fields` under `-Werror`-equivalent warning settings. The provider's
  `mkMessage` helper now explicitly sets `cache_control = Nothing`. The upstream
  `_CreateMessage` "blank" value already covers this for `CreateMessage`, but `Message`
  has no analogous `_Message`.
- 2026-05-13: `OpenAI.V1.Chat.Completions.Assistant` constructor uses
  `assistant_content :: Maybe (Vector Content)` (and `assistant_audio`, `refusal`,
  `tool_calls`) rather than the plain `content`/`name` shape the plan listed. The plan's
  code only constructed `User` messages; this implementation also handles `Assistant`
  turns (with `assistant_content = Just payload`) so multi-turn flows work.
- 2026-05-13: To use `^. #fieldName` over Claude and OpenAI types — which derive
  `Generic` but do not provide `IsLabel` instances themselves — both provider modules
  import `Data.Generics.Labels ()` for the generic-lens orphan instance. This mirrors what
  `Baikai.Prelude` does for `baikai`-owned types.


## Decision Log

Record every decision made while working on the plan.

- Decision: Split the provider implementations into two new sibling cabal packages, `baikai-claude` and `baikai-openai`, rather than adding more modules to the single `baikai` package.
  Rationale: The `claude` and `openai` Haskell packages each pull in a sizeable Servant client closure (`servant-client`, `http-client`, `http-client-tls`, `aeson` instances, etc.). Bundling both into the core `baikai` library would force every downstream consumer to pay the compile-time and dependency-resolution cost of both vendor SDKs even when they only use one. By splitting, a project that only needs Claude depends on `baikai` and `baikai-claude` and never sees the OpenAI Servant types, and vice versa. The packages are kept as siblings under the repository root (`baikai-claude/`, `baikai-openai/`) and registered in the top-level `cabal.project`, so they remain co-developed without coupling at the library boundary.
  Date: 2026-05-13

- Decision: `Baikai.Auth` (`ApiKeySource` and `resolveApiKey`) lives in the core `baikai` package, not in either vendor package.
  Rationale: API-key sourcing is vendor-neutral — both `baikai-claude` and `baikai-openai` consume the same `ApiKeySource` ADT and call the same `resolveApiKey` helper. Putting it in the core package means future provider packages (e.g. `baikai-gemini`) can reuse it without depending on either vendor SDK, and `BaikaiError`/`ProviderError` (already in `baikai`) stays the canonical failure channel. The module has no vendor-specific imports, so there is no leakage in this direction.
  Date: 2026-05-13

- Decision: Model API-key sourcing as a small ADT `Baikai.Auth.ApiKeySource = ApiKeyLiteral Text | ApiKeyEnv String`, resolved by `resolveApiKey :: MonadIO m => ApiKeySource -> m Text` which throws `ProviderError` if the named env var is unset.
  Rationale: A two-constructor ADT keeps the surface tiny while supporting the two real-world cases (literal token in test code, env var lookup in production) without dragging in a monad-reader or settings library. Putting the failure mode through the existing `BaikaiError` keeps error handling uniform with the rest of the abstraction.
  Date: 2026-05-13

- Decision: When `Baikai.Request.Request.messages` contains a `Message { role = System }`, both providers (initially) reject the request with `RequestInvalid "system role belongs in Request.systemPrompt, not Request.messages"`.
  Rationale: Anthropic's API does not accept system messages inside the `messages` array at all, and OpenAI accepts them but treats them as plain prepended text. Forcing callers to use the dedicated `systemPrompt` field keeps semantics identical across providers and prevents drift where one provider silently coalesces and another rejects. This is a contract decision; if a future use case appears, we can relax it.
  Date: 2026-05-13

- Decision: For Claude, `Baikai.Usage.Usage.cachedInputTokens` is populated from `Claude.V1.Messages.Usage.cache_read_input_tokens`, not `cache_creation_input_tokens`.
  Rationale: Anthropic bills `cache_creation_input_tokens` at the standard input rate (with a small write surcharge) and `cache_read_input_tokens` at a substantially discounted rate. Downstream cost calculation in EP-4 needs the read counter to apply the cache-hit discount; the creation counter is just standard input usage from a billing perspective. Naming the slot `cachedInputTokens` and mapping to the read counter matches the semantic intent ("tokens that were served from cache").
  Date: 2026-05-13

- Decision: For OpenAI, `Baikai.Response.Response.content` is built by mapping `OpenAI.V1.Chat.Completions.messageToContent` over every `Choice.message` and concatenating the resulting `Text` values in choice-index order.
  Rationale: `n` defaults to 1 so the common case is a single choice, but the API can return multiple candidate completions. Concatenating preserves all returned text without dropping data; if a caller wants only the first choice they can still parse out the leading segment. The `messageToContent` helper handles content-shape variants (plain text vs. structured content blocks) consistently.
  Date: 2026-05-13

- Decision: The Anthropic `anthropic-version` header is hard-coded to `"2023-06-01"` in `claudeApi`.
  Rationale: This is the current stable header value documented by Anthropic and what `Claude.V1.makeMethods` expects to be passed as its third argument. Bumping it is a one-line change inside the provider. Surfacing it as a configuration knob now would add API surface for no immediate gain.
  Date: 2026-05-13

- Decision: EP-2 ignores `top_p`, `top_k`, and `stop_sequences` when mapping `Baikai.Request.Request` to upstream request types.
  Rationale: `Baikai.Request.Request` does not yet carry these fields; only `maxTokens`, `temperature`, and `systemPrompt` are exposed beyond `model` and `messages`. Adding them is a non-breaking extension that a later plan can do by widening `Request` and updating both `mapRequest` functions. Pretending to support them now would couple this plan to fields nobody can pass in yet.
  Date: 2026-05-13

- Decision: `claudeApi`, `openaiApi`, `resolveApiKey`, and the `Provider` instance method bodies are written with `MonadIO m =>` constraints; the IO-typed work inside each function is wrapped in a single `liftIO` at the top.
  Rationale: Match the EP-1 typeclass signature. Forward-compat with a future `baikai-effectful` package whose providers will run inside `Eff es`. The single `liftIO` boundary keeps the existing `do`-block bodies unchanged.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/baikai`. The library is split across
sibling cabal packages directly under the repo root:

- `baikai/` — the core package (cabal file `baikai/baikai.cabal`, sources `baikai/src/`).
  Already populated by EP-1. EP-2 adds one module (`Baikai.Auth`) here.
- `baikai-claude/` — created by EP-2. Cabal file `baikai-claude/baikai-claude.cabal`,
  sources `baikai-claude/src/`. Houses `Baikai.Provider.Claude.Api`.
- `baikai-openai/` — created by EP-2. Cabal file `baikai-openai/baikai-openai.cabal`,
  sources `baikai-openai/src/`. Houses `Baikai.Provider.OpenAI.Api`.

The repository-root `cabal.project` lists these as the project's packages. The build is
driven by a Nix flake (`flake.nix`, `flake.lock` at the repo root) which pins `ghc912` as
the compiler. The default Haskell language is `GHC2024`, and each cabal file replicates the
same `common common-options` stanza enabling `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, and `OverloadedStrings` for every component, so module headers in this
plan do not need to re-list those pragmas. Haskell module names are independent of cabal
package names: `Baikai.Provider.Claude.Api` lives at
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` and is imported by consumers as
`import Baikai.Provider.Claude.Api` regardless of which package provides it.

Prior work (recorded in `/Users/shinzui/Keikaku/bokuno/baikai/docs/plans/1-core-abstraction-types-and-provider-class.md`)
introduced six modules under `Baikai.*`. Their types are reproduced here so this plan is
self-contained.

```haskell
-- Baikai.Model
newtype Model = Model { unModel :: Text }

-- Baikai.Request
data Role = User | Assistant | System

data Message = Message { role :: !Role, content :: !Text }

data Request = Request
  { model :: !Model
  , messages :: !(Vector Message)
  , maxTokens :: !Natural
  , temperature :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  }

-- Baikai.Usage
data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  }

-- Baikai.Response (Cost is defined in a separate module and stays Nothing in EP-2)
data Response = Response
  { content :: !Text
  , model :: !Model
  , usage :: !(Maybe Usage)
  , cost :: !(Maybe Cost)
  , provider :: !Text
  , latencyMs :: !Integer
  }

-- Baikai.Error
data BaikaiError
  = ProviderError !Text
  | RequestInvalid !Text
  | DecodeError !Text
  | ProcessError !Int !Text

-- Baikai.Provider
class Provider p where
  providerName :: p -> Text
  runRequest :: MonadIO m => p -> Request -> m Response
```

`BaikaiError` derives `Exception` from EP-1, so `throwIO` and `try` work directly on values
of this type. Field selectors are accessed via `OverloadedLabels` (e.g. `req ^. #model`),
so the plan's code blocks lean on `Control.Lens` (`(^.)`) for readability.

This ExecPlan introduces two new provider modules, each in its own new cabal package:

- `Baikai.Provider.Claude.Api` at `baikai-claude/src/Baikai/Provider/Claude/Api.hs`,
  exposed by `baikai-claude/baikai-claude.cabal`.
- `Baikai.Provider.OpenAI.Api` at `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`,
  exposed by `baikai-openai/baikai-openai.cabal`.

It also introduces one shared helper module in the core package:

- `Baikai.Auth` at `baikai/src/Baikai/Auth.hs`, added to `baikai/baikai.cabal`'s
  `exposed-modules`.

The smoke test introduced at the end of this plan lives at `baikai/test/Smoke.hs` and is
wired up as a new test-suite `baikai-smoke` in `baikai/baikai.cabal`; it depends on both
new vendor packages so it can exercise either provider when its key is present.

The upstream `claude` package is registered with `mori` and its source is on disk at
`/Users/shinzui/Keikaku/hub/haskell/claude-project/claude/`. The relevant module is
`Claude.V1`, which re-exports `Claude.V1.Messages`. The pieces this plan touches:

```haskell
-- Claude.V1 (and Claude.V1.Client)
getClientEnv :: Text -> IO ClientEnv
makeMethods :: ClientEnv -> Text -> Maybe Text -> Methods
  -- args: (env, apiKey, anthropicVersion)

-- Claude.V1.Messages
data Methods = Methods
  { createMessage :: CreateMessage -> IO MessageResponse
  , createMessageStream :: ...
  , countTokens :: ...
  , createBatch :: ...
  , ...
  }

data CreateMessage = CreateMessage
  { model :: Text
  , messages :: Vector Message
  , max_tokens :: Natural
  , system :: Maybe SystemPrompt
  , cache_control :: Maybe CacheControl
  , temperature :: Maybe Double
  , top_p :: Maybe Double
  , top_k :: Maybe Natural
  , stop_sequences :: Maybe (Vector Text)
  , stream :: Maybe Bool
  , metadata :: Maybe (Map Text Text)
  , tools :: Maybe (Vector ToolDefinition)
  , tool_choice :: Maybe ToolChoice
  , container :: Maybe Text
  , context_management :: Maybe ContextManagementConfig
  , inference_geo :: Maybe Text
  , speed :: Maybe Speed
  , output_config :: Maybe OutputConfig
  , thinking :: Maybe Thinking
  }

_CreateMessage :: CreateMessage   -- default value with all Maybe fields = Nothing

data Message = Message { role :: Role, content :: Vector Content }
data Role = User | Assistant      -- no System constructor

data Content
  = Content_Text { text :: Text, cache_control :: Maybe CacheControl }
  | ...
textContent :: Text -> Content    -- smart constructor for a plain text block

data SystemPrompt = SystemPrompt_Text Text | ...

data MessageResponse = MessageResponse
  { id :: Text
  , type_ :: Text
  , role :: Role
  , content :: Vector ContentBlock
  , model :: Text
  , stop_reason :: Maybe StopReason
  , stop_sequence :: Maybe Text
  , usage :: Usage          -- this is Claude.V1.Messages.Usage
  , container :: Maybe ContainerInfo
  }

data ContentBlock = ContentBlock_Text { text :: Text } | ...

-- distinct from Baikai.Usage.Usage
data Usage = Usage
  { input_tokens :: Natural
  , output_tokens :: Natural
  , cache_creation_input_tokens :: Maybe Natural
  , cache_read_input_tokens :: Maybe Natural
  , server_tool_use :: Maybe ServerToolUseUsage
  }
```

The upstream `openai` package is also `mori`-registered, on disk at
`/Users/shinzui/Keikaku/hub/haskell/openai-project/openai/`. The relevant module is
`OpenAI.V1`, which re-exports `OpenAI.V1.Chat.Completions` and `OpenAI.V1.Models`:

```haskell
-- OpenAI.V1
getClientEnv :: Text -> IO ClientEnv
makeMethods :: ClientEnv -> Text -> Maybe Text -> Maybe Text -> Methods
  -- args: (env, apiKey, organization, project)

-- OpenAI.V1.Models
newtype Model = Model { ... }  -- Text newtype; constructible from a Text literal

-- OpenAI.V1.Chat.Completions
data Methods = Methods
  { createChatCompletion :: CreateChatCompletion -> IO ChatCompletionObject
  , ...
  }

data CreateChatCompletion = CreateChatCompletion
  { messages :: Vector (Message (Vector Content))
  , model :: Model
  , store :: Maybe Bool
  , metadata :: Maybe (Map Text Text)
  , frequency_penalty :: Maybe Double
  , max_completion_tokens :: Maybe Natural
  , ...
  , temperature :: Maybe Double
  , top_p :: Maybe Double
  , ...
  }

_CreateChatCompletion :: CreateChatCompletion   -- default value

data Message content
  = System { content :: content, name :: Maybe Text }
  | User { content :: content, name :: Maybe Text }
  | Assistant { ... }
  | Tool { ... }

data Content = Text { text :: Text } | ImageURL { ... } | ...

data ChatCompletionObject = ChatCompletionObject
  { id :: Text
  , choices :: Vector Choice
  , created :: POSIXTime
  , model :: Model
  , ...
  , usage :: Usage CompletionTokensDetails PromptTokensDetails
  }

data Choice = Choice
  { finish_reason :: Text
  , index :: Natural
  , message :: Message Text
  , logprobs :: Maybe LogProbs
  }

messageToContent :: Monoid content => Message content -> content

-- OpenAI.V1.Usage
data Usage ct pt = Usage
  { completion_tokens :: Natural
  , prompt_tokens :: Natural
  , total_tokens :: Natural
  , completion_tokens_details :: Maybe ct
  , prompt_tokens_details :: Maybe pt
  }

data PromptTokensDetails = PromptTokensDetails
  { audio_tokens :: Maybe Natural
  , cached_tokens :: Maybe Natural
  }

data CompletionTokensDetails = CompletionTokensDetails
  { accepted_prediction_tokens :: Maybe Natural
  , audio_tokens :: Maybe Natural
  , reasoning_tokens :: Maybe Natural
  , rejected_prediction_tokens :: Maybe Natural
  }
```

The two upstream APIs differ in two ways this plan must paper over.

First, on the request side: Anthropic separates the system prompt into its own top-level
`system` field on `CreateMessage`, while OpenAI represents it as the first entry of the
`messages` array using the `System` constructor of `OpenAI.V1.Chat.Completions.Message`.
This plan keeps `Baikai.Request.Request.systemPrompt` as the canonical source for both;
`mapRequest` for OpenAI prepends a `System` message when the field is set, and `mapRequest`
for Claude assigns it to `CreateMessage.system`.

Second, on the response side: Anthropic's `MessageResponse.content` is a
`Vector ContentBlock`, where each block is one of several constructors and only
`ContentBlock_Text { text :: Text }` carries plain text. To produce a single `Text`
response, this plan filters for `ContentBlock_Text` and concatenates the `text` fields in
order, dropping any tool-use or non-text blocks (the initial mapping does not surface
tool use). OpenAI's `ChatCompletionObject.choices` is a `Vector Choice`, and each choice's
`message :: Message Text` is converted via `messageToContent`; this plan concatenates the
results across all choices in `index` order.

The token-usage shapes are also distinct. Anthropic reports raw `input_tokens` and
`output_tokens` plus the cache counters described above. OpenAI reports `prompt_tokens`,
`completion_tokens`, a nested `prompt_tokens_details.cached_tokens`, and
`completion_tokens_details.reasoning_tokens`. The `Baikai.Usage.Usage` slot
`cachedInputTokens` is the canonical "tokens served from cache" counter on the input side;
`reasoningTokens` is the canonical "hidden chain-of-thought tokens" counter on the output
side. Anthropic does not currently report reasoning tokens via this API, so that field
stays `Nothing` for the Claude provider.


## Plan of Work

The work is sequenced in four milestones. Milestones 1 through 3 each leave the package in
a `cabal build all`-green state; milestone 4 adds the live-network smoke test that proves
the providers actually talk to their respective services.

### Milestone 1: Cabal wiring and `Baikai.Auth`

Scope: create the two new sibling cabal packages (`baikai-claude` and `baikai-openai`),
update repository-root `cabal.project` to declare them alongside `baikai`, add the
`Baikai.Auth` module to `baikai/baikai.cabal`'s `exposed-modules`, and write the
`Baikai.Auth` helper. After this milestone, `cabal build all` succeeds (each new package
builds an empty library — the provider modules are added in milestones 2 and 3), and
`import Baikai.Auth` from `cabal repl baikai` returns a working `resolveApiKey` function.

Create `baikai-claude/baikai-claude.cabal` (full file shown in Interfaces and Dependencies
below) and `baikai-openai/baikai-openai.cabal` (also shown below). Both files follow the
same `common common-options` pattern as `baikai/baikai.cabal` and both depend on `baikai`
for the typeclass and core types.

Update repository-root `cabal.project` so its `packages:` stanza lists all three packages.
The full diff is given in Interfaces and Dependencies below.

Add `Baikai.Auth` to the `exposed-modules` of `baikai/baikai.cabal`'s `library` stanza
(also diffed below). No new `build-depends` are needed in `baikai` for this — `Baikai.Auth`
uses only `base`, `text`, and the existing `Baikai.Error` import.

If `cabal build` reports that `claude` or `openai` is not in the package set provided by
the flake's `ghc912`, fall back to declaring them as `source-repository-package` blocks in
`cabal.project`:

```text
packages:
  baikai
  baikai-claude
  baikai-openai

source-repository-package
  type: file+noindex
  location: /Users/shinzui/Keikaku/hub/haskell/claude-project/claude

source-repository-package
  type: file+noindex
  location: /Users/shinzui/Keikaku/hub/haskell/openai-project/openai
```

If `file+noindex` is not supported by the cabal version in use, the alternative is to
declare them via a `git` source pointing at the public repository:

```text
source-repository-package
  type: git
  location: https://github.com/MercuryTechnologies/claude.git
  tag: <commit-sha-of-known-good-revision>

source-repository-package
  type: git
  location: https://github.com/MercuryTechnologies/openai.git
  tag: <commit-sha-of-known-good-revision>
```

The path form is preferred when available because it keeps builds offline and reproducible
against the same mori-registered source the rest of the user's projects use. Verify by
running `mori registry show claude --full` and `mori registry show openai --full` to print
the on-disk paths before pasting them into `cabal.project`.

Create `baikai/src/Baikai/Auth.hs` with the following contents:

```haskell
{-# LANGUAGE LambdaCase #-}

-- | API key sourcing for provider constructors.
--
-- Providers accept an 'ApiKeySource' rather than a raw 'Text' so test code can supply
-- a literal token and production code can defer to an environment variable. The lookup
-- happens lazily inside 'resolveApiKey'; constructing an 'ApiKeyEnv' value does not read
-- the environment.
module Baikai.Auth
  ( ApiKeySource (..)
  , resolveApiKey
  ) where

import           Baikai.Error            (BaikaiError (..))
import           Control.Exception       (throwIO)
import           Control.Monad.IO.Class  (MonadIO, liftIO)
import           Data.Text               (Text)
import qualified Data.Text               as Text
import qualified System.Environment      as Environment

-- | Where a provider should obtain its API key.
data ApiKeySource
  = -- | Use this literal string. Convenient for tests and one-off scripts.
    ApiKeyLiteral !Text
  | -- | Read this environment variable at provider construction time.
    ApiKeyEnv !String
  deriving (Eq, Show)

-- | Resolve a key source to a plain 'Text'. Throws 'ProviderError' (a constructor of
-- 'BaikaiError') if 'ApiKeyEnv' is used and the named variable is unset.
resolveApiKey :: MonadIO m => ApiKeySource -> m Text
resolveApiKey (ApiKeyLiteral t) = pure t
resolveApiKey (ApiKeyEnv name) = liftIO $
  Environment.lookupEnv name >>= \case
    Just v  -> pure (Text.pack v)
    Nothing -> throwIO (ProviderError ("env var " <> Text.pack name <> " is not set"))
```

Acceptance for milestone 1: `cabal build all` succeeds and `cabal repl baikai` followed by
`:t Baikai.Auth.resolveApiKey` prints `Baikai.Auth.resolveApiKey :: Control.Monad.IO.Class.MonadIO m => Baikai.Auth.ApiKeySource -> m Data.Text.Internal.Text`.

### Milestone 2: `Baikai.Provider.Claude.Api`

Scope: implement the Claude provider inside the `baikai-claude` package. After this
milestone, `ghci> claudeApi (ApiKeyLiteral "fake")` (from `cabal repl baikai-claude`)
constructs a `ClaudeApi` value (no network call yet — `makeMethods` is pure setup), and
`runRequest` calls are type-correct.

Create `baikai-claude/src/Baikai/Provider/Claude/Api.hs`:

```haskell
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Provider wrapping the @claude@ package's Messages API.
--
-- Construct a 'ClaudeApi' with 'claudeApi' and a 'Baikai.Auth.ApiKeySource', then pass it
-- to 'Baikai.Provider.runRequest' as you would any other provider. The provider name is
-- @"anthropic.claude.api"@.
--
-- Contract: 'Baikai.Request.Request.messages' must contain only 'User' and 'Assistant'
-- roles. A 'System' role inside the messages vector causes 'runRequest' to throw
-- 'RequestInvalid'; use 'Baikai.Request.Request.systemPrompt' instead.
module Baikai.Provider.Claude.Api
  ( ClaudeApi (..)
  , claudeApi
  ) where

import qualified Baikai.Auth                 as Auth
import           Baikai.Error                (BaikaiError (..))
import qualified Baikai.Model                as Model
import           Baikai.Provider             (Provider (..))
import qualified Baikai.Request              as Req
import qualified Baikai.Response             as Resp
import qualified Baikai.Usage                as Usage
import qualified Claude.V1                   as Claude
import qualified Claude.V1.Messages          as Messages
import           Control.Exception           (throwIO)
import           Control.Lens                ((^.))
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.Text                   (Text)
import qualified Data.Text                   as Text
import           Data.Time.Clock             (UTCTime, diffUTCTime, getCurrentTime)
import           Data.Vector                 (Vector)
import qualified Data.Vector                 as Vector

-- | A configured Anthropic Messages API provider.
data ClaudeApi = ClaudeApi
  { methods :: !Messages.Methods
  }

-- | Build a 'ClaudeApi' from a key source. Performs no network I/O.
claudeApi :: MonadIO m => Auth.ApiKeySource -> m ClaudeApi
claudeApi src = do
  key <- Auth.resolveApiKey src
  env <- liftIO (Claude.getClientEnv "https://api.anthropic.com")
  pure ClaudeApi { methods = Claude.makeMethods env key (Just "2023-06-01") }

instance Provider ClaudeApi where
  providerName _ = "anthropic.claude.api"
  runRequest ClaudeApi { methods } req = liftIO $ do
    createReq <- either (throwIO . RequestInvalid) pure (mapRequest req)
    start <- getCurrentTime
    resp  <- Messages.createMessage methods createReq
    end   <- getCurrentTime
    pure (mapResponse req start end resp)

-- | Translate a 'Baikai.Request.Request' to Anthropic's 'Messages.CreateMessage'.
--
-- Rejects messages whose role is 'Req.System'; those belong in
-- 'Req.systemPrompt'.
mapRequest :: Req.Request -> Either Text Messages.CreateMessage
mapRequest req = do
  msgs <- traverse mapMessage (Vector.toList (req ^. #messages))
  pure Messages._CreateMessage
    { Messages.model       = Model.unModel (req ^. #model)
    , Messages.messages    = Vector.fromList msgs
    , Messages.max_tokens  = req ^. #maxTokens
    , Messages.system      = fmap Messages.SystemPrompt_Text (req ^. #systemPrompt)
    , Messages.temperature = req ^. #temperature
    }

mapMessage :: Req.Message -> Either Text Messages.Message
mapMessage m = case m ^. #role of
  Req.User      -> Right (mkMessage Messages.User (m ^. #content))
  Req.Assistant -> Right (mkMessage Messages.Assistant (m ^. #content))
  Req.System    -> Left "system role belongs in Request.systemPrompt, not Request.messages"

mkMessage :: Messages.Role -> Text -> Messages.Message
mkMessage r t = Messages.Message
  { Messages.role    = r
  , Messages.content = Vector.singleton (Messages.textContent t)
  }

-- | Translate Anthropic's 'Messages.MessageResponse' to 'Resp.Response'.
mapResponse :: Req.Request -> UTCTime -> UTCTime -> Messages.MessageResponse -> Resp.Response
mapResponse req start end resp = Resp.Response
  { Resp.content   = extractText (resp ^. #content)
  , Resp.model     = Model.Model (resp ^. #model)
  , Resp.usage     = Just (mapUsage (resp ^. #usage))
  , Resp.cost      = Nothing
  , Resp.provider  = "anthropic.claude.api"
  , Resp.latencyMs = millisBetween start end
  }
  where
    _ = req  -- request currently unused; retained for symmetry with OpenAI

extractText :: Vector Messages.ContentBlock -> Text
extractText = Text.concat . Vector.toList . Vector.mapMaybe textOf
  where
    textOf = \case
      Messages.ContentBlock_Text { text } -> Just text
      _                                   -> Nothing

mapUsage :: Messages.Usage -> Usage.Usage
mapUsage u = Usage.Usage
  { Usage.inputTokens       = u ^. #input_tokens
  , Usage.outputTokens      = u ^. #output_tokens
  , Usage.cachedInputTokens = u ^. #cache_read_input_tokens
  , Usage.reasoningTokens   = Nothing
  }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
```

Acceptance for milestone 2: `cabal build all` succeeds. `cabal repl baikai-claude`
followed by `:i Baikai.Provider.Claude.Api.ClaudeApi` prints the data declaration and the
`Provider` instance.

### Milestone 3: `Baikai.Provider.OpenAI.Api`

Scope: implement the OpenAI provider analogously, inside the `baikai-openai` package.
After this milestone, two `Provider` instances exist (one per vendor package) and
`cabal build all` is still green.

Create `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`:

```haskell
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Construct an 'OpenAIApi' with 'openaiApi' and a 'Baikai.Auth.ApiKeySource'. The provider
-- name is @"openai.chat.api"@.
--
-- Contract: 'Baikai.Request.Request.messages' carries User and Assistant turns only.
-- 'Baikai.Request.Request.systemPrompt', when present, is prepended to the upstream
-- @messages@ array as a 'System' message.
module Baikai.Provider.OpenAI.Api
  ( OpenAIApi (..)
  , openaiApi
  ) where

import qualified Baikai.Auth                       as Auth
import           Baikai.Error                      (BaikaiError (..))
import qualified Baikai.Model                      as Model
import           Baikai.Provider                   (Provider (..))
import qualified Baikai.Request                    as Req
import qualified Baikai.Response                   as Resp
import qualified Baikai.Usage                      as Usage
import qualified OpenAI.V1                         as OpenAI
import qualified OpenAI.V1.Chat.Completions        as Chat
import qualified OpenAI.V1.Models                  as OpenAIModels
import qualified OpenAI.V1.Usage                   as OpenAIUsage
import           Control.Exception                 (throwIO)
import           Control.Lens                      ((^.))
import           Control.Monad.IO.Class            (MonadIO, liftIO)
import           Data.Text                         (Text)
import qualified Data.Text                         as Text
import           Data.Time.Clock                   (UTCTime, diffUTCTime, getCurrentTime)
import           Data.Vector                       (Vector)
import qualified Data.Vector                       as Vector

-- | A configured OpenAI Chat Completions provider.
data OpenAIApi = OpenAIApi
  { methods :: !Chat.Methods
  }

-- | Build an 'OpenAIApi' from a key source. Performs no network I/O.
openaiApi :: MonadIO m => Auth.ApiKeySource -> m OpenAIApi
openaiApi src = do
  key <- Auth.resolveApiKey src
  env <- liftIO (OpenAI.getClientEnv "https://api.openai.com")
  pure OpenAIApi { methods = OpenAI.makeMethods env key Nothing Nothing }

instance Provider OpenAIApi where
  providerName _ = "openai.chat.api"
  runRequest OpenAIApi { methods } req = liftIO $ do
    create <- either (throwIO . RequestInvalid) pure (mapRequest req)
    start  <- getCurrentTime
    obj    <- Chat.createChatCompletion methods create
    end    <- getCurrentTime
    pure (mapResponse start end obj)

-- | Translate a 'Baikai.Request.Request' to OpenAI's 'Chat.CreateChatCompletion'.
mapRequest :: Req.Request -> Either Text Chat.CreateChatCompletion
mapRequest req = do
  body <- traverse mapMessage (Vector.toList (req ^. #messages))
  let prefix = case req ^. #systemPrompt of
        Nothing -> []
        Just sp -> [Chat.System
                      { Chat.content = Vector.singleton (Chat.Text { Chat.text = sp })
                      , Chat.name    = Nothing
                      }]
  pure Chat._CreateChatCompletion
    { Chat.messages              = Vector.fromList (prefix <> body)
    , Chat.model                 = OpenAIModels.Model (Model.unModel (req ^. #model))
    , Chat.max_completion_tokens = Just (req ^. #maxTokens)
    , Chat.temperature           = req ^. #temperature
    }

mapMessage :: Req.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage m =
  let payload = Vector.singleton (Chat.Text { Chat.text = m ^. #content })
  in case m ^. #role of
       Req.User      -> Right (Chat.User      { Chat.content = payload, Chat.name = Nothing })
       Req.Assistant -> Right (Chat.Assistant { Chat.content = payload, Chat.name = Nothing })
       Req.System    -> Left "system role belongs in Request.systemPrompt, not Request.messages"

-- | Translate OpenAI's 'Chat.ChatCompletionObject' to 'Resp.Response'.
mapResponse :: UTCTime -> UTCTime -> Chat.ChatCompletionObject -> Resp.Response
mapResponse start end obj = Resp.Response
  { Resp.content   = extractText (obj ^. #choices)
  , Resp.model     = Model.Model (modelText (obj ^. #model))
  , Resp.usage     = Just (mapUsage (obj ^. #usage))
  , Resp.cost      = Nothing
  , Resp.provider  = "openai.chat.api"
  , Resp.latencyMs = millisBetween start end
  }

modelText :: OpenAIModels.Model -> Text
modelText (OpenAIModels.Model t) = t

extractText :: Vector Chat.Choice -> Text
extractText = Text.concat . map (Chat.messageToContent . Chat.message) . Vector.toList

mapUsage :: OpenAIUsage.Usage Chat.CompletionTokensDetails Chat.PromptTokensDetails -> Usage.Usage
mapUsage u = Usage.Usage
  { Usage.inputTokens       = u ^. #prompt_tokens
  , Usage.outputTokens      = u ^. #completion_tokens
  , Usage.cachedInputTokens = (u ^. #prompt_tokens_details) >>= (^. #cached_tokens)
  , Usage.reasoningTokens   = (u ^. #completion_tokens_details) >>= (^. #reasoning_tokens)
  }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
```

Acceptance for milestone 3: `cabal build all` succeeds. `cabal repl baikai-openai`
followed by `:i Baikai.Provider.OpenAI.Api.OpenAIApi` prints the data declaration and the
`Provider` instance.

### Milestone 4: smoke test

Scope: add a `baikai-smoke` test-suite (declared in `baikai/baikai.cabal`) that issues
real requests against both providers when the appropriate environment variable is set,
and is silently skipped when it is not. The test verifies that the response content is
non-empty and that `usage.inputTokens > 0` and `usage.outputTokens > 0`. Because the test
exercises both vendor packages, it depends on `baikai`, `baikai-claude`, and
`baikai-openai` so the test binary can import both `Baikai.Provider.Claude.Api` and
`Baikai.Provider.OpenAI.Api`.

Add to `baikai/baikai.cabal`:

```cabal
test-suite baikai-smoke
  import:           common-options
  type:             exitcode-stdio-1.0
  hs-source-dirs:   test
  main-is:          Smoke.hs
  build-depends:    baikai
                  , baikai-claude
                  , baikai-openai
                  , base
                  , lens
                  , text
                  , vector
  default-language: GHC2024
```

Create `baikai/test/Smoke.hs`:

```haskell
{-# LANGUAGE OverloadedLabels  #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import           Baikai.Auth                (ApiKeySource (..))
import           Baikai.Model               (Model (..))
import           Baikai.Provider            (runRequest)
import           Baikai.Provider.Claude.Api (claudeApi)
import           Baikai.Provider.OpenAI.Api (openaiApi)
import qualified Baikai.Request             as Req
import qualified Baikai.Response            as Resp
import qualified Baikai.Usage               as Usage
import           Control.Lens               ((^.))
import           Control.Monad              (unless, when)
import           Data.Maybe                 (isJust)
import qualified Data.Text                  as Text
import qualified Data.Vector                as Vector
import           System.Environment         (lookupEnv)
import           System.Exit                (exitFailure)
import           System.IO                  (hPutStrLn, stderr)

main :: IO ()
main = do
  hadAny <- mapM runCase cases
  unless (or hadAny) $
    hPutStrLn stderr "[baikai-smoke] no provider keys set; skipping all cases."

cases :: [(String, String, IO Resp.Response)]
cases =
  [ ( "ANTHROPIC_KEY"
    , "claude-haiku-4-5-20251001"
    , do
        p <- claudeApi (ApiKeyEnv "ANTHROPIC_KEY")
        runRequest p (sampleRequest "claude-haiku-4-5-20251001")
    )
  , ( "OPENAI_KEY"
    , "gpt-4o-mini"
    , do
        p <- openaiApi (ApiKeyEnv "OPENAI_KEY")
        runRequest p (sampleRequest "gpt-4o-mini")
    )
  ]

runCase :: (String, String, IO Resp.Response) -> IO Bool
runCase (envVar, modelName, act) = do
  mKey <- lookupEnv envVar
  case mKey of
    Nothing -> do
      hPutStrLn stderr $ "[baikai-smoke] " <> envVar <> " unset; skipping " <> modelName <> "."
      pure False
    Just _ -> do
      resp <- act
      let contentOk = not (Text.null (resp ^. #content))
          uOk      = case resp ^. #usage of
            Nothing -> False
            Just u  -> u ^. #inputTokens > 0 && u ^. #outputTokens > 0
      when (not contentOk || not uOk) $ do
        hPutStrLn stderr $ "[baikai-smoke] failed for " <> modelName <> "."
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] " <> modelName <> " ok; usage present = " <> show (isJust (resp ^. #usage))
      pure True

sampleRequest :: Text.Text -> Req.Request
sampleRequest m = Req.Request
  { Req.model        = Model m
  , Req.messages     = Vector.singleton
      Req.Message
        { Req.role    = Req.User
        , Req.content = "Reply with the single word: pong."
        }
  , Req.maxTokens    = 16
  , Req.temperature  = Just 0.0
  , Req.systemPrompt = Just "You are terse."
  }
```

Note on the polymorphic provider constructors: the `cases` list above is annotated as
`[(String, String, IO Resp.Response)]`, which pins the action type to `IO`; because `IO`
is a `MonadIO`, the polymorphic `claudeApi :: MonadIO m => ApiKeySource -> m ClaudeApi`
and `openaiApi :: MonadIO m => ApiKeySource -> m OpenAIApi` resolve to `IO ClaudeApi` and
`IO OpenAIApi` respectively, so no `liftIO` is needed inside the test body.

Acceptance for milestone 4: with no keys set, `cabal test all` runs `baikai-smoke` to
completion and prints two skip lines on stderr. With at least one key set, the
corresponding case runs and the test passes only if content is non-empty and both token
counters are positive.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai`. Enter the Nix development
shell first:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
```

Verify the `mori`-registered upstream packages so the cabal.project fallback can use the
exact on-disk paths if needed:

```bash
mori registry show claude --full
mori registry show openai --full
```

Expected (truncated):

```text
project: claude
source: /Users/shinzui/Keikaku/hub/haskell/claude-project/claude
packages: claude

project: openai
source: /Users/shinzui/Keikaku/hub/haskell/openai-project/openai
packages: openai
```

After creating the two new cabal files, updating `cabal.project`, and editing
`baikai/baikai.cabal` (and, if needed, dropping in the `source-repository-package`
fallback), build everything:

```bash
cabal build all
```

Expected first-run transcript (abridged):

```text
Resolving dependencies...
Build profile: -w ghc-9.12 -O1
In order, the following will be built (use -v for more details):
 - baikai-0.1.0.0 (lib) (first run)
 - baikai-claude-0.1.0.0 (lib) (first run)
 - baikai-openai-0.1.0.0 (lib) (first run)
 - baikai-0.1.0.0 (test:baikai-smoke) (first run)
Configuring library for baikai-0.1.0.0...
Preprocessing library for baikai-0.1.0.0...
Building library for baikai-0.1.0.0...
[ 1 of  7] Compiling Baikai.Auth ...
...
Configuring library for baikai-claude-0.1.0.0...
Building library for baikai-claude-0.1.0.0...
[ 1 of  1] Compiling Baikai.Provider.Claude.Api ...
Configuring library for baikai-openai-0.1.0.0...
Building library for baikai-openai-0.1.0.0...
[ 1 of  1] Compiling Baikai.Provider.OpenAI.Api ...
Linking ...
```

Run all tests with no keys set; the smoke test should be skipped without failing:

```bash
unset ANTHROPIC_KEY OPENAI_KEY
cabal test all --test-show-details=streaming
```

Expected transcript (abridged):

```text
Running 1 test suites...
Test suite baikai-smoke: RUNNING...
[baikai-smoke] ANTHROPIC_KEY unset; skipping claude-haiku-4-5-20251001.
[baikai-smoke] OPENAI_KEY unset; skipping gpt-4o-mini.
[baikai-smoke] no provider keys set; skipping all cases.
Test suite baikai-smoke: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

Run the live smoke against both providers (replace the placeholder tokens with real keys):

```bash
ANTHROPIC_KEY=sk-ant-... OPENAI_KEY=sk-... cabal test all --test-show-details=streaming
```

Expected transcript (abridged):

```text
Test suite baikai-smoke: RUNNING...
[baikai-smoke] claude-haiku-4-5-20251001 ok; usage present = True
[baikai-smoke] gpt-4o-mini ok; usage present = True
Test suite baikai-smoke: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

To explore manually, drop into the library repl and exercise the Claude provider:

```bash
ANTHROPIC_KEY=sk-ant-... cabal repl baikai
```

Inside the repl:

```text
ghci> :set -XOverloadedStrings -XOverloadedLabels
ghci> import Baikai.Auth
ghci> import Baikai.Provider
ghci> import Baikai.Provider.Claude.Api
ghci> import Baikai.Model
ghci> import qualified Baikai.Request as Req
ghci> import qualified Data.Vector as V
ghci> import Control.Lens ((^.))
ghci> p <- claudeApi (ApiKeyEnv "ANTHROPIC_KEY")
ghci> let req = Req.Request { Req.model = Model "claude-haiku-4-5-20251001", Req.messages = V.singleton (Req.Message { Req.role = Req.User, Req.content = "ping" }), Req.maxTokens = 16, Req.temperature = Just 0, Req.systemPrompt = Just "be terse" }
ghci> r <- runRequest p req
ghci> r ^. #content
"pong"
ghci> r ^. #usage
Just (Usage {inputTokens = 14, outputTokens = 4, cachedInputTokens = Nothing, reasoningTokens = Nothing})
```


## Validation and Acceptance

The acceptance criterion is that the example program described in Purpose / Big Picture
compiles cleanly, and when run with a valid API key it produces a `Baikai.Response.Response`
value whose `content` is a non-empty `Text` and whose `usage` is a `Just Usage` carrying
strictly-positive `inputTokens` and `outputTokens`. The same must hold for both providers:
swapping `claudeApi` for `openaiApi` (with the model string adjusted to `gpt-4o-mini` and
the env var to `OPENAI_KEY`) must also satisfy the criterion.

The mechanical version of this acceptance is the `baikai-smoke` test-suite from milestone
4. To validate, run:

```bash
ANTHROPIC_KEY=sk-ant-... OPENAI_KEY=sk-... cabal test all --test-show-details=streaming
```

Expected:

```text
Test suite baikai-smoke: RUNNING...
[baikai-smoke] claude-haiku-4-5-20251001 ok; usage present = True
[baikai-smoke] gpt-4o-mini ok; usage present = True
Test suite baikai-smoke: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

Both lines must say `ok`. If either line is missing — for example because the key was not
exported — the suite skips that case and the run does not constitute validation; rerun
with the missing key in scope.

Additionally, with no keys set the suite must report skips and still exit zero:

```bash
unset ANTHROPIC_KEY OPENAI_KEY
cabal test all --test-show-details=streaming
```

Expected last lines:

```text
[baikai-smoke] no provider keys set; skipping all cases.
Test suite baikai-smoke: PASS
```

A failure mode this acceptance specifically catches: if `mapResponse` were to set
`usage = Nothing`, the post-check `u ^. #inputTokens > 0` would fall into the `Nothing`
branch and exit non-zero. If the upstream returned an empty content block, the
`Text.null` check would also exit non-zero. These are the two regressions most likely to
slip past `cabal build`.


## Idempotence and Recovery

Re-running `cabal build all` and `cabal test all` is safe. Cabal's build is incremental
and produces the same artifacts on repeat invocations. The smoke test is read-only against
both upstream APIs in the sense that no resource is created, mutated, or deleted —
however, it does cost money: each successful run charges a tiny number of input and output
tokens against the API key's account. Use `claude-haiku-4-5-20251001` for the Anthropic
case and `gpt-4o-mini` for the OpenAI case to keep the per-run cost negligible (well under
one US cent at the time of writing).

Common failure modes and how to recover:

- HTTP 401 from either provider: the API key environment variable resolved to an invalid
  or expired token. Confirm the variable is exported in the current shell (`echo $ANTHROPIC_KEY | head -c 6`),
  rotate the key in the upstream dashboard if needed, and re-run.
- HTTP 404 with a model-not-found message: the model string in the request does not exist
  for the account's region or tier. Re-check the spelling and try the documented
  smallest-tier model name. The plan deliberately pins
  `claude-haiku-4-5-20251001` and `gpt-4o-mini`; if either is sunset, pick the next
  available cheap model and update both the smoke test and the example.
- `RequestInvalid "system role belongs in Request.systemPrompt..."`: the caller passed a
  `Message { role = System }` inside `Request.messages`. Move that text to
  `Request.systemPrompt` and re-run. This is intentional per the Decision Log.
- `ProviderError "env var ANTHROPIC_KEY is not set"` thrown from `claudeApi`: the
  `ApiKeyEnv` lookup found nothing. Export the variable, or pass `ApiKeyLiteral` for one-
  off experiments.
- Build failure complaining that `claude` or `openai` is unknown: the Nix-provided
  `ghc912` package set does not contain that package. Apply the `cabal.project`
  `source-repository-package` fallback shown in milestone 1.

There is nothing destructive to roll back: this plan only adds files and small cabal
edits. To unwind, delete the two new package directories `baikai-claude/` and
`baikai-openai/` (which contain `baikai-claude.cabal`, `baikai-openai.cabal`, and their
respective `src/Baikai/Provider/.../Api.hs` files), delete `baikai/src/Baikai/Auth.hs` and
`baikai/test/Smoke.hs`, and revert the `baikai/baikai.cabal` and `cabal.project` diffs to
their EP-1 state.


## Interfaces and Dependencies

This plan introduces no new external services beyond the two upstream APIs already
implied by EP-1's master plan. The dependency surface is split across three cabal
components.

**Core package (`baikai`)** gains one new exposed module (`Baikai.Auth`) and no new
`build-depends` — `Baikai.Auth` uses only `base` and `text`, both already present.

**`baikai-claude` package** depends on:

- `base >=4.20 && <5`: the standard library.
- `baikai`: for `Baikai.Auth.ApiKeySource`, `Baikai.Provider.Provider`,
  `Baikai.Request.Request`, `Baikai.Response.Response`, `Baikai.Usage.Usage`,
  `Baikai.Model.Model`, and `Baikai.Error.BaikaiError`.
- `claude`: the Mercury Technologies Haskell binding for Anthropic's Messages API. Used
  for `Claude.V1.getClientEnv`, `Claude.V1.makeMethods`, and the request/response types in
  `Claude.V1.Messages` (`CreateMessage`, `_CreateMessage`, `Message`, `Role`, `Content`,
  `SystemPrompt`, `MessageResponse`, `ContentBlock`, `Usage`).
- `http-client` and `http-client-tls`: transitive runtime dependencies pulled in by
  `claude`'s servant-based client. Listed explicitly so that direct uses (e.g. tweaking
  the `ClientEnv` later) do not require an additional cabal edit.
- `servant-client`: the underlying RPC machinery used by `claude`. Listed explicitly for
  the same reason.
- `text ^>=2.1`: for `Data.Text.Text` in the provider module.
- `time`: `Data.Time.Clock.getCurrentTime` and `diffUTCTime` for latency measurement.
- `vector`: the Claude `Vector Content` and `Vector ContentBlock` shapes use
  `Data.Vector.Vector`.

**`baikai-openai` package** depends on:

- `base >=4.20 && <5`: the standard library.
- `baikai`: same shared types as above.
- `openai`: the Mercury Technologies Haskell binding for OpenAI. Used for
  `OpenAI.V1.getClientEnv`, `OpenAI.V1.makeMethods`, and the types in
  `OpenAI.V1.Chat.Completions` (`CreateChatCompletion`, `_CreateChatCompletion`,
  `Message`, `Content`, `ChatCompletionObject`, `Choice`, `messageToContent`,
  `CompletionTokensDetails`, `PromptTokensDetails`), `OpenAI.V1.Models.Model`, and
  `OpenAI.V1.Usage.Usage`.
- `http-client` and `http-client-tls`: transitive dependencies of `openai`'s servant
  client.
- `servant-client`: same justification as above.
- `text ^>=2.1`: for `Data.Text.Text`.
- `time`: latency measurement.
- `vector`: `Vector Choice` and `Vector Content` shapes.

The module-level signatures this plan establishes:

```haskell
module Baikai.Auth
data ApiKeySource = ApiKeyLiteral !Text | ApiKeyEnv !String
resolveApiKey :: MonadIO m => ApiKeySource -> m Text

module Baikai.Provider.Claude.Api
data ClaudeApi = ClaudeApi { methods :: !Claude.V1.Messages.Methods }
claudeApi :: MonadIO m => Baikai.Auth.ApiKeySource -> m ClaudeApi
instance Baikai.Provider.Provider ClaudeApi

module Baikai.Provider.OpenAI.Api
data OpenAIApi = OpenAIApi { methods :: !OpenAI.V1.Chat.Completions.Methods }
openaiApi :: MonadIO m => Baikai.Auth.ApiKeySource -> m OpenAIApi
instance Baikai.Provider.Provider OpenAIApi
```

The cabal wiring spans three changes: a small diff to `baikai/baikai.cabal` (adding
`Baikai.Auth` and the new `baikai-smoke` test-suite), a small diff to repository-root
`cabal.project` (adding the two new packages), and two brand-new cabal files for the
vendor packages.

Apply this diff to `baikai/baikai.cabal`:

```diff
 library
   import: common-options
   hs-source-dirs: src
   exposed-modules:
     Baikai
     Baikai.Prelude
+    Baikai.Auth

   build-depends:
     base >=4.20 && <5,
     generic-lens,
     lens ^>=5.3,
     text ^>=2.1,
+
+test-suite baikai-smoke
+  import: common-options
+  type: exitcode-stdio-1.0
+  hs-source-dirs: test
+  main-is: Smoke.hs
+  build-depends:
+    , baikai
+    , baikai-claude
+    , baikai-openai
+    , base >=4.20 && <5
+    , lens ^>=5.3
+    , text ^>=2.1
+    , vector
```

(EP-1's actual `exposed-modules` list may end up larger than the two shown here once the
six core modules are added; `Baikai.Auth` is appended whatever the current list looks
like. If the on-disk cabal file uses comma-first formatting, match it.)

Apply this diff to repository-root `cabal.project`:

```diff
 packages:
   baikai
+  baikai-claude
+  baikai-openai
```

Create `baikai-claude/baikai-claude.cabal` with the following contents:

```cabal
cabal-version: 3.4
name: baikai-claude
version: 0.1.0.0
synopsis: Anthropic Claude providers for the baikai abstraction
description:
  Wraps the claude Haskell package as a Baikai Provider for both the Anthropic API and the
  claude -p CLI.
license: BSD-3-Clause
license-file: ../LICENSE
author: Nadeem Bitar
maintainer: nadeem@gmail.com
copyright: (c) 2026 Nadeem Bitar
build-type: Simple

common common-options
  ghc-options:
    -Wall
    -Wcompat
    -Widentities
    -Wincomplete-uni-patterns
    -Wincomplete-record-updates
    -Wredundant-constraints
    -fhide-source-paths
    -Wmissing-export-lists
    -Wpartial-fields
    -Wmissing-deriving-strategies

  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

library
  import: common-options
  hs-source-dirs: src
  exposed-modules:
    Baikai.Provider.Claude.Api

  build-depends:
    , base >=4.20 && <5
    , baikai
    , claude
    , http-client
    , http-client-tls
    , servant-client
    , text ^>=2.1
    , time
    , vector
```

Create `baikai-openai/baikai-openai.cabal` with the structurally-identical file below
(`openai` swapped for `claude` and the exposed module changed):

```cabal
cabal-version: 3.4
name: baikai-openai
version: 0.1.0.0
synopsis: OpenAI providers for the baikai abstraction
description:
  Wraps the openai Haskell package as a Baikai Provider for OpenAI's Chat Completions API.
license: BSD-3-Clause
license-file: ../LICENSE
author: Nadeem Bitar
maintainer: nadeem@gmail.com
copyright: (c) 2026 Nadeem Bitar
build-type: Simple

common common-options
  ghc-options:
    -Wall
    -Wcompat
    -Widentities
    -Wincomplete-uni-patterns
    -Wincomplete-record-updates
    -Wredundant-constraints
    -fhide-source-paths
    -Wmissing-export-lists
    -Wpartial-fields
    -Wmissing-deriving-strategies

  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings

library
  import: common-options
  hs-source-dirs: src
  exposed-modules:
    Baikai.Provider.OpenAI.Api

  build-depends:
    , base >=4.20 && <5
    , baikai
    , openai
    , http-client
    , http-client-tls
    , servant-client
    , text ^>=2.1
    , time
    , vector
```

If the Nix-provided `ghc912` package set is missing `claude` or `openai`, additionally
apply the milestone-1 fallback to `cabal.project`:

```diff
 packages:
   baikai
   baikai-claude
   baikai-openai
+
+source-repository-package
+  type: file+noindex
+  location: /Users/shinzui/Keikaku/hub/haskell/claude-project/claude
+
+source-repository-package
+  type: file+noindex
+  location: /Users/shinzui/Keikaku/hub/haskell/openai-project/openai
```

EP-1's `Baikai.Provider.Provider` typeclass remains the integration seam: any caller that
holds an existentially-quantified `Provider p => p` value (or a future
`SomeProvider`-style wrapper introduced by a later plan) can now bind either of the two
new constructors without changing call sites. Cost computation in `Baikai.Response.Response.cost`
is intentionally `Nothing` from these providers; EP-4 will introduce a wrapping provider
or post-processing pipeline that fills it in based on `usage`, `model`, and a price table.


## Revisions

2026-05-13: Restructured EP-2 to create two new cabal packages (`baikai-claude`,
`baikai-openai`) instead of adding modules to the single `baikai` package. Moved
`Baikai.Auth` into `baikai` core. Updated `cabal.project` to declare all three packages.
Driver: the multi-package architecture decision recorded in
`docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.
The rationale for splitting (keeping each vendor's Servant client closure out of consumers
who only need the other vendor) is reproduced in this plan's Decision Log so EP-2 remains
self-contained.

2026-05-13: Generalised `claudeApi`, `openaiApi`, `resolveApiKey`, and the `runRequest`
instance method bodies from concrete `IO` to `MonadIO m =>`. Added a single `liftIO` at the
top of each instance method body to lift the existing IO-typed work. Driver: the MonadIO
decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision
Log on the same date.
