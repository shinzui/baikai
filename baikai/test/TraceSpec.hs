-- This module deliberately exercises 'newEventId', which is deprecated
-- in favour of 'Baikai.Evidence.newCallId'. The alias is still part of
-- the public surface, so it keeps a test; suppressing the warning here
-- is narrower than dropping the coverage.
{-# OPTIONS_GHC -Wno-deprecations #-}

module TraceSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), emptyContext)
import Baikai.Error (BaikaiError, ErrorCategory (..), providerError)
import Baikai.Evidence
  ( ModelCallEvidence,
    TransportKind (..),
    evidenceRequest,
    noThinkingRequested,
  )
import Baikai.Evidence qualified as Ev
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..), user)
import Baikai.Model (Model (..), emptyModel)
import Baikai.Options (Options, emptyOptions)
import Baikai.Prelude
import Baikai.Provider (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..), responseError)
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Stream.Event (AssistantMessageEvent (..))
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Baikai.Trace (newEventId, withTrace, withTraceStream)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..), multiSink, silent)
import Baikai.Usage (Usage, zeroUsage)
import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (AsyncException (ThreadKilled), SomeException, throwIO, try)
import Control.Monad (forM_, replicateM)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Either (isLeft)
import Data.List (findIndex)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as V
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Trace"
    [ silentTest,
      memoryFinishTest,
      memoryFailTest,
      throwingSinkTest,
      blockingSinkTest,
      blockingSinkStrictTest,
      multiSinkThrowingMemberTest,
      multiSinkBlockingMemberTest,
      multiSinkStrictNamesMemberTest,
      terminalPathAtomicityTest,
      throwToAroundTerminalTest,
      eventIdUniquenessTest,
      earlyAbortTest,
      fidelityTest,
      evidenceTests,
      requestedLevelTests,
      encodingTests
    ]

-- | Each test uses its own private 'Api' tag so tasty's parallel
-- test scheduler cannot race the (process-global) registry between
-- tests.
stubModel :: Api -> Model
stubModel a =
  emptyModel
    & #modelId
    .~ "stub-1"
    & #api
    .~ a
    & #provider
    .~ "stub.trace"
    & #maxOutputTokens
    .~ 16

stubContext :: Context
stubContext = emptyContext & #messages .~ V.fromList [user "hello"]

stubOptions :: Options
stubOptions = emptyOptions & #maxTokens .~ Just 16

stubResponse :: Api -> Response
stubResponse a =
  Response
    { message =
        AssistantPayload
          { content = V.singleton (AssistantText (TextContent "hi")),
            usage = zeroUsage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = Just (read "2026-05-14 00:00:00 UTC")
          },
      model = stubModel a,
      api = a,
      provider = "stub.trace",
      responseId = Nothing,
      latencyMs = 0,
      errorInfo = Nothing,
      evidence = Nothing
    }

registerOk :: Api -> IO ()
registerOk a =
  let handler _m _ctx _opts = pure (stubResponse a)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

registerFail :: Api -> BaikaiError -> IO ()
registerFail a e =
  let handler _m _ctx _opts = throwIO e
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

memorySink :: IO (TVar [TraceEvent], TraceSink)
memorySink = do
  ref <- newTVarIO []
  let step () e = atomically (modifyTVar' ref (e :))
      sink = TraceSink (Fold.foldlM' step (pure ()))
  pure (ref, sink)

silentTest :: TestTree
silentTest =
  testGroup
    "silent sink"
    [ testCase "returns the response on success" $ do
        let a = Custom "baikai-trace-silent-ok"
        registerOk a
        _ <- withTrace silent (stubModel a) stubContext stubOptions
        pure (),
      testCase "encodes failure as ErrorReason in the response" $ do
        let a = Custom "baikai-trace-silent-fail"
        registerFail a (providerError "boom")
        resp <- withTrace silent (stubModel a) stubContext stubOptions
        let AssistantPayload {stopReason = sr, errorMessage = em} = resp ^. #message
        sr @?= ErrorReason
        assertBool
          ("expected errorMessage to mention boom, got: " <> show em)
          (maybe False ("boom" `Text.isInfixOf`) em)
    ]

memoryFinishTest :: TestTree
memoryFinishTest =
  testCase "memory sink records CallStarted then CallFinished" $ do
    let a = Custom "baikai-trace-memory-ok"
    registerOk a
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext stubOptions
    rev <- readTVarIO ref
    let events = reverse rev
    length events @?= 2
    case events of
      [s@CallStarted {}, f@CallFinished {}] -> do
        (s ^. #eventId :: Text) @?= (f ^. #eventId :: Text)
        (s ^. #provider :: Text) @?= "stub.trace"
        (f ^. #provider :: Text) @?= "stub.trace"
        (s ^. #model :: Text) @?= "stub-1"
        (f ^. #model :: Text) @?= "stub-1"
      _ -> assertFailure ("unexpected event sequence: " <> show events)

memoryFailTest :: TestTree
memoryFailTest =
  testCase "memory sink records CallStarted then CallFailed on stream error" $ do
    let a = Custom "baikai-trace-memory-fail"
    registerFail a (providerError "stub-failure")
    (ref, sink) <- memorySink
    resp <- withTrace sink (stubModel a) stubContext stubOptions
    -- The producer-side failure surfaces as an ErrorReason on the
    -- response (no throw) and as CallFailed on the trace sink.
    let AssistantPayload {stopReason = sr} = resp ^. #message
    sr @?= ErrorReason
    rev <- readTVarIO ref
    let events = reverse rev
    length events @?= 2
    case events of
      [s@CallStarted {}, f@CallFailed {errorMessage = msg}] -> do
        (s ^. #eventId :: Text) @?= (f ^. #eventId :: Text)
        assertBool
          ("expected error to mention stub-failure, got: " <> show msg)
          ("stub-failure" `Text.isInfixOf` msg)
      _ -> assertFailure ("unexpected event sequence: " <> show events)

throwingSink :: TraceSink
throwingSink =
  TraceSink (Fold.drainMapM (\_ -> throwIO (providerError "sink exploded")))

throwingSinkTest :: TestTree
throwingSinkTest =
  testCase "a throwing sink cannot hang withTrace" $ do
    let a = Custom "baikai-trace-throwing-sink"
    registerOk a
    result <- timeout 5000000 (withTrace throwingSink (stubModel a) stubContext stubOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a throwing sink"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= Stop

-- | A sink that never returns from its first step until released.
blockingSink :: IO (MVar (), TraceSink)
blockingSink = do
  release <- newEmptyMVar
  pure (release, TraceSink (Fold.drainMapM (\_ -> readMVar release)))

-- | Unfixed, 'finalizeTrace' blocked on the worker forever and the
-- guard below reported the hang. The bound turns a pathological sink
-- into about one second and a stderr line.
blockingSinkTest :: TestTree
blockingSinkTest =
  testCase "a sink that blocks forever cannot hold withTrace past the drain bound" $ do
    let a = Custom "baikai-trace-blocking-sink"
    registerOk a
    (release, sink) <- blockingSink
    result <- timeout 2000000 (withTrace sink (stubModel a) stubContext stubOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a blocking sink"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= Stop
    putMVar release ()

-- | A record whose delivery was never confirmed is not one a strict
-- caller can account for, so the stall fails the call through the same
-- path a throwing sink does.
blockingSinkStrictTest :: TestTree
blockingSinkStrictTest =
  testCase "a strict call whose sink never confirms delivery fails" $ do
    let a = Custom "baikai-trace-blocking-sink-strict"
    -- The evidence-building fixture, so the sink is the only reason
    -- this call can fail.
    registerOkWithEvidence a
    (release, sink) <- blockingSink
    result <- timeout 2000000 (withTrace sink (stubModel a) stubContext strictOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a blocking sink"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= ErrorReason
        case responseError resp of
          Nothing -> assertFailure "expected the stall to reach the response"
          Just be ->
            assertBool
              ("the error names the stall: " <> Text.unpack (be ^. #message))
              ("did not confirm delivery" `Text.isInfixOf` (be ^. #message))
    putMVar release ()

-- | Under 'Fold.tee' the throwing member's exception stopped delivery
-- to the sibling for the rest of the call and skipped its end-of-stream
-- action, so this sibling was empty.
multiSinkThrowingMemberTest :: TestTree
multiSinkThrowingMemberTest =
  testCase "a throwing multiSink member does not starve its sibling" $ do
    let a = Custom "baikai-trace-multisink-throwing"
    registerOk a
    (ref, memory) <- memorySink
    result <-
      timeout
        5000000
        (withTrace (multiSink [throwingSink, memory]) (stubModel a) stubContext stubOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a throwing multiSink member"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= Stop
    events <- reverse <$> readTVarIO ref
    case events of
      [CallStarted {}, CallFinished {}] -> pure ()
      other -> assertFailure ("the sibling missed events: " <> show other)

multiSinkBlockingMemberTest :: TestTree
multiSinkBlockingMemberTest =
  testCase "a blocking multiSink member does not starve its sibling" $ do
    let a = Custom "baikai-trace-multisink-blocking"
    registerOk a
    (release, blocking) <- blockingSink
    (ref, memory) <- memorySink
    result <-
      timeout
        2000000
        (withTrace (multiSink [blocking, memory]) (stubModel a) stubContext stubOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a blocking multiSink member"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= Stop
    events <- reverse <$> readTVarIO ref
    case events of
      [CallStarted {}, CallFinished {}] -> pure ()
      other -> assertFailure ("the sibling missed events: " <> show other)
    putMVar release ()

-- | The aggregate failure has to say /which/ member failed, or an
-- operator with three sinks learns only that tracing broke.
multiSinkStrictNamesMemberTest :: TestTree
multiSinkStrictNamesMemberTest =
  testCase "a strict call names the multiSink member that failed" $ do
    let a = Custom "baikai-trace-multisink-strict"
    registerOkWithEvidence a
    (_ref, memory) <- memorySink
    result <-
      timeout
        5000000
        (withTrace (multiSink [throwingSink, memory]) (stubModel a) stubContext strictOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a throwing multiSink member"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= ErrorReason
        case responseError resp of
          Nothing -> assertFailure "expected the member failure to reach the response"
          Just be -> do
            let msg = be ^. #message
            assertBool
              ("the error names the member index: " <> Text.unpack msg)
              ("member 0" `Text.isInfixOf` msg)
            assertBool
              ("the error carries the member's own message: " <> Text.unpack msg)
              ("sink exploded" `Text.isInfixOf` msg)

-- | A memory sink that parks on the terminal event until released.
--
-- The park is what makes the atomicity test deterministic: when
-- @parked@ is filled the consumer has already run 'commitTerminal' to
-- completion and is waiting for the worker, which is exactly the moment
-- an asynchronous exception used to leave a half-committed terminal
-- behind.
gatedSink :: IO (TVar [TraceEvent], MVar (), MVar (), TraceSink)
gatedSink = do
  ref <- newTVarIO []
  parked <- newEmptyMVar
  release <- newEmptyMVar
  let step () e = do
        atomically (modifyTVar' ref (e :))
        case e of
          CallFinished {} -> putMVar parked () >> readMVar release
          _ -> pure ()
      sink = TraceSink (Fold.foldlM' step (pure ()))
  pure (ref, parked, release, sink)

-- | Kill the consumer while it waits for a sink that has already taken
-- the terminal. The stream's exception path runs the trace finaliser a
-- second time, and it must find nothing left to do: one evidence
-- record, one terminal, and no synthetic @aborted@ 'CallFailed' on top
-- of the real 'CallFinished'.
terminalPathAtomicityTest :: TestTree
terminalPathAtomicityTest =
  testCase "an async exception on the terminal path leaves one terminal and one evidence" $ do
    let a = Custom "baikai-trace-terminal-atomicity"
    registerOkWithEvidence a
    (ref, parked, release, sink) <- gatedSink
    outcome <- newEmptyMVar
    consumer <- forkIO $ do
      r <- try (withTrace sink (stubModel a) stubContext evidenceOptions)
      putMVar outcome (r :: Either SomeException Response)
    takeMVar parked
    throwTo consumer ThreadKilled
    r <- takeMVar outcome
    assertBool "the consumer was killed" (isLeft r)
    putMVar release ()
    events <- awaitEvents ref 3
    length [e | e@CallEvidence {} <- events] @?= 1
    length [e | e@CallFinished {} <- events] @?= 1
    length [e | e@CallFailed {} <- events] @?= 0

-- | Aim an asynchronous exception at the consumer the instant the
-- evidence event reaches the sink — while the consumer is pushing the
-- terminal and setting the flag. Fifty times, because the window is a
-- few instructions wide and no scheduling hook can hit it
-- deterministically; the plan's widened-window demonstration shows the
-- test detects the defect.
throwToAroundTerminalTest :: TestTree
throwToAroundTerminalTest =
  testCase "fifty exceptions aimed at the terminal push never duplicate terminal or evidence" $
    forM_ [1 .. 50 :: Int] $ \i -> do
      let a = Custom ("baikai-trace-throwto-" <> Text.pack (show i))
      registerOkWithEvidence a
      ref <- newTVarIO []
      consumerVar <- newEmptyMVar
      let step () e = do
            atomically (modifyTVar' ref (e :))
            case e of
              CallEvidence {} -> readMVar consumerVar >>= \tid -> throwTo tid ThreadKilled
              _ -> pure ()
          sink = TraceSink (Fold.foldlM' step (pure ()))
      outcome <- newEmptyMVar
      tid <- forkIO $ do
        r <- try (withTrace sink (stubModel a) stubContext evidenceOptions)
        putMVar outcome (r :: Either SomeException Response)
      putMVar consumerVar tid
      _ <- takeMVar outcome
      _ <- awaitEvents ref 3
      -- Let anything the finaliser might still push arrive before counting.
      threadDelay 200000
      performMajorGC
      settled <- reverse <$> readTVarIO ref
      length [e | e@CallEvidence {} <- settled] @?= 1
      length [e | e@CallFinished {} <- settled] + length [e | e@CallFailed {} <- settled] @?= 1

-- | The length assertion here used to read
-- @assertBool "every id is 16 chars" (all ((== 16) . Text.length) ids)@.
-- It now reads 32, because 'newEventId' delegates to
-- 'Baikai.Evidence.newCallId', which carries 128 bits rather than 64.
-- The widening is the point of the replacement: the old generator
-- packed a process-start /second/ into its high half and so repeated
-- itself across processes started in the same second.
eventIdUniquenessTest :: TestTree
eventIdUniquenessTest =
  testCase "newEventId yields 70000 distinct 32-char ids" $ do
    ids <- replicateM 70000 newEventId
    Set.size (Set.fromList ids) @?= 70000
    assertBool "every id is 32 chars" (all ((== 32) . Text.length) ids)

earlyAbortTest :: TestTree
earlyAbortTest =
  testCase "early abort pushes a synthetic CallFailed" $ do
    let a = Custom "baikai-trace-abort"
    registerOk a
    (ref, sink) <- memorySink
    emitted <-
      Stream.toList
        (Stream.take 1 (withTraceStream sink (stubModel a) stubContext stubOptions))
    length emitted @?= 1
    events <- awaitEvents ref 2
    case events of
      [s@CallStarted {}, f@CallFailed {errorMessage = msg}] -> do
        (s ^. #eventId :: Text) @?= (f ^. #eventId :: Text)
        assertBool
          ("expected abort message, got: " <> show msg)
          ("aborted" `Text.isInfixOf` msg)
      _ -> assertFailure ("unexpected event sequence: " <> show events)

-- The trace finalizer on an abandoned stream runs from streamly's GC hook.
awaitEvents :: TVar [TraceEvent] -> Int -> IO [TraceEvent]
awaitEvents ref n = go (100 :: Int)
  where
    go 0 = do
      evs <- readTVarIO ref
      assertFailure ("timed out waiting for trace events; got: " <> show (reverse evs))
    go k = do
      performMajorGC
      evs <- readTVarIO ref
      if length evs >= n
        then pure (reverse evs)
        else threadDelay 50000 >> go (k - 1)

-- ============================================================
-- Usage and cost fidelity
-- ============================================================

-- | Usage with every disjoint token class populated, so a trace event
-- that drops one is visible rather than merely zero.
richUsage :: Usage
richUsage =
  zeroUsage
    & #inputTokens
    .~ 11
    & #outputTokens
    .~ 7
    & #cacheReadTokens
    .~ 5
    & #cacheWriteTokens
    .~ 3
    & #reasoningTokens
    .~ Just 4
    & #totalTokens
    .~ 26

registerWithUsage :: Api -> Usage -> IO ()
registerWithUsage a u =
  let resp = stubResponse a & #message . #usage .~ u
      handler _m _ctx _opts = pure resp
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

fidelityTest :: TestTree
fidelityTest =
  testGroup
    "CallFinished fidelity"
    [ testCase "carries the full disjoint token breakdown" $ do
        let a = Custom "baikai-trace-usage-fidelity"
        registerWithUsage a richUsage
        (ref, sink) <- memorySink
        _ <- withTrace sink (stubModel a) stubContext stubOptions
        events <- reverse <$> readTVarIO ref
        -- Read through record patterns, not '#field' labels:
        -- generic-lens only resolves a label present on every
        -- constructor of the sum, and these five are on 'CallFinished'
        -- alone.
        case [f | f@CallFinished {} <- events] of
          [ CallFinished
              { inputTokens,
                outputTokens,
                cachedInputTokens,
                cacheWriteTokens,
                reasoningTokens,
                totalTokens
              }
            ] -> do
              inputTokens @?= Just 11
              outputTokens @?= Just 7
              cachedInputTokens @?= Just 5
              cacheWriteTokens @?= Just 3
              reasoningTokens @?= Just 4
              totalTokens @?= Just 26
          other -> assertFailure ("expected one CallFinished, got: " <> show other),
      -- A zero cost used to be suppressed, which made "this call was
      -- free" indistinguishable from "baikai could not price this
      -- call". The CLI providers always price at zero, so that was the
      -- common case rather than a corner.
      testCase "reports a zero cost as zero rather than omitting it" $ do
        let a = Custom "baikai-trace-zero-cost"
        registerOk a
        (ref, sink) <- memorySink
        _ <- withTrace sink (stubModel a) stubContext stubOptions
        events <- reverse <$> readTVarIO ref
        case [f | f@CallFinished {} <- events] of
          [f@CallFinished {usd}] -> do
            usd @?= Just 0
            assertBool
              "usd must be present in the encoded JSON, not dropped by omitNothingFields"
              (KeyMap.member "usd" (asObject (Aeson.toJSON f)))
          other -> assertFailure ("expected one CallFinished, got: " <> show other)
    ]

-- ============================================================
-- Evidence emission
-- ============================================================

-- | The same options every other test in this module uses, plus an
-- evidence request. A call that emits no evidence cannot prove an
-- exactly-once guarantee about evidence, so every emission case below
-- opts in.
evidenceOptions :: Options
evidenceOptions = stubOptions & #evidence .~ Just (evidenceRequest "run-52")

-- | A fixture provider that builds evidence the way a real adapter
-- does: it hands 'Build.minimalEvidence' the envelope it would have
-- sent and attaches the result to its 'Response', which
-- 'liftCompleteToStream' then carries onto the terminal event.
--
-- 'registerOk' deliberately does not, because most of this module's
-- tests are about the trace path rather than the evidence path, and a
-- provider that builds no evidence is the honest model of one that has
-- not been taught to.
registerOkWithEvidence :: Api -> IO ()
registerOkWithEvidence a =
  let handler m _ctx opts = do
        now <- getCurrentTime
        ev <-
          Build.minimalEvidence
            m
            opts
            TransportHttpApi
            noThinkingRequested
            (Aeson.object ["model" Aeson..= (m ^. #modelId :: Text)])
            now
            now
            Ev.CallSucceeded
            Nothing
        pure (stubResponse a & #evidence .~ ev)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ _ -> noThinkingRequested,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

-- | 'registerOk' with an honest describer.
--
-- The other fixtures answer 'noThinkingRequested' whatever the caller
-- set, which is exactly what hid the defect these tests pin: a stub
-- that always says "nothing was asked" cannot tell a path that lost the
-- caller's level from one that kept it.
registerOkHonest :: Api -> IO ()
registerOkHonest a =
  let handler _m _ctx _opts = pure (stubResponse a)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ o -> Build.requestedTranslation o,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

-- | A describer that answers with a wire shape of its own, so a test
-- can tell "the core asked the adapter" from "the core spelled
-- not_translated itself".
registerOkBudgetDescriber :: Api -> IO ()
registerOkBudgetDescriber a =
  let handler _m _ctx _opts = pure (stubResponse a)
      budgetTranslation o =
        Ev.ThinkingTranslation
          { Ev.requested = o ^. #thinking,
            Ev.mode = Ev.ThinkingModeBudget,
            Ev.effortText = Nothing,
            Ev.budgetTokens = Just 1024,
            Ev.wireField = Just "thinking",
            Ev.adjustments = []
          }
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler,
            describeThinking = \_ o -> budgetTranslation o,
            strengthCeiling = Ev.EvidenceRequestedOnly
          }

thinkingOptions :: Options
thinkingOptions = evidenceOptions & #thinking .~ Just ThinkingMax

-- | Read one key out of the encoded @thinking@ object.
thinkingField :: Text -> ModelCallEvidence -> Maybe Value
thinkingField k ev =
  KeyMap.lookup (Key.fromText k) (asObject (maybe Null id (evidenceField "thinking" ev)))

requestedLevelTests :: TestTree
requestedLevelTests =
  testGroup
    "the caller's thinking level on every evidence path"
    [ abortRecordsRequestedLevelTest,
      abortUsesTheAdapterDescriberTest,
      noProviderRecordsRequestedLevelTest,
      throwingHandlerRecordsRequestedLevelTest
    ]

abortRecordsRequestedLevelTest :: TestTree
abortRecordsRequestedLevelTest =
  testCase "an abandoned stream records the level the caller asked for" $ do
    let a = Custom "baikai-trace-abort-thinking"
    registerOkHonest a
    (ref, sink) <- memorySink
    emitted <-
      Stream.toList
        (Stream.take 1 (withTraceStream sink (stubModel a) stubContext thinkingOptions))
    length emitted @?= 1
    events <- awaitEvents ref 3
    ev <- exactlyOneEvidence events
    thinkingField "requested" ev @?= Just (String "max")
    thinkingField "mode" ev @?= Just (String "not_translated")

abortUsesTheAdapterDescriberTest :: TestTree
abortUsesTheAdapterDescriberTest =
  testCase "an abandoned stream asks the registered adapter to describe the translation" $ do
    let a = Custom "baikai-trace-abort-describer"
    registerOkBudgetDescriber a
    (ref, sink) <- memorySink
    emitted <-
      Stream.toList
        (Stream.take 1 (withTraceStream sink (stubModel a) stubContext thinkingOptions))
    length emitted @?= 1
    events <- awaitEvents ref 3
    ev <- exactlyOneEvidence events
    thinkingField "requested" ev @?= Just (String "max")
    -- The proof that the core consulted the adapter rather than
    -- spelling not_translated unconditionally.
    thinkingField "mode" ev @?= Just (String "budget")
    thinkingField "budget_tokens" ev @?= Just (Number 1024)

noProviderRecordsRequestedLevelTest :: TestTree
noProviderRecordsRequestedLevelTest =
  testCase "an unregistered provider records the level the caller asked for" $ do
    let a = Custom "baikai-trace-unregistered-thinking"
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext thinkingOptions
    events <- awaitEvents ref 3
    ev <- exactlyOneEvidence events
    thinkingField "requested" ev @?= Just (String "max")
    thinkingField "mode" ev @?= Just (String "not_translated")

throwingHandlerRecordsRequestedLevelTest :: TestTree
throwingHandlerRecordsRequestedLevelTest =
  testCase "a handler that threw records the level the caller asked for" $ do
    let a = Custom "baikai-trace-throwing-thinking"
    registerFail a (providerError "stub-failure")
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext thinkingOptions
    events <- awaitEvents ref 3
    ev <- exactlyOneEvidence events
    thinkingField "requested" ev @?= Just (String "max")
    thinkingField "mode" ev @?= Just (String "not_translated")
    evidenceField "status" ev @?= Just (String "failed")

evidencesIn :: [TraceEvent] -> [ModelCallEvidence]
evidencesIn events = [ev | CallEvidence {evidence = ev} <- events]

asObject :: Value -> Aeson.Object
asObject = \case
  Object o -> o
  _ -> KeyMap.empty

-- | Read one field out of an encoded evidence record.
--
-- Deliberately through the JSON rather than through a Haskell record
-- pattern: the encoded form is the contract other systems pin against,
-- and it is the thing that must not drift. It also spells fields in
-- snake_case, which a Haskell mirror would silently paper over.
evidenceField :: Text -> ModelCallEvidence -> Maybe Value
evidenceField k ev = KeyMap.lookup (Key.fromText k) (asObject (Aeson.toJSON ev))

evidenceTests :: TestTree
evidenceTests =
  testGroup
    "model-call evidence"
    [ successEvidenceTest,
      failureEvidenceTest,
      abortEvidenceTest,
      noProviderEvidenceTest,
      sinkFailureEvidenceTest,
      strictSinkFailureTest,
      strictSinkFailureIsStillOneTerminalTest,
      optOutSilentTest,
      optOutGoldenTest,
      envelopeNotForcedTest,
      strictNoRecordFailsTest,
      strictNoRecordIsOneTerminalTest,
      strictWithRecordSucceedsTest,
      strictNoRecordErrorPathKeepsProviderErrorTest,
      bestEffortNoRecordStillSucceedsTest
    ]

-- | Assert the shape every record this plan produces must have: the
-- channel works, and nothing was backfilled from the request.
assertMinimalShape :: ModelCallEvidence -> IO ()
assertMinimalShape ev = do
  evidenceField "schema_version" ev @?= Just (String Ev.evidenceSchemaVersion)
  evidenceField "run_id" ev @?= Just (String "run-52")
  evidenceField "requested_model" ev @?= Just (String "stub-1")
  evidenceField "strength" ev @?= Just (String "requested_only")
  evidenceField "observed_model" ev @?= Just (String "unobserved")
  evidenceField "response_id" ev @?= Just (String "unobserved")
  evidenceField "provider_request_id" ev @?= Just (String "unobserved")
  assertDigest "request_commitment" ev
  assertDigest "request_configuration" ev
  where
    assertDigest k e = case evidenceField k e of
      Just (String d) ->
        assertBool
          (Text.unpack k <> " must be a sha256 digest, got: " <> show d)
          ("sha256:" `Text.isPrefixOf` d && Text.length d == 71)
      other -> assertFailure (Text.unpack k <> " missing or not a string: " <> show other)

-- | Exactly one evidence record per call, joined to the rest of the
-- call's lines by the trace @eventId@.
-- | The record must reach the sink while the call is still open there.
--
-- "Baikai.Trace" pushes 'CallEvidence' before the terminal since commit
-- @1717694@, because the OpenTelemetry sink ends and removes its span on
-- the terminal and so could never attach evidence that arrived after it.
-- 'docs\/capabilities\/model-call-evidence.md' claimed an ordering
-- assertion existed; this is it, and every evidence case runs it on its
-- own path — success, failure, abort, unregistered provider.
assertEvidencePrecedesTerminal :: [TraceEvent] -> IO ()
assertEvidencePrecedesTerminal events =
  case (findIndex isEvidence events, findIndex isTerminal events) of
    (Just i, Just j) ->
      assertBool
        ("CallEvidence at " <> show i <> " must precede the terminal at " <> show j)
        (i < j)
    (Just _, Nothing) -> assertFailure "an evidence event without a terminal"
    _ -> assertFailure "no evidence event to order"
  where
    isEvidence = \case CallEvidence {} -> True; _ -> False
    isTerminal = \case
      CallFinished {} -> True
      CallFailed {} -> True
      _ -> False

exactlyOneEvidence :: [TraceEvent] -> IO ModelCallEvidence
exactlyOneEvidence events = case evidencesIn events of
  [ev] -> do
    let ids = Set.fromList [e ^. #eventId :: Text | e <- events]
    Set.size ids @?= 1
    assertMinimalShape ev
    assertEvidencePrecedesTerminal events
    pure ev
  other ->
    assertFailure
      ("expected exactly one CallEvidence, got " <> show (length other) <> ": " <> show events)

successEvidenceTest :: TestTree
successEvidenceTest =
  testCase "a successful call emits one evidence record with status succeeded" $ do
    let a = Custom "baikai-evidence-success"
    registerOkWithEvidence a
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext evidenceOptions
    events <- reverse <$> readTVarIO ref
    ev <- exactlyOneEvidence events
    evidenceField "status" ev @?= Just (String "succeeded")
    evidenceField "error_info" ev @?= Just Null
    -- Purely additive: the pre-existing contract is untouched.
    length [e | e@CallStarted {} <- events] @?= 1
    length [e | e@CallFinished {} <- events] @?= 1
    length [e | e@CallFailed {} <- events] @?= 0

failureEvidenceTest :: TestTree
failureEvidenceTest =
  testCase "a failed call emits one evidence record with status failed" $ do
    let a = Custom "baikai-evidence-failure"
    registerFail a (providerError "stub-failure")
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext evidenceOptions
    events <- reverse <$> readTVarIO ref
    ev <- exactlyOneEvidence events
    evidenceField "status" ev @?= Just (String "failed")
    case evidenceField "error_info" ev of
      Just (Object o) ->
        assertBool
          ("expected error_info to mention stub-failure, got: " <> show o)
          (maybe False (Text.isInfixOf "stub-failure" . renderString) (KeyMap.lookup "message" o))
      other -> assertFailure ("expected a populated error_info, got: " <> show other)
    length [e | e@CallStarted {} <- events] @?= 1
    length [e | e@CallFailed {} <- events] @?= 1
  where
    renderString = \case
      String t -> t
      v -> Text.pack (show v)

abortEvidenceTest :: TestTree
abortEvidenceTest =
  testCase "an abandoned stream emits one evidence record with status aborted" $ do
    let a = Custom "baikai-evidence-abort"
    registerOk a
    (ref, sink) <- memorySink
    emitted <-
      Stream.toList
        (Stream.take 1 (withTraceStream sink (stubModel a) stubContext evidenceOptions))
    length emitted @?= 1
    events <- awaitEvents ref 3
    ev <- exactlyOneEvidence events
    -- 'aborted', not 'failed'. The consumer stopped reading; reporting
    -- that as a provider failure would misattribute it.
    evidenceField "status" ev @?= Just (String "aborted")

noProviderEvidenceTest :: TestTree
noProviderEvidenceTest =
  testCase "an unregistered provider emits one evidence record with status failed" $ do
    let a = Custom "baikai-evidence-no-provider"
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext evidenceOptions
    events <- reverse <$> readTVarIO ref
    ev <- exactlyOneEvidence events
    evidenceField "status" ev @?= Just (String "failed")

sinkFailureEvidenceTest :: TestTree
sinkFailureEvidenceTest =
  testCase "a throwing sink does not fail an opted-in best-effort call" $ do
    let a = Custom "baikai-evidence-throwing-sink"
    registerOk a
    result <-
      timeout 5000000 (withTrace throwingSink (stubModel a) stubContext evidenceOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a throwing sink"
      Just resp -> do
        -- Unchanged, and it is the guarantee every existing caller
        -- depends on: the exception does not propagate and the call
        -- succeeds. Only a strict caller gets the opposite; see
        -- 'strictSinkFailureTest' below.
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= Stop

-- | The one place in baikai where a call that reached the provider and
-- came back is nevertheless reported as failed.
strictSinkFailureTest :: TestTree
strictSinkFailureTest =
  testCase "A STRICT CALL WHOSE SINK THREW FAILS, RATHER THAN SUCCEEDING SILENTLY" $ do
    -- A strict caller asked for a record of this call and the record did
    -- not survive. Handing them the answer anyway would give them
    -- something they cannot account for, with no way to notice: evidence
    -- that can vanish without the caller noticing is not evidence.
    let a = Custom "baikai-evidence-strict-throwing-sink"
    -- The evidence-building fixture, so the sink is the only reason this
    -- call can fail. With a provider that attaches no record, a strict
    -- call now fails on that account before the sink is ever reached,
    -- and this case would assert the sink rule against the record rule.
    registerOkWithEvidence a
    result <-
      timeout 5000000 (withTrace throwingSink (stubModel a) stubContext strictOptions)
    case result of
      Nothing -> assertFailure "withTrace hung on a throwing sink"
      Just resp -> do
        let AssistantPayload {stopReason = sr} = resp ^. #message
        sr @?= ErrorReason
        case responseError resp of
          Nothing -> assertFailure "expected the sink failure to reach the response"
          Just be ->
            assertBool
              ("the error names the sink: " <> Text.unpack (be ^. #message))
              ("trace sink failed" `Text.isInfixOf` (be ^. #message))

-- | Strict mode guaranteed that a record which was built and then lost
-- fails the call. It did not guarantee that one was built: a provider
-- that attached nothing returned a successful response and wrote no
-- @call_evidence@ line, with no error anywhere.
strictNoRecordFailsTest :: TestTree
strictNoRecordFailsTest =
  testCase "A STRICT CALL WHOSE PROVIDER ATTACHED NO RECORD FAILS, AND EMITS NO RECORD" $ do
    let a = Custom "baikai-evidence-strict-no-record"
    registerOk a
    (ref, sink) <- memorySink
    resp <- withTrace sink (stubModel a) stubContext strictOptions
    let AssistantPayload {stopReason = sr} = resp ^. #message
    sr @?= ErrorReason
    case responseError resp of
      Nothing -> assertFailure "expected the missing record to fail the call"
      Just be -> do
        be ^. #category @?= OtherError
        assertBool
          ("the error names the missing record: " <> Text.unpack (be ^. #message))
          ("attached no evidence record" `Text.isInfixOf` (be ^. #message))
    events <- awaitEvents ref 2
    length [e | e@CallStarted {} <- events] @?= 1
    length [e | e@CallFailed {} <- events] @?= 1
    length (evidencesIn events) @?= 0

-- | The rewrite produces one terminal, not two.
strictNoRecordIsOneTerminalTest :: TestTree
strictNoRecordIsOneTerminalTest =
  testCase "a record-less strict stream yields one EventError and no EventDone" $ do
    let a = Custom "baikai-evidence-strict-no-record-stream"
    registerOk a
    events <-
      Stream.toList (withTraceStream silent (stubModel a) stubContext strictOptions)
    length [e | e@(EventDone _) <- events] @?= 0
    length [e | e@(EventError _) <- events] @?= 1

-- | The rewrite fires on the absence of a record, not on strictness
-- alone.
strictWithRecordSucceedsTest :: TestTree
strictWithRecordSucceedsTest =
  testCase "a strict call whose provider attached a record still succeeds" $ do
    let a = Custom "baikai-evidence-strict-with-record"
    registerOkWithEvidence a
    (ref, sink) <- memorySink
    resp <- withTrace sink (stubModel a) stubContext strictOptions
    let AssistantPayload {stopReason = sr} = resp ^. #message
    sr @?= Stop
    responseError resp @?= Nothing
    events <- awaitEvents ref 3
    length (evidencesIn events) @?= 1

-- | On the error path the provider's own error is the more useful of
-- the two, and the strict contract already holds: the call failed.
strictNoRecordErrorPathKeepsProviderErrorTest :: TestTree
strictNoRecordErrorPathKeepsProviderErrorTest =
  testCase "a failed strict call keeps the provider's own error" $ do
    let a = Custom "baikai-evidence-strict-provider-error"
    registerFail a (providerError "stub-failure")
    resp <- withTrace silent (stubModel a) stubContext strictOptions
    case responseError resp of
      Nothing -> assertFailure "expected the provider's failure to reach the response"
      Just be -> do
        assertBool
          ("the provider's error survives: " <> Text.unpack (be ^. #message))
          ("stub-failure" `Text.isInfixOf` (be ^. #message))
        assertBool
          "the missing-record error must not overwrite it"
          (not ("attached no evidence record" `Text.isInfixOf` (be ^. #message)))

-- | Best effort never refuses, here as everywhere.
bestEffortNoRecordStillSucceedsTest :: TestTree
bestEffortNoRecordStillSucceedsTest =
  testCase "a best-effort call whose provider attached no record still succeeds" $ do
    let a = Custom "baikai-evidence-best-effort-no-record"
    registerOk a
    resp <- withTrace silent (stubModel a) stubContext evidenceOptions
    let AssistantPayload {stopReason = sr} = resp ^. #message
    sr @?= Stop
    responseError resp @?= Nothing

-- | The exactly-once guarantee still holds when the terminal is
-- rewritten.
strictSinkFailureIsStillOneTerminalTest :: TestTree
strictSinkFailureIsStillOneTerminalTest =
  testCase "a rewritten terminal is still exactly one terminal event" $ do
    let a = Custom "baikai-evidence-strict-sink-terminal"
    -- The evidence-building fixture, so the "survives the rewrite"
    -- assertion below has something to survive.
    registerOkWithEvidence a
    events <-
      Stream.toList (withTraceStream throwingSink (stubModel a) stubContext strictOptions)
    length [e | e@(EventDone _) <- events] @?= 0
    length [e | e@(EventError _) <- events] @?= 1
    -- The evidence the provider built survives the rewrite. It is
    -- exactly what a caller investigating this failure wants to read.
    case [p | EventError p <- events] of
      [p] -> assertBool "the evidence survives" (p ^. #evidence /= Nothing)
      other -> assertFailure ("expected one terminal, got: " <> show (length other))

strictOptions :: Options
strictOptions =
  stubOptions
    & #evidence
    .~ Just
      ( evidenceRequest "run-57"
          & #strictness
          .~ Ev.EvidenceRequired Ev.EvidenceRequestedOnly
      )

-- | The criterion that protects every existing user of this library.
optOutSilentTest :: TestTree
optOutSilentTest =
  testCase "a call with no evidence request emits no evidence and traces identically" $ do
    let a = Custom "baikai-evidence-opt-out"
    registerOkWithEvidence a
    (outRef, outSink) <- memorySink
    _ <- withTrace outSink (stubModel a) stubContext stubOptions
    optedOut <- reverse <$> readTVarIO outRef
    (inRef, inSink) <- memorySink
    _ <- withTrace inSink (stubModel a) stubContext evidenceOptions
    optedIn <- reverse <$> readTVarIO inRef
    evidencesIn optedOut @?= []
    length (evidencesIn optedIn) @?= 1
    -- Asking for evidence adds an event and changes nothing else.
    map redact optedOut @?= map redact [e | e <- optedIn, notEvidence e]
  where
    notEvidence = \case
      CallEvidence {} -> False
      _ -> True

-- | Encode an event the way a sink does, then blank the fields that
-- legitimately differ between two runs of the same call.
--
-- Deliberately textual rather than a rewrite of the decoded
-- 'Aeson.Value': 'Aeson.toJSON' produces a 'KeyMap' whose re-encoding
-- sorts keys, and field /order/ is part of what an existing consumer
-- sees. Comparing sorted objects would hide exactly the drift this is
-- here to catch.
--
-- The three redacted values are a hex identifier, an ISO-8601
-- timestamp, and an integer; none can contain a @,@ or @}@, so scanning
-- to the next one is a safe way to find the end of the value.
redact :: TraceEvent -> Text
redact =
  redactField "latencyMs" "0"
    . redactField "timestamp" "\"<ts>\""
    . redactField "eventId" "\"<id>\""
    . TextEncoding.decodeUtf8
    . BL8.toStrict
    . Aeson.encode

redactField :: Text -> Text -> Text -> Text
redactField key replacement line
  | Text.null rest = line
  | otherwise = before <> needle <> replacement <> Text.dropWhile isValueChar after
  where
    needle = "\"" <> key <> "\":"
    (before, rest) = Text.breakOn needle line
    after = Text.drop (Text.length needle) rest
    isValueChar c = c /= ',' && c /= '}'

-- | The golden fixture is the encoded event sequence an opted-out call
-- produces, recorded against
-- @baikai\/test\/fixtures\/trace-opt-out.jsonl@.
--
-- Its content was checked against the pre-plan code rather than
-- asserted from memory: the same fixture provider was run at commit
-- @0acbad8@ (the last commit before this plan touched the trace path)
-- and the two @call_started@ lines match exactly, while @call_finished@
-- differs only by the four token fields and the @usd@ field this plan
-- deliberately added. Nothing else moved, and no @call_evidence@ line
-- appears.
--
-- If this test fails, an opted-out caller's trace output changed. That
-- is a breaking change for every existing user of this library and
-- needs a changelog entry, not a new fixture pasted over the old one.
optOutGoldenTest :: TestTree
optOutGoldenTest =
  testCase "an opted-out call's trace bytes match the golden fixture" $ do
    let a = Custom "baikai-evidence-golden"
    registerOk a
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext stubOptions
    events <- reverse <$> readTVarIO ref
    expected <- Text.lines <$> Text.IO.readFile "test/fixtures/trace-opt-out.jsonl"
    map redact events @?= filter (not . Text.null) expected

-- | An opted-out call must do no work, not merely produce no output.
--
-- The fixture provider hands 'Build.minimalEvidence' an envelope that
-- throws when forced. If someone later adds a strictness annotation to
-- that parameter, or moves the opt-out check below the digest
-- computation, this test fails and says why.
envelopeNotForcedTest :: TestTree
envelopeNotForcedTest =
  testCase "an opted-out call never forces the request envelope" $ do
    let a = Custom "baikai-evidence-lazy-envelope"
        handler m _ctx opts = do
          now <- getCurrentTime
          ev <-
            Build.minimalEvidence
              m
              opts
              TransportHttpApi
              noThinkingRequested
              (error "envelope forced on the opt-out path")
              now
              now
              Ev.CallSucceeded
              Nothing
          pure (stubResponse a & #evidence .~ ev)
    registerApiProvider
      ApiProvider
        { apiTag = a,
          stream = liftCompleteToStream handler,
          complete = handler,
          describeThinking = \_ _ -> noThinkingRequested,
          strengthCeiling = Ev.EvidenceRequestedOnly
        }
    (ref, sink) <- memorySink
    _ <- withTrace sink (stubModel a) stubContext stubOptions
    events <- reverse <$> readTVarIO ref
    evidencesIn events @?= []

-- ============================================================
-- Wire encoding
-- ============================================================

-- | 'FromJSON' is hand-written and therefore can drift from the derived
-- 'ToJSON' without the compiler noticing. It already did once during
-- this plan: the decoder read a nested @data@ object, which aeson's
-- 'TaggedObject' does not produce for a record constructor, so it could
-- not have parsed a single line this package emits.
encodingTests :: TestTree
encodingTests =
  testGroup
    "TraceEvent JSON"
    [ testCase "the three decodable kinds round-trip" $
        mapM_ roundTrip [sampleStarted, sampleFinished, sampleFailed],
      -- A trace line carries its fields alongside the discriminator,
      -- not nested under one. Consumers filter on this shape.
      testCase "fields sit alongside the kind discriminator" $ do
        let o = asObject (Aeson.toJSON sampleFinished)
        KeyMap.lookup "kind" o @?= Just (String "call_finished")
        KeyMap.lookup "latencyMs" o @?= Just (Number 12)
        assertBool "no data wrapper" (not (KeyMap.member "data" o)),
      -- Not a limitation to route around: 'ModelCallEvidence' embeds a
      -- cost whose exact Rational cannot survive the Scientific it
      -- encodes through, so a decoder would return a different value
      -- than was encoded. Failing loudly beats claiming a fidelity the
      -- type does not have.
      testCase "a call_evidence line refuses to decode, with an explanation" $ do
        let a = Custom "baikai-evidence-decode"
        registerOkWithEvidence a
        (ref, sink) <- memorySink
        _ <- withTrace sink (stubModel a) stubContext evidenceOptions
        events <- reverse <$> readTVarIO ref
        case [e | e@CallEvidence {} <- events] of
          [e] -> case Aeson.eitherDecode (Aeson.encode e) :: Either String TraceEvent of
            Right decoded -> assertFailure ("expected a decode failure, got: " <> show decoded)
            Left err ->
              assertBool
                ("expected the message to point at Data.Aeson.Value, got: " <> err)
                ("Data.Aeson.Value" `Text.isInfixOf` Text.pack err)
          other -> assertFailure ("expected one CallEvidence, got: " <> show other)
    ]
  where
    roundTrip e = case Aeson.eitherDecode (Aeson.encode e) of
      Right decoded -> decoded @?= e
      Left err -> assertFailure ("failed to decode " <> show e <> ": " <> err)

fixedTime :: UTCTime
fixedTime = read "2026-05-14 00:00:00 UTC"

sampleStarted :: TraceEvent
sampleStarted =
  CallStarted
    { eventId = "abc",
      timestamp = fixedTime,
      provider = "stub.trace",
      model = "stub-1",
      maxTokens = 16,
      promptSummary = "hello"
    }

sampleFinished :: TraceEvent
sampleFinished =
  CallFinished
    { eventId = "abc",
      timestamp = fixedTime,
      provider = "stub.trace",
      model = "stub-1",
      latencyMs = 12,
      inputTokens = Just 11,
      outputTokens = Just 7,
      cachedInputTokens = Just 5,
      cacheWriteTokens = Just 3,
      reasoningTokens = Just 4,
      totalTokens = Just 26,
      usd = Just 0
    }

sampleFailed :: TraceEvent
sampleFailed =
  CallFailed
    { eventId = "abc",
      timestamp = fixedTime,
      provider = "stub.trace",
      model = "stub-1",
      latencyMs = 12,
      errorMessage = "boom"
    }
