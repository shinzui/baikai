---
title: "The baikai agent command and layered KDL job configuration"
type: Capability
description: "Give a shell script one stable command — printf '%s' \"$prompt\" | baikai agent run <job> --prompt-stdin — and move the choice of Claude Code or Codex, its permissions, paths, and limits into KDL configuration resolved across five layers, with the operator's safety ceiling read from the operator's own file and nowhere else."
generated:
  by: claude-code/opus-5
  at: "2026-08-27T00:00:00Z"
capabilityId: CAP-18
provider: mori://shinzui/baikai
status: shipped
stability: experimental
since: "0.1.0.0"
packages:
  - baikai-agent
interface:
  - baikai agent run
  - baikai agent show
  - baikai agent list
  - Baikai.Agent.Config
  - Baikai.Agent.Cli
requires:
  - CAP-17
evidence:
  - kind: test
    resource: baikai-agent/test/ConfigTests.hs
    proves: "Layer precedence in full — repository beats user, environment beats a file but loses to the command line — plus per-value attribution to file and line, a misspelled value failing rather than falling back to a valid one, a syntax error reported without echoing the document, raw provider arguments never reaching a report, that neither a repository file nor a command-line override can raise the operator ceiling, that an operator file inside the repository is refused outright, that an unrecognised key under policy is an error while another job's keys are not even warned about, and the repository-scope refusals for executable, extra-dirs and an out-of-root working-dir."
  - kind: test
    resource: baikai-agent/test/CliTests.hs
    proves: "The end-to-end command behaviour: the motivating launch runs with no provider flags in the invocation once its operator file grants the tools it asks for, a repository tool grant without that operator grant is refused, changing only the provider line moves the run to codex, a refused job never reaches process creation, the agent's own exit code passes through unchanged, a missing binary exits 69, an empty prompt is a usage error rather than an expensive run, two prompt sources is a usage error, asking for an evidence record with nowhere to put it is a usage error while --json carries it in the envelope, a planted staging file is never written through, show emits one envelope shape under --json whatever happened, and show names each value's file and line while never printing a raw provider argument."
  - kind: test
    resource: baikai-agent/test/BinaryTests.hs
    proves: "The built executable rather than the test binary: it reports the threaded runtime, and `baikai agent run` against a stub agent that ignores INT and TERM exits 75 within the grace periods, leaves no process of the group alive, reports the output drained before the kill, and writes its result as UTF-8 under LANG=C."
  - kind: guide
    resource: docs/user/unattended-agent-runs.md
    proves: "The three commands with their flags, exit codes, and stream discipline; the KDL job format and layer precedence; the operator ceiling and redaction; and a before-and-after migration of a script that embeds provider flags today."
---

# The baikai agent command and layered KDL job configuration

`cabal install baikai-agent` puts a `baikai` binary on `PATH` with three
subcommands. The point is to get provider flags out of shell scripts: the script
invokes one stable command and the choice of Claude Code or Codex lives in a
configuration file.

```console
$ printf '%s' "$prompt" | baikai agent run review --prompt-stdin
```

`Baikai.Agent.Config` resolves a named job across five layers — built-in
defaults, the operator file, the repository file, the environment, then
command-line overrides, later layers winning — and returns a report attributing
**every value to the file, line, and column it came from**. The
`agent show` command prints exactly that, plus the ceiling in force, plus the
argument vector that *would* be spawned, without starting anything.

The safety ceiling is loaded by a separate function against a separate source
list containing the operator file and nothing else, and that file must lie
outside the repository — an operator file under the checkout is refused with
exit 78 and no ceiling is established, which closes both
`--user-config .baikai/policy.kdl` and `XDG_CONFIG_HOME=$PWD/.baikai`. No
repository file, environment variable, or command-line override contributes to
the ceiling, so checking out an untrusted repository cannot widen what an agent
is allowed to do there. What the ceiling does **not** claim is protection from
whoever controls the process environment: `--user-config`, `XDG_CONFIG_HOME`
and `HOME` are how an operator says where their file is.

Every field a repository file can set is gated: bounded by a ceiling maximum,
refused from repository scope (`executable`, `extra-dirs`), or confined to the
repository root (`working-dir`). `safety.provider-args` is classified secret and
renders as `<redacted>` in every report and structured error, because raw
provider arguments are the one part of a job that can hold a credential.

Exit codes follow `sysexits`: the agent's own code passes through unchanged, and
baikai's own failures use 64 and above — 64 usage or empty prompt, 69 could not
start, 75 timeout, 77 policy refusal, 78 configuration.

This builds on [CAP-17 — unattended coding-agent runs](unattended-agent-runs.md),
which supplies the vocabulary, the ceiling algebra, and the runner it drives.

## Shape

```kdl
// .baikai/agents.kdl
jobs {
  review {
    provider      "claude"
    working-dir   "."
    model         "claude-opus-5"
    output        "capture"
    output-format "json"
    safety { capability "read-only" }
  }
}
```

## Limits

- Configuration discovery is **not** an upward search.
  `$XDG_CONFIG_HOME/baikai/agents.kdl` (or `$HOME/.config/baikai/agents.kdl`) and
  `./.baikai/agents.kdl` are the only paths; a job file in a parent directory is
  not found.
- The ceiling protects against an untrusted *repository*, not an untrusted
  operator. Anyone who can write the operator file — or choose the flags and
  environment that select it — can raise it.
- `--run-id` and `--require-evidence` need a destination: without either
  `--evidence-file` or `--json` they are a usage error, because a record that is
  built and dropped costs a `--version` probe and two digests and proves
  nothing.
- `--evidence-file` and `--require-evidence` exist but their usefulness is capped
  by configuration: an `inherit` job produces no observations at all, and a codex
  job can never satisfy a `model_observed` requirement. Both are refused up front
  rather than discovered after a run.
- An evidence-file write failure is reported on stderr and deliberately does not
  change the exit code, since the agent's own status is what a script branches on.
- `settei-formats` is deliberately excluded from the dependency set, because it
  bundles Dhall loading and repository configuration is untrusted input here.
- `baikai-agent` is at 0.2.0.0 and has not been through a compatibility cycle, so
  this capability is `experimental`.
