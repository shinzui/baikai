---
id: 56
slug: emit-unattended-agent-run-evidence
title: "Emit unattended agent-run evidence"
kind: exec-plan
created_at: 2026-08-05T20:23:58Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Emit unattended agent-run evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai has a surface for running a coding agent unattended: no terminal, no human watching, the
agent driving its own tool loop and changing files inside directories the caller explicitly
authorized. A caller describes the run with an `AgentRunRequest`, a vendor package renders it into
an argument vector, a runner spawns the process, and the caller gets back an `AgentRunResult`
carrying an exit code, whatever output was captured, and a duration. The `baikai agent run`
command wraps all of it for automation.

That surface produces **no observability of any kind**. It has no trace sink, no `Response`, no
`Usage`, no identifiers, and no dispatch through the provider registry — a search for `Trace`
across `baikai-agent/src` and `baikai-kit/src` returns nothing at all. An operator who runs a
coding agent unattended against a repository can show that a process started, that it exited with
some status, and how long it took. They cannot show which model ran, which reasoning effort was
applied, which agent session it corresponds to in the vendor's records, or what the request
actually was.

That is the gap that matters most for this whole initiative. The consuming use case behind IR-3 is
about attesting *sanctioned agent runs*, and an agent run is precisely the thing that currently
proves the least.

After this plan, an unattended run emits one `ModelCallEvidence` record just as a model call does:
the run and call identifiers, the executable that ran and its version, a digest of the exact
argument vector, the requested model and reasoning effort together with what the CLI flags
actually expressed, the session identifier the tool reported, the token usage it reported, the
process outcome, and an honest strength that a zero exit status can never raise. The
`baikai agent run` command can write it to a file, so an automation job produces a reviewable
record as a side effect of running.

You can see it working with no credentials, because the tests drive fake executables:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-agent
```

and by running the real command against a fake executable on the command line, which the Concrete
Steps section walks through.


## Progress

- [x] Add `AgentRunOutcome` to `baikai/src/Baikai/Agent.hs` — evidence beside the outcome rather
      than a field on `AgentRunResult`, for the reason in the Decision Log. (2026-08-05)
- [x] Build the thinking translation for both vendor agent renderers and return it alongside the
      command. (2026-08-05)
- [x] Capture executable identity, resolved path, and version in the runner, importing plan 55's
      cached probe rather than writing a second one. (2026-08-05)
- [x] Build the request digests over an envelope carrying both the argument vector and the prompt,
      and prove the prompt is absent from the configuration envelope under both transports.
      (2026-08-05)
- [x] Parse the structured result each tool writes, best-effort, for the session identifier, the
      model, and the usage. (2026-08-05)
- [x] Assemble the evidence in `baikai-agent/src/Baikai/Agent/Run.hs` and derive the strength.
      (2026-08-05)
- [x] Add `--evidence-file` and `--run-id` to the `baikai agent run` command, writing atomically.
      (2026-08-05)
- [x] Write fixture tests driving fake executables across success, silence, non-zero exit, timeout,
      inherited output, a run that never started, and the opt-out. (2026-08-05)
- [x] Document both options and what the record proves in
      `docs/user/unattended-agent-runs.md`. (2026-08-05)
- [x] Add `CHANGELOG.md` entries under the existing `[Unreleased]` heading. (2026-08-05)
- [x] Drive the real `baikai agent run` against a fake executable and read the record back.
      (2026-08-05)


## Surprises & Discoveries

### Evidence could not live on `AgentRunResult`, because a timed-out run has none

This plan's Interfaces section specified `AgentRunResult` gaining an `evidence` field and
`runAgentCommand` keeping its `Either AgentRunFailure AgentRunResult` return. Those two are
incompatible with the plan's own acceptance criterion that a run terminated by its timeout produces
`status = CallAborted`: `runAgentCommand` reports a timeout as `Left (RunTimedOut …)`, so evidence
hanging off the `Right` is unreachable in exactly that case.

A timed-out run is the one an operator most needs a record of — it started, consumed tokens, and
may have changed the working tree before its process group was killed. The Decision Log records the
resolution. The plan's Interfaces section has been corrected below.

### Neither vendor renderer asks its tool for structured output

`claudeAgentCommand` renders no `--output-format json` and `codexAgentCommand` renders no `--json`.
That is deliberate — the agent's output goes to an operator's terminal under the default `inherit`
mode, and turning it into a JSON stream would change what they see — but it means the tool-reported
fields this plan set out to capture are **not available by default**, even with output captured.

The parse is therefore best-effort: it reads a structured result if the operator configured one
through the job's `provider-args`, and reports honest silence otherwise. Combined with `inherit`
capturing nothing at all, an operator who wants a strength above `EvidenceRequestedOnly` has to
arrange two things, neither of which is a default. That is now stated in the runner's Haddock and in
`docs/user/unattended-agent-runs.md` rather than left to be discovered from an empty record.

### The configuration digest is degenerate on every subprocess transport

`Baikai.Evidence.configurationProjection` is an allow-list over *named* request fields, and an
argument vector has none it recognises, so an agent-run configuration envelope projects to `{}` and
every agent run shares one `request_configuration` value. Plan 55 has the same property on the two
CLI completion providers, where an argv array projects to `null`.

This is the allow-list failing in the safe direction and it satisfies this plan's acceptance
criterion — two runs differing only in prompt produce identical configuration digests — but a
digest that is constant across every run of every job is close to useless as evidence. The envelope
is built prompt-free anyway, so that if the projection ever learns about argument vectors it cannot
start leaking the prompt on the transport that puts it there. Plan 57 is the first plan positioned
to see every transport at once and should decide whether to teach the projection about argv.

### `requested_model` cannot say "none" on this surface

An `AgentRunRequest` may leave `modelId` unset, meaning "whatever the tool defaults to", and no
`--model` flag is rendered at all. `ModelCallEvidence.requestedModel` is plain `Text` with no way to
express absence, so that case records the empty string. It is documented in `requestedModelOf` and
in the record's own field documentation rather than papered over, and it is EP-1 vocabulary
territory rather than this plan's to change. Plan 57 may want a `Maybe` there; it would be a schema
break.

### A run's own timing bracket is wider than its `duration`

`spawn` takes its own start timestamp for `AgentRunResult.duration`, and this plan's evidence
timestamps bracket the whole call including process creation and the precondition checks that
precede it. The two therefore differ by a small amount, deliberately: the evidence window is "when
the runner began" to "when it finished", which is the honest span for a record about a boundary
crossing.

### Verified end to end against the real command

Not a test — the real `baikai agent run` binary, a KDL job file, and a fake executable:

```bash
cabal run -v0 baikai-agent:exe:baikai -- agent run demo \
  --config repo.kdl --prompt 'reconcile the lexical surface' \
  --run-id demo-run-1 --evidence-file evidence.json
```

```json
{
  "run_id": "demo-run-1",
  "call_id": "019fd4b33d947073abbaa96d00000000",
  "status": "succeeded",
  "strength": "model_observed",
  "requested_model": "",
  "observed_model": { "observed": "claude-opus-5" },
  "response_id": { "observed": "sess-abc123" },
  "thinking": {
    "requested": "minimal", "mode": "flag", "effort_text": "low",
    "wire_field": "--effort",
    "adjustments": [{ "kind": "effort_clamped", "requested": "minimal", "wire": "low" }]
  },
  "endpoint": {
    "api": "agent_run", "transport": "agent_run", "provider": "claude",
    "endpoint": "…/agentdemo/bin/claude",
    "implementation_version": "9.9.9 (Fake Claude Code)"
  }
}
```

The `implementation_version` is the fake's own `--version` line, read through the cached probe. The
`thinking` block is the whole point of the record: the job asked for `minimal`, the command line
said `--effort low`, and nothing but this field records that the two are not the same request.


## Decision Log

- Decision: Build a second evidence emission path for the agent surface rather than routing agent
  runs through the provider registry and the trace layer.
  Rationale: The two surfaces are architecturally disjoint by design. `Baikai.Agent`'s own module
  documentation states that it "deliberately does not implement process spawning" and returns a
  process result rather than a `Response`, because "the interesting output is the changed working
  tree, not the text". Forcing an agent run through `ApiProvider` would mean inventing a `Response`
  for something that has no assistant message, and forcing it through `Baikai.Trace` would mean
  wrapping a batch process in a streaming event algebra it does not fit. The evidence *record* is
  shared — that is the whole point of `ModelCallEvidence` being one type — but the path that
  produces it is not.
  Date: 2026-08-05

- Decision: The evidence travels back from the runner, and writing it anywhere is the caller's
  choice.
  Rationale: The agent surface has no sink abstraction and this plan should not invent one. A
  runner that returns the evidence lets `baikai agent run` write it to a file, lets a library
  caller do whatever it likes, and keeps the runner a pure-ish function of the request. Adding a
  trace-sink concept to `baikai-agent` would duplicate `Baikai.Trace.Sink` for no benefit.
  Date: 2026-08-05

- Decision: **Revised.** The evidence travels on a new `AgentRunOutcome` beside the run's outcome,
  not on `AgentRunResult`.
  Rationale: This plan originally specified an `evidence` field on `AgentRunResult` and an
  unchanged `IO (Either AgentRunFailure AgentRunResult)` return. Those two contradict this plan's
  own acceptance criterion that a timed-out run records `CallAborted`, because `runAgentCommand`
  reports a timeout as `Left (RunTimedOut …)` — so a record on the `Right` is unreachable in the
  one failure case that most deserves one. A run killed by its timeout started, ran, consumed
  tokens, and may have changed the working tree.
  The alternatives were worse. Making a timeout return `Right` would break the runner's documented
  contract that a timeout is a failure, and break the existing test that asserts it. Threading the
  evidence through `AgentRunFailure` would put it on a type whose other four constructors describe
  runs that never started. A record with two fields says exactly what happened and where the
  evidence for it is, and it leaves `AgentRunResult` the process result its own documentation says
  it is rather than a type with a field that is `Nothing` precisely when it is most wanted.
  Date: 2026-08-05

- Decision: The commitment digest covers an object carrying both the argument vector and the
  prompt; the configuration digest covers the vector with the prompt removed by value.
  Rationale: Both vendor renderers select `PromptOnStdin`, so the prompt appears nowhere in the
  argument vector. A commitment over the vector alone — which is what the two CLI completion
  providers do, because there the prompt genuinely is in the vector — would give two runs with
  identical flags and completely different instructions the same digest, silently defeating the one
  thing that digest exists to do. Removing the prompt by value rather than by position means the
  configuration envelope is prompt-free under `PromptAsArgument` too, without depending on the
  prompt staying the last element.
  Date: 2026-08-05

- Decision: Parse the tool's structured output best-effort, and do not make the renderers request
  it.
  Rationale: Neither vendor renderer emits `--output-format json` or `--json`, and adding one would
  change what an operator watching an `inherit`-mode run sees — a behaviour change well outside
  this plan and contrary to the design masterplan 8 chose. So the parse reads a structured result
  when the operator configured one through `provider-args` and records honest silence otherwise.
  The alternative, inferring the session identifier or model from anything else available, would be
  reporting the request as an observation.
  Date: 2026-08-05

- Decision: `EndpointIdentity.api` records the string `agent_run`.
  Rationale: The field is documented as "the wire protocol tag, rendered from `Baikai.Api.Api`", and
  an unattended run speaks no wire protocol: it writes to a pipe. Leaving it empty would read as
  "unknown" when the truth is "not applicable", and borrowing an `Api` tag would claim an HTTP shape
  that was never used. It duplicates `transport` for this surface, which is the honest outcome.
  Date: 2026-08-05

- Decision: The command requests evidence exactly when `--evidence-file` or `--run-id` is supplied,
  and the job's own name is the run identifier when only a destination is given.
  Rationale: An operator who supplies neither must keep the behaviour and the cost they had before
  evidence existed, which is what the runner's opt-in gate is for; making the CLI always opt in
  would defeat it. Defaulting the run identifier to the job name rather than the empty string means
  a consumer never has to special-case a blank field, and baikai treats the value as opaque text
  either way.
  Date: 2026-08-05

- Decision: A failed evidence-file write is reported on standard error and never changes the exit
  code.
  Rationale: The agent's own exit code passes through unchanged — that is the surface's central
  contract, and the motivating consumer's script ends its launch with `|| die`. Turning a
  successful run into a failure because a log file could not be written would be the worse surprise,
  and an operator who cares can see the message. The run itself already happened; the record is
  about it, not part of it.
  Date: 2026-08-05


## Outcomes & Retrospective

An unattended coding-agent run now produces a model-call evidence record, on a surface that before
this plan had no observability of any kind — no trace sink, no `Response`, no usage, no
identifiers. `cabal build all` is clean with no new warnings and every test suite passes.

What an operator can do that they could not before:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-agent --test-options='--pattern "unattended run evidence"'
```

selects nine cases, and

```bash
baikai agent run <job> --prompt-stdin --run-id <outer-run> --evidence-file <path>
```

writes one JSON object naming the executable that ran, its own reported version, the digests over
the request, what the reasoning-effort request became on the command line, whatever the tool
reported about itself, and an honest strength. The Surprises section above has a real record from
that command driving a fake executable.

Three things are worth carrying forward.

The plan's own Interfaces section was internally inconsistent, and finding out required writing the
timeout test. `AgentRunResult` cannot hold the evidence for a run that produces no
`AgentRunResult`. The fix was small but it is the kind of thing that only surfaces when the
acceptance criterion is written as a test rather than as a sentence.

The most valuable assertion in this plan is the process count, not a field. `A RUN THAT ASKED FOR
NO EVIDENCE SPAWNS EXACTLY ONE PROCESS` is what catches a `--version` probe firing on the opt-out
path, and an assertion on the absent `evidence` field would pass whether or not the probe ran. The
contrast half — that opting in spawns more than one — is what stops that test passing because the
fake was never invoked at all.

And the honest answer turned out to be smaller than the plan hoped. Neither vendor renderer asks
its tool for structured output, so the tool-reported fields this plan set out to capture are
unavailable unless an operator arranges two non-default things. Writing that down in the runner's
Haddock and in the user guide is more useful than a record that quietly reads `unobserved` and
leaves someone wondering what they did wrong.

What remains for plan 57: the configuration digest is degenerate on all three subprocess transports
and 57 is the first plan positioned to decide whether `configurationProjection` should learn about
argument vectors; `requested_model` has no way to say "no model was requested"; and this surface has
no strict-mode gate, since `runAgentCommand` takes an `EvidenceRequest` whose strictness it
currently ignores.


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. This plan
changes `baikai/` (the `Baikai.Agent` vocabulary), `baikai-agent/` (the runner, the configuration
layer, and the `baikai` executable), and the two vendor packages' agent renderers in
`baikai-claude/` and `baikai-openai/`. From the repository root, `cabal build all` compiles
everything and `cabal test baikai-agent` runs this surface's tests, which live in
`baikai-agent/test/` in the modules `CliTests` and `ConfigTests`.

Record fields in this codebase never carry the record's name as a prefix — a field is `exitCode`,
not `resultExitCode` — and `DuplicateRecordFields` is on. In fact `Baikai.Agent` relies on that:
its module header notes that its field selectors "deliberately share names with
`Baikai.Interactive`", which is why `Baikai.Agent` is **not** re-exported from the umbrella
`Baikai` module and must be imported directly. Field access goes through `generic-lens` overloaded
labels. The language is GHC2024, every `deriving` clause must name its strategy explicitly, and
every module needs an explicit export list.

### The unattended agent surface, file by file

This surface was built by
[docs/masterplans/8](../masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md);
read that MasterPlan if you want the design rationale, though everything needed to implement this
plan is below.

`baikai/src/Baikai/Agent.hs` in the core package owns the vocabulary and a pure policy algebra,
and deliberately spawns no process and renders no flags. The types that matter here:

`AgentRunRequest` describes the run: which `AgentProvider` (`AgentClaude` or `AgentCodex`), the
prompt, an optional `modelId` override, an optional `effort :: Maybe ThinkingLevel`, a required
`workingDir`, extra authorized directories, the requested `AgentSafety` policy, an optional
timeout, an output mode, an output limit, and the names of environment variables the job declares
it needs.

`AgentCommand` is the boundary value between a vendor renderer and the runner:

```haskell
data AgentCommand = AgentCommand
  { executable :: !FilePath,
    arguments :: ![String],
    promptTransport :: !AgentPromptTransport,
    promptText :: !Text
  }
```

`AgentPromptTransport` is `PromptOnStdin` or `PromptAsArgument`, and the type's documentation
warns that honoring it exactly matters: `codex exec` treats a piped stdin *and* a positional prompt
as two separate inputs, so emitting both silently corrupts the instruction. This matters for the
digests, because the prompt is in the argument vector for one transport and not the other.

`AgentRunResult` is what a finished run returns today:

```haskell
data AgentRunResult = AgentRunResult
  { provider :: !AgentProvider,
    exitCode :: !ExitCode,
    stdout :: !AgentCapturedOutput,
    stderr :: !AgentCapturedOutput,
    duration :: !NominalDiffTime
  }
```

`AgentCapturedOutput` is a three-state type — `OutputNotCaptured`, `OutputCaptured bytes`, or
`OutputTruncated bytes` — because under the `InheritOutput` mode the bytes went to the parent's
terminal and none exist to report, which an empty `ByteString` could not distinguish from a
command that printed nothing. That three-way distinction matters for this plan: **evidence parsed
from captured output is only available when output was captured at all.** Under `InheritOutput`
there is nothing to parse and every tool-reported field must be `Unobserved`.

`baikai-agent/src/Baikai/Agent/Run.hs` is the runner. `runAgentCommand` takes an
`AgentRunRequest` and an already-rendered `AgentCommand`, checks the declared environment variables
and the working directory, spawns the process, forks threads to drain the pipes, honors the
timeout, and returns either an `AgentRunFailure` or an `AgentRunResult`. It imports no vendor
renderer, so it can be exercised entirely with hand-written argument vectors — which is exactly
what its tests do and what this plan's tests will do.

`baikai-claude/src/Baikai/Provider/Claude/Agent.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs` are the pure vendor renderers. Each maps the
neutral request onto its tool's flags. The Claude one carries the same effort collapse the CLI
completion provider does:

```haskell
claudeEffortValue :: ThinkingLevel -> Text
claudeEffortValue ThinkingMinimal = "low"
claudeEffortValue lvl = renderThinkingLevel lvl
```

and the Codex one sends `-c model_reasoning_effort=<level>` with all six levels verbatim.

`baikai-agent/src/Baikai/Agent/Cli.hs` is the whole command-line surface — `agent run`,
`agent show`, and `agent list` — deliberately kept in a library module rather than in `app/Main.hs`
so the test suite can reach it without spawning the built binary. It uses
`optparse-applicative`, and it already has a `--json` switch, which is the pattern to follow for
the new output option.

### Terms used in this plan

An **unattended run** is a coding-agent invocation with no terminal and no human present, which
drives its own tool loop and may modify files. The **argument vector** is the list of strings
passed to the child process, excluding the program name. **Evidence strength** is the
`EvidenceStrength` value from `Baikai.Evidence`, an ordered enumeration of how much a record
proves. A **fake executable** is a small shell script written into a temporary directory by a test
and invoked in place of the real tool; `baikai-agent`'s existing tests already use this technique,
so read `baikai-agent/test/CliTests.hs` before writing new ones.

### What this plan depends on

Hard dependency:
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md), for
`ModelCallEvidence`, `Observed`, `ThinkingTranslation`, `ThinkingMode`, `ThinkingAdjustment`,
`EndpointIdentity`, `TransportKind`, `CallStatus`, `EvidenceStrength`, `EvidenceRequest`,
`newCallId`, `commitmentDigest`, and `configurationDigest`.

This plan deliberately does **not** depend on
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md). The agent
surface touches neither `ApiProvider` nor `TerminalPayload` nor `Baikai.Trace`, so plan 52's
channel is irrelevant here and this plan can run in parallel with it as soon as plan 51 is done.

Soft dependency:
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) parses the same two
tools' structured output and probes the same two executables for their versions. Those helpers
belong in `baikai/src/Baikai/Provider/Cli/Internal.hs`. If plan 55 has already landed, import its
`ExecutableIdentity`, `executableIdentity`, `CodexRunReport`, `parseCodexJsonlStream`,
`ClaudeCliReport`, and `decodeClaudeCliResult` rather than writing your own. If this plan lands
first, write them there in the shapes plan 55's Interfaces section specifies, so that plan 55 can
import them unchanged. Whichever lands second is responsible for consolidating; two copies of a
coding-agent output parser will diverge the first time a vendor changes its schema.

### ADR context

This repository has no `docs/adr/` directory and `mori.dhall` declares no ADR bundle, so there is
no local ADR convention to follow and no relevant record to read. Record decisions in this plan's
Decision Log;
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) establishes
`docs/adr/` and promotes the durable ones at the end of the initiative.


## Plan of Work

Three milestones: widen the result type and the renderers, capture what the run reveals, then
surface it through the command.

### Milestone 1: widen the vocabulary and the renderers

At the end of this milestone `AgentRunResult` can carry evidence and both vendor renderers describe
what they did with the caller's reasoning-effort request. Nothing is populated yet and the whole
repository still compiles.

In `baikai/src/Baikai/Agent.hs`, add one field to `AgentRunResult`:

```haskell
    -- | Evidence for this run, when the runner built any. This is the
    -- agent surface's equivalent of the evidence a model call attaches
    -- to its trace event; there is no sink here, so the runner returns
    -- it and the caller decides where it goes.
    evidence :: !(Maybe ModelCallEvidence)
```

and set it to `Nothing` in the `agentRunResult` smart constructor. Add `evidence` to the module's
export list beside the other `AgentRunResult` selectors. Note that `Baikai.Agent` is not
re-exported from the umbrella module, so this adds nothing to `import Baikai`.

Then change each vendor renderer to return the thinking translation alongside the command. The
renderers are pure functions returning `Either AgentRenderError AgentCommand`; widen them to
return the pair:

```haskell
claudeAgentCommand ::
  ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError (AgentCommand, ThinkingTranslation)

codexAgentCommand ::
  CodexAgentConfig -> AgentRunRequest -> Either AgentRenderError (AgentCommand, ThinkingTranslation)
```

Fill them the way
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) fills the completion
providers' translations, because these are the same two flags: for Claude,
`mode = ThinkingModeFlag`, `wireField = Just "--effort"`, `effortText` set to the rendered value,
and an `EffortClamped ThinkingMinimal "low"` adjustment when the caller asked for `ThinkingMinimal`;
for Codex, `mode = ThinkingModeFlag`, `wireField = Just "model_reasoning_effort"`, `effortText`
set to the canonical name, and no adjustment. When the request's `effort` is `Nothing`, return
`noThinkingRequested` — the tool then uses its own default, which is a different fact from the
caller having asked for something the tool weakened.

The renderer changes break `baikai-agent/src/Baikai/Agent/Cli.hs`'s `renderJobCommand` and any
test that calls a renderer directly. Fix them by threading the pair through; do not discard the
translation at the first call site, because Milestone 2 needs it.

Add renderer tests asserting the translation for both providers across all six levels and for the
`Nothing` case — fourteen cases in total. Put them wherever the existing renderer tests live; a
grep for `claudeAgentCommand` in the test directories finds them.

### Milestone 2: capture what the run reveals

At the end of this milestone `runAgentCommand` returns a populated evidence record, proved by
tests against fake executables.

Change `runAgentCommand`'s signature to take the evidence inputs it cannot derive on its own:

```haskell
runAgentCommand ::
  -- | The caller's evidence request: run id, strictness, attempt.
  -- 'Nothing' means the caller wants no evidence, and the runner then
  -- builds none: no digest is computed, no call identifier is
  -- generated, no executable version is probed, and the returned
  -- 'AgentRunResult' carries 'Nothing' in its evidence field. A run
  -- that opts out must cost exactly what it cost before this plan.
  Maybe EvidenceRequest ->
  -- | What the vendor renderer said it did with the reasoning-effort
  -- request. The runner cannot derive this: it never sees the vendor
  -- renderer and is deliberately independent of it.
  ThinkingTranslation ->
  AgentRunRequest ->
  AgentCommand ->
  IO (Either AgentRunFailure AgentRunResult)
```

When the first argument is `Nothing`, skip everything below and return the `AgentRunResult` the
runner produces today. Do the check once, before the process is spawned, so the two costly pieces
— hashing the argument vector and prompt, and spawning a `--version` probe of the tool — are
never reached. On this surface the probe matters more than elsewhere: an unattended run may be a
single short invocation, and doubling its process count to describe a tool it is about to run
anyway would be plainly wasteful.

When it is `Just`, build the evidence from four sources.

*What Baikai knows by construction.* The requested model comes from the request's `modelId`, or
from the empty string when the caller left the tool's default in place — and in that case the
translation and the evidence must be clear that no model was requested rather than that the empty
string was. The endpoint identity gets `transport = TransportAgentRun`, `provider` set to the
rendered agent provider name, `endpoint` set to the resolved executable path, and
`implementationVersion` set to the tool's probed version. Compute the two digests over the
argument vector rendered as a JSON array of strings.

The prompt is the subtlety here. Under `PromptAsArgument` the prompt is the last element of the
vector; under `PromptOnStdin` it is not in the vector at all but is still part of the request. The
commitment digest must cover the prompt in both cases, so compute it over an object carrying both
the argument vector and the prompt text rather than over the vector alone — otherwise two runs
with identical flags and different prompts would produce the same commitment under
`PromptOnStdin`, which would silently defeat the whole purpose. The configuration digest must
exclude the prompt in both cases. Test both transports explicitly; this is the single most likely
place for a subtle mistake in this plan.

*What the executable is.* Call `executableIdentity` from
`baikai/src/Baikai/Provider/Cli/Internal.hs` — written by this plan or by
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md), whichever lands
first — to resolve the path and probe the version, cached per process. A failed probe records the
version as absent and must never fail the run.

*What the run did.* Map the outcome onto `CallStatus`: a completed process is `CallSucceeded` when
it exited zero and `CallFailed` when it did not, and a run terminated by the timeout is
`CallAborted`. A run that never started at all returns `Left AgentRunFailure` and produces no
evidence, because nothing happened to describe. Set `startedAt`, `endedAt`, and `latencyMs` from
the runner's existing timing.

Do not read anything into the exit code beyond the status. A coding agent that fails its task and
exits 1 has still run, which is why `AgentRunResult` treats a non-zero exit as a normal result —
and a zero exit says nothing about which model served the run.

*What the tool reported.* When the output mode captured stdout, parse it with the shared helpers
for the session or thread identifier, the reported model, and the usage. Under `InheritOutput`
there is no captured output, so every one of those fields stays `Unobserved` and the strength
stays at `EvidenceRequestedOnly`. Say so in the runner's Haddock: an operator who wants strong
evidence from an unattended run must capture output, and that is a real constraint they need to
know about rather than discover.

Set the strength through `subprocessStrength` from the shared module, which returns
`EvidenceModelObserved` when both an identifier and a model were reported, `EvidenceCorrelated`
when only an identifier was, and `EvidenceRequestedOnly` otherwise — and which takes no exit code,
by design.

The tests go in a new module in `baikai-agent/test/`, wired into that suite's `other-modules` in
`baikai-agent/baikai-agent.cabal`. Follow the fake-executable pattern already in
`baikai-agent/test/CliTests.hs`. Cover: a fake executable that exits zero and prints a result
carrying a session identifier and usage, asserting `EvidenceModelObserved` or
`EvidenceCorrelated` as the fixture warrants; a fake executable that exits zero and prints a
result carrying **neither**, asserting `EvidenceRequestedOnly`; a fake executable that exits 1,
asserting `status = CallFailed` and that the strength is unaffected by the exit code; a run that
exceeds its timeout, asserting `status = CallAborted`; and a run under `InheritOutput`, asserting
every tool-reported field is `Unobserved`.

Add a digest test for each prompt transport: two runs differing only in prompt text must produce
different commitment digests and identical configuration digests, under both `PromptOnStdin` and
`PromptAsArgument`.

Then add the opt-out test: a run with `Nothing` for the evidence request returns an
`AgentRunResult` whose `evidence` field is `Nothing`, and spawns exactly one process. Assert the
process count, not just the absent field — a fake executable that appends a line to a file each
time it is invoked makes this checkable, and it is the only way to catch a version probe that fires
on a path that should never reach it.

### Milestone 3: surface it through the command

At the end of this milestone `baikai agent run` can write the evidence to a file, and an
automation job gets a reviewable record for free.

In `baikai-agent/src/Baikai/Agent/Cli.hs`, add an option to the `agent run` parser:

```text
--evidence-file PATH    Write the run's evidence record to PATH as one JSON object.
```

Follow the existing `jsonSwitch` and `userConfigOption` parsers for style. Write the file only on a
run that produced evidence — that is, one that actually started — and write it whether the run
succeeded or failed, since a failed run's evidence is exactly what an operator needs. Write it
atomically, to a temporary file in the same directory followed by a rename, so a reader polling the
path never sees a half-written record.

Also add the run identifier as an option, since an unattended job is precisely the case where a
caller has an outer run to correlate against:

```text
--run-id TEXT           Caller-supplied identifier for the logical run this invocation belongs to.
```

Thread it into the `EvidenceRequest` the CLI hands to `runAgentCommand`. Leave strictness alone
here: [docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) adds the
strict-mode flag once the refusal semantics exist.

Document both options in `docs/user/unattended-agent-runs.md`, the guide
[docs/masterplans/8](../masterplans/8-unattended-coding-agent-runs-through-a-configurable-cli.md)
created, in the same style as the options already documented there. Explain plainly what the
evidence proves and what it does not — in particular that it is a record of what Baikai requested
and observed at its own boundary, not a claim about what happened inside the provider, and not
signed.

Add CLI tests asserting that `--evidence-file` writes a schema-valid record and that a run without
the flag writes nothing.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm the prerequisite plan is complete and the tree is green:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai --test-options='--pattern Evidence'
cabal test baikai-agent
```

Confirm for yourself that this surface has no observability today, because it is the premise of
the whole plan:

```bash
rg -n 'Trace|TraceSink|CallLog' baikai-agent/src baikai-kit/src
```

Expect no output.

Read these files completely before editing, in this order:
`baikai/src/Baikai/Agent.hs` (the vocabulary),
`baikai-agent/src/Baikai/Agent/Run.hs` (the runner),
`baikai-agent/src/Baikai/Agent/Cli.hs` (the command surface), and
`baikai-agent/test/CliTests.hs` (the fake-executable pattern you will reuse).

Check whether [docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) has
already landed, because that decides whether you write the shared helpers or import them:

```bash
rg -n 'executableIdentity|CodexRunReport|ClaudeCliReport' baikai/src/Baikai/Provider/Cli/Internal.hs
```

Work through the three milestones, committing after each with all three trailers:

```text
Return model-call evidence from an unattended agent run

Widen AgentRunResult with an evidence slot, have both vendor renderers
describe what they did with the reasoning-effort request, and build the
evidence in the runner from the executable identity, the argument
vector digests, and whatever the tool reported about itself.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/56-emit-unattended-agent-run-evidence.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

After Milestone 3, drive the real command against a fake executable — no credentials, no quota:

```bash
cd /tmp
mkdir -p fake-bin
cat > fake-bin/claude <<'SH'
#!/bin/sh
echo '{"type":"result","result":"ok","is_error":false,"session_id":"sess-abc123"}'
SH
chmod +x fake-bin/claude
```

Then run the command with that directory first on `PATH`, pointing at whatever job definition the
`agent run` surface expects — `cabal run baikai -- agent run --help` shows the current arguments:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
PATH=/tmp/fake-bin:$PATH cabal run baikai -- agent run \
  --run-id demo-run-1 \
  --evidence-file /tmp/agent-evidence.json \
  <the arguments agent run requires>
jq '{runId, callId, status, strength, requestedModel, responseId, thinking}' /tmp/agent-evidence.json
```

Expect a single JSON object whose `responseId` is `{"observed":"sess-abc123"}`, whose `strength`
is `EvidenceCorrelated`, and whose `status` is `CallSucceeded`.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and `cabal test all` passes.

An unattended run driven by a fake executable that reports a session identifier produces evidence
whose `responseId` is `Observed` carrying that identifier and whose `strength` is at least
`EvidenceCorrelated`. Before this plan, an agent run produced no record of any kind.

An unattended run driven by a fake executable that exits **zero** while reporting neither an
identifier nor a model produces `strength = EvidenceRequestedOnly`. This is IR-3's rule that a
successful process exit does not upgrade evidence, and on this surface it is the rule most likely
to be violated by accident, because almost every agent run exits zero.

A run that exits non-zero produces `status = CallFailed` with a strength determined only by what
the tool reported, unaffected by the exit code. A run terminated by its timeout produces
`status = CallAborted`. A run that never started produces `Left AgentRunFailure` and no evidence.

A run under `InheritOutput` produces evidence in which every tool-reported field is `Unobserved`,
and the runner's documentation says why.

A run with no evidence request returns `evidence = Nothing` and spawns exactly one process,
proving no version probe fired on the opt-out path. An existing caller of `runAgentCommand` that
passes `Nothing` sees behaviour identical to before this plan.

Two runs differing only in their prompt produce different `requestCommitment` values and identical
`requestConfiguration` values, under **both** `PromptOnStdin` and `PromptAsArgument`. This is the
subtlest assertion in the plan and the one most worth writing first.

Both vendor renderers produce a `ThinkingTranslation` for all six levels plus the no-effort case,
and the Claude renderer records `EffortClamped ThinkingMinimal "low"` where the tool's `--effort`
flag has no `minimal`.

`baikai agent run --evidence-file PATH` writes exactly one JSON object to `PATH` that parses back
into a `ModelCallEvidence`, and a run without the flag writes nothing.

Nothing regressed: the existing `baikai-agent` test suite passes, and every assertion this plan
changes — the renderer signatures break their direct callers — is recorded in the Decision Log
with its reason.


## Idempotence and Recovery

Every code step is safe to repeat; `cabal build` and `cabal test` have no side effects, and the
tests write their fake executables into a temporary directory they create and remove.

The manual verification writes to `/tmp`; clear it between runs so a stale file cannot make a
broken build look correct:

```bash
rm -rf /tmp/fake-bin /tmp/agent-evidence.json
```

The `--evidence-file` write is the only step in this plan that touches a path a user chose. Write
atomically — temporary file in the same directory, then rename — so an interrupted run cannot
leave a truncated record that a reader would parse as complete. Never append; each run writes one
complete object, and a caller who wants a log of many runs should point each run at its own path.

Widening `runAgentCommand`'s signature breaks its callers in `baikai-agent/src/Baikai/Agent/Cli.hs`
and in the existing tests. The compiler finds them all, so the risk is scope creep rather than
silent breakage. Resist restructuring the runner's process handling while you are in there: it
contains careful timeout, process-group termination, and pipe-draining logic under a CPP guard for
POSIX signals, and none of it is this plan's business.

If the version probe added in Milestone 2 proves slow or flaky in the test environment, make it
opt-out through the existing agent configuration rather than removing it, and record that in the
Decision Log — the executable version is real evidence and dropping it silently would defeat the
plan.


## Interfaces and Dependencies

New dependencies: `baikai-agent`'s library gained `aeson` (the two request envelopes) and
`streamly-core` (the codex event-stream parser's input type), and its test suite gained `aeson`.
`directory`, `process`, `filepath`, and `optparse-applicative` were already declared.
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) landed first and
already added `directory`, `filepath`, and `process` to `baikai`'s library stanza for the shared
executable probe, so nothing was needed there.

The surface that must exist when this plan is complete:

In `baikai/src/Baikai/Agent.hs`, a new type beside `AgentRunResult`, which is
itself unchanged. See the Decision Log for why the evidence is a sibling of the
outcome rather than a field on the result:

```haskell
data AgentRunOutcome = AgentRunOutcome
  { outcome :: !(Either AgentRunFailure AgentRunResult),
    evidence :: !(Maybe ModelCallEvidence)
  }

agentRunOutcome :: Either AgentRunFailure AgentRunResult -> AgentRunOutcome
```

In `baikai-agent/src/Baikai/Agent/Run.hs`:

```haskell
runAgentCommand ::
  Maybe EvidenceRequest ->
  ThinkingTranslation ->
  AgentRunRequest ->
  AgentCommand ->
  IO AgentRunOutcome

-- The argument vector and the prompt, for the commitment digest.
agentRequestEnvelope :: AgentCommand -> Value

-- The same with the prompt removed, for the configuration digest.
agentConfigurationEnvelope :: AgentCommand -> Value
```

In `baikai-claude/src/Baikai/Provider/Claude/Agent.hs`:

```haskell
claudeAgentCommand ::
  ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError (AgentCommand, ThinkingTranslation)

claudeAgentThinking :: AgentRunRequest -> ThinkingTranslation
```

In `baikai-openai/src/Baikai/Provider/OpenAI/Agent.hs`:

```haskell
codexAgentCommand ::
  CodexAgentConfig -> AgentRunRequest -> Either AgentRenderError (AgentCommand, ThinkingTranslation)

codexAgentThinking :: AgentRunRequest -> ThinkingTranslation
```

`Baikai.Agent.Cli.renderJobCommand` returns the same pair, since it is the
dispatch point in front of both.

In `baikai/src/Baikai/Provider/Cli/Internal.hs`, shared with
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) — written by
whichever plan lands first, in exactly this shape, and imported unchanged by the other:

```haskell
data ExecutableIdentity = ExecutableIdentity
  { configured :: !Text,
    resolvedPath :: !(Maybe Text),
    version :: !(Maybe Text)
  }

executableIdentity :: FilePath -> IO ExecutableIdentity

subprocessStrength :: Observed Text -> Observed Text -> EvidenceStrength
```

`baikai-agent/src/Baikai/Agent/Cli.hs` gains `--evidence-file` and `--run-id` options on the
`agent run` command, and `baikai-agent/baikai-agent.cabal` gains the new test module in the test
suite's `other-modules`.

The `ModelCallEvidence`, `ThinkingTranslation`, and `EvidenceStrength` types are owned by
`Baikai.Evidence` in the core package and must not be extended here. This surface is the most
likely to want an agent-specific field — a changed-file count, say — and it must not get one:
the evidence record's value is that one type describes every transport, and a Shikigami consumer
reading a run's records must not have to branch on which surface produced them. If a field is
genuinely needed, that is a change to
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) and to the
MasterPlan's Integration Points section, and both must be updated before the code is written.
