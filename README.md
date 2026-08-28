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
- **Unattended agent runs from a shell script.** The `baikai` executable
  gives a script one stable command —
  `printf '%s' "$prompt" | baikai agent run <job> --prompt-stdin` — and
  the choice of Claude Code or Codex lives in a configuration file rather
  than in the script. `agent show` prints the effective configuration,
  the file and line every value came from, and the exact argument vector
  that would be spawned, without starting anything. The agent's own exit
  code propagates so `set -e` scripts behave.
- **Unattended agent-run vocabulary.** `Baikai.Agent` describes a
  coding-agent run with no terminal and no human: a working directory it
  is authorized to modify, a provider-neutral capability profile, and a
  pure operator ceiling that refuses an over-broad request instead of
  quietly weakening it. A policy a provider cannot express is refused
  before process creation rather than quietly becoming a weaker policy.
- **Repository-owned agent jobs.** `Baikai.Agent.Config` resolves a named
  job from layered KDL configuration — built-in defaults, the operator
  file, the repository file, the environment, then command-line
  overrides — and reports the file, line, and column every value came
  from. The safety ceiling is read from the operator's own file and from
  nowhere else, so an untrusted checkout cannot raise it.
- **Pluggable observability.** A `TraceSink` interface with an optional
  OpenTelemetry adapter that emits one span per provider call.
- **Custom providers.** Register your own handler under a `Custom` tag
  for any API baikai doesn't ship.

## Packages

This is a multi-package project. Depend on `baikai` plus whichever vendor
packages you need; each vendor package registers its handlers into the
shared registry and re-exports nothing of its own.

The table is in publish order — a dependency reaches Hackage before its
dependents.

| Package              | Hackage    | What's inside |
|----------------------|------------|---------------|
| **`baikai`**         | [0.5.0.0](https://hackage.haskell.org/package/baikai) | The core abstraction: `Model`, `Context`, `Options`, typed `Content`, `Tool`, the streaming event protocol, the provider registry, `Usage`/`Cost`, the error model, interactive-launch and agent-asset types, and the generated model catalog (`Baikai.Models.Generated`). The public surface is the top-level `Baikai` module; `Baikai.Prelude` re-exports `lens` + `generic-lens`. |
| **`baikai-claude`**  | [0.5.0.0](https://hackage.haskell.org/package/baikai-claude) | Anthropic providers: the Messages **API** provider and the `claude -p` **CLI** provider, plus the Claude Code **interactive** launcher (`launchClaudeInteractive`). |
| **`baikai-openai`**  | [0.5.0.0](https://hackage.haskell.org/package/baikai-openai) | OpenAI providers: the Chat Completions **API** provider (also serves every OpenAI-compatible host) and the `codex exec` **CLI** provider, plus the Codex **interactive** launcher (`launchCodexInteractive`). |
| **`baikai-trace-otel`** | [0.3.0.3](https://hackage.haskell.org/package/baikai-trace-otel) | An opt-in OpenTelemetry `TraceSink` adapter (`otelSink`). Wiring it into `Baikai.Trace.withTrace` produces one OTel span per provider call with GenAI semantic-convention attributes plus baikai-specific cost and latency. |
| **`baikai-effectful`** | [0.3.0.3](https://hackage.haskell.org/package/baikai-effectful) | A thin, policy-free [`effectful`](https://hackage.haskell.org/package/effectful) binding over baikai's transport: the dynamic `Baikai` effect (`Complete` / `StreamCollect` / `StreamEach`) and interpreters over a real or fake provider. |
| **`baikai-kit`**     | [0.1.0.4](https://hackage.haskell.org/package/baikai-kit) | Shared kit installer for command-line tools that ship a git-hosted kit of local AI-agent skills and subagents: listing, install, update, uninstall, status, and the discovery helpers an interactive session mounts. |
| **`baikai-agent`**   | [0.1.0.0](https://hackage.haskell.org/package/baikai-agent) | **Unattended** coding-agent runs, plus the **`baikai` executable** (`agent run`, `agent show`, `agent list`). `runAgentCommand` spawns `claude` or `codex` with no terminal and no human, delivers the prompt on standard input, drains both output streams within a byte limit, and on timeout terminates the whole process group. `Baikai.Agent.Config` resolves a named job from layered KDL files with per-value provenance, and loads the operator policy ceiling from user scope only. |
| `baikai-smoke`       | internal   | Live smoke tests across every shipped provider. API cases skip when their keys are absent; batch CLI cases run whenever `claude` or `codex` is on `PATH`. Not published — useful as worked examples. |

Packages version independently, so the numbers above move at different
rates; each carries its own `baikai-<package>-<version>` git tag.

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
  handler. A simple program calls each vendor package's
  `register :: IO ()`, which installs that handler into the process-global
  registry. Tests and larger applications build their own
  `ProviderRegistry` from the provider values instead —

  ```haskell
  registry <-
    newProviderRegistryFrom
      [ ClaudeApi.claudeMessagesProvider
      , OpenAIApi.openaiChatProvider
      , ClaudeCli.claudeCliProvider defaultClaudeCliConfig
      , CodexCli.codexCliProvider defaultCodexCliConfig
      ]
  assertRegistered registry [AnthropicMessages, OpenAIChatCompletions]
  ```

  — and dispatch with `completeRequestWith` / `streamRequestWith`. A
  configured provider goes into the global registry with
  `registerApiProvider (claudeCliProvider cfg)`, or into an explicit one
  with `registerApiProviderWith reg`. `assertRegistered` throws once, at
  startup, when an expected tag has no handler; without it, an
  unregistered tag returns an error-shaped `Response` or terminal
  `EventError` with category `ProviderUnavailable` at call time, which is
  later and quieter than you want. Dispatch looks the handler up by
  `Model.api`.

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
  A safety policy the chosen tool cannot express — a Codex sandbox on
  Claude, a Claude tool allow-list on Codex — is refused before launch
  rather than silently dropped, so a caller who asks to be constrained
  either is constrained or gets an error.
  See [Interactive Launches](docs/user/interactive-launches.md).

- **Attended vs unattended.** An interactive launch hands a terminal to
  a human. An unattended run has neither terminal nor human: the agent
  owns its tool loop, edits a working tree you authorized, and returns a
  process result. That is what the `baikai agent` command drives, with
  the provider, permissions, paths, and limits all coming from a KDL
  file that an operator-owned policy ceiling caps.
  See [Unattended Agent Runs](docs/user/unattended-agent-runs.md).

## Install

Every package above is on Hackage, so ordinary dependencies are all you
need:

```cabal
build-depends:
  , baikai
  , baikai-claude
  , baikai-openai
  , baikai-trace-otel   -- optional, for OpenTelemetry
  , baikai-effectful    -- optional, for the effectful binding
  , baikai-kit          -- optional, if your tool ships a kit command
```

The unattended runner is a tool rather than a library dependency.
Installing it puts a `baikai` binary on your `PATH`:

```console
$ cabal install baikai-agent
$ baikai agent --help
```

To track unreleased work instead, pin the repository from
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
- [Unattended Agent Runs](docs/user/unattended-agent-runs.md) — the
  `baikai agent run|show|list` command, the KDL job format, layer
  precedence, the operator policy ceiling, and migrating a script that
  embeds provider flags today.
- [Agent Assets](docs/user/agent-assets.md) — provider-native skill and
  custom-agent layout helpers.
- [Model-Call Evidence](docs/user/model-call-evidence.md) — what
  actually crossed the boundary to the provider: the
  requested/translated/observed split, the two digests, how much a
  record proves, strict mode, and what this deliberately is not.

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
