-- | What happens to the worker thread and the HTTP connection when the
-- consumer stops.
--
-- The driver below is the real 'sseFromResponse' over a fake response
-- whose body reader never ends and whose close hook is observable, so a
-- worker killed mid-read provably closes the response exactly as
-- production's @HTTP.withResponse@ bracket would.
--
-- "Baikai.Provider.Internal.StreamWorker" states the three cleanup
-- strengths these four cases pin: bounded read then eventual release on
-- abandonment, immediate release on cancellation, and a worker that
-- cannot strand its consumer however it dies.
module LifecycleSpec (tests) where

import Baikai
import Baikai.Models.Generated (anthropic_claude_haiku_4_5)
import Baikai.Provider.Claude.Api (SseDriver, claudeMessagesStreamWith)
import Baikai.Provider.Claude.Sse (sseFromResponse)
import Baikai.Provider.Internal.StreamWorker (frameQueueCapacity)
import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, bracket, fromException, throwIO, try)
import Control.Lens ((&), (.~), (^.))
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude lifecycle"
    [ boundedReadTest,
      abandonedReleasesAfterGcTest,
      cancellationReleasesWithoutGcTest,
      workerDeathCannotStrandTest
    ]

-- | The bound alone stops the socket read: no garbage collection and no
-- timer is involved. Before the frame queue the counter grew without
-- limit, because the worker drained an endless body into an unbounded
-- channel.
boundedReadTest :: TestTree
boundedReadTest =
  testCase "a consumer that stops after three events stops the body reader within the queue bound" $ do
    reads' <- newIORef (0 :: Int)
    closedRef <- newIORef False
    events <-
      Stream.toList
        ( Stream.take
            3
            (claudeMessagesStreamWith (countingDriver reads' closedRef Nothing) testModel emptyContext testOptions)
        )
    length events @?= 3
    settled <- awaitSettled reads'
    assertBool
      ("body reader should stop within the queue bound, read " <> show settled <> " frames")
      (settled <= fromIntegral frameQueueCapacity + 8)

-- | The eventual guarantee. Nothing runs at the moment a consumer walks
-- away; streamly's finaliser kills the worker at the next major
-- collection, and that is when the connection goes back.
abandonedReleasesAfterGcTest :: TestTree
abandonedReleasesAfterGcTest =
  testCase "an abandoned stream releases its connection after a major GC" $ do
    reads' <- newIORef (0 :: Int)
    closedRef <- newIORef False
    _ <-
      Stream.toList
        ( Stream.take
            3
            (claudeMessagesStreamWith (countingDriver reads' closedRef Nothing) testModel emptyContext testOptions)
        )
    released <- pollFor 100 50000 (performMajorGC >> readIORef closedRef)
    assertBool "an abandoned stream's connection is released at a major GC" released

-- | The immediate guarantee. The exception lands while the consumer is
-- inside the stream's step, which is inside the bracket, so streamly
-- runs the release synchronously.
cancellationReleasesWithoutGcTest :: TestTree
cancellationReleasesWithoutGcTest =
  testCase "cancelling the consumer releases the connection without a GC" $ do
    reads' <- newIORef (0 :: Int)
    closedRef <- newIORef False
    gate <- newEmptyMVar
    outcome <- newEmptyMVar
    tid <-
      forkIO $ do
        r <-
          try
            ( Stream.toList
                (claudeMessagesStreamWith (countingDriver reads' closedRef (Just gate)) testModel emptyContext testOptions)
            )
        putMVar outcome (r :: Either SomeException [AssistantMessageEvent])
    threadDelay 100000
    throwTo tid ThreadKilled
    released <- pollFor 100 10000 (readIORef closedRef)
    assertBool "cancellation releases the connection without a GC" released
    r <- takeMVar outcome
    case r of
      Left e | Just ThreadKilled <- fromException e -> pure ()
      other -> assertFailure ("expected the drained thread to die by ThreadKilled, got: " <> show (fmap length other))

-- | The queue's closed flag is set by the fork's own @finally@, so a
-- worker that dies by asynchronous exception still ends the stream.
-- Before the frame queue the consumer blocked until the runtime's
-- deadlock detector fired.
workerDeathCannotStrandTest :: TestTree
workerDeathCannotStrandTest =
  testCase "an asynchronous exception in the worker still closes the channel" $ do
    let dyingDriver :: SseDriver
        dyingDriver _call _onMetadata _onEvent = throwIO ThreadKilled
    got <-
      timeout
        2000000
        (Stream.toList (claudeMessagesStreamWith dyingDriver testModel emptyContext testOptions))
    case got of
      Nothing -> assertFailure "a worker killed asynchronously left the consumer blocked"
      Just events -> case reverse events of
        -- 'errorInfo' is a 'Maybe': whether a stream error carries a
        -- typed error at all is itself worth asserting.
        (EventError p : _) ->
          fmap (^. #message) (p ^. #errorInfo) @?= Just "claude stream ended without message_stop"
        other -> assertFailure ("expected a terminal EventError, got: " <> show (take 1 other))

-- --------------------------------------------------------------------
-- Harness
-- --------------------------------------------------------------------

-- | A driver whose body reader is generated on demand and whose close
-- hook is observable. The bracket is the shape 'HTTP.withResponse' has,
-- so a worker killed mid-read closes the response as production would.
--
-- With a gate, the reader blocks forever from the fourth read on, which
-- is the state a cancelled consumer must be able to interrupt. Without
-- one, the body never ends, which is what makes the queue bound visible.
countingDriver :: IORef Int -> IORef Bool -> Maybe (MVar ()) -> SseDriver
countingDriver reads' closedRef gate _call onMetadata onEvent =
  bracket mkFakeResponse HTTP.responseClose $ \resp ->
    sseFromResponse resp onMetadata onEvent
  where
    mkFakeResponse =
      pure
        HTTP.Response
          { HTTP.responseStatus = mkStatus 200 "",
            HTTP.responseVersion = http11,
            HTTP.responseHeaders = [(CI.mk "request-id", "req-lifecycle")],
            HTTP.responseBody = bodyReader,
            HTTP.responseCookieJar = HTTP.createCookieJar [],
            HTTP.responseClose' = HTTP.ResponseClose (writeIORef closedRef True),
            HTTP.responseOriginalRequest = HTTP.defaultRequest,
            HTTP.responseEarlyHints = []
          }
    bodyReader = do
      n <- atomicModifyIORef' reads' (\k -> (k + 1, k))
      case gate of
        Just g | n >= 3 -> takeMVar g >> pure ""
        _ -> pure (frameAt n)

-- | An endless stream: a @message_start@, a text block start, then text
-- deltas without end.
frameAt :: Int -> ByteString
frameAt 0 =
  "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_lifecycle\",\"type\":\"message\","
    <> "\"role\":\"assistant\",\"content\":[],\"model\":\"claude-lifecycle\","
    <> "\"stop_reason\":null,\"stop_sequence\":null,"
    <> "\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
frameAt 1 =
  "data: {\"type\":\"content_block_start\",\"index\":0,"
    <> "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
frameAt _ =
  "data: {\"type\":\"content_block_delta\",\"index\":0,"
    <> "\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}\n\n"

-- | Poll the counter until it has not moved for four consecutive reads,
-- then report where it stopped. A counter that never settles fails the
-- caller's bound rather than hanging: the ceiling is generous and
-- finite.
awaitSettled :: IORef Int -> IO Int
awaitSettled ref = go (200 :: Int) (-1) (0 :: Int)
  where
    go 0 _ _ = readIORef ref
    go budget lastSeen stableFor = do
      threadDelay 50000
      n <- readIORef ref
      if n == lastSeen
        then if stableFor >= 3 then pure n else go (budget - 1) n (stableFor + 1)
        else go (budget - 1) n 0

pollFor :: Int -> Int -> IO Bool -> IO Bool
pollFor 0 _ _ = pure False
pollFor n delay act = do
  ok <- act
  if ok
    then pure True
    else threadDelay delay >> pollFor (n - 1) delay act

testModel :: Model
testModel =
  anthropic_claude_haiku_4_5
    & #api .~ AnthropicMessages
    & #baseUrl .~ "https://api.anthropic.com"

testOptions :: Options
testOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")
