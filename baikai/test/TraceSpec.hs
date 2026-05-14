module TraceSpec (tests) where

import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Error (BaikaiError (..))
import Baikai.Message (Message (..), user)
import Baikai.Model (Model (..))
import Baikai.Prelude
import Baikai.Provider (Provider (..))
import Baikai.Request (Request, _Request)
import Baikai.Response (Response (..), _Response)
import Baikai.StopReason (StopReason (..))
import Baikai.Trace (withTrace)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..), silent)
import Baikai.Usage (_Usage)
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
    { message =
        AssistantMessage
          { assistantContent = V.singleton (AssistantText (TextContent "hi"))
          , usage = _Usage
          , stopReason = Stop
          , errorMessage = Nothing
          , timestamp = read "2026-05-14 00:00:00 UTC"
          }
    , model = Model "stub-1"
    , api = "stub"
    , provider = "stub.trace"
    , responseId = Nothing
    , latencyMs = 0
    }

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
        _ <- withTrace silent (StubOk stubResponse) stubRequest
        pure ()
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
    _ <- withTrace sink (StubOk stubResponse) stubRequest
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
      [s@CallStarted {}, f@CallFailed {errorMessage = msg}] -> do
        (s ^. #eventId :: Text) @?= (f ^. #eventId :: Text)
        assertBool
          ("expected error to mention stub-failure, got: " <> show msg)
          ("stub-failure" `Text.isInfixOf` msg)
      _ -> assertFailure ("unexpected event sequence: " <> show events)
