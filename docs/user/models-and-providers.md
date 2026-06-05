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

Models.anthropic_claude_haiku_4_5
Models.anthropic_claude_haiku_4_5_20251001
Models.anthropic_claude_opus_4_7
Models.anthropic_claude_sonnet_4_6
Models.deepseek_deepseek_chat
Models.deepseek_deepseek_reasoner
Models.openai_gpt_4o
Models.openai_gpt_4o_mini
Models.openai_o1
Models.openai_o1_mini
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

Per-model `compat` overrides are supported but rarely needed:
EP-5's `baseUrl` auto-detection covers every shipped host.

After editing, re-run `cabal run baikai-gen-models` and commit both
the JSON change and the regenerated `Baikai.Models.Generated.hs`.

## Hand-rolled models

You don't need a catalog entry to dispatch against a host. `_Model`
is an empty base; fill in the fields and pass it directly:

```haskell
import Baikai

llama :: Model
llama =
  _Model
    { modelId = "meta-llama/Meta-Llama-3-8B-Instruct-Turbo"
    , name = "Llama 3 8B Instruct Turbo"
    , api = OpenAIChatCompletions
    , provider = "together"
    , baseUrl = "https://api.together.xyz"
    , maxOutputTokens = 64
    }
```

The OpenAI provider auto-detects the compat record from the
`baseUrl` (the `api.together.xyz` host name maps to
`ThinkingFormatTogether`, for example). Override `compat`
explicitly if you need something the auto-detection doesn't
cover.

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
        _Model { … }
      opts key = _Options & #apiKey .~ Just (ApiKeyLiteral key)

  -- All three dispatch through the same registered handler.
  _ <- completeRequest openai   ctx (opts openaiKey)
  _ <- completeRequest deepseek ctx (opts deepseekKey)
  _ <- completeRequest llama    ctx (opts togetherKey)
  pure ()
```

The `MultiHostSmoke` module under `baikai-smoke/test/` is a working
example.

## The registry

`Baikai.Provider.Registry` maps an `Api` tag to an `ApiProvider`.
Simple scripts can use the process-global convenience registry: each
vendor package's `register :: IO ()` installs itself under a specific
`Api` tag, and `completeRequest` / `streamRequest` dispatch through
that global registry.

Applications and tests that need isolated handler sets can construct an
explicit registry with `newProviderRegistry`, register handlers with
`registerApiProviderWith` or a provider package's `registerWithRegistry`,
and dispatch through `completeRequestWith` / `streamRequestWith`.
Within one registry, registering a second handler for the same `Api` tag
replaces the first. Keep multiple configured handler sets alive by using
multiple `ProviderRegistry` values and selecting the registry at call time.

| `Api` tag                  | Registered by                       |
|----------------------------|-------------------------------------|
| `AnthropicMessages`        | `Baikai.Provider.Claude.Api`        |
| `AnthropicMessagesCli`     | `Baikai.Provider.Claude.Cli`        |
| `OpenAIChatCompletions`    | `Baikai.Provider.OpenAI.Api`        |
| `OpenAICompletionsCli`     | `Baikai.Provider.OpenAI.Cli`        |
| `Custom !Text`             | Any caller — register your own.     |

Both global and explicit dispatch look the handler up by the model's
`api` tag. Unregistered tag -> `Baikai.Error.ProviderError` for
blocking calls; `streamRequest` / `streamRequestWith` return a terminal
error event.

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
  ( ApiProvider (..)
  , completeRequestWith
  , newProviderRegistry
  , registerApiProvider
  , registerApiProviderWith
  )
import qualified Streamly.Data.Stream as Stream

myProvider :: ApiProvider
myProvider =
  ApiProvider
    { apiTag = Custom "my-llm-host"
    , stream = \model ctx opts -> Stream.fromList (myStreamProducer model ctx opts)
    , complete = \model ctx opts -> myCompleteProducer model ctx opts
    }

myModel :: Model
myModel = _Model
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
  ApiProvider
    { apiTag = Custom "my-llm-host"
    , stream = liftCompleteToStream myCompleteProducer
    , complete = myCompleteProducer
    }
```

This produces a synthetic one-shot stream (one `TextDelta` with
the whole response, then `EventDone`), matching how the CLI
providers work.

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
