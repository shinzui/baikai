---
id: 4
slug: initial-api-hardening-before-0-1
title: "Initial API Hardening Before 0.1"
kind: master-plan
created_at: 2026-06-05T02:56:59Z
intention: intention_01ktavd0a0e08r0mw24mrgjgb7
---

# Initial API Hardening Before 0.1

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Before publishing the initial `0.1.0.0` packages, the public API should make the safest long-lived choices about credentials, provider dispatch, message construction, response invariants, tool round trips, compatibility shims, and streaming extension points. After this initiative, a downstream application can call Baikai without accidentally serializing secrets, can choose between global convenience registration and explicit registry handles, can construct messages with explicit time semantics, can rely on response types that encode assistant-only invariants, can return rich tool results, and can consume provider compatibility and streaming APIs with a clear stability story.

This scope is limited to API hardening before the first public release. It includes source-compatible migration helpers where they reduce friction, but it does not include cutting a release, fixing Cabal packaging warnings, expanding model coverage, adding new providers, or changing the live smoke-test matrix except where tests must reflect the new API.


## Decomposition Strategy

The initiative is decomposed by public API concern. Credential handling is first because it affects `Options`, provider request preparation, tests, and examples, and it should be safe before any other plan adds new call paths. Provider registry handles are separate because they change dispatch architecture and can be verified independently with fake providers. Message construction and response invariants are grouped because both address whether the types encode facts the library already assumes: pure message helpers currently hide time effects, and `Response` currently permits non-assistant messages even though providers are expected to return only assistant turns. Tool-result round trips are separate because the current helper is intentionally narrow and can be widened without waiting for registry work. Compat and streaming extension points are last because they depend on the stabilized message/response shape and must reconcile what the previous plans leave in the public import surface.

An alternative was one broad "API cleanup" ExecPlan. That was rejected because the work touches independent surfaces that can be reviewed and validated separately. Another alternative was one plan per module. That was rejected because several modules participate in the same functional concern; for example, credentials span `Baikai.Options`, `Baikai.Auth`, OpenAI, Claude, docs, and smoke tests.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| EP-1 | Redact and Source API Credentials Safely | docs/plans/18-redact-and-source-api-credentials-safely.md | None | None | Complete |
| EP-2 | Introduce Explicit Provider Registry Handles | docs/plans/19-introduce-explicit-provider-registry-handles.md | None | EP-1 | Complete |
| EP-3 | Generalize Tool Result Round Trips | docs/plans/20-generalize-tool-result-round-trips.md | None | EP-4 | Complete |
| EP-4 | Make Message Construction and Response Invariants Explicit | docs/plans/21-make-message-construction-and-response-invariants-explicit.md | None | None | Complete |
| EP-5 | Stabilize Compat and Streaming Extension Points | docs/plans/22-stabilize-compat-and-streaming-extension-points.md | EP-4 | EP-2, EP-3 | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 and EP-4 can start immediately. EP-1 is isolated around credential representation and provider key resolution. EP-4 is isolated around message constructors and the response type invariant. EP-2 can also start immediately, but it has a soft dependency on EP-1 because provider registration examples and tests should use the credential shape that EP-1 settles. EP-3 can start immediately, but it has a soft dependency on EP-4 because richer tool-result payloads are cleaner once message constructors and timestamps are explicit.

EP-5 has a hard dependency on EP-4 because streaming events carry `Message` and terminal `Response` data; the extension-point decision should be made against the final assistant-message and response representation. EP-5 has soft dependencies on EP-2 and EP-3 because compat and streaming APIs may reference provider registration and tool-call event shapes, but those plans do not need to be complete for EP-5 design work to begin.


## Integration Points

`Baikai.Options` is shared by EP-1 and provider packages. EP-1 owns the credential field shape and redaction behavior. Later plans should treat that shape as settled and should not reintroduce raw secret serialization.

`Baikai.Provider.Registry`, `Baikai.Provider`, `Baikai.Stream`, `Baikai.Trace`, and provider package `register` functions are shared by EP-2 and EP-5. EP-2 owns the explicit registry/client handle API. EP-5 should consume that API when deciding which streaming functions remain global convenience wrappers and which require explicit handles.

`Baikai.Message`, `Baikai.Response`, `Baikai.Stream.Event`, `Baikai.Stream`, `Baikai.Cost.Log`, and provider response construction are shared by EP-4 and EP-5. EP-4 owns the final assistant-response invariant and timestamp-constructor policy. EP-5 should update streaming event documentation and extension points to match the final shape.

`Baikai.Context`, `Baikai.Tool`, `Baikai.Content`, provider request encoders, and smoke tests are shared by EP-3 and EP-5. EP-3 owns the richer tool-result helper API. EP-5 should ensure event and content extensibility decisions do not conflict with the final tool result representation.

`Baikai.Compat`, `Baikai.Model.Compat`, generated model catalog output, and provider request mapping are shared by EP-5 and existing generated model workflows. EP-5 owns whether compat remains exposed as concrete provider-specific records, becomes opaque, or moves toward provider packages. Any change must preserve generated model catalog regeneration tests.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Replace raw `Options.apiKey :: Maybe Text` with a redacted credential source API and update provider key resolution.
- [x] EP-1: Add tests proving secrets do not appear in `Show` or JSON output and provider env fallbacks still work.
- [x] EP-2: Add explicit registry/client handle APIs while preserving global convenience wrappers.
- [x] EP-2: Update tests and provider registration functions to demonstrate isolated registries.
- [x] EP-4: Replace hidden-time pure message constructors with explicit timestamp and effectful convenience constructors.
- [x] EP-4: Encode the assistant-response invariant in types and remove production partial/error paths that assume it dynamically.
- [x] EP-3: Generalize tool-result helpers to support text, image, and error results.
- [x] EP-3: Update tool smoke tests and docs to demonstrate multi-result and error-result round trips.
- [x] EP-5: Decide and implement the compat exposure policy for core versus provider packages.
- [x] EP-5: Document streaming event stability and add tests around any new extension mechanism.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: EP-1 kept the public field name `Options.apiKey` but changed its type to `Maybe ApiKeySource`, and `Baikai.Auth` is now re-exported by `Baikai`.
  Impact: Later plans can continue referring to `#apiKey` but should construct explicit credentials with `ApiKeyLiteral` or `ApiKeyEnv`; they should not assume the field contains raw `Text`.
  Date: 2026-06-05
- Discovery: EP-2 preserves one handler per `Api` tag inside a registry, but multiple registries can hold different handlers for the same tag.
  Impact: Later plans should pass `ProviderRegistry` through any APIs that need handler-set isolation; they should not try to encode multiple same-tag handlers in one registry.
  Date: 2026-06-05
- Discovery: EP-3 found that the current OpenAI Chat Completions and Anthropic Messages SDK request shapes only support text tool-result messages, while Baikai core can represent `ToolResultImage`.
  Impact: EP-5 should document streaming and content extension points with this provider limitation in mind. It should not assume every public `ToolResultContent` constructor is encodable by every provider; unsupported blocks need explicit provider behavior.
  Date: 2026-06-05
- Discovery: EP-4 kept streaming terminal events as broad `Message` values but made `Response.message` assistant-only by changing it to `AssistantPayload`.
  Impact: EP-5 should decide whether streaming terminal payloads should also narrow to assistant-only payloads, or whether keeping broad `Message` events is the right extension point for future non-assistant event families.
  Date: 2026-06-05
- Discovery: EP-5 kept compat records public and streaming events closed, and updated docs to state those are deliberate 0.1 policies.
  Impact: Downstream users may explicitly construct compat records for host quirks, while streaming consumers can rely on exhaustive pattern matching until a breaking event-algebra change is released.
  Date: 2026-06-05
- Discovery: EP-5 found that provider request builders remain private, so provider-package compat tests assert the public projection functions consumed by those builders without widening provider exports.
  Impact: Future work that needs deeper request-shape assertions can extract mapper helpers into hidden internal modules instead of exposing them from public provider modules.
  Date: 2026-06-05


## Decision Log

Record every decomposition or coordination decision made while working on the master
plan.

- Decision: Split the audit findings into five child ExecPlans by public API concern rather than by module.
  Rationale: The risky surfaces each cut across multiple modules and packages; grouping by concern keeps each plan independently verifiable while avoiding artificial file-based coupling.
  Date: 2026-06-05
- Decision: Make message/response invariants a prerequisite for final streaming extension-point work.
  Rationale: Streaming terminal events and reassembly carry messages and responses, so extension-point stability depends on the final message and response representation.
  Date: 2026-06-05
- Decision: Keep release packaging work out of this MasterPlan.
  Rationale: The user's current concern is the initial API, not preparing or publishing a release.
  Date: 2026-06-05
- Decision: Keep `Options.apiKey` as the migration field name for EP-1 instead of renaming it to `apiKeySource`.
  Rationale: The type change carries the safety improvement and forces explicit credential construction, while preserving record-update call sites for downstream users and later child plans.
  Date: 2026-06-05
- Decision: Model provider isolation with explicit `ProviderRegistry` handles instead of introducing a broader `BaikaiClient` record in EP-2.
  Rationale: The current request surface only needs handler-map isolation. A larger client record would add premature shape before EP-5 decides the final streaming and compat extension-point story.
  Date: 2026-06-05
- Decision: Preserve the `Response.message` field name while narrowing its type to `AssistantPayload` in EP-4.
  Rationale: The narrowed type encodes the assistant-only invariant without forcing every downstream accessor to learn a new field name before 0.1. The new `responseMessage` helper provides the total broad-message wrapper for context replay.
  Date: 2026-06-05
- Decision: Preserve public compat record constructors for 0.1.
  Rationale: Generated catalog overrides and hand-rolled models need a direct escape hatch for host quirks, and starting from default records with updates is a smaller and clearer API than introducing an opaque builder layer before the initial release.
  Date: 2026-06-05
- Decision: Preserve `AssistantMessageEvent` as a closed event algebra for 0.1.
  Rationale: Exhaustive typed consumption is more useful than a raw provider-event escape hatch for the initial API. Constructor additions will be treated as breaking changes, and docs now advise wildcard branches for consumers that prefer source resilience.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-1 completed 2026-06-05. Baikai now exposes `ApiKeySource` through the umbrella module, redacts literal credentials in `Show` and JSON output, preserves provider environment fallback behavior, and updates smoke tests and docs to use `ApiKeyLiteral`. Focused tests and `nix develop --command cabal test all` passed.

EP-2 completed 2026-06-05. Baikai now supports explicit `ProviderRegistry` handles for isolated registration and dispatch while preserving global convenience wrappers. Provider packages expose handle-based registration helpers, tracing and cost logging have explicit-registry variants, and tests prove same-`Api` providers remain isolated across registries.

EP-3 completed 2026-06-05. Baikai now exposes rich `ToolResult` helpers for text, image, explicit blocks, and error results. `appendToolResult` consumes rich results and `appendToolResultText` keeps text-only dispatch concise. Provider encoders reject unsupported image tool-result blocks explicitly instead of silently dropping them, and the user docs and smoke tests demonstrate the migrated text workflow.

EP-4 completed 2026-06-05. Message constructors now expose explicit-time and effectful variants, and the legacy pure names use deterministic fixture timestamps rather than hidden `unsafePerformIO`. `Response.message` is assistant-only as an `AssistantPayload`, `responseMessage` bridges back to a conversation `Message`, and cost logging no longer has a production non-assistant `error` branch. Focused tests and `nix develop --command cabal test all` passed.

EP-5 completed 2026-06-05. Compat records are documented as public 0.1 extension points, streaming events are documented as a closed public algebra, and examples now use the final payload-record event patterns and assistant-only `Response.message` type. Core and provider tests cover compat projection for OpenAI-compatible and Anthropic-compatible hosts, and `nix develop --command cabal test all` passed with enabled smoke tests.

The full master plan completed 2026-06-05. The initial API now has safer credential handling, explicit registry handles, richer tool-result helpers, explicit message construction and assistant-response invariants, and documented compat/streaming stability policies before the 0.1 release.
