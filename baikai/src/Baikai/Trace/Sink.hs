{-# LANGUAGE LambdaCase #-}

-- | The 'TraceSink' newtype and four built-in sinks.
--
-- A 'TraceSink' is a thin wrapper around a streamly @'Fold' IO 'TraceEvent' ()@.
-- The fold shape is deliberate: 'Streamly.Data.Fold' exports composition
-- combinators like 'Fold.tee' (fan to two folds), 'Fold.filter' (drop inputs
-- failing a predicate), and 'Fold.lmap' (project each input), so future
-- sinks (OpenTelemetry, redaction, projection) plug in without an adapter.
--
-- 'multiSink' is the one place that does /not/ compose with 'Fold.tee':
-- 'Fold.tee' runs one member then the other and lets either's exception
-- escape, so a single throwing member stopped delivery to its siblings
-- and skipped their end-of-stream actions. Each member now runs on its
-- own drain thread; see 'multiSink'.
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
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar)
import Control.Exception (Exception (..), SomeException, throwIO, try)
import Control.Monad (forM_, unless)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (defaultTimeLocale, formatTime)
import Streamly.Data.Fold (Fold)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
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

-- | Fan every event out to every sink in the list.
--
-- Each member runs on its own drain thread behind its own unbounded
-- channel, so a member that throws or blocks cannot stop delivery to
-- the others or skip their end-of-stream action. This fold's step never
-- blocks. Its final action sends every member the sentinel, waits for
-- every member, and throws one 'TraceSinkFailure' naming each failed
-- member by zero-based index when any failed — which the trace worker
-- records like any other sink failure.
--
-- The wait for a member is unbounded here; "Baikai.Trace" bounds the
-- whole drain, so a member that blocks forever costs the call the drain
-- bound and no more. One consequence is accepted: while such a member
-- is blocked the aggregate is never thrown, so a /throwing/ sibling's
-- message does not reach stderr in that combination. The stall line
-- names the actionable fact, and the sibling's events were delivered
-- regardless.
multiSink :: [TraceSink] -> TraceSink
multiSink sinks =
  TraceSink (Fold.rmapM finish (Fold.foldlM' deliver start))
  where
    start :: IO [Member]
    start = mapM startMember sinks

    deliver :: [Member] -> TraceEvent -> IO [Member]
    deliver members e = do
      forM_ members $ \member -> writeChan (chan member) (Just e)
      pure members

    finish :: [Member] -> IO ()
    finish members = do
      forM_ members $ \member -> writeChan (chan member) Nothing
      outcomes <- mapM (readMVar . outcome) members
      let failures = [(i, e) | (i, Just e) <- zip [0 :: Int ..] outcomes]
      unless (null failures) $
        throwIO (TraceSinkFailure (length members) failures)

-- | One member of a 'multiSink': the channel it is fed through and the
-- slot its drain thread fills with the outcome of its fold.
data Member = Member
  { chan :: !(Chan (Maybe TraceEvent)),
    outcome :: !(MVar (Maybe SomeException))
  }

-- | Fork one member's drain thread. The 'try' is @SomeException@ for
-- the same reason the trace worker's is: nothing throws /to/ this
-- thread, so the catch cannot swallow a cancellation aimed at anyone,
-- and a member abandoned by a stalled drain is reaped with
-- 'Control.Exception.BlockedIndefinitelyOnMVar', which is worth
-- recording rather than printing through the runtime.
startMember :: TraceSink -> IO Member
startMember (TraceSink f) = do
  c <- newChan
  o <- newEmptyMVar
  _ <- forkIO $ do
    let step () = fmap (fmap (\e -> (e, ()))) (readChan c)
    r <- try (Stream.fold f (Stream.unfoldrM step ())) :: IO (Either SomeException ())
    putMVar o (either Just (const Nothing) r)
  pure Member {chan = c, outcome = o}

-- | One or more members of a 'multiSink' failed. Not exported: the
-- strict-mode error and the stderr line both render its text, and an
-- exported type is a name the surface freeze would have to keep.
data TraceSinkFailure = TraceSinkFailure Int [(Int, SomeException)]
  deriving stock (Show)

instance Exception TraceSinkFailure where
  displayException (TraceSinkFailure total failures) =
    show (length failures)
      <> " of "
      <> show total
      <> " member sinks failed: "
      <> intercalate
        "; "
        ["member " <> show i <> ": " <> displayException e | (i, e) <- failures]

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
