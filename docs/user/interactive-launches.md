# Interactive Launches

`Baikai.Interactive` is the surface for launching a local interactive
agent CLI, such as Claude Code or Codex, and then letting that program
own the terminal UI, tool loop, approval prompts, session state, and
process exit. It is separate from the batch CLI providers documented in
`docs/user/cli-providers.md`.

Use `completeRequest` or `streamRequest` when your program needs a
single `Response` value. Use an interactive launcher when your program
wants to open a real local session for a human or another terminal owner
to drive.

## Claude Code

The Claude Code launcher lives in `baikai-claude`:

```haskell
import Baikai.Interactive
import Baikai.Provider.Claude.Interactive

main :: IO ()
main = do
  result <-
    launchClaudeInteractive
      defaultClaudeInteractiveConfig
      (interactiveLaunchRequest "Inspect this project and suggest next steps.")
        { systemPrompt = Just "Be concise."
        , modelId = Just "sonnet"
        , workingDir = Just "/path/to/project"
        , extraDirs = ["/path/to/shared/context"]
        , safety = ClaudeAllowedTools ["Read", "Bash(git status)"]
        }
  print result
```

`claudeInteractiveCommand` is the pure command builder used by tests and
callers that need to inspect or log the launch. It renders the request
to `claude` arguments including `--model`, `--system-prompt`,
`--add-dir`, and `--allowedTools`, then `--`, then the initial prompt.
`launchClaudeInteractive` runs that command with inherited stdin,
stdout, and stderr.

## Codex

The Codex launcher lives in `baikai-openai`:

```haskell
import Baikai.Interactive
import Baikai.Provider.OpenAI.Interactive

main :: IO ()
main = do
  result <-
    launchCodexInteractive
      defaultCodexInteractiveConfig
      (interactiveLaunchRequest "Inspect this project and suggest next steps.")
        { systemPrompt = Just "Be concise."
        , modelId = Just "gpt-5-codex"
        , workingDir = Just "/path/to/project"
        , extraDirs = ["/path/to/shared/context"]
        , safety = CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
        }
  print result
```

`codexInteractiveCommand` is the pure command builder. It renders
`--model`, `--cd`, `--add-dir`, `--sandbox`, and `--ask-for-approval`.
The installed Codex CLI exposes no top-level interactive system-prompt
flag, so `codexInteractivePrompt` preserves `systemPrompt` by placing it
before the user prompt in the initial prompt text. The builder renders
`--` immediately before that prompt.

## Reasoning Effort

Set `effort` on an interactive request when the launch should use an
explicit reasoning-effort level instead of the CLI's ambient default:

```haskell
import Baikai (ThinkingLevel (..))
import Baikai.Interactive

request :: InteractiveLaunchRequest
request =
  (interactiveLaunchRequest "Analyze the failing tests.")
    { effort = Just ThinkingXHigh
    }
```

Baikai provides six levels: `ThinkingMinimal`, `ThinkingLow`,
`ThinkingMedium`, `ThinkingHigh`, `ThinkingXHigh`, and `ThinkingMax`.
Claude Code receives `--effort low` for both `ThinkingMinimal` and
`ThinkingLow`, because its CLI has no `minimal` value; the other four
levels become `medium`, `high`, `xhigh`, and `max`. Codex receives all
six canonical names through `-c model_reasoning_effort=<level>`.

The default is `effort = Nothing`, which emits no effort argument and
leaves the CLI default unchanged. It does not mean Codex's explicit
`none` mode. Provider- and model-specific Codex values such as `none`
or `ultra` remain available through `extraArgs`.

The same `ThinkingLevel` type is used by API requests through
`Options.thinking`. Native OpenAI and Anthropic request paths preserve
`xhigh` and `max` when supported. DeepSeek, OpenRouter, and Together use
their existing OpenAI-compatible request shapes and clamp those two
higher levels to `high`.

## Extra Arguments

Both launch config records have `executable` and `extraArgs` fields. Use
`executable` when the CLI is not on `PATH`; use config `extraArgs` for
provider defaults your application always wants. Each
`InteractiveLaunchRequest` also has `extraArgs` for per-launch flags.
The command builders render config extra args first, then request extra
args, then `--`, then the initial prompt. That separator keeps prompts
that start with `-` from being parsed as provider flags and stops
variadic flags such as Claude's `--allowedTools` from swallowing the
prompt.

Structured effort arguments are rendered before both extra-argument
lists. A raw config or request argument can therefore remain the final
provider-specific override when needed.

## Smoke Checks

The default test suites do not start live interactive sessions because a
real session may require authentication, a trusted terminal, and manual
exit. They verify command construction instead:

```bash
cabal test baikai-claude-test baikai-openai-test
```

For a local smoke check, confirm the binaries are visible and inspect the
rendered command through the pure builders before launching:

```bash
command -v claude
command -v codex
```

Then call `launchClaudeInteractive` or `launchCodexInteractive` from an
interactive terminal and exit the provider session normally when done.

Provider-native skill and custom-agent paths are documented in
`docs/user/agent-assets.md`. Interactive launch helpers start the local
CLI; they do not install or verify provider asset files.
