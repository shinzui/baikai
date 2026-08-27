---
id: 65
slug: make-evidence-records-truthful-and-strict-mode-strict
title: "Make evidence records truthful and strict mode strict"
kind: exec-plan
created_at: 2026-08-27T04:00:45Z
intention: "intention_01m10p16mxedft15rjkk2w21g0"
master_plan: "docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md"
---

# Make evidence records truthful and strict mode strict

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Baikai can already emit an **evidence record** for a model call: a JSON document, produced by the
provider adapter that made the call, describing what the caller asked for, what baikai turned that
into on the wire, and what the provider said back. The record's whole value is that a reader can
trust each of those three statements separately. The August review
(`docs/reviews/correctness-and-api-review-follow-up.md`, findings D.1, D.2, D.3, D.7, D.8, D.10,
D.11, C.8 and the Theme H items about evidence ordering) found that on several paths the record
does not tell the truth, and that the mode that is supposed to *guarantee* a record does not.

After this plan the following are true and were not before. A caller who set `#thinking .~ Just
ThinkingMax` and then abandoned the stream, named an unregistered provider, or hit a missing API
key before any request was built, gets a record whose `thinking` field still says `max` — today
those paths all say the caller asked for nothing. A caller who required evidence and used a
provider that attaches no record gets a failed call rather than a silently record-less success. An
OpenTelemetry span carries `gen_ai.response.model` only when the provider reported a model, and
then carries the reported one — today the terminal overwrites it with the requested id. A call
with an empty `baseUrl` records the default host it went to instead of `null`. The response digest
covers the provider's token counts and never baikai's computed cost; a structured-output schema
stays out of the configuration digest as a tool schema already does. The strength rule exists
once, an observed response id counts as correlation, and a custom provider declares its own
ceiling.

You can see the first of those working from `cabal repl` with no credentials and no network:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
rm -f /tmp/baikai-ep8.jsonl
cabal repl baikai
```

```haskell
ghci> :set -XOverloadedStrings
ghci> import Baikai
ghci> import Baikai.Trace
ghci> import Baikai.Trace.Sink
ghci> sink <- fileSink "/tmp/baikai-ep8.jsonl"
ghci> let m = mkModel (Custom "nothing-registered") "test-model" "https://example.invalid"
ghci> let o = emptyOptions & #thinking .~ Just ThinkingMax & #evidence .~ Just (evidenceRequest "run-1")
ghci> _ <- withTrace sink m (contextOf [user "hi"]) o
ghci> :q
```

```bash
jq -c 'select(.kind == "call_evidence") | .evidence.thinking | {requested, mode}' /tmp/baikai-ep8.jsonl
```

Before this plan that prints `{"requested":null,"mode":"absent"}`; after it prints
`{"requested":"max","mode":"not_translated"}`.


## Progress

- [x] M1: `ThinkingModeNotTranslated` (`"not_translated"`) and `untranslatedThinking` in
      `baikai/src/Baikai/Evidence.hs`; `requestedTranslation` in `baikai/src/Baikai/Evidence/Build.hs`.
- [x] M1: the four core adapter-less paths and both providers' `immediateError` stop passing
      `noThinkingRequested`.
- [x] M1: tests — abort, unregistered provider, throwing handler, both `immediateError`s record
      the caller's level.
- [x] M2: `missingEvidenceError`, `requireEvidenceOnTerminal`, `requireEvidenceOnResponse`, wired
      into `streamRequestWith` and `completeRequestWith`; tests for strict, best-effort and error
      paths.
- [x] M2: Haddock and record truth — `Trace/Event.hs` ordering, `Trace.hs` header,
      `docs/capabilities/model-call-evidence.md` lines 32/35/129, `CHANGELOG.md` 0.5.0.0 paragraph.
- [ ] M3: OTel `CallFinished` branch stops setting `gen_ai.response.model`; `successSpanTest`
      rewritten; `observedModelSpanTest` added; `TraceEvent.model` documented as the requested id.
- [ ] M3: `endpointIdentityAt` / `prepareEvidenceAt` / `minimalEvidenceAt`; both adapters pass the
      resolved base URL; default-host tests.
- [ ] M3: `usageEnvelope`; `output_config` and `response_format` summarised; fixture markers;
      golden digests recomputed; `evidenceSchemaVersion` bumped to `2.0`.
- [ ] M4: `deriveStrength`; `anthropicStrength` and `openaiStrength` deleted; `subprocessStrength`
      delegates; response id counts as correlation; tests.
- [ ] M4: `ApiProvider.strengthCeiling`; `checkEvidenceRequirements` takes the ceiling; all
      construction sites and the two guide examples updated.
- [ ] M4: ADRs 0002–0004 revised, ADR 0006 created, README table updated, user guide and
      capability records updated, `okf validate` and the keyless `cabal test all` green.


## Surprises & Discoveries

- EP-3 and EP-4 landed before this plan, so two orientation counts differ from what the plan
  predicted. `rg -n 'describeThinking =' --type haskell --type md` finds 30, not 24 — EP-3 added
  fixtures. And `describeThinkingShape` now takes the model's `reasoning` record as a second
  argument (`describeThinkingShape (openaiCompletionsCompatFor m) (m ^. #reasoning) opts`), which
  is the expression the OpenAI provider's own `describeThinking` field uses, so `immediateError`
  copies that rather than the two-argument form the plan quotes. (M1)

- `TraceSpec`'s own sink-failure case had to change fixture. `strictSinkFailureTest`
  used `registerOk`, a provider that attaches no record, so the moment the record rule
  landed it fired first and the case asserted "the error names the sink" against the
  missing-record error. Its assertion is unchanged and still the point; the fixture is now
  `registerOkWithEvidence`, so the sink is the only reason that call can fail — which is
  what its sibling `strictSinkFailureIsStillOneTerminalTest` already did for the same
  reason. A test meaning to exercise the sink rule must build a record; this is recorded in
  ADR 0014's Consequences. (M2)

- The ADR was written in Milestone 2 rather than Milestone 4, and is numbered `0014`
  rather than `0006` (0006 through 0013 were taken by EP-1 through EP-7). Milestone 2's
  documentation edits — the capability record's Limits and the `[Unreleased]` changelog
  entry — both need to cite it, and a document that links a file which does not yet exist
  is a broken link at that commit. Milestone 4's ADR work is now the three revisions only.
  (M2)

- `traceEvent` needed the registry as well as `finalizeTrace`. The plan named only
  `finalizeTrace`, but `traceEvent` is one of its three call sites and had no registry in scope,
  so both take a `ProviderRegistry` as their first parameter now. Nothing exported changes and
  EP-9's rebase is still a one-line signature edit. (M1)


## Decision Log

- Decision: A caller's thinking level is recorded on every evidence path, and the translation on a
  path where no adapter ran is spelled with a new `ThinkingMode` value, `ThinkingModeNotTranslated`,
  encoded as the JSON string `"not_translated"`.
  Rationale: `docs/adr/0002-requested-translated-observed-are-never-collapsed.md` makes the
  requested level the caller's fact, and `noThinkingRequested` is documented as "the caller set no
  level at all"; using it when the caller set `Just ThinkingMax` is the collapse the ADR forbids
  (REV-2 D.2). No existing mode fits: `absent` means nothing was requested, `unsupported` means an
  adapter looked and could not express the level, and the other four name a wire shape that was
  never built. The snake-case spelling matches `effort_text` and `wire_field`.
  Date: 2026-08-27

- Decision: Adapter-less paths obtain their translation two ways and the core never re-derives
  one. Where a provider is registered — the consumer-abort path in `baikai/src/Baikai/Trace.hs` —
  the core calls that provider's own `describeThinking`. Where none is (unregistered provider, a
  `complete` handler that threw inside `liftCompleteToStream`) it records
  `untranslatedThinking (opts ^. #thinking)`. Both providers' `immediateError` call their own
  describer.
  Rationale: `docs/adr/0003-the-adapter-owns-the-translation-description.md` forbids re-deriving.
  Calling the registered adapter's `describeThinking` is the adapter's own function, and on the
  abort path the adapter did run, so its description is the truthful one; where no adapter exists
  there is nothing to call, and `not_translated` says exactly that.
  Date: 2026-08-27

- Decision: A strict call whose successful terminal carries no record fails with
  `Baikai.Evidence.Build.missingEvidenceError`, built with `providerError` (category `OtherError`)
  and a message beginning `this call required evidence, but the provider attached no evidence
  record`. The check runs at both dispatch points, `Baikai.Stream.streamRequestWith` and
  `Baikai.Provider.Registry.completeRequestWith`, not inside the trace layer.
  Rationale: `ErrorCategory` is documented closed and EP-10
  (`docs/plans/67-freeze-the-public-surface.md`) owns widening it; `sinkFailureError` set the
  precedent of `providerError` with a distinctive message for "baikai's own machinery failed the
  caller", and the two helpers sit side by side so EP-10 can re-categorise both in one edit.
  Enforcing at dispatch gives a `completeRequest` caller with no sink the same guarantee, and the
  trace layer then records `call_failed` with no special case of its own.
  Date: 2026-08-27

- Decision: The pre-dispatch gate does not refuse a `Custom` provider whose ceiling is
  `EvidenceRequestedOnly` when the caller requires exactly that; the record-less case is caught at
  the terminal. On the error path (`EventError` with no record) the provider's error is kept.
  Rationale: a custom provider that builds a `requested_only` record through `minimalEvidence` —
  as `baikai/test/TraceSpec.hs`'s `registerOkWithEvidence` does — is doing the right thing, and
  refusing every custom provider would make strict mode unusable with all of them. Since
  `strengthCeiling` is mandatory, "declares no ceiling" is not representable. The error-path
  choice mirrors `Trace.hs`'s sink-failure decision: overwriting the provider's error loses the
  more useful of the two, and the strict contract — a record exists or the call fails — already
  holds on a failed call.
  Date: 2026-08-27

- Decision: `gen_ai.response.model` is set only by the `CallEvidence` branch of the OpenTelemetry
  sink, from `observedModel`; the `CallFinished` branch stops setting it. `evidenceSpanTest`'s
  semantics win and `successSpanTest` is rewritten to assert absence. `TraceEvent.model` is
  documented as the requested id on every constructor.
  Rationale: REV-2 D.1. hs-opentelemetry's `addAttributes` (`api/src/OpenTelemetry/Attributes.hs`
  in the `iand675/hs-opentelemetry` checkout, `H.insert k … m` per key) replaces an existing key,
  and `Baikai.Trace` pushes `CallEvidence` before the terminal, so the terminal overwrote the
  observed value on every evidence call and labelled the requested id as the response model on
  every other call. `docs/capabilities/opentelemetry-span-export.md` lines 38–40 and 62–64 already
  promise the attribute only when the provider reported a model; the code was wrong, not the record.
  Date: 2026-08-27

- Decision: The evidence endpoint is derived from the base URL the adapter actually resolved, via
  new `endpointIdentityAt`, `prepareEvidenceAt` and `minimalEvidenceAt` that take that URL first.
  The existing three functions become aliases passing `m ^. #baseUrl`; the core adapter-less
  paths keep using the model's field.
  Rationale: REV-2 D.8. Both API adapters substitute `https://api.anthropic.com` or
  `https://api.openai.com` for an empty `baseUrl` inside `prepareCall`, so `sanitizeEndpoint ""`
  produced `endpoint: null` for a call that went to a definite host. The core cannot know a vendor
  default, so where no adapter ran `null` stays truthful. Additive functions keep every caller
  compiling; EP-2 (`docs/plans/59-unify-host-parsing-and-stop-credential-misdirection.md`)
  replaces the parser inside `sanitizeEndpoint` and is unaffected by what is passed to it.
  Date: 2026-08-27

- Decision: `response_commitment` digests the provider-reported token counts only, through a new
  `Baikai.Evidence.usageEnvelope :: Usage -> Value` that omits `cost`, used by both API
  `responseEnvelope`s and by `cliResponseEnvelope`. `evidenceSchemaVersion` becomes
  `baikai.model-call-evidence/2.0`.
  Rationale: REV-2 D.11. `Usage.cost` comes from the caller's catalog rates, so the digest changed
  whenever pricing was edited and a verifier holding only the response could not recompute it. The
  Haddock on `evidenceSchemaVersion` requires a major bump when a field changes meaning;
  `response_commitment` now covers different bytes for the same response and, per the next entry,
  so does `request_configuration` for structured-output requests. A verifier selects rules by
  `schema_version`.
  Date: 2026-08-27

- Decision: A structured-output JSON schema is author-written content wherever it appears, so
  `configurationProjection` summarises `output_config` (every key kept except `format`, which
  becomes its `type` plus a character count) and `response_format` (`type` kept; `json_schema`
  becomes `name`, `strict` and a character count). Recorded as a revision of
  `docs/adr/0004-two-digests-commitment-and-configuration.md`, with fixture markers added.
  Rationale: REV-2 D.7. `tools[].input_schema` was already stripped as content while the same
  kind of schema, with the same `description` strings, survived verbatim through two other keys,
  and the fixture planted no marker there so the redaction test was blind. `effort`, `type`,
  `name` and `strict` are configuration in the sense a tool's name is.
  Date: 2026-08-27

- Decision: One `deriveStrength :: Observed Text -> Observed Text -> Observed Text ->
  EvidenceStrength` in `Baikai.Evidence` (observed model, provider request id, response id) is the
  only strength rule; an observed response id counts as correlation; `anthropicStrength` and
  `openaiStrength` are deleted and `subprocessStrength` delegates. A model observed with no
  identifier of any kind stays `requested_only`.
  Rationale: REV-2 D.10. Three copies had drifted: the subprocess copy counted a session or thread
  id as correlation while the API copies looked only at a captured header, so a host reporting
  `model` and `id` on every chunk but no header landed at `requested_only`, below a host that sent
  only a header. A response id locates the call in the provider's records, which is what
  `EvidenceCorrelated` means. The scale is cumulative by its own Haddock ("in addition to a
  correlation identifier"), so an unlocatable model claim does not climb it; it stays recorded in
  `observed_model`, and no shipped transport produces that combination.
  Date: 2026-08-27

- Decision: `ApiProvider` gains a fifth field, `strengthCeiling :: !EvidenceStrength`, and
  `checkEvidenceRequirements` takes that ceiling instead of an `Api`. Built-in providers set it
  from `declaredStrength`, which stays for the four built-in tags and the agent surface. No base
  value is added here.
  Rationale: REV-2 D.10 and G.1. `declaredStrength (Custom _) = EvidenceRequestedOnly` meant a
  custom transport that observes a model could never satisfy `EvidenceRequired
  EvidenceCorrelated`; only the provider knows its ceiling, and ADR 0003 already put the analogous
  translation description on the same record. A base value is the policy EP-10 sets for every
  evolvable record; adding one here and renaming it there would break third parties twice. The
  break is documented under `[Unreleased]`.
  Date: 2026-08-27

- Decision: `ThinkingAdjustment` is left untouched and open for EP-3
  (`docs/plans/60-make-anthropic-thinking-style-and-sampling-support-catalog-driven.md`) to add a
  sampling-parameter adjustment, its JSON cases and its `describeAdjustment` sentence, recorded in
  both Decision Logs.
  Rationale: nothing here depends on the set of adjustments, only on the list being empty or not,
  so either landing order rebases cleanly.
  Date: 2026-08-27

- Decision: The `TraceSpec` assertion that `CallEvidence` precedes the terminal is not added here;
  `docs/capabilities/model-call-evidence.md` line 35 is corrected to what the suite proves today,
  and EP-9 (`docs/plans/66-make-trace-sinks-unable-to-hang-or-corrupt-a-call.md`, M4) adds the pin.
  Rationale: the MasterPlan assigns the pin to EP-9, and a capability claim must be true at every
  commit.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation. Before marking the plan complete, confirm the three
ADR revisions and ADR 0006 are in place and listed in `docs/adr/README.md`, and that the durable
entries above — the `not_translated` mode, the record-exists rule, the two-digest revision, the
single strength rule and the provider-declared ceiling — have been promoted rather than left here.)


## Context and Orientation

### What this repository is

`/Users/shinzui/Keikaku/bokuno/baikai` is a Haskell repository of eight Cabal packages. `baikai/`
holds every provider-neutral type; `baikai-claude/` and `baikai-openai/` are the providers;
`baikai-trace-otel/` and `baikai-effectful/` are thin bindings; `baikai-agent/` is the unattended
run surface. From the root, `cabal build all` compiles everything and `cabal test all` runs every
suite, including `baikai-smoke`, which skips its live cases without credentials — a skip is not a
failure. Record fields never carry the record's name as a prefix, `DuplicateRecordFields` is on,
field access goes through `generic-lens` labels (`ev ^. #observedModel`), the language is GHC2024,
every `deriving` names its strategy, and every module has an export list.

### Terms used in this plan

An **evidence record** is a `ModelCallEvidence` from `baikai/src/Baikai/Evidence.hs`, encoded with
snake_case keys and explicit `null`s and delivered to a trace sink as one `call_evidence` line per
call. It keeps three facts apart: what the caller **requested** (`requested_model`,
`thinking.requested`), what the adapter **translated** that into (the rest of `thinking`, a
`ThinkingTranslation` whose `mode` names the wire shape and whose `adjustments` list every
downgrade), and what the provider was **observed** to report (`observed_model`, `response_id`,
`provider_request_id`, `usage`, each typed `Observed a` so silence is `"unobserved"` and never a
default). **Strength** is the record's self-assessment, ordered `requested_only < correlated <
model_observed < fully_observed`. The **commitment digest** (`request_commitment`) is SHA-256 over
the canonical encoding of the full request body; the **configuration digest**
(`request_configuration`) is the same over an allow-list projection (`configurationProjection`)
that keeps configuration and replaces content with structural summaries; `response_commitment` is
a commitment over what came back. **Strict mode** is `Options.evidence` set to an
`EvidenceRequest` whose `strictness` is `EvidenceRequired s`; the **pre-dispatch gate**
(`checkEvidenceRequirements` in `baikai/src/Baikai/Evidence/Build.hs`) refuses before dispatch when
the transport cannot reach `s` or the thinking request would be downgraded; **best effort** never
refuses. A **span attribute** is a key/value pair on an OpenTelemetry span. A **terminal** is the
single `EventDone` or `EventError` ending a stream, wrapping a `TerminalPayload` whose `evidence ::
Maybe ModelCallEvidence` is where an adapter hands its record back. An **adapter-less path** is one
where no adapter ran to completion — the trace layer's consumer abort, an unregistered provider, a
`complete` handler that threw, and each adapter's `immediateError` when `prepareCall` failed —
all of which digest `Build.dispatchEnvelope`, `{"model": …, "max_tokens": …}`.

### The files this plan changes, and how they fit together

`baikai/src/Baikai/Evidence.hs` is the vocabulary and deliberately imports neither `Model` nor
`Options`. This plan adds a mode, `untranslatedThinking`, `deriveStrength`, `usageEnvelope`, two
summarisers in `configurationProjection`, and bumps `evidenceSchemaVersion`.

`baikai/src/Baikai/Evidence/Build.hs` bridges `Model`/`Options` to the record: `minimalEvidence`
and `prepareEvidence` (gated on `opts ^. #evidence`, lazy in the envelope), `endpointIdentity`,
`sanitizeEndpoint`, `dispatchEnvelope`, the gate, and the sink-failure policy (`onSinkFailure`,
`sinkFailureIsFatal`, `sinkFailureError`). This plan adds `requestedTranslation`, `strictnessOf`,
the three `…At` variants and `missingEvidenceError`, and changes `checkEvidenceRequirements`'s
second argument.

`baikai/src/Baikai/Provider/Registry.hs` defines `ApiProvider` (`apiTag`, `stream`, `complete`,
`describeThinking`) and `completeRequestWith`, whose no-handler branch builds evidence with
`noThinkingRequested` at line 173. `baikai/src/Baikai/Stream.hs` holds `streamRequestWith` (lines
98–112: lookup, gate, dispatch), `errorEvents` inside `liftCompleteToStream` (`noThinkingRequested`
at 559), `refusedEvents` (the one adapter-less path that already carries the adapter's real
translation — the pattern to copy) and `noProviderEvents` (642).

`baikai/src/Baikai/Trace.hs` is the trace bridge: `withTraceStreamWith reg` forks a drain worker,
pushes `CallStarted`, wraps the provider stream in `Stream.mapM (traceEvent …)` and
`Stream.finallyIO (finalizeTrace …)`; `finalizeTrace` (line 237) synthesises an `aborted`
`CallFailed` and a record with `noThinkingRequested` (270) when the consumer stopped early;
`traceEvent` pushes `CallEvidence` before the terminal and rewrites a successful terminal through
`failTerminal` when a strict caller's sink threw. This plan changes only the abort translation and
the module header; `terminalSent`, `finalizeTrace`'s blocking `takeMVar` and `multiSink` in
`baikai/src/Baikai/Trace/Sink.hs` belong to EP-9. `baikai/src/Baikai/Trace/Event.hs` defines
`TraceEvent`; its `model` field is filled with the requested `modelId` on every constructor, and
its `CallEvidence` Haddock (lines 87–90) still says the event follows the terminal.

`baikai-claude/src/Baikai/Provider/Claude/Api.hs` and
`baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` are the HTTP adapters, owned by EP-4
(`docs/plans/61-make-stream-workers-cancellable-and-error-streams-protocol-conformant.md`), which
lands first; this plan edits only their evidence content. At HEAD `5411947`: `prepareCall`
resolves the URL (`"" -> "https://api.anthropic.com"` at Claude 235, `"" ->
"https://api.openai.com"` at OpenAI 262) into a `ClaudeCall` / `OpenAICall` carrying
`requestBody` and `thinking`; stream setup calls `Build.prepareEvidence` with `m` (Claude 193,
OpenAI 213), so the endpoint comes from the possibly-empty `m ^. #baseUrl`; `observeAnthropic` /
`observeOpenAI` (Claude 408–417, OpenAI 639–648) set `strength` through `anthropicStrength` /
`openaiStrength` (430–435, 661–666), which ignore the response id; `responseEnvelope` (465–470,
697–702) digests `finalUsage ass`, cost included; `immediateError` (837–864, 1277–1304) passes
`Ev.noThinkingRequested` although `describeThinkingFor` / `describeThinkingShape` are pure and in
scope. `baikai/src/Baikai/Provider/Cli/Internal.hs` holds `subprocessStrength` (725) and
`cliResponseEnvelope` (709), used by both `Cli.hs` modules and by
`baikai-agent/src/Baikai/Agent/Run.hs` (346, 461).

`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` is one fold keyed by `eventId`; its
`CallFinished` branch inserts `SC.genAi_response_model model` (line 122) while `evidenceAttributes`
inserts `gen_ai.response.model` only from an observed model. `baikai-trace-otel/test/Main.hs` pins
both: `successSpanTest` asserts the key present on a stub that observes nothing; `evidenceSpanTest`
asserts it absent in the same situation.

The tests you extend: `baikai/test/TraceSpec.hs` (fixtures `registerOk`, `registerFail`,
`registerOkWithEvidence`, `memorySink`, `awaitEvents` — which forces GC because the abort finaliser
runs from streamly's GC hook — and `evidenceField`, which reads the encoded JSON),
`baikai/test/EvidenceSpec.hs` (golden digests over `baikai/test/fixtures/evidence-request.json`),
`baikai/test/StrictEvidenceSpec.hs`, both providers' `EvidenceSpec.hs` (a `replay` harness feeding
a recorded HTTP response through the real adapter; `successHeaders` carries `x-request-id` for
OpenAI and `request-id` for Claude), and `baikai-trace-otel/test/Main.hs`. The contract documents:
`docs/user/model-call-evidence.md`, `docs/capabilities/model-call-evidence.md` (CAP-19),
`docs/capabilities/opentelemetry-span-export.md` (CAP-10), and `CHANGELOG.md`, whose 0.5.0.0
section (lines 83–89) calls `onSinkFailure` "the hook a future release replaces" and says every
record has `strength` `requested_only` — both untrue of that release.

### ADR context

`docs/adr/` is a plain-file convention (`docs/adr/0001-architecture-decision-record-convention.md`):
`NNNN-slug.md`, frontmatter `title`, `status`, `date`, body Context/Decision/Consequences, an index
table in `docs/adr/README.md`, no OKF profile. Three records constrain and are revised here:
`docs/adr/0002-requested-translated-observed-are-never-collapsed.md` (the three facts are separate
and `Observed` has no default — this plan extends "never collapsed" to the paths that collapsed the
request into "absent" and to a sink that labelled the requested id as the response model),
`docs/adr/0003-the-adapter-owns-the-translation-description.md` (this plan says how adapter-less
paths obtain a description, and adds the adapter-declared ceiling), and
`docs/adr/0004-two-digests-commitment-and-configuration.md` (three structural summaries become
five; cost leaves the response digest). `docs/adr/0005-what-baikai-deliberately-does-not-do.md` is
read-only context: `fully_observed` stays unreachable. This plan creates
`docs/adr/0006-strict-evidence-means-a-record-exists.md` (next free number at implementation
time). No cross-repository ADR applies.

### What this plan depends on

Soft dependencies only. If EP-4 has landed, keep its `immediateError` event shape and change only
the translation argument; if not, change the argument now and EP-4 keeps the call. EP-3 may
extend `ThinkingAdjustment`; nothing here depends on the set. EP-9 edits `Trace.hs` afterwards and
rebases onto the one-parameter change to `finalizeTrace` in Milestone 1.


## Plan of Work

Four milestones, fixed by the MasterPlan.

### Milestone 1: the caller's thinking request recorded on every evidence path

At the end of this milestone every `call_evidence` line carries the level the caller set, and on
the paths where no adapter translated it the `mode` says so. Acceptance: the transcript in the
Purpose section prints `"requested":"max"`, and the six new tests pass.

In `baikai/src/Baikai/Evidence.hs`, add a constructor to `ThinkingMode` between
`ThinkingModeUnsupported` and `ThinkingModeAbsent`:

```haskell
  | -- | The caller requested a level and no provider adapter ran to
    -- translate it: the call was refused, never dispatched, or
    -- abandoned before the adapter could describe what it did. The
    -- request is recorded; the translation is unknown. Distinct from
    -- 'ThinkingModeAbsent' (nothing requested) and from
    -- 'ThinkingModeUnsupported' (an adapter looked and could not).
    ThinkingModeNotTranslated
```

Extend `renderThinkingMode` with `"not_translated"`, `parseThinkingMode` with the inverse, and the
type's Haddock list of encodings. Add beside `noThinkingRequested`, exported next to it:

```haskell
-- | The translation for a path where no adapter ran: the caller's
-- level exactly, and no claim about the wire. 'noThinkingRequested'
-- when no level was set, so the two statements stay distinct.
untranslatedThinking :: Maybe ThinkingLevel -> ThinkingTranslation
untranslatedThinking = \case
  Nothing -> noThinkingRequested
  Just lvl ->
    ThinkingTranslation
      { requested = Just lvl,
        mode = ThinkingModeNotTranslated,
        effortText = Nothing,
        budgetTokens = Nothing,
        wireField = Nothing,
        adjustments = []
      }
```

The empty `adjustments` list is deliberate: an untranslated request has not been downgraded, and
`checkEvidenceRequirements` refuses on a non-empty list. In `baikai/src/Baikai/Evidence/Build.hs`
add and export `requestedTranslation :: Options -> ThinkingTranslation`, which is
`untranslatedThinking (opts ^. #thinking)`, with a Haddock naming the two paths it serves.

Replace `noThinkingRequested` at the core sites: `errorEvents` and `noProviderEvents` in
`baikai/src/Baikai/Stream.hs` and the no-handler branch of `completeRequestWith` in
`baikai/src/Baikai/Provider/Registry.hs` all pass `Build.requestedTranslation opts`; drop the
now-unused imports.

`baikai/src/Baikai/Trace.hs` is the site with a registered provider. Give `finalizeTrace` the
registry as a new first parameter and pass `reg` from its three call sites. Inside the `unless
sent` block, before `Build.minimalEvidence`:

```haskell
        mProvider <- Registry.lookupApiProviderWith reg (m ^. #api)
        let translation = case mProvider of
              Just p -> Registry.describeThinking p m opts
              Nothing -> Build.requestedTranslation opts
```

and pass `translation` where line 270 passed `noThinkingRequested`. Import
`Baikai.Provider.Registry` qualified as `Registry`, because `ApiProvider`'s `stream` field clashes
with the streamly import. The lookup is one `readIORef` on the abort path only, and
`minimalEvidence` never forces the translation for an opted-out caller, so the guarantee
`envelopeNotForcedTest` protects is untouched. Say in a comment why the adapter's describer is
called here: the adapter did run, and its own function is the one description ADR 0003 permits.
Correct the module header (lines 22–24) while there: sink exceptions are reported on stderr and,
under `EvidenceRequired`, fail the call through `reportSinkError`.

In `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, `immediateError` passes
`(describeThinkingFor m opts)`; in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` it passes
`(describeThinkingShape (openaiCompletionsCompatFor m) opts)`, the expression the provider's
`describeThinking` field already uses at line 143. Both are pure.

Tests, in a new `requestedLevelTests` group in `baikai/test/TraceSpec.hs`. Define
`thinkingOptions = evidenceOptions & #thinking .~ Just ThinkingMax`, a fixture `registerOkHonest`
identical to `registerOk` except `describeThinking = \_ o -> Build.requestedTranslation o` (the
existing stubs answer `noThinkingRequested` whatever the caller set, which is what hid this
defect), and a helper `thinkingField k ev = evidenceField "thinking" ev >>= lookupIn k` written
like `baikai-openai/test/EvidenceSpec.hs`'s `thinkingOf`. `abortRecordsRequestedLevelTest`:
`registerOkHonest`, `Stream.take 1` of `withTraceStream` with `thinkingOptions`, `awaitEvents ref
3`, `exactlyOneEvidence`, then `requested` is `"max"` and `mode` is `"not_translated"`.
`abortUsesTheAdapterDescriberTest`: the same against a provider whose `describeThinking` returns a
hand-built translation with `mode = ThinkingModeBudget`; assert `mode` is `"budget"` — the proof
that the abort path consults the adapter rather than spelling `not_translated` unconditionally.
`noProviderRecordsRequestedLevelTest`: no registration, `withTrace` with `thinkingOptions`, the
same two assertions. `throwingHandlerRecordsRequestedLevelTest`: `registerFail a (providerError
"stub-failure")`, the same two plus `status` is `"failed"`.

In `baikai-claude/test/EvidenceSpec.hs` add `immediateErrorRecordsThinkingTest`: replay against
`testModel & #baseUrl .~ "https://unknown-host.example"` with `#thinking .~ Just ThinkingHigh`, an
evidence request, and no `apiKey`. `Transport.resolveKey` refuses an unknown host rather than
reading an environment variable, so `prepareCall` fails with `AuthError` regardless of the
developer's shell and the adapter takes `immediateError`; the replay driver is never reached.
Assert `thinking.requested` is `"high"`, `thinking.mode` equals what `describeThinkingFor` renders
for that model and is not `"absent"`, and `status` is `"failed"`. Do the same in
`baikai-openai/test/EvidenceSpec.hs` with `describeThinkingShape`.

```text
feat(evidence): record the caller's thinking level on every evidence path

Add ThinkingModeNotTranslated and untranslatedThinking to the vocabulary
and requestedTranslation to the builder. The consumer-abort path asks
the registered adapter's own describeThinking; the unregistered-provider
and thrown-handler paths record the level as not_translated; both
providers' immediateError call their own describer.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

### Milestone 2: strict mode fails a call whose terminal carries no record

At the end of this milestone "evidence that can vanish without the caller noticing is not
evidence" is true for a provider that never built a record, not only for a sink that threw.
Acceptance: a `Custom` provider that attaches no evidence, called under `EvidenceRequired
EvidenceRequestedOnly`, returns an error-shaped `Response`; its trace is `call_started` then
`call_failed` with no `call_evidence`; the same call under best effort returns `Stop`.

Add to `baikai/src/Baikai/Evidence/Build.hs`, exported beside `sinkFailureError`:

```haskell
-- | The error a strict call fails with when its provider produced a
-- successful terminal and attached no evidence record to it. Built
-- with 'providerError' for the reason 'sinkFailureError' is: nothing
-- about the request was invalid and the provider did its job, and
-- 'Baikai.Error.ErrorCategory' is closed. The message prefix is the
-- contract until the surface freeze decides on a category.
missingEvidenceError :: BaikaiError
missingEvidenceError =
  providerError
    "this call required evidence, but the provider attached no evidence record to its \
    \terminal event; the response is reported failed rather than left unaccounted for"
```

Move `strictnessOf` from `Trace.hs` into `Build.hs` and export it. Add to
`baikai/src/Baikai/Stream.hs`, exported, `requireEvidenceOnTerminal :: Options ->
AssistantMessageEvent -> AssistantMessageEvent`: when `strictnessOf opts` is `EvidenceRequired _`
and the event is `EventDone p` with `p ^. #evidence == Nothing`, return an `EventError` with
`reason` set to `ErrorReason`, `errorInfo` set to `Just Build.missingEvidenceError`, and the
assistant message's `stopReason` and `errorMessage` marked the way `Baikai.Trace.failTerminal`'s
`markFailed` marks them (copy that logic; `Trace` imports `Stream`, not the reverse). Everything
else — error terminals, any terminal carrying a record, non-terminal events, best-effort and
opted-out calls — is returned unchanged. In `streamRequestWith`, the `[] -> pure (stream p m ctx
opts)` branch becomes `pure (applyStrict (stream p m ctx opts))` where `applyStrict` is `Stream.map
(requireEvidenceOnTerminal opts)` under `EvidenceRequired _` and `id` otherwise, so a best-effort
call pays one `Maybe` test and no per-event map.

Add the `Response` twin in `baikai/src/Baikai/Provider/Registry.hs`, `requireEvidenceOnResponse ::
Options -> Response -> Response`, applied to the result of `complete p m ctx opts` in
`completeRequestWith`: when strict, `responseError resp == Nothing` and `resp ^. #evidence ==
Nothing`, set `errorInfo = Just Build.missingEvidenceError` and mark the message failed. The
built-in providers' `complete` is `streamingComplete . stream`, which does not pass through
`streamRequestWith`, which is why this second site exists. Because the trace layer wraps
`streamRequestWith`, a strict record-less call now reaches `traceEvent` as an `EventError` and
`Trace.hs` pushes `CallFailed` with no change of its own; read `traceEvent`'s `EventError` branch
to confirm rather than assume.

Tests in `baikai/test/TraceSpec.hs`'s `evidenceTests`. `strictNoRecordFailsTest`, named in
capitals like its sibling `A STRICT CALL WHOSE PROVIDER ATTACHED NO RECORD FAILS, AND EMITS NO
RECORD`: `registerOk`, `withTrace` with `strictOptions`; assert `stopReason` is `ErrorReason`,
`responseError` has category `OtherError` and a message containing `attached no evidence record`,
and the sink saw one `CallStarted`, one `CallFailed`, zero `CallEvidence`.
`strictNoRecordIsOneTerminalTest`: the streaming form yields zero `EventDone` and one `EventError`.
`strictWithRecordSucceedsTest`: `registerOkWithEvidence` under `strictOptions` with a non-throwing
sink returns `Stop` and one `CallEvidence` — the rewrite fires on the absence of a record, not on
strictness alone. `strictNoRecordErrorPathKeepsProviderErrorTest`: `registerFail` under
`strictOptions`; the message contains `stub-failure` and not `attached no evidence record`.
`bestEffortNoRecordStillSucceedsTest`: `registerOk` under `evidenceOptions` returns `Stop`. In
`baikai/test/StrictEvidenceSpec.hs`'s `dispatchTests`: `a strict completeRequest with a record-less
provider fails after the call` — `countingProvider` under `strictly EvidenceRequestedOnly`;
`responseError` carries the prefix and the assistant text still reads `the provider ran`, proving
the provider was reached and its content kept.

Documentation truth, in the same commit. In `baikai/src/Baikai/Trace/Event.hs` lines 87–90, say
`CallEvidence` is emitted exactly once, **before** the matching terminal, so a sink keyed on the
started/terminal pair still has the call open; document `model` on the type as the requested
`Model.modelId` on every constructor, with the served model available only inside
`CallEvidence`'s record as `observedModel`. In `docs/capabilities/model-call-evidence.md`: line
32's `proves` becomes "strict mode's pre-dispatch gate, and that a strict call whose provider
attached no record fails after the call"; line 35's becomes "exactly one evidence record per call
under every way a call can end, and that a strict call with no record fails rather than succeeding
silently"; line 129's `onSinkFailure` bullet is replaced by one stating the two strict-mode failure
rules (a sink that threw; a terminal with no record). Add a `## 2026-08-27` entry to
`docs/capabilities/log.md` in the file's `* **Note**:` form naming CAP-19 and this plan. In
`CHANGELOG.md`, do not rewrite the 0.5.0.0 paragraph at lines 83–89; the MasterPlan
(`docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md`, Integration
Points) rules that a released section is never edited in place. Instead add, directly under that
paragraph, a dated correction — "(correction added 2026-08-27: `onSinkFailure` shipped in 0.5.0.0
together with `sinkFailureIsFatal` and `sinkFailureError`, and not every 0.5.0.0 record has
`strength` `requested_only`; the provider entries below describe what each transport reports)" —
and add the `[Unreleased]` entry for the new rule and `missingEvidenceError`. Run the capability
validator (Concrete Steps) before committing.

```text
feat(evidence): fail a strict call whose terminal carries no record

Add missingEvidenceError, requireEvidenceOnTerminal and
requireEvidenceOnResponse, applied at both dispatch points. A provider
that attaches no record under EvidenceRequired now yields a failed call
and a call_failed trace line instead of a silent success with zero
call_evidence lines. Correct the CallEvidence ordering Haddock and the
capability record's claims.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

### Milestone 3: observed model only in the OTel span; endpoint default host; commitment digest without cost

At the end of this milestone a span never says a requested id is a response model, a default-host
call records its host, and both digests cover what their documentation says; because external
verifiers recompute those bytes, the schema version bumps. Acceptance: `cabal test
baikai-trace-otel` passes with `successSpanTest` asserting absence; both providers' default-host
tests pass; the golden digests are recomputed and the redaction test rejects the two new markers;
`evidenceSchemaVersion` reads `baikai.model-call-evidence/2.0`.

**D.1, the span.** In `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` delete the
`AttrMap.insertByKey SC.genAi_response_model model $` line from the `CallFinished` branch and drop
`model` from its pattern, with a comment: the response model is an observation and arrives on
`CallEvidence`; the trace event's `model` is the requested id, and `addAttributes` replaces an
existing key, so setting it here overwrote the observed value. In `baikai-trace-otel/test/Main.hs`
rewrite `successSpanTest`'s `has gen_ai.response.model` assertion to assert the key is **absent**
because the stub reported no model, and add `observedModelSpanTest` under `Custom
"baikai-otel-observed-model"`: `registerOkWithEvidence` extended with `& #observedModel .~
Observed "stub-1-as-served"` on the record, driven through `withTrace` with an evidence request;
assert `gen_ai.response.model` is `"stub-1-as-served"` and `gen_ai.request.model` is `"stub-1"` on
the exported span. It fails on today's code with the requested id in the response key. Update
line 22 of `docs/capabilities/opentelemetry-span-export.md` to name the case. Do not touch
`strengthText`; sharing it with `renderEvidenceStrength` is EP-9 M3's.

**D.8, the endpoint.** In `baikai/src/Baikai/Evidence/Build.hs` add and export
`endpointIdentityAt :: Text -> Model -> TransportKind -> EndpointIdentity`, `prepareEvidenceAt` and
`minimalEvidenceAt`, each taking the resolved base URL as its first argument and otherwise
matching its sibling (signatures in Interfaces). Re-express the existing three as calls passing
`m ^. #baseUrl`, and keep the envelope parameter lazy and bang-free in the new functions — the
existing Haddock says why and `envelopeNotForcedTest` enforces it. In each provider's `Api.hs`,
factor the URL default out of `prepareCall` into a pure `resolvedBaseUrl :: Model -> Text`, add
`baseUrl :: !Text` to `ClaudeCall` / `OpenAICall`, and pass `(call ^. #baseUrl)` to
`Build.prepareEvidenceAt` at stream setup and `(resolvedBaseUrl m)` to `Build.minimalEvidenceAt`
in `immediateError`. Tests: `defaultHostEndpointTest` in each provider's `EvidenceSpec.hs`,
replaying the success fixture against `testModel & #baseUrl .~ ""` and asserting
`endpoint.endpoint` is `"https://api.anthropic.com"` / `"https://api.openai.com"`; the replay
driver ignores the URL.

**D.11, cost out of the response digest.** In `baikai/src/Baikai/Evidence.hs` add and export
`usageEnvelope :: Usage -> Value`, emitting the six count fields under the snake_case names
`Usage`'s own instance uses (`input_tokens`, `output_tokens`, `cache_read_tokens`,
`cache_write_tokens`, `reasoning_tokens`, `total_tokens`) through record selectors, so a field
added to `Usage` later does not silently join the digest, and never `cost`, with the Decision Log's
reason in its Haddock. Use it in `responseEnvelope` in both `Api.hs` modules (`"usage" Aeson..=
Ev.usageEnvelope (finalUsage ass)`) and in `cliResponseEnvelope`, which `baikai-agent` also calls;
`rg -n 'responseEnvelope|cliResponseEnvelope' --type haskell` confirms those are the only three
builders. Test in `baikai/test/EvidenceSpec.hs`: two `Usage` values differing only in `cost` have
equal envelopes, and the encoded envelope has no `cost` key.

**D.7, schemas out of the configuration digest.** First confirm the wire spelling: run `mori
registry search claude` to find the MercuryTechnologies `claude` SDK checkout, read the `ToJSON`
for `OutputConfig` in its `Messages` module, and note the key names — this plan expects `effort`
and `format`, with `format` carrying `type` and `schema`; record what you find in Surprises &
Discoveries. Then in `configurationProjection` add two cases beside `messages`, `system` and
`tools` — `"output_config" -> [(k, summariseOutputConfig v)]` and `"response_format" -> [(k,
summariseResponseFormat v)]` — and remove both names from `configurationKeys`.
`summariseOutputConfig` keeps every key except `format` and replaces `format` with `{"type": <its
type or null>, "chars": <totalStringChars of the whole format value>}`; `summariseResponseFormat`
keeps `type` and replaces `json_schema` with `{"name": …, "strict": …, "chars": <totalStringChars
of the schema>}`, dropping other keys; a non-object projects to `Null` like `summariseMessage`.
Update the Haddock ("Three keys are kept" becomes five, with the rule that a JSON schema is content
wherever it appears). Extend `baikai/test/fixtures/evidence-request.json` with an `output_config`
(`"effort": "high"`, a `format` whose schema has a `description` containing
`OUTPUT-SCHEMA-MARKER`) and a `response_format` of type `json_schema` (`"name":
"quarterly_report"`, `"strict": true`, a schema containing `RESPONSE-SCHEMA-MARKER`). The fixture
is one recorded envelope serving both digest and redaction tests and already carries a non-wire
`extra_headers` key, so mixing an OpenAI key into an Anthropic-shaped body is in keeping; say so in
the test comment. In `redactionTests` both markers join the must-not-survive list and
`quarterly_report`, `effort` and `strict` join the must-be-kept list. The golden digests then
fail; Concrete Steps says how to recompute them honestly.

**The schema version.** Set `evidenceSchemaVersion` to `"baikai.model-call-evidence/2.0"` and
extend its Haddock with what a verifier must know: `response_commitment` covers `{"content",
"stop_reason", "usage"}` where `usage` is token counts only; `request_configuration` summarises
`output_config` and `response_format`; `thinking.mode` may be `"not_translated"`; a 1.0 record's
digests are recomputed under 1.0 rules, selected by `schema_version`. `assertMinimalShape` reads
the constant, so it follows; grep for `/1.0` for anything else. Add `[Unreleased]` entries for all
four changes, stating the bump and the verifier consequence in the D.11 entry, and update the
digest and strength paragraphs of `docs/user/model-call-evidence.md` and the Limits of
`docs/capabilities/model-call-evidence.md`.

```text
fix(evidence): observe the served model only, resolve the default host, digest counts not cost

The OTel CallFinished branch no longer sets gen_ai.response.model; only
CallEvidence does, from observedModel. Both API adapters pass the base
URL they resolved to the new endpointIdentityAt/prepareEvidenceAt.
response_commitment digests usageEnvelope, which carries token counts
and never cost. output_config and response_format are summarised in the
configuration projection like tools. Schema version 2.0.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```

### Milestone 4: one strength derivation; `ApiProvider` declares its ceiling; ADRs 0002–0004 revised

At the end of this milestone one function turns observations into a strength, a provider declares
its ceiling, and the durable decisions live in `docs/adr/`. Acceptance: `rg -n
'anthropicStrength|openaiStrength' --type haskell` finds nothing; an OpenAI replay with `model` and
`id` on every chunk and no captured header records `model_observed`; a custom provider declaring
`EvidenceCorrelated` passes a strict `EvidenceCorrelated` gate; `docs/adr/README.md` lists six
records; the keyless gate is green.

**D.10, the derivation.** Add to `baikai/src/Baikai/Evidence.hs`, exported under "Outcome and
strength":

```haskell
-- | The one rule that turns observations into a strength. A
-- correlation identifier is the provider's request id (typically a
-- response header) or its response id; either locates the call in the
-- provider's own records. A model is 'EvidenceModelObserved' only in
-- addition to one, because the scale is cumulative; an unlocatable
-- model claim stays in 'observedModel' without climbing it. Nothing
-- reaches 'EvidenceFullyObserved'. A successful status is not an
-- argument here on purpose.
deriveStrength :: Observed Text -> Observed Text -> Observed Text -> EvidenceStrength
deriveStrength observedModel providerRequestId responseId =
  case (observedModel, correlated) of
    (Observed _, True) -> EvidenceModelObserved
    (_, True) -> EvidenceCorrelated
    _ -> EvidenceRequestedOnly
  where
    correlated = case (providerRequestId, responseId) of
      (Observed _, _) -> True
      (_, Observed _) -> True
      _ -> False
```

In both `Api.hs` modules delete the local strength function and set `#strength` to
`Ev.deriveStrength (ass ^. #observedModel) (ass ^. #providerRequestId) (maybe Ev.Unobserved
Ev.Observed (ass ^. #responseId))`. In `baikai/src/Baikai/Provider/Cli/Internal.hs` keep
`subprocessStrength`'s signature and make its body `deriveStrength reported Unobserved
sessionIdentifier`, so `baikai-agent/src/Baikai/Agent/Run.hs` and both `Cli.hs` sites need no
change. Tests: an eight-row table in `baikai/test/EvidenceSpec.hs` over the three inputs, one
named case per row; `responseIdCountsAsCorrelationTest` in `baikai-openai/test/EvidenceSpec.hs`,
replaying `successBody` with `[]` for headers and asserting `strength` is `"model_observed"`,
`provider_request_id` is `"unobserved"` and `response_id` is observed; the same in
`baikai-claude/test/EvidenceSpec.hs` with the Claude success fixture minus its `request-id`
header. Both are the shapes REV-2 said nothing covered.

**The ceiling.** In `baikai/src/Baikai/Provider/Registry.hs` add a fifth field:

```haskell
    -- | The highest strength this provider's evidence can reach when
    -- everything goes well: a static declaration compared against a
    -- strict caller's requirement before dispatch. Declaring more than
    -- the provider delivers is the one way to make strict mode lie, so
    -- a declaration above 'Baikai.Evidence.EvidenceRequestedOnly' needs
    -- a test that drives the provider to it. A provider that attaches
    -- no record must declare 'Baikai.Evidence.EvidenceRequestedOnly'
    -- and will still fail a strict caller at the terminal.
    strengthCeiling :: !EvidenceStrength
```

Change `evidenceRefusals` to pass `strengthCeiling p` where it passed `Model.api m`, and change
`checkEvidenceRequirements`'s second parameter in `Build.hs` to `EvidenceStrength`, named
`declared`. Revise `declaredStrength`'s Haddock: the gate compares against the provider's own
`strengthCeiling`; the built-in providers set that field from this function; the agent surface's
`agentReachableStrength` still consults it by tool. Then update every construction site — the
compiler lists them; at HEAD there are twenty-four across fifteen files: both providers' `Api.hs`
and `Cli.hs` (`declaredStrength AnthropicMessages`, `AnthropicMessagesCli`,
`OpenAIChatCompletions`, `OpenAICompletionsCli`), the fixtures in `baikai/test/TraceSpec.hs`,
`StrictEvidenceSpec.hs`, `CostSpec.hs`, `ErrorInfoSpec.hs`, `HelpersSpec.hs` and `Main.hs`, both
providers' `test/EvidenceSpec.hs`, `baikai-effectful/test/StubProvider.hs`,
`baikai-trace-otel/test/Main.hs` (all `EvidenceRequestedOnly`, including the
`observedModelSpanTest` fixture, which observes a model and no identifier), and the two examples
in `docs/user/models-and-providers.md` (lines 275–283 and 315–321), which no compiler reads. In
`baikai/test/StrictEvidenceSpec.hs` rewrite `strengthGateTests` to pass `declaredStrength <tag>`
and add two dispatch cases: a custom provider declaring `EvidenceCorrelated` whose record observes
a response id passes `strictly EvidenceCorrelated` with `"strength":"correlated"`, and is refused
under `strictly EvidenceModelObserved` with `StrengthUnreachable EvidenceModelObserved
EvidenceCorrelated`. Record the break under `[Unreleased]` naming both `strengthCeiling` and the
`checkEvidenceRequirements` signature, and add one Decision Log line to
`docs/plans/67-freeze-the-public-surface.md` saying `ApiProvider` now has five fields and needs
the base value that plan defines.

**The ADRs.** Revise three records in place, keeping `status: accepted` and the original `date`,
and append to each a final `## Revisions` section with one dated line naming this plan.
`docs/adr/0002-…`: in Decision, after the three bullets, add that the requested level is recorded
on every path including those where no adapter ran, and that such a path spells its translation
`not_translated`, never `absent`; in Consequences, add that four core paths and both
`immediateError`s had collapsed the request into "absent", that stubs answering
`noThinkingRequested` regardless of the caller hid it, and that "never collapsed" binds consumers
too — a sink must not present the requested id under a response key, as the OpenTelemetry sink
did. `docs/adr/0003-…`: in Decision, add the rule for adapter-less paths (registered provider →
its `describeThinking`; none → `not_translated`; the core never re-derives); in Consequences,
replace the paragraph beginning "The cost lands on `ApiProvider`, which gained a fourth field" with
one saying the record now carries two declarations, `describeThinking` and `strengthCeiling`,
because only the adapter knows either, and that the tag-keyed `declaredStrength` remains only as
the source for built-in providers and the agent surface. `docs/adr/0004-…`: in Decision, after the
`responseCommitment` paragraph, state that it covers the assembled content, the stop reason and the
provider-reported token counts and never the cost, with the verifier reason; in Consequences,
change "Three keys are kept" to five, naming `output_config` and `response_format` and the rule
that a JSON schema is content wherever it appears, and note that this revision is the `2.0` bump
the Decision section anticipates.

Create `docs/adr/0006-strict-evidence-means-a-record-exists.md`, title "Strict evidence means a
record exists, not merely that the sink did not throw", `status: accepted`, dated when written.
Context: strict mode had two enforcement points — the gate and the sink-failure rule — and a
`Custom` provider that attached no record passed the gate at `requested_only`, returned `Stop`,
and wrote zero `call_evidence` lines with no error. Decision: under `EvidenceRequired` a successful
terminal with no record is rewritten to a failure carrying `missingEvidenceError` at both dispatch
points so `completeRequest`, `streamRequest` and `withTrace` agree; the error path keeps the
provider's error; the gate does not refuse a `requested_only` ceiling because a provider that
builds a minimal record is doing the right thing. Consequences: only a provider can declare its
ceiling, hence `strengthCeiling`; a call can now fail after reaching the provider for a second
reason and both share the `providerError` category until the surface freeze decides; the failed
response keeps the provider's content. Add the row to `docs/adr/README.md`.

Finish by updating `docs/user/model-call-evidence.md`'s strict-mode section (the record-less rule,
the custom-provider ceiling) and its migration section (the fifth field), then run the full
validation below.

```text
refactor(evidence): one strength rule, a provider-declared ceiling, ADRs 0002-0004 revised

Add deriveStrength and make every transport use it, counting an observed
response id as correlation. Add ApiProvider.strengthCeiling and compare
the gate against it instead of a tag-keyed table. Revise ADRs 0002, 0003
and 0004 for this plan's decisions and add ADR 0006: strict evidence
means a record exists.

MasterPlan: docs/masterplans/10-correctness-and-api-hardening-from-the-2026-08-review.md
ExecPlan: docs/plans/65-make-evidence-records-truthful-and-strict-mode-strict.md
Intention: intention_01m10p16mxedft15rjkk2w21g0
```


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/baikai` throughout. Confirm the tree is green and locate
every site before editing:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
cabal build all
rg -n 'noThinkingRequested' --type haskell baikai/src baikai-claude/src baikai-openai/src
rg -n 'anthropicStrength|openaiStrength|subprocessStrength' --type haskell
rg -n 'describeThinking =' --type haskell --type md . | grep -v dist-newstyle | wc -l
rg -n 'genAi_response_model' baikai-trace-otel/src
```

Expect the first search to list the six Milestone 1 sites plus the definition and the
`refusedEvents` comment, the second three definitions and four call sites, the third `24`, and the
fourth one line in the `CallFinished` branch. If a count differs, EP-3 or EP-4 has landed; read
that file's diff first and record the difference in Surprises & Discoveries. Read, before the first
edit: `baikai/src/Baikai/Evidence.hs`, `baikai/src/Baikai/Evidence/Build.hs`,
`baikai/src/Baikai/Trace.hs` completely, `baikai/src/Baikai/Stream.hs` lines 86–135 and 430–660,
`baikai/src/Baikai/Provider/Registry.hs`, and `baikai/test/TraceSpec.hs` lines 60–140 and 400–600.

After each milestone's edits, run the suites that touch it, then the full build:

```bash
cabal build all
cabal test baikai --test-options='--pattern Trace'
cabal test baikai --test-options='--pattern Evidence'
cabal test baikai --test-options='--pattern Strict'
cabal test baikai-claude --test-options='--pattern Evidence'
cabal test baikai-openai --test-options='--pattern Evidence'
cabal test baikai-trace-otel
```

A pattern matching no test reports `All 0 tests passed`; treat that as a failure. The group names
are `Baikai.Trace`, `model-call evidence`, `EvidenceSpec: Anthropic model-call evidence`,
`EvidenceSpec: OpenAI-compatible model-call evidence` and `StrictEvidenceSpec: pre-dispatch strict
evidence`.

After Milestone 1, run the Purpose section's transcript and `jq` line. Before the code change the
first three `requestedLevelTests` fail with `expected: Just (String "max") but got: Just Null`,
which is the defect. After Milestone 2, see the strict failure by hand:

```haskell
ghci> :set -XOverloadedStrings
ghci> import Baikai
ghci> import Baikai.Evidence
ghci> import Baikai.Stream (liftCompleteToStream)
ghci> let a = Custom "no-evidence-here"
ghci> let handler m _ _ = pure (emptyResponse & #model .~ m)
ghci> registerApiProvider ApiProvider { apiTag = a, stream = liftCompleteToStream handler, complete = handler, describeThinking = \_ _ -> noThinkingRequested }
ghci> let strict = emptyOptions & #evidence .~ Just (evidenceRequest "run-1" & #strictness .~ EvidenceRequired EvidenceRequestedOnly)
ghci> fmap (^. #message) . responseError <$> completeRequest (mkModel a "m" "") (contextOf [user "hi"]) strict
```

(After Milestone 4 add `, strengthCeiling = EvidenceRequestedOnly` to the record.) Expect `Just
"this call required evidence, but the provider attached no evidence record …"`; with
`evidenceRequest "run-1"` alone, expect `Nothing`.

After Milestone 3's fixture edit the two golden tests fail. Recompute honestly rather than pasting:
the redaction group must be green first, because a golden value pasted while a marker still
leaked would pin the leak.

```bash
cabal test baikai --test-options='--pattern redaction'
cabal test baikai --test-options='--pattern digests'
```

Copy the two `got:` values from the second command's failure into the two `@?=` lines, re-run,
and record both values and this procedure in Surprises & Discoveries; say in the test comment that
they changed with schema version 2.0 and why.

Validate the capability records after every edit under `docs/capabilities/`:

```bash
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

Expect no diagnostics. `--log-enforce` requires a `docs/capabilities/log.md` entry for the change;
if the validator rejects the bullet label, use the label its message names.

Before the final commit, run the release skill's keyless gate exactly as
`agents/skills/release/SKILL.md` states it, so no key or coding-agent binary in your shell can turn
a skipped live case into a pass:

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

Every suite must pass, not merely skip. Commit after each milestone with the message shown there,
always with the `MasterPlan:`, `ExecPlan:` and `Intention:` trailers, directly on `master`.


## Validation and Acceptance

The plan is complete when all of the following are observably true.

`cabal build all` succeeds with no new warnings and the keyless `cabal test all` passes with every
suite running tests.

A call with `#thinking .~ Just ThinkingMax` records `"requested":"max"` on every path:
`abortRecordsRequestedLevelTest`, `noProviderRecordsRequestedLevelTest`,
`throwingHandlerRecordsRequestedLevelTest`, and `immediateErrorRecordsThinkingTest` in both vendor
suites. The three core paths say `"mode":"not_translated"`; the abort path with a provider whose
describer says `budget` records `budget` (`abortUsesTheAdapterDescriberTest`); the adapters record
whatever their own describer says.

A strict call against a provider that attaches no record returns a `Response` whose `stopReason`
is `ErrorReason` and whose error has category `OtherError` and the prefix `this call required
evidence, but the provider attached no evidence record`; its trace is exactly `call_started`,
`call_failed` (`strictNoRecordFailsTest`); the streaming form yields one `EventError` and no
`EventDone` (`strictNoRecordIsOneTerminalTest`); `completeRequest` behaves the same with no sink
(the new `StrictEvidenceSpec` case). Best effort still returns `Stop`
(`bestEffortNoRecordStillSucceedsTest`); a provider that attaches a record succeeds under strict
(`strictWithRecordSucceedsTest`); a failed provider keeps its own error
(`strictNoRecordErrorPathKeepsProviderErrorTest`).

A span from a provider that reported no model carries `gen_ai.request.model` and no
`gen_ai.response.model` (`successSpanTest`, rewritten); a span whose record observed
`stub-1-as-served` carries that value under `gen_ai.response.model` and `stub-1` under
`gen_ai.request.model` after the terminal (`observedModelSpanTest`); `evidenceSpanTest` and
`liveEvidenceSpanTest` pass unchanged.

A replayed Anthropic or OpenAI call with `baseUrl = ""` records `endpoint.endpoint` as the default
host (`defaultHostEndpointTest`, both packages); the core adapter-less paths still record `null`.

Two `Usage` values differing only in `cost` produce the same `usageEnvelope` and the encoded
envelope has no `cost` key. The golden digests match recomputed values over the extended fixture;
the configuration projection contains neither `OUTPUT-SCHEMA-MARKER` nor `RESPONSE-SCHEMA-MARKER`
and still contains `quarterly_report`, `effort` and `strict`. `evidenceSchemaVersion` is
`baikai.model-call-evidence/2.0` and every emitted record says so.

`deriveStrength` returns the eight expected values; a replayed OpenAI stream carrying `model` and
`id` with no captured header records `"strength":"model_observed"`
(`responseIdCountsAsCorrelationTest`), the Claude equivalent likewise; the existing 429 replays
still record `correlated`; both `CliEvidenceSpec`s and `baikai-agent`'s `EvidenceTests` pass
unchanged.

`ApiProvider` has `strengthCeiling`; a custom provider declaring `EvidenceCorrelated` passes a
strict `EvidenceCorrelated` call and is refused a strict `EvidenceModelObserved` one with
`StrengthUnreachable` naming both; every `checkEvidenceRequirements` call in
`StrictEvidenceSpec.hs` passes a strength; the two guide examples compile if pasted.

ADRs 0002, 0003 and 0004 each end with a `## Revisions` section naming this plan and contain the
paragraphs Milestone 4 specifies; `docs/adr/0006-strict-evidence-means-a-record-exists.md` exists
and `docs/adr/README.md` has six rows. The two capability records validate and no longer claim
that `onSinkFailure` awaits a replacement, that `TraceSpec` pins the evidence order, or that every
record is `requested_only`. `CHANGELOG.md` carries `[Unreleased]` entries for the `not_translated`
mode; `missingEvidenceError` and the record-less strict failure; the OTel attribute change; the
endpoint default; `usageEnvelope` with the `2.0` bump and the verifier consequence; the projection
change; `deriveStrength`, the deleted strength functions and the response-id rule; and the
breaking `strengthCeiling` field and `checkEvidenceRequirements` signature — and its 0.5.0.0
section no longer contradicts itself.


## Idempotence and Recovery

Every build, test and validation step is safe to repeat. The manual transcripts write only to
`/tmp/baikai-ep8.jsonl`; delete it between runs.

The one edit that breaks compilation across packages is Milestone 4's fifth `ApiProvider` field.
Make it in one commit that also fixes every construction site, so no commit leaves the tree
unbuildable; `cabal build all` names each remaining site, and the two guide examples must be
updated by hand. If it goes wrong, `git checkout -- baikai/src/Baikai/Provider/Registry.hs` and
rebuild; nothing in Milestones 1–3 depends on the field.

Milestone 1's `finalizeTrace` parameter and Milestone 2's move of `strictnessOf` are the only edits
to `baikai/src/Baikai/Trace.hs`. Run `cabal test baikai --test-options='--pattern Trace'` after
each: the module's exactly-once guarantee rests on the `closed`/`terminalSent` interaction and a
forked worker, and does not fail loudly when disturbed. Keep both edits minimal so EP-9's rebase is
trivial.

The golden digests are recomputed only after the fixture edit and only once the redaction group is
green. To redo the fixture, `git checkout -- baikai/test/fixtures/evidence-request.json` and
start that step again; the golden lines then fail until recomputed, which is the safe direction.

The ADR edits are plain-file edits. If `0006` is taken by the time you create the record, use the
next free number and update this plan's references; if the corpus has become a profiled bundle,
follow `agents/skills/exec-plan/ADR.md` instead of this plan's file-level instructions.


## Interfaces and Dependencies

No new package dependencies. `hs-opentelemetry-api` stays at `>=1.0 && <1.1`; the only fact used
from it is that `addAttributes` replaces an existing key.

In `baikai/src/Baikai/Evidence.hs`:

```haskell
data ThinkingMode = … | ThinkingModeUnsupported | ThinkingModeNotTranslated | ThinkingModeAbsent
-- renders as "not_translated"; parseThinkingMode accepts it

untranslatedThinking :: Maybe ThinkingLevel -> ThinkingTranslation
deriveStrength :: Observed Text -> Observed Text -> Observed Text -> EvidenceStrength
usageEnvelope :: Usage -> Value
evidenceSchemaVersion :: Text                 -- "baikai.model-call-evidence/2.0"
configurationProjection :: Value -> Value     -- also summarises output_config, response_format
```

`ThinkingAdjustment` is unchanged and open for EP-3; `declaredStrength :: Api -> EvidenceStrength`
is unchanged in value.

In `baikai/src/Baikai/Evidence/Build.hs`:

```haskell
requestedTranslation :: Options -> ThinkingTranslation
strictnessOf :: Options -> EvidenceStrictness            -- moved here from Baikai.Trace
missingEvidenceError :: BaikaiError

endpointIdentityAt :: Text -> Model -> TransportKind -> EndpointIdentity
prepareEvidenceAt ::
  Text -> Model -> Options -> TransportKind -> ThinkingTranslation -> Aeson.Value -> UTCTime ->
  IO (Maybe (UTCTime -> CallStatus -> Maybe BaikaiError -> ModelCallEvidence))
minimalEvidenceAt ::
  Text -> Model -> Options -> TransportKind -> ThinkingTranslation -> Aeson.Value ->
  UTCTime -> UTCTime -> CallStatus -> Maybe BaikaiError -> IO (Maybe ModelCallEvidence)
-- endpointIdentity, prepareEvidence, minimalEvidence remain, passing (m ^. #baseUrl)

checkEvidenceRequirements ::
  EvidenceStrictness -> EvidenceStrength -> ThinkingTranslation -> [EvidenceRefusal]
-- second argument is the provider's declared ceiling, no longer an Api
```

The envelope parameters of the two new builders carry no strictness annotation, for the reason the
existing Haddock gives and `envelopeNotForcedTest` enforces.

In `baikai/src/Baikai/Stream.hs` and `baikai/src/Baikai/Provider/Registry.hs`:

```haskell
requireEvidenceOnTerminal :: Options -> AssistantMessageEvent -> AssistantMessageEvent
requireEvidenceOnResponse :: Options -> Response -> Response

data ApiProvider = ApiProvider
  { apiTag :: !Api,
    stream :: !(Model -> Context -> Options -> Stream IO AssistantMessageEvent),
    complete :: !(Model -> Context -> Options -> IO Response),
    describeThinking :: !(Model -> Options -> ThinkingTranslation),
    strengthCeiling :: !EvidenceStrength
  }
```

There is no base value for `ApiProvider`; EP-10 defines it. This is a breaking change for every
custom provider and is recorded as such in `CHANGELOG.md`. In `baikai/src/Baikai/Trace.hs`,
`finalizeTrace` takes a `ProviderRegistry` as its first argument and nothing else exported
changes. In `baikai/src/Baikai/Provider/Cli/Internal.hs`, `subprocessStrength` keeps its signature
and delegates to `deriveStrength`; `anthropicStrength` and `openaiStrength` no longer exist. In
`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` no exported name changes.

New files: `docs/adr/0006-strict-evidence-means-a-record-exists.md`. Edited fixtures:
`baikai/test/fixtures/evidence-request.json`. Edited documents: the three ADRs and their README,
`docs/user/model-call-evidence.md`, `docs/user/models-and-providers.md` (two examples only),
`docs/capabilities/model-call-evidence.md`, `docs/capabilities/opentelemetry-span-export.md`,
`docs/capabilities/log.md`, `CHANGELOG.md`, and one Decision Log line in
`docs/plans/67-freeze-the-public-surface.md`.
