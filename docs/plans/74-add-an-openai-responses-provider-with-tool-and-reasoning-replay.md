---
id: 74
slug: add-an-openai-responses-provider-with-tool-and-reasoning-replay
title: "Add an OpenAI Responses provider with tool and reasoning replay"
kind: exec-plan
created_at: 2026-09-07T23:27:01Z
intention: "intention_01m1z34288e5p9f6d5am62qmes"
master_plan: "docs/masterplans/12-support-gpt-6-astra-and-claude-fable-5-1-across-baikai-providers.md"
---

# Add an OpenAI Responses provider with tool and reasoning replay

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A caller can register a native OpenAI Responses provider, select GPT-6 Astra, stream its answer, execute a function tool through Baikai's existing caller-driven loop, and send the result back without losing reasoning continuation state. The existing Chat Completions provider remains available for other models and compatible hosts.


## Progress


- [x] (2026-09-07) Reverify Hackage preferred release 2.5.4, upstream tags (none), and local SDK through Mori; streaming driver and high-effort/current usage gaps remain.
- [x] (2026-09-07) Add API tag, Responses compat and optional `ThinkingReplay`/`replayState`; preserve legacy JSON and commitments, hide opaque payloads in Show, and reject replay at Chat/Claude boundaries. Full workspace builds.
- [x] (2026-09-07) Core (684), OpenAI (212), Claude (315) and doc-shapes suites pass; five public-surface tests re-run after adding Model serialization coverage.
- [x] (2026-09-07) Implement Responses request validation and a next-request fixture preserving persisted empty-summary/encrypted items through appendToolResult with matching call_id.
- [x] (2026-09-07) Map text/images, assistant history, tools/results, structured output, effort/sampling, metadata and supported cache preferences. Add the Responses HTTP path using shared SSE framing and manager ownership.
- [x] (2026-09-07) Request/HTTP validation: all 224 OpenAI tests pass; final exact-wire assertions pass in all 12 Responses cases. Formatter and diff checks pass.
- [x] (2026-09-07) Add pure Responses item/content-index assembler: live deltas, ordered parallel calls, snapshot reconciliation, opaque reasoning items, partial cut-off calls and raw terminal observations. All 236 OpenAI tests pass, including 12 assembler cases.
- [x] (2026-09-07) Attach the assembler to the bounded HTTP worker, classify nested/in-band failures and EOF, expose explicit Responses registration and fold completion from the same stream. Prove public two-turn runToolLoop with encrypted item/call_id preservation.
- [x] (2026-09-07) Attach exact request/normalized response commitments and observed model/IDs. Test conclusive-terminal and consumer-timeout cleanup plus a slow active consumer.
- [x] (2026-09-07) All 248 OpenAI tests pass after worker integration; formatter and diff checks pass.
- [x] (2026-09-07) Add ResponsesEvidenceSpec over real SSE decoding: strict success/refusal, local validation, HTTP/in-band errors, malformed JSON/EOF, single-byte fragmentation and trace cancellation. Share the existing byte-reader lifecycle contract with Responses.
- [x] Integrate EP-4 usage availability.
- [x] (2026-09-07) Preserve per-model API overrides and Responses compat through fetch/render/parse/generation. Activate Astra without renaming its binding; keep older OpenAI routes and Chat-only registration unchanged. Smoke setup explicitly registers both handlers.
- [x] (2026-09-07) Core 687, OpenAI 248 and compiled doc-shapes pass. A live refresh candidate has 23 OpenAI/11 Claude models semantically identical to the committed catalogs.
- [x] (2026-09-07) Final fetch-to-generator/catalog-backed replay assertions pass in 18 core and 36 Responses focused cases. Workspace build and 22-concept capability validation pass.
- [x] (2026-09-07) Document separate registration and stateless replay; CAP-14 registration example agrees with its compiled twin.
- [x] (2026-09-07) Reject duplicate function call IDs and completed reasoning missing replay state; reuse the request mapper's raw-item invariant.
- [x] (2026-09-07) All 265 OpenAI tests pass; capability validation covers all 22 concepts and diff/formatter checks pass.
- [x] Integrate EP-4 usage/pricing: reported cache writes, availability and service-tier facts feed the same payload/evidence cost; partial snapshots merge without double-counting.


## Surprises & Discoveries

Worker cancellation delivers the asynchronous exception before the driver's cleanup hook necessarily finishes. The cleanup fixture therefore waits on an explicit completion signal without relying on a GC or an immediate flag read. Responses terminal events conclude the call even when the peer keeps waiting; the worker bracket then cancels that wait.


The published SDK remains 2.5.4 with no upstream tags. Its reasoning input retains id/encrypted_content/summary, but its effort enum stops at high and its module explicitly lacks streaming transport. The source is available via mori://MercuryTechnologies/openai/packages/openai.

The full Claude suite exposed a pre-existing missing Fable 5.1 row in the provider test table; adding it activates the existing effort/cap/sampling regressions for the new model. The generic name `replay` collided with existing helpers, so the optional content field is `replayState` (JSON `replay_state`).


## Decision Log

2026-09-07: Serialize output items into one Baikai content block per item, buffering later output/content indexes until the current prefix completes. Final snapshots reconcile prefixes rather than append them. A function call lacking item completion remains a String argument prefix even if it parses as JSON. Keep the raw observed terminal response for usage availability and evidence integration.


2026-09-07: Add a separate OpenAIResponses API tag and provider; do not tunnel Responses through the Chat Completions tag. This keeps dispatch and evidence truthful.

2026-09-07: Use explicit full-history requests with store=false and returned encrypted reasoning continuation where supported. Do not require server-stored conversations or make Baikai own a new retry loop. The implementation must preserve the provider items needed for a second tool turn.


## Outcomes & Retrospective


The shared type and persistence foundation is implemented and builds throughout the workspace. Legacy thinking encodings and digest golden tests remain unchanged. The request mapper and a persisted second-request fixture are implemented; the shared HTTP driver sends POST /v1/responses. Explicit Responses registration and its worker/evidence integration are implemented. The public two-turn tool loop preserves encrypted reasoning and matching function results. Astra now selects Responses, backed by per-model fetch/generator overrides. Registration documentation and its compiled example are updated. Strict evidence and the byte-driver lifecycle contract now pass through the real SSE decoder. EP-4 integration is complete: the shared raw normalizer retains missing counters, cache writes and observed service tiers in costs and evidence, including partial failures. The final gate passes 708 core, 276 OpenAI, 335 Claude and 10 trace tests, compiled documentation, capability validation and the workspace build. This child is complete; paid live acceptance belongs to EP-5. ADR 0019 records the implemented boundary and persistence decision.


## Context and Orientation


This child depends on docs/plans/73-make-model-capabilities-and-catalog-refreshes-endpoint-aware.md for endpoint capability facts and effort normalization. That plan leaves Astra on a guarded, text-only Chat Completions route. This plan makes the existing openai_gpt_6_astra binding choose Responses only after the new provider is tested.

Baikai dispatches by Api in baikai/src/Baikai/Api.hs through ApiProvider and baikai/src/Baikai/Provider/Registry.hs. baikai-openai/src/Baikai/Provider/OpenAI/Api.hs currently exports register and openaiChatProvider. Its complete implementation folds the same streaming events that streaming callers consume. The transport is in baikai-openai/src/Baikai/Provider/OpenAI/Internal/Stream.hs; reusable bounded worker ownership is in baikai/src/Baikai/Provider/Internal/StreamWorker.hs. Evidence construction is in baikai/src/Baikai/Evidence/Build.hs. New code must preserve these contracts.

The SDK source was located through mori://MercuryTechnologies/openai/packages/openai. Hackage preferred.json reports 2.5.4 as the newest normal version on 2026-09-07; the upstream tag query returned no tags. The local 2.5.4 source exposes OpenAI.V1.Responses with CreateResponse, InputItem, OutputItem, reasoning items and ResponseStreamEvent, but its module comment says streaming transport is not implemented. Its effort enum stops at high and InputTokensDetails exposes only cached_tokens. Reverify those facts before choosing bounds or workarounds. Locate the repository with mori registry show MercuryTechnologies/openai --full; within that canonical project the source is openai/src/OpenAI/V1/Responses.hs (artifact-level URI pending). Do not assume the SDK event enum covers every current wire frame.

Official model guidance retrieved 2026-09-07 requires Responses for Astra function calls: https://developers.openai.com/api/docs/guides/latest-model. Responses uses POST /v1/responses and distinct output items for messages, reasoning, and function calls. Tool replies identify call_id, and reasoning items can contain an opaque encrypted continuation plus an item ID. These cannot be safely represented by concatenating reasoning text. Check the current Responses API reference when implementing request and event fixtures.

[ADR 0009](../adr/0009-provider-capability-facts-live-in-the-generated-catalog-record.md) keeps endpoint facts in Model compatibility. [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) separates requested model/effort from observed values; [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md) makes the adapter own translation evidence. [ADR 0010](../adr/0010-a-stream-consumer-that-stops-owns-cancelling-the-producer.md) requires bounded stream workers and consumer cancellation, [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md) centralizes transport errors, and [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md) requires an actual evidence record under strict mode. [ADR 0005](../adr/0005-what-baikai-deliberately-does-not-do.md) excludes provider retries. No dependency ADR was needed.


## Plan of Work


### Milestone 1: Define dispatch and lossless continuation


Add OpenAIResponses, wire name openai-responses, to baikai/src/Baikai/Api.hs and update exhaustive matches, environment-key defaults, evidence capability declarations, and public-surface tests across the workspace. Add Responses compatibility to baikai/src/Baikai/Compat.hs and Model's Compat sum, carrying endpoint-specific effort, sampling and cache behavior. Reuse the earlier plan's pure effort-policy helper, not Chat Completions JSON fields.

Extend baikai/src/Baikai/Content.hs with optional provider-scoped replay state on ThinkingContent. Define a typed wrapper identifying API and originating model and containing the ordered JSON item(s) needed for continuation. Preserve current Anthropic signature/redacted semantics; never stuff a Responses reasoning ID into an Anthropic signature. Old JSON without replay state decodes to Nothing. Update defaults, constructors, JSON round-trips and canonical response envelopes in baikai/src/Baikai/Evidence.hs so the commitment includes replay state. Keep opaque state out of user-facing rendered reasoning and diagnostic Show output. A target provider must reject incompatible replay state explicitly rather than leak it to another endpoint or silently claim it was replayed.

Prove with a fixture that an empty reasoning summary plus encrypted content and item ID survives responseMessage, Context appending, JSON persistence and the next request. Determine the exact minimum item fields from the current API, preserve their ordering, and record the resulting public-API compatibility impact. This milestone builds the whole workspace.


### Milestone 2: Build the request mapper and streaming transport


Create baikai-openai/src/Baikai/Provider/OpenAI/Responses.hs, Responses/Request.hs and Responses/Stream.hs; expose register and openaiResponsesProvider from the public module and declare modules in baikai-openai/baikai-openai.cabal. Use the existing HTTP manager, credential resolution, timeout and error infrastructure, with an injectable byte/event driver for offline tests.

Map system instructions, text/image input, previous assistant messages, function calls and tool results into Responses input. Preserve call_id independently from item ID. Apply supported tool choice, JSON schema output, max_output_tokens and reasoning.effort. Reject any unsupported public option or content shape with a useful InvalidRequest rather than dropping it silently; document capability limits. Serialize SDK types where accurate, then add a narrow documented local wire type or shaper for gaps. Do not add an unreleased dependency pin merely to obtain max effort or current event fields.

Implement server-sent events (a sequence of named JSON frames over one HTTP response) with a state machine indexed by output item/content indexes. Translate text, summary and function-argument deltas into Baikai events. Final item snapshots complete state; do not append a final snapshot a second time after its deltas. Keep encrypted reasoning and call identities intact. Handle completed, incomplete, failed and error terminals; an unexplained EOF is failure with partial content, not success. Completed tool calls map to ToolUse; truncated arguments remain cut-off calls that runToolLoop cannot execute. Reuse bounded cancellation and centralized transport classification. Tests must run complete and stream through the same assembler.


### Milestone 3: Attach evidence and activate the catalog route


Create request commitments from the final serialized request and response commitments from the normalized response including replay state. Record observed model, response ID, request ID and usage only when the provider supplied them. Implement describeThinking using the actual mapper and set the provider's evidence strength ceiling to what fixtures prove; strict mode must work on success, rejection, in-band error and cancellation.

The catalog currently allows API only at file level. Extend baikai/gen/GenModelsCore.hs and baikai/fetch/FetchModelsCore.hs to support an optional per-model api override, resolved against the file default, so one OpenAI catalog can contain both protocols. Retag Astra as openai-responses with explicit compat; regenerate without renaming its Haskell binding. Preserve the old register function's Chat-only behavior; add the explicit Responses registration to docs and smoke setup. Other OpenAI IDs remain on their previous routes.

Base usage must already normalize provider totals correctly; pricing completeness is integrated with docs/plans/76-account-for-cache-writes-and-context-tier-model-pricing.md. Do not hard-code an observed zero cache-write count where the response did not report one.


### Milestone 4: Prove tool-loop behavior and document the API


Add ResponsesSpec, ResponsesTransportSpec and ResponsesEvidenceSpec under baikai-openai/test and wire them into Main.hs and the Cabal file. Reuse lifecycle/error contract tests from the Chat provider where applicable. A fake two-response driver first returns an encrypted reasoning item and function call, then accepts the corresponding output and returns final text; drive it with runToolLoop and assert the second wire request retains exact call and reasoning state.

Update docs/user/models-and-providers.md, docs/user/tools.md, capability docs and their compiled examples where applicable. Write an ADR explaining separate dispatch and provider-scoped continuation. List public sum/record changes in CHANGELOG.md; the later release workflow chooses PVP versions. Built-in server tools, background jobs, async multi-agent APIs and migration of every older model are outside this child.


## Concrete Steps


Run from the repository root:

```bash
mori registry show MercuryTechnologies/openai --full
mori registry docs MercuryTechnologies/openai
curl -fsSL https://hackage.haskell.org/package/openai/preferred.json
git ls-remote --tags https://github.com/MercuryTechnologies/openai.git
cabal build all
cabal run baikai-gen-models
cabal test baikai:baikai-test baikai-openai:baikai-openai-test baikai-claude:baikai-claude-test baikai-smoke:doc-shapes
git diff --check
```

Expected results: the workspace builds, existing Chat/Claude tests still pass, new Responses tests pass, and generator drift is empty. Use the existing development shell if GHC is unavailable. Keep provider-paid calls in the final integration plan.


## Validation and Acceptance


A local scripted driver must show POST /v1/responses, store=false, preserved reasoning items and matching call_id in the second request. A two-turn runToolLoop ends in final text without forcing a tool when auto is appropriate. Parallel tool calls keep distinct IDs and argument buffers. Text/image requests, strict JSON output, low through max effort, incompatible replay rejection, partial EOF, malformed frames, duplicate terminals, cancellation and strict evidence all have observable assertions. A slow active consumer is not cancelled. An abandoned consumer releases the producer under the existing worker contract. No observation is copied from a request merely because it was requested.


## Idempotence and Recovery


Use deterministic fixtures and temporary output for generation. Keep Chat Completions usable while building the new path. Activate the Astra route only with registration, serialization and two-turn tests in place. If SDK or wire assumptions fail, retain the new work as a tested local adapter or revise this plan; do not silently fallback to Chat Completions for a Responses request.


## Interfaces and Dependencies


The public additions are Api.OpenAIResponses and Baikai.Provider.OpenAI.Responses.register :: IO () plus openaiResponsesProvider :: ApiProvider. The new mapper has the conceptual signature Model -> Context -> Options -> Either Text (request body, ThinkingTranslation); use a named prepared-request record when headers and evidence inputs must travel together. This plan owns provider-scoped reasoning replay fields and per-model API override support. The pricing child owns rate policy and usage availability semantics, integrating at the prepared request and terminal usage boundary.

Commits carry this file's ExecPlan trailer, the parent MasterPlan trailer and intention intention_01m1z34288e5p9f6d5am62qmes.

2026-09-07 implementation revision: separate the verified shared-type foundation from next-request proof, which depends on milestone 2's mapper. Evidence schema 2.1 adds optional replay state without changing existing content digests. No dependency pin or application default changed.

2026-09-07 request-mapping revision: the SDK lacks an assistant input role, json_object output format, modern effort values and prompt_cache_options. Local JSON covers only those gaps and lossless replay; ordinary request, function and image types use released SDK 2.5.4. Official Responses create reference confirms `reasoning.encrypted_content` for store=false; the prompt-caching guide permits only 30m for current models. Short selects that TTL, while an explicit long preference is rejected rather than misrepresented. Stop sequences, seed, frequency/presence penalties and image tool results currently receive useful local errors. Metadata is checked against the API's string map limits. Sampling drops retain EP-1's explicit evidence convention.
