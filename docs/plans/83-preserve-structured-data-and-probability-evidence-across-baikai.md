---
id: 83
slug: preserve-structured-data-and-probability-evidence-across-baikai
title: "Preserve structured data and probability evidence across Baikai"
kind: exec-plan
created_at: 2026-09-26T14:42:51Z
intention: "intention_01m3f2jkgpej3s8m0wpa7cw5nz"
master_plan: "docs/masterplans/14-support-typesafe-system-one-judgment-models.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex"
    at: 2026-09-26T14:42:51Z
---

# Preserve structured data and probability evidence across Baikai

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Follow `agents/skills/exec-plan/ADR.md` when changing durable project context.


## Purpose / Big Picture

A caller will be able to send structured JSON and receive structured answers with per-field probability distributions without converting them to generated text or losing them during streaming, persistence, or tracing. Demonstrate the result with a synthetic local provider: one response containing boolean, choice, and score distributions must survive stream reconstruction, whole-response JSON, trace JSONL, the call log, and the OpenTelemetry sink.

This implements the provider-neutral portion of [IR-10](../improvement-requests/support-typesafe-system-one-judgment-models.md). It has no hard dependencies. `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md` subsequently consumes the content, event, error-detail, and logging contracts defined here. No TypeSafe network implementation is needed to accept this plan.


## Progress

- [ ] Milestone 1: structured blocks and typed request-problem errors round-trip, and every existing provider explicitly handles structured input/history without loss or pattern-match failures.
- [ ] Milestone 2: atomic data events and named full-response codecs preserve distributions and method tags, including mixed-block and failure recovery cases.
- [ ] Milestone 3: actual trace, call-log, and OpenTelemetry output retains structured data; offline package tests and documented content examples pass.


## Surprises & Discoveries

`Response` currently derives only Eq, Show and Generic. The consumer at `mori://shinzui/shikumi`, project-relative path `shikumi-cache/src/Shikumi/Cache/ResponseJSON.hs` (artifact-level URI pending), defines orphan response/usage/cost decoders and deliberately excludes per-call evidence from cache JSON. This plan therefore adds named codecs rather than conflicting global instances. `AssistantContent` already has its own codecs, so the consumer's existing response encoding will automatically carry its new data constructor.

Trace terminals and `CallLogEntry` currently carry only accounting fields; neither automatically serializes response blocks. Both need an explicit structured-data field.


## Decision Log

2026-09-26: Keep answer probabilities inside `AssistantData`, separate from optional `Response.evidence`, because cached/replayed answers remain meaningful when the original provider-call evidence is removed.

2026-09-26: Add typed optional request-problem detail under `InvalidRequest`, preserving existing retry classification. Use deterministic JSON text for structured user input at existing providers; refuse assistant data history before dispatch rather than silently discard its probability evidence.

2026-09-26: Expose named full-response codecs; do not add overlapping Response, Usage, Cost or AssistantPayload instances. The byte-stability contract applies to the codec's own encoded representation, with the existing model-header redaction and decimal cost representation preserved.


## Outcomes & Retrospective


## Context and Orientation

The repository contains one directory per Haskell Cabal package and uses the Nix development shell. Core types live in `baikai/src/Baikai/Content.hs`, `Message.hs`, `Response.hs`, `Error.hs`, `Stream/Event.hs`, and `Stream.hs`. `UserContent` currently contains text/images; `AssistantContent` contains text/thinking/tool calls. Blocks use tagged JSON with `type` and `data`. `Response.message` is an `AssistantPayload` containing a vector of blocks. Probability evidence means the supplied probability for each declared answer, not a claim that Baikai has verified calibration.

`Baikai.Stream.reassembleResponse` maintains content by block index, keeps the first start and terminal, and recovers partial content on failure. `liftCompleteToStream` synthesizes per-block events from a completed response. Update both directions. `Baikai.Response.flattenAssistantText` intentionally projects text only; keep that meaning and expose a separate structured-data accessor.

Existing wire conversion is in `baikai-openai/src/Baikai/Provider/OpenAI/Internal/Request.hs`, `Responses/Request.hs`, and `baikai-claude/src/Baikai/Provider/Claude/Internal/Request.hs`. CLI rendering is shared through `baikai/src/Baikai/Provider/Cli/Internal.hs` and the providers' `Cli.hs` modules. Search all content/event matches rather than patching only the two API request mappers. `-Werror=incomplete-patterns` in package settings helps find omissions.

Persistence and reporting touch `baikai/src/Baikai/Trace/Event.hs`, `Trace.hs`, `Cost/Log.hs`, `Evidence.hs`, `Evidence/Build.hs`, and `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs`. `Evidence.canonicalEncode` recursively orders JSON keys and already supports deterministic encoding. Use it for data-to-text conversion rather than creating another ordering rule. `Evidence` already imports response-independent types, so check import direction before placing a new convenience helper in `Content`.

Follow [ADR 0002](../adr/0002-requested-translated-observed-are-never-collapsed.md) and [ADR 0003](../adr/0003-the-adapter-owns-the-translation-description.md): preserve provider facts and never re-derive request translation in logging. [ADR 0011](../adr/0011-core-owns-transport-failure-classification.md) owns error classification. [ADR 0014](../adr/0014-strict-evidence-means-a-record-exists.md) requires actual evidence under strict mode. [ADR 0017](../adr/0017-a-documented-example-compiles-in-the-test-suite.md) requires capability examples to compile, and [ADR 0020](../adr/0020-pricing-policies-and-calculation-bases-are-explicit.md) keeps local pricing out of response commitments. No existing ADR defines structured judgment content; record the accepted content/serialization boundary during implementation.


## Plan of Work

### Milestone 1 — Usable structured content and typed refusal

Add `DataContent` to `Baikai.Content`, with `value :: Value`, `probabilities :: Maybe (Map Text (Map Text Double))`, and `method :: Maybe Text`; add `UserData Value` and `AssistantData DataContent`. Keep the existing constructor tags unchanged. The new tags are `user_data` and `assistant_data`; the assistant's nested object uses `value`, `probabilities`, and `method`, omitting absent optional fields. A plain JSON data block is valid with no probabilities or method. JSON decoding rejects non-finite/out-of-range probabilities and malformed distribution maps. Do not require sums of one or invent a requirement tying the generic JSON value's shape to a particular provider's judgments.

Add total `userData`, `userDataAt`, and `userDataNow` helpers alongside the existing text/image message helpers. Add `flattenAssistantData :: Vector AssistantContent -> Vector DataContent` to `Baikai.Response`. Export the intended public names through `baikai/src/Baikai.hs`. Audit comments promising only text/images or three assistant variants.

In `Baikai.Error`, add `RequestProblem = UnsupportedFeature Text | UnsupportedModel Text`, with the Text respectively naming a field path or model identifier, and `requestProblem :: Maybe RequestProblem` on `BaikaiError`. Add `unsupportedFeature :: Text -> Text -> BaikaiError` and `unsupportedModel :: Text -> Text -> BaikaiError` smart constructors (identifier/path followed by readable explanation). Both classify as `InvalidRequest`, with no retry. Encode the detail under optional `request_problem`, with explicit kind and field/model keys; legacy errors lacking it decode to Nothing. Update all explicit error record constructions and fixtures across the workspace. Keep `refusalCategory` reserved for provider content refusals.

All existing generative providers must convert `UserData` to canonical UTF-8 JSON text at the exact position of that input block, including scalar/null JSON and Unicode. This applies to API Chat, API Responses, API Claude, and both batch CLI paths. Use the deterministic encoder at an acyclic shared helper location. A request containing `AssistantData` in history must fail with `unsupportedFeature` naming its message/block location before network/process dispatch in every existing provider; carrying only the chosen value would hide the omitted evidence. This policy does not affect text-only projections used solely for display. Audit `summarizeContext` so structured-only prompts have a deterministic bounded summary rather than appearing empty.

Extend core content/error tests and provider request/CLI tests with actual encoded payloads or captured process arguments. Acceptance: nested objects with different insertion order render identically, arrays retain order, existing text/image requests are unchanged, and assistant-data history yields typed errors with zero driver/process calls. Build all packages to prove the new constructors have no unhandled exhaustive matches.

### Milestone 2 — Atomic events and response persistence

In `Baikai.Stream.Event`, introduce `DataStart IndexPayload` and `DataEnd DataEndPayload`, with the latter holding `contentIndex :: Int` and the full `DataContent`. There is no data delta: no provider incrementally generates these blocks. Add event JSON encoding/decoding using the established style. `reassembleResponse` stores the closed block at its content index; `liftCompleteToStream` emits the corresponding start/end pair. A start with no end contributes no invented block. An error after a completed data block retains that block. Duplicate terminal events cannot overwrite it. Test both event-only assembly and agreement with the terminal message, mixed text/data ordering, and serialization of events.

Create `baikai/src/Baikai/Response/JSON.hs`, exposing `responseToJSON :: Response -> Value` and `responseFromJSON :: Value -> Parser Response`. Encode the existing response field names (`message`, `model`, `api`, `provider`, `responseId`, `latencyMs`, `errorInfo`) and optional `evidence`. Reuse existing encoders; use local parser functions for missing nested decoders rather than global orphan instances. Missing optional evidence/error detail must parse as absent. Preserve usage availability, cost basis, timestamps, stop reason, typed errors and data blocks. Existing credential-header redaction remains in force. The codec includes evidence if supplied: cache policy is the consumer's choice, not a hidden codec transformation.

Byte stability means canonical encoding after decode equals the original canonical encoding produced by this codec. It does not promise arbitrary incoming JSON whitespace/order or lossless rational arithmetic beyond the existing decimal cost encoder. Pin examples with decimal costs and redaction-safe models, including nested UserData in request codec tests and data-containing success/error responses. Check old content/event/error fixtures still parse with their old shape. Add a consumer-style test codec omitting `evidence` to prove probabilities survive independently of it, without importing a consumer repository or installing overlapping instances.

Structured content joins response commitments through its JSON encoding. Verify changing just one probability or the method changes the response commitment; changing only catalog pricing does not. Bump the evidence schema's additive minor version from the current `2.5` baseline, preserving canonical rules and legacy digest fixtures. Document the additions rather than claiming a new digest algorithm. Milestone acceptance is core tests proving exact block equality and stable response bytes for the representative fixtures.

### Milestone 3 — Trace, call-log, and sink preservation

Add `structuredData :: Maybe (Vector DataContent)` to `CallFinished`, `CallFailed`, and `CallLogEntry`, containing all AssistantData payloads in content order. Omit it when no data blocks exist; legacy JSON missing it decodes to Nothing. Both call-log construction paths (`Baikai.Cost.Log.runRequestWithLogWith` and `Baikai.Trace.runRequestWithRegistry`) must populate it. Successful and failed terminal traces should read it from the same assembled response they use for accounting; failure after a completed data block must preserve the block. A synthetic abort with no observed data must not invent one.

Extend the OpenTelemetry sink with a documented canonical JSON attribute carrying these data payloads, and preserve all existing attributes. Trace recording must work without `Options.evidence`; answer probabilities are content and must not depend on the call-evidence opt-in. Update every TraceEvent/CallLogEntry construction and decoder, keeping old data-free encodings unchanged through explicit omission where required.

Drive an explicit provider registry with a synthetic provider that emits one DataStart/DataEnd and Done. Read the actual file sink and call-log file after their scoped close, decode them, and compare the nested probability maps and method. Use the existing in-memory OpenTelemetry exporter tests for sink fidelity. Repeat with an error terminal after the data block. Add focused tests under `baikai/test/` and `baikai-trace-otel/test/Main.hs`, registering modules in their Cabal suites. Update relevant streaming/content user documentation and package changelogs, listing public sums/records affected. Final numeric version/bound coordination belongs to `docs/plans/84-deliver-the-typesafe-system-one-provider-and-judgment-catalog.md`.

Before completion, add or update local ADRs for the content carrier, named codec boundary, log payloads and typed error detail. Preserve the repository's existing ADR convention; inspect `mori show --full` before writing rather than assuming a profiled bundle. Distill only durable decisions.


## Concrete Steps

Run from the repository root. Enter the existing shell if GHC/Cabal are unavailable:

```bash
nix develop
cabal build all
cabal test baikai:test:baikai-test baikai-openai:test:baikai-openai-test baikai-claude:test:baikai-claude-test baikai-trace-otel:test:baikai-trace-otel-test
cabal test baikai-effectful:test:baikai-effectful-test baikai-smoke:test:doc-shapes
```

Add focused modules such as `baikai/test/DataContentSpec.hs` and `baikai/test/ResponseJSONSpec.hs`; register them in `baikai/test/Main.hs` and `baikai/baikai.cabal`. Expected result is passing content, stream, codec and sink assertions, with no sockets or provider credentials needed. The provider suites must show zero calls for unsupported history and exact JSON text for structured input. Do not run the general live smoke suite as an offline gate: README documents that it may invoke installed CLIs or configured providers.

Inspect remaining pattern matches after editing:

```bash
rg -n 'UserText|UserImage|AssistantText|AssistantThinking|ToolCallEnd|CallLogEntry|CallFinished|CallFailed' baikai baikai-openai baikai-claude baikai-trace-otel baikai-effectful baikai-agent
```

Update this plan with the actual tests and results at milestone boundaries. Commits use Conventional Commits and trailers for this plan, `docs/masterplans/14-support-typesafe-system-one-judgment-models.md`, and intention `intention_01m3f2jkgpej3s8m0wpa7cw5nz`.


## Validation and Acceptance

Use a fixture value with `urgent: true`, `category: technical`, and `severity: 2`; probability maps contain true/false, billing/technical, and 0/1/2 respectively. Include a choice distribution totaling 0.9 to prove no sum-to-one validation was introduced. Valid individual zero/one probabilities pass; negative, greater-than-one, nonnumeric, and non-finite decoder inputs fail. Provider-facing validation must check finiteness before constructing DataContent; a non-finite Double must never become a JSON null masquerading as a probability in a successful provider response.

The same content must be equal after event reconstruction, the named response codec, a consumer-style response codec without call evidence, and actual trace/log/sink output. For byte checks compare `canonicalEncode (responseToJSON response)` before and after parsing, rather than comparing only decoded Values. Mixed block ordering and failure after DataEnd are required cases. Preserve golden legacy JSON and old commitment digests. Core and all existing provider packages must compile and pass their offline suites before marking this plan Complete.


## Idempotence and Recovery

Tests use temporary files and scoped synthetic providers; they can be rerun without provider access. Do not alter the global registry in tests when an explicit registry is available. Keep generated-file changes separate from handwritten content edits, and regenerate only through the owning tools. If a content addition reveals another consumer, adapt it in this plan before marking completion. Revert only this initiative's edits if recovery is necessary; never reset unrelated work. No production data migration or release publication occurs here.


## Interfaces and Dependencies

The public contract is `Baikai.Content.DataContent`, `UserData`, `AssistantData`, `Baikai.Stream.Event.DataStart`/`DataEnd`, `Baikai.Response.flattenAssistantData`, the named `Baikai.Response.JSON` codec pair, and `Baikai.Error.RequestProblem`/smart constructors. The provider plan uses these exact names and map key conventions. Response-call evidence and answer-probability content remain independent.

Use existing Aeson, containers, vector and streamly dependencies. Before relying on an unfamiliar dependency API, locate its source through `mori registry list`, `mori registry search`, `mori registry show --full`, and `mori registry docs`; inspect the discovered source. No new dependency bounds are selected by this plan. Any required change must first compare the current package registry release and upstream tags. Never inspect `/nix/store` or search the filesystem root.
