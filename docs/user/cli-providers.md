# CLI Providers

baikai ships two CLI-backed providers that drive `claude -p` and
`codex exec` as subprocesses, exposing them through the same
`completeRequest` / `streamRequest` surface as the API providers.
The use case is narrow but important: running against a flat-rate
Claude.ai or ChatGPT subscription that doesn't bill per token, on
a developer machine where the CLI binary is already installed and
authenticated.

## When to use a CLI provider

| Pick the CLI provider when…                                              | Pick the API provider when…                              |
|--------------------------------------------------------------------------|----------------------------------------------------------|
| You're already paying for Claude Max / ChatGPT Plus / etc.               | You have an API key with per-token billing.              |
| You want to inherit the CLI's auth flow (`claude login`, `codex login`). | You can manage `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`.   |
| You only need text in, text out.                                         | You need tools, images, or fine control over tokens.     |
| You want the tool's own cost accounting, not per-request billing.       | You need billing you control per request.                |

The CLI providers exist so the rest of baikai's surface (Context,
Options-as-data, the event stream, the registry, the trace bridge)
works uniformly across "API call" and "CLI subprocess." They're
not a tool-equivalent feature path — see [Limitations](#limitations).

## Batch subprocesses vs interactive launches vs unattended runs

The providers described on this page are batch subprocess providers.
They call `claude -p` or `codex exec`, wait for the command to finish,
and return a normal `Response` through `completeRequest` or synthetic
events through `streamRequest`.

Interactive local agent sessions are a separate surface. The core
`Baikai.Interactive` module defines the provider-neutral request and
result types for launching a real Claude Code or Codex terminal session:
a rendered system prompt, an initial user prompt, optional model,
working directory, extra readable directories, safety preferences, and
extra provider arguments. Vendor packages consume that request type and
translate it into their CLI's flags.

There is a third surface, and it is neither of those two: an
**unattended run**. The coding agent starts with no terminal and no
human present, drives its own tool loop, changes files inside
directories you explicitly authorized, and finishes with a process
result. The deliverable is the changed working tree, not the text. That
surface is driven from a shell script by the `baikai agent` command,
with the provider chosen in a configuration file rather than in the
script — see `docs/user/unattended-agent-runs.md`.

Use the batch providers when your program needs a single response value.
Use the interactive launch surface when your program wants to hand
control to the local CLI so the provider can own its terminal UI, tool
loop, approvals, session state, and final process exit code.
See `docs/user/interactive-launches.md` for the concrete
`launchClaudeInteractive` and `launchCodexInteractive` APIs. Use the
unattended surface when nobody is watching and the run is expected to
edit the tree.

## Smallest example

```haskell
import Baikai
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as V

main :: IO ()
main = do
  ClaudeCli.register
  CodexCli.register

  let claudeModel =
        emptyModel
          { modelId = "sonnet"               -- passed to claude -p --model
          , api = AnthropicMessagesCli
          , provider = "anthropic"
          }
      codexModel =
        emptyModel
          { modelId = ""                     -- empty = let codex pick its default
          , api = OpenAICompletionsCli
          , provider = "openai"
          }
      ctx =
        emptyContext
          & #systemPrompt .~ Just "Reply with the single word: pong."
  prompt <- userNow "ping"
  let ctx' = ctx & #messages .~ V.singleton prompt

  resp1 <- completeRequest claudeModel ctx' emptyOptions
  resp2 <- completeRequest codexModel  ctx' emptyOptions
  print (resp1, resp2)
```

`register` calls install the handlers under their `Api` tags
(`AnthropicMessagesCli` for `claude -p`, `OpenAICompletionsCli`
for `codex exec`). The model record's `api` tag is the only thing
the registry looks at when dispatching — the same
`completeRequest` call routes to the subprocess based on the tag.

The CLI providers do not use the generated catalog
(`Baikai.Models.Generated`). Build a `Model` record by hand and set
`api = AnthropicMessagesCli` / `OpenAICompletionsCli`. The
`modelId` is forwarded verbatim as `--model <id>`; pass an empty
string to let the CLI pick its own default.

## Configuration

The defaults assume the binary is on `PATH` and don't pass any
extra flags. To override:

Use `registerWithRegistry` or `registerWithRegistryAndConfig` instead
when registering CLI providers into an explicit `ProviderRegistry`.

### `claude -p`

```haskell
import Baikai.Provider.Claude.Cli
  ( ClaudeCliConfig
  , defaultClaudeCliConfig
  , executable
  , extraArgs
  , registerWith
  , workingDir
  )

main :: IO ()
main = do
  registerWith
    defaultClaudeCliConfig
      { executable = "/Users/me/.local/bin/claude"
      , extraArgs = ["--allowed-tools", "Bash,Read"]
      , workingDir = Just "/path/to/project"
      }
```

### `codex exec`

```haskell
import Baikai.Provider.OpenAI.Cli
  ( CodexCliConfig
  , defaultCodexCliConfig
  , ephemeral
  , executable
  , extraArgs
  , registerWith
  , skipGitRepoCheck
  , workingDir
  )

main :: IO ()
main = do
  registerWith
    defaultCodexCliConfig
      { executable = "/opt/homebrew/bin/codex"
      , extraArgs = []
      , workingDir = Just "/path/to/project"
      , skipGitRepoCheck = True   -- default; passes --skip-git-repo-check
      , ephemeral = True          -- default; passes --ephemeral
      }
```

The Codex defaults (`skipGitRepoCheck = True`, `ephemeral = True`)
exist because Codex refuses to run outside a git working tree and
persists session state by default — neither is useful when driving
it as a library subprocess. Flip them to `False` if you actually
want the default Codex behaviour.

## The response shape

CLI providers return a normal `Response`, with three caveats:

1. **`usage` carries whatever the tool reported.** Both CLIs do
   expose token counts, and baikai now carries them through:
   `claude -p`'s result event supplies Anthropic-shaped counts
   (already disjoint, so nothing is subtracted) plus a
   `total_cost_usd` that populates `Usage.cost` exactly, and
   `codex exec --json` supplies OpenAI-style inclusive counts whose
   cached tokens are subtracted out of `inputTokens`. A tool that
   reports nothing still yields zeroes, which is an accurate record
   of its silence rather than a claim the call was free.

   > **Changed in `baikai-claude` 0.5.0.0 / `baikai-openai` 0.5.0.0.**
   > These providers used to hardcode `zeroUsage` on every call, so a
   > cost dashboard saw them as consuming no tokens and costing
   > nothing. Real tokens and, for `claude`, a real dollar figure now
   > appear where zeroes used to. Totals over historical data will not
   > match totals over new data.

   Note that `cost` is what the *tool* reported, not necessarily what
   you were billed: under a flat-rate subscription `claude` still
   reports the equivalent API cost.
2. **`responseId` carries the tool's own conversation handle.**
   `claude -p`'s `session_id` and `codex exec`'s `thread_id` — the
   handles each vendor's support tooling looks a run up by. Before
   `0.5.0.0` this was permanently `Nothing`, even though `claude`'s
   was already decoded and then discarded.
3. **`latencyMs` is wall-clock.** Measured from process spawn to
   process exit. Includes JSON decode time, which is negligible
   relative to the model call.
4. **`evidence` is present only if you asked for one.** Setting
   `Options.evidence` gets you a `ModelCallEvidence` record
   describing what crossed the boundary — including the resolved
   executable, its `--version` string, and a digest of the exact
   argument vector. See
   [Model-Call Evidence](model-call-evidence.md). Leaving it unset
   costs nothing.

The assistant message carries exactly one `AssistantText` block
holding the full response. `stopReason` is always `Stop` on
success. Failures return an error-shaped `Response` with
`stopReason = ErrorReason` and structured `errorInfo`: non-zero exits
use the `processError` smart constructor, malformed JSON uses
`decodeError`, and CLI-reported provider failures use `providerError`.

## Streaming

`streamRequest` works against CLI providers, but the stream is
synthetic. The whole response arrives in one chunk:

```text
EventStart   { partial = <empty AssistantMessage skeleton> }
TextStart    { contentIndex = 0 }
TextDelta    { contentIndex = 0, delta = "<entire response>" }
TextEnd      { contentIndex = 0, content = "<entire response>" }
EventDone    { reason = Stop, message = <full AssistantMessage> }
```

There is no intra-response streaming on the wire — `claude -p` and
`codex exec --json` both deliver their output as a single message
after the model finishes. baikai wraps that batch output with
`Baikai.Stream.liftCompleteToStream` so callers that iterate over
events don't have to special-case the CLI path. If you want true
incremental output, use the API providers.

## Multi-message contexts

`Context.messages` can carry an arbitrary conversation. The CLI
providers handle the common case (one user message, one text
block) by passing the text straight through to the CLI. Anything
more complex gets flattened into a tagged transcript:

```text
[user]: What did I just ask?
[assistant]: You asked about your last question.
[user]: And what did you say?
```

This is necessarily lossy: image content and assistant tool calls
are dropped from the rendered prompt, since neither CLI can
re-ingest them through stdin. If you need multi-turn fidelity with
tool round-trips, use the API providers.

`Context.systemPrompt` is forwarded differently per CLI. The Claude
batch provider passes it with `--system-prompt`. `codex exec` exposes no
system-prompt flag, so the Codex batch provider prepends it to the
prompt text as:

```text
System instructions:
<system prompt>

User request:
<rendered prompt>
```

## Limitations

Three things the CLI providers do **not** do, even though the
types compile:

1. **No tool calling.** `Context.tools` and `Options.toolChoice`
   are silently ignored. The CLIs don't expose a way for an
   external orchestrator to feed tool results back into an
   in-progress turn, and faking it would lose the CLI's own
   session state. The masterplan's Decision Log records the
   rationale.
2. **No image input.** `UserImage` content blocks are dropped
   when the prompt is rendered. Neither CLI accepts inline
   image bytes via stdin.
3. **Most `Options` fields are ignored.** `maxTokens`,
   `temperature`, `apiKey`, `timeoutMs`, `headers`, `metadata`,
   `cacheRetention` — none of these are forwarded. `Options` is
   accepted to keep the dispatch signature uniform, not because the
   CLI providers consume most of it. The one exception is
   `Options.thinking`: the batch providers forward it as the app's
   reasoning-effort flag — `claude -p` receives `--effort <level>`
   (with `minimal` collapsed to `low`, since the `claude` CLI has no
   `minimal`) and `codex exec` receives `-c
   model_reasoning_effort=<level>` (all six levels verbatim). Leaving
   `thinking = Nothing` emits no effort flag. Every other field can be
   left at `emptyOptions`.

If your code needs to handle both API and CLI providers
generically, *don't* assume `Options` settings will take effect —
gate those expectations on `Model.api` not being
`AnthropicMessagesCli` / `OpenAICompletionsCli`. Token counts are
now safe to read from either, but treat a zero as "the tool said
nothing" rather than "the call was free".

## Common gotchas

- **`claude` / `codex` not on `PATH`.** The default
  `executable = "claude"` (or `"codex"`) only resolves through the
  shell's `PATH`. Hard-code an absolute path via
  `executable = "/Users/me/.local/bin/claude"` if the parent
  process has a stripped `PATH` (cron, systemd, some test
  runners). The smoke tests skip the CLI cases when
  `findExecutable` returns `Nothing`; you should do the same in
  production-adjacent code.
- **`claude -p` session persistence.** baikai passes
  `--no-session-persistence` by default so successive calls don't
  share state. If you want the opposite (a long-lived CLI
  session), this provider is the wrong abstraction — drive
  `claude` directly.
- **`codex exec` outside a git repo.** Codex refuses to run when
  it can't find a git working tree. baikai passes
  `--skip-git-repo-check` by default; flip
  `skipGitRepoCheck = False` only if you want the check.
- **Long responses & subprocess buffering.** Both providers
  consume stdout to EOF before returning. Very long responses
  hold the subprocess open for the full duration — the synthetic
  stream emits its single `TextDelta` only after the CLI exits.
- **Extra arguments and dash-leading prompts.** baikai renders
  provider/config extra args before a `--` separator, then the prompt.
  Prompts that start with `-` are therefore safe. Keep `extraArgs` to
  real flags and their values; anything intended as prompt text belongs
  in `Context.messages`.
