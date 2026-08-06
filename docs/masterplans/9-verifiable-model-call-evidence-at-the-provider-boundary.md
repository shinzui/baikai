---
id: 9
slug: verifiable-model-call-evidence-at-the-provider-boundary
title: "Verifiable model-call evidence at the provider boundary"
kind: master-plan
created_at: 2026-08-05T20:23:43Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
---

# Verifiable model-call evidence at the provider boundary

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Today a Baikai caller can show what its own process was *configured* to ask a model for. It
cannot show what actually crossed the boundary to the provider. The trace event that Baikai
emits for a finished call — `CallFinished` in `baikai/src/Baikai/Trace/Event.hs` — carries the
provider name, the configured model id, a latency, input and output token counts, and a dollar
cost. It does not carry the reasoning-effort level the caller asked for, the exact wire settings
Baikai translated that request into, any provider-issued correlation identifier, or any
distinction between the model that was *requested* and the model the provider says it *ran*.
On the last point the gap is total: neither API provider ever reads the model identifier the
provider echoes back, so `Response.model` is the caller's own `Model` record by construction.

After this initiative, every terminal provider call — an Anthropic Messages API call, an
OpenAI-compatible Chat Completions call, a `claude -p` subprocess call, a `codex exec`
subprocess call, and an unattended coding-agent run started through `baikai agent run` — emits
exactly one versioned `ModelCallEvidence` value. That value records, in separate and
non-collapsible fields, what the caller requested, what Baikai translated the request into for
that specific provider, and what the provider was observed to report back. A field the provider
did not report is recorded as explicitly unobserved; it is never backfilled from the request.
The evidence carries a caller-supplied run identifier and a globally unique call identifier, the
provider's response and request-correlation identifiers when the transport exposes them, start
and terminal timestamps, latency, status, a normalized error, the full disjoint token-usage
breakdown, and two canonical digests over the request and response envelopes.

A caller who wants none of this pays nothing for it. Evidence is constructed only when the caller
sets the per-call evidence field; with that field absent — which is every existing caller — no
digest is computed, no call identifier is generated, no evidence event is emitted, and the trace
output is byte-identical to what the same call produced before this initiative. That is a hard
requirement of the design, not a best effort: the two canonical digests hash the full request
envelope, and imposing that on someone who only wanted token counts would be a real and
unjustifiable cost.

A caller that needs strong evidence can demand it. Strict evidence mode is a per-call setting
that makes Baikai refuse, *before dispatch*, to run a call on a provider or transport that
cannot supply the correlation and observation fields the caller requires, or that would silently
weaken the caller's reasoning-effort request. Callers who do not opt in keep today's best-effort
trace behavior unchanged.

Concretely, after this initiative someone can run a single command against a fake provider
fixture and read a complete, schema-valid record of the call out of a trace file:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai baikai-claude baikai-openai baikai-agent
```

and, in an application, write:

```haskell
evidence <- withEvidence sink runId model ctx (opts & #evidence .~ Just strictEvidence)
```

and get either a complete evidence record or a pre-dispatch refusal naming exactly which
required field the chosen transport cannot provide.

### What this initiative deliberately excludes

Baikai does not sign anything, does not hold a policy about which models are sanctioned, and
does not claim to know what happened inside a provider. It reports what it requested, what it
translated, and what it observed at its own boundary. Correlating calls into a run, evaluating a
pinned model profile, binding a run to a reviewed artifact, and signing the run-level statement
all belong to `mori://shinzui/shikigami`. Provider-signed receipts and confidential-computing
attestation are strictly stronger evidence than anything achievable here and need provider
support Baikai does not have; they are out of scope.

Baikai also does not gain a retry or provider-fallback loop as part of this work. No such loop
exists in the repository today — `Baikai.Error` classifies whether an error is *retryable* but
nothing retries. The evidence therefore models a retry relationship as caller-supplied
provenance (an attempt ordinal and an optional parent call id), not as something Baikai
observes. Building a retry loop is separate work.

### The originating request

This initiative implements
[docs/improvement-requests/capture-verifiable-model-call-evidence.md](../improvement-requests/capture-verifiable-model-call-evidence.md)
(IR-3), which originates from `mori://shinzui/kikan` and supplies the call-level evidence
consumed by `mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-7` and
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`, in service of
`mori://shinzui/kikan/okf/use-cases/concepts/UC-8`. The IR was reviewed in this repository
against the actual code before this MasterPlan was written; the review is recorded in the IR's
frontmatter and its corrections are carried into the decomposition below and into the Decision
Log.


## Decomposition Strategy

### ADR context

This repository has no `docs/adr/` directory and no local Architecture Decision Records. The
`mori.dhall` manifest declares exactly one OKF bundle — `improvement-requests` at
`docs/improvement-requests` — and `mori show --full` reports zero ADR bundles, so there is no
profile-governed ADR corpus to honor and no ADR handle to allocate. Cross-repository ADR search
through `mori registry concepts` surfaced no decision record governing provider-boundary
evidence, attestation envelopes, or trace-event schema versioning.

Durable project judgment for this initiative therefore has no existing home. The Decision Log
below is the authoritative record during implementation. Several decisions here are clearly
durable rather than task-local — the requested/effective/observed three-way split, the
adapter-owns-translation boundary, the two-digest hashing contract, and the deliberate exclusion
of signing and retry ownership — and the final child plan is responsible for establishing
`docs/adr/` and promoting them, following `agents/skills/exec-plan/ADR.md`.

### How the work divides

The initiative decomposes by functional concern along the path a call takes, because that is
where the real coupling lies. A single value type must be agreed before anything can emit it; a
transport channel must exist before any adapter can push evidence through it; each provider
family then translates its own vocabulary independently; and a final plan turns the collected
capability into an enforceable caller-facing contract and ships it.

The first plan, [docs/plans/51](../plans/51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md),
owns the vocabulary and the pure machinery underneath it: the `ModelCallEvidence` record and
every type it contains, the canonical JSON encoding, the two digests, and a replacement for the
call-identifier generator. It touches no provider. It is a hard dependency of everything else
because every other plan constructs values of the types it defines.

The second plan, [docs/plans/52](../plans/52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md),
owns the plumbing: how a provider adapter hands evidence back to the trace layer, and how the
trace layer emits exactly one terminal evidence record per call under streaming, early consumer
termination, and sink failure. This is separated from plan 51 because it is where the
public-surface breakage lives, and it is separated from the provider plans because all four
API/CLI provider families push through the same channel and would otherwise each invent one.

The three provider plans — [53](../plans/53-emit-anthropic-messages-api-call-evidence.md) for the
Anthropic Messages API, [54](../plans/54-emit-openai-compatible-api-call-evidence.md)
for OpenAI-compatible Chat Completions, and [55](../plans/55-emit-claude-and-codex-cli-completion-provider-evidence.md)
for the two subprocess completion providers — are separate because their translation vocabularies
share nothing. Anthropic has two thinking styles (a token budget and an adaptive mode steered by
an effort string) and its own compatibility matrix; OpenAI-compatible hosts have seven distinct
wire shapes for the same preference; the CLIs pass effort as command-line flags and report
structured results in two entirely different JSON dialects. Merging them would produce one plan
doing most of the work with no independent verifiability. They are independently verifiable
because each can be proved against recorded fixtures with no live credentials.

The sixth plan, [docs/plans/56](../plans/56-emit-unattended-agent-run-evidence.md), covers the
unattended coding-agent surface built by
[docs/masterplans/8](8-unattended-coding-agent-runs-through-a-configurable-cli.md). That surface
is architecturally disjoint from every other: `Baikai.Agent` returns an `AgentRunResult` (a
process exit code, captured output streams, and a duration), never constructs a `Response`, never
dispatches through `Baikai.Provider.Registry`, and has no trace sink at all — a grep for `Trace`
across `baikai-agent/src` and `baikai-kit/src` returns nothing. It therefore needs a second
evidence emission path rather than a variation on the first, which is exactly why it is its own
plan and why it depends only on plan 51 rather than on the transport plan.

The final plan, [docs/plans/57](../plans/57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md),
turns capability into contract. Strict evidence mode is deliberately last: it can only be
specified honestly once every provider's real evidence strength is known, and its acceptance
criterion — that it refuses a downgrade — requires all the downgrade sites to be enumerated and
recorded first. This plan also owns the migration guidance for existing trace and cost consumers,
the user documentation, the coordinated version bumps across five packages, and the ADR
distillation pass.

### Alternatives considered and rejected

**One plan per package** was rejected because `baikai` is touched by five of the seven work
streams and would have absorbed most of the initiative, while `baikai-trace-otel` would have
been a two-line plan. Package boundaries do not match the functional concerns here.

**Folding the evidence transport channel into plan 51** was rejected because plan 51 is pure and
independently testable with golden tests, whereas the transport change breaks the public
`ApiProvider` and `TerminalPayload` surfaces across five packages. Keeping the breaking change in
its own plan means a reviewer can evaluate the surface cost in isolation, and means plan 56 (the
agent surface, which uses neither type) does not have to wait for it.

**Folding strict mode into each provider plan** was rejected because strict mode is a
cross-provider policy: its whole value is that a caller can state a requirement once and have it
enforced identically regardless of which transport serves the call. Distributing it would produce
four subtly different enforcement rules.

**Splitting out a hotfix plan for the OpenAI-native effort mapping** was considered while this
decomposition still believed that mapping was buggy. It is not buggy — see Surprises &
Discoveries — so there is nothing to split out. What survives of that idea is a one-line doc
correction folded into plan 54, which is the plan that enumerates the mapping anyway.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Add the model-call evidence vocabulary and canonical hashing core | docs/plans/51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md | None | None | Complete |
| EP-2 | Carry evidence from the provider adapter to the trace boundary | docs/plans/52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md | EP-1 | None | Complete |
| EP-3 | Emit Anthropic Messages API call evidence | docs/plans/53-emit-anthropic-messages-api-call-evidence.md | EP-1, EP-2 | EP-4 | Complete |
| EP-4 | Emit OpenAI-compatible API call evidence | docs/plans/54-emit-openai-compatible-api-call-evidence.md | EP-1, EP-2 | EP-3 | Complete |
| EP-5 | Emit Claude and Codex CLI completion-provider evidence | docs/plans/55-emit-claude-and-codex-cli-completion-provider-evidence.md | EP-1, EP-2 | None | Complete |
| EP-6 | Emit unattended agent-run evidence | docs/plans/56-emit-unattended-agent-run-evidence.md | EP-1 | EP-5 | Not Started |
| EP-7 | Enforce strict evidence mode and release the evidence surface | docs/plans/57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md | EP-2, EP-3, EP-4, EP-5, EP-6 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 has no dependencies and must come first. Every other plan constructs values of the types it
defines — `ModelCallEvidence`, `Observed`, `ThinkingTranslation`, `EvidenceStrength`,
`CallIdentity` — and calls its canonical encoder and digest functions. Nothing else can compile
until those types exist.

EP-2 hard-depends on EP-1 alone. It widens the provider-to-trace channel to carry a
`ModelCallEvidence`, which requires the type to exist but requires no provider to populate it
yet: EP-2 lands with every adapter supplying a minimal evidence value built only from what the
core already knows (provider, requested model, timestamps, latency, status, usage), so the tree
compiles and the existing test suite passes at every commit.

EP-3, EP-4, and EP-5 each hard-depend on EP-1 and EP-2. They fill in the fields their own
transport can actually supply, and each is independently verifiable against recorded fixtures.
They can proceed fully in parallel. EP-3 and EP-4 carry a mutual *soft* dependency rather than a
hard one: both populate the `ThinkingTranslation` record that EP-1 defines, and whichever lands
first sets the practical convention for how a provider describes a clamp or a collapse. The
second one to land should read the first's recorded translation values and match their spelling.
Neither blocks the other, and EP-1 owns the type, so a disagreement is a reconciliation, not a
rebuild.

EP-6 hard-depends only on EP-1. The unattended agent surface never touches `ApiProvider`,
`Response`, `TerminalPayload`, or `Baikai.Trace`, so EP-2's channel is irrelevant to it. This is
deliberate: EP-6 can run in parallel with EP-2 as soon as EP-1 is complete, which shortens the
critical path. EP-6 soft-depends on EP-5 because both parse the same two coding-agent CLIs'
structured JSON output — `claude`'s result envelope and `codex exec --json`'s event stream — and
the parsing helpers should be shared rather than duplicated. If EP-5 lands first, EP-6 imports
its helpers; if EP-6 lands first, EP-5 imports EP-6's. Whichever is second is responsible for
consolidating.

EP-7 hard-depends on all five emitting plans. Strict evidence mode's contract is "reject a
transport that cannot meet the caller's required evidence strength", and that sentence cannot be
specified — let alone tested — until every transport's actual strength is known and recorded.

The waves are therefore: wave one is EP-1 alone; wave two is EP-2 and EP-6 in parallel; wave
three is EP-3, EP-4, and EP-5 in parallel; wave four is EP-7.


## Integration Points

**`Baikai.Evidence` (new module in `baikai/src/Baikai/Evidence.hs`).** Involves every plan.
EP-1 defines it and owns every type in it. No later plan may add, remove, or repurpose a field
without updating EP-1's plan file and this MasterPlan first, because the module carries an
explicit schema version string that Shikigami will pin against. Later plans consume the types
and construct values; they do not extend the vocabulary.

**`ThinkingTranslation` (a record inside `Baikai.Evidence`).** Involves EP-1, EP-3, EP-4, EP-5,
EP-6. EP-1 defines it as the provider-agnostic description of what a canonical `ThinkingLevel`
actually became on the wire: the effort text if any, the token budget if any, the mode
(adaptive, manual budget, flag-only, or unsupported), and a list of recorded adjustments
describing every clamp, collapse, or drop that was applied. Each provider plan populates it from
its own translation site and must not re-derive it anywhere downstream. The reason this is a
hard rule and not a preference: re-deriving the translation in a trace sink would require the
sink to reimplement `computeThinking`, `injectThinkingShape`, and the compat lookup for every
host, and it would silently diverge the first time a translation changed.

**`TerminalPayload` (`baikai/src/Baikai/Stream/Event.hs`).** Involves EP-2, EP-3, EP-4, EP-5.
EP-2 owns the change: the evidence travels back from an adapter on the terminal stream event. The
type is part of Baikai's public surface — `Baikai.Stream.Event`'s own module documentation states
that changing the event algebra is a breaking change — so EP-2 defines the exact new shape and the
three provider plans consume it unchanged. EP-2 is also responsible for the mechanical updates
this forces in `baikai-effectful` and `baikai-trace-otel`.

**`ApiProvider` (`baikai/src/Baikai/Provider/Registry.hs`).** Involves EP-7, and through it every
provider package. EP-2 deliberately leaves this type alone, because the evidence *channel* does
not need it — per-call data belongs on the per-call event, not on the per-handler record. EP-7
adds a fourth field, `describeThinking`, because the pre-dispatch strictness *gate* needs to know
what a provider would do with a reasoning-effort request before any request has been built. That
split is intentional and each plan states it; a reader who sees only EP-2 will correctly believe
`ApiProvider` is unchanged, and EP-7's Interfaces section is the authority on why it later is not.
Each provider's implementation is a one-liner delegating to the translation function its own plan
already built.

**`Baikai.Options` (`baikai/src/Baikai/Options.hs`).** Involves EP-1, EP-7. EP-1 adds the
per-call evidence request field (the run id and the requested strictness). EP-7 is the only plan
that gives that field enforcement teeth. Splitting it this way means the field exists early
enough for every provider plan to read it, while the refusal semantics land once.

**`TraceEvent` (`baikai/src/Baikai/Trace/Event.hs`) and its consumers.** Involves EP-2, EP-7.
EP-2 extends the event sum with the evidence-carrying case and fixes the existing fidelity losses
described under Surprises & Discoveries. EP-7 owns the migration story for existing consumers —
`Baikai.Trace.Sink`'s four built-in sinks, `baikai-trace-otel`'s span mapping, and
`Baikai.Cost.Log`'s `CallLogEntry` — so that none of them treats the new evidence as a claim
about provider-internal execution.

**The coding-agent CLI result parsers.** Involves EP-5, EP-6. Both need to read structured
identifiers and usage out of `claude -p --output-format json` and `codex exec --json`.
`baikai/src/Baikai/Provider/Cli/Internal.hs` is the existing shared home for exactly this kind of
helper and is the agreed location; whichever plan lands second consolidates into it rather than
adding a parallel copy in a vendor package.

**Package versions and the changelog.** Involves every plan. Each plan adds entries under the
existing `[Unreleased]` heading in `CHANGELOG.md` and none creates a dated release heading. EP-7
owns the coordinated version computation and the release, following
`agents/skills/release/SKILL.md`.

### Cross-plan decisions that should become ADRs

EP-7 must create `docs/adr/` and promote at least the following, per
`agents/skills/exec-plan/ADR.md`: the requested/effective/observed three-way split and the rule
that an unobserved field is never backfilled; the boundary that the provider adapter owns
translation description and no downstream layer may re-derive it; the two-digest hashing contract
and what each digest does and does not prove; and the deliberate exclusions — Baikai does not
sign, does not hold sanctioning policy, and does not own retries.


## Progress

- [x] EP-1: Define `Baikai.Evidence` — the `ModelCallEvidence` record, `Observed`,
      `ThinkingTranslation`, `EvidenceStrength`, and the schema version constant. (2026-08-05)
- [x] EP-1: Replace the process-local call-id generator with a globally unique one and add the
      caller-supplied run id to `Baikai.Options`. (2026-08-05)
- [x] EP-1: Implement canonical JSON encoding and the two digests, with golden tests proving
      stability across map ordering and encoder differences and proving no credential, prompt
      body, thinking text, or tool payload appears in the envelope. (2026-08-05)
- [x] EP-2: Widen the provider-to-trace channel so an adapter returns the evidence it built.
      (2026-08-05)
- [x] EP-2: Prove the opt-out path is free — a call with no evidence request produces trace output
      byte-identical to the pre-initiative output and computes no digest. (2026-08-05)
- [x] EP-2: Emit exactly one terminal evidence record per call across streaming, retries at the
      caller level, early consumer termination, and sink failure. (2026-08-05)
- [x] EP-2: Stop eliding usage and cost fidelity in the trace path; propagate the mechanical
      updates through `baikai-effectful` and `baikai-trace-otel`. (2026-08-05)
- [x] EP-3: Promote the Anthropic `ThinkingPlan` into the shared `ThinkingTranslation` and record
      every Anthropic downgrade site. (2026-08-05)
- [x] EP-3: Capture the Anthropic response correlation header and the provider-reported model
      through the local SSE transport. (2026-08-05)
- [x] EP-3: Prove all six canonical thinking levels against both Anthropic thinking styles with
      recorded fixtures. (2026-08-05)
- [x] EP-4: Build the OpenAI-compatible translation record across all seven wire shapes.
      (2026-08-05)
- [x] EP-4: Correct the stale `ThinkingFormatOpenAI` Haddock, leaving the native effort mapping —
      which is deliberate and test-guarded — unchanged. (2026-08-05)
- [x] EP-4: Capture the OpenAI-compatible response correlation header and provider-reported
      model. (2026-08-05)
- [x] EP-5: Preserve the Claude CLI session identifier and parse its reported usage, its reported
      cost, and the model it names in `modelUsage`. (2026-08-05)
- [x] EP-5: Parse the Codex CLI thread identifier and token counts from its event stream, and
      establish that it names no model at all. (2026-08-05)
- [x] EP-5: Record executable identity, version, and argument-vector digest, at explicitly weaker
      evidence strength that a zero exit status cannot raise. (2026-08-05)
- [ ] EP-6: Add the unattended agent-run evidence path and its emission point.
- [ ] EP-6: Capture agent-run executable identity, version, argv digest, and structured result
      identifiers.
- [ ] EP-6: Surface evidence through the `baikai agent run` command.
- [ ] EP-7: Implement strict evidence mode with pre-dispatch refusal across every enumerated
      downgrade site.
- [ ] EP-7: Make strict mode fail the call on trace-sink failure while best-effort mode keeps
      today's behavior.
- [ ] EP-7: Write `docs/user/model-call-evidence.md` and the migration guidance for existing
      trace and cost consumers.
- [ ] EP-7: Create `docs/adr/`, promote the durable decisions, and coordinate the release across
      every affected package.


## Surprises & Discoveries

These were found while reviewing IR-3 against the code, before any implementation began. They
are recorded here because several of them change what the child plans must do.

**The existing call-identifier generator is not unique across processes.** `newEventId` in
`baikai/src/Baikai/Trace.hs` builds a 64-bit value from process-start POSIX seconds in the high
32 bits and a process-local counter in the low 32 bits, and its own docstring claims only
per-process uniqueness. Two Baikai processes started within the same second emit identical
identifier sequences. For ordinary tracing this is a minor collision hazard; for evidence that a
separate system correlates into a run, it is a correctness defect. EP-1 replaces the generator
rather than extending it.

**There is no observed model anywhere in the codebase.** Both API providers build the assistant
skeleton from the caller's own `Model` record — `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
line 315 and `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` line 597 — so `Response.model` is
the request's model by construction and the provider-reported model is discarded unread. IR-3
describes this as an inability to *distinguish* requested from observed; the truth is stronger,
which makes EP-3 and EP-4 slightly larger than the request implies.

**Half the translation description already exists but is thrown away.** `ThinkingPlan` in
`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` (lines 144–179) carries exactly
the effort text, the token budget, and the wire field that IR-3 asks a provider to report. It is
computed inside `mapRequest` and then discarded. EP-3 promotes it rather than inventing
something. The OpenAI side has no equivalent at all — `injectThinkingShape` in
`baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` injects JSON directly with nothing reified —
so EP-4 must build one from scratch. This asymmetry is why the two plans are separate.

**Silent thinking downgrades occur at six distinct sites, not one.** IR-3's example is
`minimal -> low`, which suggests a single mapping table. The actual sites are: `computeThinking`
returning an empty plan when the model does not advertise `reasoning`
(`Claude/Internal/Request.hs:166`); `mapRequest` discarding an already-computed thinking plan
when the resolved max-tokens value does not exceed the budget (`Claude/Internal/Request.hs:55`),
which silently disables thinking on a reasoning model through a max-tokens interaction that is
invisible even to a caller reading the request; `ThinkingFormatNone` dropping the option, which
`baikai/src/Baikai/Compat.hs` documents as silent; `compatibleEffort` collapsing both `xhigh` and
`max` to `high` (`OpenAI/Shape.hs:214`); `adaptiveEffort ThinkingHigh = Nothing`
(`Claude/Internal/Request.hs:186`), which makes a requested `high` wire-indistinguishable from
provider-default depth; and `claudeEffortValue ThinkingMinimal = "low"` in both
`baikai-claude/src/Baikai/Provider/Claude/Agent.hs` and `.../Interactive.hs`. Two of these are
not effort-mapping at all but budget and capability interactions. EP-7's strict mode must cover
all six.

**The OpenAI-native effort path looks buggy and is not; the doc comment is what is stale.**
`ThinkingFormatOpenAI` forwards `renderThinkingLevel` verbatim (`OpenAI/Shape.hs:96`), so
`ThinkingXHigh` and `ThinkingMax` put the literal strings `"xhigh"` and `"max"` into the native
`reasoning_effort` field, while every other shape routes through `compatibleEffort` and clamps
both to `"high"`. The first review of IR-3 called this a live wire bug on the strength of that
constructor's Haddock in `baikai/src/Baikai/Compat.hs`, which lists the native vocabulary as
`minimal | low | medium | high`, and this MasterPlan originally instructed EP-4 to clamp.

That was wrong, and the code contradicts it twice. `compatibleEffort`'s own docstring scopes it to
the "non-native OpenAI-compatible request shapes", so the native path's exclusion is documented as
deliberate. And `baikai-openai/test/ShapeSpec.hs` carries a test group named "native OpenAI higher
reasoning effort" whose two cases, "xhigh survives SDK staging" and "max survives SDK staging",
assert the values reach the wire unmodified against `Models.openai_gpt_5_6_terra` — sitting
directly beside a companion test asserting a DeepSeek model clamps `max` to `high`. The
distinction is intentional, contrasted, and guarded.

The lesson is worth keeping: a doc comment is a record of what someone believed when they wrote
it, and a named test is a record of what someone decided. When they disagree, the test wins. Had
the clamp been implemented, it would have silently weakened every `xhigh` and `max` request
against a current OpenAI model — the precise failure mode this initiative exists to eliminate.
EP-4 now corrects the comment, changes no behaviour, and records an empty adjustment list on the
native path because that path genuinely expresses every level exactly.

**The trace path already loses evidence that the cost log keeps.** `CallFinished` carries only
`inputTokens` and `outputTokens`, while `CallLogEntry` in `Baikai.Cost.Log` also keeps
`cachedInputTokens` and `reasoningTokens` (`baikai/src/Baikai/Trace.hs:340`). Worse, `usd` is
suppressed entirely when the computed cost is zero (`Trace.hs:273`), so "the call cost nothing"
and "the cost is unknown" are indistinguishable in a trace. That elision directly contradicts
IR-3's requirement that absent metadata remain absent, so EP-2 must establish an explicit
non-elision rule for the evidence path.

**Response-header capture is much cheaper than IR-3 assumes.** The request says API providers
should capture server metadata "before the SDK or stream adapter discards it". Baikai does not
use the vendor SDKs' HTTP path at all: it runs its own SSE transport through
`HTTP.withResponse` in `baikai-claude/src/Baikai/Provider/Claude/Sse.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Sse.hs`, and already reads `responseHeaders` there to
parse `Retry-After`. Capturing a correlation header is available at that exact point. The only
obstacle is that the event callback has type `Either BaikaiError Event -> IO ()`, which has no
slot for once-per-response metadata; widening that callback is the whole change.

**The Claude CLI provider already parses the identifier it then throws away.** `ClaudeCliResult`
in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` decodes a `session_id` field, and
`mkResponse` a few lines later hardcodes `responseId = Nothing`. The Codex CLI provider is
further behind: `parseCodexJsonlStream` in `baikai/src/Baikai/Provider/Cli/Internal.hs` filters
the entire event stream down to `agent_message` payloads and discards the thread identifier and
token counts entirely.

**The unattended agent surface has no observability of any kind.** A grep for `Trace`, `TraceSink`,
or `CallLog` across `baikai-agent/src` and `baikai-kit/src` returns nothing. `AgentRunResult`
carries a provider, an exit code, two captured output streams, and a duration — no usage, no
identifiers, no model. EP-6 is building an evidence path where none exists, which is why it is
sized as its own plan rather than treated as an extension of EP-5.


### Found while implementing EP-1

These four affect what later plans must do, so they are recorded here as well as in
[docs/plans/51](../plans/51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md).

**`ModelCallEvidence` is `ToJSON`-only, and every later plan must read emitted evidence as a
plain `Aeson.Value`.** `Baikai.Usage.Usage` embeds `Baikai.Cost.Cost`, whose exact `Rational`
amounts encode through an approximating `Scientific` (`ratToSci = fst .
fromRationalRepetendUnlimited`, `baikai/src/Baikai/Cost.hs:84`). A `FromJSON` would decode to a
different value than was encoded. EP-2 through EP-7 must not write one, and their tests should
assert against decoded `Value` fields rather than against a Haskell mirror of the record — which
is the better test anyway, because the JSON is the actual contract Shikigami pins against.

**`EndpointIdentity.baikaiVersion` has no source yet, and EP-2 owns choosing one.** EP-1 defines
the field but does not wire up a `Paths_baikai` autogen module, because the version string is
needed by adapters in five packages and deciding where it comes from is a transport-layer
concern rather than a vocabulary one. EP-2 must resolve it once and centrally. If each adapter
hardcodes a literal instead, the field becomes a lie the first time one of them is not updated
during a release.

**Bare field selectors on the evidence types are ambiguous; use the `generic-lens` labels.**
`ModelCallEvidence` and `EvidenceRequest` both carry `runId`, `attempt`, and `supersedes`, which
is correct — they are the same three facts travelling from caller into record, and the
repository's convention forbids prefixing a field with its record's name. Under
`DuplicateRecordFields`, GHC 9.12 rejects `runId r` as an ambiguous occurrence rather than
resolving it by type. Provider adapters should write `req ^. #runId`, as the rest of the codebase
does; only code reaching for a bare selector is affected.

**Changing `canonicalEncode` after this point is a schema break, not a fix.** The golden test in
`baikai/test/EvidenceSpec.hs` pins both digests of
`baikai/test/fixtures/evidence-request.json` against literal values. If a later plan changes key
ordering, number normalisation, or string escaping, that test fails — and the correct response is
a major bump of `evidenceSchemaVersion`, because every digest recorded by an earlier build
becomes unverifiable. The test's own comment says this. Do not paste a new value over it.


### Found while implementing EP-2

These change what EP-3 through EP-7 must do.

**The evidence builder takes a `Maybe BaikaiError` the plans did not anticipate.**
`Baikai.Evidence.Build.minimalEvidence` and `prepareEvidence` end in
`CallStatus -> Maybe BaikaiError -> …`, not `CallStatus -> …`. `baseEvidence` sets `errorInfo` to
`Nothing` unconditionally, and a failed call's record has to carry one, so the builder had to grow
the argument. `prepareEvidence` is the shape a streaming adapter wants: it does the `IO` half —
the opt-out check and the call identifier — before the first byte comes back and returns a
finaliser the adapter applies at the terminal, keeping the translator pure. EP-3 and EP-4 should
use it; EP-5 and EP-6 should use `minimalEvidence`, whose outcome is known by the time it is
called.

**A `CallEvidence` event's `eventId` is the trace identifier, not the evidence record's `callId`.**
EP-2's own text said to reuse the evidence identifier "so a reader can join the evidence to its
`call_started` line", and those two halves contradict each other — the trace layer mints its
identifier before dispatch and the adapter mints the evidence's later. All four event kinds for a
call now share the trace identifier, and the `CallEvidence` event is what ties the two namespaces
together. No later plan should try to make them equal; the only way to do that is to inject the
trace identifier into `Options`, which the Decision Log rejects.

**`usage` is still `Unobserved` after EP-2, and EP-3/4/5 own it.** This MasterPlan's Progress line
lists usage among what EP-2 supplies, but the field is typed `Observed Usage`, and no assembler
yet tracks whether a provider actually reported a usage figure. Recording `Observed zeroUsage`
because the assembler happens to hold zero is precisely the fabrication the type exists to
prevent. Each provider plan populates it when its transport learns to distinguish a reported zero
from silence.

**Evidence does not reach an OpenTelemetry backend yet, and EP-7 owns the fix.** The sink ends and
removes the span on `CallFinished`/`CallFailed`, and `Baikai.Trace` pushes `CallEvidence` after
them, so the attribute-attaching branch is only reachable from a hand-fed or replayed event
stream. EP-2 followed this MasterPlan's instruction to tolerate the missing span rather than
reorder the events, which is the right call for EP-2's scope — but the consequence is a live gap.
The cheapest fix is to emit `CallEvidence` before the terminal event, which is safe precisely
because no consumer has ever seen a `call_evidence` line.

**Three unconditional behaviour changes have shipped, and the cost one is the loud one.**
`CallFinished` gained `cachedInputTokens`, `cacheWriteTokens`, `reasoningTokens`, and
`totalTokens`; a computed cost of zero is now reported as zero at all three `CallLogEntry`
construction sites and in `CallFinished`; and `FromJSON TraceEvent` is hand-written and refuses a
`call_evidence` line. A cost dashboard that read an absent `usd` as "unpriced" now counts those
calls as costing zero. EP-7's release notes must lead with that.

**A trace line has no `data` wrapper, and evidence field names are snake_case.** Aeson's
`TaggedObject` only uses `contentsFieldName` for a positional constructor, and every `TraceEvent`
constructor has named fields, so a line reads `{"kind":"call_evidence","eventId":…,"evidence":{…}}`.
Inside, the evidence record spells its fields in snake_case and renders absent fields as explicit
`null`, which is the opposite of the trace event's own encoding and is deliberate. Any plan
writing a `jq` filter or a user-facing example must use `.evidence.requested_model`, not
`.data.evidence.requestedModel`.


### Found while implementing EP-3

These change what EP-4 through EP-7 must do.

**A provider plan cannot honestly describe the no-dispatch path, and EP-7 must resolve it.** When
`mapRequest` fails or setup throws, no request is built and no translation exists, so the adapter
emits `noThinkingRequested` — which asserts the caller asked for no thinking level. For a caller
who did set one, that is false. Every honest alternative needs a `ThinkingMode` the vocabulary does
not have: "a level was requested and nothing was dispatched at all" is neither `absent` (no level
was asked for) nor `unsupported` (the transport cannot express it). EP-3 left it alone rather than
extend EP-1's vocabulary unilaterally. EP-4 hits the identical case and should also leave it. EP-7
owns pre-dispatch refusal and is where the decision belongs; if it adds a mode, EP-1's plan file
and this MasterPlan's Integration Points must be updated in the same change.

**Test a replayed call by replacing only the socket, not the provider.** EP-3's end-to-end test
runs through `claudeMessagesStreamWith`, a seam that swaps just the function opening the HTTP
connection, so the request mapper, SSE decoder, header allow-list, assembler, evidence builder,
trace layer, and sink under test are all the real ones. The rejected alternatives were a local HTTP
server, which needs a dependency and tests the socket rather than the evidence, and a fake
`ApiProvider`, which proves only that the test's own evidence assembly works. EP-4 should copy the
seam rather than invent a second technique; EP-5 and EP-6 spawn subprocesses and need something
different.

**`usage` is now populated on the Anthropic path, and the mechanism generalises.** The assembler
carries a `usageReported` flag set when a provider event actually carried token counts, so a
reported zero is distinguishable from silence and a failed call reports `"unobserved"` rather than
claiming the provider said it consumed nothing. EP-4, EP-5, and EP-6 each need the equivalent flag;
none of them can just read whether their accumulator happens to be zero.

**Derive a translation's adjustments from the mapping function, never from a table beside it.**
EP-3's `adaptiveAdjustments` reads what `adaptiveEffort` produced and compares it with
`renderThinkingLevel`, so a `Nothing` becomes `EffortOmitted` and a differing word becomes
`EffortClamped`. EP-4 faces seven wire shapes and the same temptation to hand-write a second table;
a table that must be kept in agreement by hand is exactly the failure this initiative exists to
eliminate.

**Response-header capture is an allow-list whose order is also the preference order.** EP-3
established `request-id`, then `x-request-id`, then `cf-ray`, with the adapter taking the first
present. EP-4 should match that spelling and that rule for the OpenAI-compatible hosts rather than
maintaining a separate preference list. `ResponseMetadata` also carries the HTTP status, which no
field of `ModelCallEvidence` currently holds; EP-7 may want one.

**A tasty `--pattern` that matches nothing reports "All 0 tests passed".** EP-3's documented
verification command initially selected zero tests and reported success. Every later plan in this
MasterPlan documents a `--pattern` command; check the run actually selected tests, because the
failure mode is indistinguishable from a pass.


### Found while implementing EP-4

These change what EP-5 through EP-7 must do.

**Four evidence helpers are now duplicated verbatim in two provider packages, and EP-7 should
consolidate them.** `observeAnthropic`/`observeOpenAI`, `anthropicStrength`/`openaiStrength`,
`observedUsage`, `responseCommitment`, and `correlationId` differ between
`baikai-claude/src/Baikai/Provider/Claude/Api.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` only in the package version they read and the
assembler they project. Two copies were not worth abstracting over; EP-5 adds two more transports,
and at four the duplication becomes the kind of thing that drifts. `Baikai.Evidence.Build` already
owns the construction side of the same record and is the natural home. EP-5 should not invent a
third spelling, and EP-7 is the first plan positioned to see every transport at once.

**Both API transports spell the response-commitment envelope identically by hand.** It is
`{"content": …, "stop_reason": …, "usage": …}` in both, so a verifier holding a response can
recompute the digest without knowing which provider served it. Nothing enforces that agreement
today beyond a comment in each module; whoever writes the shared helper above should own the
envelope shape too, and EP-5's subprocess transports need a deliberate answer rather than a third
guess.

**The no-dispatch infidelity EP-3 found is confirmed on the second transport.** When `mapRequest`
fails, `immediateError` emits `noThinkingRequested` — which asserts the caller asked for no
thinking level — even for a caller who set one. EP-4 left it alone for the reason EP-3 gave. Two
transports now share it and EP-5 will make it four, which strengthens the case for EP-7 resolving
it centrally rather than each provider inventing a workaround. Extending EP-1's `ThinkingMode` is
still the only honest fix, and still not a provider plan's decision.

**EP-4's most valuable test is the one its plan listed last.** Replaying the same call against a
`ThinkingFormatZai` host at `ThinkingLow` and at `ThinkingMax` produces byte-identical request
bodies and two evidence records that differ. Every other case proves a field is populated; that one
demonstrates why the whole record exists. EP-5 and EP-6 should each look for their own equivalent —
the pair of calls their transport cannot tell apart — rather than only asserting field presence.

**Reading the response identifier was a bug fix, not just an evidence feature.** `Response.responseId`
was permanently `Nothing` on the OpenAI-compatible transport even though every host sends a
top-level `id` on every chunk. It is now populated for every caller, evidence or not, which is the
class of cheap unconditional observation the Decision Log's opt-in gate deliberately excludes from
gating. EP-5 has two known instances of the same shape waiting for it: the Claude CLI session
identifier that is decoded and discarded, and the Codex thread identifier that is filtered out of
the event stream.


### Found while implementing EP-5

These change what EP-6 and EP-7 must do.

**The Codex CLI names no model anywhere, so its evidence can never exceed `EvidenceCorrelated`.**
This is harder than IR-3 or this MasterPlan assumed. `codex exec --json` at 0.146.0 emits exactly
four event kinds — `thread.started`, `turn.started`, `item.completed`, `turn.completed` — and not
one of them carries a model identifier. The only model string anywhere near the call is the one
baikai put on the command line, and recording that would be reporting the request as an
observation. EP-7's strict mode must therefore treat `EvidenceRequired EvidenceModelObserved` as a
*pre-dispatch refusal* for the Codex transport unconditionally, not as something that might
succeed depending on the run. The Claude CLI is the opposite: it names the model that consumed
tokens in its result event's `modelUsage` keys, so it reaches `EvidenceModelObserved` routinely.

**The subprocess transports do not have the no-dispatch translation infidelity EP-3 and EP-4
found.** Both API transports emit `noThinkingRequested` when `mapRequest` fails, falsely asserting
the caller requested no level. A CLI provider's translation is a pure function of `Options`
computed *before* the process is spawned, so a failed launch, a nonzero exit, and an unparseable
result all still carry the real translation. EP-7 owns the fix, and now knows it applies to two of
the four completion transports rather than all four — which also means adding a new `ThinkingMode`
for that case would leave two transports never using it.

**The Claude CLI reports a total cost, and the trace layer does not recompute cost.**
`claude -p`'s result event carries `total_cost_usd`, which EP-5 now carries into `Usage.cost`
exactly, as a `Rational` rather than through a `Double`. Together with the token counts this is the
second unconditional cost-visible behaviour change in this initiative, after EP-2's always-present
zero. `Baikai.Trace` reads `Usage.cost` directly rather than recomputing it from pricing
(`Trace.hs:358` and `:431`), so this reaches every cost consumer immediately. EP-7's release notes
must lead with both together: a dashboard that showed these calls as free now shows real tokens and
a real dollar figure, and totals over historical data will not match totals over new data.

**Codex's `cache_write_input_tokens` has undetermined inclusion semantics.** Its recorded value is
zero, so the recording cannot say whether it is part of the inclusive `input_tokens` total, and
codex's source is not in the local Mori corpus. EP-5 resolved it by subtracting only
`cached_input_tokens` — matching both codex's own non-cached-input arithmetic and this
repository's existing OpenAI normalization — and carrying the cache-write count through unchanged,
on the grounds that an undercount is the worse error for evidence. EP-6 parses the same tool and
should reuse `codexUsage` rather than deciding this again.

**A digest comparison across two calls must hold the executable fixed.** The subprocess request
envelope is the argument vector with the executable first, so two calls through two different
binaries produce different commitment digests for a reason unrelated to what a test is usually
asking about. EP-6 spawns the same tools and will hit this.

**A fake executable used in a test must answer `--version` before doing anything else.** The
evidence path invokes the configured executable a second time to read its version, so a fake that
records its argument vector unconditionally overwrites the recording under test with
`["--version"]`. EP-6 drives fake executables too.

**A live smoke assertion pinned the behaviour EP-5 corrects, and caught it.** `baikai-smoke`
required `usage_zero` for both CLI providers; every fixture test passed while it failed against
the real binaries. It was inverted deliberately rather than deleted, and it now asserts that usage
and the response identifier are reported. EP-6 changes `AgentRunResult`, which `baikai-smoke` also
exercises; check it rather than assuming the unit suites are the whole story.

**A two-second subprocess timeout is load-sensitive in this repository's test runs.** EP-5's
version probe was bounded at two seconds per the plan and failed intermittently when four `cabal
test` suites ran in parallel; individual subprocess cases were observed taking over five seconds.
It is now five. Any later plan bounding a subprocess should pick the bound from "what stops an
infinite hang", not from "what feels fast".


## Decision Log

- Decision: Cover both the API/CLI completion providers and the unattended agent surface, rather
  than only the completion path.
  Rationale: IR-3's acceptance criterion 1 names "Codex CLI and Claude CLI" without saying which
  of Baikai's two disjoint CLI surfaces it means. The consuming use case
  (`mori://shinzui/kikan/okf/use-cases/concepts/UC-8`) and the consuming request
  (`mori://shinzui/shikigami/okf/improvement-requests/concepts/IR-7`) are both about sanctioned
  *agent runs*, and IR-3's own dispatch section asks for "the executable identity and version,
  rendered argument-vector digest", which maps onto `AgentCommand` in `Baikai.Agent`. Covering
  only the completion providers would leave the actual consumer unserved. The cost is one
  additional child plan (EP-6) building a second emission path, because the agent surface shares
  no plumbing with the completion path.
  Date: 2026-08-05

- Decision: Emit two distinct digests — a content commitment over the canonicalized unredacted
  envelope, and a redaction-stable configuration digest — rather than IR-3's single "hash of the
  redacted request envelope".
  Rationale: As written, IR-3 is internally inconsistent. Its Privacy and Integrity section
  implies hashing after redaction, which yields a digest that commits to configuration but not to
  content; its stated purpose is to let Shikigami bind a run to the reviewed artifact, which
  requires a digest that commits to content. Both are useful and they are not the same value. The
  commitment digest leaks nothing on its own and can be verified by anyone who independently holds
  the prompt; the configuration digest is safe to compare across runs that legitimately differ in
  content. Naming them separately makes each one's meaning checkable rather than assumed.
  Date: 2026-08-05

- Decision: In strict evidence mode, a trace-sink failure fails the call. In best-effort mode it
  keeps today's behavior of reporting once on stderr and continuing.
  Rationale: `Baikai.Trace` currently captures sink exceptions in the drain worker and reports
  them on stderr during cleanup (`Trace.hs:242`), so the call succeeds and its evidence is
  silently gone. IR-3's acceptance criterion 4 requires run/call correlation to survive
  trace-sink failure; under today's behavior the *call* survives and the *evidence* does not,
  which is the opposite of what the criterion is for. Evidence that can vanish without the caller
  noticing is not evidence. Best-effort callers are unaffected, so no existing user sees a
  behavior change.
  Date: 2026-08-05

- Decision: **Reversed.** Leave the OpenAI-native `reasoning_effort` mapping exactly as it is, and
  correct the stale `ThinkingFormatOpenAI` Haddock instead.
  Rationale: This decision originally read "clamp `ThinkingXHigh` and `ThinkingMax` to `high` on
  the OpenAI-native path", justified by that constructor's Haddock listing only
  `minimal | low | medium | high` and by every other shape routing through `compatibleEffort`. It
  was reversed on challenge, and the reversal is kept visible rather than edited away because the
  reasoning error is instructive. Two things in the code contradict the original: the helper's
  docstring scopes it to the "non-native" shapes, making the native exclusion deliberate; and
  `baikai-openai/test/ShapeSpec.hs` contains two named guards, "xhigh survives SDK staging" and
  "max survives SDK staging", asserting those values reach the wire intact against a GPT-5.6 model,
  beside a companion test asserting DeepSeek clamps. A stale doc comment was weighed above a
  tested, deliberately contrasted design. Implementing the clamp would have silently weakened
  every `xhigh` and `max` request against a current OpenAI model, which is exactly the class of
  failure this initiative exists to eliminate. EP-4 is now additive on the wire and its acceptance
  requires the existing OpenAI test suite to pass unmodified.
  Date: 2026-08-05 (reversed the same day)

- Decision: Model retry and fallback as caller-supplied provenance (an attempt ordinal and an
  optional parent call id), not as something Baikai observes.
  Rationale: IR-3's requested contract asks for a "retry/fallback relationship" and its
  acceptance criterion 4 asks that correlation survive retries, but Baikai has no retry or
  fallback loop anywhere — `Baikai.Error` classifies retryability and nothing acts on it. The
  only honest options are for the caller to declare the relationship or for Baikai to grow a
  retry loop. The latter is a large piece of unrelated work and is not what IR-3 asks for.
  Date: 2026-08-05

- Decision: Decompose into seven child plans with EP-6 depending only on EP-1.
  Rationale: Seven is the upper bound the MasterPlan specification permits, and the alternative
  groupings were worse: package-shaped plans concentrate five-sevenths of the work in `baikai`,
  and merging the provider plans destroys independent verifiability because their translation
  vocabularies share nothing. Making EP-6 depend only on EP-1 — legitimate, because the agent
  surface touches neither `ApiProvider` nor `TerminalPayload` nor `Baikai.Trace` — lets it run in
  parallel with EP-2 and shortens the critical path from five waves to four.
  Date: 2026-08-05

- Decision: EP-2 lands with every adapter supplying a minimal evidence value rather than gating
  on the provider plans.
  Rationale: The alternative is a long-lived branch where the tree does not compile until all
  three provider plans finish. Landing a minimal but honest evidence value — one whose observed
  fields are all explicitly unobserved — keeps every commit green, keeps the existing test suite
  passing, and matches the initiative's own rule that an unobserved field is recorded as
  unobserved rather than backfilled. The minimal value is not a stub; it is a correct evidence
  record for a transport that has not yet learned to observe anything.
  Date: 2026-08-05

- Decision: Evidence construction is gated on the caller's opt-in. A call whose `Options.evidence`
  is `Nothing` computes no digest, generates no call identifier, probes no executable version, and
  emits no evidence event.
  Rationale: This corrects an error in the decomposition as first written, which had every adapter
  construct a minimal evidence value on every call. That conflated two separate things: EP-2 needs
  every adapter *wired up* so no commit leaves the tree broken, which is about landing order; it
  does not need every adapter to *do the work* on every call, which is about runtime behaviour.
  The two canonical digests each hash the full request envelope, so always-on evidence would
  impose two SHA-256 passes over every prompt, a `/dev/urandom` read, and a trace event several
  times the size of a `call_finished` line, on callers who never asked for any of it. Gating costs
  one branch per adapter and buys a genuinely zero-cost path for every existing user.
  The gate lives inside the shared `minimalEvidence` builder rather than at each adapter's call
  site, so an adapter cannot forget it, and the request-envelope argument is passed lazily so an
  opted-out call never even builds the value it would have hashed.
  Cheap observations stay unconditional, because they are bug fixes independent of evidence: the
  provider-reported model, the response correlation header, the Claude CLI session identifier that
  is currently decoded and discarded, and the CLI token usage currently reported as zero. Each
  costs a lookup and each improves `Response` for every caller. Only work that exists solely to
  serve evidence is gated.
  Date: 2026-08-05

- Decision: Accept the compile-time breakage and the three behaviour fixes, rather than adding
  parallel entry points to preserve every existing signature.
  Rationale: Considered and rejected: keeping `doneTerminal`/`errorTerminal` at their current
  arity with `*WithEvidence` siblings, putting evidence on the existing terminal `TraceEvent`
  constructors instead of adding `CallEvidence`, and adding `*WithMetadata` variants of the SSE
  entry points. Each avoids breaking a downstream consumer, and each leaves the package with two
  ways to do one thing forever. Baikai is at 0.4 with a coordinated major bump already planned in
  EP-7, so the migration is a single well-documented event rather than permanent surface debt. The
  affected consumers are custom provider implementations and custom trace sinks — both deliberate
  extension points, both small in number, and both served by a changelog entry naming the exact
  edit. The three unconditional behaviour changes are all corrections: the CLI providers reporting
  real token usage instead of zero, the always-present zero cost, and the widened call-identifier
  format. The first of those changes what a cost dashboard shows and needs the loudest changelog
  entry of the release. Note that nothing in this initiative changes what any provider receives on
  the wire — an earlier draft would have, via the OpenAI-native effort clamp that was reversed
  above.
  Date: 2026-08-05

- Decision: Split the `ApiProvider` change away from the evidence channel — EP-2 leaves the type
  alone and EP-7 adds `describeThinking` to it.
  Rationale: The two needs are genuinely different. Carrying evidence *back* from a completed call
  is per-call data and belongs on the terminal event, which is why EP-2 widens `TerminalPayload`
  and touches no handler. Refusing a call *before* dispatch requires knowing what a provider would
  do with the request before any request exists, which only a per-handler function can answer.
  Bundling the second into EP-2 would have broken every registration site across three packages
  for a feature EP-2 does not implement, and would have blocked EP-6 — which depends on neither —
  behind a larger change.
  Date: 2026-08-05

- Decision: Defer creating `docs/adr/` to EP-7 rather than seeding it in EP-1.
  Rationale: The repository has no ADR corpus and `mori.dhall` declares no ADR bundle, so
  establishing one is a real decision about repository convention rather than a formality. The
  decisions worth promoting are cross-plan by nature — the observed/requested boundary, adapter
  ownership of translation, the digest contract, the exclusions — and several of them may be
  refined by what the provider plans discover. Writing them once at the end, from the accumulated
  Decision Logs, produces better records than writing them speculatively at the start.
  Date: 2026-08-05


## Outcomes & Retrospective

(To be filled during and after implementation.)
