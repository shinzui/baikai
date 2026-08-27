-- | The bounded worker/consumer hand-off in
-- "Baikai.Provider.Internal.StreamWorker".
--
-- Both HTTP providers depend on the three properties pinned here: every
-- frame pushed before the close is delivered, a worker blocked on a full
-- queue is interruptible, and the queue closes however the body ends.
module StreamWorkerSpec (tests) where

import Baikai.Provider.Internal.StreamWorker
  ( FrameQueue,
    closeFrames,
    forkFrameWorker,
    frameQueueCapacity,
    newFrameQueue,
    pullFrame,
    pushFrame,
  )
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryTakeMVar)
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Internal.StreamWorker"
    [ deliversEveryFrameTest,
      blockedPushIsInterruptibleTest,
      killedBodyClosesQueueTest
    ]

-- | Ordering and completeness: the close flag never overtakes frames
-- already in the queue.
deliversEveryFrameTest :: TestTree
deliversEveryFrameTest =
  testCase "pullFrame delivers every frame pushed before close" $ do
    q <- newFrameQueue
    forM_ [1 :: Int .. 10] (pushFrame q)
    closeFrames q
    let drain acc =
          pullFrame q >>= \case
            Nothing -> pure (reverse acc)
            Just a -> drain (a : acc)
    got <- drain []
    got @?= [1 .. 10]

-- | A worker whose consumer has stopped parks on a full queue rather
-- than reading on, and the park is an interruptible STM wait, so
-- 'killThread' reaches it.
blockedPushIsInterruptibleTest :: TestTree
blockedPushIsInterruptibleTest =
  testCase "pushFrame blocks when the queue is full and is interruptible" $ do
    q <- newFrameQueue
    pushed <- newEmptyMVar
    diedRef <- newIORef False
    tid <- forkIO $ do
      ( do
          forM_ [1 .. fromIntegral frameQueueCapacity] (pushFrame q :: Int -> IO ())
          pushFrame q 0
          putMVar pushed ()
        )
        `finally` writeIORef diedRef True
    threadDelay 100000
    stillBlocked <- tryTakeMVar pushed
    stillBlocked @?= Nothing
    killThread tid
    threadDelay 50000
    died <- readIORef diedRef
    assertBool "the blocked pusher was interrupted" died

-- | The close flag is set by the fork's own @finally@, so a worker that
-- dies by asynchronous exception cannot leave the consumer waiting.
killedBodyClosesQueueTest :: TestTree
killedBodyClosesQueueTest =
  testCase "forkFrameWorker closes the queue when the body is killed" $ do
    q <- newFrameQueue :: IO (FrameQueue Int)
    blocked <- newEmptyMVar
    tid <- forkFrameWorker q (takeMVar blocked)
    threadDelay 20000
    killThread tid
    got <- timeout 1000000 (pullFrame q)
    got @?= Just Nothing
