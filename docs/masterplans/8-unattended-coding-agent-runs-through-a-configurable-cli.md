---
id: 8
slug: unattended-coding-agent-runs-through-a-configurable-cli
title: "Unattended coding-agent runs through a configurable CLI"
kind: master-plan
created_at: 2026-07-30T04:35:32Z
intention: "intention_01kyrmt8wjeyyaygk69s6r0s7d"
---

# Unattended coding-agent runs through a configurable CLI

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This initiative implements
`docs/improvement-requests/add-configurable-cli-for-unattended-coding-agent-runs.md`
(IR-1). That request is the statement of the problem; this MasterPlan is the accepted
design. Where the two disagree, this MasterPlan wins, and the Decision Log below records
why.


## Vision & Scope

Baikai currently has two integration surfaces. The first is **API and batch completions**:
`completeRequest` / `streamRequest` reach either a provider HTTP API or a batch subprocess
(`claude -p`, `codex exec`) and return a `Response`. The second is **interactive launches**:
`launchClaudeInteractive` / `launchCodexInteractive` hand a real terminal to the vendor CLI
and return only an exit code when the human quits. Neither is what unattended automation
needs. Automation wants the coding agent to own its internal tool loop, mutate an
explicitly authorized working tree, and return a process result — with no terminal, no
human, and no fabricated token accounting.

After this initiative there is a third surface: an **unattended coding-agent run**. A shell
script invokes one stable command, supplies a prompt on standard input, and selects Claude
Code or Codex entirely through configuration. The concrete before-and-after is the first
consumer, `scripts/sync-keiro-dsl.sh` in the `shinzui/keiro-syntax` repository, which today
embeds provider-specific flags directly:

```bash
claude -p "$prompt" \
  --add-dir "$keiro_path" \
  --permission-mode acceptEdits \
  --allowedTools Read Write Edit Glob Grep Bash Skill TodoWrite
```

After this initiative that launch becomes provider-neutral, with the flag knowledge living
in Baikai and the policy living in a repository-owned KDL file:

```bash
printf '%s' "$prompt" | baikai agent run sync-keiro-dsl \
  --prompt-stdin \
  --set extra-dir="$keiro_path"
```

Switching that job from Claude Code to Codex becomes a one-line configuration edit rather
than a script rewrite.

Three properties make the surface trustworthy rather than merely convenient. First, every
run is **capped**: a repository-owned job file is untrusted input, so a user-level policy
file bounds the maximum authority any job may request, and exceeding that bound is a loud
refusal rather than a silent downgrade. Second, every effective configuration is
**inspectable**: `baikai agent show <job>` prints each selected value, the scope and file
position it came from, and the exact argument vector that would be spawned, without
launching anything and without rendering secret material. Third, every safety mapping is
**total**: a policy a provider cannot express fails before process creation instead of
quietly becoming a weaker policy.

In scope: a provider-neutral unattended request/result vocabulary in the core `baikai`
package; pure argument-vector renderers in `baikai-claude` and `baikai-openai`; a new
publishable `baikai-agent` package holding the process runner, the layered configuration
layer, and the `baikai` executable with `agent run`, `agent show`, and `agent list`; a
repair to the existing interactive launchers, which today drop cross-provider safety policy
silently; user documentation; pure command-rendering tests; and integration tests that
drive fake executables so no live model is ever called.

Out of scope, following the improvement request: moving deterministic workflow logic, test
gates, marker handling, or commits out of consuming scripts merely because they now call
this command; defining Handan's task registry or result envelope; normalizing the native
tool names of every present and future coding agent, for which a capability profile plus an
explicit provider escape hatch is enough in the first version; installing or authenticating
Claude Code or Codex; and treating an unattended run as a Baikai API completion with
invented token usage or response metadata.


## Decomposition Strategy

The initiative decomposes by functional concern into six child plans grouped in four
implementation waves. The shape follows the architecture the repository already uses for
interactive launches: the core package owns pure provider-neutral vocabulary, vendor
packages own their own command-line flags, and application-level concerns live outside
both.

EP-1 defines the vocabulary and, critically, the pure policy-ceiling algebra. It is first
because every other plan consumes its types, and because the security core of the
initiative — deciding whether a requested safety policy is within a permitted ceiling — is
a pure function that deserves pure tests before any process is ever spawned.

EP-2 translates that vocabulary into Claude Code and Codex argument vectors. It is separate
from EP-1 because vendor flag knowledge belongs in vendor packages, and separate from the
runner because rendering is pure and exhaustively testable while spawning is not.

EP-3 repairs the existing interactive launchers so both surfaces honor one safety contract.
It is its own plan rather than a footnote in EP-2 because it changes already-published
behavior, carries the release consequences, and must be able to be scheduled, reviewed, and
reverted independently of the new surface.

EP-4 creates the `baikai-agent` package and the process runner. It is separate from EP-2
because the runner consumes an already-rendered command and therefore needs nothing from
the vendor packages, which lets it proceed in parallel. It is separate from EP-5 because
spawning processes and resolving configuration fail in completely different ways and are
verified with completely different fixtures: fake executables for one, KDL documents and
environment snapshots for the other.

EP-5 adds the layered configuration layer on top of `settei`. It is separate from EP-4
because it is pure resolution logic with no subprocess involvement, and separate from EP-6
because a resolved job plus a rendered command is a complete, testable artifact before any
command-line parser exists.

EP-6 ships the executable, the documentation, and the end-to-end proof against the
`sync-keiro-dsl.sh` shape, and coordinates the release. It is last because it is the only
plan that requires every other artifact to exist simultaneously.

Alternatives considered and rejected. Putting the runner and configuration layer in the core
`baikai` package was rejected: core has no `process`, `directory`, or
`optparse-applicative` dependency today, `Baikai.Interactive` is deliberately pure
vocabulary, and an executable in core could not reach the vendor renderers it must dispatch
to without core depending on its own provider packages. Publishing two new packages, a
`baikai-agent` library and a separate `baikai-cli` executable as the improvement request
suggested, was rejected because it would move vendor flag mapping out of the vendor
packages and diverge from how the interactive surface is organized, for the benefit of a
library/executable split that a single package with an `executable` stanza already
provides. Extending `InteractiveLaunchRequest` with unattended fields was rejected because
an inherited terminal and a captured, timed, byte-capped subprocess are different
contracts, and merging them would repeat the mistake the interactive MasterPlan explicitly
avoided when it declined to extend `ApiProvider`. Hand-rolling the configuration layer was
rejected because layer precedence, per-value scope attribution, and secret redaction are
exactly the load-bearing parts of improvement-request safety requirements 3 and 4, and
`settei` already implements them with published Hackage releases.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Add the unattended agent-run core abstraction | docs/plans/45-add-the-unattended-agent-run-core-abstraction.md | None | None | Complete |
| EP-2 | Render Claude and Codex unattended agent commands | docs/plans/46-render-claude-and-codex-unattended-agent-commands.md | EP-1 | None | Complete |
| EP-3 | Make interactive launch safety mapping fail visibly | docs/plans/47-make-interactive-launch-safety-mapping-fail-visibly.md | EP-1 | EP-2 | Complete |
| EP-4 | Build the baikai-agent package and unattended process runner | docs/plans/48-build-the-baikai-agent-package-and-unattended-process-runner.md | EP-1 | EP-2 | Complete |
| EP-5 | Resolve unattended agent jobs with layered KDL configuration | docs/plans/49-resolve-unattended-agent-jobs-with-layered-kdl-configuration.md | EP-1, EP-4 | None | Complete |
| EP-6 | Ship the baikai agent CLI and prove the unattended fixture | docs/plans/50-ship-the-baikai-agent-cli-and-prove-the-unattended-fixture.md | EP-2, EP-4, EP-5 | EP-3 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).

The four implementation waves are: wave one is EP-1 alone; wave two is EP-2, EP-3, and EP-4
in parallel; wave three is EP-5; wave four is EP-6.


## Dependency Graph

EP-1 has no dependencies and must run first. It creates
`baikai/src/Baikai/Agent.hs`, which defines the unattended request and result types, the
capability profile, the policy ceiling, the pure ceiling-intersection function, and the
render-error and run-failure taxonomies. Every later plan imports these names. Without them
each later plan would invent its own spelling of "what safety did this job ask for," which
is the specific failure the improvement request set out to prevent.

EP-2 hard-depends on EP-1 because its two new modules are functions from EP-1's request
type to an argument vector, and because refusing an unsupported policy means returning
EP-1's render-error type rather than a locally invented one.

EP-3 hard-depends on EP-1 for the same render-error type: the point of the plan is that the
interactive surface and the unattended surface share one safety contract, which requires
sharing the type that expresses a refusal. EP-3 soft-depends on EP-2 because reviewing
EP-2's total-mapping tests first makes the interactive repair mechanical rather than
exploratory, but EP-3 does not read any artifact EP-2 produces and can proceed without it.

EP-4 hard-depends on EP-1 for the request, result, output-mode, and failure types. It
soft-depends on EP-2 only for realistic end-to-end fixtures: the runner deliberately
accepts an already-rendered executable-and-arguments pair, so it never imports a vendor
renderer and can be built and tested with hand-written argument vectors while EP-2 is still
in progress. This decoupling is intentional and is what lets wave two run three plans
concurrently.

EP-5 hard-depends on EP-1 because it decodes KDL documents into EP-1's types, and on EP-4
because EP-4 creates the `baikai-agent` package directory, its `.cabal` file, and its test
suite, into which EP-5 adds modules. Attempting EP-5 before EP-4 would mean inventing the
package skeleton twice.

EP-6 hard-depends on EP-2, EP-4, and EP-5 simultaneously: the executable dispatches a
resolved job through a vendor renderer into the runner, so it is the first point at which
all three must agree. It soft-depends on EP-3 because the coordinated release EP-6
performs should ideally carry EP-3's provider-package major bumps in the same release set;
if EP-3 slips, EP-6 can release without it at the cost of a second release cycle later.

EP-2, EP-3, and EP-4 can proceed fully in parallel once EP-1 is complete. Nothing else may
proceed in parallel: EP-5 serializes behind EP-4's package skeleton, and EP-6 serializes
behind everything.


## Integration Points

`baikai/src/Baikai/Agent.hs` is the initiative's central shared artifact. **EP-1 owns it.**
EP-2, EP-3, EP-4, EP-5, and EP-6 all consume it and none may redefine any of its types. It
exports the unattended provider identity, the request record, the result record, the
capability profile, the safety request, the policy ceiling, the pure function that
intersects a request against a ceiling, the output-discipline enumeration, the render-error
type, and the run-failure type. Later plans extend behavior by adding functions in their own
modules, never by widening EP-1's records in place; EP-1 therefore hides its record
constructors and exports base values plus field accessors, exactly as
`baikai/src/Baikai/Interactive.hs` already does, so that adding a defaulted field later is
not a breaking change.

The **capability profile** is the single most important shared decision, because it is where
"provider-neutral" either holds or leaks. EP-1 defines the profile as a small closed set —
read-only, edit-workspace, and full-access — and defines the ceiling as a maximum profile
plus an explicit boolean permitting raw provider arguments. EP-2 owns the mapping from that
profile to each vendor's flags and owns the mapping table's tests. EP-5 owns decoding the
profile from KDL and loading the ceiling from the user-scope file. EP-6 owns displaying the
resolved profile and its provenance. The division matters: if EP-2 discovers that a profile
cannot be expressed honestly for one provider, the correct response is to record it in this
MasterPlan's Surprises & Discoveries section and refuse at render time, never to invent a
near-miss flag. The improvement request's safety requirement is explicit that unsupported
shared policy must fail visibly rather than downgrade.

`AgentCommand`, the rendered executable-plus-argument-vector-plus-prompt-transport value,
is the boundary between EP-2 and EP-4. **EP-1 owns the type** so that neither side depends
on the other; EP-2 produces it and EP-4 consumes it. Because it carries the prompt
transport as data rather than as an argument string, EP-4 can implement standard-input
delivery without knowing which provider it is spawning, and EP-2 can decide per provider
whether the prompt travels on standard input or as a positional argument protected by the
provider's `--` separator.

`Baikai.Interactive`'s `InteractiveSafety` type is shared between EP-1 and EP-3 in a
subtler way: EP-3 does not reuse it, it repairs the launchers that consume it. EP-1 must
not attempt to unify `InteractiveSafety` and the new unattended safety request into one
type. They describe different vocabularies — the interactive one has no notion of a
capability profile or a ceiling, and the unattended one has no notion of an inherited
terminal — and the two surfaces are kept honest by sharing the *refusal* type, not the
policy type. EP-3's Decision Log must record this explicitly so a later contributor does
not "simplify" them into one.

`baikai-agent/baikai-agent.cabal` is shared between EP-4, EP-5, and EP-6. **EP-4 creates
it** with the library stanza, the test suite, and the `process` dependency. EP-5 adds the
four `settei` dependencies and its configuration modules to the existing stanzas. EP-6 adds
the `executable baikai` stanza and the `optparse-applicative` dependency. Each plan must
add only its own modules to `exposed-modules` and `other-modules` and must not reorder or
remove another plan's entries.

The root `CHANGELOG.md` is shared by all six plans. The repository has exactly one changelog
covering every package, not one per package. Each plan adds package-scoped bullets under the
`[Unreleased]` heading and none of them creates dated release headings; EP-6 coordinates the
actual release through `agents/skills/release/SKILL.md`.

`agents/skills/release/SKILL.md` is shared between EP-4 and EP-6. It currently enumerates
six publishable packages in dependency order and asserts that every publishable package
resolves from Hackage only. **EP-4 adds `baikai-agent` to that enumeration** when it creates
the package, so the list is never wrong in the interim; EP-6 owns the dependency-bound
updates and the actual publish. Both plans must respect the Hackage-only rule, which is why
the `settei` family was verified as published before being chosen.

Documentation is shared across the initiative. EP-6 owns the new
`docs/user/unattended-agent-runs.md` guide. EP-1 and EP-3 own the edits to
`docs/user/interactive-launches.md`; EP-6 owns the edits to `docs/user/cli-providers.md`
that point readers from the two existing surfaces to the third. Every plan that changes
observable behavior updates the root `README.md` highlight list.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1 (2026-08-05): Define `Baikai.Agent` request, result, capability profile, output discipline, and provider identity.
- [x] EP-1 (2026-08-05): Define the policy ceiling and the pure ceiling-intersection function that refuses rather than clamps.
- [x] EP-1 (2026-08-05): Define the render-error and run-failure taxonomies distinguishing refusal, spawn failure, timeout, malformed output, and non-zero exit.
- [x] EP-1 (2026-08-05): Add pure tests covering every capability/ceiling pair, including every refusal.
- [x] EP-2 (2026-08-05): Render Claude Code unattended argument vectors, including permission mode, tool allow-list, and additional directories.
- [x] EP-2 (2026-08-05): Render Codex unattended argument vectors, including sandbox mode, working root, and additional directories.
- [x] EP-2 (2026-08-05): Prove both renderers refuse unsupported policy before any process would be created.
- [x] EP-2 (2026-08-05): Add exact whole-argv tests, including prompts and paths beginning with a dash.
- [x] EP-3 (2026-08-05): Make the Claude and Codex interactive safety mappings total and visibly failing.
- [x] EP-3 (2026-08-05): Update interactive-launch documentation and record the release consequence of the changed signatures.
- [x] EP-4 (2026-08-05): Create the `baikai-agent` package skeleton and register it in `cabal.project` and the release skill.
- [x] EP-4 (2026-08-05): Implement the process runner with standard-input prompt delivery, timeout with process-group termination, output caps, and the three output disciplines.
- [x] EP-4 (2026-08-05): Add fake-executable integration tests for working directory, timeout, non-zero exit, spawn failure, and output truncation.
- [x] EP-5 (2026-08-05): Declare the `settei` configuration for an unattended job and decode it from KDL.
- [x] EP-5 (2026-08-05): Implement scope discovery and the built-in, user, repository, environment, and command-line layer order.
- [x] EP-5 (2026-08-05): Load the user-scope policy ceiling and apply it to every resolved job.
- [x] EP-5 (2026-08-05): Add tests for precedence, per-value provenance, secret redaction, and ceiling refusal.
- [ ] EP-6: Implement `agent run`, `agent show`, and `agent list` with documented exit codes and stream discipline.
- [ ] EP-6: Prove the `sync-keiro-dsl.sh` launch shape end-to-end against fake executables.
- [ ] EP-6: Write `docs/user/unattended-agent-runs.md` and cross-link the two existing surfaces.
- [ ] EP-6: Coordinate the release across every affected package and update the improvement-request status.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: `codex exec` does not accept `--ask-for-approval`. The installed
  `codex-cli 0.146.0` exposes `-a, --ask-for-approval` only on the top-level interactive
  `codex` command; `codex exec --help` lists `-s/--sandbox`,
  `--dangerously-bypass-approvals-and-sandbox`, `-C/--cd`, `--add-dir`,
  `--skip-git-repo-check`, `--ephemeral`, `--json`, and `-o/--output-last-message`, with no
  approval flag. The improvement request's claim that Codex "may render its sandbox,
  approval, `--cd`, and `--add-dir` arguments" is therefore false for the unattended path.
  Consequence: approval policy is not part of the shared unattended vocabulary. EP-1 must
  not add it, and EP-2 must express any approval intent through Codex's generic
  `-c approval_policy=<value>` config override behind the raw-argument opt-in.

- Discovery: the policy the first consumer actually needs cannot be expressed by the
  existing interactive vocabulary at all. `baikai/src/Baikai/Interactive.hs` defines
  `InteractiveSafety` as `DefaultSafety | ClaudeAllowedTools [Text] | CodexSandbox … …`,
  with no representation of Claude's `--permission-mode`. The `sync-keiro-dsl.sh` fixture
  needs `acceptEdits` *and* a tool allow-list together. Consequence: EP-1 defines new safety
  vocabulary rather than reusing `InteractiveSafety`, and this is the evidence for the
  Decision Log entry that the two types stay separate.

- Discovery: the existing interactive launchers already violate the safety contract this
  initiative is adopting. `baikai-claude/src/Baikai/Provider/Claude/Interactive.hs` line 109
  returns `[]` for a `CodexSandbox` policy, and
  `baikai-openai/src/Baikai/Provider/OpenAI/Interactive.hs` line 118 returns `[]` for a
  `ClaudeAllowedTools` policy. Both are silent downgrades to a weaker policy than the caller
  asked for. Consequence: EP-3 exists as a scoped repair rather than the defect being merely
  documented.

- Discovery: `cradle` cannot implement the unattended runner. The dependency source at
  `/Users/shinzui/Keikaku/hub/haskell/cradle-project` exposes `setStdinHandle :: Handle`,
  `setNoStdin`, `addStdoutHandle`, `silenceStdout`, `setWorkingDir`, and
  `modifyEnvVar`, but no timeout, no way to write a `ByteString` to a child's standard
  input, and no output-size bound. `baikai-claude` uses `cradle` while `baikai-openai`
  already uses `System.Process` directly for its Codex batch provider. Consequence: EP-4
  uses `System.Process`, and the `process` dependency lands in `baikai-agent` rather than in
  core, keeping `baikai` free of a process dependency.

- Discovery: the configuration layer is largely already built and published. `settei`,
  `settei-kdl`, `settei-env`, and `settei-optparse-applicative` are all at `0.2.0.0` on
  Hackage (verified by HTTP query against `hackage.haskell.org`), and `kdl-hs` is at
  `1.1.1`. `settei` provides deterministic layer precedence, `Origin`/`SourceLocation`
  provenance, `Secret` sensitivity that is redacted before a value can enter a report *or a
  structured error*, and `renderResolutionText`/`renderResolutionJson`. `settei-kdl` records
  exact node spans. Consequence: EP-5 declares a `Config` and wires four sources instead of
  building precedence and redaction from scratch, and improvement-request acceptance
  criterion 5 is nearly free. Caveat recorded for EP-5: `settei` 0.2.0.0 describes itself as
  experimental in its own README.

- Discovery: `settei` has no cap or ceiling semantics. Grepping
  `/Users/shinzui/Keikaku/bokuno/settei/settei/src/Settei/` for `ceiling`, `clamp`,
  `constrain`, and `restrict` returns nothing; the "most restrictive" behavior its security
  document describes applies to merging `Public` against `Secret` sensitivity, not to
  bounding a value. Consequence: the user-level policy ceiling is Baikai's own logic, it is
  pure, and EP-1 owns it. This is the reason the ceiling is a wave-one concern rather than a
  detail of the configuration plan.

- Discovery: Claude's unattended permission vocabulary is wider than the improvement request
  implies. Installed Claude Code 2.1.220 accepts `--permission-mode` values `acceptEdits`,
  `auto`, `bypassPermissions`, `manual`, `dontAsk`, and `plan`, and `--allowedTools` accepts
  a comma- or space-separated list. Consequence: EP-2's mapping table must state which of
  the six modes each capability profile selects and why, and must treat `manual` and
  `dontAsk` as unusable for unattended runs because they can block forever waiting for a
  human.

- Discovery: `--add-dir` does not mean the same thing on both providers. Claude documents it
  as "additional directories to allow tool access to"; `codex exec` documents it as
  "additional directories that should be writable alongside the primary workspace".
  Consequence: the shared `extraDirs` field grants read-or-write authority on Claude and
  write authority on Codex, and EP-2 and EP-6 must document the divergence rather than
  claim the field is fully neutral.

- Discovery (EP-1, 2026-08-05): the shared vocabulary in `baikai/src/Baikai/Agent.hs` exports
  the accessors of its abstract records — `AgentRunRequest`, `AgentSafety`, and `AgentCeiling`
  — through the subordinate-name form, `AgentRunRequest (provider, prompt, …)`, not as bare
  top-level names. GHC 9.12.4 rejects a bare export of a field name that two records in one
  module define, and `provider` is defined by both the request and the result:
  `error: [GHC-87543] Ambiguous occurrence ‘provider’`. The subordinate form still hides the
  data constructor, so the "extend by adding a defaulted field, never by widening a
  constructor" property this MasterPlan's Integration Points section requires is intact, and
  consumers see no difference because they read fields through `generic-lens` labels. Every
  consuming plan — EP-2, EP-3, EP-4, EP-5, EP-6 — is unaffected in practice. Consequence for
  any plan that adds a record to `Baikai.Agent`: use the same export form when a field name
  collides, and do not reach for a type prefix, which repository convention forbids.

- Discovery (EP-1, 2026-08-05): no capability profile turned out to be inexpressible, so EP-2
  starts from the vocabulary as designed. EP-1 renders no flags and therefore proves nothing
  about expressibility; it only confirms that nothing in the *shape* of the three profiles
  forced a change. The refusal path EP-2 needs is in place and exported:
  `UnsupportedCapability`, `UnsupportedToolRestriction`, and `ProviderMismatch`, each carrying
  a human-readable explanation the renderer supplies.

- Discovery (EP-1, 2026-08-05): this repository has no ADR corpus, so cross-plan durable
  context has nowhere to be promoted to yet. There is no `docs/adr/` directory, and
  `mori.dhall` declares exactly one OKF bundle — `improvement-requests` at
  `docs/improvement-requests`, profiled by `mori/improvement-requests-profile.dhall` — with no
  bundle whose path is `docs/adr`. Per `agents/skills/exec-plan/ADR.md`, adopting a corpus is
  separate work through the `adopt-architecture-decisions` Seihou blueprint and must not be an
  incidental plan edit. Consequence: EP-2 through EP-6 should keep recording durable decisions
  in their Decision Logs and in this MasterPlan, and the MasterPlan's completion ADR
  distillation pass has a prerequisite — either adopt the bundle first, or record explicitly
  that the durable context stays in the plans. Candidates already identified for promotion:
  core stays pure while spawning and configuration live in `baikai-agent`; a ceiling refuses
  rather than clamps; the interactive and unattended policy types stay separate and share only
  the refusal type; unattended failures do not reuse `Baikai.Error`.

- Discovery (EP-2, 2026-08-05): the flag table this initiative was designed against still
  holds. Re-verified against Claude Code `2.1.222` (a patch ahead of the `2.1.220` the plans
  cite) and `codex-cli 0.146.0`: `--permission-mode` still offers all six values including
  `plan` and `acceptEdits`, `--allowedTools` and `--add-dir` are still variadic on Claude,
  `codex exec` still exposes `--sandbox`, `--cd`, `--add-dir`, `--skip-git-repo-check`, and
  `--ephemeral`, and `codex exec --help | grep ask-for-approval` still prints nothing. No
  capability turned out to be inexpressible, so EP-5 and EP-6 can document the mapping tables
  exactly as this MasterPlan's Integration Points section anticipated.

- Discovery (EP-2, 2026-08-05): `PromptAsArgument` is now a transport that **no shipped renderer
  selects**. Both `claudeAgentCommand` and `codexAgentCommand` always choose `PromptOnStdin`,
  because standard-input delivery removes the dash-leading-prompt hazard on both tools and
  avoids Codex's `<stdin>`-block trap entirely. The constructor is still load-bearing: EP-1
  exports it, and EP-4's runner must honor it, since that is the only place the two-sided
  contract can be observed — a fixture executable can check whether the prompt arrived on
  standard input or as an argument, which a pure renderer test cannot. Consequence for EP-4: do
  not treat the branch as dead code, and pin it with a fixture rather than assuming a renderer
  will produce it.

- Discovery (EP-3, 2026-08-05): the pre-fix evidence for the silent downgrade, which this
  MasterPlan's Vision & Scope cites as one of the three trustworthiness properties. Temporary tests
  written before the repair showed that a caller asking Claude for
  `CodexSandbox CodexReadOnly CodexApprovalNever`, and a caller asking Codex for
  `ClaudeAllowedTools ["Read"]`, each received the identical unrestricted argument vector
  `["--", "inspect the repo"]` — no `--allowedTools`, no `--sandbox`, no `--ask-for-approval`. The
  requested restriction left no trace at all, so the defect could not have been caught by reading a
  process listing either. Both surfaces now refuse with `SafetyNotExpressible` and start no process.
  Consequence for EP-6: the coordinated release's changelog can state the before-and-after
  concretely rather than describing the old behavior abstractly, and the user guide already quotes
  both refusal messages verbatim for searchability.

- Discovery (EP-3, 2026-08-05): the two provider packages are **not** at the same version, contrary
  to what EP-3's own release note assumed. `baikai-claude` is at `0.4.0.1` — bumped on 2026-07-30 for
  a `crypton` bound widening — while `baikai-openai` is still at `0.4.0.0`. Both need a PVP-major
  bump for EP-3's signature changes, so the substance is unchanged, but EP-6 must compute each
  package's next major from its actual in-tree version rather than assuming the pair moves in step.

- Discovery (EP-3, 2026-08-05): the workspace has no interactive-launcher caller outside the two
  vendor test suites. `baikai-smoke/test/InteractiveSmoke.hs`, which EP-3 named as the single most
  dangerous edit in the initiative because its `findExecutable` gating stands between the suite and
  real billable calls, only runs `claude --help` and `codex --help` and greps the help text; it never
  builds an `InteractiveLaunchRequest`. It was therefore left completely untouched. Consequence: the
  `Baikai.Interactive` surface has exactly one in-repository consumer shape, and the only party that
  must adapt to the new `Either` is the external `shinzui/seihou` project, whose
  `Seihou.CLI.AgentLaunchExec` module builds interactive launch requests. EP-6's release must say so
  explicitly, because a downstream consumer that upgrades without adapting will fail to compile.

- Discovery (EP-4, 2026-08-05): **interrupting the process group does not kill a coding agent's
  shell-spawned children**, which is the one cross-plan fact this initiative's timeout story depends
  on. POSIX requires a non-interactive shell to set `SIGINT` to *ignored* in the background commands
  it starts, so `interruptProcessGroupOf` — the only group-wide signal the `process` package offers
  — reaches the agent and not the children it backgrounded. Because the interrupt does kill the
  agent, the leader exits inside the grace period and any escalation conditioned on "the leader is
  still running" never executes, so the grandchild survives everything and keeps writing to the
  working tree a script is about to inspect and commit. EP-4 therefore escalates to a group-wide
  `SIGTERM` unconditionally through `System.Posix.Signals.signalProcessGroup`, since `process` has
  no group-wide terminate, behind an `if !os(windows)` Cabal conditional and a
  `BAIKAI_POSIX_SIGNALS` CPP guard. One ordering detail is load-bearing: `P.getPid` yields `Nothing`
  once a process is reaped, so the group identifier must be read before the grace-period wait.
  Consequence for EP-6: the `baikai agent run` documentation may state plainly that a timeout
  terminates the agent's own child processes, and the executable must not introduce a second, weaker
  termination path of its own. Consequence for EP-5: the package now carries a non-Windows
  conditional, so a configuration module needing POSIX facilities should reuse the existing guard
  rather than adding a second spelling.

- Discovery (EP-4, 2026-08-05): draining an output stream on the thread that waits for the process
  makes the timeout unreachable whenever output is captured, because the drain blocks until the
  child closes the pipe. The runner forks both drains and waits on its own thread. The classic
  deadlock the initiative was guarding against — waiting before draining, so a child that fills the
  64-kilobyte pipe buffer blocks forever — is still avoided, because draining still *starts* before
  the wait; only which thread does the reading changed. Consequence for EP-6: `agent run` gets a
  working timeout in all three output disciplines rather than only when output is inherited, which
  matters because a CI consumer will want `capture` and a deadline at the same time.

- Discovery (EP-4, 2026-08-05): `PromptAsArgument` gives the child no standard input at all, so a
  fixture that reads standard input under that transport *fails* rather than reading nothing —
  `cat` exits 1 with a bad-file-descriptor error. That failure is the evidence the transport is
  honored. This closes the loop on the EP-2 discovery that no shipped renderer selects the
  transport: EP-4's fixture is the place the two-sided contract is observed, exactly as EP-2
  anticipated, and the branch is not dead code.

- Discovery (EP-5, 2026-08-05): the verified KDL key shapes, which EP-6 needs before it writes
  example configuration files. Nested nodes flatten to dotted keys through at least three levels, so
  `jobs { demo { safety { capability … } } }` reaches `jobs.demo.safety.capability`; **hyphens are
  legal in every key segment**, in job names as well as leaf names, so no word-separator change was
  needed; `#false` is the correct KDL v2 boolean literal; and `settei-kdl`'s spans survive into each
  value's `Origin` with a path, a line, and a column. Consequence: EP-6 can write the documented
  schema verbatim.

- Discovery (EP-5, 2026-08-05): **a KDL node's argument count changes its raw type**, which broke the
  schema this MasterPlan's Integration Points section anticipated. A list-shaped node with zero
  arguments is a `RawNull`, with one argument a `RawText`, and only with two or more a `RawArray`;
  `settei`'s `listDecoder` accepts `RawArray` alone. So `extra-dirs "/path/one"` — the single-value
  spelling the plans documented — would have failed with "expected an array", and no list-valued
  `--set` override could ever have worked, because `cliOverride` always builds a `RawText`.
  Consequence: EP-5 defines a `scalarOrListDecoder` and uses it for every list-valued setting.
  Consequence for EP-6: `--set jobs.<name>.extra-dirs=/one` sets a one-element list, and there is no
  command-line spelling for a multi-element list; a job needing several directories states them in a
  file.

- Discovery (EP-5, 2026-08-05): **`SourceKind` cannot distinguish the two configuration files.**
  `settei-kdl` builds every source it reads as `FileSource "KDL v2"` — the payload names the
  *format*, not the path — so the user document and the repository document are identical by kind,
  and only the source *name*, which the caller supplies, tells them apart. Consequence: EP-5 owns a
  new `AgentConfigScope` (`UserScope` / `RepositoryScope`) whose renderer doubles as the source
  label, and `listAgentJobs` returns that rather than `SourceKind`. Consequence for EP-6: display
  `AgentConfigScope`; reaching for `SourceKind` would print `FileSource "KDL v2"` for both scopes.

- Discovery (EP-5, 2026-08-05): **`renderResolutionText` names a value's source but drops its file
  location; only `renderResolutionJson` carries path, line, and column.** The spans do reach the
  report — the JSON rendering proves it — so this is a renderer limitation rather than lost
  provenance. Consequence for EP-6, and it is load-bearing: `agent show` cannot satisfy
  improvement-request acceptance criterion 5, which requires each value's file position, by printing
  `renderResolutionText` alone. It must emit the JSON rendering or walk `reportNodes` and render
  `origin ^. #location` itself.

- Discovery (EP-5, 2026-08-05): the ceiling's security property is pinned by a test, not only by a
  comment. Mutating `loadAgentCeiling` to append the repository sources to the user sources — the
  exact one-line "consistency fix" its comment warns against — makes exactly one test fail,
  `A REPOSITORY FILE CANNOT RAISE THE CEILING`, while every other test in the workspace keeps
  passing. The mutation was applied, the failure observed, and the module restored. Consequence for
  EP-6: the executable must not introduce a second path to the ceiling; it calls `loadAgentCeiling`
  and `applyCeilingToJob` and adds no override of its own.

- Discovery: both providers can take the prompt on standard input, which removes the
  dash-leading-prompt hazard entirely, but Codex has a trap. `codex exec --help` states that
  if standard input is piped *and* a positional prompt is also given, standard input is
  appended as a `<stdin>` block. Consequence: EP-2 must never emit both, and EP-1's
  `AgentCommand` carries the prompt transport as an explicit choice so this is a type-level
  distinction rather than a convention.


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Add a third integration surface rather than extending `InteractiveLaunchRequest`
  or `ApiProvider`.
  Rationale: an inherited terminal, a parsed `Response`, and a captured, timed, byte-capped
  subprocess that mutates a working tree are three different contracts with three different
  result shapes. MasterPlan 3 already declined to extend `ApiProvider` for exactly this
  reason and the argument transfers unchanged. Merging them would force many callers to
  handle a result variant that cannot occur on their surface.
  Date: 2026-07-30

- Decision: Keep the core `baikai` package pure. `Baikai.Agent` contains vocabulary and the
  pure ceiling algebra only; the process runner, the configuration layer, and the executable
  live in a new `baikai-agent` package.
  Rationale: core currently depends on none of `process`, `directory`, or
  `optparse-applicative`, and `Baikai.Interactive` establishes the precedent that core owns
  shared vocabulary while spawning lives elsewhere. An executable in core also could not
  dispatch to the vendor renderers without core depending on its own provider packages.
  Date: 2026-07-30

- Decision: Ship exactly one new package, `baikai-agent`, containing the runner, the
  configuration layer, and an `executable baikai` stanza — rather than the improvement
  request's suggested pair of `baikai-agent` and `baikai-cli`.
  Rationale: the request's own naming was explicitly illustrative. A single package with a
  library and an executable stanza already gives the library/executable split, while the
  two-package version would move vendor flag mapping out of the vendor packages and diverge
  from how the interactive surface is organized. One new package is also one new entry in
  the release workflow instead of two.
  Date: 2026-07-30

- Decision: Vendor argument-vector rendering stays in `baikai-claude` and `baikai-openai`.
  Rationale: this mirrors `Baikai.Provider.Claude.Interactive` and
  `Baikai.Provider.OpenAI.Interactive` exactly, keeps vendor-specific command-line trivia
  out of both core and the new package, and means a future provider is added by writing one
  vendor module rather than by editing shared dispatch code.
  Date: 2026-07-30

- Decision: Build the configuration layer on `settei`, `settei-kdl`, `settei-env`, and
  `settei-optparse-applicative`, with KDL as the file format.
  Rationale: KDL is the established fleet convention and `settei-kdl` is a first-party,
  published, span-preserving reader. More importantly, `settei` already implements
  deterministic layer precedence, per-value provenance, and secret redaction that survives
  into structured errors, which are precisely improvement-request safety requirements 3 and
  4 and acceptance criterion 5. Hand-rolling them would re-implement a solved problem in the
  one area where a mistake is a security bug. TOML was rejected because its only advantage
  was matching Codex's own `config.toml`, which is a weak reason next to reusing a
  first-party provenance-aware library. Dhall was rejected because repository configuration
  is untrusted input here and a format whose parser resolves imports enlarges that attack
  surface. Recorded caveat: `settei` 0.2.0.0 self-describes as experimental, and this adds
  four dependencies to `baikai-agent`.
  Date: 2026-07-30

- Decision: With no user-level policy file present, the default ceiling permits read-only
  and edit-workspace capability but refuses full-access capability and refuses raw provider
  arguments.
  Rationale: this is the only default under which acceptance criteria 1 and 2 hold on a
  fresh machine, because the first consumer needs edit authority and would otherwise require
  an out-of-band setup step before any job could run. It still satisfies safety requirement
  1, since edit authority is confined to the working directory and explicit extra
  directories, and safety requirement 2, since sandbox-bypassing modes and arbitrary
  provider arguments — the two things that can widen authority unboundedly — remain
  opt-in at user scope only. Defaulting to read-only was rejected as making the zero-config
  path useless; trusting repository configuration by default was rejected as directly
  contradicting the request's statement that a checkout is untrusted input.
  Date: 2026-07-30

- Decision: A request that exceeds the ceiling is refused with a structured error naming the
  offending field, the requested value, the permitted maximum, and the scope that set the
  ceiling. It is never clamped to the permitted value.
  Rationale: silent clamping is how a job that believes it may edit ends up doing nothing
  and reporting success, and it is the mirror image of the silent downgrade this initiative
  is repairing in the interactive launchers. It also matches `settei`'s own principle that a
  malformed high-priority value fails resolution rather than falling back to a lower valid
  one.
  Date: 2026-07-30

- Decision: Repair the existing interactive launchers' silent safety downgrade inside this
  initiative, as EP-3.
  Rationale: this initiative adopts "unsupported policy fails visibly" as a contract.
  Shipping a new surface that honors it while leaving a published surface that violates it
  would mean the repository asserts one rule and implements two. Doing it here also lets the
  provider-package major version bumps ride in one coordinated release rather than two.
  Accepted cost: the two provider packages need major bumps because exported function
  signatures change.
  Date: 2026-07-30

- Decision: The new unattended safety vocabulary and the existing `InteractiveSafety` stay
  separate types that share only the refusal type.
  Rationale: the interactive vocabulary has no capability profile and no ceiling; the
  unattended vocabulary has no notion of an inherited terminal or of interactive approval
  prompts. Unifying them would require one of the two surfaces to carry fields that are
  meaningless on it. Sharing the refusal type is what makes the contract common; sharing the
  policy type would make the vocabulary dishonest.
  Date: 2026-07-30

- Decision: The runner consumes an already-rendered command value and never imports a vendor
  renderer.
  Rationale: this is what allows EP-2 and EP-4 to be implemented concurrently, keeps the
  runner testable with hand-written argument vectors and fake executables, and keeps a
  single dispatch point in the executable where the provider is selected.
  Date: 2026-07-30

- Decision: Six child plans in four waves, rather than the improvement request's implied four
  components.
  Rationale: the request names one contract, vendor renderers, a configuration layer, and a
  companion executable. Splitting the runner from the configuration layer is justified
  because they fail differently and are verified with entirely different fixtures, and
  adding the interactive repair is justified because it touches published behavior and must
  be independently revertible. Six plans keeps each within the specification's guidance of
  two to seven while leaving no plan doing the majority of the work.
  Date: 2026-07-30

- Decision: The built-in configuration layer is expressed as `settei` named default rules inside the
  job declaration, not as a synthetic `BuiltInSource` layer.
  Rationale: every job key contains the job name, so a built-in *source* would have to be rebuilt per
  name and could not be a constant, and resolving one job against a source built for another would
  emit unknown-key warnings for all of the other's keys. Named rules are name-independent, keep the
  declaration complete on its own, and report as `from default rule <name>` with a rationale, which
  is more informative than `built-in`. Precedence is unaffected: a default applies only when no
  source supplies the key. The five-layer contract this MasterPlan documents is unchanged; only how
  layer one is built changed.
  Date: 2026-08-05

- Decision: No acceptance step in this initiative invokes a live model. Pure renderer tests
  and fake-executable integration tests are the evidence.
  Rationale: MasterPlan 3 discovered that the `baikai-smoke` suite runs authenticated batch
  CLI completions whenever `claude` or `codex` is merely present on `PATH`, independent of
  API-key environment variables. Every plan's final validation command must therefore remove
  provider keys *and* filter the CLI directories from `PATH`, and no plan may use an
  authenticated invocation to check argument construction.
  Date: 2026-07-30


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)
