# Changelog

All notable changes to baikai are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **baikai:** Added `ThinkingXHigh` and `ThinkingMax` to the exported
  `ThinkingLevel` vocabulary and added a defaulted
  `InteractiveLaunchRequest.effort` field. Extending the closed sum type is a
  PVP-major API change for downstream exhaustive matches.
- **baikai-claude:** Added `--effort` rendering to interactive Claude Code
  launches and preserved `xhigh` / `max` on native adaptive Anthropic API
  requests, with larger fixed budgets for manual-thinking models.
- **baikai-openai:** Added `model_reasoning_effort` overrides to interactive
  Codex launches and preserved `xhigh` / `max` in native OpenAI request JSON;
  non-native OpenAI-compatible request shapes continue to clamp them to
  `high`.

## [baikai 0.3.1.0] - 2026-07-15

### Added

- Added `claude-sonnet-5` to the Anthropic model catalog (1M context window,
  128k max output, `tool_call` + reasoning).
- Added the `gpt-5.6` family — `gpt-5.6`, `gpt-5.6-luna`, `gpt-5.6-sol`, and
  `gpt-5.6-terra` — to the OpenAI model catalog (chat-completions with
  `tool_call` support).

### Changed

- Corrected `claude-sonnet-4-5` context window to 1M tokens and
  `claude-sonnet-4-6` max output to 128k tokens in the catalog.
- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-claude 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-openai 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-trace-otel 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-effectful 0.3.0.1] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai-kit 0.1.0.2] - 2026-07-15

### Changed

- Added PVP-compliant upper bounds to all previously-unbounded library and
  executable dependencies.

## [baikai 0.3.0.0] - 2026-07-03

### Added

- Added the documented record-update bases `emptyOptions`, `emptyContext`,
  `emptyModel`, `emptyResponse`, `emptyTool`, `emptyTextContent`,
  `emptyThinkingContent`, `emptyToolCall`, `emptyImageContent`,
  `emptyEmbeddingModel`, plus zero-valued bases `zeroUsage`, `zeroCost`,
  `zeroCostBreakdown`, and `zeroModelCost`.
- Added `firstEmbedding`, a total accessor for OpenAI-compatible embedding
  responses.
- Added `responseError`, `errorResponse`, `httpError`, and
  `parseRetryAfterSeconds` for the in-band error contract.

### Changed

- **Breaking:** Constructors for evolvable records are no longer exported:
  `Options`, `Context`, `Model`, `OpenAICompletionsCompat`,
  `AnthropicMessagesCompat`, and `InteractiveLaunchRequest` are built from
  exported base values plus record updates.
- **Breaking:** The `_X` base values are deprecated in favor of the new
  `empty*` and `zero*` names; the aliases remain for this release.
- **Breaking:** Removed `unModel`; use `mkModel` or `emptyModel` record
  updates.
- **Breaking:** Renamed `InteractiveLaunchRequest.model` to `modelId`.
- **Breaking:** `Response.latencyMs` and trace event `latencyMs` fields are
  now `Int`.
- **Breaking:** `completeRequest` / `completeRequestWith` no longer throw
  `BaikaiError` for unregistered API tags; they return an error-shaped
  `Response`.
- **Breaking:** CLI providers now report subprocess/decode/provider failures
  in-band as error-shaped `Response`s.
- **Breaking:** `errorTerminal` now requires a `BaikaiError`, enforcing
  structured error details for `EventError` construction sites.
- Documented that `Baikai.Prelude` is a convenience module outside the PVP
  stability contract and that `.Internal` modules have no compatibility
  guarantees.

### Fixed

- Empty embedding `data` arrays now produce a typed `decodeError` instead of
  crashing on an empty vector.
- The model-fetch JSON renderer now delegates string escaping to aeson.
- The model generator now fails on sanitized Haskell identifier collisions
  instead of rendering duplicate bindings.
- Live HTTP status, `Retry-After`, and network-failure classification now
  works on both API providers.
- `content_filter` / Anthropic refusals terminate as classified `EventError`
  terminals, and `liftCompleteToStream` preserves error-shaped responses.

## [baikai-claude 0.3.0.0] - 2026-07-03

### Changed

- **Breaking:** `Baikai.Provider.Claude.ErrorClass` moved to
  `Baikai.Provider.Claude.Internal.ErrorClass`.
- **Breaking:** `mapRequest` and pure request-shaping helpers moved from
  `Baikai.Provider.Claude.Api` to
  `Baikai.Provider.Claude.Internal.Request`.
- **Breaking:** `ClaudeCliConfig` and `ClaudeInteractiveConfig` constructors
  are no longer exported; start from their default config values and update
  fields.
- **Breaking:** CLI and interactive `extraArgs` fields are now `[Text]`.

## [baikai-openai 0.3.0.0] - 2026-07-03

### Changed

- **Breaking:** `Baikai.Provider.OpenAI.ErrorClass` moved to
  `Baikai.Provider.OpenAI.Internal.ErrorClass`.
- **Breaking:** `mapRequest` and pure request-shaping helpers moved from
  `Baikai.Provider.OpenAI.Api` to
  `Baikai.Provider.OpenAI.Internal.Request`.
- **Breaking:** `CodexCliConfig` and `CodexInteractiveConfig` constructors are
  no longer exported; start from their default config values and update fields.
- **Breaking:** CLI and interactive `extraArgs` fields are now `[Text]`.

## [baikai-trace-otel 0.3.0.0] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.
- Adjusted to the core trace event `latencyMs :: Int` type.

## [baikai-effectful 0.3.0.0] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.

## [baikai-kit 0.1.0.1] - 2026-07-03

### Changed

- Updated the `baikai` dependency bound to `^>=0.3.0`.

## [baikai 0.2.0.0] - 2026-06-21

### Added

- `Usage`, `Cost`, and `CostBreakdown` now have `Semigroup`/`Monoid`
  instances that add field-by-field, plus `sumUsage :: Foldable f => f
  Usage -> Usage`, so callers can total per-call usage and cost.
  `reasoningTokens` combines as presence-wins (`Nothing` only when both
  operands are `Nothing`).
- A categorised error model: `BaikaiError` is now a record carrying an
  `ErrorCategory` (`AuthError`, `RateLimited`, `ContextOverflow`,
  `InvalidRequest`, `TransientError`, `DecodeFailure`, `ProcessFailure`,
  `ProviderUnavailable`, `OtherError`), an optional HTTP `httpStatus`, a
  `retryAfterSeconds` hint, and a subprocess `exitCode`. New smart
  constructors (`providerError`, `invalidRequest`, `decodeError`,
  `processError`, `rateLimited`, `authError`, `providerUnavailable`),
  the `isRetryable` predicate, and the pure `classifyHttpStatus` /
  `classifyHttpStatusWithBody` helpers let callers implement retry
  policy without parsing error text. `ErrorCategory` and `BaikaiError`
  serialize to JSON.
- `Response` and the streaming `EventError`'s `TerminalPayload` now
  carry `errorInfo :: Maybe BaikaiError`, so a failed `completeRequest`
  (or a drained stream) exposes the structured category/retry hint
  in-band. `Baikai.Stream.Event` gains `doneTerminal` / `errorTerminal`
  constructors.

### Changed

- **Breaking:** `BaikaiError`'s four flat constructors
  (`ProviderError`, `RequestInvalid`, `DecodeError`, `ProcessError`)
  were replaced by the record above. Migrate by lowercasing to the
  smart constructors — `ProviderError "x"` becomes `providerError "x"`,
  `ProcessError n "x"` becomes `processError n "x"`, etc.
- **Breaking:** `Baikai.Stream.Event.TerminalPayload` and
  `Baikai.Response.Response` gained an `errorInfo` field; build
  `TerminalPayload` via `doneTerminal` / `errorTerminal`.

### Fixed

- Restored JSON decoding for `BaikaiError` values with omitted optional
  metadata fields.

## [baikai-claude 0.2.0.0] - 2026-06-21

### Added

- The Anthropic API and `claude -p` CLI providers now classify failures
  into the typed `BaikaiError` categories: HTTP errors (via the caught
  `servant-client` `ClientError`) map status/`Retry-After`/body onto
  `AuthError` / `RateLimited` / `ContextOverflow` / `InvalidRequest` /
  `TransientError`, and mid-stream Anthropic `error` events are
  classified by their error type. The result is surfaced on
  `Response.errorInfo`.

## [baikai-openai 0.2.0.0] - 2026-06-21

### Added

- The OpenAI/OpenAI-compatible API and `codex exec` CLI providers now
  classify failures into the typed `BaikaiError` categories the same way
  as `baikai-claude` (HTTP `ClientError` for status-based errors,
  streamed error text for mid-stream errors), surfaced on
  `Response.errorInfo`.

## [baikai-trace-otel 0.2.0.0] - 2026-06-21

### Changed

- Updated the `baikai` dependency bound to `^>=0.2.0` for compatibility with
  the `baikai 0.2.0.0` breaking API release.

## [baikai-effectful 0.2.0.0] - 2026-06-21

### Changed

- Updated the `baikai` dependency bound to `^>=0.2.0` for compatibility with
  the `baikai 0.2.0.0` breaking API release.

## [baikai 0.1.1.0] - 2026-06-12

### Added

- Added provider-agnostic `ResponseFormat` support on `Options`, including
  plain JSON-object mode and named JSON-schema mode.
- Added `Baikai.Embedding`, an OpenAI `/v1/embeddings` client for text
  embeddings.

## [baikai-claude 0.1.1.0] - 2026-06-12

### Added

- Mapped baikai `ResponseFormat` options onto Anthropic `output_config` for
  Claude API requests.
- Exported `mapRequest` for request-mapping tests and downstream inspection.

## [baikai-openai 0.1.1.0] - 2026-06-12

### Added

- Mapped baikai `ResponseFormat` options onto OpenAI Chat Completions
  `response_format`.
- Exported `mapRequest` for request-mapping tests and downstream inspection.

## [baikai-effectful 0.1.0.0] - 2026-06-12

### Added

- Initial release: effectful binding for baikai with the `Baikai` dynamic
  effect, `complete`, `streamCollect`, `streamEach`, and registry-backed
  interpreters.

## [baikai 0.1.0.0] - 2026-06-04

### Added

- Initial release: unified Haskell interface for working with multiple AI
  providers. Core modules including `Baikai`, `Baikai.Prelude`, `Baikai.Api`,
  `Baikai.Provider`, `Baikai.Provider.Registry`, `Baikai.Response`,
  `Baikai.Stream`, `Baikai.Tool`, `Baikai.Trace`, and the cost/usage modules.
- Depends on released `streamly` (`>=0.11 && <0.13`) and `streamly-core`
  (`>=0.3 && <0.5`) from Hackage, so all dependencies resolve from Hackage.

## [baikai-claude 0.1.0.0] - 2026-06-04

### Added

- Initial release: Anthropic Claude providers for the baikai abstraction,
  wrapping the `claude` package for both the Anthropic API and the `claude -p`
  CLI (`Baikai.Provider.Claude.Api`, `.Cli`, `.Interactive`).

## [baikai-openai 0.1.0.0] - 2026-06-04

### Added

- Initial release: OpenAI providers for the baikai abstraction, wrapping the
  `openai` package for OpenAI's Chat Completions API
  (`Baikai.Provider.OpenAI.Api`, `.Cli`, `.Interactive`).

## [baikai-trace-otel 0.1.0.0] - 2026-06-04

### Added

- Initial release: OpenTelemetry `TraceSink` adapter for baikai
  (`Baikai.Trace.Sink.OpenTelemetry`), emitting one OTel span per provider call
  with GenAI semantic-convention attributes plus baikai cost and latency.
