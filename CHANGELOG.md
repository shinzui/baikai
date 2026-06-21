# Changelog

All notable changes to baikai are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [baikai 0.1.2.0] - 2026-06-21

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

## [baikai-claude 0.1.2.0] - 2026-06-21

### Added

- The Anthropic API and `claude -p` CLI providers now classify failures
  into the typed `BaikaiError` categories: HTTP errors (via the caught
  `servant-client` `ClientError`) map status/`Retry-After`/body onto
  `AuthError` / `RateLimited` / `ContextOverflow` / `InvalidRequest` /
  `TransientError`, and mid-stream Anthropic `error` events are
  classified by their error type. The result is surfaced on
  `Response.errorInfo`.

## [baikai-openai 0.1.2.0] - 2026-06-21

### Added

- The OpenAI/OpenAI-compatible API and `codex exec` CLI providers now
  classify failures into the typed `BaikaiError` categories the same way
  as `baikai-claude` (HTTP `ClientError` for status-based errors,
  streamed error text for mid-stream errors), surfaced on
  `Response.errorInfo`.

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
