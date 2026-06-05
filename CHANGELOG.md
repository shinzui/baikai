# Changelog

All notable changes to baikai are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
