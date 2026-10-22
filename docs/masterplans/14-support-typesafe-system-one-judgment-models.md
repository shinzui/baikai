---
id: 14
slug: support-typesafe-system-one-judgment-models
title: "Support TypeSafe System One judgment models"
kind: master-plan
created_at: 2026-09-26T14:42:40Z
intention: "intention_01m3f2jkgpej3s8m0wpa7cw5nz"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex"
    at: 2026-09-26T14:42:40Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T03:06:57Z
      verdict: "changes-requested"
      note: "Stale against the 2026-10-21 child revisions: confidence field, Baikai.Judgment in core, and the typesafe-hs cross-repository dependency and Hackage gate are unrecorded"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T03:25:19Z
      mode: "update"
      note: "Refresh for 2026-10-21 child revisions, model the typesafe-hs dependency and Hackage gate, split former EP-84 into EP-99 and EP-84"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-22T04:20:50Z
      mode: "update"
      note: "Sync with the Shikumi consumer: record its 2026-10-21 reconciliation, correct the ADR 12 attribution, state EP-99's question-order rule"
---

# Support TypeSafe System One judgment models

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into `docs/adr/` using `agents/skills/exec-plan/ADR.md`.


## Vision & Scope

Implement [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md): a caller can submit one JSON state and a schema of closed-set questions to TypeSafe Jev, receive chosen answers, every declared answer's probability and the per-answer confidence the provider reports, and preserve that content through stream assembly, JSON persistence, traces, and call logs. A closed set means every allowed answer is declared before the call. The new `baikai-typesafe` package supplies the provider; catalog records expose the judgment-only capability without requiring callers to recognize provider names. The protocol baseline is TypeSafe's OpenAPI document, version 0.2.0, published at https://api.typesafe.ai/openapi.json; the DSPy 3.4.0 client that IR-10 was written from is a historical cross-check only.

The schema compiler, generation-control audit and answer validator are provider-neutral and live in the core package as `Baikai.Judgment`, so a second judgment dialect (OpenAI's Decisions API, in public beta since 2026-10-06) would add only an API tag, a catalog record, a wire mapping and a transport. That second adapter is outside this initiative. The TypeSafe wire types and codecs come from the in-house client `mori://shinzui/typesafe-hs`, a separate repository whose first release is planned by `mori://shinzui/typesafe-hs/masterplans/1-deliver-the-initial-typesafe-hs-client` and specified from this initiative's needs in that repository's `docs/initial-spec.md` (requirements R1 to R12; artifact-level URI pending). Building that client is not part of this MasterPlan, but its progress gates the adapter plan (see Dependency Graph).

Completion includes typed refusals before dispatch, strict response validation, truthful call evidence, offline HTTP acceptance, an explicitly selected live smoke case, compiled documentation examples, and a coordinated PVP version/changelog preparation. Publishing packages and creating release tags require a separate release operation, and `baikai-typesafe` cannot be released before `typesafe-hs` is on Hackage. Rich decision types, local thresholds and cuts, locally computed weights, calibration, and generative token probabilities remain outside this initiative; Baikai preserves the expected score and confidence a provider reports and never derives them. The consumer initiative is `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`; its routing work is `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`.


## Decomposition Strategy

Use three behavior-oriented child plans in a line. EP-83 establishes a usable provider-neutral data path, including handling in existing providers and persistence; its tests use a local synthetic provider, so its acceptance is independent of Jev. EP-99 adds the judgment-only catalog facts and the provider-neutral judgment layer to core: a router can ask `isJudgmentOnly`, a schema compiles into neutral questions, and neutral answers validate into one data block, all proven by pure tests. EP-84 delivers the TypeSafe adapter on that layer and the in-house client, with transport, evidence, documentation and package integration.

Until 2026-10-22 the second and third streams were one plan. The 2026-10-21 revision moved the compiler and validator from the provider package into core for a future second dialect, which gave that work its own demonstrable behaviour, its own tests, and a different dependency profile: it needs only EP-83, while the adapter also waits on the external client, which had no Cabal package on 2026-10-22. Splitting keeps Baikai's critical path moving while the client is built and restores balance between the plans. Splitting further (transport from adapter, packaging from adapter) would scatter ownership of one request contract; splitting by package would separate content from the consumers that must preserve it.

The relevant local decisions are [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md), separating requested and observed evidence; [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md), placing translation descriptions in the adapter; [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md), excluding retries and unsupported claims about provider internals; [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md), making model facts catalog-owned; [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md), governing resource cleanup; [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md), centralizing error classification; [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md), enforcing actual evidence presence; [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), compiling capability examples; and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md), making unknown pricing explicit. No existing local ADR defines judgment data. Mori discovery found no indexed cross-repository ADR for this feature; the consumer plan and actual cache source were inspected through its registered project. The client repository has no ADR corpus yet; its first child plan creates one that cites Baikai's ADR 0005 and ADR 0011 as the reasons the client carries no retry, classification or environment policy.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 83 | Preserve structured data and probability evidence across Baikai | [docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md](../plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md) | None | None | Not Started |
| 99 | Add a provider-neutral judgment layer and judgment-only catalog facts to core | [docs/plans/99-add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core.md](../plans/99-add-a-provider-neutral-judgment-layer-and-judgment-only-catalog-facts-to-core.md) | EP-83 | None | Not Started |
| 84 | Deliver the TypeSafe System One provider and judgment catalog | [docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md](../plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md) | EP-83, EP-99 | None | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled. EP-84 additionally depends on work outside this repository; see Dependency Graph.


## Dependency Graph

Implement EP-83, then EP-99, then EP-84. EP-99 compiles against EP-83's `DataContent` and typed request-problem constructors. EP-84 compiles against both: EP-83's data blocks, atomic data events, named response codecs and persistence/logging contracts, and EP-99's judgment layer, API tag, output kind and catalog entries. Both are hard dependencies; no temporary parallel evidence carrier or duplicate compiler is permitted.

EP-84 also depends on the in-house client, implemented in parallel in its own repository under `mori://shinzui/typesafe-hs/masterplans/1-deliver-the-initial-typesafe-hs-client`. As of 2026-10-22 that repository has a specification and six drafted child plans but no Cabal package, and Hackage has no package named `typesafe-hs`. The gates are:

- EP-84 Milestone 1's wire mapping imports the client's request and response types, so it needs the client's request-encoding and response-decoding plans Complete: `mori://shinzui/typesafe-hs/plans/2-encode-system-one-requests-deterministically` and `mori://shinzui/typesafe-hs/plans/3-decode-system-one-responses-model-listings-and-error-bodies`. Until the client is on Hackage, `cabal.project` references it with a `source-repository-package` stanza pinned to a commit, never a local path.
- EP-84 Milestone 3's isolated source-distribution build, and any release of `baikai-typesafe`, need the client published by `mori://shinzui/typesafe-hs/plans/6-prepare-the-first-hackage-release-of-typesafe-hs`. The stanza is removed in the change that sets the released bound. EP-84 cannot be marked Complete before this.
- The client's servant binding (its plan 4) and conformance suite (its plan 5) are soft dependencies: Baikai's provider does not call the servant client, but the conformance suite is the evidence that the wire types match the specification Baikai's fixture was written against.

```text
EP-83 ──> EP-99 ─────────────────────────────────┬──> EP-84 M1 (wire mapping) ──> EP-84 M2
typesafe-hs EP-1 ──> EP-2, EP-3 ─────────────────┘
typesafe-hs EP-4, EP-5 ──> EP-6 (Hackage) ──────────> EP-84 M3 (sdist gate, release)
```

EP-83 and EP-99 proceed regardless of the client's state. The Shikumi consumer does not block Baikai. Baikai's offline acceptance must run in this checkout with no consumer checkout installed. Consumer migration guidance must name the exact public API, serialization semantics, and refusal policy delivered here.


## Integration Points

**Content, events, and persistence — owner EP-83.** `baikai/src/Baikai/Content.hs` defines `UserData Value` and `AssistantData DataContent`, where `DataContent` has `value :: Value`, `probabilities :: Maybe (Map Text (Map Text Double))`, `confidence :: Maybe (Map Text Double)`, and `method :: Maybe Text`. The confidence map was added on 2026-10-21 at the adapter plan's request so provider-reported per-answer confidence has a carrier; it is encoded under `confidence`, omitted when absent, and never derived from the distribution. `DataStart`/`DataEnd` carry atomic structured blocks through `Baikai.Stream.Event` and `Baikai.Stream`. EP-83 owns named full-response JSON codecs in a new `Baikai.Response.JSON` module, plus optional `structuredData` fields on terminal trace events and call-log entries. EP-99 builds `DataContent` values and EP-84 carries them; neither redefines these interfaces. Boolean keys are `true` and `false`; score keys are decimal indices. The method tag is `provider_classification`; probabilities and confidences are validated individually and never renormalized.

**Typed request problems — owner EP-83.** Extend `BaikaiError` with optional typed `requestProblem` detail and constructors for unsupported features (including the offending field path) and unsupported models. Both remain in `InvalidRequest` and are non-retryable. Existing JSON without this field still decodes. EP-99 and EP-84 use these smart constructors and core transport classification; neither adds a competing error category vocabulary.

**Judgment protocol — owner EP-99, in core.** `baikai/src/Baikai/Judgment.hs` defines `Judgment`, `JudgmentKind`, `Judgments`, `compileJudgments`, `judgmentUserMessage`, `refuseGenerationControls`, `prepareJudgment`, `JudgmentAnswer`, `validateAnswers` and the method constant. `Judgments` are ordered by the schema's `required` array when it lists every declared property exactly once, otherwise by ascending key, because aeson objects do not preserve declaration order (EP-99 Decision Log, 2026-10-22); the consumer's parity test relies on that rule. The validator is the only code that builds a judgment `DataContent`; an adapter maps `Judgments` to its wire and its wire answers back to `Map Text JudgmentAnswer`, applies its own part-kind and content rules, and nothing more. The compiler passes instructions and descriptions through as JSON values; a dialect that accepts fewer shapes refuses them by path in its adapter. Numbers reach the neutral side as `Double` only after bounds were checked on the wire representation, and the validator re-checks them. The module is exported through `baikai/src/Baikai.hs`: EP-83 adds its names first, EP-99 appends after them, and neither reorders existing exports.

**Model, API and catalog facts — owner EP-99; authentication and registry wiring — owner EP-84.** EP-99 adds `TypeSafeSystemOne` with wire tag `typesafe-system-one`, the catalog-carried `OutputKind` (`GenerativeOutput` or `JudgmentOutput`) with the pure `isJudgmentOnly` query, and `InputData`; it owns `Model` defaults/JSON/Show, generator and fetcher preservation, `baikai/data/models/typesafe.json`, the generated entries for `jev-latest` and `jev-preview`, and the audit of every existing API-tag match across the workspace, because the constructor lands there. A missing output kind in old model JSON defaults to generative. Catalog facts are never inferred from a `jev-` prefix. EP-84 owns the TypeSafe host entry in `Baikai.Auth.defaultApiKeyEnvForBaseUrl` (mapped to `TYPESAFE_API_KEY`), provider registry wiring, and every match inside the new package.

**TypeSafe wire types — owner `mori://shinzui/typesafe-hs`, consumed by EP-84.** `baikai-typesafe` depends on the package `mori://shinzui/typesafe-hs/packages/typesafe-hs` for the `TypeSafe.Wire` types, `encodeSystemOneRequest`, `decodeSystemOneResponse`, `parseErrorBody` and the number helpers; it does not use the client's servant layer (`TypeSafe.V1`) and makes its own http-client call. The client's binding decisions this initiative must respect, taken from its MasterPlan on 2026-10-22: `questions` is a `Vector (QuestionName, Question)` and choice criteria a `Vector (Text, Maybe Content)`, both encoded in declared order; `Content` has text, object and array constructors only, so a numeric or boolean instruction or description has no encoding and is refused by path in EP-84; every number is a `Scientific` with `unitInterval` and `finiteDouble` helpers that the decoders never apply, and token counts are `Int`; box questions and answers and an `assets` map are bound as ordinary constructors, which Baikai never sends (assets empty) and refuses by name on receipt; unknown `type` tags surface as `QuestionOther` and `AnswerOther`; the package enables `NoFieldSelectors` and derives `Generic` on every wire type, so Baikai reads its records through generic-lens labels as the rest of the workspace does. The client brings `servant` and `servant-client` into `baikai-typesafe`'s dependency closure; that is accepted because the workspace already resolves them through the `openai` package, and EP-84 verifies the bounds intersect. A requirement in the client's specification that cannot be met is recorded in EP-84's Decision Log before any adapter-side workaround.

**Evidence and accounting — owner EP-83 for representation, EP-84 for provider facts.** EP-83 adds structured content to serialization and response commitments while preserving old encodings, and versions the additive evidence change. EP-84 captures the exact request bytes and actual response model, request ID and usage. It extends the configuration projection only if needed to describe judgment configuration without copying state, instructions, or criteria descriptions. The existing allow-list already excludes the new `state` and `questions` fields safely. Response commitments include chosen values, probability maps, confidences and the method tag. Unknown prices remain explicitly unavailable estimates. Provider adapters supply evidence; trace sinks never infer it.

**Shared manifests, tests, and documentation — owner EP-84 for final integration.** EP-83 and EP-99 make the Cabal, source-module, test and changelog additions their standalone behaviour needs, each in its own test modules with exhaustive pattern matches. EP-84 adds the package to `cabal.project` and `mori.dhall` and to the smoke and doc-shapes dependencies; owns the `source-repository-package` stanza for the unpublished client and its removal before release; reconciles all dependency bounds and version changes once; and owns the final README, user guide, capability record, and IR-10 completion update. The release order is the client to Hackage first, then the coordinated Baikai release. No plan advances a published-version badge or a capability's released `since` value before publication.

**Consumer handoff — owner EP-84.** The Shikumi plan originally assumed generation defaults would be dropped. This initiative chooses to refuse every explicit generation/reasoning control, which IR-10 permits and makes fully observable without adding a new general adjustment protocol. Shikumi reconciled its MasterPlan 12 and EP-63 to that policy on 2026-10-21 (`mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`): its request-defaults layer will skip the thinking, speed and token-ceiling defaults for a judgment-only model, routing switches on `isJudgmentOnly`, the state travels as `UserData`, evidence is read from `AssistantData`, its own response codec is retained, and a parity test checks its schema reader against `compileJudgments`. The drop assumption lived in that MasterPlan, not in the consumer's ADR 12 (project-relative path `docs/adr/0012-apply-request-defaults-before-cache-and-observation.md`, artifact-level URI pending), which only fixes the defaults layer's position after routing; Shikumi amends that ADR when it implements the exemption. EP-84's migration guidance must match those assumptions. No out-of-repository edits are part of these child plans. Named response codecs avoid duplicate instances with the consumer's orphan instances; answer distributions remain in `AssistantContent`, independent of whether a cache removes per-call evidence.

During implementation, EP-83 records the durable content/serialization and typed-error decisions in ADRs; EP-99 records the provider-neutral judgment layer (why the protocol lives in core, what is adapter-owned, why provider-reported confidence and expected score are preserved) and the judgment capability as a catalog fact; EP-84 records wire validation, synthetic streaming, the refusal/default policy and the dependency on the in-house client rather than the community `typesafe-ai` packages. Update existing decisions when their subject already covers the change. At final completion, distill all three child plans' decisions and discoveries into the ADR corpus.


## Progress

Planning complete; all three child plans are Not Started. EP-83 is ready to implement; EP-99 follows it and needs nothing outside this repository; EP-84's wire mapping waits on the client's plans 2 and 3, and its release gate on the client's Hackage publication (see Dependency Graph). Remaining initiative gates are the exact offline three-question HTTP fixture with its noul-criteria variant, the refusal/malformed-response matrix through both public call modes, full-response and trace/log round trips, package/example/version integration, and `typesafe-hs` 0.1.0.0 on Hackage with the `source-repository-package` stanza removed. The opt-in live test must exist and be key-gated; report separately whether it was actually exercised.


## Surprises & Discoveries

The request describes a whole-response JSON round trip, but `baikai/src/Baikai/Response.hs` has no Aeson instances. The registered consumer supplies orphan instances in `mori://shinzui/shikumi`, project-relative path `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` (artifact-level URI pending), and deliberately removes per-call evidence. Adding global instances in Baikai would conflict with those instances. Named codecs provide a testable core contract without that conflict.

`TraceEvent` and `CallLogEntry` currently record usage/cost summaries, not response content. Merely adding an `AssistantData` constructor would not satisfy IR-10's trace/log acceptance; EP-83 must add explicit optional data payloads and test their actual sink output.

Mori cannot currently resolve the consumer's new MasterPlan handle and has no registered `stanfordnlp/dspy` project. The Shikumi documents exist at its registered source path. DSPy's tagged primary source was checked directly; retain the canonical project URI plus source paths, with artifact-level URIs pending, rather than replacing those references with ambiguous filenames. On 2026-09-26 the Shikumi example's boolean criteria looked like an extension IR-10 did not specify. TypeSafe's OpenAPI 0.2.0 document, read on 2026-10-21, defines optional noul criteria, so EP-84 accepts them and its fixture gained a second variant; the same document makes `confidence`, `score`, `legend`, `model` and `usage` required where the DSPy client treated them as absent or optional. EP-84's Surprises & Discoveries has the detail.

2026-10-22: The client repository found that the published document has grown without a version bump (box questions and answers, image assets, a multipart body and two danger-zone headers, still labelled 0.2.0). Baikai needs none of it, but the client binds all of it, so EP-84's adapter handles the box constructors and the assets map explicitly rather than as unknown tags. The client's specification also assumed Baikai uses `OverloadedRecordDot`; Baikai's common stanza enables `OverloadedLabels` and reads records through generic-lens, which the client's `Generic` deriving supports.

2026-10-22: The 2026-10-21 revision of both child plans did not touch this MasterPlan, so for a day the coordination document contradicted its children on the content fields, the judgment layer's location, the noul criteria and the external client. A child revision that changes an integration point must edit this document in the same commit.

2026-10-22, consumer sync: Shikumi had already reconciled its MasterPlan 12 and EP-63 to this initiative on 2026-10-21, including the request-defaults exemption this document still described as pending, and the earlier wording here misattributed the drop assumption to the consumer's ADR 12. The same sync found that EP-99 said `Judgments` are in "schema property order" without saying how that order is recovered from an aeson object; the rule is now fixed in EP-99 so the consumer's parity test has something to compare.


## Decision Log

2026-09-26: Keep all generic structured-content propagation in EP-83 and all Jev-specific behavior in EP-84. Each has an independently demonstrable outcome; this avoids a separate integration-only child with no standalone behavior.

2026-09-26: Preserve the existing error category vocabulary with typed optional request-problem detail. Callers can distinguish unsupported features/models without parsing messages or destabilizing retry categories.

2026-09-26: Use named response codecs and strict refusal of explicit generation controls. These resolve the observed consumer-instance conflict and make the cross-repository handoff precise. Consumer-side suppression of generation defaults is documented as required adoption work.

2026-10-21, recorded here 2026-10-22: The protocol baseline is TypeSafe's OpenAPI 0.2.0 document; DSPy 3.4.0 is a historical cross-check. Provider-reported confidence and expected score are preserved, never derived (ADR 0002 and ADR 0003), which required the additive confidence map on EP-83's `DataContent`.

2026-10-21, recorded here 2026-10-22: The schema compiler, generation-control audit and answer validator live in core as `Baikai.Judgment`, so that a second judgment dialect (OpenAI Decisions) adds only a wire mapping and transport. Nothing this initiative ships should need redoing for that adapter; the adapter itself is excluded.

2026-10-21, recorded here 2026-10-22: TypeSafe wire types and codecs come from the in-house client `mori://shinzui/typesafe-hs`, specified from the adapter plan's needs, not from the community `typesafe-ai`/`typesafe-ai-core` packages. A one-maintainer 0.1.0.0 package would be a release-blocking Hackage dependency, its prefixed field names and lenient numeric decoding do not match this repository's conventions, and owning the specification mirror keeps drift handling in this project's control. The consequence is a cross-repository hard dependency and a fixed release order, modeled in the Dependency Graph.

2026-10-22: Split the former EP-84 into EP-99 (judgment-only catalog facts and the provider-neutral judgment layer in core) and EP-84 (the TypeSafe adapter on the in-house client, transport, evidence, documentation and packaging). The core work has its own demonstrable behaviour and pure tests, depends only on EP-83, and has a second intended consumer; the adapter also depends on the external client, which is not yet built. The split keeps the critical path moving and balances the plans. EP-84 stays as the adapter plan rather than being cancelled and replaced, so its history and provenance remain in one file; its Decision Log records the change.


## Outcomes & Retrospective


## Revision Notes

2026-10-22: Refreshed after review. Vision & Scope, Decomposition Strategy, the registry, Dependency Graph, Integration Points, Progress, Surprises & Discoveries and the Decision Log now reflect the 2026-10-21 child revisions (confidence map, `Baikai.Judgment` in core, OpenAPI 0.2.0 baseline, noul criteria), the in-house client `mori://shinzui/typesafe-hs` whose plans gate the adapter's wire mapping and release, and the split of the former EP-84 into EP-99 and EP-84. EP-84 was revised in the same pass; EP-83 was unchanged.

2026-10-22, later: Synced with the Shikumi consumer. The consumer handoff records Shikumi's 2026-10-21 reconciliation and corrects the ADR 12 attribution; the judgment-protocol integration point records EP-99's question-order rule, added to EP-99 in the same pass.
