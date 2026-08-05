{-# LANGUAGE LambdaCase #-}

-- | The 'TraceSink' newtype and four built-in sinks.
--
-- A 'TraceSink' is a thin wrapper around a streamly @'Fold' IO 'TraceEvent' ()@.
-- The fold shape is deliberate: 'Streamly.Data.Fold' exports composition
-- combinators like 'Fold.tee' (fan to two folds), 'Fold.filter' (drop inputs
-- failing a predicate), and 'Fold.lmap' (project each input), so future
-- sinks (OpenTelemetry, redaction, projection) plug in without an adapter.
module Baikai.Trace.Sink
  ( TraceSink (..),
    silent,
    stdoutSink,
    fileSink,
    multiSink,
    renderHuman,
  )
where

import Baikai.Evidence qualified as Evidence
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

-- | A trace sink is a streamly fold over 'TraceEvent' values. Folds
-- compose: 'Fold.tee' fans events to two sinks, 'Fold.filter' drops
-- events that fail a predicate, 'Fold.lmap' projects each event before
-- feeding the inner fold.
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
-- 'Fold.tee' across the input list; 'Fold.tee' runs both folds on each
-- input and returns the pair of their accumulators, which we discard.
multiSink :: [TraceSink] -> TraceSink
multiSink sinks =
  TraceSink (foldr step Fold.drain sinks)
  where
    step (TraceSink f) acc = fmap (const ()) (Fold.tee f acc)

-- | Format an event as a single human-readable line.
renderHuman :: TraceEvent -> Text
renderHuman = \case
  CallStarted {timestamp, provider, model, maxTokens, promptSummary} ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]",
        provider,
        model,
        "START",
        "max=" <> tshow maxTokens,
        Text.take 80 promptSummary
      ]
  CallFinished {timestamp, provider, model, latencyMs, inputTokens, outputTokens, usd} ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]",
        provider,
        model,
        "->",
        tshow latencyMs <> "ms",
        maybe "" (\n -> "in=" <> tshow n) inputTokens,
        maybe "" (\n -> "out=" <> tshow n) outputTokens,
        maybe "(no-cost)" (\s -> "$" <> tshow s) usd
      ]
  CallFailed {timestamp, provider, model, latencyMs, errorMessage} ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]",
        provider,
        model,
        "FAILED",
        tshow latencyMs <> "ms:",
        errorMessage
      ]
  -- One line, and deliberately not the whole record. A human-readable
  -- sink is for watching calls go by; an evidence record is several
  -- hundred bytes of structured detail meant to be read out of
  -- 'fileSink' output by a machine. What belongs on a terminal is the
  -- fact that evidence exists, which run and call it names, and how
  -- much it proves.
  CallEvidence {timestamp, provider, model, evidence} ->
    Text.unwords
      [ "[" <> fmtTime timestamp <> "]",
        provider,
        model,
        "EVIDENCE",
        evidenceSummary evidence
      ]
  where
    tshow :: (Show a) => a -> Text
    tshow x = Text.pack (show x)
    fmtTime t = Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t)

-- | Read through a record pattern rather than bare selectors:
-- 'Evidence.ModelCallEvidence' and 'Evidence.EvidenceRequest' both
-- carry @runId@, so under @DuplicateRecordFields@ a bare
-- @Evidence.runId ev@ is an ambiguous occurrence.
evidenceSummary :: Evidence.ModelCallEvidence -> Text
evidenceSummary
  Evidence.ModelCallEvidence {Evidence.runId, Evidence.callId, Evidence.strength} =
    Text.unwords
      [ "run=" <> runId,
        "call=" <> callId,
        "strength=" <> Text.pack (show strength)
      ]
