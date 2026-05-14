-- | The provider registry — the dispatch surface that replaces the
-- prior 'Baikai.Provider' typeclass and 'SomeProvider' existential.
--
-- An 'ApiProvider' is the per-API handler. EP-3 promotes 'stream' to
-- the primary method: every handler exposes a streaming producer
-- that emits 'AssistantMessageEvent' values, and 'complete' is the
-- synchronous draining wrapper (typically
-- @streamingComplete . stream@). The registry is a top-level
-- 'IORef' keyed by 'Api' tag; vendor packages call
-- 'registerApiProvider' from their @register :: IO ()@ entry
-- points, typically once from the caller's @main@.
--
-- 'completeRequest' looks the handler up by the 'Model'\'s 'Api'
-- tag and dispatches; it throws 'Baikai.Error.ProviderError' when
-- no handler is registered for that tag.
module Baikai.Provider.Registry
  ( ApiProvider (..)
  , registerApiProvider
  , lookupApiProvider
  , completeRequest
  ) where

import Baikai.Api (Api, renderApi)
import Baikai.Context (Context)
import Baikai.Error (BaikaiError (..))
import Baikai.Model (Model (..))
import Baikai.Options (Options)
import Baikai.Response (Response)
import Baikai.Stream.Event (AssistantMessageEvent)
import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Streamly.Data.Stream (Stream)
import System.IO.Unsafe (unsafePerformIO)

-- | A per-API handler. 'stream' is the primary streaming
-- entry point; 'complete' is the synchronous draining wrapper,
-- typically @streamingComplete . stream@ from "Baikai.Stream".
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , stream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
  , complete :: Model -> Context -> Options -> IO Response
  }

-- | Process-global handler map. The 'unsafePerformIO' + 'NOINLINE'
-- pattern mirrors 'Baikai.Trace'\'s @eventCounter@; the registry is
-- a single shared 'IORef' for the lifetime of the process.
registry :: IORef (Map Api ApiProvider)
registry = unsafePerformIO (newIORef Map.empty)
{-# NOINLINE registry #-}

-- | Install (or replace) a handler. Idempotent for the same 'Api'
-- tag — calling 'registerApiProvider' twice for the same tag keeps
-- only the second handler.
registerApiProvider :: ApiProvider -> IO ()
registerApiProvider p =
  atomicModifyIORef' registry $ \m -> (Map.insert (apiTag p) p m, ())

-- | Look up the handler registered for an 'Api' tag.
lookupApiProvider :: Api -> IO (Maybe ApiProvider)
lookupApiProvider tag = Map.lookup tag <$> readIORef registry

-- | Dispatch a synchronous request through the registered handler
-- for the model's 'Api' tag. Throws 'ProviderError' when no handler
-- is registered for that tag.
completeRequest :: Model -> Context -> Options -> IO Response
completeRequest m ctx opts = do
  mProvider <- lookupApiProvider (api m)
  case mProvider of
    Just p -> complete p m ctx opts
    Nothing ->
      throwIO $
        ProviderError ("No provider registered for API: " <> renderApi (api m))
