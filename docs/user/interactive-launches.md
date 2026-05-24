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
      (_InteractiveLaunchRequest "Inspect this project and suggest next steps.")
        { systemPrompt = Just "Be concise."
        , model = Just "sonnet"
        , workingDir = Just "/path/to/project"
        , extraDirs = ["/path/to/shared/context"]
        , safety = ClaudeAllowedTools ["Read", "Bash(git status)"]
        }
  print result
```

`claudeInteractiveCommand` is the pure command builder used by tests and
callers that need to inspect or log the launch. It renders the request
to `claude` arguments including `--model`, `--system-prompt`,
`--add-dir`, and `--allowedTools`. `launchClaudeInteractive` runs that
command with inherited stdin, stdout, and stderr.

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
      (_InteractiveLaunchRequest "Inspect this project and suggest next steps.")
        { systemPrompt = Just "Be concise."
        , model = Just "gpt-5-codex"
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
before the user prompt in the initial prompt text.

## Extra Arguments

Both launch config records have `executable` and `extraArgs` fields. Use
`executable` when the CLI is not on `PATH`; use config `extraArgs` for
provider defaults your application always wants. Each
`InteractiveLaunchRequest` also has `extraArgs` for per-launch flags.
The command builders render config extra args first, then request extra
args, then the initial prompt.

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
