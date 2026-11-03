module TracedStreamSpec (tests) where

import Baikai hiding (CallFailed, requested)
import Baikai.Effectful (runBaikai, runBaikaiWith, streamCollectTraced)
import Baikai.Evidence qualified as Ev
import Baikai.Prelude
import Baikai.Trace (TraceEvent (..), TraceSink (..))
import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Exception (Exception (..), SomeException, asyncExceptionFromException, asyncExceptionToException, finally, fromException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Effectful (runEff)
import GHC.Clock (getMonotonicTimeNSec)
import Streamly.Data.Fold qualified as Fold
import StubProvider
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

newtype Cancelled = Cancelled Int
  deriving stock (Eq, Show)

instance Exception Cancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

requested :: Options
requested = stubOptions & #evidence .~ Just (evidenceRequest "effectful-abort")

strictOptions :: Options
strictOptions = requested & #evidence . _Just . #strictness .~ EvidenceRequired EvidenceRequestedOnly

memorySink :: IO (IORef [TraceEvent], TraceSink)
memorySink = do
  cell <- newIORef []
  pure (cell, TraceSink (Fold.drainMapM (\e -> modifyIORef' cell (e :))))

records :: [TraceEvent] -> [ModelCallEvidence]
records events = [ev | CallEvidence {evidence = ev} <- events]

tests :: TestTree
tests =
  testGroup
    "TracedStreamSpec"
    [ terminalTest False,
      terminalTest True,
      testCase "strict refusal precedes dispatch and preserves terminal evidence" $ do
        (reg, count) <- evidenceRegistry False
        (cell, sink) <- memorySink
        let opts = requested & #evidence . _Just . #strictness .~ EvidenceRequired EvidenceCorrelated
        events <- runEff . runBaikaiWith reg $ streamCollectTraced sink stubModel stubContext opts
        count >>= (@?= 0)
        traces <- records <$> readIORef cell
        let terminalRecords = [ev | EventError p <- events, Just ev <- [p ^. #evidence]]
        traces @?= terminalRecords
        length traces @?= 1
        map (^. #status) traces @?= [Ev.CallFailed]
        assertBool "refusal error recorded" (all (isJust . (^. #errorInfo)) traces),
      testCase "opt-out emits no evidence" $ do
        (reg, _) <- evidenceRegistry False
        (cell, sink) <- memorySink
        _ <- runEff . runBaikaiWith reg $ streamCollectTraced sink stubModel stubContext stubOptions
        readIORef cell >>= ((@?= []) . records),
      testCase "a provider without evidence keeps strict missing-record enforcement" $ do
        reg <- stubRegistry "legacy"
        (cell, sink) <- memorySink
        events <- runEff . runBaikaiWith reg $ streamCollectTraced sink stubModel stubContext strictOptions
        assertBool "missing record fails" (any (\case EventError {} -> True; _ -> False) events)
        readIORef cell >>= ((@?= []) . records),
      testCase "global interpreter delegates traced collection" $ do
        let model = stubModel & #api .~ Custom "effectful-traced-global-102"
            handler _ _ _ = pure emptyResponse
        registerApiProvider (apiProviderWith (model ^. #api) (liftCompleteToStream handler) handler)
        (cell, sink) <- memorySink
        events <- runEff . runBaikai $ streamCollectTraced sink model stubContext stubOptions
        assertBool "terminal returned" (any (\case EventDone {} -> True; _ -> False) events)
        traces <- readIORef cell
        length traces @?= 2,
      testCase "best-effort cancellation acknowledges abort before handler" $ cancellationTest requested Healthy,
      testCase "strict cancellation preserves the original exception" $ cancellationTest strictOptions Healthy,
      testCase "blocked sink bounds cancellation and may deliver later once" $ cancellationTest strictOptions Blocked,
      testCase "blocked sink also bounds best-effort cancellation" $ cancellationTest requested Blocked,
      testCase "throwing sink cannot replace strict cancellation" $ cancellationTest strictOptions Throwing,
      testCase "throwing sink cannot replace best-effort cancellation" $ cancellationTest requested Throwing
    ]

terminalTest :: Bool -> TestTree
terminalTest failCall = testCase (if failCall then "provider failure keeps evidence identity" else "success keeps evidence identity") $ do
  (reg, count) <- evidenceRegistry failCall
  (cell, sink) <- memorySink
  events <- runEff . runBaikaiWith reg $ streamCollectTraced sink stubModel stubContext requested
  count >>= (@?= 1)
  traces <- records <$> readIORef cell
  let terminalRecords =
        [ ev
        | event <- events,
          p <- case event of EventDone t -> [t]; EventError t -> [t]; _ -> [],
          Just ev <- [p ^. #evidence]
        ]
  traces @?= terminalRecords
  length traces @?= 1
  map (^. #status) traces @?= [if failCall then Ev.CallFailed else CallSucceeded]

data SinkMode = Healthy | Blocked | Throwing
  deriving stock (Eq)

cancellationTest :: Options -> SinkMode -> IO ()
cancellationTest opts mode = do
  (reg, entered, released) <- blockingRegistry
  cell <- newIORef []
  sinkEntered <- newEmptyMVar
  sinkReleased <- newEmptyMVar
  ended <- newEmptyMVar
  let step e = do
        case e of
          CallStarted {} -> do
            putMVar sinkEntered ()
            case mode of
              Blocked -> readMVar sinkReleased
              Throwing -> throwIO (userError "fixture sink failure")
              Healthy -> pure ()
          _ -> pure ()
        modifyIORef' cell (e :)
      sink = TraceSink (Fold.rmapM (\() -> putMVar ended ()) (Fold.drainMapM step))
  outcome <- newEmptyMVar
  tid <- forkIO $ do
    result <- try (runEff . runBaikaiWith reg $ streamCollectTraced sink stubModel stubContext opts)
    -- All observations belong to the caller's exception handler: no waiting
    -- for evidence, forced collection, or post-cancellation polling.
    snapshot <- readIORef cell
    providerDone <- tryReadMVar released
    sinkDone <- tryReadMVar ended
    putMVar outcome (result :: Either SomeException [AssistantMessageEvent], snapshot, providerDone, sinkDone)
  let run = do
        timeout 2000000 (readMVar entered) >>= (@?= Just ())
        timeout 2000000 (readMVar sinkEntered) >>= (@?= Just ())
        start <- getMonotonicTimeNSec
        throwTo tid (Cancelled 73102)
        observed <- timeout 3000000 (takeMVar outcome)
        stop <- getMonotonicTimeNSec
        case observed of
          Nothing -> assertFailure "cancelled collection hung"
          Just (result, snapshot, providerDone, sinkDone) -> do
            case result of
              Left ex -> fromException ex @?= Just (Cancelled 73102)
              Right _ -> assertFailure "cancellation disappeared"
            providerDone @?= Just ()
            case mode of
              Healthy -> do
                map (^. #status) (records snapshot) @?= [Ev.CallAborted]
                sinkDone @?= Just ()
              _ -> records snapshot @?= []
            assertBool "cleanup stays bounded" (stop - start < 2500000000)
            when (mode == Blocked) $ do
              assertBool "production drain budget was exercised" (stop - start >= 800000000)
              putMVar sinkReleased ()
              timeout 2000000 (readMVar ended) >>= (@?= Just ())
              eventual <- records <$> readIORef cell
              map (^. #status) eventual @?= [Ev.CallAborted]
  run `finally` (void (tryPutMVar sinkReleased ()) >> throwTo tid (Cancelled 73102))
