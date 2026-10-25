---
id: 100
slug: support-explicit-thinking-off-with-truthful-provider-evidence
title: "Support explicit thinking off with truthful provider evidence"
kind: exec-plan
intention: intention_01m5sq5g5ye2ar84dj1pyn6517
created_at: 2026-10-25T14:23:32Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-25T14:23:32Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-25T14:25:44Z
      mode: "implement"
      note: "Adapt PR 5 with catalog capability checks and truthful strict evidence"
---

# Support explicit thinking off with truthful provider evidence

## Purpose / Big Picture


Let callers distinguish leaving the provider default alone (`Nothing`) from requesting no reasoning (`Just ThinkingNone`). This resolves the shared missing API in issues #1 and #4. Carry an explicit wire request when supported; report every fallback so strict evidence can refuse before dispatch. Do not equate a request with proof that the server actually disabled reasoning.

## Progress


- [x] 2026-10-25: Explicit off works through core options, provider requests, and CLI/config rendering; generated catalog facts distinguish models that accept disable.
- [x] 2026-10-25: Offline request serialization, catalog regeneration, strict complete/stream preflight, configuration, and observation-separation tests pass. Core 834, OpenAI 312, Claude 461, agent 117, TypeSafe 11, Effectful 4, and OpenTelemetry 11 tests passed (1,750 total).
- [x] 2026-10-25: User docs and ADRs 3/9 record off/default, capability, and strict-evidence boundaries. Documentation shapes (28 Haskell blocks and one KDL block), smoke-options, repository-prescribed OKF checks, formatting, and whitespace validation passed.

## Surprises & Discoveries


PR #5 supplies much of the implementation, but incorrectly exempts an unsupported host from strict checking for `ThinkingNone`: lacking controls does not prove that the model cannot reason. Its OpenAI policies also omit `none` for Sol/Luna despite support, and leave older reasoning models unconstrained. Its legacy Anthropic JSON default assumes disable support that was never recorded.

Issue #4 overstates default-on behavior: Anthropic documents Opus 4.6–4.8 as default-off. The Haiku 5.5 report is still valid. Ollama v0.30.6 source explicitly converts `reasoning_effort: none` to native `think: false` and rejects `minimal`.

## Decision Log


Use PR #5 as implementation input, preserve its contribution in the final commit, and correct the evidence and capability gaps. Keep the existing best-effort preference contract: unsupported off requests carry an adjustment; strict evidence rejects those adjustments. Treat unsupported host controls as unknown behavior, even for off. Only a catalog model that does not support reasoning can satisfy off by omission.

Keep `ThinkingNone` distinct from positive effort and from `Nothing`. Provider adapters own translation; model-specific restrictions are catalog facts. Anthropic legacy/unannotated compatibility records must not invent disable support. Sonnet 5.5's `between_tools` is not a promise of no thinking blocks and must not be represented as exact full disable. No native Ollama transport is added: the existing OpenAI-compatible transport carries `none`.

## Outcomes & Retrospective


Issues #1 and #4 are valid manifestations of the missing explicit off preference.
Adapted PR #5 to current master, corrected its unsupported-host strictness exemption,
used the SDK's existing native none constructor, made legacy Anthropic capability
loading conservative, and corrected curated OpenAI effort policies. User/API/CLI
surfaces distinguish off from omission; requested, translated, and observed facts
remain separate. Evidence schema 2.7 adds none without altering digest rules.

The provider tests serialize requests without contacting real inference services;
the reports' latency/token measurements were not reproduced. DeepSeek, OpenRouter,
Together, and the Claude CLI retain explicitly recorded low-effort fallbacks for
none. Supporting their distinct disable mechanisms is outside the two reported
API paths. Sonnet 5.5's partial between-tools mode is deliberately not labeled
full disable. No new provider transport, model, dependency version, or release is
introduced. No material external friction was encountered; the strict capability
metadata warning is already documented by the repository, and its prescribed
non-strict profile-enforced validation passes.

## Context and Orientation


`baikai/src/Baikai/ThinkingLevel.hs` owns the shared ordered effort vocabulary and parser. `baikai/src/Baikai/Compat.hs` owns model compatibility records. JSON under `baikai/data/models/` is generated into `baikai/src/Baikai/Models/Generated.hs` by `baikai/gen/GenModelsCore.hs`; `baikai/fetch/FetchModelsCore.hs` preserves curated facts when refreshing the catalog.

`baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` creates Anthropic's thinking object and evidence together. `baikai-openai/src/Baikai/Provider/OpenAI/Shape.hs` does the same for Chat-compatible wire shapes; `baikai-openai/src/Baikai/Provider/OpenAI/Responses/Request.hs` handles Responses. CLI/Agent/Interactive renderers consume the same level vocabulary. `baikai/src/Baikai/Evidence.hs` classifies adjustments for strict dispatch checks.

[ADR 2](../adr/0002-requested-translated-observed-are-never-collapsed.md) separates caller intent, serialized translation, and server observations. [ADR 3](../adr/0003-the-adapter-owns-the-translation-description.md) requires evidence to come from the actual adapter. [ADR 9](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) requires model-specific facts in generated records, with no model-name tests in adapters. [ADR 14](../adr/0014-strict-evidence-means-a-record-exists.md) requires strict calls to deliver the promised evidence record.

## Plan of Work


First introduce the off constructor, rendering/parsing and provider mappings, adapting PR #5 to current master. Make Anthropic disable capability explicit and conservative for old persisted data. Use OpenAI's existing accepted-effort lists to distinguish models that accept none from models that require positive effort. Preserve unchanged requests for `Nothing` and existing supported positive levels.

Then add meaningful tests through request serialization and registry strict preflight, checking both complete and stream paths when refusal is required. Verify a local Ollama-style model emits none, supported Claude emits only disabled (no effort/display/budget), unsupported models record a fallback, and unknown host controls cannot satisfy strict off. Verify fetch/generation preserves capability facts and CLI/config accepts none.

Finally update user docs, unreleased notes, and the existing evidence/catalog ADRs, run focused tests and the affected package suites, and commit on the current branch with plan/intention trailers.

## Concrete Steps


Run from the repository root:

```bash
nix develop --no-write-lock-file -c cabal run baikai-gen-models
nix develop --no-write-lock-file -c cabal test baikai-test baikai-openai-test baikai-claude-test baikai-agent-test
nix develop --no-write-lock-file -c cabal test baikai-typesafe-test baikai-effectful-test baikai-trace-otel-test --test-options=--hide-successes
nix develop --no-write-lock-file -c cabal test doc-shapes smoke-options
okf validate docs/capabilities --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf validate docs/user --strict --profile mori/user-documentation-profile.dhall --profile-enforce --log-enforce
nix fmt
git diff --check
```

The generator must agree with the checked-in catalog; test suites must report no failures. Additional dependent package checks are warranted where the new exhaustive constructor affects their compilation.

## Validation and Acceptance


A reasoning model at a custom localhost OpenAI-compatible endpoint with `Just ThinkingNone` serializes `reasoning_effort: none`; `Nothing` omits it. Anthropic Haiku 5.5 serializes `thinking: {type: disabled}` and no effort/display/budget, including alongside structured output. Always-on models never receive a prohibited disable value. Restricted OpenAI models resolve only to accepted values and expose the adjustment. Strict calls whose host cannot transmit off or whose model clamps off fail before any dispatch; supported off and a known non-reasoning model are not rejected for thinking translation. JSON/parser/config and CLI rendering retain the distinction between none and omission. Offline tests prove these request contracts, not latency savings or provider execution behavior.

## Idempotence and Recovery


Generation and tests are repeatable. Work remains on the current branch. No publishing, issue comments, or remote merges are required. Re-run the generator after catalog edits; do not hand-maintain generated capability records.

## Interfaces and Dependencies


Add `ThinkingNone` to `ThinkingLevel` and an explicit Anthropic disable capability. This is a public sum-type expansion and must be documented for the next PVP major release. Reuse the current openai and claude dependencies; dependency sources were located with Mori at `mori://MercuryTechnologies/openai/packages/openai` and `mori://MercuryTechnologies/claude/packages/claude`. Both SDKs already expose disabled/none variants. No dependency upgrade or model catalog expansion is needed.
