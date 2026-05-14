---
id: 6
slug: opentelemetry-trace-sink-package
title: "OpenTelemetry trace sink package"
kind: exec-plan
created_at: 2026-05-13T23:53:37Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# OpenTelemetry trace sink package

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan creates a new cabal package, `baikai-trace-otel`, that adapts the `TraceSink` interface defined in `baikai` to OpenTelemetry. After this change, any consumer of the AI Provider Abstraction Library can add a single line to their `build-depends` and receive one OTel span per provider call, automatically populated with the GenAI semantic-convention attributes (model, provider, token counts) along with baikai-specific attributes (latency, USD cost). Failed calls record the exception on the span and set its status to `Error`. The package is intentionally split out from `baikai` itself so that consumers who do not want OpenTelemetry pay zero transitive-closure cost: `baikai` will not depend on `hs-opentelemetry-api` or `hs-opentelemetry-sdk`.

The user-visible behavior is opt-in tracing through a small import. After this change ships, the following program compiles and runs against a globally-configured OTel tracer provider:

```haskell
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import OpenTelemetry.Trace (getGlobalTracerProvider, makeTracer, tracerOptions)

main :: IO ()
main = do
  tp <- getGlobalTracerProvider
  let tracer = makeTracer tp "baikai" tracerOptions
  let sink = otelSink tracer
  withTrace sink myProvider myRequest >>= print
```

When run with any OTel SDK exporter installed (stdout, OTLP, in-memory), the program emits one span per provider call named `"baikai.call"` (configurable) with the kind `Client`, attributes following the GenAI semantic conventions, and status `Ok` on success or `Error` on failure. The new package depends on `baikai` (for `TraceEvent` and `TraceSink`), the OpenTelemetry API package (`hs-opentelemetry-api`), and the OpenTelemetry SDK package (`hs-opentelemetry-sdk`) for span creation and attribute setting. The fourth package slots into the existing three-package layout established by EP-2 (`baikai`, `baikai-claude`, `baikai-openai`).

The reader of this plan should be able, after following it, to build `baikai-trace-otel`, run its test suite, and produce a working OTel span in an in-memory exporter against a stub provider — all without touching the existing three packages beyond a one-line `cabal.project` update.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here, even if it requires splitting a partially completed task into two ("done" vs. "remaining"). This section must always reflect the actual current state of the work.

- [ ] Create the `baikai-trace-otel/` directory under the project root.
- [ ] Write the `baikai-trace-otel/baikai-trace-otel.cabal` file with library + test-suite stanzas.
- [ ] Update `cabal.project` to add `baikai-trace-otel` to the `packages:` list.
- [ ] Create `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` with the module header and imports.
- [ ] Implement `OtelSinkOptions` and `defaultOtelSinkOptions`.
- [ ] Implement `otelSink :: Tracer -> TraceSink` as a thin wrapper over `otelSinkWith`.
- [ ] Implement `otelSinkWith :: Tracer -> OtelSinkOptions -> TraceSink` as a stateful `Fold` keyed by `eventId`.
- [ ] Implement the attribute-construction helpers for `CallStarted`, `CallFinished`, `CallFailed`.
- [ ] Implement the fold finalizer that closes leaked spans.
- [ ] Verify the `OpenTelemetry.Trace.Core` API names against the local mori-registered source.
- [ ] Create `baikai-trace-otel/test/Main.hs` with the tasty test suite using the in-memory exporter.
- [ ] Add the success-path test: one span, status Ok, expected attributes.
- [ ] Add the failure-path test: one span, status Error, error message attribute.
- [ ] Run `cabal build all` and `cabal test all` from the project root and confirm green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Ship OTel support as a separate cabal package `baikai-trace-otel`, not as a module inside `baikai`.
  Rationale: `hs-opentelemetry-api` plus `hs-opentelemetry-sdk` drag in a non-trivial transitive closure (HTTP client for OTLP, thread management, batched exporters). Consumers who only want structured tracing through `Baikai.Trace.Sink.JsonLines` or who run in a constrained environment should not pay for that closure. A separate package makes the dependency opt-in.
  Date: 2026-05-13

- Decision: Name span attributes using the OpenTelemetry GenAI semantic conventions where they exist.
  Rationale: The GenAI semantic conventions (https://opentelemetry.io/docs/specs/semconv/gen-ai/) are the emerging standard for instrumenting LLM clients. Using `gen_ai.system`, `gen_ai.request.model`, `gen_ai.response.model`, `gen_ai.request.max_tokens`, `gen_ai.usage.input_tokens`, and `gen_ai.usage.output_tokens` means baikai-emitted spans are immediately usable by any GenAI-aware observability backend. Baikai-specific data (`baikai.event_id`, `baikai.latency_ms`, `baikai.cost.usd`, `baikai.error`) uses the `baikai.` prefix to avoid conflict.
  Date: 2026-05-13

- Decision: Implement the sink as a stateful streamly `Fold` whose state is a `Map Text Span` keyed by `eventId`.
  Rationale: `withTrace` (EP-5) emits `TraceEvent`s in pairs (`CallStarted` + `CallFinished`) or pairs (`CallStarted` + `CallFailed`) on the same `eventId`. The fold must match starts with their corresponding finishes so it can call `Otel.endSpan` on the right span. A `Map Text Span` keyed by `eventId` is the smallest representation that supports concurrent in-flight calls (which a future async provider may produce).
  Date: 2026-05-13

- Decision: Emit `baikai.cost.usd` as a `Double` attribute via `fromRational`.
  Rationale: OpenTelemetry attributes do not natively support `Rational`. `Double` is lossy in principle but precise enough for USD amounts up to roughly 15 significant decimal digits, well beyond the precision any provider's cost figure ever has. The alternative (string-encoded rational) would defeat numerical queries in observability backends.
  Date: 2026-05-13

- Decision: Close leaked spans in the fold's finalizer.
  Rationale: A `CallStarted` without a matching `CallFinished` or `CallFailed` would leak the span — never reaching `endSpan`, never being exported. The fold's finalizer (`Fold.rmapM`) iterates over any spans still present in the state map at end-of-stream and calls `endSpan` with the current wall-clock time, so spans always close even if the producer drops events.
  Date: 2026-05-13

- Decision: Pin `hs-opentelemetry-api ^>=0.2` and `hs-opentelemetry-sdk ^>=0.1` with `^>=` bounds.
  Rationale: The Core API names (`createSpan`, `addAttributes`, `setStatus`, `endSpan`) are stable across the 0.x minor series. The `^>=` operator allows non-breaking minor bumps automatically. The implementer must verify the exact symbol names against the local mori-registered source at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Trace/Core.hs` before building, as some helpers (e.g. `timestampFromTime`) have moved between minor versions.
  Date: 2026-05-13

- Decision: Span kind is `Client`.
  Rationale: A provider call is an outbound request from the application to a third-party LLM API. OpenTelemetry semantics for outbound API calls is `SpanKind = Client`. Using `Client` ensures correct rendering in observability UIs that distinguish between server, client, internal, producer, and consumer spans.
  Date: 2026-05-13

- Decision: `otelSink` and `otelSinkWith` return a `TraceSink` whose underlying fold is `Fold IO TraceEvent ()`; the per-event step functions are `IO`-typed. EP-6 does not add `MonadIO m =>` constraints.
  Rationale: The sink runs inside the worker that EP-5's `withTrace` forks. The worker lives in `IO`. Making the fold polymorphic over `MonadIO m =>` would force every sink author to thread the constraint through their step logic for no payoff (no caller of the fold sits outside the worker). The future `baikai-effectful` package will provide an `Eff es`-flavoured `withTraceEff` wrapper around EP-5's `withTrace`, but the sink contract is unchanged.
  Date: 2026-05-13


## Revisions

- 2026-05-13: Confirmed that EP-6's `otelSink`/`otelSinkWith` signatures remain unchanged after the project-wide MonadIO cascade. The `TraceSink` shape stays as `Fold IO TraceEvent ()` because the sink runs inside the worker spawned by EP-5's `withTrace`, which lives in `IO`. Added a Decision Log entry capturing this. Driver: the MonadIO decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The project root is `/Users/shinzui/Keikaku/bokuno/baikai`. After EP-2 of the master plan (`docs/masterplans/1-ai-provider-abstraction-library.md`) lands, the repository contains three cabal packages — `baikai/`, `baikai-claude/`, `baikai-openai/` — and a `cabal.project` file at the root that reads:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
```

This ExecPlan adds a fourth package, `baikai-trace-otel/`, alongside the existing three. The target GHC is `ghc912`. The cabal file uses `default-language: GHC2024` and the default extensions `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings` (consistent with the other three packages).

The new package consumes two types defined in the `baikai` package by EP-1 and EP-5 (`TraceEvent` in `Baikai.Trace.Types` and `TraceSink` in `Baikai.Trace`):

```haskell
data TraceEvent
  = CallStarted
      { eventId :: !Text
      , timestamp :: !UTCTime
      , provider :: !Text
      , model :: !Text
      , maxTokens :: !Natural
      , promptSummary :: !Text
      }
  | CallFinished
      { eventId :: !Text
      , timestamp :: !UTCTime
      , provider :: !Text
      , model :: !Text
      , latencyMs :: !Integer
      , inputTokens :: !(Maybe Natural)
      , outputTokens :: !(Maybe Natural)
      , usd :: !(Maybe Rational)
      }
  | CallFailed
      { eventId :: !Text
      , timestamp :: !UTCTime
      , provider :: !Text
      , model :: !Text
      , latencyMs :: !Integer
      , errorMessage :: !Text
      }
  deriving stock (Generic, Show)

newtype TraceSink = TraceSink { runSink :: Fold IO TraceEvent () }
```

A `TraceSink` is a streamly `Fold` (from `streamly-core`'s `Streamly.Data.Fold`) that consumes a stream of `TraceEvent` values in `IO`. The `withTrace` combinator (EP-5) emits a `CallStarted` immediately before a provider call and either a `CallFinished` or a `CallFailed` immediately after, sharing the same `eventId :: Text`. Multiple in-flight calls may overlap if a consumer wraps a streaming or async provider, hence the keyed match. Future `Eff es` callers will obtain their tracing via a `baikai-effectful` wrapper around `withTrace`, but the `otelSink` value itself is consumed without modification on that path.

The `hs-opentelemetry` library is registered with mori at `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/`. The implementer should read the local source rather than guessing. The key modules and symbols:

- `OpenTelemetry.Trace.Core` (`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Trace/Core.hs`): `Tracer`, `Span`, `createSpan :: Tracer -> Context -> Text -> SpanArguments -> m Span`, `endSpan :: Span -> Maybe Timestamp -> m ()`, `addAttributes :: Span -> HashMap Text Attribute -> m ()`, `setStatus :: Span -> SpanStatus -> m ()`, `recordException`, `defaultSpanArguments`, `SpanKind(Client)`, `SpanStatus(Unset, Ok, Error)`.
- `OpenTelemetry.Trace` (re-export surface): `getGlobalTracerProvider`, `makeTracer`, `tracerOptions`.
- `OpenTelemetry.Attributes`: `Attribute`, `ToAttribute(toAttribute)` for `Int`, `Text`, `Double`, `Bool`.
- The in-memory exporter package `hs-opentelemetry-exporter-in-memory` (also mori-registered under the same project root) exposes a `newInMemoryExporter :: IO InMemoryExporter` plus accessors that return the recorded spans as a `Vector ImmutableSpan`. The implementer should read the in-memory exporter's source for the exact accessor name (it has been renamed across minor versions).

The streamly `Fold` API used by this plan is `Fold.foldlM' :: (s -> a -> m s) -> m s -> Fold m a s` followed by `Fold.rmapM :: (s -> m b) -> Fold m a s -> Fold m a b` to attach the finalizer. The implementer should read `/Users/shinzui/Keikaku/hub/haskell/streamly-project/streamly/core/src/Streamly/Internal/Data/Fold/Type.hs` if the names differ.

Non-obvious terms used in this plan: "transitive closure cost" means the total set of packages and dynamic libraries brought in via `build-depends` recursion; "leaked span" means a `Span` that was created via `createSpan` but never passed to `endSpan`, which prevents the exporter from emitting it; "GenAI semantic conventions" are the OpenTelemetry-blessed attribute names for instrumenting calls to generative-AI APIs, documented at https://opentelemetry.io/docs/specs/semconv/gen-ai/ .


## Plan of Work

The work is split into four milestones. Each milestone is independently verifiable: after milestone 1 the package exists and `cabal build all` succeeds even though the module is empty; after milestone 2 the library module is implemented and compiles; after milestone 3 the test suite passes; after milestone 4 the smoke example prints a real OTel span.

### Milestone 1: Create the `baikai-trace-otel` package skeleton

Scope: create the directory `baikai-trace-otel/`, write `baikai-trace-otel/baikai-trace-otel.cabal`, create `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` with just the module header (no body), update `cabal.project` at the project root to list the new package. After this milestone, running `cabal build all` from the project root succeeds and `cabal-install` recognizes the fourth package.

The cabal file in full:

```cabal
cabal-version:      3.0
name:               baikai-trace-otel
version:            0.1.0.0
synopsis:           OpenTelemetry TraceSink for baikai
description:
  Provides an opt-in OpenTelemetry adapter for the baikai TraceSink interface.
  Adding this package to your build-depends and wiring `otelSink` into
  `Baikai.Trace.withTrace` produces one OTel span per provider call, with
  GenAI semantic-convention attributes plus baikai-specific cost and latency.
license:            BSD-3-Clause
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
build-type:         Simple

common warnings
  ghc-options: -Wall -Wunused-packages

library
  import:             warnings
  hs-source-dirs:     src
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings
  exposed-modules:    Baikai.Trace.Sink.OpenTelemetry
  build-depends:
    , base                ^>=4.20
    , baikai
    , containers          ^>=0.7
    , hs-opentelemetry-api ^>=0.2
    , hs-opentelemetry-sdk ^>=0.1
    , streamly            ^>=0.10
    , streamly-core       ^>=0.2
    , text                ^>=2.1
    , time                ^>=1.12
    , unordered-containers ^>=0.2

test-suite baikai-trace-otel-test
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Main.hs
  default-language:   GHC2024
  default-extensions:
    DuplicateRecordFields
    OverloadedStrings
  build-depends:
    , base
    , baikai
    , baikai-trace-otel
    , containers
    , hs-opentelemetry-api
    , hs-opentelemetry-sdk
    , hs-opentelemetry-exporter-in-memory
    , tasty               ^>=1.5
    , tasty-hunit         ^>=0.10
    , text
    , time
    , unordered-containers
```

Update `cabal.project` from its three-package form to:

```text
packages:
  baikai
  baikai-claude
  baikai-openai
  baikai-trace-otel
```

Commands to verify: `cabal build all` succeeds; `cabal list-bin baikai-trace-otel-test` resolves (even if the binary is not yet built).

### Milestone 2: Implement `Baikai.Trace.Sink.OpenTelemetry`

Scope: fill in `baikai-trace-otel/src/Baikai/Trace/Sink/OpenTelemetry.hs` with the data type `OtelSinkOptions`, the value `defaultOtelSinkOptions`, the function `otelSink`, and the function `otelSinkWith`. After this milestone, the library compiles and `import Baikai.Trace.Sink.OpenTelemetry` resolves from a downstream test.

The full module:

```haskell
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

-- | OpenTelemetry adapter for the baikai 'TraceSink' interface.
--
-- Wire 'otelSink' (or 'otelSinkWith') into 'Baikai.Trace.withTrace' to emit
-- one OTel span per provider call. Span attributes follow the OpenTelemetry
-- GenAI semantic conventions where possible; baikai-specific data uses the
-- @baikai.@ prefix.
module Baikai.Trace.Sink.OpenTelemetry
  ( otelSink
  , otelSinkWith
  , OtelSinkOptions (..)
  , defaultOtelSinkOptions
  ) where

import Baikai.Trace (TraceSink (..))
import Baikai.Trace.Types (TraceEvent (..))
import Control.Monad (forM_)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Clock (getCurrentTime)
import qualified OpenTelemetry.Attributes as Attr
import qualified OpenTelemetry.Trace.Core as Otel
import qualified Streamly.Data.Fold as Fold

-- | Tunable knobs for 'otelSinkWith'.
data OtelSinkOptions = OtelSinkOptions
  { spanName :: !Text
    -- ^ Name to give each emitted span. Default: @"baikai.call"@.
  , includePromptSummary :: !Bool
    -- ^ If 'True', attach the redacted prompt summary as
    -- @gen_ai.prompt_summary@. Off by default to avoid logging
    -- user content into observability backends.
  }

defaultOtelSinkOptions :: OtelSinkOptions
defaultOtelSinkOptions =
  OtelSinkOptions
    { spanName = "baikai.call"
    , includePromptSummary = False
    }

-- | Adapt a 'Otel.Tracer' to a baikai 'TraceSink' with the default options.
otelSink :: Otel.Tracer -> TraceSink
otelSink tracer = otelSinkWith tracer defaultOtelSinkOptions

-- | Adapt a 'Otel.Tracer' to a baikai 'TraceSink' with custom options.
otelSinkWith :: Otel.Tracer -> OtelSinkOptions -> TraceSink
otelSinkWith tracer opts =
  TraceSink $
    Fold.rmapM finalizer (Fold.foldlM' (stepEvent tracer opts) (pure Map.empty))
  where
    finalizer :: Map Text Otel.Span -> IO ()
    finalizer remaining = do
      now <- getCurrentTime
      let ts = Otel.timestampFromTime now
      forM_ (Map.elems remaining) $ \sp ->
        Otel.endSpan sp (Just ts)

stepEvent :: Otel.Tracer -> OtelSinkOptions -> Map Text Otel.Span -> TraceEvent -> IO (Map Text Otel.Span)
stepEvent tracer OtelSinkOptions {spanName, includePromptSummary} m
  CallStarted {eventId, timestamp, provider, model, maxTokens, promptSummary} = do
    let baseAttrs :: HashMap Text Attr.Attribute
        baseAttrs =
          HashMap.fromList
            [ ("gen_ai.system", Attr.toAttribute provider)
            , ("gen_ai.request.model", Attr.toAttribute model)
            , ("gen_ai.request.max_tokens", Attr.toAttribute (fromIntegral maxTokens :: Int))
            , ("baikai.event_id", Attr.toAttribute eventId)
            ]
        attrs =
          if includePromptSummary
            then HashMap.insert "gen_ai.prompt_summary" (Attr.toAttribute promptSummary) baseAttrs
            else baseAttrs
        sargs =
          Otel.defaultSpanArguments
            { Otel.kind = Otel.Client
            , Otel.attributes = attrs
            , Otel.startTime = Just (Otel.timestampFromTime timestamp)
            }
    sp <- Otel.createSpan tracer Otel.emptyContext spanName sargs
    pure (Map.insert eventId sp m)
stepEvent _ _ m CallFinished {eventId, timestamp, model, latencyMs, inputTokens, outputTokens, usd} =
  case Map.lookup eventId m of
    Nothing -> pure m
    Just sp -> do
      let attrs :: HashMap Text Attr.Attribute
          attrs =
            HashMap.fromList $
              [ ("gen_ai.response.model", Attr.toAttribute model)
              , ("baikai.latency_ms", Attr.toAttribute (fromIntegral latencyMs :: Int))
              ]
                <> maybe [] (\n -> [("gen_ai.usage.input_tokens", Attr.toAttribute (fromIntegral n :: Int))]) inputTokens
                <> maybe [] (\n -> [("gen_ai.usage.output_tokens", Attr.toAttribute (fromIntegral n :: Int))]) outputTokens
                <> maybe [] (\r -> [("baikai.cost.usd", Attr.toAttribute (fromRational r :: Double))]) usd
      Otel.addAttributes sp attrs
      Otel.setStatus sp Otel.Ok
      Otel.endSpan sp (Just (Otel.timestampFromTime timestamp))
      pure (Map.delete eventId m)
stepEvent _ _ m CallFailed {eventId, timestamp, latencyMs, errorMessage} =
  case Map.lookup eventId m of
    Nothing -> pure m
    Just sp -> do
      Otel.addAttributes sp $
        HashMap.fromList
          [ ("baikai.latency_ms", Attr.toAttribute (fromIntegral latencyMs :: Int))
          , ("baikai.error", Attr.toAttribute errorMessage)
          ]
      Otel.setStatus sp (Otel.Error errorMessage)
      Otel.endSpan sp (Just (Otel.timestampFromTime timestamp))
      pure (Map.delete eventId m)
```

The exact `OpenTelemetry.Trace.Core` symbol names may differ slightly between the version pinned in Nix and what the code above assumes. Before declaring this milestone done, the implementer must open `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/api/src/OpenTelemetry/Trace/Core.hs` and confirm: `createSpan` argument order, `endSpan` signature, `addAttributes` vs. `addAttribute`, `defaultSpanArguments` record field names (`kind`, `attributes`, `startTime`), and `timestampFromTime`'s actual home module. Adjust imports accordingly.

Commands to verify: `cabal build baikai-trace-otel` succeeds with no warnings beyond unused-package.

### Milestone 3: In-memory exporter test

Scope: write `baikai-trace-otel/test/Main.hs`. After this milestone, `cabal test baikai-trace-otel-test` runs two test cases: a success case and a failure case.

The full test file:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Baikai.Trace (TraceSink (..), withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.Vector as Vector
import qualified OpenTelemetry.Attributes as Attr
import qualified OpenTelemetry.Exporter.InMemory as InMem
import qualified OpenTelemetry.Trace as Otel
import qualified OpenTelemetry.Trace.Core as Otel
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-trace-otel"
      [ testCase "success path emits one Ok span with expected attributes" testSuccessSpan
      , testCase "failure path emits one Error span with error message" testFailureSpan
      ]

testSuccessSpan :: IO ()
testSuccessSpan = do
  (tracer, getSpans) <- newTracerWithInMemory
  let sink = otelSink tracer
  _ <- withTrace sink stubSuccessProvider stubRequest
  spans <- getSpans
  assertEqual "exactly one span" 1 (Vector.length spans)
  let sp = Vector.head spans
  Otel.spanName sp @?= "baikai.call"
  let attrs = Otel.spanAttributes sp
  assertBool "has gen_ai.system" (HashMap.member "gen_ai.system" attrs)
  assertBool "has gen_ai.request.model" (HashMap.member "gen_ai.request.model" attrs)
  assertBool "has baikai.latency_ms" (HashMap.member "baikai.latency_ms" attrs)
  Otel.spanStatus sp @?= Otel.Ok

testFailureSpan :: IO ()
testFailureSpan = do
  (tracer, getSpans) <- newTracerWithInMemory
  let sink = otelSink tracer
  _ <- withTrace sink stubFailureProvider stubRequest
  spans <- getSpans
  assertEqual "exactly one span" 1 (Vector.length spans)
  let sp = Vector.head spans
  case Otel.spanStatus sp of
    Otel.Error msg -> assertBool "error message non-empty" (not (null msg))
    other -> fail ("expected Error status, got: " <> show other)
  let attrs = Otel.spanAttributes sp
  assertBool "has baikai.error" (HashMap.member "baikai.error" attrs)

-- The names below stand in for whatever `newInMemoryExporter`, `stubSuccessProvider`,
-- and `stubRequest` are called once EP-1, EP-5, and the in-memory exporter source
-- are read. The implementer adapts to the actual symbols.
```

The stub provider, stub request, and the wiring of the in-memory exporter to a `TracerProvider` (so `getSpans :: IO (Vector ImmutableSpan)` works) must be filled in by reading the in-memory exporter's source under the mori-registered `hs-opentelemetry-project` directory. The typical idiom is to construct an exporter, wrap it in a simple processor, attach to a fresh `TracerProvider`, and call a `flush`-equivalent before reading spans.

Commands to verify: `cabal test baikai-trace-otel-test` exits with code 0 and reports `2 of 2 tests passed`.

### Milestone 4: Smoke example

Scope: a single example program inside the test executable (or as a second `test-suite` stanza, or as an `executable`) that uses `hs-opentelemetry-exporter-handle` to stream spans to stdout, so a developer can eyeball one OTel span on their terminal. This milestone is for human verification, not CI.

A minimal driver that the implementer can copy into a scratch file or a one-off `executable` stanza:

```haskell
module Main (main) where

import Baikai.Trace (withTrace)
import Baikai.Trace.Sink.OpenTelemetry (otelSink)
import qualified OpenTelemetry.Trace as Otel

main :: IO ()
main = do
  tp <- Otel.getGlobalTracerProvider
  let tracer = Otel.makeTracer tp "baikai" Otel.tracerOptions
  let sink = otelSink tracer
  _ <- withTrace sink stubProvider stubRequest
  Otel.shutdownTracerProvider tp
```

Commands to verify: run the example under `cabal run baikai-trace-otel-smoke` with `OTEL_TRACES_EXPORTER=console` (or whatever the handle-exporter env var resolves to) and observe one JSON span on stdout.


## Concrete Steps

All commands run from the project root, `/Users/shinzui/Keikaku/bokuno/baikai`, inside a `nix develop` shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
```

Expected: a shell prompt with `ghc-9.12.x`, `cabal-install` 3.x, and `hs-opentelemetry-*` packages available on `cabal`'s view of the package db.

After creating the directory and files described in milestones 1 through 3, verify the full build:

```bash
cabal build all
```

Expected transcript (abbreviated):

```text
Resolving dependencies...
Build profile: -w ghc-9.12.x -O1
In order, the following will be built (use -v for more details):
 - baikai-trace-otel-0.1.0.0 (lib) (first run)
 - baikai-trace-otel-0.1.0.0 (test:baikai-trace-otel-test) (first run)
Configuring library for baikai-trace-otel-0.1.0.0...
Preprocessing library for baikai-trace-otel-0.1.0.0...
Building library for baikai-trace-otel-0.1.0.0...
[1 of 1] Compiling Baikai.Trace.Sink.OpenTelemetry ( src/Baikai/Trace/Sink/OpenTelemetry.hs, ... )
```

Then run the test suite:

```bash
cabal test baikai-trace-otel-test --test-show-details=direct
```

Expected:

```text
Running 1 test suites...
Test suite baikai-trace-otel-test: RUNNING...
baikai-trace-otel
  success path emits one Ok span with expected attributes: OK
  failure path emits one Error span with error message:    OK

All 2 tests passed (0.0xs)
Test suite baikai-trace-otel-test: PASS
```

To eyeball a real span with the handle/stdout exporter (milestone 4), run the smoke executable (only if the `executable` stanza is added) with the console exporter env var set:

```bash
OTEL_TRACES_EXPORTER=console cabal run baikai-trace-otel-smoke
```

Expected: one JSON object printed on stdout containing fields `name: "baikai.call"`, `kind: "Client"`, `status: "Ok"`, and a `attributes` map with `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `baikai.latency_ms`, and (if the stub returns a cost) `baikai.cost.usd`.


## Validation and Acceptance

Acceptance is the test suite `baikai-trace-otel-test` passing in the project's CI/local Nix dev shell. The two test cases exercise the end-to-end behavior:

The success case: build a `Tracer` backed by an in-memory exporter, build the sink with `otelSink tracer`, run a stub provider through `withTrace sink stubSuccessProvider stubRequest`, then read the exporter's recorded spans. Expectations:

- Exactly one span is recorded.
- Span name equals `"baikai.call"`.
- Attributes contain `gen_ai.system`, `gen_ai.request.model`, `gen_ai.request.max_tokens`, `gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `baikai.event_id`, and `baikai.latency_ms`.
- If the stub provider's response carries a cost, `baikai.cost.usd` is present as a `Double` attribute.
- Span status is `Ok`.

The failure case: same setup, but the stub provider raises an exception. Expectations:

- Exactly one span is recorded.
- Span status is `Error` with the non-empty error message.
- Attributes contain `baikai.error` (the error message) and `baikai.latency_ms`.

Run with:

```bash
cabal test baikai-trace-otel-test --test-show-details=direct
```

Expected exit code: 0. Expected output:

```text
baikai-trace-otel
  success path emits one Ok span with expected attributes: OK
  failure path emits one Error span with error message:    OK

All 2 tests passed
```

Beyond the unit tests, run the smoke example (milestone 4) and visually confirm one JSON-encoded span appears on stdout. This proves the change is effective at runtime, not just at compile time.


## Idempotence and Recovery

Re-running `cabal build all` and `cabal test baikai-trace-otel-test` is safe and produces the same result every time. The in-memory exporter is constructed fresh inside each test case, so tests do not share state across runs or across cases. Spans are flushed via the exporter's flush primitive (or by tearing down the `TracerProvider`) at the end of each test, so no spans leak between tests.

If a `CallStarted` event is emitted but neither `CallFinished` nor `CallFailed` arrives — which can happen if a producer aborts mid-stream — the fold's finalizer closes the still-open span with the current wall-clock time as its end timestamp. This means the exporter still receives a span (possibly with status `Unset`), avoiding any leak of OS resources tied to the span.

If the OTel SDK is misconfigured (no exporter registered with the `TracerProvider`), spans are dropped silently. This is a property of `hs-opentelemetry-sdk`, not of baikai. During development, the recommended quick-verification path is to install the handle exporter writing JSON to stdout (`hs-opentelemetry-exporter-handle`) and confirm that span data appears on the terminal. The smoke example in milestone 4 demonstrates this.

To roll back the change: delete the `baikai-trace-otel/` directory, remove the `baikai-trace-otel` line from `cabal.project`, and run `cabal build all` again. No state in the other three packages depends on this package, so removal is clean.


## Interfaces and Dependencies

The new package's library `build-depends` (final, end-of-milestone-2):

- `base ^>=4.20` — standard prelude on GHC 9.12.
- `baikai` — provides `Baikai.Trace.TraceSink` (newtype around `Fold IO TraceEvent ()`) and `Baikai.Trace.Types.TraceEvent`.
- `containers ^>=0.7` — `Data.Map.Strict.Map` for the in-flight-spans state.
- `hs-opentelemetry-api ^>=0.2` — `OpenTelemetry.Trace.Core`, `OpenTelemetry.Attributes`.
- `hs-opentelemetry-sdk ^>=0.1` — `OpenTelemetry.Trace` re-exports, `defaultSpanArguments`, the actual `Tracer` runtime.
- `streamly ^>=0.10`, `streamly-core ^>=0.2` — `Streamly.Data.Fold.Fold`, `foldlM'`, `rmapM`.
- `text ^>=2.1` — `Text` keys and attribute values.
- `time ^>=1.12` — `getCurrentTime`, `UTCTime`.
- `unordered-containers ^>=0.2` — `Data.HashMap.Strict.HashMap` for attribute maps (the OTel API takes a `HashMap`).

Test-suite-only `build-depends`:

- `tasty ^>=1.5`, `tasty-hunit ^>=0.10` — test driver and assertions.
- `hs-opentelemetry-exporter-in-memory` — produces a `Vector ImmutableSpan` of recorded spans for assertion.

Module-level exports of `Baikai.Trace.Sink.OpenTelemetry` at end of milestone 2:

- `otelSink :: Otel.Tracer -> TraceSink`
- `otelSinkWith :: Otel.Tracer -> OtelSinkOptions -> TraceSink`
- `OtelSinkOptions(..)` with fields `spanName :: Text` and `includePromptSummary :: Bool`.
- `defaultOtelSinkOptions :: OtelSinkOptions`.

The cabal file in its final form (also reproduced under milestone 1 for completeness):

```cabal
cabal-version:      3.0
name:               baikai-trace-otel
version:            0.1.0.0
synopsis:           OpenTelemetry TraceSink for baikai
license:            BSD-3-Clause
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
build-type:         Simple

common warnings
  ghc-options: -Wall -Wunused-packages

library
  import:             warnings
  hs-source-dirs:     src
  default-language:   GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    OverloadedLabels
    OverloadedStrings
  exposed-modules:    Baikai.Trace.Sink.OpenTelemetry
  build-depends:
    , base                 ^>=4.20
    , baikai
    , containers           ^>=0.7
    , hs-opentelemetry-api ^>=0.2
    , hs-opentelemetry-sdk ^>=0.1
    , streamly             ^>=0.10
    , streamly-core        ^>=0.2
    , text                 ^>=2.1
    , time                 ^>=1.12
    , unordered-containers ^>=0.2

test-suite baikai-trace-otel-test
  import:             warnings
  type:               exitcode-stdio-1.0
  hs-source-dirs:     test
  main-is:            Main.hs
  default-language:   GHC2024
  default-extensions:
    DuplicateRecordFields
    OverloadedStrings
  build-depends:
    , base
    , baikai
    , baikai-trace-otel
    , containers
    , hs-opentelemetry-api
    , hs-opentelemetry-sdk
    , hs-opentelemetry-exporter-in-memory
    , tasty                ^>=1.5
    , tasty-hunit          ^>=0.10
    , text
    , time
    , unordered-containers
```

The `cabal.project` diff:

```diff
 packages:
   baikai
   baikai-claude
   baikai-openai
+  baikai-trace-otel
```

No other interface changes are required across the project. The `baikai` package's `TraceSink` and `TraceEvent` types are consumed verbatim. The `baikai-claude` and `baikai-openai` packages are unaffected.
