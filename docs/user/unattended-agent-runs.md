# Unattended Agent Runs

An **unattended run** starts a local coding agent — Claude Code or Codex —
with no terminal and no human present. The agent drives its own tool loop,
changes files inside directories you explicitly authorized, and finishes with
a process result. The interesting output is the changed working tree, not the
text.

This is Baikai's third integration surface, and the one a shell script talks
to. The other two are documented in `docs/user/cli-providers.md` (batch
completions through `claude -p` and `codex exec` that return a `Response`
value) and `docs/user/interactive-launches.md` (handing a real terminal to a
human and getting back an exit code when they quit). If your program wants a
text answer, you want the first. If a person is going to sit in front of it,
you want the second. If nobody is watching and the deliverable is a changed
working tree, you are in the right place.

This guide covers both halves of that surface: the `baikai agent` command a
script invokes, and the configuration that decides what the command does.

## Getting the command

The command ships in `baikai-agent`, which you install rather than depend on.
Installing it puts a `baikai` binary on your `PATH`:

```console
$ cabal install baikai-agent
$ baikai agent --help
```

The coding agent itself is not bundled: a job that names Claude Code needs
`claude` on `PATH`, and one that names Codex needs `codex`.

Inside this repository the package name `baikai` and the executable name
`baikai` collide, so `cabal run baikai` is ambiguous — use
`cabal run baikai-agent:exe:baikai` instead.

## The command

```text
baikai agent run <job>  [--prompt-stdin | --prompt-file PATH | --prompt TEXT]
                        [--set KEY=VALUE ...] [--config PATH] [--user-config PATH] [--json]
                        [--run-id TEXT] [--evidence-file PATH] [--require-evidence STRENGTH]
baikai agent show <job> [--set KEY=VALUE ...] [--config PATH] [--user-config PATH] [--json]
baikai agent list       [--config PATH] [--user-config PATH] [--json]
```

`--config` names the repository-scope document and `--user-config` the
operator-scope one, each overriding discovery for that scope alone. `--set`
overrides one setting of the selected job; its key is relative to the job, so
`--set output=capture` addresses `jobs.<job>.output`. A key that already begins
with `jobs.` is taken as written.

### Quick start

Write a job. The smallest useful one names a provider, a working directory, and
how much authority it wants:

```kdl
// ./.baikai/agents.kdl
jobs {
  reconcile {
    provider    "claude"
    working-dir "."
    safety { capability "edit-workspace" }
  }
}
```

Confirm it is there:

```console
$ baikai agent list
reconcile  repository configuration
```

Look at what it would do, without doing it:

```console
$ baikai agent show reconcile
job "reconcile"

effective configuration
  jobs.reconcile.effort = (unset)
  jobs.reconcile.env-requires = []
      from default rule no-required-environment
  jobs.reconcile.executable = (unset)
  jobs.reconcile.extra-dirs = []
      from default rule no-extra-dirs
  jobs.reconcile.model = (unset)
  jobs.reconcile.output = inherit
      from default rule inherit-output
  jobs.reconcile.output-limit = Just 4194304
      from default rule default-output-limit
  jobs.reconcile.provider = "claude"
      from repository configuration at .baikai/agents.kdl:4:17
  jobs.reconcile.safety.allowed-tools = []
      from default rule no-tool-restriction
  jobs.reconcile.safety.capability = "edit-workspace"
      from repository configuration at .baikai/agents.kdl:6:25
  jobs.reconcile.safety.provider-args = <redacted>
      from default rule no-provider-args
  jobs.reconcile.timeout = (unset)
  jobs.reconcile.working-dir = "."
      from repository configuration at .baikai/agents.kdl:5:17

policy ceiling, from built-in default (no operator configuration file)
  max-capability       edit-workspace
  allow-provider-args  false
  allowed-providers    claude, codex

rendered command
  claude
    -p
    --no-session-persistence
    --permission-mode acceptEdits
  prompt transport: standard input (the prompt appears nowhere in the argument vector)
```

Every declared setting is listed, including the ones no layer set —
`(unset)` for an optional setting with no value, and the named default rule
that produced the rest. Values declared with a `Show`-based renderer keep their
Haskell spelling, which is why some carry quotes and `output-limit` reads
`Just 4194304`. The line and column are the position of the value in the file
that supplied it.

Then run it:

```bash
printf 'reconcile the grammar with the lexer' | baikai agent run reconcile --prompt-stdin
```

### `baikai agent list`

Prints one line per configured job — the name and the scope whose definition
won — sorted by name so the output is stable enough to diff. A name defined in
both scopes is reported once, with a note that another scope also defines it.

An empty list is a normal state, not an error: the command exits 0, prints
nothing on standard output, and says `no jobs are configured` on standard
error. A script piping the list never has to filter prose out of its data.

### `baikai agent show`

Performs the entire pipeline **except** spawning, and prints what it found.
This is the command to reach for when a run did something you did not expect.

It prints, in order: every resolved value with the file, line, and column it
came from or the default rule that produced it; the policy ceiling in force and
where it was read from; and the exact argument vector that would be spawned,
plus where the prompt would travel. `show` takes no prompt, so the prompt is
shown as supplied at run time rather than as a configured value.

A job whose policy is refused — because it exceeds the ceiling, or because the
provider cannot express it — still prints its configuration, and *then* the
refusal, so you see both what was asked for and why it was denied. Printing
nothing, or printing the configuration and silently omitting the command, would
hide the case you most need the command for.

Raw provider arguments appear as `<redacted>`, both in the effective
configuration and in the rendered argument vector. See
[Redaction](#redaction).

### `baikai agent run`

Resolves the job, caps it against the ceiling, renders the argument vector, and
spawns the tool. The prompt comes from exactly one of `--prompt-stdin`,
`--prompt-file PATH`, or `--prompt TEXT`; supplying two is a usage error rather
than a silent precedence puzzle, and an empty prompt from any of them is a
usage error too. An unattended agent given no instruction does something
unpredictable and expensive, so failing immediately is the kinder outcome.

The prompt is read as bytes and decoded as UTF-8 explicitly, not through the
handle's locale encoding, so a prompt containing interpolated paths or
non-ASCII text survives a machine without a UTF-8 locale.

### Recording what a run was

Two options ask Baikai to write down what it did, so an automation job produces
a reviewable record as a side effect of running:

| option | meaning |
|--------|---------|
| `--evidence-file PATH` | write the run's evidence record to `PATH` as one JSON object |
| `--run-id TEXT` | the identifier for the logical run this invocation belongs to |
| `--require-evidence STRENGTH` | refuse to start unless the run can produce evidence of at least this strength |

Supplying neither leaves the run exactly as it was before evidence existed, and
costs exactly what it cost before: nothing is hashed, no identifier is
generated, and the tool is not invoked a second time to read its version.
Supplying either turns the recording on. With `--evidence-file` but no
`--run-id`, the job's own name stands in as the run identifier; Baikai treats
that value as opaque text and never parses it.

The record is written atomically — a uniquely named staging file beside the
destination, followed by a rename — so a reader polling the path never sees a half-written
object. It is never appended to: each run writes one complete record, so a
script wanting a log of many runs should point each run at its own path. A run
that never started, because the executable was missing or a precondition
failed, writes nothing at all; an empty file would claim a run happened.
Failing to write the file is reported on standard error and never changes the
exit code, because the agent's own status is what a calling script branches on.

A run that was killed by its timeout **does** get a record, with a status of
`aborted`. That run started, consumed tokens, and may have changed the working
tree, which is precisely the case where an operator most wants to know what
happened.

`--require-evidence` takes one of `requested_only`, `correlated`,
`model_observed`, or `fully_observed` — the same words a record's `strength`
field spells, so you read a record and pass the word back. It refuses **before
anything is spawned** when the requirement is impossible with this
configuration, exiting with the refusal code `77`:

```console
$ baikai agent run nightly --prompt-stdin --require-evidence correlated < prompt.txt
refused before starting, because this run cannot produce the evidence it
required: this transport can reach at most requested_only evidence, and the
call required correlated
```

That example is an `inherit` job: the agent's bytes go to your terminal and
Baikai never holds them, so nothing the tool reports can be observed however
well the run goes. The gate is structural rather than predictive — it refuses
what is impossible, and stays quiet when the requirement is merely uncertain.
A run that *could* have reported what you needed and did not says so in its own
record's `strength`; failing it after the fact would destroy the report of work
that really happened.

```bash
baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --run-id nightly-2026-08-05 \
  --evidence-file /var/log/baikai/nightly.json < prompt.txt
```

#### What the record proves, and what it does not

The record states what Baikai **requested**, what it **translated** that request
into on the tool's command line, and what it **observed** the tool report back.
Those three are kept separate and are never collapsed: a field the tool did not
report reads as `"unobserved"` and is never filled in from the request.

It is not a claim about what happened inside the provider, and it is not signed.
A tool that exits zero has demonstrated that it ran and did not crash — it has
not stated which model served the request, so a clean exit never raises the
record's `strength`. Since almost every unattended run exits zero, that rule is
the difference between a record that means something and one that does not.

The two digests are worth understanding. `request_commitment` covers the
argument vector **and the prompt**, so anyone who independently holds the prompt
can confirm that a given record describes that run; publishing the digest
discloses nothing about the prompt itself. `request_configuration` covers the
request with its content removed, so it is safe to compare across runs that
legitimately differ in what they asked.

Getting a `strength` above `requested_only` from an unattended run takes two
things, and neither is the default. The job must **capture** output — under
`inherit` the agent's bytes went to your terminal and Baikai never held them —
and the tool must be configured to print a structured format, which means adding
`--output-format json` for `claude` or `--json` for `codex exec` through the
job's `provider-args`. Without both, the tool's session identifier, model, and
token counts are genuinely unavailable and the record says so.

### Exit codes

The agent's own exit code **passes through unchanged**. Baikai's own failures
start at 64 and follow the `sysexits` convention, so a script can tell "the
agent decided the task failed" from "the tool could not be started".

| code | meaning |
|------|---------|
| `0` | the agent ran and exited 0 |
| `n` (1…) | the agent ran and exited `n`, passed through unchanged |
| `64` | the command line could not be parsed, or the prompt was empty or ambiguous |
| `69` | the coding-agent executable could not be started |
| `75` | the run exceeded its timeout; its process group was interrupted, then terminated, then killed, and the output drained before the kill is reported |
| `77` | policy refused the run: the ceiling was exceeded, or the provider cannot express it |
| `78` | configuration was missing, unreadable, or invalid |

One ambiguity is real and is documented rather than hidden: if a provider ever
exits with a code of 64 or above, a script cannot tell it apart from a Baikai
failure. Coding agents conventionally exit 0 or 1, so in practice they do not
collide — and `--json` carries the unambiguous answer in its `outcome` field.

### Streams

| stream | content |
|--------|---------|
| standard output | the agent's output in `capture` mode; `agent show` and `agent list` output |
| standard error | every Baikai diagnostic, warning, and error; the agent's output in `inherit` and `tee` modes |

Baikai's own messages always go to standard error. The agent's output follows
the job's `output` setting, and which one to pick depends on what the script
wants:

- **`inherit`** when the script's log *is* the terminal. The agent writes
  straight to your streams; Baikai captures nothing. This is the default and
  what the motivating consumer uses.
- **`capture`** when the script wants `response=$(baikai agent run job)`. The
  agent's standard output becomes the command's standard output, and nothing
  else does — Baikai's diagnostics and the agent's own standard error both go
  to standard error, so the captured value is the answer and only the answer.
- **`tee`** when it wants both: the bytes stream to your terminal as they
  arrive *and* are retained under the byte limit.

Output truncated at `output-limit` is announced on standard error. A silently
truncated response that a script then parses is a bug waiting to happen.

A run that hits its timeout still reports what it drained, under exactly the
same rules. Under `capture`, `response=$(baikai agent run job)` receives the
partial answer and `$?` is 75, so a script that checks the status can decide
whether a partial answer is worth having; under `tee` the bytes were already
echoed as they arrived and are not printed twice; under `inherit` they went to
your terminal and Baikai has nothing to add. The timeout message itself is on
standard error, as every Baikai message is.

The command's own output is UTF-8 whatever the environment's locale says. That
matters where an unattended run actually happens — a cron entry, a systemd
unit, a container — because those give a process `LANG=C`, and encoding through
that locale would make a single accented character in the agent's answer fail
the write *after* the run had finished.

With `--json`, standard output carries exactly one JSON object per command
instead. For `agent run` that object is the outcome envelope, including the
captured streams when the job captures. A timed-out run's envelope carries
`outcome`, `exitCode` and `message` as every failure does, followed by the same
`stdout`, `stdoutTruncated`, `stderr` and `stderrTruncated` fields a finished
run would have — present only for a stream that was actually captured, so a
reader can still tell "the agent printed nothing" from "the bytes went to the
terminal".

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

## What a capability becomes

A capability profile is only trustworthy if you can see exactly what it turns
into — which is what `baikai agent show` prints, and what the tables below
document.

Claude Code:

| capability         | rendered flag                         |
|--------------------|---------------------------------------|
| `read-only`        | `--permission-mode plan`              |
| `edit-workspace`   | `--permission-mode acceptEdits`       |
| `full-access`      | `--permission-mode bypassPermissions` |

Every Claude run also gets `-p`, and `--no-session-persistence` unless the
renderer's `persistSession` is `True`.

The read-only mapping carries a caveat worth knowing before you rely on it.
Claude Code has no permission mode meaning exactly "may read, must not write".
Of its six modes, `manual` and `dontAsk` can block forever waiting for a human
and are unusable unattended, `acceptEdits` and `bypassPermissions` permit
writes, and `auto` delegates the decision to a classifier whose behavior is not
a stable contract. `plan` is the only mode that reliably does not modify the
tree — but it also frames the task as producing a plan, so a read-only Claude
run behaves differently from a read-only Codex run, which merely has a
restricted sandbox.

Codex:

| capability         | rendered flag                   |
|--------------------|---------------------------------|
| `read-only`        | `--sandbox read-only`           |
| `edit-workspace`   | `--sandbox workspace-write`     |
| `full-access`      | `--sandbox danger-full-access`  |

Every Codex run also gets `exec` and `--cd <working-dir>`, plus
`--skip-git-repo-check` and `--ephemeral` unless the renderer turns them off.

Three cross-provider facts matter more than the tables:

- **A tool allow-list is refused for Codex.** `codex exec` has no tool
  allow-list flag, so a job with a non-empty `safety.allowed-tools` and
  `provider "codex"` is refused with exit code 77 and a message naming the
  sandbox as the alternative. It is never run with unrestricted tools, because
  a caller who narrows the tool set and gets every tool has been handed more
  authority than they asked for. This is the one place where switching
  providers is not a one-line change — and you are told so, loudly, rather than
  silently given weaker isolation.
- **`extra-dirs` does not mean the same thing on both tools.** Claude Code
  documents `--add-dir` as additional directories to allow tool *access* to;
  `codex exec` documents it as additional directories that should be *writable*
  alongside the primary workspace.
- **The prompt never appears in the argument vector.** Both renderers deliver
  it on standard input, so a prompt beginning with a dash cannot be parsed as a
  flag or swallowed by a variadic flag such as `--allowedTools`. For Codex this
  also avoids a documented trap: if standard input is piped *and* a positional
  prompt is given, `codex exec` appends standard input as a `<stdin>` block.

Reasoning effort follows each tool's own vocabulary. Claude receives
`--effort`, whose values do not include `minimal`, so `minimal` maps up to
`low`. Codex receives `-c model_reasoning_effort=<level>` and takes all six
canonical levels unchanged. A blank `model` emits no `--model` flag on either
provider.

Raw provider arguments are appended verbatim after every structured flag and
are neither inspected nor rewritten. That channel is gated once, by the
operator ceiling — adding a second check that scans for dangerous flag
spellings would look like a security boundary that a renamed vendor flag
defeats.

## Migrating a script

The launch this surface was built for looks like this today, in
`scripts/sync-keiro-dsl.sh` in the `shinzui/keiro-syntax` repository:

```bash
claude -p "$prompt" \
  --add-dir "$keiro_path" \
  --permission-mode acceptEdits \
  --allowedTools Read Write Edit Glob Grep Bash Skill TodoWrite \
  || die "agent run failed"
```

Every one of those flags becomes configuration. In `.baikai/agents.kdl`:

```kdl
jobs {
  sync-keiro-dsl {
    provider    "claude"
    working-dir "."
    output      "inherit"
    safety {
      capability    "edit-workspace"
      allowed-tools "Read" "Write" "Edit" "Glob" "Grep" "Bash" "Skill" "TodoWrite"
    }
  }
}
```

and in the script:

```bash
printf '%s' "$prompt" | baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --set extra-dirs="$keiro_path" \
  || die "agent run failed"
```

Reading the translation piece by piece:

- `-p` and `--no-session-persistence` are implied by "this is an unattended
  run" and are rendered for you.
- `--permission-mode acceptEdits` becomes `capability "edit-workspace"`, which
  is the provider-neutral spelling of the same authority. Change `provider` to
  `"codex"` and it renders `--sandbox workspace-write` instead.
- `--allowedTools Read Write …` becomes `allowed-tools`, and Baikai joins the
  names with commas into one argument rather than passing them separately,
  because the flag is variadic and separate values can absorb a following flag.
- `--add-dir "$keiro_path"` stays on the command line as
  `--set extra-dirs="$keiro_path"`, because it is computed at run time from a
  registry lookup while everything else is static. Note the plural: the setting
  is `extra-dirs`, and `--set` sets it to a one-element list. A job that needs
  several directories states them in the file.
- `"$prompt"` moves to standard input. It is large, multi-line, and contains
  interpolated paths, and standard input is what makes that safe.
- `|| die` still works, because the agent's exit code propagates unchanged.
- `output "inherit"` keeps the script's existing behavior: the agent's output
  goes to the terminal the script inherited, exactly as before.

**What does not move.** The script keeps owning its lock, its dirty-tree check,
its test gate, its marker file, and its commit. This command runs a coding
agent; it is not a workflow engine, and it does not want to absorb the
deterministic parts of your pipeline. The only thing it takes over is the
launch.

Switching that job to Codex is a one-line edit — `provider "codex"` — with one
honest exception: `allowed-tools` has to go, because `codex exec` has no such
flag, and leaving it in is refused rather than silently ignored. See
[What a capability becomes](#what-a-capability-becomes).

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

Turning a resolved job into something that runs takes two more steps: render it
to an argument vector with `claudeAgentCommand` or `codexAgentCommand`, and
spawn it with `runAgentCommand` from `Baikai.Agent.Run`. See
`docs/user/interactive-launches.md` for the vocabulary those share.

The `baikai` executable is itself a thin wrapper over `Baikai.Agent.Cli`, whose
`runAgentCli` returns a record rather than writing to streams or exiting:

```haskell
data AgentCliRun = AgentCliRun
  { exitCode :: !Int, standardOutput :: !Text, standardError :: !Text }

runAgentCli          :: EnvSnapshot -> AgentCliOptions -> IO AgentCliRun
runAgentCliWithPaths :: AgentConfigPaths -> EnvSnapshot -> AgentCliOptions -> IO AgentCliRun

renderJobCommand ::
  AgentJob ->
  AgentRunRequest ->
  Either AgentRenderError (AgentCommand, ThinkingTranslation)
```

`runAgentCli` discovers the two configuration files; `runAgentCliWithPaths`
takes them explicitly, which is what a test wants. `renderJobCommand` is the
single point in the codebase that knows both providers.

The translation half of that pair describes what the job's reasoning effort
became on the chosen provider's command line. It travels alongside the command
because the runner deliberately imports no vendor renderer and so cannot derive
it — see [Model-Call Evidence](model-call-evidence.md).

Note that under `inherit` and `tee` the agent's own output goes straight to the
real process streams and never enters `AgentCliRun`. That is intended — it is
what a script whose log is the terminal wants — and it means a caller cannot
observe inherited output by inspecting the record.
