-- | The provider registry — the dispatch surface that replaces the
-- prior 'Baikai.Provider' typeclass and 'SomeProvider' existential.
--
-- An 'ApiProvider' is the per-API handler: a closure that consumes
-- @(Model, Context, Options)@ and returns a 'Response'. The registry
-- is a top-level 'IORef' keyed by 'Api' tag; vendor packages call
-- 'registerApiProvider' from their @register :: IO ()@ entry points,
-- typically once from the caller's @main@.
--
-- 'completeRequest' looks the handler up by the 'Model'\'s 'Api' tag
-- and dispatches; it throws 'Baikai.Error.ProviderError' when no
-- handler is registered for that tag.
--
-- EP-3 will add a @stream@ field on 'ApiProvider' and reduce
-- 'complete' to a draining wrapper around the stream.
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
import Control.Exception (throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import System.IO.Unsafe (unsafePerformIO)

-- | A per-API handler. 'complete' is the synchronous dispatch entry
-- point that EP-3 will derive from a streaming primitive; in EP-2 it
-- is the only entry point.
data ApiProvider = ApiProvider
  { apiTag :: !Api
  , complete :: Model -> Context -> Options -> IO Response
  }

-- | Process-global handler map. The 'unsafePerformIO' + 'NOINLINE'
-- pattern mirrors 'Baikai.Trace'\'s @eventCounter@; the registry is a
-- single shared 'IORef' for the lifetime of the process.
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

-- | Dispatch a request through the registered handler for the
-- model's 'Api' tag. Throws 'ProviderError' when no handler is
-- registered for that tag.
completeRequest :: Model -> Context -> Options -> IO Response
completeRequest m ctx opts = do
  mProvider <- lookupApiProvider (api m)
  case mProvider of
    Just p -> complete p m ctx opts
    Nothing ->
      throwIO $
        ProviderError ("No provider registered for API: " <> renderApi (api m))
