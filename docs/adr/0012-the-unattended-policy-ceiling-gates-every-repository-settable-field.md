---
title: The unattended policy ceiling gates every field a repository can set, and allowedTools is a grant
status: accepted
date: 2026-08-27
---

# The unattended policy ceiling gates every field a repository can set, and allowedTools is a grant

## Context

`baikai agent run <job>` starts a coding agent — Claude Code or Codex —
with no human present, from a job described in a KDL file that the
repository being worked on owns. An automation daemon that checks out a
repository is reading a file somebody else wrote: it is untrusted input.
The **policy ceiling** is the operator-owned limit that stands between
that file and the operator's machine. It is read from the operator's own
file and nowhere else, and `applyAgentCeiling` is the pure check.

The first ceiling checked three things: the provider, the capability, and
whether the raw-argument channel was open. A job description has nine
settings a repository file can write, and the other six were unbounded.
A repository file could name the program to run (`executable
"./scripts/run.sh"`), point the run at the operator's home (`extra-dirs
"/Users/op/.ssh"`, which is write access on Codex), remove the memory
bound (`output-limit "unlimited"`), and run untimed.

The sharpest of the six was the tool list. `AgentSafety.allowedTools` was
documented as an "optional narrowing of the provider's tool set", and
`applyAgentCeiling` never looked at it. It is not a narrowing. On Claude
Code it renders `--allowedTools`, whose help at 2.1.247 reads "Comma or
space-separated list of tool names to allow"; the flag pre-approves the
named tools so the permission mode never raises a request for them, and
in an unattended run a permission request nobody answers is denied. So

```kdl
safety {
  capability    "edit-workspace"
  allowed-tools "Bash"
}
```

in a repository file passed the ceiling and gave an unattended run
arbitrary shell access under a capability whose whole meaning is "may
change files in its working directory". The narrowing flags Claude Code
also has are `--tools` and `--disallowedTools`; baikai models neither.

One shape of the ceiling's own provenance was also open. The operator
file is chosen by `--user-config`, else `XDG_CONFIG_HOME`, else `HOME` —
so `--user-config .baikai/policy.kdl`, or `XDG_CONFIG_HOME=$PWD/.baikai`,
made a file the repository controls *be* the ceiling, while the guide
promised that no repository file, environment variable or flag could
raise it.

## Decision

**Every setting a repository file can write is bounded by the ceiling,
refused from repository scope, or confined to the repository root.** The
three treatments are:

- *Bounded*: `provider`, `safety.capability`, `safety.allowed-tools`,
  `safety.provider-args`, `timeout`, `output-limit`. The ceiling carries
  a maximum for each and refuses a job that exceeds it, naming both
  values. `policy.max-output-limit` defaults to a finite 67108864 bytes,
  because the memory belongs to the operator's host; `policy.max-timeout`
  defaults to unlimited, because time is a budget every site sets
  differently and a finite default would break every job that omits
  `timeout`. Where a maximum is finite it also refuses a job that
  requests *no* limit at all, because a maximum defeated by omitting the
  setting is not a maximum.
- *Operator-only*: `executable` and `extra-dirs`. A repository value is
  `RepositoryScopeForbidden`, exit 77. `executable` turns configuration
  into code execution with the operator's environment and the prompt on
  standard input. `extra-dirs` inside the root adds nothing the working
  directory already gives, so the only extra directories a checkout would
  ask for are outside it. Neither is bound to an environment variable
  either: `BAIKAI_AGENT_EXECUTABLE` is removed.
- *Confined*: `working-dir`. A repository value must resolve inside the
  repository root after canonicalisation, so a committed symbolic link
  cannot leave it. The root is the directory the process runs in, carried
  explicitly as `AgentConfigPaths.repositoryRoot`; `--config PATH` chooses
  which file supplies repository settings and does not move the root.

**`allowedTools` is a grant.** The permitted set is what the maximum
capability implies, extended by an operator allow-list
`policy.allowed-tools`. `read-only` implies `Read`, `Glob`, `Grep`,
`NotebookRead`, `TodoWrite`; `edit-workspace` adds `Edit`, `MultiEdit`,
`Write`, `NotebookEdit`; `full-access` implies every grant. Matching is
exact on the whole string, so `Bash(git *)` is not `Bash`. `Bash` is in no
finite implied set: it runs arbitrary commands, which is what
`full-access` means.

**The ceiling file must lie outside the repository.** An operator file
whose canonical path is the repository root or under it is refused with
exit 78 and no ceiling is established. `--user-config`,
`XDG_CONFIG_HOME` and `HOME` remain operator inputs: the ceiling is
exactly as trustworthy as the process environment that selects it, and
the guide now says so rather than promising more.

**An unrecognised key under the operator file's `policy` node is an
error**, not a warning. Everywhere else a forward-compatible file should
not stop an older binary; for the one node whose purpose is limiting
authority, a misspelling that silently leaves the default in force is
indefensible.

Two violations — `RepositoryScopeForbidden` and
`WorkingDirOutsideRepository` — depend on *which file* supplied a value,
and `applyAgentCeiling` sees a request rather than its provenance. They
are produced by the configuration layer from the resolution report
(`repositoryScopeViolations`) and concatenated with the pure check's
list, so an operator sees one refusal naming every problem.

## Consequences

Adding a job setting now means deciding, in the same change, which of the
three treatments it gets, and writing the test that pins it. A setting
added without that decision defaults to *bounded by nothing*, which is
the state this record exists to end.

The implied grant lists are Claude Code's built-in tool names at version
2.1.247, and they fail closed: a name that is not listed can only ever be
refused unless the maximum capability is `full-access` or the operator
names it. A coding agent that grows a new tool therefore cannot widen an
existing ceiling by accident; the cost is that an operator adopting a new
tool has to say so, which is the direction the error should point.

The change is breaking for existing repositories in two ways an operator
must act on. A job that set `executable` in its repository file moves that
line to the operator file or to `--set`. A job that granted a tool outside
its capability's implied set — which the motivating consumer does, with
`Bash` and `Skill` under `edit-workspace` — needs
`policy { allowed-tools "Bash" "Skill" }` in the operator's own file,
once. Both refusals name the setting and the fix.

For a library caller, the default ceiling now refuses a request whose
`outputLimit` is `Nothing`, because capture without bound is what the
finite maximum exists to refuse. Jobs resolved through `baikai-agent` are
unaffected: that layer's own default supplies a finite limit, and only an
explicit `output-limit "unlimited"` reaches the ceiling as `Nothing`.

The related record [0005](0005-what-baikai-deliberately-does-not-do.md)
still holds and bounds this one: the ceiling is the operator's policy
about a run baikai spawns, not baikai's judgement about what anyone
should be allowed to do.
