-- | The hand-off between a provider's SSE worker thread and the
-- consumer draining its 'Stream'.
--
-- __This module is internal.__ Like "Baikai.Provider.Cli.Internal" it is
-- exposed so the provider packages can share one implementation, and it
-- is outside baikai's PVP promise: its contents may change in a minor
-- release.
--
-- A provider forks one worker per call to read frames off the socket and
-- push them here; the consumer pulls them out on the other side. Three
-- things about that hand-off are deliberate, and a reader of either
-- provider's @Api.hs@ will find the reasoning only here.
--
-- __The queue is bounded.__ 'frameQueueCapacity' slots, and 'pushFrame'
-- blocks when they are full. A consumer that simply stops pulling — it
-- took the first three events and moved on — therefore stops the socket
-- read after at most 'frameQueueCapacity' further frames, with the
-- worker parked in an interruptible STM wait. No garbage collection and
-- no timer is involved: the bound alone stops the read, and the provider
-- stops being billed for a generation nobody is reading. An unbounded
-- channel gives the opposite behaviour, draining the whole response into
-- memory for a consumer that will never look at it.
--
-- __Cleanup has three strengths, and they are not the same.__
--
-- * /Immediate/ when the consumer stops by exception. 'withFrameWorker'
--   wraps the consumer in 'Stream.bracketIO', so an exception thrown
--   into the draining thread — @Ctrl-C@, 'System.Timeout.timeout',
--   @cancel@ — lands while that thread sits inside the stream's own
--   step, inside the bracket. streamly runs the release synchronously:
--   the worker is killed, the transport's own @bracket@ around the HTTP
--   response runs, and the connection is back in the pool before the
--   exception reaches the caller.
--
-- * /Immediate/ when the stream ends normally, for the same reason.
--
-- * /Eventual/ when the consumer abandons the stream without an
--   exception (@Stream.take 3@ and carry on). Nothing runs at that
--   moment, because nothing knows it happened; the bound above has
--   already stopped the read, and streamly's GC finaliser runs the same
--   'killThread' at the next major collection, which is when the
--   connection is released. Callers who need the connection back at a
--   known moment cancel the draining thread or wrap the drain in
--   'System.Timeout.timeout'.
--
-- A "consumer still alive" flag was considered and rejected: nothing
-- sets it to false on abandonment, so only the collector can answer
-- "will anyone pull again". So was a stall deadline on a full queue —
-- a slow but live consumer, a callback that takes minutes per event,
-- would be cut off, and correctness must not depend on consumer speed.
--
-- __The worker never writes a sentinel.__ End-of-frames is a 'TVar'
-- flag set by 'forkFrameWorker''s 'finally', not a @Nothing@ pushed onto
-- the queue. A sentinel write can block on a full queue and so defeat
-- the very cleanup it is part of; a 'TVar' write never blocks. This is
-- also why an asynchronous exception delivered to the worker can no
-- longer strand the consumer: the flag is set however the body ends.
module Baikai.Provider.Internal.StreamWorker
  ( FrameQueue,
    frameQueueCapacity,
    newFrameQueue,
    pushFrame,
    closeFrames,
    pullFrame,
    forkFrameWorker,
    withFrameWorker,
  )
where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    check,
    newTVarIO,
    orElse,
    readTVar,
    writeTVar,
  )
import Control.Concurrent.STM.TBQueue (TBQueue, newTBQueueIO, readTBQueue, writeTBQueue)
import Control.Exception (finally, mask_)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | The bounded hand-off between one worker and one consumer.
data FrameQueue a = FrameQueue
  { frames :: !(TBQueue a),
    closed :: !(TVar Bool)
  }
  deriving stock (Generic)

-- | How many frames a worker may run ahead of its consumer.
--
-- Large enough that a consumer doing ordinary per-event work is never
-- the bottleneck, small enough that an abandoned stream stops reading
-- the socket almost at once.
frameQueueCapacity :: Natural
frameQueueCapacity = 64

newFrameQueue :: IO (FrameQueue a)
newFrameQueue = FrameQueue <$> newTBQueueIO frameQueueCapacity <*> newTVarIO False

-- | Push one frame. Blocks while the queue is full, interruptibly, so a
-- worker parked here dies as soon as it is killed.
pushFrame :: FrameQueue a -> a -> IO ()
pushFrame q a = atomically (writeTBQueue (frames q) a)

-- | Mark the queue closed. Never blocks, so it is safe inside a
-- 'finally' on a full queue.
closeFrames :: FrameQueue a -> IO ()
closeFrames q = atomically (writeTVar (closed q) True)

-- | The next frame, or 'Nothing' once the queue is empty /and/ closed.
-- Frames pushed before the close are always delivered first.
pullFrame :: FrameQueue a -> IO (Maybe a)
pullFrame q =
  atomically $
    (Just <$> readTBQueue (frames q))
      `orElse` (readTVar (closed q) >>= check >> pure Nothing)

-- | Fork a worker body so that its 'ThreadId' cannot be lost to an
-- asynchronous exception arriving between the fork and the caller
-- recording it, and so that the queue is closed however the body ends —
-- normal return, synchronous exception, or 'killThread'.
forkFrameWorker :: FrameQueue a -> IO () -> IO ThreadId
forkFrameWorker q body =
  mask_ (forkIOWithUnmask (\unmask -> unmask body `finally` closeFrames q))

-- | Run a consumer stream with the worker alive, killing the worker when
-- the stream stops, throws, or is collected. See the module
-- documentation for which of those is immediate and which is eventual.
withFrameWorker :: FrameQueue a -> IO () -> Stream IO b -> Stream IO b
withFrameWorker q body consumer =
  Stream.bracketIO (forkFrameWorker q body) killThread (const consumer)
