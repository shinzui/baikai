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
  revisions:
    - model: "gpt-6-sol"
      harness: "codex-cli"
      at: 2026-09-23T17:08:06Z
      mode: "implement"
      note: "Added focused smoke cases and began offline compatibility assertions"
---

# Prove GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5 live compatibility

This ExecPlan is a living document. Update Progress, Discoveries, Decisions, and Outcomes as work proceeds.


## Purpose / Big Picture

A maintainer can run one bounded command that proves GPT-6 Sol, GPT-6 Luna, and Claude Opus 5.5 actually answer on Baikai's selected APIs and complete a function-tool conversation. A catalog build cannot show account access or live protocol compatibility. The result names requested and observed models, dispatched endpoints, tool calls, and cost bases without exposing prompts, credentials, or opaque reasoning.


## Progress

- [x] 2026-09-23 17:12 UTC: Add three model pairs and six named cases to the existing focused smoke mode; all ten selectors and provider-key preflights pass without network access.
- [x] 2026-09-23 17:12 UTC: Add offline assertions for case selection, request shaping, replay, and pricing; the full prescribed offline gate passes.
- [x] 2026-09-23 17:15 UTC: Run required-key live text and tool checks and preserve dated redacted output in `docs/validation/plan-82/2026-09-23-live-summary.json`; Sol and Luna passed both cases.
- [x] 2026-09-23 18:11 UTC: Retry `opus55-text` and `opus55-tools` with the Default Workspace selected through `ANTHROPIC_WORKSPACE_ID`; both passed, and the tool case used two calls with one dispatcher invocation. Retry the earlier failed Fable cases as well; both passed.
- [x] 2026-09-23 17:15 UTC: Update `docs/user/models-and-providers.md` with the ten-case command and observed scope.
- [x] 2026-09-23 18:11 UTC: Preserve `docs/validation/plan-82/2026-09-23-complete.json`, update the guide, and close the plan after all ten cases have passed across the initial run and selected retries.


## Surprises & Discoveries

2026-09-23: The first fetch produced 23 OpenAI and 11 Anthropic records because the old include sets filtered out the three new IDs. After curation, a fresh candidate produced 25 and 12 records, including all three, with no new-record diff against the reviewed catalog. A skipped case is still not proof of live support.

2026-09-23: The Anthropic SDK's typed request omits `tool_choice` for `ToolChoiceNone`; Baikai's transport shaper inserts the wire-level `none` choice. The Opus binding test therefore checks the captured transport request, which is the behavior the provider receives. The first offline run exposed this fixture mismatch; the corrected full gate passed.

2026-09-23: The required-key run had both credential alternatives present, but Anthropic returned `auth_error` with HTTP 401 for Fable and Opus 5.5. No Anthropic model or usage was observed. Sol and Luna each passed text and a two-call tool case with one dispatcher invocation; the runner verified the fixed timestamp in each final answer. The redacted evidence removes provider request and response IDs while retaining endpoints, observed models, cost bases, and status. A present credential is not proof of account access.

2026-09-23 18:00 UTC: Reloading `direnv` renewed its cache, and the selected Opus text and tool calls each reached `/v1/messages`; both still received `auth_error` HTTP 401 with no observed model. In the reloaded environment `ANTHROPIC_KEY` was set and `ANTHROPIC_API_KEY` absent. The credential is present but still rejected. The two-case retry artifact is redacted and dated.

2026-09-23: A replacement key cleared authentication but `opus55-text` returned `invalid_request_error` HTTP 400. A minimal direct Messages probe exposed the safe error: the key is not workspace-scoped and requires `anthropic-workspace-id`. The List Workspaces API returned an empty list; Anthropic's documentation says it omits the Default Workspace. No model or usage was observed, so this is an account-routing prerequisite rather than evidence of an Opus wire incompatibility.

2026-09-23 18:11 UTC: The signed-in Claude Console showed one workspace, Default, with its ID. Passing that ID through the optional smoke-runner header made Opus text and tools pass; selected Fable retries passed too. The combined ten-case evidence omits the workspace ID, credentials, request IDs, response IDs, prompts, and opaque reasoning. The live Opus responses contained zero reasoning blocks, so signed-thinking replay remains proven by offline fixtures rather than by this live run.


## Decision Log

2026-09-23: Extend the existing `--new-models` smoke mode and preserve its `baikai.new-model-smoke/1` output shape. This keeps one credential preflight and evidence format for five recently added bindings. Use the existing Responses and Messages adapters; investigate an observed mismatch before changing either provider. Catalog-specific wire facts remain in generated records under ADR 0009.

2026-09-23: Reuse the existing provider protocol fixtures and add binding-specific checks for Sol/Luna response shaping, replay identity, and tier prices, plus Opus forced-choice, signed replay, and cache/speed prices. This catches catalog regressions without duplicating the provider's generic tests.

2026-09-23: Leave the plan open after the Anthropic 401 response and retry only its failed named cases once authentication is repaired. The response contains no model observation or usage, so it cannot support an Opus compatibility claim or a provider wire change.

2026-09-23: Let the focused smoke runner read optional `ANTHROPIC_WORKSPACE_ID` and send it as an Anthropic-only per-call header through the existing `Options.headers` path. Workspace-scoped keys still work without it, and the ID never enters smoke output. This uses the public header override interface without adding a provider-model branch.

2026-09-23: Combine successful results from the initial full run with only the failed Anthropic cases rerun after workspace selection. This yields ten observable passes while avoiding duplicate paid calls. Keep the earlier 401 and workspace-required 400 records as diagnostic history.


## Outcomes & Retrospective

Completed on 2026-09-23: The six new cases are selectable and the prescribed offline suite passes. Sol and Luna text and tool cases passed live through `/v1/responses`; Opus 5.5 text and tool cases passed through `/v1/messages`. The combined redacted record has ten passed results, including the existing Astra and Fable cases. Every observed model matches its request, every tool case has two calls and one dispatcher invocation, and every response has a complete standard token-rate cost basis. The runner checked the exact fixed timestamp in each tool final answer. Live responses exposed no reasoning blocks, so encrypted/signed continuation is supported by offline fixtures rather than live observation. Cost remains a local estimate, not invoice reconciliation. The expired first key and the replacement key's workspace requirement were account setup constraints, not adapter incompatibilities. ADRs 0009, 0019, and 0020 already cover the durable protocol and pricing architecture; no new ADR is needed.


## Context and Orientation

`baikai-smoke/test/NewModelsSmoke.hs` implements bounded text and function-tool cases for Astra, Fable, Sol, Luna, and Opus 5.5. It accepts optional `ANTHROPIC_WORKSPACE_ID` for multi-workspace Anthropic keys through the existing per-call header override. `baikai-smoke/test/SmokeOptions.hs` owns named-case parsing, and `baikai-smoke/test/SmokeOptionsSpec.hs` checks it without credentials. `baikai-smoke/test/Smoke.hs` registers OpenAI Chat, OpenAI Responses, and Anthropic Messages before dispatch. [Plan 77](77-prove-new-model-compatibility-with-focused-offline-and-live-checks.md) records that earlier focused work and evidence.

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

Expected live output has six `passed` results for the new cases, the existing four results, and one `baikai.new-model-smoke/1` JSON document. With a multi-workspace Anthropic key, set `ANTHROPIC_WORKSPACE_ID` to the ID shown in Claude Console Settings → Workspaces before the command; a workspace-scoped key needs no extra variable. On 2026-09-23 the initial full run failed Anthropic authentication, so successful OpenAI calls were preserved and only failed Anthropic cases were rerun after workspace selection. The combined ten-pass record is `docs/validation/plan-82/2026-09-23-complete.json`. Do not record raw conversations or opaque reasoning.


## Validation and Acceptance

Milestone 1 passes when every named selector returns exactly one case and required-key preflight fails without dispatch when its provider key is missing. Milestone 2 passes when fixtures show exact shaped routes, rejected configurations, tool identities, replay state, and pricing categories. Milestone 3 passes only when all six new live cases report `passed`, observed endpoints and models match, and tool cases report a dispatcher invocation and exact timestamp. A skip, empty text, incomplete usage, or zero tool calls is not acceptance. Cost calculations remain local estimates, not an invoice match.


## Idempotence and Recovery

Offline tests and case parsing are repeatable. Live calls are paid; preserve successful evidence and rerun only a failed selected case. Keep the original four cases intact. If account access is absent, the credential is rejected, or workspace selection is required, retain redacted failure output and leave affected live Progress unchecked until a selected retry passes. Never paste credentials or workspace IDs into plan or validation artifacts.


## Interfaces and Dependencies

Use `SmokeOptions.caseNames :: [String]` and `NewModelsSmoke.runNewModels :: Bool -> Maybe String -> IO Bool`. `Baikai.Provider.OpenAI.Responses` and `Baikai.Provider.Claude.Api` already register routes in `Smoke.hs`; `Baikai.Provider.Registry.completeRequest` makes the public call and `Baikai.Context.appendToolResult` builds the next turn. Mori identifies dependency sources as `mori://MercuryTechnologies/openai/packages/openai` and `mori://MercuryTechnologies/claude/packages/claude`; their local `OpenAI/V1/Responses.hs` and `Claude/V1/Messages.hs` are the SDK files to inspect if needed. Keep model restrictions in generated catalog facts per ADR 0009, never adapter ID branches. This plan depends on the catalog refresh and completed Astra/Fable route work in plan 77; it has no shared-interface owner.


## Revision note

2026-09-23: Implemented the selectors, binding checks, offline validation, and live probe. Sol and Luna passed; Opus could not pass because the available Anthropic credential returned HTTP 401. The plan remains open for two targeted retries.

2026-09-23: After the user reloaded `direnv`, reran only the two Opus cases. The credential was present but the provider again returned HTTP 401, so acceptance remains open. Added a separate redacted retry artifact rather than overwriting the first live record.

2026-09-23: The replacement key returned HTTP 400 requiring an explicit workspace ID. Added optional smoke-runner header support and a redacted error record; live acceptance remains open pending workspace selection.

2026-09-23: The Default Workspace ID resolved the replacement key's routing requirement. Opus and Fable text/tool cases passed on selected retries; all ten focused cases are present as passes in one redacted combined record. The plan is complete.
