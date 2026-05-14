{-# LANGUAGE ScopedTypeVariables #-}

-- | The 'withTrace' wrapper and supporting helpers.
--
-- 'withTrace' lifts a registry-dispatched call into one that emits
-- a 'CallStarted' event before the call and a 'CallFinished' or
-- 'CallFailed' event after, routing both through a user-supplied
-- 'TraceSink'. The sink lives behind a streamly 'Fold', so
-- composition (file plus stdout, redaction, batched OTel export) is
-- just fold composition.
--
-- Per-call plumbing: open a 'Chan' of @Maybe TraceEvent@, fork a
-- worker thread that drains the channel through the sink's fold,
-- push events, write a 'Nothing' sentinel to end the stream, then
-- wait for the worker to flush. Both the success and failure paths
-- drain the worker before returning or re-throwing.
module Baikai.Trace
  ( -- * Re-exports
    TraceEvent (..)
  , TraceSink (..)

    -- * Wrappers
  , withTrace
  , runRequestWith

    -- * Helpers
  , newEventId
  , summarizeContext
  ) where



import Baikai.Context (Context)
import Baikai.Cost (usdAsScientific)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogEntry (..)
  , CallLogHandle
  , appendEntry
  , summarizeContext
  )
import Baikai.Message (Message (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
import Baikai.Provider.Registry (completeRequest)
import Baikai.Response (Response)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Baikai.Usage (Usage)
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Data.Bits (unsafeShiftL, (.&.), (.|.))
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric (showHex)
import Streamly.Data.Stream qualified as Stream
import System.IO.Unsafe (unsafePerformIO)

-- | Wrap a registry-dispatched call with structured tracing.
--
-- Opens a per-call channel, forks a worker that drains events
-- through the sink's fold, emits 'CallStarted', invokes
-- 'completeRequest', emits 'CallFinished' (success) or 'CallFailed'
-- (any synchronous exception), closes the channel, waits for the
-- worker to drain, then returns the response or re-throws the
-- original exception. The worker is guaranteed to have drained the
-- terminal event before this function returns.
withTrace
  :: MonadUnliftIO m
  => TraceSink -> Model -> Context -> Options -> m Response
withTrace (TraceSink sinkFold) m ctx opts = withRunInIO $ \_run -> do
  chan <- newChan :: IO (Chan (Maybe TraceEvent))
  done <- newEmptyMVar

  _ <- forkIO $ do
    let step :: () -> IO (Maybe (TraceEvent, ()))
        step () = do
          msg <- readChan chan
          pure (fmap (\e -> (e, ())) msg)
    Stream.unfoldrM step ()
      & Stream.fold sinkFold
    putMVar done ()

  eid <- newEventId
  start <- getCurrentTime
  writeChan chan $
    Just
      CallStarted
        { eventId = eid
        , timestamp = start
        , provider = m ^. #provider
        , model = m ^. #modelId
        , maxTokens = resolvedMaxTokens m opts
        , promptSummary = summarizeContext ctx
        }

  result <- try (completeRequest m ctx opts :: IO Response)
  end <- getCurrentTime
  let latency :: Integer
      latency = round (1000 * diffUTCTime end start)
  case result of
    Right resp -> do
      let mu = assistantUsage resp
          meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
      writeChan chan $
        Just
          CallFinished
            { eventId = eid
            , timestamp = end
            , provider = m ^. #provider
            , model = (resp ^. #model) ^. #modelId
            , latencyMs = latency
            , inputTokens = fmap Usage.inputTokens mu
            , outputTokens = fmap Usage.outputTokens mu
            , usd = if meaningfulCost then fmap (usdAsScientific . Usage.cost) mu else Nothing
            }
      writeChan chan Nothing
      takeMVar done
      pure resp
    Left (e :: SomeException) -> do
      writeChan chan $
        Just
          CallFailed
            { eventId = eid
            , timestamp = end
            , provider = m ^. #provider
            , model = m ^. #modelId
            , latencyMs = latency
            , errorMessage = Text.pack (displayException e)
            }
      writeChan chan Nothing
      takeMVar done
      throwIO e

-- | Convenience: combine tracing with the call-log persistence in
-- one call. Traces the call, then appends a 'CallLogEntry' to the
-- given handle.
runRequestWith
  :: MonadUnliftIO m
  => TraceSink
  -> CallLogHandle
  -> Model
  -> Context
  -> Options
  -> m Response
runRequestWith sink h m ctx opts = do
  resp <- withTrace sink m ctx opts
  now <- liftIO getCurrentTime
  let mu = assistantUsage resp
      meaningfulCost = maybe False (\u -> usdRat (Usage.cost u) > 0) mu
      entry =
        CallLogEntry
          { timestamp = now
          , provider = m ^. #provider
          , model = m ^. #modelId
          , inputTokens = mu >>= positiveNat . Usage.inputTokens
          , outputTokens = mu >>= positiveNat . Usage.outputTokens
          , cachedInputTokens = mu >>= positiveNat . Usage.cacheReadTokens
          , reasoningTokens = mu >>= Usage.reasoningTokens
          , usd = if meaningfulCost then fmap (usdAsScientific . Usage.cost) mu else Nothing
          , latencyMs = resp ^. #latencyMs
          , promptSummary = summarizeContext ctx
          }
  appendEntry h entry
  pure resp

-- | Project the assistant turn's 'Usage' out of a response. Returns
-- 'Nothing' when the response carries a non-assistant message
-- (which providers never produce in practice).
assistantUsage :: Response -> Maybe Usage
assistantUsage resp = case resp ^. #message of
  AssistantMessage {usage = u} -> Just u
  _ -> Nothing

-- | 'Cost.usd' accessor named to avoid colliding with the
-- 'TraceEvent.usd' field selector.
usdRat :: Cost.Cost -> Rational
usdRat = Cost.usd

-- | 'Just n' when @n > 0@, otherwise 'Nothing'. Keeps zero-valued
-- counters out of the trace event when the dimension was not
-- exercised.
positiveNat :: Natural -> Maybe Natural
positiveNat 0 = Nothing
positiveNat n = Just n

-- | The effective max-output cap: 'Options.maxTokens' when set,
-- otherwise the model's published 'maxOutputTokens'.
resolvedMaxTokens :: Model -> Options -> Natural
resolvedMaxTokens m opts = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)

-- | Return a short hex id unique within the current process.
-- Combines the low 16 bits of POSIX seconds at first-access with the
-- low 16 bits of a monotonically increasing counter, formatted as 8
-- hex chars.
newEventId :: IO Text
newEventId = do
  n <- atomicModifyIORef' eventCounter (\k -> (k + 1, k))
  let raw :: Word
      raw = (eventBase .&. 0xFFFF) `unsafeShiftL` 16 .|. (n .&. 0xFFFF)
      hex = showHex raw ""
      padded = replicate (8 - length hex) '0' <> hex
  pure (Text.pack padded)

eventCounter :: IORef Word
eventCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE eventCounter #-}

eventBase :: Word
eventBase = unsafePerformIO $ do
  t <- getPOSIXTime
  pure (fromIntegral (floor t :: Integer))
{-# NOINLINE eventBase #-}

