---
id: 4
slug: cost-tracking-with-per-model-pricing
title: "Cost tracking with per-model pricing"
kind: exec-plan
created_at: 2026-05-13T23:39:28Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# Cost tracking with per-model pricing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan (EP-4) adds per-model USD cost computation and an optional JSONL call log on
top of the API providers introduced by EP-2. After it is in place, every `Baikai.Response`
returned by an API provider for a model in the seeded pricing table has its `cost` field
populated with a `Just (Cost { usd, breakdown })` value derived from the token usage the
provider already reports. Models that are not in the table return `cost = Nothing`, and
CLI providers (funded by subscription, with no per-call usage data) also continue to
report `cost = Nothing`.

The user-visible behavior is two-fold. Callers read `response ^. #cost` and obtain a
precise `Rational` USD amount for any supported model without doing arithmetic. They can
also opt into a JSONL log of every API call by opening a `CallLogHandle` (via
`openCallLog` or, idiomatically, `withCallLog`) and threading it through the new helper
`runRequestWithLog`; each call enqueues a single JSON object containing a timestamp,
provider name, model, token usage, computed cost, latency, and a short prompt summary,
which a background worker thread drains to disk. The log file is one JSON object per
line and safe to tail with standard unix tools.

A small end-to-end example illustrates the shape. First, the cost field is filled in by
a Claude API call:

```haskell
import Baikai
import Baikai.Provider.Claude.Api (claudeApi)
import Control.Lens ((^.))

main :: IO ()
main = do
  api <- claudeApi
  let req = mkRequest (Model "claude-sonnet-4-6") "Summarize the Treaty of Westphalia."
  resp <- runRequest api req
  print (resp ^. #cost)
  -- Just (Cost { usd = 42 % 10000, breakdown = CostBreakdown {...} })
```

Second, enabling a JSONL call log and tailing it:

```haskell
import Baikai.Cost.Log (CallLogConfig (..), withCallLog, runRequestWithLog)

main :: IO ()
main = do
  api <- claudeApi
  let cfg = CallLogConfig { path = "/tmp/baikai-calls.jsonl", enabled = True }
  let req = mkRequest (Model "claude-haiku-4-5-20251001") "Hello"
  withCallLog cfg $ \handle -> do
    _ <- runRequestWithLog handle api req
    pure ()
```

```bash
tail -f /tmp/baikai-calls.jsonl
{"timestamp":"2026-05-13T23:42:11Z","provider":"claude-api","model":"claude-haiku-4-5-20251001","inputTokens":12,"outputTokens":7,"cachedInputTokens":null,"reasoningTokens":null,"usd":0.000047,"latencyMs":812,"promptSummary":"Hello"}
```


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-05-13 Define `PricingRate` data type in `Baikai.Cost.Pricing` (in `baikai/src/Baikai/Cost/Pricing.hs`).
- [x] 2026-05-13 Seed `claudePricing` map from https://www.anthropic.com/pricing.
- [x] 2026-05-13 Seed `openaiPricing` map from https://openai.com/api/pricing.
- [x] 2026-05-13 Define `defaultPricing = claudePricing <> openaiPricing`.
- [x] 2026-05-13 Add `lookupRate :: Map Text PricingRate -> Model -> Maybe PricingRate` helper.
- [x] 2026-05-13 Implement `compute :: Map Text PricingRate -> Model -> Usage -> Maybe Cost`.
- [x] 2026-05-13 Implement `attachCost :: Map Text PricingRate -> Response -> Response` in `Baikai.Cost.Pricing` (kept there to avoid a `Baikai.Cost`↔`Baikai.Cost.Pricing` import cycle — see Decision Log).
- [x] 2026-05-13 Add `pricing :: Map Text PricingRate` field to `ClaudeApi` record in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`, defaulting to `defaultPricing`.
- [x] 2026-05-13 Wire `attachCost` into `ClaudeApi`'s `runRequest` implementation in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`.
- [x] 2026-05-13 Add `pricing :: Map Text PricingRate` field to `OpenAIApi` record in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`, defaulting to `defaultPricing`.
- [x] 2026-05-13 Wire `attachCost` into `OpenAIApi`'s `runRequest` implementation in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`.
- [x] 2026-05-13 Add `containers` to `baikai-claude.cabal` and `baikai-openai.cabal` build-depends (needed for `Data.Map.Strict.Map` in the `pricing` field).
- [x] 2026-05-13 `streamly` and `streamly-core` already in `baikai/baikai.cabal` build-depends from EP-3 — no-op here.
- [x] 2026-05-13 Implement `Baikai.Cost.Log` (in `baikai/src/Baikai/Cost/Log.hs`) with `CallLogConfig`, `CallLogEntry`, the opaque `CallLogHandle`, and a `Chan`-fed worker that drains via `Streamly.Data.Stream.unfoldrM` + `Streamly.Data.Fold.drainMapM`.
- [x] 2026-05-13 Implement `openCallLog`, `closeCallLog`, and `withCallLog`.
- [x] 2026-05-13 Implement `appendEntry :: MonadIO m => CallLogHandle -> CallLogEntry -> m ()` as a non-blocking channel push (no-op when `enabled = False`).
- [x] 2026-05-13 Implement `runRequestWithLog :: (Provider p, MonadIO m) => CallLogHandle -> p -> Request -> m Response`.
- [x] 2026-05-13 Add unit tests for `compute` (known, unknown, cached-only) and `attachCost` (known, unknown, no-usage), plus a `CallLog` group that exercises the disabled-handle short-circuit and the enabled handle's end-to-end JSONL write through a `CannedProvider`. `cabal test all` reports 11/11 pass.
- [x] 2026-05-13 Update `baikai/baikai.cabal` `exposed-modules` to include `Baikai.Cost.Pricing` and `Baikai.Cost.Log`; add `aeson`, `bytestring`, `directory`, `filepath` to the test suite's build-depends.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-05-13: The plan put `attachCost` in `Baikai.Cost`, but that creates a module
  import cycle: `Baikai.Cost.Pricing` already imports `Baikai.Cost (Cost (..),
  CostBreakdown (..))` for the result types, and `attachCost` would force the
  reverse import for `PricingRate` and `compute`. Resolved by defining `attachCost`
  in `Baikai.Cost.Pricing` next to `compute`. Both `Baikai.Cost.Pricing` and
  `Baikai.Cost` are exported from the library; consumers of the cost surface are
  expected to import `Baikai.Cost.Pricing` (which is also where `defaultPricing`
  lives) so the public ergonomics are unchanged. Evidence: `cabal build baikai`
  fails with `Module imports form a cycle` if `attachCost` is defined in
  `Baikai.Cost`.

- 2026-05-13: `streamly` and `streamly-core` were already listed in
  `baikai/baikai.cabal` `build-depends` — EP-3 added them when wiring the codex
  JSONL parser. The plan's diff that adds them under EP-4 is therefore a no-op
  on this tree; M4 will use them without a cabal edit.

- 2026-05-13: Adding a `Map Text PricingRate` field to each vendor provider
  required `containers` in `baikai-claude.cabal` and `baikai-openai.cabal`
  build-depends. The plan's diff for Milestone 3 did not call this out (the
  field type alias `Map` was imported but the package was assumed transitive).
  Added explicitly.

- 2026-05-13: Streamly 0.12's public surface in this repo does not export a
  `Streamly.Data.Channel` module — the plan's illustrative `Channel.newChannel`
  / `Channel.send` / `Channel.fromChannel` names don't resolve. M4 will use
  `Control.Concurrent.Chan` from `base` for the producer/consumer queue (with
  a `Maybe CallLogEntry` shutdown sentinel) and still drain it through a
  `Streamly.Data.Stream` + `Streamly.Data.Fold` pipeline, which satisfies the
  master-plan-level constraint "call log buffered through a streamly fold to
  disk". No new third-party deps needed.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `Rational` rather than `Double` for all USD values and pricing rates.
  Rationale: Prices are exact decimal fractions (for example "$3 per million tokens" is
  exactly `3 % 1000000` USD per token). `Double` introduces binary-floating-point drift that
  accumulates across many small token-level multiplications and produces user-visible
  rounding errors when costs are summed. `Rational` is in `base`, costs nothing to construct,
  and is already what EP-1 chose for `Cost.usd`. Conversion to a display format is the
  caller's responsibility via `usdAsScientific`.
  Date: 2026-05-13

- Decision: The pricing table is a `Map Text PricingRate` keyed by the literal model string
  (for example `"claude-sonnet-4-6"`).
  Rationale: Model identifiers are already free-form `Text` in `Baikai.Model`, providers
  pass them through unchanged, and a `Map` keyed on the same string requires no extra
  normalization. A typed enum would force the library to be updated every time a provider
  releases a new model name; a string-keyed map lets users add their own rows without a
  library release.
  Date: 2026-05-13

- Decision: Unknown models yield `cost = Nothing` rather than `Cost { usd = 0, ... }`.
  Rationale: `Nothing` is a truthful signal that the library does not know the price.
  Returning a zero cost would silently understate spend on any model the user has not
  registered, which is exactly the failure mode the cost-tracking feature is meant to
  prevent. Callers that want to default-to-zero can pattern-match on `Maybe` themselves.
  Date: 2026-05-13

- Decision: Call logging is opt-in via `CallLogConfig { enabled = True }`.
  Rationale: Writing to disk on every request is a side effect that should be explicit.
  A user who never constructs a `CallLogConfig` never opens a log file. The disabled branch
  short-circuits before `withFile` is called, so the cost of disabled logging is one record
  pattern-match per call.
  Date: 2026-05-13

- Decision: `runRequestWithLog` is a free function in `Baikai.Cost.Log`, not a method on the
  `Provider` typeclass.
  Rationale: Logging is a cross-cutting concern that composes over any `Provider`
  implementation. Adding it to the typeclass would force every provider (including CLI
  providers and future ones) to know about logging, and would prevent layering other
  wrappers (for example tracing in a future EP) without further typeclass churn. A wrapper
  function keeps the typeclass minimal and composes cleanly.
  Date: 2026-05-13

- Decision: Each provider record carries its own `pricing :: Map Text PricingRate` field,
  defaulting to `defaultPricing`.
  Rationale: This lets a user override pricing per-provider (for example to model a
  negotiated enterprise discount, or to add a model the seeded table does not know about)
  without monkey-patching a global. The cost of carrying the field is a single record slot
  and one `Map.lookup` per call.
  Date: 2026-05-13

- Decision: The cost modules (`Baikai.Cost`, `Baikai.Cost.Pricing`, `Baikai.Cost.Log`) all
  live in the core `baikai` package, not in a vendor-specific package and not in a new
  satellite. The vendor packages `baikai-claude` and `baikai-openai` import the core cost
  module to call `attachCost` inside their `Provider` instances.
  Rationale: Cost computation is provider-agnostic — the same `compute` function, the same
  pricing table type, and the same `attachCost` wrapper work for every API provider. Putting
  the modules in `baikai` core means consumers using only the API providers do not pull in
  the OTel closure or any other satellite. The cost of placing the code in core is zero
  additional dependencies: `compute` and `attachCost` are pure, and `Baikai.Cost.Log` only
  needs `streamly` plus packages EP-1 already depends on.
  Date: 2026-05-13

- Decision: `Baikai.Cost.Log` is built around a streamly channel plus a worker thread that
  drains entries to disk, rather than calling `withFile`/`hPut` synchronously inside
  `appendEntry`.
  Rationale: Decouples API call latency from disk write latency. `appendEntry` becomes a
  cheap channel push that returns immediately, so a slow disk or filesystem hiccup does not
  pad the apparent latency of every `runRequest`. The worker can later be upgraded to batch
  flush every N entries or every 1s without changing any call site, because the public
  surface is just `openCallLog`/`closeCallLog`/`appendEntry`/`withCallLog`. File-handle
  ownership is also cleaner: exactly one thread holds the handle for the lifetime of the
  log, so there is no need to serialize concurrent writers.
  Date: 2026-05-13

- Decision: `openCallLog`, `closeCallLog`, `appendEntry`, and `runRequestWithLog` are `MonadIO m =>`. `withCallLog` stays in `IO`.
  Rationale: One-shot operations match the EP-1 typeclass change. `withCallLog` is a bracket that wraps `bracket :: IO a -> ...`; making it polymorphic would require `MonadUnliftIO`, which is incompatible with `effectful`'s `Eff es`. A future `baikai-effectful` package will ship an `Eff es`-native `withCallLogEff`.
  Date: 2026-05-13

- Decision: `attachCost` lives in `Baikai.Cost.Pricing`, not in `Baikai.Cost`, despite the plan's prose putting it in `Baikai.Cost`.
  Rationale: `Baikai.Cost.Pricing` imports `Baikai.Cost (Cost (..), CostBreakdown (..))` to build the result, so defining `attachCost` in `Baikai.Cost` would close an import cycle. Keeping it in `Pricing` next to `compute` is also the natural grouping — both functions take the same `Map Text PricingRate` and need to know the same shape. The public surface is preserved: callers import `Baikai.Cost.Pricing (attachCost, defaultPricing)`.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- 2026-05-13: EP-4 complete. The library now populates `Response.cost` for any
  API call whose model appears in `defaultPricing`, and the optional
  `Baikai.Cost.Log` module records each call as one JSONL line with timestamp,
  provider, model, token usage, USD cost (as `Scientific`), latency, and a
  ≤200-char user-message summary. `cabal test all` reports 11/11 pass in
  `baikai-test`; `baikai-smoke` still runs end-to-end green against OpenAI
  (`gpt-4o-mini` ≈ usage present), Anthropic `sonnet`, and `codex` default.

- Acceptance evidence: the deterministic compute case
  `compute defaultPricing (Model "claude-haiku-4-5-20251001") (Usage 1000 500
  Nothing Nothing) == Just (Cost { usd = 7/2000, breakdown = ... })`
  is in `baikai/test/CostSpec.hs::computeTests`. The call-log integration test
  uses a `CannedProvider`, writes to `<tmpdir>/baikai-cost-test.jsonl`, then
  reads back the single line and asserts on every populated field. Both pass.

- Gaps vs the plan: `attachCost` lives in `Baikai.Cost.Pricing` rather than
  `Baikai.Cost` to avoid an import cycle (recorded in Decision Log and
  Surprises). The streamly channel module the plan named (`Streamly.Data.Channel`)
  does not exist in the streamly 0.12 pinned by the repo; the channel is
  `Control.Concurrent.Chan` instead, but the worker still drains via a
  streamly `Stream.unfoldrM` + `Fold.drainMapM` pipeline, preserving the
  master-plan-level "buffered through a streamly fold" property.

- Future work the plan flagged that was intentionally not done: a configurable
  drain timeout on `closeCallLog`, in-worker `Stream.handle` to keep writing
  after IO errors, and an `Eff es`-native `withCallLogEff` in a future
  `baikai-effectful` package. None block EP-5 or EP-6.


## Context and Orientation

The project lives at `/Users/shinzui/Keikaku/bokuno/baikai` and is laid out as four
sibling cabal packages: `baikai` (core types and the `Provider` typeclass),
`baikai-claude` and `baikai-openai` (vendor API providers, added by EP-2), and
`baikai-trace-otel` (added by EP-6). Each package has its own cabal file —
`baikai/baikai.cabal`, `baikai-claude/baikai-claude.cabal`,
`baikai-openai/baikai-openai.cabal`, and `baikai-trace-otel/baikai-trace-otel.cabal` —
and they are tied together by the top-level `cabal.project`. The target compiler is
`ghc912`. The default language is `GHC2024`, which means `NumericUnderscores` (used below
for `1_000_000`) is already on. The cabal files' `default-extensions` blocks enable
`DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedStrings`,
which is what lets the code below use `^. #fieldName` lens access and write `Map.fromList`
with bare string literals.

EP-4 adds new code only inside the core `baikai` package. The two new modules are
`Baikai.Cost.Pricing`, in `baikai/src/Baikai/Cost/Pricing.hs`, and `Baikai.Cost.Log`, in
`baikai/src/Baikai/Cost/Log.hs`. The existing `Baikai.Cost` module (introduced by EP-1, in
`baikai/src/Baikai/Cost.hs`) is extended with one new function, `attachCost`, but its
existing types are not changed. The vendor packages `baikai-claude` and `baikai-openai`
receive a small wiring diff each — in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`
and `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` — to import `Baikai.Cost`, carry a
`pricing` field, and call `attachCost` before returning a `Response`.

`Baikai.Cost.Log` introduces one new third-party dependency: `streamly` (with its core
runtime `streamly-core`). The call log is drained from a streamly channel by a dedicated
worker thread so that `appendEntry` never blocks the caller on disk I/O.

EP-1 already established the following types, reproduced here so this plan is self-contained.

```haskell
newtype Model = Model { unModel :: Text }

data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  }

data Cost = Cost
  { usd :: !Rational
  , breakdown :: !CostBreakdown
  }

data CostBreakdown = CostBreakdown
  { inputUsd :: !Rational
  , outputUsd :: !Rational
  , cachedInputUsd :: !Rational
  }

data Response = Response
  { content :: !Text
  , model :: !Model
  , usage :: !(Maybe Usage)
  , cost :: !(Maybe Cost)
  , provider :: !Text
  , latencyMs :: !Integer
  }
```

EP-2 introduced two API provider records and a `Provider` typeclass:

```haskell
-- Current state from EP-2:
data ClaudeApi = ClaudeApi { methods :: !Claude.V1.Methods }
data OpenAIApi = OpenAIApi { methods :: !OpenAI.V1.Methods }
class Provider p where runRequest :: p -> Request -> IO Response
```

EP-4 adds a `pricing :: !(Map Text PricingRate)` field to each provider record, defaulted
by the smart constructors `claudeApi` and `openaiApi` to `defaultPricing`. The
`Provider` typeclass itself does not change.

The pricing values shipped in the seeded table are taken from the providers' published
price pages on 2026-05-13: https://www.anthropic.com/pricing for Claude and
https://openai.com/api/pricing for OpenAI. These pages change. The seeded `claudePricing`
and `openaiPricing` maps in `Baikai.Cost.Pricing` are explicitly marked as snapshots; a
maintainer who wants current numbers should consult those pages and edit the maps.

The call log is JSONL: one JSON object per line, encoded with `Data.Aeson.encode`, terminated
by `\n`. A single line, pretty-printed for the reader, has the following shape.

```json
{
  "timestamp": "2026-05-13T23:42:11Z",
  "provider": "claude-api",
  "model": "claude-haiku-4-5-20251001",
  "inputTokens": 12,
  "outputTokens": 7,
  "cachedInputTokens": null,
  "reasoningTokens": null,
  "usd": 4.7e-5,
  "latencyMs": 812,
  "promptSummary": "Hello"
}
```

The `usd` value in the encoded record is the result of `aeson`'s default encoding of a
`Rational`, which goes through `Scientific`. Numeric precision is preserved within
`Scientific`'s representation. The `promptSummary` is the first 200 characters of the first
user message in the request, with no further processing.

EP-4 adds `streamly` and `streamly-core` to the `baikai` library's `build-depends`. No
other third-party dependencies are introduced. EP-1 already added `aeson`, `bytestring`,
`containers`, `time`, `text`, `vector`, and `scientific`, which together cover the rest
of EP-4's runtime needs.


## Plan of Work

Work proceeds in five milestones. Each milestone leaves the package in a compiling state
and is independently runnable with `cabal build all`. The final milestone wires the unit
tests, which are the acceptance criterion for the whole plan.

### Milestone 1 - Pricing table

Create `baikai/src/Baikai/Cost/Pricing.hs` with the `PricingRate` type and the seeded
Claude and OpenAI tables. At the end of this milestone the module compiles and exports
`PricingRate`, `claudePricing`, `openaiPricing`, `defaultPricing`, and `lookupRate`.
Verify with `cabal build all`. No tests yet — this milestone only exposes data and a
pure lookup.

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Per-model pricing tables. Prices are quoted in USD per million tokens and stored as
-- exact 'Rational' values. The seeded values are a snapshot taken on 2026-05-13 from
-- https://www.anthropic.com/pricing and https://openai.com/api/pricing. Providers change
-- prices; verify against the current page before relying on these values, and feel free
-- to override them per-provider via the 'pricing' field on each provider record.
module Baikai.Cost.Pricing
  ( PricingRate (..)
  , claudePricing
  , openaiPricing
  , defaultPricing
  , lookupRate
  ) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

import Baikai.Model (Model (..))

data PricingRate = PricingRate
  { inputPerMillion :: !Rational
  , outputPerMillion :: !Rational
  , cachedInputPerMillion :: !(Maybe Rational)
  }
  deriving stock (Generic, Show)

-- | Anthropic Claude (USD per million tokens). Snapshot 2026-05-13.
-- Source: https://www.anthropic.com/pricing
claudePricing :: Map Text PricingRate
claudePricing = Map.fromList
  [ ("claude-opus-4-7",            PricingRate { inputPerMillion = 15, outputPerMillion = 75, cachedInputPerMillion = Just (3 / 2) })
  , ("claude-sonnet-4-6",          PricingRate { inputPerMillion = 3,  outputPerMillion = 15, cachedInputPerMillion = Just (3 / 10) })
  , ("claude-sonnet-4-5-20250929", PricingRate { inputPerMillion = 3,  outputPerMillion = 15, cachedInputPerMillion = Just (3 / 10) })
  , ("claude-haiku-4-5-20251001",  PricingRate { inputPerMillion = 1,  outputPerMillion = 5,  cachedInputPerMillion = Just (1 / 10) })
  ]

-- | OpenAI Chat (USD per million tokens). Snapshot 2026-05-13.
-- Source: https://openai.com/api/pricing
openaiPricing :: Map Text PricingRate
openaiPricing = Map.fromList
  [ ("gpt-5",       PricingRate { inputPerMillion = 5,        outputPerMillion = 20,      cachedInputPerMillion = Just (5 / 10) })
  , ("gpt-4o",      PricingRate { inputPerMillion = 5,        outputPerMillion = 20,      cachedInputPerMillion = Just (25 / 10) })
  , ("gpt-4o-mini", PricingRate { inputPerMillion = 15 / 100, outputPerMillion = 6 / 10,  cachedInputPerMillion = Just (75 / 1000) })
  , ("o3",          PricingRate { inputPerMillion = 60,       outputPerMillion = 240,     cachedInputPerMillion = Just 30 })
  ]

defaultPricing :: Map Text PricingRate
defaultPricing = claudePricing <> openaiPricing

lookupRate :: Map Text PricingRate -> Model -> Maybe PricingRate
lookupRate pricing (Model m) = Map.lookup m pricing
```

The seeded numbers are illustrative — the implementer should verify each against the
provider's current pricing page before merging. The shape (a `Map Text PricingRate`
keyed by model string) is fixed; the values are editable.

### Milestone 2 - `compute` and `attachCost`

Add the pure cost computation in `Baikai.Cost.Pricing` and the `Response`-aware wrapper
in `Baikai.Cost`. At the end of this milestone the package compiles, `compute` is
callable from a `cabal repl`, and `attachCost` can be applied to a `Response` value.

```haskell
-- in Baikai.Cost.Pricing, appended below lookupRate:

import Baikai.Cost (Cost (..), CostBreakdown (..))
import Baikai.Usage (Usage)
import Control.Lens ((^.))

compute :: Map Text PricingRate -> Model -> Usage -> Maybe Cost
compute pricing model usage =
  case lookupRate pricing model of
    Nothing -> Nothing
    Just rate ->
      let inUsd =
            toRational (usage ^. #inputTokens)
              * rate ^. #inputPerMillion
              / 1_000_000
          outUsd =
            toRational (usage ^. #outputTokens)
              * rate ^. #outputPerMillion
              / 1_000_000
          cachedUsd =
            case (usage ^. #cachedInputTokens, rate ^. #cachedInputPerMillion) of
              (Just n, Just r) -> toRational n * r / 1_000_000
              _ -> 0
          total = inUsd + outUsd + cachedUsd
      in Just Cost
           { usd = total
           , breakdown = CostBreakdown
               { inputUsd = inUsd
               , outputUsd = outUsd
               , cachedInputUsd = cachedUsd
               }
           }
```

```haskell
-- in Baikai.Cost (new function, exported from the existing module):

import Baikai.Cost.Pricing (PricingRate, compute)
import Baikai.Response (Response)
import Control.Lens ((&), (.~), (^.))
import Data.Map.Strict (Map)
import Data.Text (Text)

attachCost :: Map Text PricingRate -> Response -> Response
attachCost pricing resp = case resp ^. #usage of
  Nothing -> resp
  Just usage ->
    resp & #cost .~ compute pricing (resp ^. #model) usage
```

Lens access via `^.` and the `#fieldName` overloaded label is the project convention,
enabled by `OverloadedLabels` in the cabal default-extensions. `NumericUnderscores`
(part of `GHC2024`) is what lets `1_000_000` parse as an integer literal.

### Milestone 3 - Wire into providers

Modify each provider record (which lives in its own vendor package after EP-2) to carry a
`pricing :: Map Text PricingRate` field, default it via the smart constructor, and apply
`attachCost` to the response inside the existing `runRequest` implementation. Both
vendor packages depend on `baikai`, so importing `Baikai.Cost` and `Baikai.Cost.Pricing`
requires no cabal changes in the vendor packages themselves. The diffs below assume
EP-2's current shape.

```diff
--- a/baikai-claude/src/Baikai/Provider/Claude/Api.hs
+++ b/baikai-claude/src/Baikai/Provider/Claude/Api.hs
@@
 import Baikai.Provider (Provider (..))
+import Baikai.Cost (attachCost)
+import Baikai.Cost.Pricing (PricingRate, defaultPricing)
+import Data.Map.Strict (Map)
+import Data.Text (Text)

 data ClaudeApi = ClaudeApi
   { methods :: !Claude.V1.Methods
+  , pricing :: !(Map Text PricingRate)
   }

 claudeApi :: IO ClaudeApi
 claudeApi = do
   methods <- Claude.V1.makeMethods
-  pure ClaudeApi { methods }
+  pure ClaudeApi { methods, pricing = defaultPricing }

 instance Provider ClaudeApi where
   runRequest api req = do
     raw <- Claude.V1.send (api ^. #methods) (toClaudeRequest req)
-    pure (mapResponse raw)
+    pure (attachCost (api ^. #pricing) (mapResponse raw))
```

The diff for `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs` is structurally identical:
add the same four imports, add `pricing :: !(Map Text PricingRate)` to the `OpenAIApi`
record, default it to `defaultPricing` in `openaiApi`, and wrap the final `mapResponse
raw` in `attachCost (api ^. #pricing) ...` inside the `Provider OpenAIApi` instance.

After applying these diffs the providers fill in `cost` for any model present in their
`pricing` map and leave it `Nothing` otherwise. Users override the table by constructing
the record by hand instead of using the smart constructor.

### Milestone 4 - Call log and `runRequestWithLog`

Create `baikai/src/Baikai/Cost/Log.hs`. The module owns the `CallLogConfig` and
`CallLogEntry` types, the opaque `CallLogHandle`, the streamly-channel-based worker that
drains entries to disk, the lifecycle functions `openCallLog`/`closeCallLog`/`withCallLog`,
the non-blocking `appendEntry`, and the `runRequestWithLog` wrapper.

The design is asynchronous. Each `CallLogHandle` owns a streamly channel and a worker
thread. `appendEntry` writes one `CallLogEntry` onto the channel and returns; the worker
thread reads from the channel and appends one JSON line per entry to the configured file.
This decouples API call latency from disk write latency, gives the channel a place to
absorb bursts, and pins file-handle ownership to a single thread.

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry (..)
  , CallLogHandle
  , openCallLog
  , closeCallLog
  , withCallLog
  , appendEntry
  , runRequestWithLog
  ) where

import Baikai.Model (Model (..))
import Baikai.Provider (Provider (..))
import Baikai.Request (Request)
import Baikai.Response (Response)
import Baikai.Usage (Usage)
import Control.Concurrent (ThreadId, forkIO)
import Control.Exception (bracket)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Function ((&))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.IO (IOMode (AppendMode), withFile)

-- NOTE: streamly 0.10 module names — the implementer should verify against the
-- exact streamly version pinned in the cabal file. `Streamly.Data.Stream`,
-- `Streamly.Data.Fold`, and a channel module (either `Streamly.Data.Channel` in
-- recent releases or `Streamly.Internal.Data.Channel` in older ones) are the
-- intended surface.
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Channel qualified as Channel

data CallLogConfig = CallLogConfig
  { path :: !FilePath
  , enabled :: !Bool
  }

data CallLogEntry = CallLogEntry
  { timestamp :: !UTCTime
  , provider :: !Text
  , model :: !Text
  , inputTokens :: !(Maybe Natural)
  , outputTokens :: !(Maybe Natural)
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  , usd :: !(Maybe Rational)
  , latencyMs :: !Integer
  , promptSummary :: !Text
  }
  deriving stock (Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Opaque handle for an open call log. Owns a streamly channel plus the
-- worker thread that drains entries to disk.
data CallLogHandle = CallLogHandle
  { channel :: !(Channel.Channel IO CallLogEntry)
  , worker :: !ThreadId
  , config :: !CallLogConfig
  }

openCallLog :: MonadIO m => CallLogConfig -> m CallLogHandle
openCallLog cfg = liftIO $ do
  chan <- Channel.newChannel
  tid <- forkIO (runWriter cfg chan)
  pure CallLogHandle { channel = chan, worker = tid, config = cfg }
  where
    runWriter c chan =
      Channel.fromChannel chan
        & Stream.mapM (writeEntry c)
        & Stream.fold Fold.drain

    writeEntry CallLogConfig { path } entry =
      withFile path AppendMode $ \h ->
        BSL.hPut h (Aeson.encode entry <> "\n")

-- | Close the channel and wait for the worker to drain pending entries to disk.
-- The worker exits cleanly once the channel is empty and closed.
closeCallLog :: MonadIO m => CallLogHandle -> m ()
closeCallLog handle = liftIO (Channel.closeChannel (channel handle))

-- | Bracketed lifetime. Recommended over manual open/close. Stays in 'IO'
-- because 'bracket' from @base@ is @IO a -> ...@; making this polymorphic
-- would require 'MonadUnliftIO', which is incompatible with @effectful@'s
-- @Eff es@. Consumers in other monads call @liftIO . withCallLog cfg . ...@
-- or wait for a future @baikai-effectful@ wrapper.
withCallLog :: CallLogConfig -> (CallLogHandle -> IO a) -> IO a
withCallLog cfg = bracket (openCallLog cfg) closeCallLog

-- | Non-blocking. Pushes one entry onto the channel; the worker writes it to
-- disk asynchronously. When `enabled = False`, returns immediately without
-- touching the channel.
appendEntry :: MonadIO m => CallLogHandle -> CallLogEntry -> m ()
appendEntry handle entry
  | not (enabled (config handle)) = pure ()
  | otherwise = liftIO (Channel.send (channel handle) entry)

-- | Run a request and, if logging is enabled, enqueue a JSONL record. The
-- caller is responsible for opening and closing the handle, idiomatically via
-- `withCallLog`.
runRequestWithLog :: (Provider p, MonadIO m) => CallLogHandle -> p -> Request -> m Response
runRequestWithLog handle provider req = do
  resp <- runRequest provider req
  now <- liftIO getCurrentTime
  let u = resp ^. #usage
      entry = CallLogEntry
        { timestamp = now
        , provider = resp ^. #provider
        , model = unModel (resp ^. #model)
        , inputTokens = fmap (^. #inputTokens) u
        , outputTokens = fmap (^. #outputTokens) u
        , cachedInputTokens = u >>= (^. #cachedInputTokens)
        , reasoningTokens = u >>= (^. #reasoningTokens)
        , usd = fmap (^. #usd) (resp ^. #cost)
        , latencyMs = resp ^. #latencyMs
        , promptSummary = Text.take 200 (firstUserMessage req)
        }
  appendEntry handle entry
  pure resp
```

`firstUserMessage` returns the text of the first user-role message in the request, or
empty text if there are none. The worker uses `withFile` in `AppendMode` per entry,
which on Linux and macOS guarantees atomic appends for small `hPut` writes; since the
worker is the only thread that ever opens the path, no cross-thread interleaving is
possible. Exceptions raised inside the worker (for example a full disk) terminate the
worker thread; in a future revision the worker can be wrapped in `Stream.handle` to log
and continue.

The streamly module names above (`Streamly.Data.Channel`, `Channel.newChannel`,
`Channel.send`, `Channel.closeChannel`, `Channel.fromChannel`) are illustrative — the
implementer should verify against the streamly version pinned in the cabal file and pick
the channel module that exists there. Either way, the surface presented from
`Baikai.Cost.Log` (the opaque handle, `openCallLog`, `closeCallLog`, `withCallLog`,
`appendEntry`, `runRequestWithLog`) stays as written.

The cabal change required to make the module compile is small. The `baikai` library
gains `streamly` and `streamly-core` in `build-depends`:

```diff
--- a/baikai/baikai.cabal
+++ b/baikai/baikai.cabal
@@ library
   build-depends:
       aeson
     , base
     , bytestring
     , containers
     , scientific
+    , streamly
+    , streamly-core
     , text
     , time
     , vector
```

The exact bound (for example `streamly >= 0.10 && < 0.11`) follows the project's existing
convention for third-party bounds.

### Milestone 5 - Tests and cabal exposed-modules

Add `baikai/test/CostSpec.hs`. The tests are pure (no network) and exercise the four
cases the Validation section enumerates. The suite `baikai-tests` already exists from
EP-1; append `CostSpec` to its `other-modules`.

```haskell
module CostSpec (spec) where

import Baikai.Cost (attachCost)
import Baikai.Cost.Pricing (compute, defaultPricing)
import Baikai.Model (Model (..))
import Baikai.Response (Response (..))
import Baikai.Usage (Usage (..))
import Control.Lens ((^.))
import Test.Hspec

spec :: Spec
spec = do
  let usage = Usage 1000 500 Nothing Nothing
      mkResp m = Response
        { content = "hi", model = Model m, usage = Just usage
        , cost = Nothing, provider = "claude-api", latencyMs = 100
        }
  describe "compute" $ do
    it "is deterministic for claude-haiku-4-5-20251001" $
      -- 1000*(1/1_000_000) + 500*(5/1_000_000) = 1/1000 + 1/400 = 7/2000
      fmap (^. #usd) (compute defaultPricing (Model "claude-haiku-4-5-20251001") usage)
        `shouldBe` Just (7 / 2000)
    it "returns Nothing for unknown models" $
      compute defaultPricing (Model "totally-fake-model") usage `shouldBe` Nothing
  describe "attachCost" $ do
    it "fills the cost field on known models" $
      fmap (^. #usd) (attachCost defaultPricing (mkResp "claude-haiku-4-5-20251001") ^. #cost)
        `shouldBe` Just (7 / 2000)
    it "leaves cost Nothing on unknown models" $
      (attachCost defaultPricing (mkResp "totally-fake-model")) ^. #cost `shouldBe` Nothing
```

Update `baikai/baikai.cabal` to expose `Baikai.Cost.Pricing` and `Baikai.Cost.Log` and
to add `CostSpec` to the test suite. The exact diff is in the Interfaces and Dependencies
section. Acceptance is `cabal test all` exiting 0 with all four cases passing.


## Concrete Steps

All commands are run from the repository root, `/Users/shinzui/Keikaku/bokuno/baikai`.
First enter the dev shell so the right `ghc`, `cabal`, and `hpack` are on `PATH`.

```bash
cd /Users/shinzui/Keikaku/bokuno/baikai
nix develop
```

Inside the dev shell, build everything to confirm the baseline compiles before any edits.

```bash
cabal build all
```

The expected transcript ends with `Building library for baikai-0.1.0.0...` followed by
per-module `[N of M] Compiling Baikai.Cost.Pricing` lines and a final `Linking ...` line.

After Milestone 2 is in place, sanity-check `compute` in a REPL session.

```bash
cabal repl baikai
```

```text
ghci> import Baikai.Cost.Pricing
ghci> import Baikai.Usage
ghci> import Baikai.Model
ghci> compute defaultPricing (Model "claude-sonnet-4-6") (Usage 1000 500 Nothing Nothing)
Just (Cost {usd = 21 % 2000, breakdown = CostBreakdown {inputUsd = 3 % 1000, outputUsd = 3 % 400, cachedInputUsd = 0 % 1}})
ghci> compute defaultPricing (Model "totally-fake-model") (Usage 1000 500 Nothing Nothing)
Nothing
```

The first result corresponds to `1000 * 3 / 1_000_000 + 500 * 15 / 1_000_000 = 3/1000 +
3/400 = 21/2000` USD, exactly `$0.0105`.

After Milestone 5, run the test suite.

```bash
cabal test all
```

Expected transcript (truncated):

```text
Running 1 test suites...
Test suite baikai-tests: RUNNING...
Cost
  compute
    computes a deterministic cost for claude-haiku-4-5-20251001 [OK]
    returns Nothing for an unknown model                         [OK]
  attachCost
    fills the cost field on a known model                        [OK]
    leaves the cost field as Nothing on an unknown model         [OK]

Finished in 0.0042 seconds
4 examples, 0 failures
Test suite baikai-tests: PASS
```

To exercise the call log against a real provider (requires `ANTHROPIC_API_KEY`), run a
short script and tail the JSONL file in a second terminal.

```bash
export ANTHROPIC_API_KEY=...
cabal run baikai-example -- --log /tmp/baikai-calls.jsonl
```

```bash
tail -f /tmp/baikai-calls.jsonl
```

Each call appends one line. Delete the file with `rm /tmp/baikai-calls.jsonl` to reset
the log.


## Validation and Acceptance

Acceptance is the conjunction of three observable behaviors.

First, the unit test for `compute` passes with deterministic values:
`compute defaultPricing (Model "claude-haiku-4-5-20251001") (Usage 1000 500 Nothing
Nothing)` returns `Just (Cost { usd = 7 / 2000, breakdown = CostBreakdown { inputUsd =
1 / 1000, outputUsd = 1 / 400, cachedInputUsd = 0 } })`. The total `7 / 2000 = 0.0035`
USD matches `1000 * (1 / 1_000_000) + 500 * (5 / 1_000_000)`.

Second, `attachCost` fills the `cost` field of a synthetic `Response` for known models
and leaves it `Nothing` for unknown models. Both are exercised in
`baikai/test/CostSpec.hs`.

Third, the call log appends exactly one valid JSONL record per successful API call. A
record's `provider`, `model`, `usage`, `usd`, and `latencyMs` agree with the
corresponding fields of the `Response`, and `promptSummary` is the first 200 characters
of the first user message in the request.

The command that produces the acceptance evidence is `cabal test all`, with the
transcript shown in the Concrete Steps section above (four examples, zero failures).

A manual end-to-end check against a real provider:

```bash
cabal repl baikai
```

```text
ghci> api <- claudeApi
ghci> resp <- runRequest api (mkRequest (Model "claude-sonnet-4-6") "ping")
ghci> resp ^. #cost
Just (Cost {usd = 9 % 1000000, breakdown = ...})
```

A non-`Nothing` `cost` for a known model is the user-visible behavior this ExecPlan
promises. Compilation alone is not sufficient: both the unit tests and at least one
integration check should be observed.


## Idempotence and Recovery

Every pure function here is safe to re-run. `compute`, `lookupRate`, and `attachCost`
have no side effects and produce the same `Maybe Cost` for the same inputs.

The JSONL call log is append-only. The worker thread opens the configured path in
`AppendMode` for each entry, which creates the file if it does not exist and otherwise
appends a single JSON line. Re-running the same request twice produces two records — that
is the intended behavior. To reset the log, delete the file:

```bash
rm /tmp/baikai-calls.jsonl
```

The next call recreates it.

Because writes are asynchronous, **closing the handle is required to flush pending
writes to disk**. `closeCallLog` closes the streamly channel and blocks until the worker
finishes draining all enqueued entries; the recommended way to guarantee this is to wrap
the consumer in `withCallLog`, which calls `closeCallLog` from `bracket`'s release
action even on exception. A process that exits without closing the handle (for example
because of `exitImmediately` or a hard SIGKILL) loses any entries that the worker has
not yet written. A clean shutdown — `exitSuccess`, `exitFailure`, or simply falling off
the end of `main` after the `withCallLog` block — drains the channel first.

`closeCallLog` accepts a configurable drain timeout in a future revision. The initial
implementation waits unconditionally for the channel to empty; if the disk hangs, so
does shutdown. A caller that wants a bounded shutdown can wrap the close in
`System.Timeout.timeout`.

If the disk is full or the path is unwritable, the worker thread raises an `IOException`
and terminates. `appendEntry` on a handle whose worker has died will continue to push
onto the channel — those entries are not written. In a future revision the worker can be
wrapped in `Stream.handle` (from `Streamly.Data.Stream`) to log the failure and continue
processing. Callers that need strict guarantees today can instead call `runRequest`
directly and append synchronously via their own `try`-wrapped routine.

Inside `runRequestWithLog`, `runRequest` completes before `appendEntry` runs. Because
`appendEntry` is non-blocking, a slow or failing disk no longer pads the apparent
latency of the API call — but neither does it surface as an exception at the call site.


## Interfaces and Dependencies

EP-4 adds new code only inside the `baikai` core package. The vendor packages
`baikai-claude` and `baikai-openai` receive a small wiring diff each (shown in
Milestone 3) but get no new modules. The OTel package `baikai-trace-otel` is untouched.

EP-4 introduces one new third-party dependency on the `baikai` library: `streamly`
(together with its core runtime `streamly-core`). Used by `Baikai.Cost.Log` to run the
asynchronous channel + worker that drains JSONL entries to disk. No other third-party
packages are added; EP-1 already pulled in `aeson`, `bytestring`, `containers`, `time`,
`text`, `vector`, and `scientific`, which together cover the rest of EP-4's runtime
needs. The `lens` package was also pulled in by EP-1 for `^.` access on records and is
reused here. The vendor packages do not gain new `build-depends`: they already depend on
`baikai`, which is enough to import `Baikai.Cost` and `Baikai.Cost.Pricing`.

Two new internal modules are introduced in `baikai`. The first is `Baikai.Cost.Pricing`,
in `baikai/src/Baikai/Cost/Pricing.hs`, which exports:

```haskell
module Baikai.Cost.Pricing
  ( PricingRate (..)
  , claudePricing :: Map Text PricingRate
  , openaiPricing :: Map Text PricingRate
  , defaultPricing :: Map Text PricingRate
  , lookupRate :: Map Text PricingRate -> Model -> Maybe PricingRate
  , compute :: Map Text PricingRate -> Model -> Usage -> Maybe Cost
  ) where
```

The second is `Baikai.Cost.Log`, in `baikai/src/Baikai/Cost/Log.hs`, which exports:

```haskell
module Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry (..)
  , CallLogHandle             -- opaque
  , openCallLog               :: MonadIO m => CallLogConfig -> m CallLogHandle
  , closeCallLog              :: MonadIO m => CallLogHandle -> m ()
  , withCallLog               :: CallLogConfig -> (CallLogHandle -> IO a) -> IO a
  , appendEntry               :: MonadIO m => CallLogHandle -> CallLogEntry -> m ()
  , runRequestWithLog
      :: (Provider p, MonadIO m)
      => CallLogHandle
      -> p
      -> Request
      -> m Response
  ) where
```

The existing `Baikai.Cost` module gains a single new export:

```haskell
attachCost :: Map Text PricingRate -> Response -> Response
```

Existing exports of `Baikai.Cost` (`Cost`, `CostBreakdown`, `usdAsScientific`) are
unchanged.

The two API provider records `ClaudeApi` (in `baikai-claude/src/Baikai/Provider/Claude/Api.hs`)
and `OpenAIApi` (in `baikai-openai/src/Baikai/Provider/OpenAI/Api.hs`) each gain one field,
`pricing :: Map Text PricingRate`, defaulted by their respective smart constructors
`claudeApi` and `openaiApi` to `defaultPricing`. The `Provider` typeclass itself is
unchanged.

The cabal file for `baikai` gets the following diff (combining the exposed-modules,
build-depends, and test other-modules changes):

```diff
--- a/baikai/baikai.cabal
+++ b/baikai/baikai.cabal
@@ library
   exposed-modules:
       Baikai
       Baikai.Cost
+      Baikai.Cost.Log
+      Baikai.Cost.Pricing
       Baikai.Model
       Baikai.Provider
       Baikai.Request
       Baikai.Response
       Baikai.Usage

   build-depends:
       aeson
     , base
     , bytestring
     , containers
     , scientific
+    , streamly
+    , streamly-core
     , text
     , time
     , vector

@@ test-suite baikai-tests
   other-modules:
+      CostSpec
       Paths_baikai
```

Note that `Baikai.Provider.Claude.Api` and `Baikai.Provider.OpenAI.Api` no longer appear
in `baikai`'s `exposed-modules` — they live in the `baikai-claude` and `baikai-openai`
packages respectively, as established by EP-2.

The complete set of new identifiers introduced by this plan: `PricingRate`,
`claudePricing`, `openaiPricing`, `defaultPricing`, `lookupRate`, `compute`,
`attachCost`, `CallLogConfig`, `CallLogEntry`, `CallLogHandle`, `openCallLog`,
`closeCallLog`, `withCallLog`, `appendEntry`, and `runRequestWithLog`.


## Revisions

2026-05-13: Updated EP-4 to reflect the multi-package layout (cost modules live in
`baikai` core; provider wiring diffs target `baikai-claude` and `baikai-openai`).
Redesigned `Baikai.Cost.Log` around a streamly channel + worker thread so that
`appendEntry` does not block the calling code on disk I/O. Driver: the multi-package and
streamly decisions recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s
Decision Log on the same date.

- 2026-05-13: Generalised `openCallLog`, `closeCallLog`, `appendEntry`, and `runRequestWithLog` from concrete `IO` to `MonadIO m =>` (wrapping existing IO bodies in `liftIO`). `withCallLog` and the internal streamly worker stay in `IO` because bracket-style entry points cannot be polymorphic without `MonadUnliftIO`, which `effectful` does not satisfy. Driver: the MonadIO decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.

- 2026-05-14: Correction. The "`effectful` does not satisfy `MonadUnliftIO`" premise was wrong — `effectful-core` provides `instance IOE :> es => MonadUnliftIO (Eff es)`. Generalised `withCallLog` from concrete `IO` to `MonadUnliftIO m =>` via `Control.Monad.IO.Unlift.withRunInIO`; the streamly worker thread still runs in `IO` because it lives inside `forkIO` and that is genuinely `IO`-bound. Updated the misleading inline comment on `withCallLog`. Driver: the 2026-05-14 correction recorded in the masterplan's Decision Log.
