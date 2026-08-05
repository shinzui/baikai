---
id: 57
slug: enforce-strict-evidence-mode-and-release-the-evidence-surface
title: "Enforce strict evidence mode and release the evidence surface"
kind: exec-plan
created_at: 2026-08-05T20:23:58Z
intention: "intention_01kz9sfq3kekjrfw4278azrm3p"
master_plan: "docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md"
---

# Enforce strict evidence mode and release the evidence surface

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

By the time this plan starts, every one of Baikai's five transports emits a `ModelCallEvidence`
record describing what it requested, what it translated the request into, and what it observed the
provider report back. Each record already carries an honest self-assessment of how much it proves,
in a field called `strength`.

What is still missing is the ability for a caller to *demand* something. A critical workload that
must be able to show which model ran cannot currently express that requirement: it can only run
the call and discover afterwards that the transport it chose reports nothing, or that its
reasoning-effort request was quietly weakened on the way to the wire. By then the work is done and
the money is spent.

This plan adds strict evidence mode: a per-call setting that makes Baikai refuse, **before
dispatch**, to run a call whose transport cannot reach the strength the caller requires or that
would silently downgrade the caller's thinking request. Callers who do not opt in keep today's
behavior exactly, which is the point — strictness is a promotion, not a migration.

Getting this right requires enumerating every place where Baikai currently weakens a request
without telling anyone. There are six such places across three packages, and only three of them
are effort-mapping at all; the rest are model-capability and token-budget interactions that a
caller reading their own request would never spot. The three provider plans made each one visible
in the evidence. This plan makes each one refusable.

This plan also finishes the initiative: it writes the user guide, gives existing trace and cost
consumers a migration path that does not let them mistake this evidence for a claim about
provider internals, establishes the repository's first Architecture Decision Records, and
coordinates the release across five packages.

After this plan, someone can write:

```haskell
let opts = emptyOptions
      & #thinking .~ Just ThinkingMax
      & #evidence .~ Just (evidenceRequest "run-42"
          & #strictness .~ EvidenceRequired EvidenceModelObserved)
```

and be certain that the call either produces a record naming the model that ran, or fails before
spending anything, with an error saying exactly which requirement the chosen transport could not
meet.


## Progress

- [ ] Implement the pre-dispatch strictness check and its error type.
- [ ] Enumerate and cover all six downgrade sites in the check.
- [ ] Publish each transport's declared maximum evidence strength.
- [ ] Make strict mode fail the call on trace-sink failure; leave best-effort unchanged.
- [ ] Add the strict-mode flag to `baikai agent run`.
- [ ] Write `docs/user/model-call-evidence.md`.
- [ ] Write the migration guidance for existing trace, cost-log, and OpenTelemetry consumers.
- [ ] Create `docs/adr/` and promote the initiative's durable decisions.
- [ ] Update the IR's status and the improvement-request log.
- [ ] Compute per-package version bumps and prepare the coordinated release.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: In strict evidence mode, a trace-sink failure fails the call. Best-effort mode keeps
  today's behavior of reporting once on stderr and continuing.
  Rationale: `baikai/src/Baikai/Trace.hs` currently captures sink exceptions in its drain worker
  and reports them on stderr during cleanup, so the call succeeds and its evidence is silently
  gone. IR-3's acceptance criterion 4 requires run and call correlation to survive trace-sink
  failure; under today's behavior the *call* survives and the *evidence* does not, which is the
  opposite of what the criterion is for. Evidence that can vanish without the caller noticing is
  not evidence. No existing caller is affected, because best-effort is the default and is
  unchanged.
  Date: 2026-08-05

- Decision: The strictness check runs before dispatch and refuses, rather than running after and
  annotating.
  Rationale: IR-3 asks for exactly this and the reason is economic: a caller who requires observed
  evidence and cannot get it wants to know before paying for the call, not after. A post-hoc
  annotation would also be unenforceable, since the caller has already received the answer and
  will use it.
  Date: 2026-08-05


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. This plan
touches `baikai/`, `baikai-claude/`, `baikai-openai/`, `baikai-agent/`, and `baikai-trace-otel/`,
plus the documentation tree. From the repository root, `cabal build all` compiles everything and
`cabal test all` runs every suite. `cabal test all` includes `baikai-smoke`, which exercises live
providers when credentials or CLI binaries are present and skips them otherwise; a skip is not a
failure.

Record fields never carry the record's name as a prefix, `DuplicateRecordFields` is on, field
access goes through `generic-lens` overloaded labels, the language is GHC2024, every `deriving`
clause must name its strategy explicitly, and every module needs an explicit export list.

### What the preceding six plans built

Read the MasterPlan at
[docs/masterplans/9](../masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md)
first; it is the map. In brief:

[docs/plans/51](51-add-the-model-call-evidence-vocabulary-and-canonical-hashing-core.md) created
`baikai/src/Baikai/Evidence.hs` holding `ModelCallEvidence` and everything in it: the `Observed`
type whose `Unobserved` constructor is a positive statement that the provider reported nothing;
`ThinkingTranslation` with its `ThinkingMode` and its list of `ThinkingAdjustment` values;
`EvidenceStrength`, an ordered four-constructor enumeration from `EvidenceRequestedOnly` through
`EvidenceCorrelated` and `EvidenceModelObserved` to `EvidenceFullyObserved`; and
`EvidenceRequest`/`EvidenceStrictness`, which plan 51 also wired into `Baikai.Options` as an
`evidence :: Maybe EvidenceRequest` field. That field currently has no enforcement behind it —
supplying `EvidenceRequired` today changes nothing. Giving it teeth is this plan's first job.

[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) added the
evidence slot to `TerminalPayload` and `Response`, added the `CallEvidence` constructor to
`TraceEvent`, and left a deliberate hook for this plan:

```haskell
onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
```

whose only implementation today is the existing stderr report.

[docs/plans/53](53-emit-anthropic-messages-api-call-evidence.md),
[docs/plans/54](54-emit-openai-compatible-api-call-evidence.md), and
[docs/plans/55](55-emit-claude-and-codex-cli-completion-provider-evidence.md) taught the four
completion transports to observe, each ending in a named strength function —
`anthropicStrength`, `openaiStrength`, `subprocessStrength`.
[docs/plans/56](56-emit-unattended-agent-run-evidence.md) built the parallel path for the
unattended agent surface.

### The six downgrade sites, which are the substance of this plan

These were enumerated by reading the code, and each provider plan made each one visible in the
evidence as a `ThinkingAdjustment`. This plan makes each one refusable. Two are not effort
mappings at all, which is why "check the translation table" is not a sufficient implementation.

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, `computeThinking` drops the
thinking configuration entirely when the chosen model does not advertise reasoning support,
recorded as `ThinkingDroppedUnsupportedModel`.

In the same file, `mapRequest` discards an already-computed thinking plan when the model's output
ceiling clamps the sum of requested output tokens and thinking budget down to at or below the
budget itself, recorded as `ThinkingDroppedBudgetExceeded`. This is the least discoverable of the
six: a caller changed a max-tokens setting and silently lost thinking.

In `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs`, the `ThinkingFormatNone` branch drops the
option because the host exposes no reasoning control, recorded as
`ThinkingDroppedUnsupportedHost`; and `compatibleEffort` clamps `minimal` up to `low` and both
`xhigh` and `max` down to `high`, recorded as `EffortClamped`.

Also in that file, the `ThinkingFormatZai` and `ThinkingFormatQwen` branches express no depth at
all, so every level collapses to a bare on/off toggle, recorded as `EffortCollapsedToToggle`. A
caller asking for `max` and a caller asking for `low` produce byte-identical requests on those
hosts.

**`ThinkingFormatOpenAI` is deliberately not on this list.** The native path sends every canonical
level verbatim and expresses all six exactly, so it produces no adjustment and strict mode must
never refuse it. This is worth stating because the native path *looks* like a seventh downgrade
site next to the six above — a reviewer of IR-3 initially read it as one, on the strength of a
stale doc comment — and a strict-mode implementation that refuses a native `xhigh` request would
be rejecting the one OpenAI-compatible configuration that honours the caller in full. See
[docs/plans/54](54-emit-openai-compatible-api-call-evidence.md)'s Decision Log for the evidence
that the native behaviour is intentional and test-guarded.

In `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`, `adaptiveEffort` returns
`Nothing` for `ThinkingHigh`, so the request carries no effort field and is indistinguishable on
the wire from the provider's default depth, recorded as `EffortOmitted`.

And in `baikai-claude/src/Baikai/Provider/Claude/Cli.hs` and
`baikai-claude/src/Baikai/Provider/Claude/Agent.hs`, `claudeEffortValue` collapses `minimal` to
`low` because the tool's `--effort` flag has no `minimal`, recorded as `EffortClamped`.

### Terms used in this plan

**Strict evidence mode** is the caller-selected requirement that a call produce evidence of at
least a stated strength, enforced by refusing to dispatch otherwise. A **downgrade** is any case
where what went on the wire expresses less than what the caller asked for. **Declared strength**
is the maximum strength a transport can reach under ideal conditions, which is a static property
of the transport, as distinct from the strength an individual call achieved. **PVP** is the
Haskell Package Versioning Policy, `A.B.C.D`, under which the first two components together form
the major version.

### ADR context

This repository has no `docs/adr/` directory. The `mori.dhall` manifest declares exactly one OKF
bundle — `improvement-requests` at `docs/improvement-requests`, with the profile
`mori/improvement-requests-profile.dhall` — and `mori show --full` reports zero ADR bundles. So
there is no ADR corpus, no profile to validate against, and no allocated `ADR-N` handle to
preserve.

**This plan creates the corpus.** Follow `agents/skills/exec-plan/ADR.md` exactly, and note its
conditional: when no profiled bundle exists, preserve the repository's established filesystem
convention rather than inventing OKF frontmatter as an incidental plan edit. Since there is no
established ADR convention here either, this plan makes one, and the choice is itself worth
recording. The Plan of Work below states what to do.

### What this plan depends on

Hard dependencies: all five emitting plans —
[52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md),
[53](53-emit-anthropic-messages-api-call-evidence.md),
[54](54-emit-openai-compatible-api-call-evidence.md),
[55](55-emit-claude-and-codex-cli-completion-provider-evidence.md), and
[56](56-emit-unattended-agent-run-evidence.md) — must be complete. Strict mode's contract is
"refuse a transport that cannot meet the caller's requirement", and that sentence cannot be
specified, let alone tested, until every transport's real strength is known and every downgrade is
recorded.


## Plan of Work

Four milestones: enforcement, sink policy, documentation and durable records, and release.

### Milestone 1: pre-dispatch enforcement

At the end of this milestone a strict caller gets a refusal instead of a call, and every one of
the six downgrade sites triggers it.

Two things must be checkable before dispatch: whether the transport *can* reach the required
strength, and whether this specific request *would* be downgraded. The second is already
computable — the thinking translation is built during request preparation, before anything is
sent. The first needs a new static declaration, because a strength is otherwise only known after a
call completes.

Add to `Baikai.Evidence`:

```haskell
-- | The highest strength a transport can reach when everything goes
-- well. This is a static property of the transport, not a claim about
-- any particular call: a transport that declares
-- 'EvidenceModelObserved' still produces 'EvidenceRequestedOnly' for a
-- call that failed before the provider said anything.
--
-- Declaring more than a transport can deliver is the one way to make
-- strict mode lie, so each declaration must be justified by a test that
-- actually reaches it.
declaredStrength :: Api -> EvidenceStrength
```

Base it on the `Api` tag, which is what the registry already dispatches on. From what the provider
plans established: `AnthropicMessages` and `OpenAIChatCompletions` declare
`EvidenceModelObserved`, since neither provider echoes its thinking configuration and
`EvidenceFullyObserved` is therefore unreachable on both. `AnthropicMessagesCli` and
`OpenAICompletionsCli` declare whatever plan 55's fixtures actually proved — read that plan's
Surprises & Discoveries for what the installed tools report, and if a tool reports a model then
`EvidenceModelObserved` is justified, otherwise declare `EvidenceCorrelated`. `Custom` declares
`EvidenceRequestedOnly`, because Baikai knows nothing about a caller-supplied transport.

Do not guess any of these. Each declaration needs a test that drives the transport to that
strength; a declaration without one is exactly the lie the Haddock warns about.

Then add the check itself, in `Baikai.Evidence.Build`:

```haskell
-- | Why a strict call was refused before dispatch.
data EvidenceRefusal
  = -- | The transport's declared maximum is below what the caller
    --   required. Carries the required strength and the declared one.
    StrengthUnreachable !EvidenceStrength !EvidenceStrength
  | -- | The request would reach the wire expressing less than the
    --   caller asked for. Carries every adjustment that would apply.
    ThinkingWouldDowngrade ![ThinkingAdjustment]
  deriving stock (Eq, Show, Generic)

renderEvidenceRefusal :: EvidenceRefusal -> Text

-- | The pre-dispatch gate. Returns every reason the call must not
-- proceed, or an empty list when it may. Under 'EvidenceBestEffort'
-- this always returns an empty list.
checkEvidenceRequirements ::
  EvidenceStrictness -> Api -> ThinkingTranslation -> [EvidenceRefusal]
```

Collect every reason rather than returning the first, matching what
`Baikai.Agent.applyAgentCeiling` already does for policy violations and for the same reason: an
operator fixing a configuration should see all of it in one run.

Take the translation lazily, and short-circuit on strictness before forcing it. A caller who set
no evidence request, or who set `EvidenceBestEffort`, must never cause `describeThinking` to run:
the gate has nothing to decide for them, and calling a provider's translation function on every
dispatch to then discard the result would put a cost on the default path for a feature only strict
callers use. Structure the function so the `EvidenceBestEffort` branch returns `[]` without
touching its third argument, and give the parameter no strictness annotation. This mirrors the
same discipline
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) applies to
the request envelope in `minimalEvidence`, and for the same reason.

At the two dispatch sites, wrap the whole gate — including the `describeThinking` call that feeds
it — so it is skipped entirely when `Options.evidence` is `Nothing`. That is the common case and it
should cost one `Maybe` test.

The downgrade rule needs one judgement stated explicitly in the Haddock, because it is not
obvious. `ThinkingModeAbsent` — the caller requested no level at all — is never a downgrade;
there is nothing to weaken. But every non-empty `adjustments` list is, including
`EffortOmitted`, which is the subtlest: the request is *not* weaker in effect, it is merely
indistinguishable on the wire from the default. A caller who demanded strict evidence and gets a
request they cannot later prove asked for `high` has not got what they demanded, so refuse.

Wire the gate into the two dispatch points. In `Baikai.Stream.streamRequestWith`, after the
provider is looked up and before its stream is returned, run the check and, on refusal, return a
one-event error stream carrying a `BaikaiError` built from the refusals. In
`Baikai.Provider.Registry.completeRequestWith`, do the same and return an error-shaped `Response`.
Both paths already have exactly this shape for the no-provider-registered case, so follow it.

The thinking translation is built inside each provider's request preparation, which happens after
dispatch — so the gate needs the translation earlier. The cleanest way that does not restructure
every provider: give `ApiProvider` a fourth field carrying a pure translation function.

```haskell
data ApiProvider = ApiProvider
  { apiTag :: !Api,
    stream :: !(Model -> Context -> Options -> Stream IO AssistantMessageEvent),
    complete :: !(Model -> Context -> Options -> IO Response),
    -- | Describe, without sending anything, what this provider would do
    -- with the caller's reasoning-effort request. Used by the
    -- pre-dispatch strictness gate, which must be able to refuse before
    -- any request is built or sent.
    describeThinking :: !(Model -> Options -> ThinkingTranslation)
  }
```

This is a breaking change to a public type and to every registration site, which is why
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md) deliberately
left `ApiProvider` alone: the channel for evidence did not need it, and this gate does. Each
provider's implementation is a one-liner calling the translation function that plan already built.
Record this in the Decision Log as a deviation from plan 52's stated non-change, with this reason.

The tests belong in a new `baikai/test/StrictEvidenceSpec.hs`, wired into `baikai/test/Main.hs`,
plus per-provider cases in each vendor package. Cover, at minimum: a best-effort caller is never
refused, for every transport and every level — this is the "no existing caller is affected"
guarantee and it deserves to be exhaustive; a caller requiring `EvidenceModelObserved` against a
`Custom` transport is refused with `StrengthUnreachable`; and each of the six downgrade sites,
driven to a refusal carrying the specific `ThinkingAdjustment` that site produces. Six separate
tests, named for their sites, not one parameterised test — when one breaks later you want its name
to tell you which site regressed.

Add one test proving the refusal is genuinely pre-dispatch: point a provider at a base URL that
would fail loudly if contacted, request strict evidence it cannot satisfy, and assert the refusal
arrives with no connection attempted.

### Milestone 2: sink-failure policy

At the end of this milestone a strict caller learns when their evidence could not be written.

Implement the `onSinkFailure` hook plan 52 left. Under `EvidenceBestEffort`, keep the existing
behavior exactly: report once on stderr during cleanup and let the call succeed. Under
`EvidenceRequired`, the call must fail with a `BaikaiError` naming the sink failure.

The mechanics need care, because `baikai/src/Baikai/Trace.hs` deliberately isolates sink failures
from the call: the sink runs on a forked drain worker, its exception is captured into an `IORef`,
and `finalizeTrace` reads that `IORef` during cleanup under `Stream.finallyIO`. To fail the call,
the strict path must surface that captured exception into the stream's terminal event rather than
only onto stderr. Read the whole trace module before touching it — the interaction between the
`closed` and `terminalSent` `IORef`s is what makes the existing exactly-once guarantee hold, and
the tests plan 52 wrote for the five termination cases are what will catch you if you break it.

Test that a strict call whose sink throws returns an error-shaped `Response`, that a best-effort
call whose sink throws returns a normal `Response` and writes to stderr, and that neither emits
two terminal records.

### Milestone 3: documentation and durable records

At the end of this milestone the surface is explained, existing consumers know what to do, and the
initiative's durable decisions have a home outside the plans.

Write `docs/user/model-call-evidence.md`, following the style of the existing guides in
`docs/user/` — read `docs/user/prompt-caching.md` for a good short one and
`docs/user/unattended-agent-runs.md` for a good long one. It must cover: what an evidence record
is and what a caller does to get one; the requested-versus-translated-versus-observed split and
why an unobserved field is never backfilled; what each of the two digests proves and, just as
importantly, what neither proves; the strength enumeration and each transport's declared maximum,
with the plain statement that no current transport reaches `EvidenceFullyObserved` because no
provider echoes its thinking configuration; strict mode, with a worked example of a refusal; and
an explicit scope statement.

That scope statement is the most important paragraph in the document and it should be blunt:
Baikai reports what it requested, what it translated, and what it observed at its own boundary. It
does not sign anything. It does not know what happened inside a provider. It has no opinion about
which models are sanctioned. A trace record is evidence in the sense that a well-kept logbook is
evidence — it is a contemporaneous record by a party with no independent knowledge of the other
side. Anyone presenting it as more than that is misrepresenting it.

It must also state, plainly and early, what evidence costs a caller who does not want it: nothing
at runtime. No digest is computed, no call identifier generated, no executable version probed, and
no evidence event emitted unless the caller sets the `evidence` field in `Options`. Say this in the
guide rather than only in the plans, because the first question a careful reader of a library
asks about a feature like this is what it costs them to ignore it.

Then write the migration guidance, as a section in the same document. It has to be honest that
this release does break things, and precise about what. Start with the summary: a caller who
never mentions `Baikai.Evidence` sees no runtime cost and no behavioural change beyond the four
corrections listed below, but a caller who implements a custom provider or a custom trace sink has
edits to make. Then three existing consumer kinds need detail. A `TraceSink` consumer pattern-matching exhaustively on `TraceEvent` now sees a
fourth constructor and must handle or ignore it; the new `CallFinished` token fields are additive
and a consumer reading only `inputTokens` and `outputTokens` is unaffected, but a consumer that
inferred "cost unknown" from an absent `usd` field must stop, because a zero cost is now reported
as zero. A `Baikai.Cost.Log` consumer is unaffected in shape. A `baikai-trace-otel` consumer gains
new span attributes and loses nothing. Say all of this concretely, naming the fields.

Now the ADRs. Create `docs/adr/` and, following `agents/skills/exec-plan/ADR.md`, use a plain
filesystem convention rather than inventing OKF frontmatter — the guide is explicit that a
profiled bundle should not be created as an incidental plan edit, and `mori.dhall` declares none.
Use `docs/adr/NNNN-slug.md` with a short frontmatter block carrying `title`, `status`, and `date`,
and record the choice of convention in the first ADR so the next person does not have to guess.
If you decide the repository should instead adopt the shared
`documentation.architectureDecisions` OKF profile, that is a legitimate call, but it is a separate
piece of work with its own migration and its own `mori.dhall` edit — say so in the Decision Log
rather than doing it here.

Promote at least these four, distilled from the seven plans' Decision Logs, Surprises &
Discoveries, and Outcomes sections:

The requested-versus-effective-versus-observed split, and the rule that an unobserved field is
never backfilled from the request. Include why `Observed` is a distinct type rather than `Maybe`.

The boundary that a provider adapter owns the description of what it translated, and no downstream
layer may re-derive it. Include the concrete reason: re-deriving in a sink would require
reimplementing `computeThinking`, `injectThinkingShape`, and the per-host compat lookup, and would
silently diverge the first time a translation changed.

The two-digest contract: what a commitment proves, what a configuration digest proves, and why
IR-3's single "digest of the redacted request envelope" was insufficient for both purposes.

The deliberate exclusions: Baikai does not sign run attestations, does not hold sanctioning
policy, does not claim knowledge of provider internals, and does not own retries. Name where each
of those responsibilities does live.

Finally, update the improvement request. Set the `status` field in
`docs/improvement-requests/capture-verifiable-model-call-evidence.md`'s frontmatter to
`completed`, and add a Completion entry to `docs/improvement-requests/log.md` following the format
of the IR-1 completion entry already there: what was built, across which plans, which acceptance
criteria are proved and how, and what remains outside the request. Note explicitly which of IR-3's
seven acceptance criteria were met as stated and which were met in a modified form the review
agreed — the two-digest split and the caller-supplied retry provenance are both deliberate
deviations and the log is where they are recorded.

### Milestone 4: the coordinated release

At the end of this milestone the changed packages are versioned, tagged, and published.

Follow `agents/skills/release/SKILL.md`, which owns the process; this plan owns only the decisions
specific to this initiative. Run its pre-flight dependency check first — it verifies that
`cabal.project` has no GitHub package pins and that Hackage has versions satisfying the streamly
and settei bounds — before anything else.

Five packages changed: `baikai`, `baikai-claude`, `baikai-openai`, `baikai-agent`, and
`baikai-trace-otel`. Compute each bump from what actually changed in it under PVP, where the first
two components together are the major version. `baikai` broke `TerminalPayload`, `Response`,
`TraceEvent`, and `ApiProvider`, so it takes a major bump. The two vendor packages changed
exported function signatures — `mapRequest`, `shapeRequestBody`, `sseFromResponse`, and both agent
renderers — so they take major bumps too. `baikai-agent` changed `runAgentCommand`'s signature, a
major bump. `baikai-trace-otel` only gained a branch, so it takes a minor bump unless its
dependency bound on `baikai` must widen, which it must — so check whether that alone forces a
major under this repository's convention, and follow whatever the release skill says rather than
deciding fresh.

`baikai-kit` and `baikai-smoke` did not change but depend on packages that did; check whether
their bounds need widening and, if so, whether that is a release or only a bounds edit.

Convert the accumulated `[Unreleased]` changelog entries into dated release headings, one per
package, at this point and not before — the six preceding plans were each instructed to add to
`[Unreleased]` and to create no dated heading, precisely so this step is a single coherent edit.

Publish in dependency order, `baikai` first, as the release skill requires.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout.

Confirm all five prerequisite plans are complete and the tree is green:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
cabal test all
```

Then confirm the prerequisite is real rather than nominal, by checking that every transport
actually emits evidence:

```bash
rg -n 'anthropicStrength|openaiStrength|subprocessStrength' --type haskell
```

Expect hits in `baikai-claude`, `baikai-openai`, and `baikai/src/Baikai/Provider/Cli/Internal.hs`.
If any is missing, the corresponding plan is not done and this one cannot start.

Read the MasterPlan at
[docs/masterplans/9](../masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md)
completely, then each preceding plan's Decision Log and Surprises & Discoveries sections — those
are the raw material for Milestone 3's ADRs and for the completion log entry, and reading them at
the start tells you what actually happened rather than what was planned.

Re-derive the six downgrade sites from the code rather than trusting this document, since the
provider plans may have found more:

```bash
rg -n 'ThinkingDropped|EffortClamped|EffortOmitted|EffortCollapsedToToggle' --type haskell src baikai*/src
```

Every distinct construction site is a case strict mode must cover. If the count is not six, the
extra sites are a discovery and belong in this plan's Surprises & Discoveries.

Work through the four milestones, committing after each with all three trailers:

```text
Refuse a strict evidence call before dispatch

Add declaredStrength per transport and a pre-dispatch gate that
collects every reason a strict call must not proceed, covering all six
sites where baikai currently weakens a thinking request silently.

MasterPlan: docs/masterplans/9-verifiable-model-call-evidence-at-the-provider-boundary.md
ExecPlan: docs/plans/57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md
Intention: intention_01kz9sfq3kekjrfw4278azrm3p
```

After Milestone 1, see a refusal for yourself:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal repl baikai
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import Baikai
ghci> import Baikai.Evidence
ghci> let m = mkModel (Custom "unknown-transport") "some-model" "https://example.invalid"
ghci> let o = emptyOptions & #evidence .~ Just (evidenceRequest "run-1" & #strictness .~ EvidenceRequired EvidenceModelObserved)
ghci> r <- completeRequest m (contextOf [user "hi"]) o
ghci> responseError r
```

Expect a `Just` carrying an error whose message names `StrengthUnreachable` and states both the
required and the declared strength — and note that no network connection was attempted, because
the base URL is unresolvable and the call returned anyway.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and `cabal test all` passes.

A caller requiring `EvidenceModelObserved` on a transport that declares less is refused before
dispatch, with an error naming both strengths. Proved additionally by pointing the model at an
unresolvable base URL and observing the refusal without a connection attempt.

Each of the six downgrade sites, driven individually, refuses a strict call and reports the
specific `ThinkingAdjustment` that site produces. Six named tests. This is IR-3's acceptance
criterion 5.

A best-effort caller is never refused, for every transport and every reasoning level. This is the
"no existing caller is affected" guarantee and the test must be exhaustive rather than
representative.

The gate does no work on the default path. A provider whose `describeThinking` throws when called
serves a call with `Options.evidence = Nothing`, and a call with `EvidenceBestEffort`, without
raising. That assertion is what keeps the strict-mode machinery off the hot path for the callers
who never use it.

A strict call whose trace sink throws returns an error-shaped `Response`. A best-effort call whose
trace sink throws returns a normal `Response` and reports on stderr. Neither emits two terminal
records — re-run the five termination tests plan 52 wrote and confirm they still pass unchanged.

Every value `declaredStrength` returns is reached by at least one test that drives that transport
to it. A declaration without a corresponding test is the one way strict mode can lie and must not
survive review.

`docs/user/model-call-evidence.md` exists, states the scope boundary explicitly, and gives a
worked strict-mode refusal example that a reader can run.

`docs/adr/` exists and contains the four promoted decisions, each linked from this plan and from
the MasterPlan.

`docs/improvement-requests/capture-verifiable-model-call-evidence.md` has `status: completed` and
`docs/improvement-requests/log.md` carries a Completion entry naming which of IR-3's seven
acceptance criteria were met as stated and which in an agreed modified form.

The release is cut per `agents/skills/release/SKILL.md`, with each changed package's version bump
justified by what changed in it, and published in dependency order with `baikai` first.


## Idempotence and Recovery

Every build and test step is safe to repeat. The documentation and ADR steps are ordinary file
writes.

Two steps are not idempotent and need care. Converting `[Unreleased]` changelog entries into dated
release headings is a one-way edit; do it once, in Milestone 4, and if you need to redo it,
`git checkout -- CHANGELOG.md` and redo from the accumulated entries rather than hand-editing a
half-converted file. Publishing to Hackage is irreversible: a published version cannot be
withdrawn, only deprecated. The release skill's pre-flight check exists for exactly this reason —
run it and believe it.

The riskiest code change is Milestone 2's alteration of the trace module's sink-failure path,
because that module's exactly-once guarantee rests on an interaction between a forked drain worker,
three `IORef`s, and a `finallyIO` cleanup that will not fail loudly when you get it wrong. Run the
trace tests after every edit to that file:

```bash
cabal test baikai --test-options='--pattern Trace'
cabal test baikai --test-options='--pattern Evidence'
```

Adding the fourth field to `ApiProvider` breaks every registration site across three packages. Do
it in a single commit that also fixes every site, so no commit in history leaves the tree
unbuildable. The compiler finds them all.

If Milestone 4's release must be deferred — a dependency is not on Hackage, or a bound cannot be
satisfied — that is not a reason to hold the rest of the plan. Land Milestones 1 through 3, leave
the changelog entries under `[Unreleased]`, mark the release item unchecked in Progress with a note
saying what blocks it, and record the blocker in Surprises & Discoveries. The MasterPlan's own
Progress section should reflect the same split.


## Interfaces and Dependencies

No new package dependencies.

The surface that must exist when this plan is complete:

In `baikai/src/Baikai/Evidence.hs`:

```haskell
declaredStrength :: Api -> EvidenceStrength
```

In `baikai/src/Baikai/Evidence/Build.hs`:

```haskell
data EvidenceRefusal
  = StrengthUnreachable !EvidenceStrength !EvidenceStrength
  | ThinkingWouldDowngrade ![ThinkingAdjustment]
  deriving stock (Eq, Show, Generic)

renderEvidenceRefusal :: EvidenceRefusal -> Text

checkEvidenceRequirements ::
  EvidenceStrictness -> Api -> ThinkingTranslation -> [EvidenceRefusal]

onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
```

In `baikai/src/Baikai/Provider/Registry.hs`, `ApiProvider` gains a fourth field:

```haskell
    describeThinking :: !(Model -> Options -> ThinkingTranslation)
```

and every provider in `baikai-claude` and `baikai-openai` supplies it from the translation function
its own plan already built. This is a deviation from
[docs/plans/52](52-carry-evidence-from-the-provider-adapter-to-the-trace-boundary.md)'s statement
that `ApiProvider` is unchanged; that statement was true for the evidence *channel* and is not true
for the pre-dispatch *gate*, which needs a translation before any request exists. Record the
deviation in this plan's Decision Log and update plan 52's Interfaces section to point here.

In `baikai-agent/src/Baikai/Agent/Cli.hs`, the `agent run` command gains a strict-evidence option
alongside the `--run-id` and `--evidence-file` options that
[docs/plans/56](56-emit-unattended-agent-run-evidence.md) added.

New files: `docs/user/model-call-evidence.md`, `baikai/test/StrictEvidenceSpec.hs`, and the
`docs/adr/` directory with its four records.
