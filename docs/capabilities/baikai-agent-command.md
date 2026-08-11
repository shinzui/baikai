---
title: "The baikai agent command and layered KDL job configuration"
type: Capability
description: "Give a shell script one stable command — printf '%s' \"$prompt\" | baikai agent run <job> --prompt-stdin — and move the choice of Claude Code or Codex, its permissions, paths, and limits into KDL configuration resolved across five layers, with the operator's safety ceiling read from the operator's own file and nowhere else."
generated:
  by: claude-code/opus-5
  at: "2026-08-10T00:00:00Z"
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
    proves: "Layer precedence in full — repository beats user, environment beats a file but loses to the command line — plus per-value attribution to file and line, a misspelled value failing rather than falling back to a valid one, a syntax error reported without echoing the document, raw provider arguments never reaching a report, and that neither a repository file nor a command-line override can raise the operator ceiling."
  - kind: test
    resource: baikai-agent/test/CliTests.hs
    proves: "The end-to-end command behaviour: the motivating launch runs with no provider flags in the invocation, changing only the provider line moves the run to codex, a refused job never reaches process creation, the agent's own exit code passes through unchanged, a missing binary exits 69, an empty prompt is a usage error rather than an expensive run, two prompt sources is a usage error, and show names each value's file and line while never printing a raw provider argument."
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
list containing the operator file and nothing else. No repository file,
environment variable, or command-line override can raise it, so checking out an
untrusted repository cannot widen what an agent is allowed to do there.
`safety.provider-args` is classified secret and renders as `<redacted>` in every
report and structured error, because raw provider arguments are the one part of a
job that can hold a credential.

Exit codes follow `sysexits`: the agent's own code passes through unchanged, and
baikai's own failures use 64 and above — 64 usage or empty prompt, 69 could not
start, 70 malformed output, 75 timeout, 77 policy refusal, 78 configuration.

This builds on [CAP-17 — unattended coding-agent runs](unattended-agent-runs.md),
which supplies the vocabulary, the ceiling algebra, and the runner it drives.

## Shape

```kdl
// .baikai/agents.kdl
job "review" {
  provider "claude"
  model "claude-opus-5"
  capability "read-only"
  output "capture"
}
```

## Limits

- Configuration discovery is **not** an upward search.
  `$XDG_CONFIG_HOME/baikai/agents.kdl` (or `$HOME/.config/baikai/agents.kdl`) and
  `./.baikai/agents.kdl` are the only paths; a job file in a parent directory is
  not found.
- The ceiling protects against an untrusted *repository*, not an untrusted
  operator. Anyone who can write the operator file can raise it.
- `--evidence-file` and `--require-evidence` exist but their usefulness is capped
  by configuration: an `inherit` job produces no observations at all, and a codex
  job can never satisfy a `model_observed` requirement. Both are refused up front
  rather than discovered after a run.
- An evidence-file write failure is reported on stderr and deliberately does not
  change the exit code, since the agent's own status is what a script branches on.
- `settei-formats` is deliberately excluded from the dependency set, because it
  bundles Dhall loading and repository configuration is untrusted input here.
- `baikai-agent` is at 0.1.0.0 and has not been through a compatibility cycle, so
  this capability is `experimental`.
