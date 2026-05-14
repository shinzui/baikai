module TraceSpec (tests) where

import Baikai.Error (BaikaiError (..))
import Baikai.Message (user)
import Baikai.Model (Model (..))
import Baikai.Prelude
import Baikai.Provider (Provider (..))
import Baikai.Request (Request, _Request)
import Baikai.Response (Response, _Response)
import Baikai.Trace (withTrace)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..), silent)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (throwIO, try)
import Data.Text qualified as Text
import Data.Vector qualified as V
import Streamly.Data.Fold qualified as Fold
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Trace"
    [ silentTest
    , memoryFinishTest
    , memoryFailTest
    ]

-- | Stub provider whose runRequest either returns a fixed response or
-- throws a 'BaikaiError'.
data Stub
  = StubOk Response
  | StubFail BaikaiError

instance Provider Stub where
  providerName _ = "stub.trace"
  runRequest (StubOk r) _ = pure r
  runRequest (StubFail e) _ = liftIO (throwIO e)

stubResponse :: Response
stubResponse =
  _Response
    & #content .~ "hi"
    & #model .~ Model "stub-1"
    & #provider .~ "stub.trace"
    & #latencyMs .~ 0

stubRequest :: Request
stubRequest =
  _Request
    & #model .~ Model "stub-1"
    & #maxTokens .~ 16
    & #messages .~ V.fromList [user "hello"]

-- | An in-memory sink that prepends every event to a 'TVar [TraceEvent]'.
-- 'withTrace' guarantees the worker has drained the terminal event before
-- returning, so the TVar is fully populated by the time the test reads it.
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
        resp <- withTrace silent (StubOk stubResponse) stubRequest
        resp ^. #content @?= "hi"
    , testCase "re-throws on failure" $ do
        r <- try (withTrace silent (StubFail (ProviderError "boom")) stubRequest)
        case r of
          Left e -> e @?= ProviderError "boom"
          Right (_ :: Response) -> assertFailure "expected exception, got response"
    ]

memoryFinishTest :: TestTree
memoryFinishTest =
  testCase "memory sink records CallStarted then CallFinished" $ do
    (ref, sink) <- memorySink
    resp <- withTrace sink (StubOk stubResponse) stubRequest
    resp ^. #content @?= "hi"
    rev <- readTVarIO ref
    let events = reverse rev
    length events @?= 2
    case events of
      [s@CallStarted {}, f@CallFinished {}] -> do
        eventId (s :: TraceEvent) @?= eventId (f :: TraceEvent)
        provider (s :: TraceEvent) @?= "stub.trace"
        provider (f :: TraceEvent) @?= "stub.trace"
        model (s :: TraceEvent) @?= "stub-1"
        model (f :: TraceEvent) @?= "stub-1"
      _ -> assertFailure ("unexpected event sequence: " <> show events)

memoryFailTest :: TestTree
memoryFailTest =
  testCase "memory sink records CallStarted then CallFailed on exception" $ do
    (ref, sink) <- memorySink
    r <- try (withTrace sink (StubFail (ProviderError "stub-failure")) stubRequest)
    case r of
      Left e -> e @?= ProviderError "stub-failure"
      Right (_ :: Response) -> assertFailure "expected exception, got response"
    rev <- readTVarIO ref
    let events = reverse rev
    length events @?= 2
    case events of
      [s@CallStarted {}, f@CallFailed {}] -> do
        eventId (s :: TraceEvent) @?= eventId (f :: TraceEvent)
        assertBool
          ("expected error to mention stub-failure, got: " <> show (errorMessage f))
          ("stub-failure" `Text.isInfixOf` errorMessage f)
      _ -> assertFailure ("unexpected event sequence: " <> show events)
