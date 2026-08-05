---
id: 55
slug: emit-claude-and-codex-cli-completion-provider-evidence
title: "Emit Claude and Codex CLI completion-provider evidence"
kind: exec-plan
created_at: 2026-08-05T20:23:58Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Emit Claude and Codex CLI completion-provider evidence

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Two of Baikai's providers are not network clients at all. They run a coding-agent command-line
tool as a child process and read its output: `claude -p --output-format json` for Anthropic, and
`codex exec --json` for OpenAI. A caller uses them the same way they use an API provider — same
`Model` record, same `completeRequest` call — but the evidence available from them is
fundamentally different, and this plan is largely about being honest about how.

Right now both providers throw away almost everything the tool tells them. The Claude provider
*already decodes* a `session_id` field out of the tool's JSON result and then hardcodes
`responseId = Nothing` a few lines later. The Codex provider is further behind: it filters the
tool's entire event stream down to the text of `agent_message` events and discards the thread
identifier, the token counts, and everything else. Both hardcode `usage = zeroUsage`, which in a
cost log is a harmless shrug and in an evidence record is a false claim that the call used no
tokens.

After this plan, both subprocess providers emit evidence carrying what the tool actually reported:
the session or thread identifier, the token usage when the tool reports any, the model when the
tool names one, and — new for both — the identity of the executable that ran, its version string,
and a digest of the exact argument vector Baikai constructed. The evidence also states plainly
that a subprocess call is *weaker* evidence than an API call, and encodes the rule that a
successful process exit does not upgrade it. A tool that exits zero has run; it has not thereby
told you which model it used.

You can see it working with no credentials and no real tool invocation, because the tests drive
fake executables:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-claude baikai-openai
```


## Progress

- [ ] Extend `ClaudeCliResult` to decode the fields the tool already reports, and stop discarding
      `session_id`.
- [ ] Parse the Codex event stream for the thread identifier, token counts, and model, instead of
      discarding everything but the message text.
- [ ] Move the shared coding-agent result parsing into
      `baikai/src/Baikai/Provider/Cli/Internal.hs`.
- [ ] Capture executable identity, resolved path, and version for both tools, with caching.
- [ ] Build the argument-vector digest and confirm the configuration projection drops the prompt.
- [ ] Build the thinking translation for both CLI effort flags, recording the Claude `minimal`
      collapse.
- [ ] Populate both evidence records and derive the strength, capped so a zero exit cannot raise
      it.
- [ ] Write fixture tests driving fake executables for both tools.
- [ ] Add `CHANGELOG.md` entries under the existing `[Unreleased]` heading.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A zero exit status never raises evidence strength.
  Rationale: IR-3 states this explicitly and it is the single most important rule on this
  transport. A coding-agent CLI that exits zero has demonstrated that it ran and did not crash. It
  has not stated which model served the request, what effort was applied, or whether the request
  reached the intended provider at all. Encoding "exited zero" as corroboration would make the
  weakest evidence in the system look like the strongest, because subprocess calls almost always
  exit zero.
  Date: 2026-08-05

- Decision: Capture the executable's version by running it with `--version` once per process and
  caching the result, rather than per call — and only when the caller opted into evidence.
  Rationale: A version string is stable for the lifetime of a Baikai process in every realistic
  deployment, and spawning an extra subprocess per model call would roughly double the process
  cost of the cheapest possible call. Cache it in an `IORef` keyed by resolved executable path so
  that a caller who configures two different executables gets two correct answers. Probe lazily,
  from inside the evidence branch: a caller who never asked for evidence must not spawn a process
  whose only purpose is to describe a tool they were about to run anyway. If the probe fails — the
  tool is missing, or does not support `--version` — record the version as absent rather than
  failing the call; the call itself may still succeed and the absence is itself accurate evidence.
  Date: 2026-08-05

- Decision: The identifier and usage parsing from Milestone 1 is unconditional; only the digests
  and the version probe are gated on the evidence opt-in.
  Rationale: These providers currently report `zeroUsage` and a `Nothing` response identifier for
  every call, which is wrong for a cost-tracking caller who has never heard of evidence. Fixing
  that is a correction to `Response` and belongs to everyone. It also costs nothing extra: the
  provider has already read and decoded the tool's output to extract the assistant text, so the
  additional fields are lookups in a value that already exists. Gating a free bug fix behind an
  opt-in flag would be the wrong trade in the opposite direction.
  Date: 2026-08-05


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. This plan
changes three: `baikai/` (one shared internal module), `baikai-claude/`, and `baikai-openai/`.
From the repository root, `cabal build all` compiles everything and `cabal test baikai-claude` or
`cabal test baikai-openai` runs a package's tests. Test suites live in each package's `test/`
directory, use `tasty` with `tasty-hunit`, and are assembled in that directory's `Main.hs`.

Record fields in this codebase never carry the record's name as a prefix — a field is `sessionId`,
not `resultSessionId` — and `DuplicateRecordFields` is on so unrelated records legitimately share
plain names. Field access goes through `generic-lens` overloaded labels. The language is GHC2024,
every `deriving` clause must name its strategy explicitly, and every module needs an explicit
export list.

### The two subprocess providers, and how they differ from everything else

Both register as ordinary `ApiProvider` handlers in
`baikai/src/Baikai/Provider/Registry.hs`, so a caller dispatches to them exactly as to an API
provider. Neither streams: both run the tool to completion, parse its output, and build a
`Response` in one step. Their `stream` field is `liftCompleteToStream (runXCli cfg)`, which wraps
the batch result in a synthetic five-event stream so the streaming interface still works.

**The Claude CLI provider** is `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`.
`claudeCliCommand` renders the argument vector:

```haskell
    ["-p"]
      <> modelArgs m
      <> ["--output-format", "json", "--no-session-persistence"]
      <> systemPromptArgs ctx
      <> effortArgs opts
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> ["--", Text.unpack (Internal.renderPrompt ctx)]
```

Note the prompt is the last element of that vector, protected by `--`. That matters for the
digests: the argument vector contains the prompt, so the commitment digest legitimately covers it
and the configuration projection must drop it.

`effortArgs` renders `--effort` from the caller's `ThinkingLevel`, through:

```haskell
claudeEffortValue :: ThinkingLevel -> Text
claudeEffortValue ThinkingMinimal = "low"
claudeEffortValue lvl = renderThinkingLevel lvl
```

so `minimal` collapses to `low` — the tool's `--effort` flag has no `minimal` — and every other
level passes through unchanged. That collapse is currently invisible to a caller.

The result decoding is where the discarded evidence lives:

```haskell
data ClaudeCliResult = ClaudeCliResult
  { result :: !Text,
    is_error :: !Bool,
    session_id :: !(Maybe Text)
  }
```

`decodeResult` handles both output shapes the tool can produce — a bare JSON object, or an array
of event objects from which it picks the one whose `type` is `"result"`. Then `mkResponse`, a few
lines below, builds the `Response` with `usage = zeroUsage` and `Resp.responseId = Nothing`,
discarding the `session_id` it just decoded.

**The Codex CLI provider** is `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`. It spawns the
process with `System.Process` directly, drains stdout through
`Baikai.Provider.Cli.Internal.parseCodexJsonlStream`, drains stderr on a forked thread, and waits.
Its `effortArgs` sends `-c model_reasoning_effort=<level>` and, per its own Haddock, "Codex
accepts all six Baikai levels verbatim" — so unlike Claude's flag, nothing collapses.

`parseCodexJsonlStream` in `baikai/src/Baikai/Provider/Cli/Internal.hs` is where the discarding
happens. It splits stdout on newlines, decodes each line as JSON, runs each value through
`extractAgentMessage`, and concatenates the results:

```haskell
parseCodexJsonlStream chunks = do
  ...
  msgs <-
    Stream.foldMany lineFold bytes
      & Stream.mapMaybe Aeson.decodeStrict
      & Stream.mapMaybe extractAgentMessage
      & Stream.fold Fold.toList
  pure (Text.concat msgs)
```

`extractAgentMessage` accepts three schema variants — a nested `item` object, a nested `msg`
object, or a flat object — reflecting that the tool's event schema has changed across versions.
Everything that is not an `agent_message` is dropped, including the session-start event and any
token accounting.

### What the tools actually report

Both tools are installed on this machine — `claude` at version 2.1.222 and `codex-cli` at 0.146.0
as of this plan's writing. **Do not trust this section over the tools themselves.** Before
implementing, run each one against a trivial prompt and read its real output, because both
schemas have changed across versions and this plan's value depends on parsing what the installed
version actually emits. The Concrete Steps section gives the exact commands.

What you should expect to find, and must verify: `claude -p --output-format json` emits a result
object carrying at least `result`, `is_error`, `session_id`, a `usage` block with token counts,
and in recent versions a per-model usage breakdown and a total cost. `codex exec --json` emits a
newline-delimited event stream that begins with a thread- or session-start event carrying an
identifier, and includes token-count events during the run.

Whatever you find, the rule is the same: parse what is genuinely there, and record everything else
as `Unobserved`. Do not infer a model identifier from the one Baikai passed on the command line —
that is the request, not an observation, and conflating them is exactly what this initiative
exists to prevent.

### Terms used in this plan

The **argument vector** is the list of strings Baikai passes to the child process, excluding the
program name. A **session identifier** or **thread identifier** is the tool's own handle for the
conversation, which the vendor's support tooling can use to look it up. **Evidence strength** is
the `EvidenceStrength` value from `Baikai.Evidence`, an ordered enumeration of how much a record
proves. A **fake executable** is a small shell script written into a temporary directory by a test
and invoked in place of the real tool, so a test can drive the provider deterministically with no
credentials — `baikai-agent`'s existing tests use this technique and are worth reading as a model.

### What this plan depends on

Hard dependencies:
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) for the
vocabulary and
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) for the
channel. From plan 51 this plan uses `ThinkingTranslation`, `ThinkingAdjustment`, `Observed`,
`EvidenceStrength`, `TransportKind`, and `commitmentDigest`; from plan 52 it uses
`minimalEvidence` and the evidence slot on `TerminalPayload`.

Soft dependency:
[docs/plans/56](56-emit-unattended-agent-run-evidence.md) parses the same two tools' structured
output for the unattended agent surface. The parsing helpers belong in
`baikai/src/Baikai/Provider/Cli/Internal.hs`, which is the existing shared home for exactly this
kind of code. If plan 56 has already landed, import its helpers rather than writing new ones; if
this plan lands first, plan 56 imports yours. Whichever is second is responsible for consolidating
rather than leaving two copies.

### ADR context

This repository has no `docs/adr/` directory and `mori.dhall` declares no ADR bundle, so there is
no local ADR convention to follow and no relevant record to read. Record decisions in this plan's
Decision Log;
[docs/plans/57](57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md) establishes
`docs/adr/` and promotes the durable ones at the end of the initiative.


## Plan of Work

Three milestones: first learn what the tools report, then capture what Baikai itself knows about
the process it spawned, then assemble both into evidence.

### Milestone 1: stop discarding what the tools report

At the end of this milestone both providers parse the identifiers and usage their tools report,
and both surface them on the `Response` they already build. No evidence record changes yet, but
the discarded `session_id` bug is fixed and visible.

Begin by reading the tools' real output — see Concrete Steps for the commands — and record what
you find in this plan's Surprises & Discoveries, including the exact JSON shape. That record is
what makes this plan re-executable a year from now when the schemas have moved again.

For the Claude provider, extend `ClaudeCliResult` with the fields the installed version actually
emits. At minimum add a usage block; add a model field if one is present. Keep every new field
`Maybe`, because the tool's schema varies by version and a missing field must degrade to
`Unobserved` rather than failing the decode. Then fix `mkResponse` to carry `session_id` into
`Resp.responseId` and the parsed usage into the payload's `usage`, replacing the hardcoded
`zeroUsage`. Preserve the distinction the `Usage` type requires: its prompt-side classes are
disjoint, so if the tool reports an inclusive prompt total that already contains cached tokens,
subtract before constructing, exactly as `baikai/src/Baikai/Usage.hs` documents for the
OpenAI-inclusive case.

For the Codex provider, replace `parseCodexJsonlStream` with a function that folds the event
stream into a small result record rather than concatenating text:

```haskell
-- | What a @codex exec --json@ run reported about itself, beyond the
-- assistant text. Every field is optional because the event schema has
-- changed across codex versions and a missing field is a genuine
-- absence, not a parse failure.
data CodexRunReport = CodexRunReport
  { message :: !Text,
    threadId :: !(Maybe Text),
    reportedModel :: !(Maybe Text),
    usage :: !(Maybe Usage)
  }

parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport
```

Keep `extractAgentMessage` and its three-schema tolerance exactly as it is — it exists because the
schema really does vary — and add sibling extractors in the same style for the thread identifier
and the token counts. Write them to tolerate a missing or renamed field by returning `Nothing`,
never by throwing.

Put the new record and its extractors in `baikai/src/Baikai/Provider/Cli/Internal.hs`, which
already houses exactly this kind of shared subprocess helper and whose header already states it is
an internal interface not covered by PVP guarantees. Do the same for the Claude result parsing:
move `ClaudeCliResult`'s decoding there too, so that
[docs/plans/56](56-emit-unattended-agent-run-evidence.md) has one place to import from.

The tests for this milestone go in `baikai/test/CliInternalSpec.hs`, which already exists and
already tests these parsers. Add cases feeding recorded stdout from both tools and asserting the
identifiers, model, and usage are extracted; and add negative cases feeding output with those
fields absent, asserting the result is `Nothing` rather than an exception or a zero.

Verify:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai --test-options='--pattern CliInternal'
```

### Milestone 2: capture what Baikai knows about the process

At the end of this milestone both providers know which executable they ran, where it resolved to,
what version it reports, and a digest of the exact argument vector.

Add a shared helper to `baikai/src/Baikai/Provider/Cli/Internal.hs`:

```haskell
-- | Identity of the executable a subprocess provider ran.
data ExecutableIdentity = ExecutableIdentity
  { -- | The name or path as configured.
    configured :: !Text,
    -- | The absolute path it resolved to on PATH, when resolution
    --   succeeded.
    resolvedPath :: !(Maybe Text),
    -- | What the tool prints for @--version@, trimmed. 'Nothing' when
    --   the probe failed or the tool has no such flag; a failed probe
    --   is recorded as absent rather than failing the call.
    version :: !(Maybe Text)
  }

-- | Resolve and probe an executable, caching the result for the
-- lifetime of the process, keyed by the configured name. Probing runs
-- the tool once with @--version@; a tool that hangs is bounded by a
-- short timeout, because a version probe must never be able to wedge a
-- model call.
executableIdentity :: FilePath -> IO ExecutableIdentity
```

Resolve the path with `System.Directory.findExecutable`. Bound the probe with
`System.Timeout.timeout` at a couple of seconds. Cache in an `IORef (Map FilePath
ExecutableIdentity)` created with the same `unsafePerformIO`-plus-`NOINLINE` pattern that
`baikai/src/Baikai/Provider/Registry.hs` already uses for its global registry, so the idiom
matches what is already in the codebase.

Then, in each provider, render the argument vector as a JSON array of strings and hand it to the
digest functions from plan 51. The commitment digest covers the whole vector including the
prompt — that is what makes it a commitment. The configuration digest must not: extend plan 51's
`configurationProjection` to handle an argv-shaped input, or, if that turns out to be awkward,
have each provider build a separate configuration value containing the flags and their values with
the prompt element removed, and digest that. Choose whichever produces the clearer code and record
the choice in the Decision Log; what matters is the property, tested directly, that the prompt
text does not appear in the bytes the configuration digest is computed over.

Also build the thinking translation for each provider. For Claude, `mode = ThinkingModeFlag`,
`wireField = Just "--effort"`, `effortText` set to the rendered value, and an
`EffortClamped ThinkingMinimal "low"` adjustment when the level was `ThinkingMinimal`. For Codex,
`mode = ThinkingModeFlag`, `wireField = Just "model_reasoning_effort"`, `effortText` set to the
canonical name, and no adjustment — Codex accepts all six levels verbatim, which is worth
asserting in a test precisely because it is the only transport in Baikai that does.

### Milestone 3: assemble the evidence

At the end of this milestone both subprocess providers emit complete evidence records with an
honest strength.

In each provider, replace the `minimalEvidence` call plan 52 added with one passing the real
thinking translation, the argv-derived digests, and `TransportKind = TransportSubprocess`. Then
overwrite the observed fields from Milestone 1's parsed report and set the strength through a named
function shared by both, in `baikai/src/Baikai/Provider/Cli/Internal.hs`.

That call returns `Maybe ModelCallEvidence` and is `Nothing` when the caller did not opt into
evidence, so this milestone's enrichment happens inside a `traverse` or an explicit `case`. Two
things on this transport in particular must sit inside that branch. The digests, as everywhere
else. And the **version probe from Milestone 2**, which spawns a whole extra subprocess: even
cached per process, the first opted-out call would otherwise pay for a `--version` invocation of a
tool it is about to invoke anyway, which is a visible cost on the cheapest possible call. Call
`executableIdentity` only when building evidence.

Milestone 1's parsing is the opposite case and stays unconditional. Reading the session identifier
and the token usage out of output the provider has already read and already decoded costs nothing
extra, and both are corrections to `Response` that every caller benefits from — a cost-tracking
user currently gets `zeroUsage` from these providers whether they want evidence or not. Do not gate
a bug fix behind an opt-in flag.

The strength function:

```haskell
-- | How much a subprocess call's evidence proves.
--
-- A coding-agent CLI that exits zero has demonstrated that it ran and
-- did not crash. It has not stated which model served the request, so a
-- successful exit never raises the strength. Only a value the tool
-- itself reported can do that.
subprocessStrength ::
  -- | The session or thread identifier the tool reported.
  Observed Text ->
  -- | The model the tool reported, if it reports one at all.
  Observed Text ->
  EvidenceStrength
```

It returns `EvidenceModelObserved` when the tool reported both, `EvidenceCorrelated` when it
reported only an identifier, and `EvidenceRequestedOnly` otherwise. Write the exit status nowhere
near it.

Populate `EndpointIdentity` for both: `transport = TransportSubprocess`, `endpoint` set to the
resolved executable path rather than a URL — a subprocess has no endpoint URL, and recording the
model's base URL there would be misleading, since no HTTP request was made — and
`implementationVersion` set to the executable's probed version rather than the Baikai vendor
package version, because for this transport the tool *is* the implementation. Record the vendor
package version too if the `EndpointIdentity` record has room; if it does not, prefer the tool's
version, since that is the one that determines behavior.

Set `responseCommitment` from a digest over the tool's parsed result, `Observed` on success and
`Unobserved` on a failed run that produced no parseable result.

The tests are fixture-driven and need no credentials. Write a fake executable into a temporary
directory — a shell script that ignores its arguments and prints recorded JSON on stdout, then
exits zero — point the provider's config at it, run a call through `withTrace` with a capturing
sink, and assert the single `CallEvidence` record. For each provider assert: an `Observed`
`responseId` carrying the fixture's session or thread identifier; an `Observed` `usage` with the
fixture's token counts and not `zeroUsage`; a `strength` matching what the fixture actually
reported; an `EndpointIdentity` whose `endpoint` is the fake executable's path; and a
`thinking.mode` of `ThinkingModeFlag`.

Then write the test that proves the central rule of this plan: a fake executable that exits zero
but prints a result containing **no** session identifier and **no** model must produce evidence
with `strength = EvidenceRequestedOnly`. That single assertion is what stops the weakest transport
in the system from looking like the strongest.

Add one more for Claude specifically: a call with `thinking = Just ThinkingMinimal` must produce a
translation carrying `EffortClamped ThinkingMinimal "low"` and an argument vector containing
`--effort low`. Assert both together, so the description and the argv cannot drift apart.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm the two prerequisite plans are complete and the tree is green:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test baikai --test-options='--pattern Evidence'
```

Read these files completely before editing, in this order:
`baikai/src/Baikai/Provider/Cli/Internal.hs` (the shared parsers),
`baikai-claude/src/Baikai/Provider/Claude/Cli.hs` (the Claude provider),
`baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs` (the Codex provider), and
`baikai/test/CliInternalSpec.hs` (the parser test pattern you will extend).

See the discarded identifier for yourself before fixing it:

```bash
rg -n 'session_id|responseId' baikai-claude/src/Baikai/Provider/Claude/Cli.hs
```

Expect to see `session_id` decoded in `ClaudeCliResult` and `responseId = Nothing` set in
`mkResponse`.

Now find out what the installed tools actually emit. Both are present on this machine; confirm
their versions first, because this plan's parsing depends on them:

```bash
claude --version
codex --version
```

Then capture real output. These commands invoke live models and consume quota, so use a trivial
prompt and run each once:

```bash
cd /tmp
claude -p --output-format json --no-session-persistence -- 'say ok' > /tmp/claude-result.json
jq 'keys' /tmp/claude-result.json
jq '{session_id, is_error, usage, modelUsage}' /tmp/claude-result.json
```

```bash
cd /tmp
codex exec --json 'say ok' > /tmp/codex-events.jsonl
jq -c '.type // (.msg.type) // (.item.type)' /tmp/codex-events.jsonl | sort -u
jq -c 'select((.type // .msg.type // .item.type) | test("thread|session|token|usage"))' /tmp/codex-events.jsonl
```

Record the resulting shapes in this plan's Surprises & Discoveries, then copy the captured output
into the test fixture directories as the recorded inputs the tests replay. If you cannot run the
tools — no credentials, no network — say so in Surprises & Discoveries and write the parsers
against the schemas described in Context and Orientation, marking every field optional; the
parsers must degrade to `Unobserved` on an unexpected shape anyway, so this is a degraded but
workable path.

Work through the three milestones, committing after each with all three trailers:

```text
Preserve the identifiers and usage the coding-agent CLIs report

Stop discarding the claude session_id that ClaudeCliResult already
decodes, fold the codex event stream into a report carrying its thread
id and token counts, and move both parsers into the shared CLI internal
module.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/55-emit-claude-and-codex-cli-completion-provider-evidence.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and `cabal test all` passes.

A Claude CLI call driven by a fake executable produces exactly one `CallEvidence` record whose
`responseId` is `Observed` carrying the fixture's `session_id`. Before this plan that field was
hardcoded `Nothing` despite being decoded.

A Codex CLI call driven by a fake executable produces exactly one `CallEvidence` record whose
`responseId` is `Observed` carrying the fixture's thread identifier, and whose `usage` is
`Observed` with the fixture's token counts. Before this plan both were absent and `zeroUsage`
respectively.

A fake executable that exits zero but reports no identifier and no model produces
`strength = EvidenceRequestedOnly`. This is IR-3's rule that a successful process exit does not
upgrade evidence, and it is the acceptance criterion this plan exists to satisfy.

Both records carry an `EndpointIdentity` whose `endpoint` is the resolved executable path and
whose `implementationVersion` is the tool's own reported version, and a `requestCommitment`
computed over the argument vector.

The prompt does not appear in the bytes the configuration digest is computed over. Assert this
directly on the encoded bytes, with a fixture prompt containing a distinctive literal string, in
the same style as plan 51's redaction test.

A Claude CLI call at `ThinkingMinimal` produces both an argument vector containing `--effort low`
and a translation recording `EffortClamped ThinkingMinimal "low"`. A Codex CLI call at every one of
the six levels produces an argument vector containing that level's canonical name verbatim and a
translation with no adjustments.

Nothing regressed: the existing `baikai`, `baikai-claude`, and `baikai-openai` test suites pass,
and any assertion this plan changes is recorded in the Decision Log with its reason. In
particular, `baikai/test/CliInternalSpec.hs` asserts against `parseCodexJsonlStream`'s current
`IO Text` signature and will need updating for the new return type — that is expected, not a
regression.


## Idempotence and Recovery

Every code step is safe to repeat; `cabal build` and `cabal test` have no side effects, and the
tests write their fake executables into a temporary directory they create and remove.

The output-capture commands in Concrete Steps are the exception: they invoke live coding-agent
tools, consume quota, and cost money. Run each once, save the output to a file, and work from the
file thereafter. Do not put them in a script that a test runs.

Changing `parseCodexJsonlStream`'s return type from `IO Text` to `IO CodexRunReport` breaks its
existing callers and tests. The compiler finds them all, so the risk is scope creep rather than
silent breakage. If the change starts growing beyond the two call sites and the one test module,
stop and record why in the Decision Log.

The version probe added in Milestone 2 spawns an extra subprocess. If it turns out to be slow or
flaky in the test environment, make the probe opt-out through the provider's existing config
record rather than removing it, and record that in the Decision Log — the version is real evidence
and dropping it silently would defeat the plan.


## Interfaces and Dependencies

New dependencies: `directory` for `findExecutable`, in whichever package hosts
`executableIdentity`; check `baikai/baikai.cabal` first, since `directory` is already a dependency
of the package's two generator executables and may only need adding to the library stanza.
`System.Timeout` and `System.Process` are in `base` and `process`, both already available.

The surface that must exist when this plan is complete:

In `baikai/src/Baikai/Provider/Cli/Internal.hs`:

```haskell
data CodexRunReport = CodexRunReport
  { message :: !Text,
    threadId :: !(Maybe Text),
    reportedModel :: !(Maybe Text),
    usage :: !(Maybe Usage)
  }

parseCodexJsonlStream :: Stream IO ByteString -> IO CodexRunReport

data ClaudeCliReport = ClaudeCliReport
  { result :: !Text,
    isError :: !Bool,
    sessionId :: !(Maybe Text),
    reportedModel :: !(Maybe Text),
    usage :: !(Maybe Usage)
  }

decodeClaudeCliResult :: ByteString -> Either BaikaiError ClaudeCliReport

data ExecutableIdentity = ExecutableIdentity
  { configured :: !Text,
    resolvedPath :: !(Maybe Text),
    version :: !(Maybe Text)
  }

executableIdentity :: FilePath -> IO ExecutableIdentity

subprocessStrength :: Observed Text -> Observed Text -> EvidenceStrength
```

Note that `ClaudeCliReport` uses `isError` where the tool's JSON field is `is_error`; the record
field follows Haskell naming and the aeson instance does the mapping. Do not name the Haskell
field `is_error` to match the wire.

In `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`, `mkResponse` carries the session identifier
and parsed usage instead of `Nothing` and `zeroUsage`, and the provider builds a
`ThinkingTranslation` with `mode = ThinkingModeFlag`.

In `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, `consume` builds its `Response` from a
`CodexRunReport` instead of a bare `Text`, and the provider builds a `ThinkingTranslation` with
`mode = ThinkingModeFlag`.

The `ThinkingTranslation`, `ThinkingMode`, `ThinkingAdjustment`, and `EvidenceStrength` types are
owned by `Baikai.Evidence` and must not be extended here. If a needed case is missing, that is a
change to
[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) and to the
MasterPlan's Integration Points section, and both must be updated before the code is written.
