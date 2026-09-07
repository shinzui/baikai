---
id: 73
slug: make-model-capabilities-and-catalog-refreshes-endpoint-aware
title: "Make model capabilities and catalog refreshes endpoint-aware"
kind: exec-plan
created_at: 2026-09-07T23:27:01Z
intention: "intention_01m1z341nne5zszbdvzjmtab3z"
master_plan: "docs/masterplans/12-support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers.md"
---

# Make model capabilities and catalog refreshes endpoint-aware

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A caller selecting GPT-6 Astra through today's Chat Completions provider will receive an actionable local error when asking for tools, instead of a request sent to an endpoint that cannot perform that model's tool calls. Unsupported sampling settings will follow explicit catalog policy, and minimal reasoning will translate to low with evidence of that adjustment. A subsequent model refresh will check capabilities on the selected endpoint before advertising agent support.


## Progress


- [x] (2026-09-07) Inspect current mapping, catalog pipeline, and ADR contract.
- [x] (2026-09-07) Persist endpoint facts through curation, JSON and generation; pin Astra and reject malformed effort policies. Core suite: all 680 tests passed, including regeneration and refresh preservation. Claude library builds after selector disambiguation.
- [ ] Review a live fetch candidate and verify restrictions persist.
- [ ] Enforce request restrictions and test evidence through dispatch.
- [ ] Update documentation, refresh skill, and ADR; run acceptance checks.


## Surprises & Discoveries


The sampling selector is shared by OpenAI and Anthropic compatibility records. GHC requires record-dot or lens access at the two previously unqualified call sites; both now use explicit record access. No public selector was renamed.


## Decision Log


2026-09-07: Keep the existing Astra binding usable for text-only Chat Completions until the Responses provider exists. Reject tools on that route; do not remove the exported binding or silently reroute requests. The later Responses plan owns changing the binding's default API.

2026-09-07: Store acceptance facts in compatibility records and generated JSON, following ADR 0009. Use an explicit supported-effort list and the existing adjustment evidence to map minimal to low. Do not introduce another adapter table keyed by model name.


## Outcomes & Retrospective


Catalog milestone implemented and verified with 680 core tests, a Claude library build, formatter checks and `git diff --check`. Request enforcement, provider dispatch tests and workflow documentation remain outstanding.


## Context and Orientation


Baikai is a Haskell provider abstraction. A Model chooses an Api (the network protocol used for dispatch), limits, prices, and a compat record (facts used when shaping requests). The current Astra binding was added in commit aaecbf5. Its api is OpenAIChatCompletions and compat is CompatNone, which resolves host defaults rather than model-generation restrictions.

The OpenAI migration guidance retrieved 2026-09-07 states that Astra accepts Chat Completions for text, but tool calling requires Responses; it accepts low, medium, high, xhigh and max effort, not minimal, and rejects temperature and top_p. Source: https://developers.openai.com/api/docs/guides/latest-model. The model page's separate endpoint and feature lists do not establish that every feature exists on every endpoint. These facts are embedded here so implementation does not depend on a search result; recheck the official guide if implementation occurs after this date.

The relevant files are baikai/src/Baikai/Compat.hs, baikai/src/Baikai/Model.hs, baikai/fetch/FetchModelsCore.hs, baikai/gen/GenModelsCore.hs, baikai/data/models/openai.json, and baikai/src/Baikai/Models/Generated.hs. The fetcher currently curates OpenAI IDs in openaiInclude and emits file-level API and automatic compatibility. Request construction is mapRequest in baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs; injectThinkingShape in baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs currently forwards every canonical effort unchanged. prepareCall in baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs owns pre-network preparation.

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) requires generation facts in the catalog. [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) requires the actual request mapping to produce its own evidence. [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md) requires strict calls to fail when a translation weakens a requested setting or the required evidence cannot be delivered. No cross-repository ADR was needed.


## Plan of Work


### Milestone 1: Persist endpoint-specific OpenAI facts


Extend OpenAICompletionsCompat with supportsToolCalls, supportsSamplingParameters and supportedReasoningEfforts :: Maybe [ThinkingLevel]. Nothing preserves the current unconstrained host behavior; Just values must be nonempty, unique and ordered by supported effort. Preserve existing defaults for other models. Rename colliding selectors only if the compiler requires it and update all consumers together.

Replace the OpenAI ID-only curation with explicit generation facts where necessary, carrying dated sources. Teach the fetcher and generator to round-trip the OpenAI per-model compat block; retain old auto JSON for unaffected entries. Astra's Chat Completions entry must explicitly say no tools, no sampling and the five accepted effort levels. Regenerate with baikai-gen-models and pin these values in baikai/test/CatalogSpec.hs. Use renamed fake IDs in tests to prove behavior depends on facts rather than spelling. Core catalog tests must pass before moving on.


### Milestone 2: Enforce the facts before network dispatch


Add one pure capability validation path shared by complete and stream preparation. For Astra's text-only route reject a nonempty Context.tools or required/specific tool choice with InvalidRequest and a message explaining that this endpoint requires OpenAI Responses for tools. ToolChoiceAuto with no tools remains a normal text request; do not execute a tool or retry elsewhere.

Omit unsupported temperature/top_p according to the existing Anthropic sampling convention and describe the change using the repository's evidence vocabulary. Audit other sampling fields against current endpoint documentation rather than treating the two named fields as an exhaustive list. For effort, preserve supported values; map minimal upward to low when low is the first supported value and record the adjustment from the same mapping. Ensure describeThinking sees the same result so strict evidence refuses the downgrade before dispatch. Existing hand-rolled and third-party-host models keep their prior defaults.

Extend baikai-openai/test/ReasoningSpec.hs, ShapeSpec.hs, TransportSpec.hs and EvidenceSpec.hs with a request driver that counts calls. Invalid configurations must cause zero network calls and one valid error terminal; permitted text requests must have the exact shaped fields. The capability check is not an inference that a provider executed those settings.


### Milestone 3: Correct claims and make the refresh workflow catch this case


Update docs/user/models-and-providers.md and the Unreleased changelog to distinguish Astra text support from agent support. Amend agents/skills/update-models/SKILL.md to require migration-guide review and endpoint-specific tool validation, including the case where a model supports Chat Completions but tools require Responses. Add an offline models.dev-shaped fixture to baikai/test/FetchModelsSpec.hs proving refresh cannot overwrite explicit restrictions. Document source disagreements and leave unverified capabilities unadvertised.

Run the tests below and update ADR 0009 with the OpenAI extension when implementation establishes it. Coordinate schema edits with docs/plans/75-enforce-claude-fable-5-1-tool-choice-and-thinking-history-contracts.md and docs/plans/76-account-for-cache-writes-and-context-tier-model-pricing.md; preserve fields already added by them.


## Concrete Steps


All commands run from the repository root with the existing Nix-provided GHC/Cabal environment.

```bash
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-openai:baikai-openai-test
fourmolu --mode check baikai/src/Baikai/Compat.hs baikai/fetch/FetchModelsCore.hs baikai/gen/GenModelsCore.hs
git diff --check
```

Fetch into a temporary directory with cabal run baikai-fetch-models -- --out-dir DIRECTORY, compare with the committed data, then regenerate. Expected results are passing suites, zero generator drift, and a candidate Astra entry that retains explicit restrictions. Do not format Generated.hs manually.


## Validation and Acceptance


Astra plus a tool is rejected locally with a Responses-specific explanation. Astra text with minimal effort emits low in permissive mode and records an adjustment; strict mode rejects that downgrade with no network traffic. Low through max preserve their exact values. Unsupported sampling fields are absent. An older compatible model retains its existing behavior. Tests exercise both complete and streaming dispatch through the provider registry, not only a JSON helper. A fixture with an arbitrary model ID and Astra's facts behaves identically.


## Idempotence and Recovery


Generation and fixture tests are repeatable without keys. Keep the JSON and generated module in one commit. If official documentation changes, revise the dated curation facts and fixture expectations together. Do not repair failed refreshes by erasing restrictions or resetting unrelated work. No network inference is needed to complete this child; live verification is owned by the integration plan.


## Interfaces and Dependencies


This plan owns OpenAICompletionsCompat capability fields, their defaults, fetch/generator schema and pure request validation. It preserves ApiProvider's public shape. The later Responses plan consumes the effort-policy helper and defines its own endpoint tag and compatibility record. No dependency bump is planned; use the currently resolved SDK and, if an API change proves necessary, locate it first through mori registry show MercuryTechnologies/openai --full and verify any proposed release against Hackage and upstream tags.

Commits carry this file's ExecPlan trailer, the parent MasterPlan trailer and intention intention_01m1z341nne5zszbdvzjmtab3z. This explicit child intention takes precedence over the parent's intention.
