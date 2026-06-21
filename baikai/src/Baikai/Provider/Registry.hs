-- | The provider registry — the dispatch surface that replaces the
-- prior 'Baikai.Provider' typeclass and 'SomeProvider' existential.
--
-- An 'ApiProvider' is the per-API handler. EP-3 promotes 'stream' to
-- the primary method: every handler exposes a streaming producer
-- that emits 'AssistantMessageEvent' values, and 'complete' is the
-- synchronous draining wrapper (typically @streamingComplete . stream@).
-- Callers can use an explicit 'ProviderRegistry' handle to isolate handler
-- sets, or use the global convenience registry for simple scripts.
--
-- 'completeRequest' looks the handler up by the 'Model'\'s 'Api'
-- tag and dispatches; it throws a 'Baikai.Error.BaikaiError' in the
-- 'Baikai.Error.ProviderUnavailable' category when no handler is
-- registered for that tag.
module Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    newProviderRegistry,
    globalProviderRegistry,
    registerApiProviderWith,
    registerApiProvider,
    lookupApiProviderWith,
    lookupApiProvider,
    completeRequestWith,
    completeRequest,
  )
where

import Baikai.Api (Api, renderApi)
import Baikai.Context (Context)
import Baikai.Error (providerUnavailable)
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
  { apiTag :: !Api,
    stream :: !(Model -> Context -> Options -> Stream IO AssistantMessageEvent),
    complete :: !(Model -> Context -> Options -> IO Response)
  }

-- | A mutable provider registry handle. Each handle owns its own handler map,
-- so tests and applications can maintain isolated provider sets in one process.
newtype ProviderRegistry = ProviderRegistry
  { registryRef :: IORef (Map Api ApiProvider)
  }

-- | Construct an empty provider registry.
newProviderRegistry :: IO ProviderRegistry
newProviderRegistry = ProviderRegistry <$> newIORef Map.empty

-- | Process-global handler registry used by the legacy convenience functions.
-- The 'unsafePerformIO' + 'NOINLINE' pattern mirrors 'Baikai.Trace'\'s
-- @eventCounter@; this is a single shared handle for the lifetime of the
-- process.
globalProviderRegistry :: ProviderRegistry
globalProviderRegistry = unsafePerformIO newProviderRegistry
{-# NOINLINE globalProviderRegistry #-}

-- | Install (or replace) a handler. Idempotent for the same 'Api'
-- tag — calling 'registerApiProviderWith' twice for the same tag keeps only
-- the second handler.
registerApiProviderWith :: ProviderRegistry -> ApiProvider -> IO ()
registerApiProviderWith reg p =
  atomicModifyIORef' (registryRef reg) $ \m -> (Map.insert (apiTag p) p m, ())

-- | Install (or replace) a handler in the process-global registry.
registerApiProvider :: ApiProvider -> IO ()
registerApiProvider = registerApiProviderWith globalProviderRegistry

-- | Look up the handler registered for an 'Api' tag.
lookupApiProviderWith :: ProviderRegistry -> Api -> IO (Maybe ApiProvider)
lookupApiProviderWith reg tag = Map.lookup tag <$> readIORef (registryRef reg)

-- | Look up the handler registered for an 'Api' tag in the process-global
-- registry.
lookupApiProvider :: Api -> IO (Maybe ApiProvider)
lookupApiProvider = lookupApiProviderWith globalProviderRegistry

-- | Dispatch a synchronous request through the registered handler
-- for the model's 'Api' tag. Throws a 'ProviderUnavailable' error when no handler
-- is registered for that tag.
completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
completeRequestWith reg m ctx opts = do
  mProvider <- lookupApiProviderWith reg (api m)
  case mProvider of
    Just p -> complete p m ctx opts
    Nothing ->
      throwIO $
        providerUnavailable ("No provider registered for API: " <> renderApi (api m))

-- | Dispatch a synchronous request through the process-global registry.
completeRequest :: Model -> Context -> Options -> IO Response
completeRequest = completeRequestWith globalProviderRegistry
