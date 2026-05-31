---
id: 17
slug: upgrade-hs-opentelemetry-to-1-0-0
title: "Upgrade hs-opentelemetry to 1.0.0"
kind: exec-plan
created_at: 2026-05-31T23:13:23Z
intention: "intention_01kt04whaye81ttymt67cd2wsg"
---

# Upgrade hs-opentelemetry to 1.0.0

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan upgrades the optional `baikai-trace-otel` package to the `hs-opentelemetry` 1.0.0 package family and validates that the OpenTelemetry GenAI attributes emitted by baikai match the semantic conventions bundled with that release. A user who enables `Baikai.Trace.Sink.OpenTelemetry.otelSink` should still get one client span per provider call, but after this work the span should use the current GenAI attribute names from OpenTelemetry semantic-conventions v1.40 instead of relying on handwritten strings from the older GenAI draft.

The change is observable through the existing in-memory OpenTelemetry test suite. Running `cabal test baikai-trace-otel-test` from the repository root should create a stub provider call, export exactly one span, and assert that the span contains stable keys such as `gen_ai.provider.name`, `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, and `gen_ai.usage.output_tokens`. It should no longer require or assert the deprecated `gen_ai.system` key.

This is an internal compatibility upgrade. The public baikai API remains `otelSink :: OpenTelemetry.Trace.Core.Tracer -> TraceSink` and `otelSinkWith :: OpenTelemetry.Trace.Core.Tracer -> OtelSinkOptions -> TraceSink`. Consumers should not need to change application code beyond allowing Cabal to resolve the newer OpenTelemetry packages.


## Progress

Use this checklist to track implementation. Every stopping point must update this section with a date and evidence.

- [x] 2026-05-31 Confirm the dependency plan against the local mori-registered `iand675/hs-opentelemetry` source and record any API differences not already captured here. Evidence: `mori registry show iand675/hs-opentelemetry --full` reported the local source path, and cabal file inspection confirmed `hs-opentelemetry-api-1.0.0.0`, `hs-opentelemetry-sdk-1.0.0.0`, `hs-opentelemetry-exporter-in-memory-1.0.0.0`, and `hs-opentelemetry-semantic-conventions-1.40.0.0`.
- [x] 2026-05-31 Update Cabal dependencies for `baikai-trace-otel` so the library and tests resolve against the `hs-opentelemetry` 1.0.0 family and the semantic-conventions package. Evidence: `cabal build baikai-trace-otel --dry-run` selected `hs-opentelemetry-sdk-1.0.0.0`; the library now depends directly on `hs-opentelemetry-semantic-conventions >=1.40 && <2`.
- [x] 2026-05-31 Migrate `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` from handwritten GenAI attribute strings to typed semantic-convention keys where a key exists. Evidence: `rg -n '"gen_ai\.system"|genAi_system' baikai-trace-otel/src baikai-trace-otel/test` returned no matches, and the sink now uses `OpenTelemetry.SemanticConventions` keys for provider, operation, request model, max tokens, response model, and usage tokens.
- [x] 2026-05-31 Migrate `baikai-trace-otel/test/Main.hs` to inspect 1.0.0 `ImmutableSpan` values through `spanHot` and to assert stable GenAI semantics. Evidence: tests now read `Otel.hotName`, `Otel.hotAttributes`, and `Otel.hotStatus` from `Otel.spanHot`, and assert `gen_ai.provider.name` plus absence of the deprecated GenAI system key.
- [x] 2026-05-31 Run focused validation with `cabal build baikai-trace-otel` and `cabal test baikai-trace-otel-test`. Evidence: `cabal build baikai-trace-otel` completed cleanly; `cabal test baikai-trace-otel-test` passed both tests.
- [x] 2026-05-31 Run workspace validation with `cabal build all` and the non-live test suites; run `cabal test all` only when live smoke-test credentials and CLIs are available. Evidence: `cabal build all` completed; `baikai-test` passed 31/31, `baikai-claude-test` passed 1/1, `baikai-openai-test` passed 2/2, and `baikai-trace-otel-test` passed 2/2. Live `baikai-smoke` execution was skipped because this plan only requires non-live validation unless live credentials and CLIs are intentionally in scope.
- [x] 2026-05-31 Update this ExecPlan's Outcomes & Retrospective and commit the code and plan with both `ExecPlan:` and `Intention:` trailers. Outcomes are filled below; commit is the final step of this session.


## Surprises & Discoveries

- 2026-05-31: The mori registry already has `iand675/hs-opentelemetry` at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`, and the package family there is versioned for 1.0.0: `hs-opentelemetry-api-1.0.0.0`, `hs-opentelemetry-sdk-1.0.0.0`, `hs-opentelemetry-exporter-in-memory-1.0.0.0`, and `hs-opentelemetry-semantic-conventions-1.40.0.0`.

- 2026-05-31: The 1.0 migration guide says `ImmutableSpan` no longer exposes fields like the older test's `spanName`, `spanAttributes`, and `spanStatus` helpers. The stable structure is `ImmutableSpan { spanKind, spanHot }`, where `spanHot :: IORef SpanHot`, and `SpanHot` contains `hotName`, `hotAttributes`, and `hotStatus`.

- 2026-05-31: OpenTelemetry semantic-conventions v1.40 includes both the deprecated GenAI key `genAi_system = AttributeKey "gen_ai.system"` and the current key `genAi_provider_name = AttributeKey "gen_ai.provider.name"`. The current baikai sink writes `gen_ai.system`; this upgrade should move the provider discriminator to `gen_ai.provider.name`.

- 2026-05-31: The GenAI v1.40 comments specify that Anthropic cache-read and cache-creation input tokens should be included in `gen_ai.usage.input_tokens`, and baikai's `TraceEvent.CallFinished.inputTokens` already represents the normalized total `Usage.inputTokens`. The OTel sink should continue to emit that total rather than separately recomputing provider-specific cache math.

- 2026-05-31: `cabal build baikai-trace-otel --dry-run` selected `hs-opentelemetry-exporter-otlp-1.0.0.0` as a transitive dependency of `hs-opentelemetry-sdk-1.0.0.0`. No source change is needed in baikai, but this confirms the SDK 1.0 dependency closure is larger than the direct in-memory-exporter test surface.


## Decision Log

- Decision: Treat `gen_ai.provider.name` as the canonical provider attribute and stop asserting `gen_ai.system`.
  Rationale: In the local 1.0.0 dependency source, `OpenTelemetry.SemanticConventions.genAi_system` is marked deprecated and points to `gen_ai.provider.name`. Baikai should align with the current GenAI semantic conventions while keeping custom baikai-only attributes under the `baikai.` prefix.
  Date: 2026-05-31

- Decision: Add an explicit dependency on `hs-opentelemetry-semantic-conventions` in `baikai-trace-otel/baikai-trace-otel.cabal`.
  Rationale: The sink should import `OpenTelemetry.SemanticConventions` directly. Cabal requires directly imported packages to appear in `build-depends`, even if another dependency also depends on them.
  Date: 2026-05-31

- Decision: Keep `baikai.latency_ms`, `baikai.event_id`, `baikai.cost.usd`, and `baikai.error` as custom attributes.
  Rationale: The researched GenAI semantic conventions include model, provider, operation, response, and token usage keys, but they do not define baikai's internal event correlation id, USD cost, or exact latency field. Prefixing these with `baikai.` avoids pretending they are upstream-standard fields.
  Date: 2026-05-31

- Decision: Keep the public `otelSink` and `otelSinkWith` signatures unchanged.
  Rationale: The OpenTelemetry 1.0.0 core APIs still expose `Tracer`, `createSpan`, `defaultSpanArguments`, `addAttributes`, `setStatus`, and `endSpan`. The compatibility break is in attribute construction and exported span inspection, not in the sink's public API.
  Date: 2026-05-31


## Outcomes & Retrospective

2026-05-31: `baikai-trace-otel` now targets the `hs-opentelemetry` 1.0 package family. The library directly depends on `hs-opentelemetry-api ==1.0.*` and `hs-opentelemetry-semantic-conventions >=1.40 && <2`; the test suite targets `hs-opentelemetry-api ==1.0.*`, `hs-opentelemetry-sdk ==1.0.*`, and `hs-opentelemetry-exporter-in-memory ==1.0.*`.

The OTel sink now records current GenAI semantic-convention attributes through `OpenTelemetry.SemanticConventions`: `gen_ai.provider.name`, `gen_ai.operation.name`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, and `gen_ai.usage.output_tokens`. It no longer emits the deprecated `gen_ai.system` key. Baikai-specific attributes remain custom and prefixed: `baikai.event_id`, `baikai.latency_ms`, `baikai.cost.usd`, and `baikai.error`.

The test suite now inspects OpenTelemetry 1.0 exported spans through `ImmutableSpan.spanHot`, reading `hotName`, `hotAttributes`, and `hotStatus`. The success test asserts the stable GenAI keys and the absence of the deprecated GenAI system key. The failure test still asserts the error status and baikai error attributes.

Validation passed:

```text
cabal build baikai-trace-otel
cabal test baikai-trace-otel-test
cabal build all
cabal test baikai-test              # 31/31
cabal test baikai-claude-test       # 1/1
cabal test baikai-openai-test       # 2/2
cabal test baikai-trace-otel-test   # 2/2
```

`baikai-smoke` was built as part of `cabal build all` but its live test execution was skipped. That suite can call external providers and local CLIs, so this plan treats it as optional unless credentials and live-provider validation are explicitly in scope. No downstream baikai API changes were required; `otelSink` and `otelSinkWith` keep the same public signatures.


## Context and Orientation

The repository root is `/Users/shinzui/Keikaku/bokuno/baikai`. The mori identity is `shinzui/baikai`, a Haskell library with four Cabal packages: `baikai`, `baikai-claude`, `baikai-openai`, and `baikai-trace-otel`, plus the `baikai-smoke` test package. The optional OpenTelemetry integration lives only in `baikai-trace-otel` so users who do not want OpenTelemetry dependencies do not pay the compile-time or dependency cost.

The important local files are:

`cabal.project` lists the workspace packages. It currently says `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, and `hs-opentelemetry-exporter-in-memory` resolve from Hackage, while streamly packages are pinned via `source-repository-package`.

`baikai-trace-otel/baikai-trace-otel.cabal` declares the OTel adapter library and its tests. The library currently depends on `hs-opentelemetry-api`; the test suite depends on `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, and `hs-opentelemetry-exporter-in-memory`.

`baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` defines the public adapter. `otelSink` is a convenience wrapper around `otelSinkWith`. `otelSinkWith` builds a `TraceSink`, which is a streamly `Fold IO TraceEvent ()`. When it sees `CallStarted`, it creates an OpenTelemetry span and stores it in a `Map Text Span` keyed by `eventId`. When it sees `CallFinished` or `CallFailed`, it finds the stored span, adds final attributes, sets status, ends the span, and removes it from the map. The finalizer ends any spans left in the map so a dropped terminal event does not leak an open span.

`baikai-trace-otel/test/Main.hs` defines two end-to-end tests using `OpenTelemetry.Exporter.InMemory.Span.inMemoryListExporter`. The tests register stub providers, run `Baikai.Trace.withTrace` with `otelSink`, then inspect the exported `ImmutableSpan`.

`baikai/src/Baikai/Trace/Event.hs` defines the three trace events consumed by the OTel sink: `CallStarted`, `CallFinished`, and `CallFailed`. `CallStarted` includes `provider`, `model`, `maxTokens`, and a redacted `promptSummary`. `CallFinished` includes `latencyMs`, optional normalized `inputTokens`, optional `outputTokens`, and optional USD cost as `Scientific`. `CallFailed` includes `latencyMs` and `errorMessage`.

`baikai/src/Baikai/Trace.hs` constructs those events around provider calls. Its `CallFinished.inputTokens` comes from `Usage.inputTokens`, not from a raw provider-specific response. This matters because GenAI semantic conventions expect `gen_ai.usage.input_tokens` to include cached input tokens when applicable.

The dependency source and docs are found through mori, not by guessing APIs. The relevant mori commands are:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
```

The local dependency source path reported by mori is `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project`. Do not search `/nix/store` or `/`; use this path and the current repository path only.

OpenTelemetry terms used in this plan:

An OpenTelemetry span is a timed unit of work in a trace. Here, one provider call produces one span.

A span attribute is a typed key-value pair attached to a span. Backends use attributes for filtering, grouping, and dashboards.

GenAI semantic conventions are OpenTelemetry's standardized attribute names for generative AI clients. In the 1.0.0 dependency source, these keys are generated in `OpenTelemetry.SemanticConventions` from semantic-conventions v1.40.

`SpanHot` is the 1.0.0 record containing mutable span fields. Tests that inspect exported spans must read `spanHot` and then inspect `hotName`, `hotAttributes`, and `hotStatus`.


## Plan of Work

### Milestone 1: lock down dependency expectations

Start by confirming the local dependency state with mori and the source tree. The goal is to know exactly which `hs-opentelemetry` packages Cabal should resolve and which modules the code can import. At the end of this milestone, the implementer should know whether Cabal is already resolving 1.0.0 from Hackage or whether `cabal.project` needs an explicit pin.

Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
```

Then inspect the dependency source:

```bash
cd /Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project
sed -n '1,80p' hs-opentelemetry/api/hs-opentelemetry-api.cabal
sed -n '1,80p' hs-opentelemetry/sdk/hs-opentelemetry-sdk.cabal
sed -n '1,80p' hs-opentelemetry/exporters/in-memory/hs-opentelemetry-exporter-in-memory.cabal
sed -n '1,90p' hs-opentelemetry/semantic-conventions/hs-opentelemetry-semantic-conventions.cabal
```

Acceptance for this milestone is evidence that `hs-opentelemetry-api`, `hs-opentelemetry-sdk`, and `hs-opentelemetry-exporter-in-memory` are `1.0.0.0`, and that `hs-opentelemetry-semantic-conventions` is `1.40.0.0`. If Hackage resolution fails later because the solver chooses older packages, add explicit constraints to `cabal.project` rather than vendoring new source casually. Prefer this form:

```cabal
constraints:
  hs-opentelemetry-api ==1.0.*,
  hs-opentelemetry-sdk ==1.0.*,
  hs-opentelemetry-exporter-in-memory ==1.0.*,
  hs-opentelemetry-semantic-conventions >=1.40 && <2
```

Only add `source-repository-package` entries for OpenTelemetry if Cabal cannot resolve the 1.0.0 packages from Hackage in the local environment. If local pins are needed, copy the existing streamly style in `cabal.project` and pin to a specific Git tag or commit, not to a floating branch.

### Milestone 2: update Cabal dependencies

Edit `baikai-trace-otel/baikai-trace-otel.cabal`. In the library stanza, add `hs-opentelemetry-semantic-conventions >=1.40 && <2` because the implementation will import `OpenTelemetry.SemanticConventions`. Tighten the existing OTel dependency to the 1.0 family if the local solver does not already do so. The library's relevant dependencies should include:

```cabal
    hs-opentelemetry-api ==1.0.*,
    hs-opentelemetry-semantic-conventions >=1.40 && <2,
```

In the test-suite stanza, keep direct dependencies on the SDK and in-memory exporter, and tighten them to the 1.0 family if necessary:

```cabal
    hs-opentelemetry-api ==1.0.*,
    hs-opentelemetry-exporter-in-memory ==1.0.*,
    hs-opentelemetry-sdk ==1.0.*,
```

If adding exact 1.0 constraints in the cabal file creates solver conflicts for downstream users, move the exact version constraints to `cabal.project` and leave package-level lower bounds in the `.cabal` file. The package file should express source compatibility; the project file should express this repository's validation target.

Acceptance for this milestone is:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai-trace-otel --dry-run
```

The expected result is a successful build plan that mentions the 1.0 OpenTelemetry packages. If `--dry-run` does not print versions in this environment, run the real build in Milestone 5 and use `cabal v2-build -v` only if version evidence is still needed.

### Milestone 3: migrate the OTel sink to typed GenAI keys

Edit `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`. Add imports for the typed key helpers and semantic conventions. The implementation may use either `OpenTelemetry.Attributes.Map.insertByKey` or the attribute builder exported by `OpenTelemetry.Attributes`. The builder form is concise and type-checks values against the semantic-convention key types:

```haskell
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.SemanticConventions qualified as SC
```

For `CallStarted`, replace the handwritten attributes:

```haskell
("gen_ai.system", ...)
("gen_ai.request.model", ...)
("gen_ai.request.max_tokens", ...)
```

with typed semantic-convention keys:

```haskell
SC.genAi_provider_name
SC.genAi_operation_name
SC.genAi_request_model
SC.genAi_request_maxTokens
```

Use `"chat"` for `gen_ai.operation.name` because baikai currently exposes text completion and chat-style message calls through the same assistant-message abstraction. If a future embeddings or retrieval API is added, that future API should set a different operation name in its own trace event rather than overloading this sink now.

The current `maxTokens` field is `Natural`; the typed key expects `Int64`. Convert with `fromIntegral maxTokens :: Int64`, matching the existing safe assumption that max-token values fit into a machine integer. Keep `baikai.event_id` as a custom text attribute. If `includePromptSummary` is true, keep `gen_ai.prompt_summary` as a custom attribute because v1.40 does not define that key; do not switch to `gen_ai.prompt` because that key is deprecated and can contain raw prompt content.

For `CallFinished`, replace handwritten stable keys with typed keys:

```haskell
SC.genAi_response_model
SC.genAi_usage_inputTokens
SC.genAi_usage_outputTokens
```

Keep `baikai.latency_ms` and `baikai.cost.usd` custom. The current `usd :: Maybe Scientific` should continue converting to a `Double` for `baikai.cost.usd` because OpenTelemetry attributes support numeric primitives, not `Scientific`.

For `CallFailed`, keep `baikai.latency_ms` and `baikai.error` custom. Do not invent a GenAI failure key. The span status `Otel.Error errorMessage` is the standard error signal.

After this milestone, the source should no longer contain `gen_ai.system`. It may contain custom key string literals that intentionally do not exist in semantic conventions. Verify with:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
rg -n '"gen_ai\.system"|genAi_system' baikai-trace-otel/src baikai-trace-otel/test
```

The expected output is empty.

### Milestone 4: migrate tests to 1.0 exported-span shape

Edit `baikai-trace-otel/test/Main.hs`. The old tests inspect exported spans with names like `Otel.spanName sp`, `Otel.spanAttributes sp`, and `Otel.spanStatus sp`. In the 1.0.0 API, an exported `ImmutableSpan` has cold fields such as `spanKind` directly, and mutable fields are under `spanHot :: IORef SpanHot`. Add a small helper:

```haskell
spanHotSnapshot :: Otel.ImmutableSpan -> IO Otel.SpanHot
spanHotSnapshot = readIORef . Otel.spanHot
```

Then update assertions:

```haskell
hot <- spanHotSnapshot sp
Otel.hotName hot @?= "baikai.call"
let attrs = Attr.getAttributeMap (Otel.hotAttributes hot)
Otel.hotStatus hot @?= Otel.Ok
Otel.spanKind sp @?= Otel.Client
```

For the success test, assert that the attribute map includes:

```text
gen_ai.provider.name
gen_ai.operation.name
gen_ai.request.model
gen_ai.request.max_tokens
gen_ai.response.model
gen_ai.usage.input_tokens
gen_ai.usage.output_tokens
baikai.event_id
baikai.latency_ms
```

Also assert that `gen_ai.system` is absent. This makes the semantic migration explicit and prevents accidental reintroduction of the deprecated key.

The existing `stubResponse` currently uses `_Usage`, which may produce zero token counts and therefore may skip usage attributes depending on implementation. For this migration, set a non-zero usage value in the stub response so `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens` are guaranteed to be emitted. Inspect `baikai/src/Baikai/Usage.hs`; if `_Usage` is a smart constructor with lens fields, use a lens chain like:

```haskell
sampleUsage =
  _Usage
    & #inputTokens .~ 12
    & #outputTokens .~ 3
```

Then use `usage = sampleUsage` in the `AssistantMessage` inside `stubResponse`.

For the failure test, assert through `hotStatus` rather than the old status accessor, and keep checking `baikai.error` and `baikai.latency_ms`. It is acceptable for failure spans to lack response and usage attributes because no model response completed.

Acceptance for this milestone is that `baikai-trace-otel/test/Main.hs` compiles against the 1.0.0 source API and validates stable GenAI attributes rather than only checking for handwritten strings.

### Milestone 5: focused validation

Run the focused build and test suite:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai-trace-otel
cabal test baikai-trace-otel-test
```

Expected result:

```text
Build profile: -w ghc-9.12...
...
Running 1 test suites...
Test suite baikai-trace-otel-test: RUNNING...
baikai-trace-otel
  success path emits one Ok span with expected attributes: OK
  failure path emits one Error span with error message:      OK

2 out of 2 tests passed
Test suite baikai-trace-otel-test: PASS
```

The exact GHC version and build output can vary, but the test names and `2 out of 2 tests passed` are the important acceptance signal. If the build fails due to Cabal solver selection, return to Milestone 1 and add project-level constraints or source pins. If the build fails on typed attributes, read `OpenTelemetry.Attributes`, `OpenTelemetry.Attributes.Map`, and `OpenTelemetry.SemanticConventions` in the mori dependency source instead of guessing.

### Milestone 6: workspace validation and documentation

Run:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build all
cabal test baikai-test
cabal test baikai-claude-test
cabal test baikai-openai-test
cabal test baikai-trace-otel-test
```

Expected result is that all four non-live suites pass. `baikai-smoke` is a live smoke-test package that may call OpenAI, Claude, local CLIs, and spend tokens. Run it only when the environment has the needed API keys and CLIs and the operator is intentionally validating live providers:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal test baikai-smoke
```

If live smoke tests are skipped, record that explicitly in Outcomes & Retrospective. Do not mark the whole plan blocked merely because live provider credentials are absent; the OTel migration is validated by the in-memory exporter test and non-live package tests.

Finally, update `docs/plans/17-upgrade-hs-opentelemetry-to-1-0-0.md`: check off completed Progress items with dates, add any Surprises & Discoveries, and fill Outcomes & Retrospective.


## Concrete Steps

All commands in this section run from the repository root unless the command explicitly changes directory.

1. Confirm mori project context:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
mori show --full
```

Expected output identifies the project as `shinzui/baikai` and lists the `baikai-trace-otel` package.

2. Confirm OpenTelemetry dependency source:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
mori registry show iand675/hs-opentelemetry --full
mori registry docs iand675/hs-opentelemetry
```

Expected output includes the path `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project` and the docs key `semantic-conventions-guide`.

3. Edit `baikai-trace-otel/baikai-trace-otel.cabal` as described in Milestone 2.

4. Edit `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` as described in Milestone 3.

5. Edit `baikai-trace-otel/test/Main.hs` as described in Milestone 4.

6. Verify the deprecated key is gone from the OTel package:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
rg -n '"gen_ai\.system"|genAi_system' baikai-trace-otel/src baikai-trace-otel/test
```

Expected output is empty.

7. Run focused tests:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai-trace-otel
cabal test baikai-trace-otel-test
```

Expected output ends with `Test suite baikai-trace-otel-test: PASS`.

8. Run non-live workspace validation:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build all
cabal test baikai-test
cabal test baikai-claude-test
cabal test baikai-openai-test
cabal test baikai-trace-otel-test
```

Expected output is that every named suite passes.

9. Commit with Conventional Commits and both required trailers:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
git status --short
git add cabal.project baikai-trace-otel/baikai-trace-otel.cabal baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs baikai-trace-otel/test/Main.hs docs/plans/17-upgrade-hs-opentelemetry-to-1-0-0.md
git commit -m "fix(otel): upgrade hs-opentelemetry semantics" -m "Update baikai-trace-otel for the hs-opentelemetry 1.0 package family and validate stable GenAI semantic-convention attributes." -m "ExecPlan: docs/plans/17-upgrade-hs-opentelemetry-to-1-0-0.md" -m "Intention: intention_01kt04whaye81ttymt67cd2wsg"
```

Only include `cabal.project` in the commit if it was actually changed. If unrelated user changes exist in the working tree, do not stage them.


## Validation and Acceptance

The main acceptance criterion is semantic, not just compilation: the in-memory exporter test must prove that a successful traced provider call emits one `Client` span named `baikai.call` with current GenAI attributes.

The success span must include:

```text
gen_ai.provider.name
gen_ai.operation.name
gen_ai.request.model
gen_ai.request.max_tokens
gen_ai.response.model
gen_ai.usage.input_tokens
gen_ai.usage.output_tokens
baikai.event_id
baikai.latency_ms
```

The success span must not include:

```text
gen_ai.system
```

The failure span must have `hotStatus = Error ...`, contain `baikai.error` and `baikai.latency_ms`, and still end exactly one span.

The minimum commands that must pass before this plan is complete are:

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
cabal build baikai-trace-otel
cabal test baikai-trace-otel-test
cabal build all
cabal test baikai-test
cabal test baikai-claude-test
cabal test baikai-openai-test
```

`cabal test all` is stronger but includes live smoke tests through `baikai-smoke`; run it only when credentials and CLIs are intentionally available.


## Idempotence and Recovery

The source edits are ordinary text changes and can be repeated safely. Re-running Cabal build and test commands is safe; Cabal may reuse or rebuild `dist-newstyle` artifacts, but it should not mutate source files.

If Cabal selects old OpenTelemetry packages, add project-level constraints in `cabal.project` and retry. If the solver still cannot find 1.0.0 packages from Hackage, use mori to inspect the registered local source and add explicit `source-repository-package` pins only after recording the reason in Surprises & Discoveries and Decision Log.

If tests fail because exported span fields moved again, inspect the source under `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Internal/Trace/Types.hs` and `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Trace/Core.hs`. Do not search `/nix/store` or `/`.

If an edit partially succeeds and the build is broken, leave the code in place, update Progress with what is done and what remains, and continue from the first failing compiler error. Do not revert unrelated user changes. Use `git diff -- <path>` to isolate only the files touched for this plan.


## Interfaces and Dependencies

The public interface after the upgrade remains:

```haskell
otelSink :: OpenTelemetry.Trace.Core.Tracer -> Baikai.Trace.Sink.TraceSink
otelSinkWith :: OpenTelemetry.Trace.Core.Tracer -> OtelSinkOptions -> Baikai.Trace.Sink.TraceSink
```

`OtelSinkOptions` remains:

```haskell
data OtelSinkOptions = OtelSinkOptions
  { spanName :: !Text
  , includePromptSummary :: !Bool
  }
```

The implementation depends on these OpenTelemetry 1.0.0 APIs:

```haskell
OpenTelemetry.Trace.Core.Tracer
OpenTelemetry.Trace.Core.Span
OpenTelemetry.Trace.Core.ImmutableSpan
OpenTelemetry.Trace.Core.SpanHot
OpenTelemetry.Trace.Core.createSpan
OpenTelemetry.Trace.Core.defaultSpanArguments
OpenTelemetry.Trace.Core.addAttributes
OpenTelemetry.Trace.Core.setStatus
OpenTelemetry.Trace.Core.endSpan
OpenTelemetry.Trace.Core.SpanKind(Client)
OpenTelemetry.Trace.Core.SpanStatus(Ok, Error)
OpenTelemetry.Common.Timestamp
OpenTelemetry.Attributes.toAttribute
OpenTelemetry.Attributes.getAttributeMap
OpenTelemetry.SemanticConventions.genAi_provider_name
OpenTelemetry.SemanticConventions.genAi_operation_name
OpenTelemetry.SemanticConventions.genAi_request_model
OpenTelemetry.SemanticConventions.genAi_request_maxTokens
OpenTelemetry.SemanticConventions.genAi_response_model
OpenTelemetry.SemanticConventions.genAi_usage_inputTokens
OpenTelemetry.SemanticConventions.genAi_usage_outputTokens
```

The test suite depends on:

```haskell
OpenTelemetry.Exporter.InMemory.Span.inMemoryListExporter
OpenTelemetry.Trace.Core.createTracerProvider
OpenTelemetry.Trace.Core.emptyTracerProviderOptions
OpenTelemetry.Trace.Core.makeTracer
OpenTelemetry.Trace.Core.tracerOptions
```

The new dependency target is the `hs-opentelemetry` 1.0.0 family plus semantic-conventions v1.40:

```text
hs-opentelemetry-api == 1.0.*
hs-opentelemetry-sdk == 1.0.*
hs-opentelemetry-exporter-in-memory == 1.0.*
hs-opentelemetry-semantic-conventions >= 1.40 && < 2
```

Baikai-owned trace events stay unchanged. This plan does not add new `TraceEvent` constructors or fields. If a future plan wants separate GenAI operation names for embeddings, retrieval, agent invocation, or tool execution spans, that future plan should extend the baikai trace-event model intentionally rather than hiding that distinction inside the OTel sink.
