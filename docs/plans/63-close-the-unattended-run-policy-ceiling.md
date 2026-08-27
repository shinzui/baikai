---
id: 63
slug: close-the-unattended-run-policy-ceiling
title: "Close the unattended-run policy ceiling"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Close the unattended-run policy ceiling

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

`baikai agent run <job>` starts a coding agent — Claude Code or Codex — with no human present,
from a job described in a KDL file that the repository being worked on owns. That file is
untrusted input: an automation daemon that checks out a repository is reading a file somebody
else wrote. The **policy ceiling**, an operator-owned limit read from the operator's own file and
nowhere else, is what is supposed to stop that file from granting itself more authority than the
operator permits. Today it checks the provider, the capability, and the raw-argument channel, and
nothing else. A repository file can name the program to run (`executable "./scripts/run.sh"`),
point the run at the operator's home (`extra-dirs "/Users/op/.ssh"`, write access on Codex),
remove the memory bound (`output-limit "unlimited"`), and — the finding that motivates this plan —
write `allowed-tools "Bash"` under `capability "edit-workspace"`, which passes the ceiling and
renders `--allowedTools Bash`. On Claude Code that flag is a **grant**: it pre-approves a tool the
permission mode would otherwise refuse, so an unattended run gets shell access the operator never
authorised. The guide also promises that no environment variable or flag can raise the ceiling,
while `--user-config .baikai/policy.kdl` or `XDG_CONFIG_HOME=$PWD/.baikai` makes a file the
repository controls *be* the ceiling.

After this plan, every setting a repository file can write is bounded by the ceiling or refused
from repository scope, the tool list is modelled and documented as the grant it is, and a ceiling
file inside the repository is refused. Concretely: with no operator file, a repository
`.baikai/agents.kdl` whose job `review` sets `allowed-tools "Bash"` under `edit-workspace` makes
`baikai agent run review --prompt "look"` exit `77` and print `refused: the request exceeds the
permitted policy ceiling: tool grants Bash are not permitted under the maximum capability
edit-workspace; add them to policy.allowed-tools in the operator file or raise
policy.max-capability`, before any process is created. A repository `executable` or `extra-dirs`
is refused naming the setting; a repository `working-dir` outside the repository root is refused
naming both paths; a `timeout` or `output-limit` above the operator's maximum is refused naming
both values. An operator who wants the old behaviour writes `policy { allowed-tools "Bash" }` in
their own file, once.

The plan also closes the smaller truthfulness gaps the review found here — unknown-key warnings
for other jobs and the operator's `policy` node, `--run-id` and `--require-evidence` building a
record that goes nowhere, an exit code `70` nothing produces, an evidence `endpoint` resolved
against the wrong directory, an `errorInfo` embedding up to four mebibytes of standard error, and
a predictable staging path that follows a pre-planted symlink — and makes the surface changes that
must land before `baikai-agent` 0.2: `envPassthrough` renamed, a structured-output setting so
evidence no longer needs the privileged `provider-args` channel, a defined base for a relative
`working-dir`, and a `show --json` envelope on failure as on success.

**The observable outcome**, verifiable with one test command: the keyless `cabal test all` in
Concrete Steps passes with cases in which a repository document setting `executable`, one setting
`allowed-tools "Bash"` under `edit-workspace`, and one setting `extra-dirs` are each refused with
the named violation; a ceiling file inside the repository root is refused; and the
`sync-keiro-dsl` fixture, which today passes `Bash` through, runs only once its operator document
grants it.


## Progress

- [x] Milestone 1: ceiling gates every repository-settable field; `allowedTools` modelled as a
      grant. (2026-08-27) Core types, `applyAgentCeiling`, the three `policy` keys,
      `repositoryScopeViolations`, the reworked test harnesses and the twelve new cases all
      landed; the keyless `cabal test all` is green across all eight suites.
- [x] Milestone 2: ceiling-file provenance decided and documented. (2026-08-27) The
      refusal, the unknown-policy-key error and their four tests landed; the guide text
      the milestone decided is written in Milestone 4, with the rest of the documentation.
- [x] Milestone 3: CLI truthfulness (unknown-key noise, evidence flags, exit 70, endpoint,
      `errorInfo` bound, staging path). (2026-08-27) All six fixes landed with their tests;
      the guide's exit-code table and CAP-18's exit-code sentence lost their `70` row in the
      same commit.
- [ ] Milestone 4: 0.2 config-surface adjustments (`env-requires`, structured output,
      `show --json`), the ADR, the guide, both capability records, the changelog.


## Surprises & Discoveries

- __The finite `maxOutputLimit` default re-bases every ceiling test built from
  `agentRunRequest`.__ `agentRunRequest` defaults `outputLimit` to `Nothing`, meaning
  "capture without bound", and the plan's own decision makes a finite maximum refuse
  exactly that. So `applyAgentCeiling defaultAgentCeiling (agentRunRequest …)` — which
  five cases in `baikai/test/AgentSpec.hs` asserted was `Right` — became a refusal, and
  the two `Left` cases gained a second violation. Every case that is not itself about
  the output limit now starts from a local `bounded` helper that sets a limit, with the
  reason written beside it. This is the same shape EP-3 recorded for `Model.reasoning`:
  a gate added to a check re-bases every test that reached the checked path through a
  default-valued record, and the default is invisible at the call site. The behaviour
  itself is deliberate and is recorded in `CHANGELOG.md` under `[Unreleased]`: through
  `baikai-agent` it cannot arise, because that layer's own default supplies a finite
  limit and only an explicit `output-limit "unlimited"` reaches the ceiling as
  `Nothing`. (2026-08-27, Milestone 1)

- __Two top-level `jobs` nodes in one KDL document are an array, not a merge.__ The
  plan's fixtures build a document by concatenating `jobDoc "edit-workspace"` with a
  second document carrying only `executable`. settei-kdl reads the repeated node as an
  array and every key then fails to resolve with `cannot traverse jobs through array in
  file source repository configuration (KDL v2)` — a message that reads like a
  resolution bug rather than a malformed fixture. `jobDoc` now takes the extra lines and
  writes one node (`jobDocWith`), and the operator-scope fixtures use a single-node
  helper. Any later plan composing KDL fixtures by concatenation will hit this.
  (2026-08-27, Milestone 1)

- __`canonicalizePath` on macOS resolves `/etc` to `/private/etc`.__ The symlink-escape
  case asserted the violation named `/etc` exactly; it names the fully canonical path,
  which is the point — the check exists to defeat a committed link, so it reports where
  the link led. The assertion is now a suffix plus "not under the root".
  (2026-08-27, Milestone 1)

- __A test that sets a process-global environment variable races the fixture that
  reads it.__ The new `A REPOSITORY TOOL GRANT NEEDS AN OPERATOR GRANT` case began by
  setting `BAIKAI_TEST_CLAUDE_ARGV`, as the fixture it is a variant of does, and under
  tasty's parallel execution the two cases overwrote each other's value — one run in
  four failed somewhere in `baikai-agent-test`. The new case never reaches the runner
  (the ceiling refuses first), so it needs neither variable and now sets neither. This
  is the same shape EP-2 recorded for the process-global `ClientEnv` cache: a case that
  writes shared process state must either not do so or be folded into the case that
  reads it. (2026-08-27, Milestone 2)

- __`codex-cli` is at 0.150.1, not the 0.149.1 the plan expected.__ The four flags the
  plan's model rests on are unchanged: `claude` 2.1.247 still documents
  `--allowedTools` as a "list of tool names to allow", and `codex exec` still has
  `--json` and `--output-schema FILE`. The grant model is only right while that sentence
  is, so it was re-read rather than assumed. (2026-08-27, Milestone 1)


## Decision Log

- Decision: `allowedTools` keeps its name and KDL spelling `allowed-tools` and is re-documented as
  a **grant** everywhere it appears.
  Rationale: the name mirrors Claude Code's `--allowedTools`, whose help reads "list of tool names
  to allow"; what was wrong was the Haddock and guide, which called it a narrowing. Renaming would
  break every repository file to fix a comment. The narrowing flags `--tools` and
  `--disallowedTools` are not modelled; a later field can add them.
  Date: 2026-08-27

- Decision: The permitted grant set is derived from the ceiling's `maxCapability` and extended by
  an operator allow-list, `policy.allowed-tools`; a grant outside that union is
  `ToolGrantForbidden`. `read-only` implies `Read`, `Glob`, `Grep`, `NotebookRead`, `TodoWrite`;
  `edit-workspace` adds `Edit`, `MultiEdit`, `Write`, `NotebookEdit`; `full-access` permits every
  grant. Matching is exact on the whole string, so `Bash(git *)` is not `Bash`. Codex is
  unchanged — the renderer refuses any non-empty list — and the ceiling check runs first.
  Rationale: a grant is authority and the capability already says how much the operator permits;
  `Bash` runs arbitrary commands, which is what `full-access` means. Capability alone was rejected
  because the motivating consumer legitimately wants `Bash` under `edit-workspace` with a human's
  say-so; an allow-list alone because an operator who never mentions tools should still be able to
  grant `Read`. The implied sets are small and fail closed, so drift in Claude Code's tool set can
  only refuse, never widen. Checking before rendering means a Codex job that violates both hears
  about the policy problem, the one the operator can fix.
  Date: 2026-08-27

- Decision: `executable` and `extra-dirs` are operator-scope settings; a repository-supplied value
  is `RepositoryScopeForbidden`, exit 77. The operator file and `--set` may still set both, and
  `BAIKAI_AGENT_EXECUTABLE` is removed from the environment layer.
  Rationale: `executable` turns configuration into code execution with the operator's environment
  and the prompt on standard input, and plan 49 added it for "an operator whose installation is
  not on `PATH`"; the module's own comment says the environment must not widen authority because a
  variable is inherited and easy to set by accident. `extra-dirs` inside the root adds nothing the
  working directory does not give, so the only extra directories a repository would ask for are
  outside it — the operator's grant to make. Bounding instead was rejected: a path check on
  `executable` still lets a repository choose which of the operator's binaries runs, and an
  in-root check on `extra-dirs` permits only the useless case.
  Date: 2026-08-27

- Decision: A repository-supplied `working-dir` must resolve inside the repository root after
  canonicalisation, else `WorkingDirOutsideRepository`. The root is the directory `baikai` runs
  in, carried on `AgentConfigPaths` as `repositoryRoot` so tests can point it elsewhere;
  `--config PATH` chooses the file, not the root. A relative `working-dir` resolves against the
  root, so `"."` is the repository whichever file declared it.
  Rationale: discovery reads `./.baikai/agents.kdl` and nothing else (plan 49), so the working
  directory already is the repository. Canonicalising defeats a committed symlink `work -> /`.
  Resolving `"."` against the declaring file was rejected: the operator file's directory is never a
  sensible base, and two files defining one job would make `"."` mean two places depending on
  which layer won.
  Date: 2026-08-27

- Decision: `timeout` and `output-limit` get maxima, `policy.max-timeout` and
  `policy.max-output-limit`, applied to the resolved job whatever scope set the value. Default
  `max-output-limit` is `67108864` (64 MiB, sixteen times the built-in per-stream default);
  default `max-timeout` is `"unlimited"`. A finite maximum refuses a job asking for more and one
  asking for no limit at all.
  Rationale: memory belongs to the host the operator owns, so a concrete default is right and a
  repository's `output-limit "unlimited"` is refused until the operator opens it. Time is a budget
  every site sets differently, and a finite default would break every job that omits `timeout`,
  including the guide's quick start. The absent-timeout rule stops `max-timeout` being defeated by
  omission.
  Date: 2026-08-27

- Decision: A ceiling file inside the repository root is refused with exit 78 (a configuration
  error: no ceiling could be established), and the guide says the ceiling is exactly as
  trustworthy as the process environment that selects it. `--user-config`, `XDG_CONFIG_HOME` and
  `HOME` stay operator inputs.
  Rationale: those three are how an operator says where their file is. What can be closed is the
  one shape in which the repository becomes the ceiling: a path under the checkout. The check
  costs nothing on a normal machine — a file that does not exist is never checked — and closes
  both `--user-config .baikai/policy.kdl` and `XDG_CONFIG_HOME=$PWD/.baikai`. Documenting alone
  would describe a boundary a one-line flag defeats.
  Date: 2026-08-27

- Decision: The unknown-key noise is removed by filtering settei's warnings after resolution — kept
  for the selected job or a stray top-level node, dropped for another job or the operator file's
  `policy` node, and a repository `policy` node produces one notice — and an unknown key under
  `policy` in the operator file is an error, `UnknownPolicySetting`.
  Rationale: settei's only resolver option is `unknownKeyPolicy`, `WarnUnknownKeys` or
  `RejectUnknownKeys` (`settei/src/Settei/Resolve.hs:62-83`), never per key, so a per-key policy
  is not a real option; rebuilding a filtered `Source` via `sourceFromPairs` and `locateSource`
  duplicates the adapter and drops annotations. Each warning already carries its key and source
  name (`UnknownKeyProblem {key, origin}`). For the one node whose purpose is to limit authority, a
  misspelling that silently leaves the default in force is indefensible.
  Date: 2026-08-27

- Decision: `--run-id` or `--require-evidence` without `--evidence-file` or `--json` is a usage
  error (64); with `--json`, the record travels in the envelope as `evidence`, and every `--json`
  output becomes an aeson-built envelope, `show` on failure included, replacing the hand-rolled
  writer at `baikai-agent/src/Baikai/Agent/Cli.hs:1191-1209`.
  Rationale: a record built and dropped costs a `--version` probe and two digests and proves
  nothing, and no default destination exists that is not a surprise. The writer justifies itself
  by an aeson dependency the package already declares; embedding a `ModelCallEvidence`, which has
  `ToJSON`, is a one-liner with aeson.
  Date: 2026-08-27

- Decision: `OutputMalformed` and exit code 70 are deleted rather than given a producer.
  Rationale: the runner treats the tool's output as best-effort observation and its deliverable is
  the changed working tree; under a producer a run that edited files correctly but printed an
  unparseable final line would be reported as failure 70 with its exit code and output discarded.
  The record's `strength` and `unobserved` fields already say when output could not be read.
  Date: 2026-08-27

- Decision: The evidence `endpoint` resolves a relative, path-shaped `executable` against
  `working-dir` before probing; `errorInfo` carries the last 4096 bytes of standard error with a
  prefix stating how many earlier bytes were dropped; the staging file is created with
  `System.IO.openBinaryTempFileWithDefaultPermissions` beside the destination and renamed.
  Rationale: the child execs relative to `working-dir` (the runner sets `P.cwd`). Four kibibytes is
  a few dozen lines, where a failing tool's reason lives. A fresh `O_EXCL`-created name cannot be
  pre-planted; the default-permissions variant keeps the mode `writeFile` gave.
  Date: 2026-08-27

- Decision: `AgentRunRequest.envPassthrough` is renamed `envRequires`, in the `baikai` major
  release EP-10 already owes.
  Rationale: the field is a precondition list and the key has said `env-requires` since plan 49.
  Date: 2026-08-27

- Decision: The minimal structured-output field is `outputFormat :: AgentOutputFormat` on
  `AgentRunRequest`, constructors `TextFormat` and `JsonFormat`, KDL key `output-format`, rendering
  `--output-format json` on Claude and `--json` on Codex; no schema field; the strict-evidence
  gate is not tightened to require it.
  Rationale: this is the one setting evidence needs to observe a session, model and usage without
  opening `provider-args`. A result schema (`--json-schema` inline on Claude, `--output-schema
  FILE` on Codex) is a different feature with a shape mismatch and can be added later. The gate
  stays because `provider-args` is opaque by design and could still supply the flag.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Read this section completely before editing. It assumes no prior knowledge of this repository,
of the coding-agent tools, or of the `settei` library.

Baikai is a multi-package Cabal workspace; each package is a directory with a `.cabal` file. This
plan edits four. `baikai` holds the provider-neutral vocabulary in `baikai/src/Baikai/Agent.hs`.
`baikai-claude` and `baikai-openai` hold the renderers
`baikai-claude/src/Baikai/Provider/Claude/Agent.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs`, which turn a request into an argument vector.
`baikai-agent` holds the configuration layer `baikai-agent/src/Baikai/Agent/Config.hs`, the
command surface `baikai-agent/src/Baikai/Agent/Cli.hs`, the runner
`baikai-agent/src/Baikai/Agent/Run.hs`, and the thin executable `baikai-agent/app/Main.hs`. The
guide `docs/user/unattended-agent-runs.md` is the contract an operator reads; the capability
records `docs/capabilities/unattended-agent-runs.md` (CAP-17) and
`docs/capabilities/baikai-agent-command.md` (CAP-18) summarise it.

This plan is EP-6 of the MasterPlan in the frontmatter. It answers findings F.2, F.3, F.4, F.13
and F.14 of `docs/reviews/correctness-and-api-review-follow-up.md`, plus the guide drift on the
ceiling in its Theme H. EP-1 (`docs/plans/58-…`) owns the process-lifecycle half of `Run.hs` —
`spawn`, `consume`, `waitWithTimeout`, `terminateGroup`, `drain` — and the interactive Codex
approval refusal. Do not edit those. This plan touches `Run.hs` only at the precondition line in
`runAgentCommand`, `evidenceStatus`, `buildEvidence` and `agentEndpoint`; whichever plan lands
second rebases.

### Terms

An **unattended run** starts `claude` or `codex` with no terminal and no human; its deliverable is
the changed working tree. A **capability** is the provider-neutral filesystem authority a run asks
for: `read-only`, `edit-workspace` (may change files in its working directory and its explicit
extra directories), or `full-access` (no sandbox). The type is `AgentCapability`, whose derived
`Ord` ascends in that order and is what the ceiling compares.

The **policy ceiling** is the operator-owned limit on what any job may ask for: `AgentCeiling`,
checked by the pure `applyAgentCeiling`, loaded by `loadAgentCeiling` from the operator's file and
nothing else. It never clamps: a job over the ceiling is refused with every violation named. Per
`docs/adr/0005-what-baikai-deliberately-does-not-do.md`, baikai holds no sanctioning policy of its
own — the ceiling is the operator's policy about a run baikai spawns, not baikai's judgement.

A **grant** widens what a tool may do; a **narrowing** restricts it. On Claude Code the
distinction is in the flags. From `claude --help` at 2.1.247:

```text
--allowedTools, --allowed-tools <tools...>
    Comma or space-separated list of tool names to allow (e.g. "Bash(git *)
    Edit")
--disallowedTools, --disallowed-tools <tools...>
    Comma or space-separated list of tool names to deny (e.g. "Bash(git *)
    Edit")
--tools <tools...>                    Specify the list of available tools from
                                      the built-in set. Use "" to disable all
                                      tools, "default" to use all tools, or
                                      specify tool names (e.g.
                                      "Bash,Edit,Read").
--permission-mode <mode>              Permission mode to use for the session
                                      (choices: "acceptEdits", "auto",
                                      "bypassPermissions", "manual",
                                      "dontAsk", "plan")
```

`--permission-mode acceptEdits` auto-approves file edits inside the working directory; any other
tool use, `Bash` or `WebFetch`, raises a permission request, and in `-p` mode with nobody present
that request is denied. `--allowedTools Bash` pre-approves `Bash` so no request is raised: a grant
beyond the permission mode. `--tools` and `--disallowedTools` are the narrowings. The current
Haddock on `AgentSafety.allowedTools` (`baikai/src/Baikai/Agent.hs:145-149`) says the opposite —
"Optional narrowing of the provider's tool set. An empty list means do not restrict tools beyond
what the capability implies" — and `applyAgentCeiling` (`:387-409`) never looks at it.

**Repository scope** is `./.baikai/agents.kdl` in the directory `baikai` runs in; **operator
scope** is `$XDG_CONFIG_HOME/baikai/agents.kdl`, else `$HOME/.config/baikai/agents.kdl`, or what
`--user-config PATH` names. **Operator inputs** are the operator file and the command line
(`--set`); the **environment** is neither and is deliberately narrow. A **KDL layer** is one of the
five sources a job resolves across — built-in defaults, operator file, repository file,
environment, command line, later winning.

**settei** is the first-party configuration library (`/Users/shinzui/Keikaku/bokuno/settei`,
Hackage 0.2 series) that does the layering. A `Setting` names a dotted key and a decoder; a
`Config a` composes settings into a record; a `Source` is one layer; `resolve` returns a
`ResolveResult` whose `answer` is the value or errors, whose `report` attributes every key to an
`Origin` (`kind`, `name`, `key`, `location`), and whose `warnings` is a list of `ConfigWarning`,
today the single constructor `UnknownKeyWarning UnknownKeyProblem {key, origin}`
(`settei/src/Settei/Error.hs:53-56,90-93`). settei-kdl tags every document `FileSource "KDL v2"`,
so the two files are told apart by source *name*, which this repository sets to
`"user configuration"` and `"repository configuration"` through `renderAgentConfigScope`.

### What the code does today

`applyAgentCeiling` collects `ProviderForbidden`, `CapabilityExceeded` and
`ProviderArgsForbidden`. The job record (`Config.hs:144-180`) carries `executable`, `workingDir`,
`extraDirs`, `allowedTools`, `timeout` and `outputLimit`, all settable from the repository file,
none gated (F.3); the environment bindings (`:567-578`) include `BAIKAI_AGENT_EXECUTABLE`.
`defaultAgentConfigPaths` (`:593-608`) reads `XDG_CONFIG_HOME` and `HOME`, `Cli.hs:554-565` lets
`--user-config` replace the discovered path, and nothing checks where that file is (F.4). The
Claude renderer's `allowedToolArgs` (`Claude/Agent.hs:188-194`) emits `--allowedTools a,b`; the
Codex renderer refuses any list. `stageJob` (`Cli.hs:641-681`) resolves with
`defaultResolveOptions`, so settei warns about every leaf the per-job schema does not declare.
`evidenceRequestFor` (`:1044-1058`) builds a request for any evidence flag, but only
`writeEvidenceFile` (`:1071-1090`) consumes it, only with a path, staging at `path <> ".partial"`
with `BSL.writeFile`, which follows a symlink already there; the `--json` envelope carries no
record. `failureExitCode` (`:1097-1108`) maps `OutputMalformed` to 70 and nothing constructs it.
`Run.hs:380-389` probes `executableIdentity (cmd ^. #executable)`, whose `resolveExecutable`
(`baikai/src/Baikai/Provider/Cli/Internal.hs:633-641`) calls `makeAbsolute` against the parent's
directory while `spawn` sets `P.cwd = Just (req ^. #workingDir)`; `Run.hs:355-367` puts the whole
captured standard error into `processError` (F.13). F.14 adds: `envPassthrough`
(`Agent.hs:251-261`) is a precondition list the KDL calls `env-requires`; the guide (`:257-263`)
tells an operator wanting evidence above `requested_only` to add `--output-format json` through
`provider-args`; `working-dir "."` resolves against the process directory undocumented;
`show --json` prints a bare report on failure (`Cli.hs:804-807`).

### Facts about the tests you will change

Every test that runs a fake agent writes its path into the **repository** document as
`executable "…"`: `syncKeiroDslDocument` (`baikai-agent/test/CliTests.hs:436-452`), `scriptedJob`
(`:636-648`), and the inline documents of `swappingTheProviderIsAConfigurationChangeTest`,
`swappingTheProviderRefusesATheToolListTest` and `theCeilingRefusesBeforeAnythingIsStartedTest`.
Milestone 1 makes that a violation, so each splits into an operator document carrying
`executable` and a repository document carrying the rest. `minimalJob` (`:221-232`) and the inline
`show` documents (`:349-365`, `:387-401`) write `working-dir "/tmp"`; with the root check they must
say `working-dir "."`. `ConfigTests.withConfigs` (`ConfigTests.hs:87-97`) writes both files into
one directory; Milestone 2 refuses a ceiling file inside the root, so the operator file moves to a
sibling. `syncKeiroDslRunsTest` (`:454-499`) asserts the whole vector including
`--allowedTools Read,Write,Edit,Glob,Grep,Bash,Skill,TodoWrite` from a repository-only document —
the pass-through the review calls a decision; the vector stays and the grant moves to the
operator document. `baikai/test/AgentSpec.hs:47` asserts `req ^. #envPassthrough @?= []`, `:213`
lists `OutputMalformed "expected JSON, got a banner"`, and `baikai-agent/test/Main.hs:208` reads
`& #envPassthrough .~ names`; each is quoted where it changes.

### Repository conventions and ADR context

Every package sets `default-language: GHC2024` with `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`; `baikai-agent` promotes `-Werror=incomplete-patterns`,
so adding a `CeilingViolation` constructor without extending `renderCeilingViolation` fails the
build, as intended. Fields are read with `generic-lens` labels and carry no type prefix.
`AgentCeiling` and `AgentRunRequest` hide their constructors; build values by updating
`defaultAgentCeiling` and `agentRunRequest`. Formatting is `nix fmt`. Tests are `tasty` with
`tasty-hunit`; both vendor suites assert whole argument vectors with `@?=`, and this plan's tests
must too. The ADR corpus follows `docs/adr/0001-architecture-decision-record-convention.md`: plain
files `NNNN-slug.md`, frontmatter `title`, `status`, `date`, body Context/Decision/Consequences, a
row in `docs/adr/README.md`. The one relevant record is 0005, cited above; no cross-repository ADR
applies — the MasterPlan's Mori search for "policy ceiling" found nothing.


## Plan of Work

Four milestones, fixed by the MasterPlan. Milestone 1 is the security change; Milestone 2 closes
the trust hole around the ceiling file; Milestone 3 is a set of independent truthfulness fixes;
Milestone 4 makes the pre-0.2 shape changes, writes the ADR, and brings the documentation back.

### Milestone 1 — The ceiling gates every repository-settable field; `allowedTools` is a grant

Scope: `applyAgentCeiling` bounds tool grants, timeout and output limit; `Baikai.Agent.Config`
refuses a repository-scope `executable`, `extra-dirs`, or out-of-root `working-dir`; `cabal test
all` passes with the new cases; the `sync-keiro-dsl` fixture runs only with an operator grant.

In `baikai/src/Baikai/Agent.hs`, rewrite the Haddock on `AgentSafety.allowedTools`: tools the run
is **granted** — pre-approved — beyond what the capability's permission mode approves on its own;
an empty list grants nothing beyond the mode; Claude renders `--allowedTools`; Codex refuses a
non-empty list. Fix `agentSafety`'s comment likewise. Extend the ceiling:

```haskell
data AgentCeiling = AgentCeiling
  { maxCapability :: !AgentCapability,
    allowProviderArgs :: !Bool,
    allowedProviders :: ![AgentProvider],
    -- | Grants the operator permits beyond 'toolGrantsImpliedBy' the maximum
    -- capability. Exact spellings; @Bash(git *)@ is not @Bash@.
    allowedTools :: ![Text],
    -- | The longest wall-clock limit any job may request; 'Nothing' permits an
    -- unlimited run. A finite maximum refuses a job with no timeout.
    maxTimeout :: !(Maybe NominalDiffTime),
    -- | The largest per-stream capture any job may request; 'Nothing' permits
    -- @unlimited@.
    maxOutputLimit :: !(Maybe Int)
  }
```

`defaultAgentCeiling` sets `allowedTools = []`, `maxTimeout = Nothing`,
`maxOutputLimit = Just defaultMaxOutputLimit`, with `defaultMaxOutputLimit = 67108864` exported and
commented with the Decision Log's reason. Add and export the implied grants:

```haskell
-- | The grants a capability implies on its own; 'Nothing' means every grant.
-- The names are Claude Code's built-in tools at 2.1.247. A name absent here
-- needs full access or an explicit operator grant, so an unknown tool can only
-- ever be refused.
toolGrantsImpliedBy :: AgentCapability -> Maybe [Text]
toolGrantsImpliedBy AgentReadOnly = Just readTools
toolGrantsImpliedBy AgentEditWorkspace = Just (readTools <> editTools)
toolGrantsImpliedBy AgentFullAccess = Nothing
```

with `readTools = ["Read", "Glob", "Grep", "NotebookRead", "TodoWrite"]` and
`editTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]`. Add five violations:

```haskell
  | -- | Requested grants outside the permitted set, then the maximum capability in force.
    ToolGrantForbidden ![Text] !AgentCapability
  | -- | The requested timeout ('Nothing' is no limit), then the permitted maximum.
    TimeoutExceeded !(Maybe NominalDiffTime) !NominalDiffTime
  | -- | The requested per-stream limit ('Nothing' is unlimited), then the permitted maximum.
    OutputLimitExceeded !(Maybe Int) !Int
  | -- | The leaf name of a setting only operator scope may set, e.g. @executable@.
    RepositoryScopeForbidden !Text
  | -- | The resolved working directory, then the repository root it must lie inside.
    WorkingDirOutsideRepository !FilePath !FilePath
```

Each `renderCeilingViolation` line names both sides and is actionable. `ToolGrantForbidden`
renders `tool grants Bash, Skill are not permitted under the maximum capability edit-workspace;
add them to policy.allowed-tools in the operator file or raise policy.max-capability`;
`TimeoutExceeded Nothing m` renders `the job sets no timeout, and the permitted maximum is 2h`;
`OutputLimitExceeded Nothing m` renders `output-limit unlimited exceeds the permitted maximum
67108864 bytes`; `RepositoryScopeForbidden name` renders `the repository configuration set <name>,
which only the operator file or the command line may set`. Render a `NominalDiffTime` through a
local helper printing `Ns`, or `Nm`/`Nh` when divisible — the spellings `parseDuration` accepts —
not `show`.

Extend `applyAgentCeiling` with three more comprehensions appended to its `concat`:
`ToolGrantForbidden forbidden (limit ^. #maxCapability)` where `forbidden` is every requested
grant neither in the implied set (an implied `Nothing` permits all) nor in
`limit ^. #allowedTools`, emitted only when non-empty; `TimeoutExceeded requested permitted` when
`maxTimeout` is `Just permitted` and the request's `timeout` is `Nothing` or greater;
`OutputLimitExceeded` likewise. Say in the Haddock that scope violations are not this function's
business — it sees a request, not where each value came from — and come from the configuration
layer.

In `Config.hs`, add `repositoryRoot :: !FilePath` to `AgentConfigPaths`, documented as the
directory the process runs in, unmoved by `--config`, set explicitly by tests;
`defaultAgentConfigPaths` fills it with `getCurrentDirectory`. Remove the `BAIKAI_AGENT_EXECUTABLE`
binding from `agentEnvBindings` and name the executable in its comment as the fourth thing the
environment must not set. Extend `agentCeilingConfig` with three `withDefault` settings —
`policy.allowed-tools` (`scalarOrListDecoder textDecoder`), `policy.max-timeout` (a decoder
accepting `"unlimited"` as `Nothing`, else `durationDecoder`), `policy.max-output-limit` (reuse
`outputLimitDecoder`) — each defaulting from `defaultAgentCeiling` under a named rule. Then add the
scope check, in IO because canonicalising is:

```haskell
-- | Violations that depend on which file supplied a value. The pure ceiling
-- cannot see provenance; this reads it from the resolution report.
repositoryScopeViolations ::
  AgentConfigPaths -> ResolutionReport -> Text -> AgentJob -> IO [CeilingViolation]

-- | The pure ceiling's violations as a list, so a caller can concatenate.
ceilingViolations :: AgentCeiling -> AgentRunRequest -> [CeilingViolation]
```

`reportNodes` yields `ResolutionNode {key, origin, ...}`; a value came from the repository when
`origin` is `Just o` with `o ^. #name == renderAgentConfigScope RepositoryScope`. Look up the nodes
for `jobs.<name>.executable`, `.extra-dirs` and `.working-dir`. A repository `executable` yields
`RepositoryScopeForbidden "executable"`; a repository `extra-dirs` yields
`RepositoryScopeForbidden "extra-dirs"` only when the resolved list is non-empty. For a repository
`working-dir`, `canonicalizePath` both `root </> workingDir` (an absolute right operand passes
through `</>` unchanged) and `root`, and require the first to equal the second or start with it
plus a separator; otherwise `WorkingDirOutsideRepository resolved canonicalRoot`. `canonicalizePath`
in `directory` 1.3.10 resolves the longest existing prefix, so a missing directory still gets an
answer and the runner's `WorkingDirMissing` reports it later.

In `Cli.hs`, extend `StagedJob` with `scopeViolations :: ![CeilingViolation]`, computed in
`stageJob` after the ceiling loads. In `explain` and `execute`, replace the `applyCeilingToJob`
step with a guard over `scopeViolations <> ceilingViolations ceiling request`: empty proceeds,
anything else is `Left (CeilingRejected violations)`. Extend `renderCeiling` and `ceilingJson` with
the three fields, rendering `[]` as `(none beyond the capability)` and `Nothing` as `unlimited`.
In both renderers change only comments: `allowedToolArgs` explains that `--allowedTools`
pre-approves the named tools and the ceiling has already checked the grant;
`toolRestrictionGuard` keeps its message and notes the ceiling runs first.

Tests. In `baikai/test/AgentSpec.hs` extend `ceilingAcceptanceTest` so the edit-workspace request
also carries `allowedTools = ["Read", "Edit"]`, `timeout = Just 600` and `outputLimit = Just 1024`
and is still returned byte-identical. Add `toolGrantCeilingTest`: `allowedTools = ["Bash"]` under
`edit-workspace` is `Left [ToolGrantForbidden ["Bash"] AgentEditWorkspace]` against the default,
`Right` against `& #allowedTools .~ ["Bash"]` and against `& #maxCapability .~ AgentFullAccess`,
and `["Bash(git *)"]` is refused even with `"Bash"` granted. Add `impliedGrantsTest` pinning the
three sets, and `timeoutCeilingTest` and `outputLimitCeilingTest` covering within, above, and
absent-under-finite-maximum, including `outputLimit = Nothing` against the default being
`Left [OutputLimitExceeded Nothing 67108864]`. Extend `violationRenderingTest` so each new
constructor names both values and `ToolGrantForbidden` names `policy.allowed-tools`.

In `baikai-agent/test/ConfigTests.hs`, rework `withConfigs` to write the operator document to
`dir </> "operator" </> "agents.kdl"` and the repository document to
`dir </> "repo" </> ".baikai" </> "agents.kdl"`, returning `repositoryRoot = dir </> "repo"`. Add a
group `"repository scope"` with a helper `scopeViolationsFor :: AgentConfigPaths -> Text -> IO
[CeilingViolation]` and these cases: `repositoryExecutableIsRefusedTest`, named `"A REPOSITORY
FILE CANNOT SET THE EXECUTABLE"`, adding `executable "/opt/bin/claude"` to `jobDoc "edit-workspace"`
and asserting exactly `[RepositoryScopeForbidden "executable"]`; `repositoryExtraDirsAreRefusedTest`
with `extra-dirs "/Users/op/.ssh"` asserting `[RepositoryScopeForbidden "extra-dirs"]`;
`operatorScopeMaySetBothTest` (the same settings in the operator document yield `[]`);
`workingDirMustStayInsideTheRootTest` (`"."` and `"sub"` yield `[]`, `".."` yields one
`WorkingDirOutsideRepository`, and a symlink `escape -> /` made with `createDirectoryLink` plus
`working-dir "escape/etc"` yields one too); `executableIsNotEnvBoundTest` (resolving with
`envSnapshot [("BAIKAI_AGENT_EXECUTABLE", "/evil")]` gives `job ^. #executable @?= Nothing`); and
`ceilingPolicyKeysTest` (`allowed-tools "Bash"`, `max-timeout "2h"`, `max-output-limit "unlimited"`
load as `["Bash"]`, `Just 7200`, `Nothing`). Existing ceiling tests keep passing because
`runAgainstCeiling` exercises the pure check only.

In `baikai-agent/test/CliTests.hs`, rework the harness first: replace `repositoryOnly path` with
`pathsIn dir operatorDoc repoDoc`, which writes an optional operator document to
`dir </> "operator" </> "agents.kdl"`, the repository document to
`dir </> "repo" </> ".baikai" </> "agents.kdl"`, returns `repositoryRoot = dir </> "repo"`, and
makes `dir </> "repo"` the working directory every fixture names. Split `syncKeiroDslDocument` into
an operator document

```kdl
policy {
  allowed-tools "Bash" "Skill"
}
jobs {
  sync-keiro-dsl {
    executable "<fake claude path>"
  }
}
```

and the old repository document minus its `executable` line. The asserted vector in
`syncKeiroDslRunsTest`, including `"--allowedTools", "Read,Write,Edit,Glob,Grep,Bash,Skill,TodoWrite"`,
is unchanged, because the grant is now permitted by the operator rather than passed through. Add
`bashGrantIsRefusedUnderTheDefaultCeilingTest`, named `"A REPOSITORY TOOL GRANT NEEDS AN OPERATOR
GRANT"`: the same repository document, no operator `policy`, exit `refusedExitCode`, standard error
containing `Bash`, `edit-workspace` and `policy.allowed-tools`, the fake's record file absent. Split
`scriptedJob` into `operatorJob dir executable` and `repositoryJob dir outputMode` and update the
three inline documents. Change `working-dir "/tmp"` to `working-dir "."` in `minimalJob` and the two
inline `show` documents; `showExplainsWithProvenanceTest`'s `(Text.pack path <> ":3:")` still holds
because the provider stays on line 3. Add `repositoryExecutableIsRefusedThroughTheCommandTest`
(exit 77, `executable` in the message, nothing started) and `showListsTheCeilingFieldsTest`
(`allowed-tools`, `max-timeout`, `max-output-limit` appear in `show`).

### Milestone 2 — Ceiling-file provenance decided and documented

Scope: a ceiling file inside the repository root is refused, an unknown `policy` key is an error,
and the guide states which inputs choose the ceiling file and what that implies.

In `Config.hs`, add two `AgentConfigError` constructors: `CeilingFileInsideRepository !FilePath
!FilePath` (file, root) rendering `the operator configuration file <file> lies inside the
repository <root>, so the repository could have written the policy ceiling; move it outside the
checkout or pass --user-config with a path outside it`, and `UnknownPolicySetting !FilePath
![Text]` rendering the file and keys. In `loadAgentCeiling`, before reading, canonicalise the user
path and `repositoryRoot` and return the first error when the path equals the root or begins with
it plus a separator; after resolving, collect every `UnknownKeyWarning` whose key's first segment
is `policy` and return the second error when any exist, still discarding `jobs.*` warnings. The
strong comment above the source list gains one sentence: the location check is the other half of
the same property, because a file the repository can write is not the operator's.

Tests in `ConfigTests.hs`: `ceilingFileInsideRepositoryIsRefusedTest`, named `"A CEILING FILE
INSIDE THE REPOSITORY IS REFUSED"`, writes a valid raising policy to
`dir </> "repo" </> ".baikai" </> "policy.kdl"`, points `userConfig` at it, and asserts
`Left (CeilingFileInsideRepository _ _)` with both paths in the rendering; a companion asserts the
same file one directory above the root loads. `unknownPolicyKeyIsAnErrorTest`:
`policy { max-capabilty "read-only" }` yields `Left (UnknownPolicySetting _ ["policy.max-capabilty"])`.
In `CliTests.hs`, `ceilingInsideTheRepoExitsSeventyEightTest` drives `agent show` with such a path
and asserts `configExitCode`.

The guide text lands in Milestone 4 but is decided here: "The ceiling" states that it is read from
the operator file, chosen by `--user-config`, else `XDG_CONFIG_HOME`, else `HOME`; that those are
process inputs whoever starts the process controls; that a file under the repository root is
refused so a checkout cannot supply its own ceiling; and that this is what "no repository file,
environment variable, or flag can raise it" means and does not mean — it does not protect against
whoever controls the process environment.

### Milestone 3 — CLI truthfulness

Scope: six independent fixes in `Cli.hs` and the evidence half of `Run.hs`, each with a test.

Unknown keys. In `Config.hs` add `relevantWarnings :: Text -> [ConfigWarning] -> [ConfigWarning]`,
keeping a warning when its key is under `jobs.<selected>` or its first segment is neither `jobs`
nor `policy`, and `repositoryPolicyNotice :: [ConfigWarning] -> Maybe Text` returning `the
repository configuration contains a policy node; it has no effect, because the ceiling is read
from the operator file only` when any `policy` warning's origin name is the repository scope. In
`stageJob`, build `warningsText` from `renderWarningsText (relevantWarnings jobName ws)` plus the
notice. Tests in `ConfigTests.hs`: `otherJobsDoNotWarnTest`, `typoInTheSelectedJobStillWarnsTest`
(`timout "5m"` warns naming `jobs.demo.timout`), `repositoryPolicyNodeIsNoticedOnceTest`; in
`CliTests.hs`, `show` against an operator file with a `policy` node has empty standard error.

Evidence destination. In `runCommand`, before staging, when `runId` or `requiredEvidence` is set
and neither `evidenceFile` nor `jsonOutput` is, return `failedRun usageExitCode` with `--run-id
and --require-evidence produce an evidence record, which needs a destination: add --evidence-file
PATH or --json`. In `interpret`'s `--json` branches include `"evidence": <record>` when the outcome
carries one. Tests: `runIdWithoutADestinationIsAUsageErrorTest` (exit 64, message names
`--evidence-file`) and `jsonCarriesTheEvidenceRecordTest` (capturing fake, `--json` and
`--run-id r`, the envelope's `evidence.run_id` is `r`).

Exit 70. Delete `OutputMalformed` from `AgentRunFailure` and `renderAgentRunFailure`, delete
`internalExitCode` and its export from `Cli.hs`, and delete the `OutputMalformed _ ->
internalExitCode` arm. In `baikai/test/AgentSpec.hs` `failureRenderingTest`, the list ends

```haskell
            WorkingDirMissing "/tmp/gone",
            OutputMalformed "expected JSON, got a banner"
          ]
```

— remove the `OutputMalformed` line and the comma above it. Remove the `70` row from the guide's
table and `70 malformed output` from CAP-18 (`:63`).

Endpoint. In `buildEvidence` replace `executableIdentity (cmd ^. #executable)` with
`executableIdentity (executableForEvidence req cmd)`:

```haskell
-- | The path the child actually execs: a relative path containing a separator
-- is resolved by the operating system against the working directory the
-- runner sets, so the evidence must resolve it the same way.
executableForEvidence :: AgentRunRequest -> AgentCommand -> FilePath
executableForEvidence req cmd
  | any isPathSeparator exe && isRelative exe = (req ^. #workingDir) </> exe
  | otherwise = exe
  where exe = cmd ^. #executable
```

`isPathSeparator`, `isRelative`, `</>` come from `System.FilePath`, already a dependency. Test in
`EvidenceTests.hs`: `relativeExecutableEndpointTest` writes the fake at `dir </> "bin" </> "fake"`,
runs `"./bin/fake"` with `workingDir = dir`, and asserts `endpoint.endpoint` is
`dir </> "bin" </> "fake"`.

`errorInfo`. Add `errorInfoStderrTailBytes :: Int` = `4096`, exported, and `stderrTail ::
AgentCapturedOutput -> Text` keeping the last that many bytes (`BS.drop (BS.length bytes - n)`)
and, when anything was dropped, prefixing `[stderr truncated to the last 4096 of <total> bytes] `.
Use it in `evidenceStatus` instead of `capturedText`. Test `errorInfoIsBoundedTest`: a fake writes
100 KiB of `x` lines then `final: reason` to standard error and exits 1; `error_info.message` is
shorter than `errorInfoStderrTailBytes + 80` characters, contains `final: reason`, and begins with
`[stderr truncated`.

Staging file. Rewrite `writeEvidenceFile` to `openBinaryTempFileWithDefaultPermissions
(takeDirectory path) (takeFileName path <> ".partial")`, `BSL.hPut h (Aeson.encode record)`,
`hClose h`, `renameFile staging path`, removing the temporary on failure. `base` creates the file
under a fresh name with `O_EXCL`, so a symlink planted at the guessable name is never followed;
the default-permissions variant keeps the mode `writeFile` gave. Test
`stagingFileCannotBePrePlantedTest`: create a canary, `createFileLink` from
`evidence.json.partial` to it, run with `--evidence-file evidence.json`, assert the canary is
unchanged, the record parses, and no directory entry containing `.partial` remains. The existing
assertion in `writesTheEvidenceFileTest`, `leftover <- doesFileExist (evidencePath <> ".partial")`,
becomes that directory-listing check, since the staging name is no longer that exact string.
Update the guide's "a staging file beside the destination" to "a uniquely named staging file".

### Milestone 4 — 0.2 config-surface adjustments, the ADR, and the documentation

Scope: the rename, the structured-output field, the working-directory base, the aeson envelopes,
the ADR, and the guide, capability records and changelog.

Rename. In `Baikai.Agent` rename `envPassthrough` to `envRequires` in the export list, the record,
`agentRunRequest`, and the `MissingEnvironment` Haddock; in `Run.hs:179` and the comment at `:501`;
in `Config.hs:546`; in `baikai/test/AgentSpec.hs:47`, where `req ^. #envPassthrough @?= []` becomes
`req ^. #envRequires @?= []`; in `baikai-agent/test/Main.hs:208`, where
`& #envPassthrough .~ names` becomes `& #envRequires .~ names`; and in
`docs/user/interactive-launches.md:116-117`.

Structured output. In `Baikai.Agent` add

```haskell
data AgentOutputFormat = TextFormat | JsonFormat
renderAgentOutputFormat :: AgentOutputFormat -> Text   -- "text" | "json"
parseAgentOutputFormat  :: Text -> Maybe AgentOutputFormat
```

and `outputFormat :: !AgentOutputFormat` on `AgentRunRequest`, `TextFormat` by default; extend
`requestDefaultTest` with `req ^. #outputFormat @?= TextFormat`. The Claude renderer adds
`outputFormatArgs` yielding `["--output-format", "json"]` for `JsonFormat`, placed right after
`effortArgs`; the Codex renderer yields `["--json"]` in the same position. The installed tools
document both: `claude --help` has `--output-format <format> … "text" (default), "json" (single
result), or "stream-json"`, and `codex exec --help` has `--json  Print events to stdout as JSONL` —
the shapes `decodeClaudeCliResult` and `parseCodexJsonlStream` already consume. In `Config.hs` add
`outputFormat` to `AgentJob`, a setting at `jobs.<name>.output-format` with a named default rule
`text-output-format`, and copy it in `agentJobRequest`. Tests: `agentOutputFormatTest` in each
vendor suite asserting the whole vector, `outputFormatTest` in `ConfigTests.hs`, and
`showExplainsWithProvenanceTest` extended to see `jobs.demo.output-format`. The Haddock on
`runAgentCommand` and `observeToolOutput` no longer says the renderers cannot ask for a structured
format.

Working-directory base. In `stageJob`, after building the request, set `#workingDir` to
`(paths ^. #repositoryRoot) </> (job ^. #workingDir)`, so `"."` becomes the root and an absolute
path is untouched. The `swappingTheProviderIsAConfigurationChangeTest` assertion `"--cd",
Text.pack dir` becomes the repository directory the reworked harness uses.

Envelopes. Replace `jsonObject`, `jsonArray` and `jsonString` with `Aeson.object`, `Aeson.toJSON`
and one `encodeEnvelope :: Aeson.Value -> Text`. Embed settei's report by decoding
`renderResolutionJson report` with `Aeson.decodeStrict`, falling back to `Aeson.String`.
`show --json` always emits `{"job", "outcome": "shown"|"refused"|"failed", "exitCode", "message",
"configuration", "ceiling", "command"}` with `null` for absent parts; `run --json` keeps its
`outcome` values and gains `evidence`; `list --json` is unchanged. Tests:
`showJsonFailureIsAnEnvelopeTest` (a malformed document under `--json` yields one object with
`outcome` `failed` and `exitCode` `78`) and `showJsonRefusalIsAnEnvelopeTest`.

The ADR. Create
`docs/adr/NNNN-the-unattended-policy-ceiling-gates-every-repository-settable-field-and-allowed-tools-is-a-grant.md`,
where `NNNN` is the next free number at implementation time — EP-1, EP-2, EP-3, EP-4, EP-7, EP-8
and EP-10 also create records, so check `ls docs/adr` then rather than assuming `0006`.
Frontmatter `title: The unattended policy ceiling gates every field a repository can set, and
allowedTools is a grant`, `status: accepted`, the date. Context: the repository file is untrusted
and the ceiling is the only thing between it and the operator's machine; the first ceiling checked
three of nine settings and modelled the tool list as a narrowing. Decision: every setting a
repository can write is bounded by the ceiling or refused from repository scope; `allowedTools` is
a grant whose permitted set is implied by the maximum capability and extended only by the
operator; the ceiling file must lie outside the repository; the environment never sets the
executable. Consequences: adding a job setting means deciding, in the same change, which of the
three treatments it gets — bounded, operator-only, or free — and writing the test; the grant lists
fail closed; the motivating consumer needs an operator grant for `Bash`. Add the row to
`docs/adr/README.md`.

The guide, `docs/user/unattended-agent-runs.md`. Add `output-format` to the repository example and
"Setting reference"; describe `safety.allowed-tools` as "tools granted beyond the capability;
refused for codex; bounded by the ceiling"; add the three `policy` keys with defaults to the
operator example; add a short table of the three treatments — bounded (`provider`,
`safety.capability`, `safety.allowed-tools`, `safety.provider-args`, `timeout`, `output-limit`),
operator-only (`executable`, `extra-dirs`), confined to the root (`working-dir`). Remove
`BAIKAI_AGENT_EXECUTABLE` from the environment table and the precedence row. Rewrite "The ceiling"
as Milestone 2 decided, and replace the refusal examples at `:542-552` with real renderings — the
raw-argument one is `raw provider arguments are not permitted; 2 requested, and their values are
secret and are not shown` — plus one each for a tool grant and a repository-scope setting.
Rewrite "Where a value came from" (`:578-594`) to show `renderEffectiveConfig`'s format, the quick
start's `from repository configuration at .baikai/agents.kdl:4:17`, not settei's. Replace the
`provider-args` evidence advice (`:257-263`) with `output-format "json"`; state the destination
rule; drop the `70` row; say `show --json` always emits an envelope. In the migration section say
the script's `--allowedTools … Bash` now requires `policy { allowed-tools "Bash" "Skill" }` in the
operator's file, and why. In "Using it from Haskell" show `repositoryRoot` and
`repositoryScopeViolations`.

The capability records. CAP-17: rewrite the ceiling paragraph to say it gates every
repository-settable field and `allowedTools` is a grant checked against the maximum capability;
add a `Limits` bullet that the implied grant lists are Claude Code's names and fail closed. CAP-18:
rewrite the ceiling sentence at `:53-56` per Milestone 2, fix the exit-code sentence, and replace
the `Shape` block's KDL — a `job "review" {` node with a bare `capability` the schema never
accepted — with

```kdl
// .baikai/agents.kdl
jobs {
  review {
    provider      "claude"
    working-dir   "."
    output        "capture"
    output-format "json"
    safety { capability "read-only" }
  }
}
```

EP-11 reconciles the rest of the catalogue. Changelog: under `[Unreleased]` in the root
`CHANGELOG.md`, bullets for `baikai` (breaking: `envPassthrough` renamed, `OutputMalformed`
removed, `CeilingViolation` extended; added: the ceiling fields, `toolGrantsImpliedBy`,
`AgentOutputFormat`, the grant semantics), `baikai-claude` and `baikai-openai` (added: the format
flag from `outputFormat`), and `baikai-agent` (breaking: `repositoryRoot`, repository-scope
refusals, `BAIKAI_AGENT_EXECUTABLE` and exit 70 removed, the destination rule, the envelope shape;
added: the three `policy` keys, `output-format`, the in-repository refusal, scoped warnings,
bounded `errorInfo`, unique staging). Do not bump versions; EP-10 owns that.


## Concrete Steps

Run every command from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.

Before writing code, re-verify the facts the grant model rests on. These read help text only:

```bash
claude --version
claude --help | rg -- '--allowedTools|--disallowedTools|--tools|--output-format' -A 4
codex --version
codex exec --help | rg -- '--json|--output-schema' -A 1
```

Expect `2.1.247 (Claude Code)`, `codex-cli 0.149.1`, and the text quoted in Context and
Orientation. If `--allowedTools` has been renamed or its help no longer says "to allow", stop and
record it in Surprises & Discoveries; the grant model is only right while that sentence is.

After each milestone:

```bash
cabal build all
cabal test baikai-test baikai-agent-test baikai-claude-test baikai-openai-test
```

To see the headline refusal by hand, with no coding-agent binary involved, point the executable at
a throwaway repository and an empty home so your real operator file cannot interfere:

```bash
mkdir -p /tmp/baikai-ceiling/.baikai /tmp/baikai-ceiling-home
cat > /tmp/baikai-ceiling/.baikai/agents.kdl <<'KDL'
jobs {
  review {
    provider    "claude"
    working-dir "."
    safety {
      capability    "edit-workspace"
      allowed-tools "Read" "Bash"
    }
  }
}
KDL
cd /tmp/baikai-ceiling
HOME=/tmp/baikai-ceiling-home cabal --project-dir /Users/shinzui/Keikaku/bokuno/baikai \
  run baikai-agent:exe:baikai -- agent run review --prompt "look around"; echo "exit $?"
```

Expected:

```text
refused: the request exceeds the permitted policy ceiling: tool grants Bash are not permitted under the maximum capability edit-workspace; add them to policy.allowed-tools in the operator file or raise policy.max-capability
exit 77
```

Writing `policy { allowed-tools "Bash" }` to `/tmp/baikai-ceiling-home/.config/baikai/agents.kdl`
makes the same command run (it will fail with exit 69, since no `claude` is on `PATH` there, which
proves the ceiling was passed); copying that file to `/tmp/baikai-ceiling/.baikai/policy.kdl` and
passing `--user-config .baikai/policy.kdl` prints a message beginning `the operator configuration
file` and exits 78. Clean up with `rm -rf /tmp/baikai-ceiling /tmp/baikai-ceiling-home`.

Full validation after Milestone 4. Two independent gates make the `baikai-smoke` suite spend
money — provider keys, and the mere presence of `claude` or `codex` on `PATH` — and
`agents/skills/release/SKILL.md` closes both with this `zsh` command, quoted verbatim:

```zsh
baikai_test_path=(${path:#/Users/shinzui/.local/bin})
baikai_test_path=(${baikai_test_path:#/opt/homebrew/bin})
env -u ANTHROPIC_KEY -u ANTHROPIC_API_KEY \
  -u OPENAI_KEY -u OPENAI_API_KEY \
  -u DEEPSEEK_KEY -u DEEPSEEK_API_KEY \
  -u OPENROUTER_API_KEY -u TOGETHER_API_KEY \
  -u BAIKAI_EMBEDDING_LIVE PATH="${(j/:/)baikai_test_path}" \
  cabal test all
```

Run `nix fmt`, `git diff --check` and `cabal build all` before it and `nix flake check` after.
Every suite must pass, not merely skip, and the smoke suite must report no keys or binaries. No
test may read the real `HOME` or `XDG_CONFIG_HOME`; every test builds `AgentConfigPaths` with an
explicit `repositoryRoot`.

Commit once per milestone, each with all three trailers:

```text
feat(agent)!: gate every repository-settable field and model allowedTools as a grant

Tool grants are bounded by the maximum capability plus an operator
allow-list; timeout and output-limit get maxima; a repository executable,
extra-dirs, or out-of-root working-dir is refused.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/63-close-the-unattended-run-policy-ceiling.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(agent): refuse a ceiling file inside the repository and an unknown policy key

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/63-close-the-unattended-run-policy-ceiling.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
fix(agent)!: make the command surface truthful about warnings, evidence and exit codes

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/63-close-the-unattended-run-policy-ceiling.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

```text
feat(agent)!: 0.2 configuration surface, the ceiling ADR, and the guide

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/63-close-the-unattended-run-policy-ceiling.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

When done, update the parent MasterPlan: EP-6's four Progress lines checked, its registry status
`Complete`, and the final `AgentCeiling` field set recorded for EP-10, which must not change it.


## Validation and Acceptance

This plan is accepted when all of the following hold, each observable by a person.

With no operator file, `baikai agent run review --prompt "look"` against a repository
`.baikai/agents.kdl` whose job sets `capability "edit-workspace"` and `allowed-tools "Bash"` exits
77, prints a refusal naming `Bash`, `edit-workspace` and `policy.allowed-tools`, and starts no
process; with an operator file containing `policy { allowed-tools "Bash" }` or
`max-capability "full-access"` it runs. `Read`, `Edit` and `Write` under `edit-workspace` need no
grant; `Bash(git *)` is refused even when `Bash` is granted.

A repository document setting `executable` is refused naming `executable`; one setting a non-empty
`extra-dirs` is refused naming `extra-dirs`; the same settings in the operator file or through
`--set` are accepted. A repository `working-dir` of `"."` or a subdirectory is accepted; `".."`, an
absolute path outside the root, or a path through a symlink that leaves the root is refused naming
the resolved directory and the root. A `timeout` above `policy.max-timeout`, or no `timeout` under
a finite `max-timeout`, is refused naming both values; `output-limit "unlimited"` is refused under
the default ceiling naming `67108864` and accepted once the operator sets `max-output-limit
"unlimited"`. `BAIKAI_AGENT_EXECUTABLE=/evil baikai agent show review` shows `executable = (unset)`.

`baikai agent show review --user-config .baikai/policy.kdl`, and the same with
`XDG_CONFIG_HOME=$PWD/.baikai`, exit 78 naming the file and the root; an operator file with
`policy { max-capabilty "read-only" }` exits 78 naming `policy.max-capabilty`. `baikai agent show
demo` against a repository defining `demo` and `other` and an operator file with a `policy` node
prints nothing on standard error; a repository `policy` node prints exactly one notice; a
misspelled key inside `demo` still warns.

`baikai agent run demo --prompt x --run-id r` with neither `--evidence-file` nor `--json` exits 64
naming `--evidence-file`; with `--json` the envelope's `evidence.run_id` is `r`. No code path
produces exit 70. An evidence record for a job whose executable is `./bin/agent` names
`<working-dir>/bin/agent` as its endpoint. A failed run with 100 KiB of standard error produces an
`error_info.message` of at most 4096 bytes plus a truncation prefix, ending with the tool's last
line. A symlink planted at `<evidence-file>.partial` is never written through; the record lands
and no `.partial` file remains.

`agentRunRequest` defaults `outputFormat` to `TextFormat` and `envRequires` to `[]`;
`#envPassthrough` no longer compiles. `output-format "json"` renders `--output-format json` for
Claude and `--json` for Codex in the positions the vendor tests pin. `show --json` on a malformed
document emits one object with `outcome` `failed` and `exitCode` `78`.

`docs/adr/` has the new record and its README row. The guide documents the three treatments, the
three `policy` keys, `output-format`, the ceiling-file rule, the corrected refusal texts, the
`renderEffectiveConfig` format, the evidence destination rule and the migration note; its
environment table has three rows and its exit-code table no `70`. CAP-17 and CAP-18 agree, and
CAP-18's `Shape` is the schema the code accepts. `CHANGELOG.md` has `[Unreleased]` bullets for all
four packages. `nix fmt`, `git diff --check`, `cabal build all`, the keyless `cabal test all`, and
`nix flake check` all succeed. No acceptance step invokes a live model or an installed
coding-agent binary with a prompt.


## Idempotence and Recovery

Every step can be repeated. Tests write only under `withSystemTempDirectory`; the manual transcript
writes under `/tmp/baikai-ceiling` and `/tmp/baikai-ceiling-home` and is removed with one
`rm -rf`. Nothing contacts a provider.

The milestones are separable and each leaves the workspace green. Milestone 1 changes behaviour a
consumer may depend on — a repository that today sets `executable` or grants `Bash` stops working
until the operator writes a policy — so its commit carries `!` and the changelog says what to add.
Inside Milestone 1 the safe order is: core types and `applyAgentCeiling` with their tests, then the
configuration layer, then the harness rework as its own no-behaviour-change step, then the
fixtures. If EP-1 has already landed in `Run.hs`, rebase: this plan's edits are confined to
`runAgentCommand`'s precondition line, `evidenceStatus`, `buildEvidence` and `agentEndpoint`. If it
has not, leave `spawn`, `consume`, `waitWithTimeout`, `terminateGroup` and `drain` alone. To roll
back, revert the milestone commits in reverse order; documentation is edited in the same commits
as the code it describes, so a revert never leaves the guide ahead of behaviour.


## Interfaces and Dependencies

No new package dependencies. `baikai-agent` already declares `aeson`, `directory`, `filepath` and
the `settei` packages. `openBinaryTempFileWithDefaultPermissions` is in `base`;
`canonicalizePath`, `getCurrentDirectory`, `createDirectoryLink` and `createFileLink` are in
`directory` 1.3.10, the version in this workspace.

At completion `baikai/src/Baikai/Agent.hs` exports these in addition to today's names, and no
longer exports `OutputMalformed` or the field `envPassthrough`:

```haskell
data AgentOutputFormat = TextFormat | JsonFormat
renderAgentOutputFormat :: AgentOutputFormat -> Text
parseAgentOutputFormat :: Text -> Maybe AgentOutputFormat

-- AgentRunRequest fields, final: provider, prompt, modelId, effort, workingDir,
-- extraDirs, safety, timeout, output, outputFormat, outputLimit, envRequires

-- AgentCeiling fields, final; EP-10 must not change this set:
--   maxCapability, allowProviderArgs, allowedProviders,
--   allowedTools :: [Text], maxTimeout :: Maybe NominalDiffTime, maxOutputLimit :: Maybe Int
defaultMaxOutputLimit :: Int   -- 67108864
toolGrantsImpliedBy :: AgentCapability -> Maybe [Text]

data CeilingViolation
  = CapabilityExceeded !AgentCapability !AgentCapability
  | ProviderArgsForbidden ![Text]
  | ProviderForbidden !AgentProvider ![AgentProvider]
  | ToolGrantForbidden ![Text] !AgentCapability
  | TimeoutExceeded !(Maybe NominalDiffTime) !NominalDiffTime
  | OutputLimitExceeded !(Maybe Int) !Int
  | RepositoryScopeForbidden !Text
  | WorkingDirOutsideRepository !FilePath !FilePath
```

`baikai-agent/src/Baikai/Agent/Config.hs` exports, beyond today's names:

```haskell
data AgentConfigPaths = AgentConfigPaths
  { userConfig :: !(Maybe FilePath), repoConfig :: !(Maybe FilePath), repositoryRoot :: !FilePath }

data AgentConfigError
  = ConfigFileUnreadable !FilePath !Text
  | InvalidJobName !Text !Text
  | CeilingFileInsideRepository !FilePath !FilePath
  | UnknownPolicySetting !FilePath ![Text]

repositoryScopeViolations ::
  AgentConfigPaths -> ResolutionReport -> Text -> AgentJob -> IO [CeilingViolation]
ceilingViolations :: AgentCeiling -> AgentRunRequest -> [CeilingViolation]
relevantWarnings :: Text -> [ConfigWarning] -> [ConfigWarning]
repositoryPolicyNotice :: [ConfigWarning] -> Maybe Text
agentEnvBindings :: Text -> Bindings   -- BAIKAI_AGENT_PROVIDER, _MODEL, _TIMEOUT only
```

`Baikai.Agent.Run` additionally exports `errorInfoStderrTailBytes :: Int` and
`executableForEvidence :: AgentRunRequest -> AgentCommand -> FilePath`; `Baikai.Agent.Cli` no
longer exports `internalExitCode`.

The KDL schema at completion, which the guide documents and the tests pin:

```kdl
// operator scope: ~/.config/baikai/agents.kdl — must lie outside the repository
policy {
  max-capability      "edit-workspace"   // read-only | edit-workspace | full-access
  allow-provider-args #false
  allowed-providers   "claude" "codex"
  allowed-tools       "Bash" "Skill"     // grants beyond the capability; default none
  max-timeout         "2h"               // duration or "unlimited"; default unlimited
  max-output-limit    67108864           // bytes or "unlimited"; default 67108864
}

// repository scope: ./.baikai/agents.kdl — untrusted; every setting is bounded,
// operator-only, or confined to the repository root
jobs {
  review {
    provider      "claude"          // required; bounded by allowed-providers
    working-dir   "."               // required; a repository value must stay inside the root
    timeout       "45m"             // optional; bounded by max-timeout
    output        "capture"         // inherit | capture | tee
    output-format "json"            // text | json; default text
    output-limit  4194304           // bounded by max-output-limit
    env-requires  "KEIRO_PATH"      // names only
    safety {
      capability    "edit-workspace"   // required; bounded by max-capability
      allowed-tools "Read" "Bash"      // grants; bounded by the capability plus policy.allowed-tools
      provider-args "--betas" "x"      // secret; needs allow-provider-args
    }
    // executable and extra-dirs here are refused; set them in the operator file or with --set
  }
}
```

The precedence contract, updated:

```text
layer              can set job settings                       can set the ceiling
built-in defaults  yes                                        yes (the default)
operator file      yes, including executable and extra-dirs   yes; refused if inside the repository
repository file    yes, except executable and extra-dirs;     no
                   working-dir confined to the root
environment        provider, model, timeout                   no
command line       yes, including executable and extra-dirs   no
```

Downstream impact: `baikai` breaks (`envPassthrough` renamed, `OutputMalformed` removed,
`CeilingViolation` extended); `baikai-agent` breaks (`AgentConfigPaths` field, refusals, exit 70,
envelope shape); both vendor packages change additively. EP-10 records the version bumps; EP-11
sweeps whatever documentation this plan did not own.
