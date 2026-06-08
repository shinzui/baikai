{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeFamilies #-}

-- | A thin, policy-free @effectful@ binding over baikai's transport.
--
-- This module exposes a single dynamic effect, 'Baikai', whose operations mirror
-- baikai's transport functions, plus two interpreters that run those operations
-- against a real (global) or isolated provider registry. It carries NO policy:
-- failures propagate exactly as baikai produces them — the blocking path
-- ('complete') throws 'Baikai.Error.BaikaiError'; the streaming paths
-- ('streamCollect', 'streamEach') surface baikai's terminal @EventError@ in-band.
-- Retries, caching, budgets, rate limiting, and error remapping belong one layer
-- up, in terms of this effect.
module Baikai.Effectful
  ( -- * The effect
    Baikai (..),

    -- * Operations
    complete,
    streamCollect,
    streamEach,

    -- * Interpreters
    runBaikai,
    runBaikaiWith,

    -- * Re-exports of the baikai request/response vocabulary
    Model,
    Context,
    Options,
    Response,
    AssistantMessageEvent,
  )
where

import Baikai (AssistantMessageEvent, Context, Model, Options, Response)
import Baikai qualified
import Baikai.Provider.Registry (ProviderRegistry)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret, localSeqUnliftIO, send)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

-- | The provider-neutral baikai transport effect. Operations mirror baikai's
-- transport functions; the interpreter selects the provider registry.
data Baikai :: Effect where
  -- | A blocking completion. Mirrors 'Baikai.completeRequest' — throws
  -- 'Baikai.Error.BaikaiError' on failure.
  Complete :: Model -> Context -> Options -> Baikai m Response
  -- | A streaming completion materialized into the full event list. Mirrors
  -- 'Baikai.streamRequest' drained to a list; a terminal @EventError@ appears
  -- as the last element on failure (baikai does not throw here).
  StreamCollect :: Model -> Context -> Options -> Baikai m [AssistantMessageEvent]
  -- | A streaming completion where each event is handed, in order, to a
  -- caller-supplied callback that runs inside the same effect context.
  StreamEach :: Model -> Context -> Options -> (AssistantMessageEvent -> m ()) -> Baikai m ()

type instance DispatchOf Baikai = 'Dynamic

-- | Issue a blocking completion. Throws baikai's 'Baikai.Error.BaikaiError' on
-- failure, just like 'Baikai.completeRequest' — this binding does not catch it.
complete :: (Baikai :> es) => Model -> Context -> Options -> Eff es Response
complete m c o = send (Complete m c o)

-- | Materialize a streaming completion into the full event list. Convenient when
-- you do not need incremental deltas. Does not throw on provider failure; a
-- terminal 'AssistantMessageEvent' @EventError@ appears as the last element.
streamCollect :: (Baikai :> es) => Model -> Context -> Options -> Eff es [AssistantMessageEvent]
streamCollect m c o = send (StreamCollect m c o)

-- | Stream a completion, invoking the callback on each event in order, inside
-- 'Eff'. Preserves incrementality: the callback sees events as they arrive, in
-- the same effect context as the caller.
streamEach ::
  (Baikai :> es) =>
  Model ->
  Context ->
  Options ->
  (AssistantMessageEvent -> Eff es ()) ->
  Eff es ()
streamEach m c o k = send (StreamEach m c o k)

-- | Interpret 'Baikai' against an explicit provider registry. Requires 'IOE'
-- because the operations are ultimately baikai 'IO' calls. No retries, caching,
-- or error remapping.
runBaikaiWith :: (IOE :> es) => ProviderRegistry -> Eff (Baikai : es) a -> Eff es a
runBaikaiWith reg = interpret $ \env -> \case
  Complete m c o ->
    liftIO (Baikai.completeRequestWith reg m c o)
  StreamCollect m c o ->
    liftIO (Stream.toList (Baikai.streamRequestWith reg m c o))
  StreamEach m c o k ->
    -- @k@ is the caller's @Eff@ action (a higher-order argument). @localSeqUnliftIO@
    -- gives a function @unlift :: forall r. Eff localEs r -> IO r@ valid for the
    -- duration of the block, so we run @k event@ as IO inside a streamly fold that
    -- drains the stream — one callback invocation per event, in order.
    localSeqUnliftIO env $ \unlift ->
      Stream.fold
        (Fold.drainMapM (\event -> unlift (k event)))
        (Baikai.streamRequestWith reg m c o)

-- | Interpret 'Baikai' against baikai's process-global provider registry.
runBaikai :: (IOE :> es) => Eff (Baikai : es) a -> Eff es a
runBaikai = runBaikaiWith Baikai.globalProviderRegistry
