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
  opening a real Claude Code / Codex terminal session with explicit
  model and reasoning-effort controls, and pure layout/path helpers for
  provider-native skills and custom agents.
- **Unattended agent-run vocabulary.** `Baikai.Agent` describes a
  coding-agent run with no terminal and no human: a working directory it
  is authorized to modify, a provider-neutral capability profile, and a
  pure operator ceiling that refuses an over-broad request instead of
  quietly weakening it. Flag rendering and process spawning are not part
  of this module yet.
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
| **`baikai`**         | not yet    | The core abstraction: `Model`, `Context`, `Options`, typed `Content`, `Tool`, the streaming event protocol, the provider registry, `Usage`/`Cost`, the error model, interactive-launch and agent-asset types, and the generated model catalog (`Baikai.Models.Generated`). The public surface is the top-level `Baikai` module; `Baikai.Prelude` re-exports `lens` + `generic-lens`. |
| **`baikai-claude`**  | not yet    | Anthropic providers: the Messages **API** provider and the `claude -p` **CLI** provider, plus the Claude Code **interactive** launcher (`launchClaudeInteractive`). |
| **`baikai-openai`**  | not yet    | OpenAI providers: the Chat Completions **API** provider (also serves every OpenAI-compatible host) and the `codex exec` **CLI** provider, plus the Codex **interactive** launcher (`launchCodexInteractive`). |
| **`baikai-trace-otel`** | not yet | An opt-in OpenTelemetry `TraceSink` adapter (`otelSink`). Wiring it into `Baikai.Trace.withTrace` produces one OTel span per provider call with GenAI semantic-convention attributes plus baikai-specific cost and latency. |
| `baikai-smoke`       | internal   | Live smoke tests across every shipped provider. API cases skip when their keys are absent; batch CLI cases run whenever `claude` or `codex` is on `PATH`. Not published — useful as worked examples. |

Packages version independently and will publish in dependency order,
`baikai` first.

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
  prompt <- userNow "Say hi."
  let ctx  = emptyContext & #systemPrompt .~ Just "You are terse."
                      & #messages .~ V.singleton prompt
      opts = emptyOptions & #maxTokens .~ Just 32
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print (flattenAssistantText (flattenAssistantBlocks resp))
```

`emptyContext` / `emptyOptions` / `emptyModel` are empty bases you fill with
`generic-lens` record updates. `apiKey` left unset falls back to the
provider's environment variable (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
…). Set `#apiKey .~ Just (ApiKeyLiteral key)` to override with an
explicit credential. Swap `completeRequest` for `streamRequest` to fold
over typed events instead of a single `Response`. See
[Getting Started](docs/user/getting-started.md) for the streaming
walkthrough.

## How it fits together

- **Registry.** `Baikai.Provider.Registry` maps each `Api` tag to a
  handler. Simple programs can use the process-global convenience
  registry through each vendor package's `register :: IO ()` (and
  `registerWith` for configuration). Tests and larger apps can instead
  create a `ProviderRegistry` with `newProviderRegistry`, register into
  it with `registerWithRegistry` or `registerApiProviderWith`, and call
  `completeRequestWith` / `streamRequestWith`. Dispatch looks the handler
  up by `Model.api`; an unregistered tag returns an error-shaped
  `Response` or terminal `EventError` with category `ProviderUnavailable`.

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

Until the packages appear on the package index, pull them from git via
`cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/shinzui/baikai
  tag: <commit>
  subdir: baikai baikai-claude baikai-openai
```

Once published, use ordinary package dependencies:

```cabal
build-depends:
  , baikai
  , baikai-claude
  , baikai-openai
  , baikai-trace-otel   -- optional, for OpenTelemetry
```

## Documentation

- [Getting Started](docs/user/getting-started.md) — install, register
  providers, first blocking and streaming calls.
- [Models & Providers](docs/user/models-and-providers.md) — the
  generated catalog, hand-rolled models, multi-host OpenAI-compat
  targets, reasoning effort, the registry, custom providers, usage &
  cost.
- [Streaming](docs/user/streaming.md) — the `AssistantMessageEvent`
  algebra, event stability policy, fold patterns, and partial output
  recovery.
- [Tools](docs/user/tools.md) — declaring tools, tool-choice options,
  and the two-turn tool-result round trip.
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
cabal test all       # includes live smoke cases when credentials or CLIs are available
nix fmt              # fourmolu + cabal-fmt + nixpkgs-fmt
nix flake check
```

`baikai-smoke` has two independent live gates: API cases require their
provider keys, while batch CLI cases run whenever the corresponding
`claude` or `codex` executable is discoverable on `PATH` and use its
ambient authentication. Account for both when you need a fully offline
test run.

### Refreshing the model catalog

The catalog has two representations: hand-reviewable JSON under
`baikai/data/models/` and the generated Haskell module
`baikai/src/Baikai/Models/Generated.hs`. Refreshing is two steps —
fetch (network → JSON), then generate (JSON → Haskell) — and you review
the `git diff` before committing:

```bash
cabal run baikai-fetch-models   # fetch models.dev, rewrite anthropic.json + openai.json
cabal run baikai-gen-models     # regenerate Generated.hs from the JSON
git --no-pager diff baikai/data/models baikai/src/Baikai/Models/Generated.hs
cabal test baikai               # CatalogSpec proves JSON and Generated.hs agree
```

`baikai-fetch-models` pulls `https://models.dev/api.json`, keeps the
curated, tool-capable Anthropic and OpenAI models, normalizes them to
the catalog shape, and applies a small hand-maintained override layer
(see the header of `baikai/fetch/FetchModelsCore.hs`). Useful flags:
`--from-file PATH` (offline, e.g. a saved `api.json`), `--stdout` (print
instead of writing), and `--provider {openai|anthropic|all}`. To edit a
single price by hand, change the JSON and run only `baikai-gen-models`.

## License

[BSD-3-Clause](./LICENSE) — (c) 2026 Nadeem Bitar.
