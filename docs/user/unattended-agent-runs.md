# Unattended Agent Runs

An **unattended run** starts a local coding agent — Claude Code or Codex —
with no terminal and no human present. The agent drives its own tool loop,
changes files inside directories you explicitly authorized, and finishes with
a process result. The interesting output is the changed working tree, not the
text.

This is Baikai's third integration surface. The other two are documented in
`docs/user/cli-providers.md` (batch completions returning a `Response`) and
`docs/user/interactive-launches.md` (handing a real terminal to a human).

This guide covers the **configuration** side: how a repository describes a
named job, how an operator caps what any job may ask for, and which layer wins
when two of them disagree.

## The two files

Configuration lives in two KDL documents, and which one a value came from
matters more than it usually would, because they are trusted differently.

| File | Path | Trust |
|------|------|-------|
| Operator scope | `$XDG_CONFIG_HOME/baikai/agents.kdl`, or `$HOME/.config/baikai/agents.kdl` when `XDG_CONFIG_HOME` is unset | Yours. The only place the safety ceiling is read from. |
| Repository scope | `./.baikai/agents.kdl`, relative to the working directory | **Untrusted input.** Somebody else wrote it. |

Neither file has to exist. A missing file is a normal state, not an error.

The repository path is the working directory's `.baikai/agents.kdl` and
**nothing else** — there is no upward search through parent directories. An
upward search would make the effective configuration depend on where the
process happened to start, and a job could silently pick up a file from a
directory outside the repository it believes it is working in. For a file that
grants filesystem authority, that is an unacceptable surprise. Scripts
already `cd` to their repository root.

## The repository file

A repository names jobs. Here is the complete shape, with every setting:

```kdl
jobs {
  sync-keiro-dsl {
    provider     "claude"          // required: claude | codex
    working-dir  "."               // required
    executable   "/usr/bin/claude" // optional: overrides PATH lookup
    model        "sonnet"          // optional
    effort       "high"            // optional: minimal|low|medium|high|xhigh|max
    extra-dirs   "/path/one"       // optional list; default empty
    timeout      "45m"             // optional; no limit when omitted
    output       "inherit"         // inherit | capture | tee; default inherit
    output-limit 4194304           // bytes per stream; default 4194304
    env-requires "KEIRO_PATH"      // optional list of names; never values
    safety {
      capability    "edit-workspace"        // required
      allowed-tools "Read" "Write" "Edit"   // optional; refused for codex
      provider-args "--betas" "context-1m"  // optional; SECRET, operator opt-in
    }
  }
}
```

Three settings are **required** and have no default: `provider`,
`working-dir`, and `safety.capability`. The capability has no default on
purpose — a job that forgot to state how much authority it wants must not
silently receive some.

### Setting reference

| Setting | Type | Required | Default |
|---------|------|----------|---------|
| `provider` | `claude` \| `codex` | yes | — |
| `working-dir` | path | yes | — |
| `safety.capability` | `read-only` \| `edit-workspace` \| `full-access` | yes | — |
| `executable` | path | no | resolved on `PATH` |
| `model` | text | no | the tool's own default |
| `effort` | `minimal` \| `low` \| `medium` \| `high` \| `xhigh` \| `max` | no | the tool's own default |
| `extra-dirs` | list of paths | no | empty |
| `timeout` | duration | no | no limit |
| `output` | `inherit` \| `capture` \| `tee` | no | `inherit` |
| `output-limit` | bytes, or `"unlimited"` | no | `4194304` (4 MiB) |
| `env-requires` | list of variable names | no | empty |
| `safety.allowed-tools` | list of tool names | no | empty (no narrowing) |
| `safety.provider-args` | list of raw arguments | no | empty |

A few settings deserve a note.

**`extra-dirs` does not mean the same thing on both providers.** Claude Code
documents `--add-dir` as "additional directories to allow tool access to";
`codex exec` documents it as "additional directories that should be writable
alongside the primary workspace". The field grants read-or-write authority on
Claude and write authority on Codex. It is not fully neutral, and it is worth
knowing which one you are configuring.

**`env-requires` is names only, never values.** It does not restrict the
child's environment — the agent inherits yours in full, because both tools
need `HOME`, `PATH`, and their own credential files. What it buys is a
precondition check: the run fails before spawning when a declared variable is
unset or empty, so a misconfigured job produces one clear error instead of an
agent that starts and then flails.

**A duration carries its unit.** `"90s"` is ninety seconds, `"45m"` is
forty-five minutes, `"2h"` is two hours. A bare number means seconds, so
`"45"` and `45` are both forty-five seconds. Zero and negative values are
**rejected** rather than treated as "no timeout": `timeout "0"` would mean
"kill every run immediately", which nobody intends and which would be baffling
to diagnose. Omitting the setting is how a run goes untimed.

**`output-limit` is per stream, not in total.** Write `"unlimited"` to remove
the bound. The default is concrete rather than unbounded because an operator
who never mentions a limit should not be one runaway agent away from
exhausting memory.

### Lists take one value, several, or none

All three of these are valid, and all three decode:

```kdl
extra-dirs                        // no arguments  -> empty list
extra-dirs "/only"                // one argument  -> one-element list
extra-dirs "/first" "/second"     // two or more   -> two-element list
```

This matters because a KDL node's shape depends on how many arguments it has,
and a naive reader would accept only the third form.

## The operator file

An operator's file can do everything a repository file can, and one thing a
repository file cannot: set the **policy ceiling**.

```kdl
// ~/.config/baikai/agents.kdl
policy {
  max-capability      "edit-workspace"   // read-only | edit-workspace | full-access
  allow-provider-args #false
  allowed-providers   "claude" "codex"
}

// Defaults every job in every repository inherits, unless it says otherwise.
jobs {
  sync-keiro-dsl {
    timeout "20m"
  }
}
```

Setting only one of the three policy settings is fine; the rest keep their
defaults.

## Precedence

Five layers. Later layers win.

| # | Layer | Can set job settings | Can set the ceiling |
|---|-------|----------------------|---------------------|
| 1 | Built-in defaults | yes | yes (the default) |
| 2 | Operator file | yes | **yes** |
| 3 | Repository file | yes | **no** |
| 4 | Environment | `provider`, `model`, `executable`, `timeout` only | **no** |
| 5 | Command line | yes | **no** |

A worked example. Suppose `provider` is set in three places:

```kdl
// 2. ~/.config/baikai/agents.kdl
jobs { demo { provider "codex" } }
```

```kdl
// 3. ./.baikai/agents.kdl
jobs { demo { provider "claude" } }
```

```bash
# 5. the command line
--set jobs.demo.provider=codex
```

The command line wins, so the job runs `codex`. Remove the flag and the
repository file wins, so it runs `claude`. Remove the repository file too and
the operator's `codex` is what is left.

A malformed value in a higher layer **fails** rather than falling back to a
valid lower one. If the repository file says `capability "edit-worksapce"`,
resolution stops with an error naming `jobs.demo.safety.capability`; it does
not quietly activate whatever the operator's file said. A typo in an untrusted
file must not silently change which policy is in force.

### The environment layer is deliberately narrow

Exactly four variables are bound:

| Variable | Sets |
|----------|------|
| `BAIKAI_AGENT_PROVIDER` | `provider` |
| `BAIKAI_AGENT_MODEL` | `model` |
| `BAIKAI_AGENT_EXECUTABLE` | `executable` |
| `BAIKAI_AGENT_TIMEOUT` | `timeout` |

The capability, the tool list, and the raw provider arguments are **not**
bound, and this is not an oversight. An environment variable is easy to set
accidentally and is inherited by every child process; letting one widen a
job's authority would create exactly the ambient influence the ceiling exists
to prevent.

## The ceiling

A repository configuration file is untrusted input. An automation daemon that
encounters a checkout is reading a file somebody else wrote, and that file
could ask for unrestricted filesystem access. The ceiling is what stops it.

**The ceiling is read from the operator file and from nowhere else.** No
repository file, no environment variable, and no command-line flag can raise
it. A ceiling any lower layer could raise is not a ceiling: if the repository
file could set `policy.max-capability` an untrusted checkout would grant
itself whatever it liked, and if a `--set` override could, then
`--set policy.max-capability=full-access` would defeat the mechanism outright
— which is exactly the flag a compromised automation script would add.

A repository file *may contain* a `policy` node. It simply has no effect on
the ceiling. It is not an error, and it is not silently honored either; it is
ignored.

### With no operator file

The default ceiling permits **read-only** and **edit-workspace** capability,
refuses **full-access**, and refuses raw provider arguments. Both providers
are permitted.

That default is what makes a job that changes files work on a fresh machine
with no out-of-band setup step, while the two things that can widen authority
without bound — sandbox-bypassing modes and arbitrary vendor flags — stay
opt-in at operator scope.

### Exceeding it is a refusal, not a downgrade

A job that asks for more than the ceiling permits is **refused**. It is never
clamped to the permitted value. Silent clamping is how a job that believes it
may edit ends up doing nothing and reporting success.

The refusal names what was asked for and what is permitted:

```text
the request exceeds the permitted policy ceiling: requested capability
full-access exceeds the permitted maximum edit-workspace
```

The other two violations read:

```text
raw provider arguments are not permitted: --betas context-1m
provider codex is not permitted; permitted providers: claude
```

Every violation is reported, not just the first, so fixing a job description
takes one pass rather than three.

## Redaction

`safety.provider-args` is classified **secret**. It is the one setting an
operator could write a credential into — nothing stops `--api-key sk-…` from
appearing there — and Baikai converts a secret-classified value to an opaque
redacted form before it can enter a resolution report or a structured error.

In any effective-configuration report, raw provider arguments render as:

```text
jobs.sync-keiro-dsl.safety.provider-args = <redacted>
```

The key name still appears, because redacting the value should not hide that
the setting was set. To see the arguments themselves, read the file you wrote
them in.

Every other setting is public, because none of them can hold a credential by
construction: environment variables are referenced by name and never by value,
and both coding agents keep their own credentials in their own stores.

## Where a value came from

Every resolution carries a report attributing each chosen value to the file it
came from, including the exact line and column. Two renderings exist:
`renderResolutionText` names the scope and shows what each value shadowed, and
`renderResolutionJson` additionally carries the path, line, and column of every
origin.

```text
jobs.demo.provider = "claude"
  from file source repository configuration (KDL v2)
  shadowed: file source user configuration (KDL v2)
jobs.demo.output = inherit
  from default rule inherit-output
jobs.demo.safety.provider-args = <redacted>
  from default rule no-provider-args
```

## Using it from Haskell

The configuration layer lives in `Baikai.Agent.Config` in the `baikai-agent`
package:

```haskell
resolveAgentJob ::
  AgentConfigPaths -> EnvSnapshot -> [CliOverride] -> Text ->
  IO (Either AgentConfigError (ResolveResult AgentJob))

loadAgentCeiling  :: AgentConfigPaths -> IO (Either AgentConfigError AgentCeiling)
applyCeilingToJob :: AgentCeiling -> AgentRunRequest -> Either AgentRenderError AgentRunRequest

agentJobRequest :: AgentJob -> Text -> AgentRunRequest   -- the prompt arrives at call time
listAgentJobs   :: AgentConfigPaths -> IO (Either AgentConfigError [AgentJobEntry])
```

`defaultAgentConfigPaths` locates the two files described above, setting each
to `Nothing` when it does not exist. The paths are an explicit record so a
caller — or a test — can point somewhere else.

The ceiling is a **separate call** from job resolution, with a separate source
list. That asymmetry is the security property, so it is two functions rather
than one function with a flag.

Turning a resolved job into something that runs takes three more steps: render
it to an argument vector with `claudeAgentCommand` or `codexAgentCommand`, and
spawn it with `runAgentCommand` from `Baikai.Agent.Run`. See
`docs/user/interactive-launches.md` for the vocabulary those share.
