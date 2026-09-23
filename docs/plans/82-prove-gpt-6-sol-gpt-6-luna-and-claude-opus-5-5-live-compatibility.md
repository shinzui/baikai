---
id: 82
slug: prove-gpt-6-sol-gpt-6-luna-and-claude-opus-5-5-live-compatibility
title: "Prove GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5 live compatibility"
kind: exec-plan
created_at: 2026-09-23T16:41:12Z
intention: "intention_01m37j8q4pehr8vxnajbxqzxwg"
provenance:
  created_by:
    model: "gpt-6-sol"
    harness: "codex-cli"
    at: 2026-09-23T16:41:12Z
---

# Prove GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5 live compatibility

This ExecPlan is a living document. Update Progress, Discoveries, Decisions, and Outcomes as work proceeds.


## Purpose / Big Picture

A maintainer can run one bounded command that proves GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5 actually answer on Baikai's selected APIs and complete a function-tool conversation. A catalog build cannot show account access or live protocol compatibility. The result names requested and observed models, dispatched endpoints, tool calls, and cost bases without exposing prompts, credentials, or opaque reasoning.


## Progress

- [ ] Add three model pairs and six named cases to the existing focused smoke mode.
- [ ] Add offline assertions for case selection, request shaping, replay, and pricing.
- [ ] Run required-key live text and tool checks; preserve dated redacted output.
- [ ] Update the model guide with the command and observed scope, then close the plan.


## Surprises & Discoveries

2026-09-23: The first fetch produced 23 OpenAI and 11 Anthropic records because the old include sets filtered out the three new IDs. After curation, a fresh candidate produced 25 and 12 records, including all three, with no new-record diff against the reviewed catalog. A skipped case is still not proof of live support.


## Decision Log

2026-09-23: Extend the existing `--new-models` smoke mode and preserve its `baikai.new-model-smoke/1` output shape. This keeps one credential preflight and evidence format for five recently added bindings. Use the existing Responses and Messages adapters; investigate an observed mismatch before changing either provider. Catalog-specific wire facts remain in generated records under ADR 0009.


## Outcomes & Retrospective

Outstanding. No live calls for the three bindings had been run when this plan was created. At completion, record each case's result, date, and remaining access or accounting limitation; distill durable decisions into an ADR only if the protocol or catalog architecture changes.


## Context and Orientation

`baikai-smoke/test/NewModelsSmoke.hs` implements bounded text and function-tool cases for Astra and Fable. `baikai-smoke/test/SmokeOptions.hs` owns named-case parsing, and `baikai-smoke/test/SmokeOptionsSpec.hs` checks it without credentials. `baikai-smoke/test/Smoke.hs` registers OpenAI Chat, OpenAI Responses, and Anthropic Messages before dispatch. [Plan 77](77-prove-new-model-compatibility-with-focused-offline-and-live-checks.md) records that earlier focused work and evidence.

The new bindings live in `baikai/data/models/openai.json`, `baikai/data/models/anthropic.json`, and generated `baikai/src/Baikai/Models/Generated.hs`. Sol/Luna select Responses; Opus selects Messages. `baikai-openai/src/Baikai/Provider/OpenAI/Responses/Request.hs` shapes effort, tools, cache options, and replay. Its `Stream.hs` and `Assembler.hs` consume streaming events. `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs` rejects forced tools from catalog facts and chooses adaptive thinking; `Internal/Stream.hs` preserves signed blocks and extracts usage. `baikai/src/Baikai/Context.hs` appends tool turns. `baikai/src/Baikai/Cost/Pricing.hs` applies tier and cache-duration prices; `baikai/src/Baikai/Usage.hs` distinguishes missing counts from zero.

On 2026-09-23 the [Sol](https://developers.openai.com/api/docs/models/gpt-6-sol) and [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) pages specified Responses for function tools at default effort; Chat Completions allows them only at effort `none`. Both have 1,050,000 context and 128,000 output tokens. Standard prices per million input, cache read, cache write, and output tokens are Sol $2/$0.20/$2.50/$10 and Luna $0.10/$0.01/$0.125/$0.50. Above 272,000 input tokens, full-request input/cache rates double and output rises 1.5 times. The [Opus 5.5 page](https://platform.claude.com/docs/en/models/opus-5-5/overview) states 1M context, 128K output, $4/$0.20/$5/$20 base rates and $8 one-hour cache writes. Its [migration guide](https://platform.claude.com/docs/en/models/opus-5-5/migration-guide) states thinking cannot be disabled, forced `any`/named tools fail, and signed thinking must be replayed with append-only history. [Fast mode](https://platform.claude.com/docs/en/build-with-claude/fast-mode) is separately priced at $8/$0.40/$10/$40 and requires account access. The catalog guards forced choice, uses adaptive thinking, and carries both cache durations.

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) requires wire facts in catalog compatibility records. [ADR 0019](../adr/0019-reasoning-continuation-is-scoped-to-its-provider-and-model.md) scopes opaque replay. [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) separates base rates, tiers and duration rates from observed billing. No cross-repository ADR is required.


## Plan of Work

### Milestone 1: Select and shape six focused cases

Extend `caseNames` in `baikai-smoke/test/SmokeOptions.hs` with `sol-text`, `sol-tools`, `luna-text`, `luna-tools`, `opus55-text`, and `opus55-tools`. Extend model/credential pairs in `baikai-smoke/test/NewModelsSmoke.hs` in the same order. Keep low effort, 4096 output tokens, 120-second per-request timeout, and four-request tool bound. Each case uses a generated binding and registered provider. Update `SmokeOptionsSpec.hs` so selecting one case needs only that provider's credential group. Acceptance: pure tests show missing required keys fail before any network request and an unselected case is not counted.

### Milestone 2: Verify protocol and arithmetic offline

Add focused assertions with the generated models. Sol/Luna requests target `/v1/responses`, omit sampling at low effort, preserve function call IDs and encrypted continuation on the second turn, and price fresh/cache tokens on both sides of 272K. Opus requests reject required and named tool choice before transport; auto/none retain exact wire meaning. A two-turn fixture replays signed empty thinking and preserves the system/tools/message prefix. Verify five-minute, one-hour and fast rate selection, and that absent usage stays unknown. Reuse `baikai-openai/test/ResponsesSpec.hs`, `baikai-claude/test/FableContractsSpec.hs`, and existing pricing fixtures where they already prove identical behavior; add only model-specific assertions that catch a wrong binding. A passing offline suite does not close live acceptance.

### Milestone 3: Prove the live route

Run six selected cases with `--require-keys` and real credentials. Each text case returns nonempty text; each tool case invokes `get_time` and includes its fixed timestamp in the final answer. The JSON summary names the dispatched endpoint (`/v1/responses` or `/v1/messages`), separates requested and observed models, includes call/dispatcher counts, and states the cost basis. Preserve redacted output in `docs/validation/` with its date and update `docs/user/models-and-providers.md`. A missing key or skipped case leaves acceptance open. Diagnose one failed case with `--case` instead of repeating successful paid cases. For an actual wire/event mismatch, record the safe response shape, inspect the current SDK source through Mori, verify Hackage release and upstream tag, and make a bounded correction or new plan.


## Concrete Steps

Run from repository root `/Users/shinzui/Keikaku/bokuno/baikai`:

```bash
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes baikai-smoke:smoke-options
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys'
```

For a diagnosed single-case failure:

```bash
cabal test baikai-smoke:baikai-smoke --test-options='--new-models --require-keys --case sol-tools'
```

Expected live output has six `passed` results for the new cases, the existing four results, and one `baikai.new-model-smoke/1` JSON document. Do not record raw conversations or opaque reasoning.


## Validation and Acceptance

Milestone 1 passes when every named selector returns exactly one case and required-key preflight fails without dispatch when its provider key is missing. Milestone 2 passes when fixtures show exact shaped routes, rejected configurations, tool identities, replay state, and pricing categories. Milestone 3 passes only when all six new live cases report `passed`, observed endpoints and models match, and tool cases report a dispatcher invocation and exact timestamp. A skip, empty text, incomplete usage, or zero tool calls is not acceptance. Cost calculations remain local estimates, not an invoice match.


## Idempotence and Recovery

Offline tests and case parsing are repeatable. Live calls are paid; preserve successful evidence and rerun only a failed selected case. Keep the original four cases intact. If account access is absent, retain the keyless preflight output and leave the live Progress item unchecked. Never paste credentials into plan or validation artifacts.


## Interfaces and Dependencies

Use `SmokeOptions.caseNames :: [String]` and `NewModelsSmoke.runNewModels :: Bool -> Maybe String -> IO Bool`. `Baikai.Provider.OpenAI.Responses` and `Baikai.Provider.Claude.Api` already register routes in `Smoke.hs`; `Baikai.Provider.Registry.completeRequest` makes the public call and `Baikai.Context.appendToolResult` builds the next turn. Mori identifies dependency sources as `mori://MercuryTechnologies/openai/packages/openai` and `mori://MercuryTechnologies/claude/packages/claude`; their local `OpenAI/V1/Responses.hs` and `Claude/V1/Messages.hs` are the SDK files to inspect if needed. Keep model restrictions in generated catalog facts per ADR 0009, never adapter ID branches. This plan depends on the catalog refresh and completed Astra/Fable route work in plan 77; it has no shared-interface owner.
