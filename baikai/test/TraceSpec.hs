module TraceSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), _Context)
import Baikai.Error (BaikaiError, providerError)
import Baikai.Message (AssistantPayload (..), user)
import Baikai.Model (Model (..), _Model)
import Baikai.Options (Options, _Options)
import Baikai.Prelude
import Baikai.Provider (ApiProvider (..), registerApiProvider)
import Baikai.Response (Response (..))
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Trace (newEventId, withTrace, withTraceStream)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..), silent)
import Baikai.Usage (_Usage)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (throwIO)
import Control.Monad (replicateM)
import Data.Set qualified as Set
import Data.Text qualified as Text
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
      eventIdUniquenessTest,
      earlyAbortTest
    ]

-- | Each test uses its own private 'Api' tag so tasty's parallel
-- test scheduler cannot race the (process-global) registry between
-- tests.
stubModel :: Api -> Model
stubModel a =
  _Model
    & #modelId
    .~ "stub-1"
    & #api
    .~ a
    & #provider
    .~ "stub.trace"
    & #maxOutputTokens
    .~ 16

stubContext :: Context
stubContext = _Context & #messages .~ V.fromList [user "hello"]

stubOptions :: Options
stubOptions = _Options & #maxTokens .~ Just 16

stubResponse :: Api -> Response
stubResponse a =
  Response
    { message =
        AssistantPayload
          { content = V.singleton (AssistantText (TextContent "hi")),
            usage = _Usage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = read "2026-05-14 00:00:00 UTC"
          },
      model = stubModel a,
      api = a,
      provider = "stub.trace",
      responseId = Nothing,
      latencyMs = 0,
      errorInfo = Nothing
    }

registerOk :: Api -> IO ()
registerOk a =
  let handler _m _ctx _opts = pure (stubResponse a)
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler
          }

registerFail :: Api -> BaikaiError -> IO ()
registerFail a e =
  let handler _m _ctx _opts = throwIO e
   in registerApiProvider
        ApiProvider
          { apiTag = a,
            stream = liftCompleteToStream handler,
            complete = handler
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

eventIdUniquenessTest :: TestTree
eventIdUniquenessTest =
  testCase "newEventId yields 70000 distinct 16-char ids" $ do
    ids <- replicateM 70000 newEventId
    Set.size (Set.fromList ids) @?= 70000
    assertBool "every id is 16 chars" (all ((== 16) . Text.length) ids)

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
