# baikai

> A unified Haskell interface for working with multiple AI providers.

baikai lets you write one set of calls — `completeRequest` and
`streamRequest` — and dispatch them against Anthropic Claude, OpenAI,
any OpenAI-compatible host (DeepSeek, OpenRouter, Together, …), or the
local `claude -p` / `codex exec` CLIs. Which backend runs is decided by
the `Model` value you pass, not by a different code path. Requests,
streamed events, token usage, and cost accounting flow through the same
provider-neutral types regardless of who is on the other side.

## Name

**baikai** is the romanization of the Japanese word **媒介** (*baikai*),
meaning *mediation*, *medium*, or *intermediary* — the thing that carries
something between two parties. The library sits between application code
and a variety of AI providers, so the name describes the role: a single
medium through which requests, responses, traces, and cost accounting
flow regardless of which provider is on the other side.

## Highlights

- **One dispatch surface, many backends.** `completeRequest` (blocking)
  and `streamRequest` (incremental) route by the model's `Api` tag
  through a process-global provider registry.
- **Models as data.** A `Model` record carries everything needed to
  dispatch: API tag, base URL, per-million-token costs, context window,
  output cap, and compatibility quirks. A generated catalog ships a
  ready-made value for every shipped model, and you can hand-roll one
  for any host the catalog doesn't cover.
- **Typed streaming event protocol.** Streams of `AssistantMessageEvent`
  (`EventStart`, `TextStart/Delta/End`, tool-call events, `EventDone` /
  `EventError`) built on [`streamly`](https://hackage.haskell.org/package/streamly),
  always terminated by exactly one done-or-error event.
- **Typed content blocks & tools.** Structured user/assistant content
  (text, images), tool definitions, and the two-turn tool round-trip on
  the API providers.
- **Usage & cost accounting.** Every successful call returns a `Usage`
  with input/output/cache/reasoning token counts and a `Cost` computed
  from the model's rates.
- **Subscription-backed CLI providers.** Drive `claude -p` and
  `codex exec` as subprocesses through the same surface — useful when you
  pay a flat-rate Claude Max / ChatGPT subscription instead of per token.
- **Interactive launches & agent assets.** Provider-neutral helpers for
  opening a real Claude Code / Codex terminal session, and pure
  layout/path helpers for provider-native skills and custom agents.
- **Pluggable observability.** A `TraceSink` interface with an optional
  OpenTelemetry adapter that emits one span per provider call.
- **Custom providers.** Register your own handler under a `Custom` tag
  for any API baikai doesn't ship.

## Packages

This is a multi-package project. Depend on `baikai` plus whichever vendor
packages you need; each vendor package registers its handlers into the
shared registry and re-exports nothing of its own.

| Package              | Hackage    | What's inside |
|----------------------|------------|---------------|
| **`baikai`**         | published  | The core abstraction: `Model`, `Context`, `Options`, typed `Content`, `Tool`, the streaming event protocol, the provider registry, `Usage`/`Cost`, the error model, interactive-launch and agent-asset types, and the generated model catalog (`Baikai.Models.Generated`). The public surface is the top-level `Baikai` module; `Baikai.Prelude` re-exports `lens` + `generic-lens`. |
| **`baikai-claude`**  | published  | Anthropic providers: the Messages **API** provider and the `claude -p` **CLI** provider, plus the Claude Code **interactive** launcher (`launchClaudeInteractive`). |
| **`baikai-openai`**  | published  | OpenAI providers: the Chat Completions **API** provider (also serves every OpenAI-compatible host) and the `codex exec` **CLI** provider, plus the Codex **interactive** launcher (`launchCodexInteractive`). |
| **`baikai-trace-otel`** | published | An opt-in OpenTelemetry `TraceSink` adapter (`otelSink`). Wiring it into `Baikai.Trace.withTrace` produces one OTel span per provider call with GenAI semantic-convention attributes plus baikai-specific cost and latency. |
| `baikai-smoke`       | internal   | Live smoke tests across every shipped provider (skips, never fails, when API keys are absent). Not published — useful as worked examples. |

Packages version independently and publish in dependency order, `baikai`
first.

## Quick taste

```haskell
import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Vector qualified as V

main :: IO ()
main = do
  OpenAIApi.register                       -- install the handler once
  let ctx  = _Context & #systemPrompt .~ Just "You are terse."
                      & #messages .~ V.singleton (user "Say hi.")
      opts = _Options & #maxTokens .~ Just 32
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print (flattenAssistantText (flattenAssistantBlocks resp))
```

`_Context` / `_Options` / `_Model` are empty bases you fill with
`generic-lens` record updates. `apiKey` left unset falls back to the
provider's environment variable (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
…). Swap `completeRequest` for `streamRequest` to fold over typed
events instead of a single `Response`. See
[Getting Started](docs/user/getting-started.md) for the streaming
walkthrough.

## How it fits together

- **Registry.** `Baikai.Provider.Registry` is a process-global map from
  `Api` tag to handler. Each vendor package exposes `register :: IO ()`
  (and a `registerWith` for configuration). Dispatch looks the handler
  up by `Model.api`; an unregistered tag throws `ProviderError`.

  | `Api` tag                | Registered by                  | Backend |
  |--------------------------|--------------------------------|---------|
  | `AnthropicMessages`      | `Baikai.Provider.Claude.Api`   | Anthropic Messages HTTP API |
  | `AnthropicMessagesCli`   | `Baikai.Provider.Claude.Cli`   | `claude -p` subprocess |
  | `OpenAIChatCompletions`  | `Baikai.Provider.OpenAI.Api`   | OpenAI + any OpenAI-compatible host |
  | `OpenAICompletionsCli`   | `Baikai.Provider.OpenAI.Cli`   | `codex exec` subprocess |
  | `Custom !Text`           | any caller                     | your handler |

- **API vs CLI providers.** API providers give you tokens, tools,
  images, true incremental streaming, and per-call cost. CLI providers
  trade those for running against a flat-rate subscription: text in,
  text out, zero usage, synthetic one-shot streams. See
  [CLI Providers](docs/user/cli-providers.md).

- **Batch vs interactive.** Batch providers return a single `Response`.
  The interactive launchers hand the terminal to a real Claude Code /
  Codex session that owns its own tool loop, approvals, and exit code.
  See [Interactive Launches](docs/user/interactive-launches.md).

## Install

The core packages are being published to Hackage. Once available:

```cabal
build-depends:
  , baikai
  , baikai-claude
  , baikai-openai
  , baikai-trace-otel   -- optional, for OpenTelemetry
```

Until a published version is on the index, pull from git via
`cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/baikai
  tag: <commit>
  subdir: baikai baikai-claude baikai-openai
```

## Documentation

- [Getting Started](docs/user/getting-started.md) — install, register
  providers, first blocking and streaming calls.
- [Models & Providers](docs/user/models-and-providers.md) — the
  generated catalog, hand-rolled models, multi-host OpenAI-compat
  targets, the registry, custom providers, usage & cost.
- [CLI Providers](docs/user/cli-providers.md) — driving `claude -p` and
  `codex exec` as subprocess providers.
- [Interactive Launches](docs/user/interactive-launches.md) — opening
  real Claude Code / Codex sessions.
- [Agent Assets](docs/user/agent-assets.md) — provider-native skill and
  custom-agent layout helpers.

## Develop

The project ships a Nix flake (built on `haskell-nix-dev`) that pins the
toolchain and provides the dev shell. It targets **GHC 9.12.4** with
`default-language: GHC2024`, the project's standard warning set, and the
default extensions `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, and `OverloadedStrings`.

```bash
nix develop          # or: direnv allow, if you use direnv
cabal build all
cabal test all       # smoke tests skip when API keys are absent
nix fmt              # fourmolu + cabal-fmt + nixpkgs-fmt
nix flake check
```

The generated model catalog is regenerated with:

```bash
cabal run baikai-gen-models
```

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
