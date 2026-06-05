---
id: 4
slug: initial-api-hardening-before-0-1
title: "Initial API Hardening Before 0.1"
kind: master-plan
created_at: 2026-06-05T02:56:59Z
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
| EP-2 | Introduce Explicit Provider Registry Handles | docs/plans/19-introduce-explicit-provider-registry-handles.md | None | EP-1 | Not Started |
| EP-3 | Generalize Tool Result Round Trips | docs/plans/20-generalize-tool-result-round-trips.md | None | EP-4 | Not Started |
| EP-4 | Make Message Construction and Response Invariants Explicit | docs/plans/21-make-message-construction-and-response-invariants-explicit.md | None | None | Not Started |
| EP-5 | Stabilize Compat and Streaming Extension Points | docs/plans/22-stabilize-compat-and-streaming-extension-points.md | EP-4 | EP-2, EP-3 | Not Started |

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
- [ ] EP-2: Add explicit registry/client handle APIs while preserving global convenience wrappers.
- [ ] EP-2: Update tests and provider registration functions to demonstrate isolated registries.
- [ ] EP-4: Replace hidden-time pure message constructors with explicit timestamp and effectful convenience constructors.
- [ ] EP-4: Encode the assistant-response invariant in types and remove production partial/error paths that assume it dynamically.
- [ ] EP-3: Generalize tool-result helpers to support text, image, and error results.
- [ ] EP-3: Update tool smoke tests and docs to demonstrate multi-result and error-result round trips.
- [ ] EP-5: Decide and implement the compat exposure policy for core versus provider packages.
- [ ] EP-5: Document streaming event stability and add tests around any new extension mechanism.


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery: EP-1 kept the public field name `Options.apiKey` but changed its type to `Maybe ApiKeySource`, and `Baikai.Auth` is now re-exported by `Baikai`.
  Impact: Later plans can continue referring to `#apiKey` but should construct explicit credentials with `ApiKeyLiteral` or `ApiKeyEnv`; they should not assume the field contains raw `Text`.
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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-1 completed 2026-06-05. Baikai now exposes `ApiKeySource` through the umbrella module, redacts literal credentials in `Show` and JSON output, preserves provider environment fallback behavior, and updates smoke tests and docs to use `ApiKeyLiteral`. Focused tests and `nix develop --command cabal test all` passed.
