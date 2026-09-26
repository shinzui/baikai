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
---

# Support TypeSafe System One judgment models

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into `docs/adr/` using `agents/skills/exec-plan/ADR.md`.


## Vision & Scope

Implement [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md): a caller can submit one JSON state and a schema of closed-set questions to TypeSafe Jev, receive chosen answers and every declared answer's probability, and preserve that content through stream assembly, JSON persistence, traces, and call logs. A closed set means every allowed answer is declared before the call. The new `baikai-typesafe` package supplies the provider; catalog records expose the judgment-only capability without requiring callers to recognize provider names.

Completion includes typed refusals before dispatch, strict response validation, truthful call evidence, offline HTTP acceptance, an explicitly selected live smoke case, compiled documentation examples, and a coordinated PVP version/changelog preparation. Publishing packages and creating release tags require a separate release operation. Rich decision types, thresholds, weighted scores, calibration, and generative token probabilities remain outside this initiative. The consumer initiative is `mori://shinzui/shikumi/masterplans/12-support-typesafe-jev-and-probability-backed-decision-outputs`; its routing work is `mori://shinzui/shikumi/plans/63-declare-decision-outputs-and-route-them-to-system-one-models`.


## Decomposition Strategy

Use two behavior-oriented child plans. The first establishes a usable provider-neutral data path, including handling in existing providers and persistence. Its tests use a local synthetic provider, so its acceptance is independent of Jev. The second delivers a real provider on that contract, including schema compilation, model capability/catalog support, transport, documentation and package integration. Splitting schema translation, transport, and packaging into additional plans would scatter ownership of the same request contract. Splitting by package would separate content from the consumers that must preserve it.

The relevant local decisions are [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md), separating requested and observed evidence; [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md), placing translation descriptions in the adapter; [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md), excluding retries and unsupported claims about provider internals; [ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md), making model facts catalog-owned; [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md), governing resource cleanup; [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md), centralizing error classification; [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md), enforcing actual evidence presence; [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md), compiling capability examples; and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md), making unknown pricing explicit. No existing local ADR defines judgment data. Mori discovery found no indexed cross-repository ADR for this feature; the consumer plan and actual cache source were inspected through its registered project.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 83 | Preserve structured data and probability evidence across Baikai | [docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md](../plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md) | None | None | Not Started |
| 84 | Deliver the TypeSafe System One provider and judgment catalog | [docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md](../plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md) | EP-83 | None | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled.


## Dependency Graph

Implement `docs/plans/83-preserve-structured-data-and-probability-evidence-across-baikai.md` before `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md`. The latter compiles against the former's data blocks, atomic data events, typed request-problem detail, and persistence/logging contracts. This is a hard dependency; no temporary parallel evidence carrier is permitted. Independent upstream documentation research can proceed at any time, but there is no parallel implementation assumption.

The Shikumi consumer does not block Baikai. Baikai's offline acceptance must run in this checkout with no consumer checkout installed. Consumer migration guidance must name the exact public API, serialization semantics, and refusal policy delivered here.


## Integration Points

**Content, events, and persistence — owner EP-83.** `baikai/src/Baikai/Content.hs` defines `UserData Value` and `AssistantData DataContent`, where `DataContent` has `value :: Value`, `probabilities :: Maybe (Map Text (Map Text Double))`, and `method :: Maybe Text`. `DataStart`/`DataEnd` carry atomic structured blocks through `Baikai.Stream.Event` and `Baikai.Stream`. EP-83 owns named full-response JSON codecs in a new `Baikai.Response.JSON` module, plus optional `structuredData` fields on terminal trace events and call-log entries. EP-84 only produces and consumes these interfaces. Boolean keys are `true` and `false`; score keys are decimal indices. The method tag is `provider_classification`; probabilities are validated individually and never renormalized.

**Typed request problems — owner EP-83.** Extend `BaikaiError` with optional typed `requestProblem` detail and constructors for unsupported features (including the offending field path) and unsupported models. Both remain in `InvalidRequest` and are non-retryable. Existing JSON without this field still decodes. EP-84 uses these smart constructors and core transport classification; it does not add a competing error category vocabulary.

**Model/API/catalog/authentication — owner EP-84.** Add `TypeSafeSystemOne` with wire tag `typesafe-system-one`, a catalog-carried `OutputKind` (`GenerativeOutput` or `JudgmentOutput`) and pure `isJudgmentOnly` query, and `InputData`. EP-84 owns `Model` defaults/JSON/Show, generator and fetcher preservation, `typesafe.json`, generated catalog entries, API normalization, host-based key lookup, and provider registry wiring. A missing output kind in old model JSON defaults to generative. Catalog facts are never inferred from a `jev-` prefix.

**Evidence and accounting — owner EP-83 for representation, EP-84 for provider facts.** EP-83 adds structured content to serialization and response commitments while preserving old encodings, and versions the additive evidence change. EP-84 captures the exact request bytes and actual response model, request ID and usage. It extends the configuration projection only if needed to describe judgment configuration without copying state, instructions, or criteria descriptions. The existing allow-list already excludes the new `state` and `questions` fields safely. Unknown prices remain explicitly unavailable estimates. Provider adapters supply evidence; trace sinks never infer it.

**Shared manifests, tests, and documentation — owner EP-84 for final integration.** EP-83 makes the Cabal/source-module/test and changelog additions necessary for its standalone content behavior, including provider adaptation and OpenTelemetry. EP-84 adds the package to `cabal.project`, `mori.dhall`, and smoke/doc-shapes dependencies; reconciles all dependency bounds and version changes once; and owns the final README, user guide, capability record, and IR-10 completion update. Both extend core tests in separate modules and retain exhaustive pattern matches. Neither advances a published-version badge or a capability's released `since` value before publication.

**Consumer handoff — owner EP-84.** The Shikumi plan assumes generation defaults may be dropped. This initiative chooses to refuse every explicit generation/reasoning control, which IR-10 permits and makes fully observable without adding a new general adjustment protocol. Consumer guidance requires routing to clear those defaults for judgment-only models. No out-of-repository edits are part of these child plans. Named response codecs avoid duplicate instances with the consumer's orphan instances; answer distributions remain in `AssistantContent`, independent of whether a cache removes per-call evidence.

During implementation, EP-83 records the durable content/serialization and typed-error decisions in ADRs; EP-84 records the judgment capability, wire validation, synthetic streaming, and refusal/default policy. Update existing decisions when their subject already covers the change. At final completion, distill both child plans' decisions and discoveries into the ADR corpus.


## Progress

Planning complete; both child plans are Not Started. EP-83 is ready to implement; EP-84 waits for its public content/error contracts. Remaining initiative gates are the exact offline three-question HTTP fixture, the refusal/malformed-response matrix, full-response and trace/log round trips, and package/example/version integration. The opt-in live test must exist and be key-gated; report separately whether it was actually exercised.


## Surprises & Discoveries

The request describes a whole-response JSON round trip, but `baikai/src/Baikai/Response.hs` has no Aeson instances. The registered consumer supplies orphan instances in `mori://shinzui/shikumi`, project-relative path `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` (artifact-level URI pending), and deliberately removes per-call evidence. Adding global instances in Baikai would conflict with those instances. Named codecs provide a testable core contract without that conflict.

`TraceEvent` and `CallLogEntry` currently record usage/cost summaries, not response content. Merely adding an `AssistantData` constructor would not satisfy IR-10's trace/log acceptance; EP-83 must add explicit optional data payloads and test their actual sink output.

Mori cannot currently resolve the consumer's new MasterPlan handle and has no registered `stanfordnlp/dspy` project. The Shikumi documents exist at its registered source path. DSPy's tagged primary source was checked directly; retain the canonical project URI plus source paths, with artifact-level URIs pending, rather than replacing those references with ambiguous filenames. The Shikumi example adds boolean criteria not specified by IR-10; the Baikai fixture follows IR-10's noul shape containing only type and instructions.


## Decision Log

2026-09-26: Keep all generic structured-content propagation in EP-83 and all Jev-specific behavior in EP-84. Each has an independently demonstrable outcome; this avoids a separate integration-only child with no standalone behavior.

2026-09-26: Preserve the existing error category vocabulary with typed optional request-problem detail. Callers can distinguish unsupported features/models without parsing messages or destabilizing retry categories.

2026-09-26: Use named response codecs and strict refusal of explicit generation controls. These resolve the observed consumer-instance conflict and make the cross-repository handoff precise. Consumer-side suppression of generation defaults is documented as required adoption work.


## Outcomes & Retrospective
