---
id: 5
slug: observability-and-call-tracing
title: "Observability and call tracing"
kind: exec-plan
created_at: 2026-05-13T23:39:31Z
intention: "intention_01krhv5e3ge8gbtm77v3qjvbb9"
master_plan: "docs/masterplans/1-ai-provider-abstraction-library.md"
---

# Observability and call tracing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This ExecPlan adds structured trace events for every provider call. Every call through
a wrapped provider emits `CallStarted` when work begins and either `CallFinished` or
`CallFailed` when it ends. Each event carries provider, model, timestamp, latency, and
(for finished calls) input/output token counts and dollar cost. Events are delivered to
a `TraceSink` — a thin newtype around a `streamly` `Fold IO TraceEvent ()`. The fold
shape is the key design decision: folds compose with `Fold.tee`, `Fold.filter`, and
`Fold.lmap`, and the OpenTelemetry sink shipped by EP-6 is itself a fold and slots into
the same plumbing without an adapter.

What changes for the user is a single wrapper. Where today a caller writes
`runRequest provider req`, after EP-5 they write `withTrace stdoutSink provider req` and
every call prints a one-line human-readable summary. Swap the sink for the result of
`fileSink "calls.jsonl"` and the same events become JSON Lines on disk, suitable for `jq`
filtering, log aggregation, or replay. A `silent` sink is provided for tests, and
`multiSink` fans events out to several sinks at once.

Worked example:

```haskell
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink (stdoutSink, fileSink, multiSink)
import Data.Text.IO qualified as Text.IO

main :: IO ()
main = do
  fSink <- fileSink "calls.jsonl"
  let sink = multiSink [stdoutSink, fSink]
  resp <- withTrace sink myProvider myRequest
  Text.IO.putStrLn (content resp)
```

`withTrace` opens a streamly channel, forks one worker running the chosen fold over the
channel's stream, pushes `CallStarted`, invokes `runRequest`, then pushes either
`CallFinished` or `CallFailed`, closes the channel, and waits for the worker to drain.
The failure path re-throws the original exception after the failure event is durable.
EP-5 deliberately does not retry, redact, or sample events; those concerns belong above
the sink interface.

## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Add `streamly ^>=0.10`, `streamly-core ^>=0.2`, and `stm` to `build-depends`; add `Baikai.Trace`, `Baikai.Trace.Event`, `Baikai.Trace.Sink` to `exposed-modules` in `baikai/baikai.cabal`.
- [ ] Create `baikai/src/Baikai/Trace/Event.hs` with the `TraceEvent` type.
- [ ] Define JSON encoding using tagged-object `Aeson.Options` (`"kind"` discriminator, snake-case tags).
- [ ] Create `baikai/src/Baikai/Trace/Sink.hs` exporting `TraceSink` (newtype around `Fold IO TraceEvent ()`), `silent`, `stdoutSink`, `fileSink`, `multiSink`.
- [ ] Implement `renderHuman :: TraceEvent -> Text` for the human one-line summary.
- [ ] Implement `fileSink :: FilePath -> IO TraceSink` (open per write for crash safety).
- [ ] Implement `multiSink` via `Fold.tee` folded across the input list.
- [ ] Create `baikai/src/Baikai/Trace.hs` exporting `withTrace`, `runRequestWith`, `newEventId`, `summarizePrompt`.
- [ ] Implement `newEventId` (POSIX seconds at start + `IORef Word` counter, 8 hex chars) and `summarizePrompt` (first 200 chars of last user message).
- [ ] Implement the per-call channel/worker plumbing in `withTrace`, draining on both success and failure paths.
- [ ] Write the unit test that uses `silent` to verify success and failure do not panic.
- [ ] Write the unit test that uses an in-memory `TVar [TraceEvent]` sink (lifted into a `Fold IO TraceEvent ()`) to assert `CallStarted` / `CallFinished` / `CallFailed` ordering.
- [ ] Run `cabal build all` and `cabal test all`; record output in Concrete Steps.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: `TraceSink` is `newtype TraceSink = TraceSink { runSink :: Fold IO TraceEvent () }`, not a function-in-record.
  Rationale: A streamly fold composes with the ecosystem (`Fold.tee` for `multiSink`,
  `Fold.filter` for redaction, `Fold.lmap` for projection) for free. EP-6's OTel sink
  is itself a fold and plugs into `withTrace` without an adapter. A function-in-record
  would force every future composition primitive to be reinvented.
  Date: 2026-05-13

- Decision: `withTrace` forks one worker thread per call (open channel, fork, drain, close).
  Rationale: Keeps the EP-5 surface area small and avoids a global handle to be
  initialized at app startup. The cost is one `forkIO` per call — negligible against
  millisecond-scale provider latency. A follow-up `withTraceShared` taking a pre-opened
  `TraceHandle` (channel + worker, opened once) is planned for a future ExecPlan but
  out of scope here.
  Date: 2026-05-13

- Decision: Event ids are a process-local `IORef Word` counter combined with POSIX
  seconds at process start, formatted as 8 hex characters.
  Rationale: The id only needs to correlate `CallStarted` with its matching finish/fail
  within a single process run. Pulling in `uuid` would add a dependency for no gain.
  The trade-off (not unique across separate process runs) is documented.
  Date: 2026-05-13

- Decision: JSON encoding uses Aeson's `TaggedObject` with `tagFieldName = "kind"`,
  `contentsFieldName = "data"`, and snake-case constructor tags (`call_started`,
  `call_finished`, `call_failed`).
  Rationale: A tagged discriminator is the conventional JSONL shape and makes
  `jq 'select(.kind == "call_finished")'` straightforward.
  Date: 2026-05-13

- Decision: `fileSink` opens the file in append mode for each event and closes it
  immediately, rather than holding a long-lived handle.
  Rationale: Crash safety and simplicity beat throughput for trace events. Cost is one
  `open`/`close` syscall per event — microsecond scale, dwarfed by network latency.
  A higher-throughput variant (kept-open handle, flushed on close) can be added later
  without changing the public type.
  Date: 2026-05-13

- Decision: `withTrace` re-throws exceptions after emitting `CallFailed` and draining
  the worker.
  Rationale: Tracing is observation, not error handling. Callers expect `runRequest`
  to throw on failure; `withTrace` must preserve that contract. Draining before
  re-throwing guarantees the failure event is durable in any persistent sink.
  Date: 2026-05-13

- Decision: EP-5 lives entirely in the core `baikai` package. No changes to
  `baikai-claude`, `baikai-openai`, or `baikai-trace-otel`.
  Rationale: Tracing is a horizontal concern wrapping the `Provider` typeclass; it has
  no provider-specific knowledge. EP-6 (`baikai-trace-otel`) will depend on `baikai`
  and supply a `TraceSink`-shaped fold.
  Date: 2026-05-13

- Decision: Target `streamly ^>=0.10` and `streamly-core ^>=0.2`.
  Rationale: The version pair available in the Nix package set for `ghc912`. The fold
  and channel API names referenced in this plan come from these versions. Caveat:
  the streamly API is still maturing; the implementer should check the resolved
  version with `mori registry show streamly --full` and substitute equivalents
  (`Fold.foldMapM`, `Fold.drainBy`) if a name is not exported.
  Date: 2026-05-13

- Decision: `withTrace`, `runRequestWith`, and `fileSink` keep concrete `IO` signatures; `TraceSink` keeps `Fold IO TraceEvent ()`.
  Rationale: Bracket-style functions and the worker fold cannot be polymorphic over `MonadIO m =>` because they rely on `bracket` over `IO` and `forkIO`. `MonadUnliftIO` would seemingly fit but is not implemented for `effectful`'s `Eff es`, so a polymorphic signature would be a false promise. A future `baikai-effectful` package will provide `withTraceEff :: TraceSink -> p -> Request -> Eff es Response` using effectful's native concurrency primitives. The decision matches the project-wide MonadIO cascade recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.
  Date: 2026-05-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/baikai` is four sibling Cabal
packages: `baikai` (core), `baikai-claude` (Claude API adapter), `baikai-openai`
(OpenAI Codex CLI adapter), and `baikai-trace-otel` (the EP-6 OpenTelemetry sink).
EP-5 only touches `baikai`; its manifest is `baikai/baikai.cabal` and sources live at
`baikai/src/`. The compiler is `ghc912`, default language `GHC2024`, with default
extensions `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`. EP-1 already added the dependencies `aeson`, `bytestring`,
`containers`, `time`, `text`, `vector`, `scientific`.

This ExecPlan adds three modules under `baikai/src/Baikai/Trace/`:
`Baikai.Trace.Event` (the `TraceEvent` sum type and its `Aeson.Options`),
`Baikai.Trace.Sink` (the `TraceSink` newtype wrapping a `Fold IO TraceEvent ()`, the
four built-in sinks, and `renderHuman`), and `Baikai.Trace` (the `withTrace` /
`runRequestWith` wrappers plus `newEventId` and `summarizePrompt`, re-exporting
`TraceEvent` and `TraceSink`). The split keeps the JSON-instance module separate
from the wrapper module so test code can import only the type and the in-memory sink.

This plan consumes the following types defined by EP-1 (reproduced inline so the plan is
self-contained):

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

data BaikaiError
  = ProviderError !Text
  | RequestInvalid !Text
  | DecodeError !Text
  | ProcessError !Int !Text
  deriving (Show)
instance Exception BaikaiError

class Provider p where
  providerName :: p -> Text
  runRequest :: p -> Request -> IO Response
```

**Why streamly folds matter here.** A `Fold m a b` is a left-fold over a stream of
`a` in monad `m` producing `b`. For this plan `b = ()`: a sink consumes events for
their side effects. Folds compose: `Fold.tee f g` runs both folds on every input
(exactly what `multiSink` needs), `Fold.filter p f` drops inputs not satisfying `p`
(future redaction), `Fold.lmap g f` projects inputs (future enrichment). The relevant
modules are `Streamly.Data.Fold` (`Fold`, `drain`, `drainMapM`, `tee`, `filter`,
`lmap`), `Streamly.Data.Stream` (`Stream`, `fold`), and `Streamly.Data.Channel`
(`Channel`, `newChannel`, `fromChannel`, `writeChannel`, `closeChannel`). The
mori-managed local copy is at
`/Users/shinzui/Keikaku/hub/haskell/streamly-project/streamly/`; run
`mori registry show streamly --full` and read those modules on disk before settling
on exact import names.

New runtime dependencies on top of EP-1's set: `streamly`, `streamly-core`, and `stm`
(used by the in-memory test sink built from a `TVar [TraceEvent]`). The event-id
counter uses `IORef Word`, so no `random` dependency is added. The four built-in sinks
defined in this plan are `silent`, `stdoutSink`, `fileSink`, and `multiSink`; see
Plan of Work Milestone 2 for the full definitions. The fold-based `TraceSink` shape
means EP-6 (`baikai-trace-otel`) can provide a `TraceSink` whose inner fold batches
events into an OTLP exporter — no glue code is needed in `baikai`.

EP-5's entry points (`withTrace`, `runRequestWith`, `fileSink`, and the `TraceSink`/`Fold IO` shape) are deliberately concrete `IO` rather than polymorphic over `MonadIO m =>` because they are bracket-style or worker-fold shaped and would require `MonadUnliftIO` (which `effectful`'s `Eff es` does not satisfy); a future `baikai-effectful` package will adapt them to `Eff es` using effectful's native concurrency primitives.

## Plan of Work

Four milestones, each leaving the package buildable and independently verifiable.

### Milestone 1 — `Baikai.Trace.Event` types and JSON encoding

Create `baikai/src/Baikai/Trace/Event.hs` containing the `TraceEvent` sum type and its
`FromJSON`/`ToJSON` instances. Expose the module via `baikai.cabal`. Acceptance:
`cabal build all` succeeds; `cabal repl baikai` can evaluate `Aeson.encode (CallStarted ...)`
and produce a single-line JSON object with a `"kind"` discriminator.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Trace.Event
  ( TraceEvent (..)
  , traceEventOptions
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Options (..), SumEncoding (..), defaultOptions)
import Data.Char (toLower)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

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

traceEventOptions :: Options
traceEventOptions = defaultOptions
  { sumEncoding = TaggedObject { tagFieldName = "kind", contentsFieldName = "data" }
  , constructorTagModifier = dropWhile (== '_') . camelToSnake
  , omitNothingFields = True
  }
  where
    camelToSnake :: String -> String
    camelToSnake [] = []
    camelToSnake (c : cs)
      | c `elem` ['A' .. 'Z'] = '_' : toLower c : camelToSnake cs
      | otherwise = c : camelToSnake cs

instance ToJSON TraceEvent where
  toJSON = genericToJSON traceEventOptions
  toEncoding = Aeson.genericToEncoding traceEventOptions

instance FromJSON TraceEvent where
  parseJSON = genericParseJSON traceEventOptions
```

The chosen tag values are `call_started`, `call_finished`, `call_failed`. Examples of
each constructor's JSON serialization:

```json
{"kind":"call_started","eventId":"a1b2c3d4","timestamp":"2026-05-13T18:30:00Z","provider":"anthropic.claude.api","model":"claude-sonnet-4-6","maxTokens":1024,"promptSummary":"Summarize..."}
{"kind":"call_finished","eventId":"a1b2c3d4","timestamp":"2026-05-13T18:30:01Z","provider":"anthropic.claude.api","model":"claude-sonnet-4-6","latencyMs":1234,"inputTokens":120,"outputTokens":87,"usd":0.0042}
{"kind":"call_failed","eventId":"e5f6a7b8","timestamp":"2026-05-13T18:31:05Z","provider":"anthropic.claude.api","model":"claude-opus-4-7","latencyMs":4123,"errorMessage":"HTTP error 429 Too Many Requests"}
```

`omitNothingFields = True` keeps `inputTokens`, `outputTokens`, and `usd` out of the
JSON when `Nothing` (e.g. subscription-based providers that do not report tokens).


### Milestone 2 — `Baikai.Trace.Sink` with four sinks and human renderer

Create `baikai/src/Baikai/Trace/Sink.hs` exporting the `TraceSink` newtype, the four
built-in sinks, and the human renderer. Add to `exposed-modules`. Acceptance: running
`Stream.fold (runSink stdoutSink) (Stream.fromList [someEvent])` prints one line;
`fileSink "/tmp/smoke.jsonl"` similarly produces a one-line file.

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Baikai.Trace.Sink
  ( TraceSink (..)
  , silent
  , stdoutSink
  , fileSink
  , multiSink
  , renderHuman
  ) where

import Baikai.Trace.Event (TraceEvent (..))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (defaultTimeLocale, formatTime)
import Streamly.Data.Fold (Fold)
import Streamly.Data.Fold qualified as Fold
import System.IO (IOMode (AppendMode), withFile)

-- | A trace sink is a streamly fold over 'TraceEvent' values. Folds compose:
-- 'Fold.tee' fans events to two sinks, 'Fold.filter' drops events that fail a
-- predicate, 'Fold.lmap' projects each event before feeding the inner fold.
newtype TraceSink = TraceSink
  { runSink :: Fold IO TraceEvent ()
  }

-- | Consume events without effect. Useful in tests.
silent :: TraceSink
silent = TraceSink Fold.drain

-- | Print each event to stdout using 'renderHuman'.
stdoutSink :: TraceSink
stdoutSink = TraceSink (Fold.drainMapM (Text.IO.putStrLn . renderHuman))

-- | Append each event as one JSON-encoded line. Open-per-write is
-- intentional: crash safety beats throughput for trace events. A
-- kept-open-handle variant is a future enhancement.
fileSink :: FilePath -> IO TraceSink
fileSink path =
  pure $ TraceSink $ Fold.drainMapM $ \e ->
    withFile path AppendMode $ \h ->
      BSL.hPut h (Aeson.encode e <> "\n")

-- | Fan every event out to every sink in the list. Implemented by folding
-- 'Fold.tee' across the input list; 'Fold.tee' runs both folds on each input.
multiSink :: [TraceSink] -> TraceSink
multiSink sinks =
  TraceSink (foldr (\(TraceSink f) acc -> fmap (const ()) (Fold.tee f acc)) Fold.drain sinks)

-- | Format an event as a single human-readable line.
renderHuman :: TraceEvent -> Text
renderHuman = \case
  CallStarted { timestamp, provider, model, maxTokens, promptSummary } ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]", provider, model, "START"
      , "max=" <> tshow maxTokens, Text.take 80 promptSummary
      ]
  CallFinished { timestamp, provider, model, latencyMs, inputTokens, outputTokens, usd } ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]", provider, model, "->", tshow latencyMs <> "ms"
      , maybe "" (\n -> "in=" <> tshow n) inputTokens
      , maybe "" (\n -> "out=" <> tshow n) outputTokens
      , maybe "(no-cost)" (\r -> "$" <> tshow (fromRational r :: Double)) usd
      ]
  CallFailed { timestamp, provider, model, latencyMs, errorMessage } ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]", provider, model
      , "FAILED", tshow latencyMs <> "ms:", errorMessage
      ]
  where
    tshow x = Text.pack (show x)
    fmtTime t = Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t)
```

Examples of the human one-line output:

```text
[2026-05-13T18:30:00Z] anthropic.claude.api claude-sonnet-4-6 START max=1024 Summarize the article
[2026-05-13T18:30:01Z] anthropic.claude.api claude-sonnet-4-6 -> 1234ms in=120 out=87 $0.0042
[2026-05-13T18:31:02Z] openai.codex.cli o3 -> 3500ms (no-cost)
[2026-05-13T18:32:45Z] anthropic.claude.api claude-opus-4-7 FAILED 4123ms: HTTP error 429 Too Many Requests
```


### Milestone 3 — `Baikai.Trace.withTrace` and helpers

Create `baikai/src/Baikai/Trace.hs` with `withTrace`, the helpers `newEventId` and
`summarizePrompt`, and the optional `runRequestWith` convenience; add to
`exposed-modules`. The wrapper opens a `streamly` channel, forks a worker draining
the sink's fold, emits `CallStarted`, calls `runRequest` inside `try`, emits
`CallFinished` or `CallFailed`, closes the channel, waits for the worker, then
returns or re-throws. Acceptance: a stub `Provider` wrapped in `withTrace silent`
returns a `Response`; in-memory-sink tests confirm one `CallStarted` followed by one
`CallFinished` (or `CallFailed`).

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Baikai.Trace
  ( -- Re-exports
    TraceEvent (..)
  , TraceSink (..)
    -- Wrapper
  , withTrace
  , runRequestWith
    -- Helpers (exported so tests can use them)
  , newEventId
  , summarizePrompt
  ) where

import Baikai.Core
  ( BaikaiError (..)
  , CallLogConfig (..)
  , CallLogEntry (..)
  , Cost (..)
  , Message (..)
  , MessageRole (..)
  , Model (..)
  , Provider (..)
  , Request (..)
  , Response (..)
  , Usage (..)
  , appendEntry
  )
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import Streamly.Data.Channel qualified as Channel
import Streamly.Data.Stream qualified as Stream
import System.IO.Unsafe (unsafePerformIO)

-- | Wrap a provider call with structured tracing. Opens a streamly channel,
-- forks a worker that drains events through the sink's fold, emits a
-- 'CallStarted', invokes the provider, emits either 'CallFinished' or
-- 'CallFailed', closes the channel, waits for the worker, then returns the
-- response or re-throws the original exception.
withTrace :: Provider p => TraceSink -> p -> Request -> IO Response
withTrace (TraceSink sinkFold) provider req = do
  chan <- Channel.newChannel
  workerDone <- newEmptyMVar
  _tid <- forkIO $ do
    Stream.fold sinkFold (Channel.fromChannel chan)
    putMVar workerDone ()

  eid <- newEventId
  start <- getCurrentTime
  Channel.writeChannel chan CallStarted
    { eventId = eid
    , timestamp = start
    , provider = providerName provider
    , model = unModel (model (req :: Request))
    , maxTokens = maxTokens (req :: Request)
    , promptSummary = summarizePrompt req
    }

  result <- try (runRequest provider req)
  end <- getCurrentTime
  let latency :: Integer
      latency = round (1000 * diffUTCTime end start)
  case result of
    Right resp -> do
      Channel.writeChannel chan CallFinished
        { eventId = eid
        , timestamp = end
        , provider = providerName provider
        , model = unModel (model (resp :: Response))
        , latencyMs = latency
        , inputTokens = fmap inputTokens (usage (resp :: Response))
        , outputTokens = fmap outputTokens (usage (resp :: Response))
        , usd = fmap usd (cost (resp :: Response))
        }
      Channel.closeChannel chan
      takeMVar workerDone
      pure resp
    Left (e :: SomeException) -> do
      Channel.writeChannel chan CallFailed
        { eventId = eid
        , timestamp = end
        , provider = providerName provider
        , model = unModel (model (req :: Request))
        , latencyMs = latency
        , errorMessage = Text.pack (displayException e)
        }
      Channel.closeChannel chan
      takeMVar workerDone
      throwIO e

-- | Convenience: combine EP-5 tracing with EP-4 call-log persistence in one call.
runRequestWith
  :: Provider p
  => TraceSink
  -> CallLogConfig
  -> p
  -> Request
  -> IO Response
runRequestWith sink logCfg p req = do
  resp <- withTrace sink p req
  now <- getCurrentTime
  appendEntry logCfg CallLogEntry
    { entryTimestamp = now
    , entryProvider = providerName p
    , entryModel = unModel (model (resp :: Response))
    , entryLatencyMs = latencyMs (resp :: Response)
    , entryInputTokens = fmap inputTokens (usage (resp :: Response))
    , entryOutputTokens = fmap outputTokens (usage (resp :: Response))
    , entryUsd = fmap usd (cost (resp :: Response))
    }
  pure resp

-- | Return a short hex id unique within the current process. Combines the
-- low 16 bits of POSIX seconds at process start with a monotonically
-- increasing counter, formatted as 8 hex chars.
newEventId :: IO Text
newEventId = do
  n <- atomicModifyIORef' eventCounter (\k -> (k + 1, k))
  base <- eventBase
  pure (Text.pack (pad8 (showHex (base + fromIntegral n) "")))
  where
    pad8 s = replicate (8 - length s) '0' <> take 8 s

eventCounter :: IORef Word
eventCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE eventCounter #-}

eventBase :: IO Word
eventBase = do
  t <- getPOSIXTime
  pure (fromIntegral (floor t :: Integer) * 0x10000)

-- | Extract the first 200 characters of the most recent user message in the
-- request. Returns "" if there is no user message.
summarizePrompt :: Request -> Text
summarizePrompt req =
  case reverse (filter ((== User) . role) (messages (req :: Request))) of
    (m : _) -> Text.take 200 (content (m :: Message))
    []      -> Text.empty
```

The field-access pattern `unModel (model (req :: Request))` works under
`DuplicateRecordFields`; with `OverloadedLabels` + `lens` it becomes `req ^. #model`.
The channel API may live under `Streamly.Internal.Data.Channel`; locate the exports
via `mori registry docs streamly` and adjust imports accordingly. An equivalent
`Streamly.Data.IORef` plus forked `Stream.unfoldrM` consumer is acceptable if the
channel API differs significantly.


### Milestone 4 — Tests

Add tests at `baikai/test/Trace/TraceSpec.hs` exercising three scenarios. Acceptance:
`cabal test all` passes all three.

Test 1 — `silent` sink does not panic. A stub returning a known `Response` wrapped
in `withTrace silent` returns that response; a second stub that throws
`ProviderError "boom"` is wrapped and called inside `try`, and the caught exception
equals `ProviderError "boom"`.

Test 2 — in-memory sink records `CallStarted` then `CallFinished`. A `TVar [TraceEvent]`
adapted to a `Fold IO TraceEvent ()` (step prepends). Wrap a successful stub; call;
reverse the list; assert length 2, `[CallStarted, CallFinished]`, same `eventId`, and
matching provider/model.

Test 3 — in-memory sink records `CallStarted` then `CallFailed`. Same setup, but the
stub throws `ProviderError "stub-failure"`. Wrap in `try`; assert re-thrown; assert
events are `[CallStarted, CallFailed]` with matching `eventId` and `errorMessage`
containing "stub-failure".

Sketch of the in-memory sink (the fold is built by lifting a `TVar`-mutating step
into `Fold.foldlM'`):

```haskell
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Streamly.Data.Fold qualified as Fold
import Baikai.Trace.Event (TraceEvent)
import Baikai.Trace.Sink (TraceSink (..))

memorySink :: IO (TVar [TraceEvent], TraceSink)
memorySink = do
  ref <- newTVarIO []
  let step () e = atomically (modifyTVar' ref (e :))
      sink = TraceSink (Fold.foldlM' step (pure ()))
  pure (ref, sink)
```

After the call returns (or `try` catches), the test reads `readTVarIO ref` and
asserts on the reversed list. Because `withTrace` waits for the worker to drain
before returning, the list is guaranteed to contain both events by the time the
assertion runs — no `threadDelay` is needed.

## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/baikai`. Enter the development
shell with `nix develop`, then after each milestone:

```bash
cabal build all
cabal test all
```

Expected tail of a clean build shows the three new modules compiling:

```text
[ 7 of 12] Compiling Baikai.Trace.Event   ( src/Baikai/Trace/Event.hs, ... )
[ 8 of 12] Compiling Baikai.Trace.Sink    ( src/Baikai/Trace/Sink.hs, ... )
[ 9 of 12] Compiling Baikai.Trace         ( src/Baikai/Trace.hs, ... )
```

Drop into a REPL on the core package and exercise the wrapper interactively with a
minimal stub provider:

```bash
cabal repl baikai
```

```text
ghci> :set -XOverloadedStrings -XDuplicateRecordFields
ghci> import Baikai.Core
ghci> import Baikai.Trace
ghci> import Baikai.Trace.Sink
ghci> import Data.Ratio ((%))
ghci> :{
ghci| data Stub = Stub
ghci| instance Provider Stub where
ghci|   providerName _ = "stub.demo"
ghci|   runRequest _ _ = pure Response
ghci|     { content = "ok", model = Model "stub-1"
ghci|     , usage = Just (Usage 10 5 Nothing Nothing)
ghci|     , cost = Just (Cost (1 % 1000) (CostBreakdown 0 0 0))
ghci|     , provider = "stub.demo", latencyMs = 42 }
ghci| :}
ghci> let req = Request { model = Model "stub-1", maxTokens = 16, messages = [Message User "hello"], system = Nothing }
ghci> _ <- withTrace stdoutSink Stub req
[2026-05-13T18:30:00Z] stub.demo stub-1 START max=16 hello
[2026-05-13T18:30:00Z] stub.demo stub-1 -> 0ms in=10 out=5 $1.0e-3
ghci> sink <- fileSink "/tmp/baikai-trace-demo.jsonl"
ghci> _ <- withTrace sink Stub req
ghci> :q
```

Inspect the file the second session wrote:

```bash
cat /tmp/baikai-trace-demo.jsonl
```

Expected output (two lines, one per event):

```text
{"kind":"call_started","eventId":"02b3a40000","timestamp":"2026-05-13T18:30:00Z","provider":"stub.demo","model":"stub-1","maxTokens":16,"promptSummary":"hello"}
{"kind":"call_finished","eventId":"02b3a40000","timestamp":"2026-05-13T18:30:00Z","provider":"stub.demo","model":"stub-1","latencyMs":0,"inputTokens":10,"outputTokens":5,"usd":0.001}
```

## Validation and Acceptance

Acceptance criteria, stated as observable behavior:

1. Wrapping any `Provider`-typed value `p` in `withTrace stdoutSink p` produces, per
   call, exactly one `CallStarted` line followed by either one `CallFinished` (on
   success) or one `CallFailed` (on exception) line on stdout, in that order.
   `withTrace` returns the `Response` on success and re-throws the original exception
   on failure, after the worker has drained the end-event.
2. Wrapping the same `p` in `withTrace =<< fileSink path` appends, for each call,
   exactly one or two JSONL records to `path`. Each record is on its own line and is
   parseable by `aeson`'s `eitherDecode`. The `kind` field is one of `call_started`,
   `call_finished`, `call_failed`.
3. Wrapping `p` in `withTrace silent p` produces no observable side effect from the
   sink and returns (or re-throws) exactly what `runRequest p req` would have produced
   or thrown.
4. The unit tests in `baikai/test/Trace/TraceSpec.hs` all pass.

The exact command to verify the unit tests is:

```bash
cabal test all
```

Expected transcript:

```text
Running 1 test suites...
Test suite baikai-test: RUNNING...
Trace
  silent sink does not panic on success or failure: OK
  memory sink records CallStarted then CallFinished in order: OK
  memory sink records CallStarted then CallFailed on exception: OK
All 3 tests passed (0.04s)
Test suite baikai-test: PASS
```

To verify the JSONL output beyond `cabal test`, the operator runs the REPL session
shown in Concrete Steps and `cat`s the file; a sample showing one successful and one
failed call:

```text
{"kind":"call_started","eventId":"02b3a40000","timestamp":"2026-05-13T18:30:00Z","provider":"anthropic.claude.api","model":"claude-sonnet-4-6","maxTokens":1024,"promptSummary":"Summarize the article..."}
{"kind":"call_finished","eventId":"02b3a40000","timestamp":"2026-05-13T18:30:01Z","provider":"anthropic.claude.api","model":"claude-sonnet-4-6","latencyMs":1234,"inputTokens":120,"outputTokens":87,"usd":0.0042}
{"kind":"call_failed","eventId":"02b3a40001","timestamp":"2026-05-13T18:31:04Z","provider":"anthropic.claude.api","model":"claude-opus-4-7","latencyMs":4123,"errorMessage":"HTTP error 429 Too Many Requests"}
```

Passing tests demonstrate end-to-end behavior — the in-memory sink observes actual
`TraceEvent` values traversing the channel and fold. The REPL session covers the real
I/O sinks (stdout and file).

## Idempotence and Recovery

Re-running `cabal build all` and `cabal test all` is safe and has no side effects
beyond Cabal's build cache. The trace tests use either `silent` or an in-memory `TVar`
sink, so they touch no filesystem state and are repeatable without cleanup.

`fileSink path` opens the file in append mode on each emit (creating it if missing,
appending if present); re-running the REPL demo grows the file. To start clean, run
`rm -f calls.jsonl` first.

`withTrace` guarantees the worker drains every event before returning: both the
success and failure paths close the channel and `takeMVar workerDone` before returning
or re-throwing. Concurrent calls each get their own worker; the file is opened and
closed per event so single lines are atomic at the kernel level. Records from
concurrent calls can interleave at line boundaries
(`A.start, B.start, B.finish, A.finish`), but each line is intact and the `eventId`
field lets downstream consumers correlate start with finish or fail.

If a sink throws (e.g. `fileSink` on disk full), the exception propagates out of the
fold and the worker. The implementer must wrap the worker body in `try` and put
`workerDone` from a `finally` to avoid blocking `withTrace` forever; the sink
exception is carried in an `MVar (Maybe SomeException)` that `withTrace` checks and
re-throws. Callers who want best-effort tracing can wrap their sink at the fold
level (`Fold.drainMapM $ \e -> void (try @SomeException ...)`); we do not ship a
`bestEffort` combinator because silently swallowing exceptions is the wrong default
for an observability library.

## Interfaces and Dependencies

Runtime library dependencies (added to `library` `build-depends` in
`baikai/baikai.cabal`):

- `aeson`, `bytestring`, `time`, `text` — already present from EP-1.
- `streamly ^>=0.10` — provides the `Fold`, `Stream`, and `Channel` types. **New.**
- `streamly-core ^>=0.2` — the core fold/stream API. **New.**
- `stm` — `TVar` for the in-memory test sink. **New.**

Verify the resolved versions and API names via
`mori registry show streamly --full` and `mori registry show streamly-core --full`,
and substitute equivalent names (e.g. `Fold.drainBy`, `Fold.teeWith`) where needed.

Test dependencies: if the project already has `tasty`/`tasty-hunit`, reuse them.
Otherwise, the new tests are written as a hand-rolled `main` that exits with
`exitFailure` on assertion failure, requiring no new dependency.

Cabal manifest diff:

```diff
 library
   hs-source-dirs:     src
   exposed-modules:
     Baikai.Core
+    Baikai.Trace
+    Baikai.Trace.Event
+    Baikai.Trace.Sink
   build-depends:
       base
     , aeson
     , bytestring
     , containers
     , scientific
+    , stm
+    , streamly        ^>=0.10
+    , streamly-core   ^>=0.2
     , text
     , time
     , vector
```

Every type and function the public API of EP-5 exports:

- `Baikai.Trace.Event`: `TraceEvent (..)` (constructors `CallStarted`, `CallFinished`,
  `CallFailed`; derives `Generic`, `Show`; JSON via `traceEventOptions`),
  `traceEventOptions :: Aeson.Options`.
- `Baikai.Trace.Sink`: `TraceSink (newtype { runSink :: Fold IO TraceEvent () })`,
  `runSink`, `silent :: TraceSink`, `stdoutSink :: TraceSink`,
  `fileSink :: FilePath -> IO TraceSink`, `multiSink :: [TraceSink] -> TraceSink`,
  `renderHuman :: TraceEvent -> Text`.
- `Baikai.Trace`:
  `withTrace :: Provider p => TraceSink -> p -> Request -> IO Response`,
  `runRequestWith :: Provider p => TraceSink -> CallLogConfig -> p -> Request -> IO Response`,
  `newEventId :: IO Text`, `summarizePrompt :: Request -> Text`. Re-exports
  `TraceEvent (..)` and `TraceSink (..)`.

EP-5 does not modify or re-export anything from `Baikai.Core` beyond what is already
public in EP-1 and EP-4. Composition with EP-4's call log is opt-in via
`runRequestWith`. The fold-based `TraceSink` is the integration point for EP-6
(`baikai-trace-otel`), which will export an `otelSink :: OtelConfig -> IO TraceSink`
that composes with the built-in sinks via `multiSink` like any other `TraceSink`.

## Revisions

- 2026-05-13: Reconciled EP-5 with the project-wide MonadIO cascade. EP-5's signatures are unchanged because `withTrace`, `runRequestWith`, `fileSink`, and the `TraceSink`/`Fold IO` shape all live in bracket/worker territory and cannot be polymorphic without `MonadUnliftIO` (which `effectful` does not satisfy). Added a Decision Log entry capturing this and a Context note pointing at the future `baikai-effectful` wrapper. Driver: the MonadIO decision recorded in `docs/masterplans/1-ai-provider-abstraction-library.md`'s Decision Log on the same date.
