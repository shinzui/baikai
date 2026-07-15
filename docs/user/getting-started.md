# Getting Started

baikai is a unified Haskell interface for AI providers. The same
`completeRequest` / `streamRequest` calls dispatch against Claude,
OpenAI, OpenAI-compatible hosts (DeepSeek, OpenRouter, Together, …)
or the `claude -p` / `codex exec` CLIs, depending on which `Model`
record you pass.

## Packages

| Package         | What's inside                                                                 |
|-----------------|-------------------------------------------------------------------------------|
| `baikai`        | The core surface: `Model`, `Context`, `Options`, `Tool`, the event stream, the registry, the generated model catalog. |
| `baikai-claude` | Anthropic Messages API + `claude -p` CLI providers. Exposes `register :: IO ()` per provider. |
| `baikai-openai` | OpenAI Chat Completions API + `codex exec` CLI providers. Same `register` shape. |
| `baikai-kit`    | Shared kit installer for tools that install local AI-agent skills and subagents from a git repository. |
| `baikai-smoke`  | Internal live test suite — useful as worked examples.                         |

You depend on `baikai` plus whichever vendor packages you need. The
vendor packages re-export nothing of their own; they just register
handlers into the central `Baikai.Provider.Registry` when their
`register` action runs.

## Install

baikai is not yet on Hackage. Pull it in via `cabal.project`:

```cabal
source-repository-package
    type: git
    location: https://github.com/shinzui/baikai
    tag: <commit>
    subdir: baikai baikai-claude baikai-openai
```

Then in your project's `.cabal` file:

```cabal
build-depends:
  , baikai
  , baikai-claude
  , baikai-openai
```

If your application also exposes a `kit` command, add the `baikai-kit`
subdirectory to the same git pin and add `baikai-kit` to
`build-depends`; see [Kit Packages](kit.md).

## Register providers

Each vendor package exposes a `register :: IO ()` convenience helper.
Call it once from `main` (or any equivalent startup point) before
dispatching a request through the global registry:

```haskell
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Baikai.Provider.OpenAI.Cli qualified as CodexCli

main :: IO ()
main = do
  ClaudeApi.register
  ClaudeCli.register
  OpenAIApi.register
  CodexCli.register
  -- … your code …
```

Registration is idempotent per `Api` tag: calling `register` twice
keeps the second handler. Only register the providers you actually
use; an unregistered API tag returns an error-shaped `Response` for
blocking calls, or a terminal `EventError` for streams, with
`errorInfo.category = ProviderUnavailable`.

For isolated tests or applications with more than one handler set,
construct a `ProviderRegistry` with `newProviderRegistryFrom` and
provider values such as `OpenAIApi.openaiChatProvider`, then dispatch
with `completeRequestWith` or `streamRequestWith`. Use
`assertRegistered` at startup to fail fast when an expected `Api` tag
has no handler.

## Your first call (text)

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Data.Text qualified as Text

main :: IO ()
main = do
  OpenAIApi.register
  text <- completeText Models.openai_gpt_4o_mini "Say hi."
  putStrLn (Text.unpack text)
```

`completeText` is the one-shot convenience wrapper: it builds a single
user-message context, uses `emptyOptions`, and returns
`flattenAssistantText (flattenAssistantBlocks resp)`. If the provider
returns an error-shaped response, it throws the `BaikaiError`.

## Your first call (blocking)

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Vector qualified as V

main :: IO ()
main = do
  OpenAIApi.register
  prompt <- userNow "Say hi."
  let ctx =
        emptyContext
          & #systemPrompt .~ Just "You are terse."
          & #messages .~ V.singleton prompt
      opts =
        emptyOptions
          & #maxTokens .~ Just 32
          & #temperature .~ Just 0.0
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print resp
```

`emptyContext` and `emptyOptions` are empty bases for record updates; the
`#field .~ value` syntax comes from `generic-lens`. `apiKey` is left
unset, so the OpenAI handler reads `OPENAI_API_KEY` and the Anthropic
handler reads `ANTHROPIC_API_KEY`. Pass
`#apiKey .~ Just (ApiKeyLiteral key)` explicitly to override with a
literal credential, or use `ApiKeyEnvChain ["OPENAI_API_KEY", "FALLBACK_KEY"]`
to try several environment variables in order; `Show` and JSON instances
redact literal keys.

The result is a `Response`. `resp ^. #message` is the assistant
payload. Use `responseMessage resp` when you need it wrapped as a
conversation `Message`, and use `flattenAssistantBlocks` for text
extraction:

```haskell
let blocks = flattenAssistantBlocks resp     -- Vector AssistantContent
    text = flattenAssistantText blocks       -- Text
```

## Your first call (streaming)

`completeRequest` is really `Stream.fold` over a stream of typed
events. To work directly with the deltas, call `streamRequest`:

```haskell
import qualified Streamly.Data.Stream as Stream

main :: IO ()
main = do
  OpenAIApi.register
  events <- Stream.toList $
    streamRequest Models.openai_gpt_4o_mini ctx opts
  -- events :: [AssistantMessageEvent]
  mapM_ print events
```

You'll see something like:

```text
EventStart   { partial = AssistantMessage {…, assistantContent = []} }
TextStart    { contentIndex = 0 }
TextDelta    { contentIndex = 0, delta = "Hi" }
TextDelta    { contentIndex = 0, delta = " there" }
TextDelta    { contentIndex = 0, delta = "." }
TextEnd      { contentIndex = 0, content = "Hi there." }
EventDone    { reason = Stop, message = AssistantMessage {…} }
```

The stream always ends in exactly one `EventDone` (success) or
`EventError` (failure); see [Streaming](streaming.md).

## Picking a model

`Baikai.Models.Generated` ships a ready-made `Model` value for
every entry in `baikai/data/models/`. The identifiers are
`<provider>_<modelId>` with non-alphanumerics replaced by
underscores:

```haskell
Models.anthropic_claude_sonnet_4_6
Models.anthropic_claude_haiku_4_5
Models.openai_gpt_4o_mini
Models.openai_o1
Models.deepseek_deepseek_chat
Models.openrouter_openai_gpt_4o_mini
```

Adjust per-call defaults (cost limits, max output tokens) with a
record update:

```haskell
Models.openai_gpt_4o_mini { maxOutputTokens = 256 }
```

You can also hand-roll a `Model` for a host the catalog doesn't
cover — see [Models & Providers](models-and-providers.md).

## Where next

- [Streaming](streaming.md) — the event protocol, folds, error
  recovery.
- [Tools](tools.md) — tool definitions, the two-turn round-trip
  pattern.
- [Models & Providers](models-and-providers.md) — the generated
  catalog, hand-built models, multi-host OpenAI-compat targets.
- [Prompt Caching](prompt-caching.md) — the `cacheRetention` knob and
  reading the cache token/cost split back from `Usage`.
- [CLI Providers](cli-providers.md) — driving `claude -p` and
  `codex exec` as subprocess providers (use your existing Claude
  Max / ChatGPT Plus subscription instead of an API key).
- [Kit Packages](kit.md) — installing provider-native skills and
  subagents from a git-hosted kit repository.
