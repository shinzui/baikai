---
id: 19
slug: introduce-explicit-provider-registry-handles
title: "Introduce Explicit Provider Registry Handles"
kind: exec-plan
created_at: 2026-06-05T02:57:11Z
intention: intention_01ktavd0a0e08r0mw24mrgjgb7
master_plan: "docs/masterplans/4-initial-api-hardening-before-0-1.md"
---

# Introduce Explicit Provider Registry Handles

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this change, a Baikai user can choose an explicit provider registry handle instead of relying only on process-global mutable state. The current API stores handlers in a top-level `IORef`, so tests and applications cannot isolate two different handler sets in the same process. The new API should keep the current convenience functions for simple scripts, but it should also expose an explicit `ProviderRegistry` or `BaikaiClient` value that callers can construct, register into, and pass to completion/streaming functions.

The behavior is visible with tests that create two registries in the same process, register different fake providers under the same `Api` tag, and verify that calls through each registry return different responses without overwriting each other.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Audit every public and internal caller of `registerApiProvider`, `lookupApiProvider`, `completeRequest`, and `streamRequest`. Completed 2026-06-05. `rg -n "registerApiProvider|lookupApiProvider|completeRequest|streamRequest|withTrace" baikai baikai-openai baikai-claude baikai-trace-otel baikai-smoke docs` found the registry implementation in `baikai/src/Baikai/Provider/Registry.hs`, streaming lookup in `baikai/src/Baikai/Stream.hs`, tracing in `baikai/src/Baikai/Trace.hs`, cost logging in `baikai/src/Baikai/Cost/Log.hs`, provider registration in the OpenAI and Claude API/CLI modules, and docs under `README.md` and `docs/user/`.
- [x] Add an explicit registry/client handle API in `Baikai.Provider.Registry`. Completed 2026-06-05. The core module now exposes `ProviderRegistry`, `newProviderRegistry`, `globalProviderRegistry`, `registerApiProviderWith`, `lookupApiProviderWith`, and `completeRequestWith`.
- [x] Rebuild global convenience functions on top of a default registry handle. Completed 2026-06-05. `registerApiProvider`, `lookupApiProvider`, `completeRequest`, and `streamRequest` delegate to `globalProviderRegistry`.
- [x] Update provider packages to expose both handle-based and global registration helpers. Completed 2026-06-05. OpenAI and Claude API providers expose `registerWithRegistry`; CLI providers expose `registerWithRegistry` and `registerWithRegistryAndConfig` while preserving `register` and `registerWith`.
- [x] Add tests proving two registries can hold independent providers for the same `Api`. Completed 2026-06-05. `baikai/test/Main.hs` creates two registries, registers different fake providers under the same `Custom "baikai-test"` tag, and verifies `completeRequestWith` returns different responses.
- [x] Update tracing, cost logging, smoke tests, and docs where dispatch entry points change. Completed 2026-06-05. `Baikai.Trace` and `Baikai.Cost.Log` expose explicit-registry variants, smoke tests continue to pass through global wrappers, and README/user docs describe explicit registry handles.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery: `streamRequestWith` can be tested without a live provider by registering a fake provider whose `stream` uses `liftCompleteToStream`.
  Evidence: `nix develop --command cabal test baikai-test` passed a new `streamRequestWith dispatches through an explicit registry` test.
  Date: 2026-06-05
- Discovery: The full suite still exercised global OpenAI smoke behavior after globals were rebuilt on `globalProviderRegistry`.
  Evidence: `nix develop --command cabal test all` reported `gpt-4o-mini ok via OPENAI_API_KEY`, CLI smoke passes, and all test suites passed.
  Date: 2026-06-05


## Decision Log

Record every decision made while working on the plan.

- Decision: Preserve global registration as a convenience wrapper while introducing explicit handles.
  Rationale: Existing examples and smoke tests use simple `register :: IO ()` functions. Removing them would create unnecessary migration friction, but keeping only globals would lock in a poor long-term API.
  Date: 2026-06-05
- Decision: Verify the change with same-API, different-handler tests.
  Rationale: The risk is not whether dispatch works once; the risk is whether handler state can be isolated in one process.
  Date: 2026-06-05
- Decision: Preserve the one-handler-per-`Api`-tag replacement rule inside each registry.
  Rationale: This matches the existing global registry behavior and keeps dispatch unambiguous. Applications that need multiple configured handler sets for the same tag can now create multiple `ProviderRegistry` handles and choose the handle at call time.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Completed 2026-06-05. Baikai now has explicit provider registry handles for registration, lookup, blocking dispatch, streaming dispatch, tracing, and cost logging. The existing global registration and request functions remain available as wrappers over `globalProviderRegistry`. Provider packages can register into explicit handles, including configured CLI providers. Tests prove two registries can isolate different providers under the same `Api` tag, and the full test suite passes.


## Context and Orientation

The provider registry is the mechanism that maps an `Api` tag to the code that knows how to call that API. It lives in `baikai/src/Baikai/Provider/Registry.hs`. Today it defines `ApiProvider`, a process-global `registry :: IORef (Map Api ApiProvider)`, `registerApiProvider`, `lookupApiProvider`, and `completeRequest`.

The public re-export module `baikai/src/Baikai/Provider.hs` exposes the registry functions. Streaming dispatch in `baikai/src/Baikai/Stream.hs` calls `lookupApiProvider` and returns a one-event error stream if no provider is registered. Tracing in `baikai/src/Baikai/Trace.hs` calls `streamRequest`. Cost logging in `baikai/src/Baikai/Cost/Log.hs` calls `completeRequest`.

Provider packages register handlers in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, `baikai-openai/src/Baikai/Provider/OpenAI/Cli.hs`, `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, and `baikai-claude/src/Baikai/Provider/Claude/Cli.hs`. Each package currently exposes `register :: IO ()`, and CLI packages also expose `registerWith`.

Tests rely on global registration in `baikai/test/Main.hs`, `baikai/test/CostSpec.hs`, and `baikai/test/TraceSpec.hs`. Those tests are good places to add explicit-registry coverage.


## Plan of Work

Milestone 1 introduces the explicit handle. In `baikai/src/Baikai/Provider/Registry.hs`, add a public `ProviderRegistry` newtype or record that owns the `IORef (Map Api ApiProvider)`. Add `newProviderRegistry :: IO ProviderRegistry`, `registerApiProviderWith :: ProviderRegistry -> ApiProvider -> IO ()`, `lookupApiProviderWith :: ProviderRegistry -> Api -> IO (Maybe ApiProvider)`, and `completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response`. Keep the existing top-level functions, but implement them by calling the `With` variants against a `globalProviderRegistry`.

Milestone 2 updates streaming and tracing. In `baikai/src/Baikai/Stream.hs`, add `streamRequestWith :: ProviderRegistry -> Model -> Context -> Options -> Stream IO AssistantMessageEvent`. Keep `streamRequest` as a wrapper using `globalProviderRegistry`. In `baikai/src/Baikai/Trace.hs`, add handle-based variants if needed, such as `withTraceStreamWith` and `withTraceWith`, or choose a naming scheme that reads naturally. The exact names may change, but the API must let a caller trace calls through an explicit registry.

Milestone 3 updates provider packages. Each provider module should expose handle-based registration in addition to the current global helper. A reasonable target is `registerWithRegistry :: ProviderRegistry -> IO ()` for API providers and `registerWithRegistryAndConfig :: ProviderRegistry -> Config -> IO ()` for configurable CLI providers. Preserve current `register` and `registerWith` names as global convenience wrappers.

Milestone 4 updates tests and docs. Add tests that create two registries, register two fake providers for the same `Custom "test"` API tag, and assert that `completeRequestWith registryA` and `completeRequestWith registryB` return different providers/messages. Update docs and README snippets that describe calling `register`.


## Concrete Steps

Work from the repository root:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
```

Audit dispatch call sites:

```bash
rg -n "registerApiProvider|lookupApiProvider|completeRequest|streamRequest|withTrace" baikai baikai-openai baikai-claude baikai-trace-otel baikai-smoke docs
```

Run focused tests after the core registry changes:

```bash
nix develop --command cabal test baikai-test
```

Run provider tests after provider package registration changes:

```bash
nix develop --command cabal test baikai-openai-test baikai-claude-test
```

Run the full suite before completion:

```bash
nix develop --command cabal test all
```


## Validation and Acceptance

Acceptance requires a test that proves isolation. The test should create two explicit registries, register a fake provider under the same API tag in each, and call `completeRequestWith` against both. The observed responses must differ according to the provider registered in the selected registry. This test would fail or be impossible with only the current process-global registry.

Existing global behavior must still work. Existing tests that call `registerApiProvider` and `completeRequest` should either remain valid or be updated to assert the same behavior through the global convenience wrappers.

Streaming must have an explicit-registry path. A caller must be able to obtain a stream through a selected registry without mutating the global registry.

The command:

```bash
nix develop --command cabal test all
```

must complete successfully.


## Idempotence and Recovery

The safest migration is additive first. Add explicit-registry functions and tests while leaving existing globals in place. Once the explicit API is proven, reimplement globals in terms of the explicit registry. If a later provider update fails, the core can remain in the additive state while provider modules are migrated one at a time.


## Interfaces and Dependencies

This plan should not add new dependencies. It uses `Data.IORef`, `Data.Map.Strict`, and existing Streamly types already used by `Baikai.Provider.Registry` and `Baikai.Stream`.

At the end, `baikai/src/Baikai/Provider/Registry.hs` must expose an explicit registry handle and handle-based variants of registration, lookup, and completion. `baikai/src/Baikai/Stream.hs` must expose an explicit-registry streaming function. Provider packages must expose handle-based registration while preserving global convenience helpers.
