---
type: Reference
title: Models & Providers
description: Reference model records, the generated catalog, provider registries, and compatibility.
docId: DOC-7
tags: [models, providers, catalog, registry, compatibility]
generated:
  by: human:nadeem
  at: 2026-08-27T23:10:08Z
---

# Models & Providers

A `Model` record is everything baikai needs to dispatch a request:
which API to use, which host to call, what the per-million-token
costs are, what the context window and output cap are, and which
compatibility quirks apply. The generated catalog
(`Baikai.Models.Generated`) ships one ready-made `Model` per
shipped catalog entry; you can also hand-roll one for a host the
catalog doesn't cover.

## The generated catalog

```haskell
import Baikai.Models.Generated qualified as Models

Models.anthropic_claude_opus_4_8
Models.anthropic_claude_sonnet_4_6
Models.anthropic_claude_haiku_4_5
Models.anthropic_claude_fable_5
Models.deepseek_deepseek_chat
Models.deepseek_deepseek_reasoner
Models.openai_gpt_5_5
Models.openai_gpt_5_mini
Models.openai_gpt_4o_mini
Models.openai_o3
Models.openrouter_anthropic_claude_sonnet_4
Models.openrouter_openai_gpt_4o_mini
```

The identifiers are `<provider>_<modelId>` with non-identifier
characters (slashes, dashes, dots) replaced by underscores. Each
value is a fully populated `Model` carrying the right `Api` tag,
`baseUrl`, costs, context window, max-output cap, and compat
record. Use it directly or override fields with a record update:

```haskell
let model =
      Models.openai_gpt_4o_mini
        { maxOutputTokens = 256
        , baseUrl = "https://my-openai-proxy.example.com"
        }
```

The catalog is auto-generated. Source of truth: the JSON files
under `baikai/data/models/`. Regenerate after editing them:

```bash
cabal run baikai-gen-models
```

(Run from anywhere in the repo — the executable locates
`baikai.cabal` by walking up from the current directory.) The
`CatalogSpec` test in `cabal test all` catches drift between the
JSON sources and the committed `Baikai.Models.Generated`.

## Adding a model to the catalog

Drop or extend a JSON file under `baikai/data/models/`. Each file
declares one provider with its `baseUrl`, `api` tag, optional
`compat` block (or `"auto"`), and a list of model entries:

```json
{
  "provider": "openai",
  "baseUrl": "https://api.openai.com",
  "api": "openai-chat-completions",
  "compat": "auto",
  "models": [
    {
      "id": "gpt-4o-mini",
      "name": "GPT-4o Mini",
      "input": ["text", "image"],
      "cost": { "input": 0.15, "output": 0.6 },
      "contextWindow": 128000,
      "maxOutputTokens": 16384,
      "enabled": true
    }
  ]
}
```

A per-model `compat` block overrides the file-level directive. Every
**Anthropic** entry carries one and must: `baseUrl` auto-detection knows
the host but cannot know the model generation, and which extended-thinking
wire shape a generation accepts — and whether it accepts sampling
parameters — is a fact of the generation:

```json
    {
      "id": "claude-sonnet-5",
      "name": "Claude Sonnet 5",
      "reasoning": true,
      "input": ["text", "image"],
      "cost": { "input": 3.0, "output": 15.0 },
      "contextWindow": 1000000,
      "maxOutputTokens": 128000,
      "compat": {
        "kind": "anthropic-messages",
        "thinkingStyle": "adaptive",
        "supportsSamplingParameters": false
      },
      "enabled": true
    }
```

`baikai-gen-models` **refuses** an `anthropic-messages` entry that arrives
without one, rather than falling back to auto-detection. The OpenAI side
needs no per-model block; `"compat": "auto"` covers every shipped host.

The facts come from `anthropicInclude` in
`baikai/fetch/FetchModelsCore.hs`, the one place a human vets an Anthropic
id into the catalog, so a wholesale refresh cannot lose them. Adding a
generation means adding an entry there with a dated comment naming its
source. See
[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md).

After editing, re-run `cabal run baikai-gen-models` and commit both
the JSON change and the regenerated `Baikai.Models.Generated.hs`.

## Hand-rolled models

You don't need a catalog entry to dispatch against a host. A model needs
three things to dispatch — the `Api` tag the registry looks up, the model
id the host knows, and the base URL — and `mkModel` takes exactly those:

```haskell
mkModel :: Api -> Text -> Text -> Model

deepseek :: Model
deepseek = mkModel OpenAIChatCompletions "deepseek-chat" "https://api.deepseek.com"
```

`name` defaults to the model id and `provider` to `renderApi` of the tag.
For prices, context and output caps, or an explicit `compat`, start from
`emptyModel` and fill in the fields:

```haskell
import Baikai

llama :: Model
llama =
  emptyModel
    { modelId = "meta-llama/Meta-Llama-3-8B-Instruct-Turbo"
    , name = "Llama 3 8B Instruct Turbo"
    , api = OpenAIChatCompletions
    , provider = "together"
    , baseUrl = "https://api.together.xyz"
    , maxOutputTokens = 64
    }
```

Whichever you start from, set `api`: `emptyModel.api` is `Custom ""`,
which is registered to nothing and dispatches nowhere. That is the one
mistake a blank base makes easy, and the failure says so by name rather
than reporting an empty tag.

The OpenAI provider auto-detects the compat record from the
`baseUrl` (the `api.together.xyz` host name maps to
`ThinkingFormatTogether`, for example). Override `compat`
explicitly if you need something the auto-detection doesn't
cover.

Two things auto-detection cannot know, because they are facts about the
*model generation* rather than the host:

- **`reasoning` defaults to `False`.** `Options.thinking` reaches the
  wire only for a model that advertises reasoning support, on either API
  provider. A level on a hand-rolled model that left `reasoning` at its
  default is dropped, and the drop is recorded as
  `thinking_dropped_unsupported_model` in the call's evidence. Set
  `reasoning = True` if the model can reason.

- **A hand-rolled Anthropic model naming an adaptive-era id needs its
  compat record.** `CompatNone` means the budget thinking shape with
  sampling parameters supported, which every generation before Opus 4.7
  accepts. If your `modelId` is `claude-sonnet-5`, `claude-opus-4-7`,
  `claude-opus-4-8` or `claude-fable-5`, write:

  ```haskell
  compat =
    CompatAnthropicMessages
      defaultAnthropicMessagesCompat
        { thinkingStyle = AnthropicThinkingAdaptive
        , supportsSamplingParameters = False
        }
  ```

  or start from a catalog model's `compat` value. baikai does not guess
  this from the model id: it used to, from a hand-written prefix table,
  and the table did not know `claude-sonnet-5`. See
  [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md).

## Base URLs

`baseUrl` is the **API root**: the host, or the prefix under which a host
mounts the API. baikai appends the endpoint path itself —
`/v1/chat/completions`, `/v1/messages`, `/v1/embeddings` — so you never
write it.

The catalog's own values show the shape: `https://api.openai.com`,
`https://api.anthropic.com`, `https://openrouter.ai/api`. A base URL that
already ends in `/v1` is accepted and that one segment is removed before
composing, so `https://api.deepseek.com/v1` — the spelling every OpenAI
SDK teaches — requests `/v1/chat/completions` rather than
`/v1/v1/chat/completions`. Only a trailing `/v1` is treated this way;
`/v10` and `/v1beta` are ordinary path segments.

The host name in this field decides two things beyond where the request
goes: which environment variable supplies the API key when you set none,
and which per-host compatibility record applies. Everything after the
first `/`, `?` or `#` is path, query or fragment and cannot change the
host — a base URL such as `https://proxy.example.com/v1?u=@api.openai.com`
names `proxy.example.com`, resolves no key and gets no vendor compat
record.

Some shapes are refused before anything is sent, each with a message
saying what to write instead:

- **No scheme, or a scheme other than `http`/`https`.** A scheme-less URL
  would otherwise be sent over plaintext HTTP with your key attached.
- **Credentials in the URL** (`https://user:pw@host/`). They are never
  sent. Use `Options.apiKey` for the API key, or `Options.headers` for a
  gateway's own header.
- **A query string.** baikai composes the request path itself and does
  not support per-host query parameters such as `?api-version=`. If a
  host needs one, front it with a gateway that adds it.
- **A fragment**, which is not part of a request at all.
- **A full endpoint URL as the base** (`https://h/v1/chat/completions`),
  which is the API root plus the path baikai is about to append.

The refusal arrives as a normal in-band error — an `EventStart` followed
by an `EventError` whose category is `InvalidRequest` — and it happens
*before* a key is read from the environment, so a refused base URL never
causes a credential to be looked up. The message renders the URL without
its userinfo or query, so it is safe to log.

Two more things a request will not do. It **never follows a redirect**: a
chat or messages POST has no legitimate 3xx, and following one would
re-send your bearer token to whatever host the `Location` header names, so
a 3xx is delivered as the terminal error carrying its status. And
`print`ing an `Options`, a `Model` or a `Response` **redacts** the value
of any header whose name looks credential-carrying, so a gateway key you
put in `headers` does not reach your logs.

## Compatibility policy

`Compat`, `OpenAICompletionsCompat`, and `AnthropicMessagesCompat`
describe provider quirks: each field says whether a host accepts one
request shape, such as OpenAI-style reasoning controls, Anthropic cache
markers, or long cache retention. The compat record constructors are not
exported; start from `defaultOpenAICompletionsCompat` or
`defaultAnthropicMessagesCompat` and update only the fields you need.

Most callers should leave `compat = CompatNone`; providers then call
`openaiCompletionsCompatFor` or `anthropicMessagesCompatFor` and
auto-detect the record from `baseUrl`. Hand-rolled models and catalog
entries can carry an explicit override:

```haskell
let compat =
      defaultOpenAICompletionsCompat
        { supportsStrictMode = False
        , thinkingFormat = ThinkingFormatNone
        }

let model =
      emptyModel
        { modelId = "custom-chat"
        , api = OpenAIChatCompletions
        , baseUrl = "https://proxy.example.com"
        , compat = CompatOpenAICompletions compat
        }
```

Prefer starting from `defaultOpenAICompletionsCompat` or
`defaultAnthropicMessagesCompat` and using record updates. New hosts
may require new fields or enum constructors in later versions, and
record updates keep those changes easier to absorb than spelling out
every field manually.

## Reasoning effort

API callers select a provider-neutral reasoning preference through
`Options.thinking`:

```haskell
let opts = emptyOptions & #thinking .~ Just ThinkingXHigh
```

`ThinkingLevel` has six ordered values: `ThinkingMinimal`,
`ThinkingLow`, `ThinkingMedium`, `ThinkingHigh`, `ThinkingXHigh`, and
`ThinkingMax`. Their canonical spellings are `minimal`, `low`,
`medium`, `high`, `xhigh`, and `max`. Leaving `thinking = Nothing`
omits the reasoning control and lets the provider use its default.

Providers translate this shared vocabulary according to the request
shape selected by the model's compatibility record:

| Destination | Mapping |
|-------------|---------|
| Native OpenAI | Preserves all six canonical spellings in the final JSON request. |
| Anthropic adaptive thinking | Maps `minimal` to `low`, sends `low`, `medium`, `xhigh`, and `max` explicitly, and omits `high` because it is the provider default. |
| Anthropic budget thinking | Uses token budgets of 1024, 2048, 8192, 16384, 24576, and 32768 respectively. |
| DeepSeek, OpenRouter, and Together | Maps `minimal` to `low` and clamps `xhigh` and `max` to `high`. |
| Z.ai and Qwen | Sends the host's boolean “enable thinking” control; the requested level is not represented. |
| `ThinkingFormatNone` | Omits the control. |

The chosen model must still support reasoning: on **both** API
providers, a level on a model whose catalog entry says `reasoning =
False` sends no reasoning control at all and records
`thinking_dropped_unsupported_model`. That check runs before the host's
wire shape is consulted, because a host may speak a perfectly good
reasoning dialect while the model selected on it cannot reason —
`gpt-4o-mini` on OpenAI's own host, or `deepseek-chat` on DeepSeek's.

### Sampling parameters

`Options` carries five sampling controls. Which of them reach which API
is a fact of the API and of the model generation, and every drop is
recorded in the call's evidence rather than being silent:

| `Options` field | OpenAI Chat Completions | Anthropic Messages |
|---|---|---|
| `temperature` | sent | sent, unless the generation rejects it |
| `topP` | sent | sent, unless the generation rejects it |
| `seed` | sent | **no such field**, recorded as `sampling_dropped_unsupported_api` |
| `frequencyPenalty` | sent | **no such field**, same |
| `presencePenalty` | sent | **no such field**, same |

Anthropic's adaptive-era generations — `claude-sonnet-5`,
`claude-opus-4-7`, `claude-opus-4-8`, `claude-fable-5` — return a 400 for
`temperature`, `top_p` and `top_k`. baikai reads
`AnthropicMessagesCompat.supportsSamplingParameters` off the model's
catalog record, omits the parameters rather than sending a request it
knows will fail, and records
`sampling_dropped_unsupported_model` with the field names.

`Options.metadata` is forwarded by neither API provider. Anthropic's
`metadata` accepts only `user_id` and rejects other keys, so forwarding
an arbitrary map would trade a silent drop for a 400.

The batch `claude -p` and `codex exec` providers forward
`Options.thinking` as the app's reasoning-effort flag: `claude -p`
receives `--effort <level>` (mapping `minimal` to `low`, since the
`claude` CLI has no `minimal`) and `codex exec` receives `-c
model_reasoning_effort=<level>` for all six levels. Leaving `thinking =
Nothing` emits no effort flag. Interactive Claude Code and Codex
launches carry the same preference through
`InteractiveLaunchRequest.effort`; see
[Interactive Launches](interactive-launches.md#model-and-reasoning-effort).

## Multi-host on `openai-completions`

The same `Baikai.Provider.OpenAI.Api` handler serves every host
that speaks OpenAI Chat Completions. To target a second host,
register the handler once and pass a `Model` whose `api =
OpenAIChatCompletions` and `baseUrl` points at the host:

```haskell
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi

main :: IO ()
main = do
  OpenAIApi.register     -- one registration; serves every openai-compat host

  let openai = Models.openai_gpt_4o_mini
      deepseek = Models.deepseek_deepseek_chat
      llama = -- the hand-rolled record above
        emptyModel { … }
      opts key = emptyOptions & #apiKey .~ Just (ApiKeyLiteral key)

  -- All three dispatch through the same registered handler.
  _ <- completeRequest openai   ctx (opts openaiKey)
  _ <- completeRequest deepseek ctx (opts deepseekKey)
  _ <- completeRequest llama    ctx (opts togetherKey)
  pure ()
```

The `MultiHostSmoke` module under `baikai-smoke/test/` is a working
example.

Each host wants its own credential, and `Options.apiKey` is an
`ApiKeySource` rather than a bare string so you can say where the
credential comes from without reading it yourself:

| `ApiKeySource` | Means |
|---|---|
| `ApiKeyLiteral key` | this exact credential |
| `ApiKeyEnv name` | read the named environment variable |
| `ApiKeyEnvChain names` | read the first variable in the list that is set |

`ApiKeyEnvChain` is what a program that must accept both `OPENAI_API_KEY`
and a house-specific spelling wants. A variable that is set but empty is
not a key: it fails as an `AuthError` naming the variable, rather than
sending a blank credential and reporting the host's 401. Leaving `apiKey`
unset falls back to the per-host default variable for the model's
`baseUrl`. `Show` and `ToJSON` on `Options` render `ApiKeyLiteral` as
`<redacted>`, so a key does not reach your logs by being printed.

## The registry

`Baikai.Provider.Registry` maps an `Api` tag to an `ApiProvider`.
Simple scripts can use the process-global convenience registry: each
vendor package's `register :: IO ()` installs itself under a specific
`Api` tag, and `completeRequest` / `streamRequest` dispatch through
that global registry.

Applications and tests that need isolated handler sets build the registry
from the provider values each vendor package exports —
`claudeMessagesProvider`, `openaiChatProvider`, `claudeCliProvider cfg`,
`codexCliProvider cfg` — and dispatch through
`completeRequestWith` / `streamRequestWith`:

```haskell
registry <-
  newProviderRegistryFrom
    [ ClaudeApi.claudeMessagesProvider
    , OpenAIApi.openaiChatProvider
    ]
assertRegistered registry [AnthropicMessages, OpenAIChatCompletions]
```

`newProviderRegistry` builds an empty one and `registerApiProviderWith reg`
adds a handler to it later, which is what a test that swaps a provider
mid-run wants. Within one registry, registering a second handler for the
same `Api` tag replaces the first. Keep multiple configured handler sets
alive by using multiple `ProviderRegistry` values and selecting the
registry at call time.

`assertRegistered reg tags` throws once, at startup, naming every tag with
no handler. Without it the same mistake surfaces per call, as the
`ProviderUnavailable` response described below — later, and inside
whatever error handling the call site happens to have.

| `Api` tag                  | Registered by                       |
|----------------------------|-------------------------------------|
| `AnthropicMessages`        | `Baikai.Provider.Claude.Api`        |
| `AnthropicMessagesCli`     | `Baikai.Provider.Claude.Cli`        |
| `OpenAIChatCompletions`    | `Baikai.Provider.OpenAI.Api`        |
| `OpenAICompletionsCli`     | `Baikai.Provider.OpenAI.Cli`        |
| `Custom !Text`             | Any caller — register your own.     |

Both global and explicit dispatch look the handler up by the model's
`api` tag. An unregistered tag returns an error-shaped `Response` for
blocking calls, or a terminal `EventError` for streams, with
`errorInfo.category = ProviderUnavailable`.

The two `*Cli` tags drive local subprocesses (`claude -p` and
`codex exec`) rather than HTTP calls; their semantics differ from
the API providers in important ways — see
[CLI Providers](cli-providers.md).

## Custom providers

Register a handler under a `Custom` tag for any API baikai doesn't
ship:

```haskell
import Baikai
import Baikai.Provider.Registry
  ( ApiProvider
  , apiProviderWith
  , completeRequestWith
  , newProviderRegistry
  , registerApiProvider
  , registerApiProviderWith
  )
import qualified Streamly.Data.Stream as Stream

myProvider :: ApiProvider
myProvider =
  apiProviderWith
    (Custom "my-llm-host")
    (\model ctx opts -> Stream.fromList (myStreamProducer model ctx opts))
    (\model ctx opts -> myCompleteProducer model ctx opts)
```

`ApiProvider` exports its field selectors and no constructor, so you
start from `apiProviderWith` — the tag, the streaming producer, the
synchronous completer — and override the rest by record update. That is
what keeps a field added in a later release from breaking your build.
The two fields it fills in for you:

```haskell
myProvider :: ApiProvider
myProvider =
  apiProviderWith (Custom "my-llm-host") myStream myComplete
    -- What this provider would do with Options.thinking, asked before
    -- any request is built. Only the strict-evidence gate calls it; a
    -- provider with no reasoning controls answers honestly with the
    -- default, which is this.
    & #describeThinking .~ (\_model _opts -> noThinkingRequested)
    -- The highest strength this provider's evidence can reach. Declaring
    -- more than you deliver is the one way to make strict mode lie, so
    -- the default is the weakest answer.
    & #strengthCeiling .~ EvidenceRequestedOnly

myModel :: Model
myModel = emptyModel
  { modelId = "my-llm-1"
  , api = Custom "my-llm-host"
  , baseUrl = "https://my-llm.example.com"
  }

main :: IO ()
main = do
  registerApiProvider myProvider
  resp <- completeRequest myModel ctx opts
  print resp
```

For an isolated registry, keep the handler out of global state:

```haskell
main :: IO ()
main = do
  registry <- newProviderRegistry
  registerApiProviderWith registry myProvider
  resp <- completeRequestWith registry myModel ctx opts
  print resp
```

Implementing `stream` is the primary work — the simplest path is
to write a synchronous `complete` and lift it with
`Baikai.Stream.liftCompleteToStream`:

```haskell
myProvider =
  apiProviderWith
    (Custom "my-llm-host")
    (liftCompleteToStream myCompleteProducer)
    myCompleteProducer
```

This produces a synthetic one-shot stream (one `TextDelta` with
the whole response, then `EventDone`), matching how the CLI
providers work.

Both fields exist because a provider can lie about itself in exactly two
ways, and each is answered by a field the builder defaults to the honest
value. `describeThinking :: Model -> Options -> ThinkingTranslation` says
what this provider would do with `Options.thinking`; it is called only by
the pre-dispatch strict-evidence gate, never on an ordinary call. If your
provider does translate `Options.thinking` onto a wire field, return a
`ThinkingTranslation` describing what it becomes — built by the same
function that builds the request, so the two cannot drift apart.
`strengthCeiling :: EvidenceStrength` is the highest evidence strength
your transport can reach; the strict gate compares a caller's requirement
against it rather than against a table keyed by `Api`, which is what used
to answer `EvidenceRequestedOnly` for every `Custom` tag whatever the
transport actually observed. `EvidenceRequestedOnly` is the honest answer
for a provider that attaches no record or a minimal one, and such a
provider will still fail a strict caller at the terminal. Declare more
only with a test that drives the provider to it. See
[Model-Call Evidence](model-call-evidence.md).

## Cost & usage

Every successful call's `Response.message` is an assistant payload
carrying a `Usage`:

```haskell
data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cacheReadTokens :: !Natural
  , cacheWriteTokens :: !Natural
  , reasoningTokens :: !(Maybe Natural)
  , totalTokens :: !Natural
  , cost :: !Cost
  }
```

`Cost` is computed from the model's per-million-token rates
(`ModelCost.inputCost`, `outputCost`, `cacheReadCost`,
`cacheWriteCost`) and the token counts. CLI providers populate
everything with zero — they don't expose token usage.

`cacheReadTokens` and `cacheWriteTokens` are populated when you request
prompt caching via `Options.cacheRetention`. See
[Prompt Caching](prompt-caching.md) for the request-side preference, the
host-aware long/short downgrade, and a worked write-then-read example.
