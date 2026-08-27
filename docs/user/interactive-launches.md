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

## The Third Surface: Unattended Runs

There is a third case, and it is neither of the two above: an
**unattended run**. The coding agent starts with no terminal and no
human present, drives its own internal tool loop, changes files inside
directories the caller explicitly authorized, and finishes with a
process result rather than a `Response`. The interesting output is the
changed working tree, not the text.

`Baikai.Agent` is the provider-neutral vocabulary for that case:

- `AgentRunRequest` names the provider, the prompt, a **required**
  working directory, extra directories the run may reach, a safety
  policy, a timeout, an output discipline, an output byte limit, and the
  environment variables the job declares it requires.
- `AgentSafety` carries a `AgentCapability` — `AgentReadOnly`,
  `AgentEditWorkspace`, or `AgentFullAccess` — plus an optional tool
  allow-list and a raw provider-argument escape hatch.
- `AgentCeiling` is the limit an *operator* places on what any job may
  request, because a job description checked into a repository is
  untrusted input. `applyAgentCeiling` is a pure check that returns the
  request unchanged when it is within the ceiling and reports every
  violation when it is not. It never clamps an over-broad request to the
  permitted value: a job that asked for more authority than it may have
  is an error to report, not a request to quietly weaken.
  `defaultAgentCeiling` permits read-only and edit-workspace authority,
  and refuses full access and raw provider arguments.
- `AgentRunResult` reports the exit code, the duration, and each stream
  as `OutputNotCaptured`, `OutputCaptured`, or `OutputTruncated`. A
  non-zero exit code is a normal result, not a failure: a coding agent
  that fails its task and exits 1 has still run.
- `AgentRunOutcome` pairs that outcome with the evidence a run
  produced, when the caller asked for any.
- `AgentRenderError` is a refusal raised before anything is spawned,
  and `AgentRunFailure` is a failure while spawning or waiting.

`Baikai.Agent` itself spawns nothing and renders no flags.

### Running one

The process runner lives in the `baikai-agent` package, as
`runAgentCommand` in `Baikai.Agent.Run`:

```haskell
runAgentCommand ::
  Maybe EvidenceRequest ->
  ThinkingTranslation ->
  AgentRunRequest ->
  AgentCommand ->
  IO AgentRunOutcome
```

The first two arguments are about evidence and are covered in
[Model-Call Evidence](model-call-evidence.md); passing `Nothing` and
`noThinkingRequested` reproduces the pre-`0.5.0.0` behaviour exactly,
at the same cost. The result is an `AgentRunOutcome` pairing the
outcome — the same `Either AgentRunFailure AgentRunResult` as before,
in its `outcome` field — with the evidence built for the run, if any.

> **Changed in `baikai-agent` 0.1.0.0.** The evidence is a sibling of
> the outcome rather than a field on `AgentRunResult`, because the run
> that most needs a record is one that produced no result: a run killed
> by its own timeout reports `Left (RunTimedOut …)`, so a record hanging
> off the `Right` would be unreachable exactly there.

The last two arguments are both required and neither is redundant. The request
supplies every process-level setting — working directory, timeout,
output discipline, output limit, and declared environment variables —
while the command supplies the executable, the argument vector, and the
prompt transport. `AgentCommand` carries no working directory on
purpose: Claude Code has no working-directory flag, so for one of the
two providers it can only ever be a process-level setting, and two
copies of a working directory that disagree would be a sandbox escape
rather than a cosmetic bug.

Four behaviors decide how a caller reads the result:

- **A non-zero exit code is a `Right`, not a `Left`.** A coding agent
  that attempts its task and fails has run. `Left` means the tool never
  started or never finished; `Right` means it ran, and the exit code
  says how it went. What a non-zero code means for a workflow is the
  calling script's policy, not the library's.
- **`InheritOutput` captures nothing, by design.** The child writes
  straight to the parent's own streams and both result fields are
  `OutputNotCaptured`. That is the default, and it is what a script
  whose log is the terminal it inherited wants. Ask for `CaptureOutput`
  or `TeeOutput` to get bytes back.
- **The byte limit truncates rather than failing.** Output past
  `outputLimit` is read and discarded, and the stream comes back as
  `OutputTruncated` carrying exactly the retained prefix. Closing the
  pipe early instead would make the agent's next write fail, producing a
  crash attributed to the tool rather than to the limit.
- **A timeout kills the whole process group.** A coding agent runs shell
  commands as its own children; terminating only the agent would leave
  them running, holding the working tree open and possibly still writing
  to it. The run is interrupted, given a short grace period, and then
  the group is terminated, so the agent's own children go with it.
  `RunTimedOut` reports the configured limit, not the measured elapsed
  time.

Two preconditions are checked before anything is spawned: a working
directory that does not exist yields `WorkingDirMissing`, and any
variable named in `envPassthrough` that is unset or empty yields
`MissingEnvironment` listing every one of them at once. `envPassthrough`
is a precondition check, not a filter — the child inherits the parent's
environment in full, because both tools need `HOME`, `PATH`, and their
own credential files to work at all.

The whole surface:

```text
output mode      child streams          result stdout/stderr
inherit          parent's own streams   OutputNotCaptured
capture          pipes, parent silent   OutputCaptured / OutputTruncated
tee              pipes, echoed onward   OutputCaptured / OutputTruncated

outcome                                 return value
ran, exit 0                             Right, exitCode ExitSuccess
ran, exit non-zero                      Right, exitCode ExitFailure n
working directory absent                Left WorkingDirMissing
declared variable unset or empty        Left MissingEnvironment
executable not startable                Left SpawnFailed
still running at the deadline           Left RunTimedOut, group terminated
```

### What a capability becomes

The pure renderers `claudeAgentCommand` in `Baikai.Provider.Claude.Agent`
and `codexAgentCommand` in `Baikai.Provider.OpenAI.Agent` turn a
capability profile into an argument vector, or refuse the request.
Neither spawns anything.

The mapping tables — what each capability becomes on each tool, the
Claude read-only caveat, the Codex tool-allow-list refusal, and the two
different meanings of `--add-dir` — live with the rest of the unattended
surface in
[docs/user/unattended-agent-runs.md](unattended-agent-runs.md#what-a-capability-becomes).

That guide also documents the `baikai agent run|show|list` command a
shell script actually invokes, how a repository describes a named job,
how an operator caps what any job may ask for, and which configuration
layer wins.

`Baikai.Agent` is not re-exported from the umbrella `Baikai` module,
because its field accessors deliberately share names with
`Baikai.Interactive`. Import it directly, qualified if you need both
surfaces at once:

```haskell
import Baikai.Agent
import Baikai.Agent qualified as Agent
```

The two surfaces keep separate policy types on purpose.
`InteractiveSafety` has no notion of a capability profile or an operator
ceiling, and the unattended vocabulary has no notion of an inherited
terminal or of interactive approval prompts. What they share is the
*refusal* type, `AgentRenderError`: an unsupported policy fails visibly
on both surfaces rather than silently becoming a weaker policy. See
[Refused Safety Policies](#refused-safety-policies) below for what that
means when you call an interactive launcher.

## Refused Safety Policies

`InteractiveSafety` carries constructors for both providers in one type,
so nothing stops a caller from handing a Codex sandbox policy to the
Claude launcher, or a Claude tool allow-list to the Codex launcher.
Neither tool can express the other's policy.

Baikai refuses such a request before starting anything. Both pure
command builders and both launchers return
`Either AgentRenderError`, and the refusal is
`SafetyNotExpressible`:

```haskell
claudeInteractiveCommand ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
launchClaudeInteractive ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)

codexInteractiveCommand ::
  CodexInteractiveConfig -> InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
launchCodexInteractive ::
  CodexInteractiveConfig -> InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
```

Read the two result branches precisely, because they are not the same
kind of bad news. A `Left` means **no process was started at all**: the
policy was rejected before process creation, so nothing ran and nothing
in your working tree changed. A `Right` carrying a non-zero `ExitCode`
means the session **ran and exited non-zero**, which is an ordinary
outcome of an interactive session.

`renderAgentRenderError` turns the refusal into one line of plain
English. The three messages are:

```text
claude cannot honor the requested safety policy: Claude Code cannot
express a Codex sandbox policy (read-only, never); use
ClaudeAllowedTools, or DefaultSafety to accept Claude's own default

codex cannot honor the requested safety policy: Codex has no tool
allow-list flag, so it cannot honor the requested tools (Read); use
CodexSandbox to restrict Codex, or DefaultSafety to accept its own
default

codex cannot honor the requested safety policy: the installed codex CLI
accepts only on-request and never for --ask-for-approval (codex
0.149.1); it rejects untrusted, so the session was not started; use
CodexApprovalOnRequest or CodexApprovalNever
```

The full behavior table:

| request safety                | Claude launcher             | Codex launcher                          |
|-------------------------------|-----------------------------|-----------------------------------------|
| `DefaultSafety`               | `Right`, no safety flags    | `Right`, no safety flags                |
| `ClaudeAllowedTools []`       | `Right`, no safety flags    | `Right`, no safety flags                |
| `ClaudeAllowedTools ["Read"]` | `Right`, `--allowedTools`   | `Left SafetyNotExpressible`             |
| `CodexSandbox mode CodexApprovalOnRequest` | `Left SafetyNotExpressible` | `Right`, `--sandbox`/`--ask-for-approval` |
| `CodexSandbox mode CodexApprovalNever`     | `Left SafetyNotExpressible` | `Right`, `--sandbox`/`--ask-for-approval` |
| `CodexSandbox mode CodexApprovalUntrusted` | `Left SafetyNotExpressible` | `Left SafetyNotExpressible`             |
| `CodexSandbox mode CodexApprovalOnFailure` | `Left SafetyNotExpressible` | `Left SafetyNotExpressible`             |

Three rows deserve a word. `DefaultSafety` means "I am not specifying a
policy; use the tool's own default", so rendering no safety flag honors
it exactly and is **never** a refusal. An *empty* `ClaudeAllowedTools`
list restricts nothing, so there is nothing for Codex to fail to honor
and it renders successfully there too; only a non-empty list is a
restriction Codex cannot express.

The last two rows are about the installed tool rather than about Codex
in principle. `untrusted` and `on-failure` are spellings older Codex
generations accepted; `codex --help` at 0.149.1 lists exactly
`on-request` and `never`, and passing either of the older ones makes the
CLI exit with a usage error. Left to render, that surfaced as a `Right`
carrying a non-zero exit code — a session that ran — which is precisely
what these refusals exist to prevent, so the launcher refuses them
before creating a process. They are refused rather than quietly mapped
onto `on-request`, because substituting a different approval policy
would change what the caller asked for. The constructors stay in
`CodexApprovalPolicy` so code that matches on the type keeps compiling.

**This is a behavior change.** In previous releases, a policy the chosen
provider could not express was silently discarded and the session
started with no restriction at all — a caller who asked for a read-only
Codex sandbox on Claude got an unrestricted Claude session and a success
result. A call that appeared to work before may now return `Left`. That
is the point: the previous success was reporting a constraint that was
never applied. If you hit it, either switch to a policy the chosen
provider can express, or state `DefaultSafety` if you genuinely did not
want a restriction.

## Claude Code

The Claude Code launcher lives in `baikai-claude`:

```haskell
import Baikai.Agent (renderAgentRenderError)
import Baikai.Interactive
import Baikai.Provider.Claude.Interactive
import Data.Text.IO qualified as TIO

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
  case result of
    Left err -> TIO.putStrLn (renderAgentRenderError err)  -- nothing was started
    Right launched -> print launched
```

`claudeInteractiveCommand` is the pure command builder used by tests and
callers that need to inspect or log the launch. It renders the request
to `claude` arguments including `--model`, `--system-prompt`,
`--add-dir`, and `--allowedTools`, then `--`, then the initial prompt,
or refuses with `Left` when the safety policy is a Codex sandbox.
`launchClaudeInteractive` runs that command with inherited stdin,
stdout, and stderr, and starts no process when the builder refuses.

## Codex

The Codex launcher lives in `baikai-openai`:

```haskell
import Baikai.Agent (renderAgentRenderError)
import Baikai.Interactive
import Baikai.Provider.OpenAI.Interactive
import Data.Text.IO qualified as TIO

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
  case result of
    Left err -> TIO.putStrLn (renderAgentRenderError err)  -- nothing was started
    Right launched -> print launched
```

`codexInteractiveCommand` is the pure command builder. It renders
`--model`, `--cd`, `--add-dir`, `--sandbox`, and `--ask-for-approval`,
or refuses with `Left` when the safety policy is a non-empty Claude tool
allow-list.
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
