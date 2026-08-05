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
-- tag and dispatches; when no handler is registered it returns an
-- error-shaped 'Response' in the 'Baikai.Error.ProviderUnavailable'
-- category.
module Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    newProviderRegistry,
    newProviderRegistryFrom,
    globalProviderRegistry,
    registerApiProviderWith,
    registerApiProvider,
    assertRegistered,
    lookupApiProviderWith,
    lookupApiProvider,
    completeRequestWith,
    completeRequest,
    runToolLoopWith,
    runToolLoop,
    completeText,
  )
where

import Baikai.Api (Api, renderApi)
import Baikai.Content (AssistantContent (..), ToolCall)
import Baikai.Context (Context, appendToolResult, contextOf)
import Baikai.Error (providerUnavailable)
import Baikai.Evidence (noThinkingRequested)
import Baikai.Evidence qualified as Evidence
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..), ToolResult, toolResultErrorText, user)
import Baikai.Model (Model)
import Baikai.Model qualified as Model
import Baikai.Options (Options, emptyOptions)
import Baikai.Response (Response (..), errorResponse, flattenAssistantBlocks, flattenAssistantText, responseError)
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event (AssistantMessageEvent)
import Control.Exception qualified as Exception
import Control.Monad (forM, unless)
import Data.Foldable (traverse_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
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

-- | Construct a registry pre-populated with the given providers. Later entries
-- win on tag collisions, matching 'registerApiProviderWith'.
newProviderRegistryFrom :: [ApiProvider] -> IO ProviderRegistry
newProviderRegistryFrom providers = do
  reg <- newProviderRegistry
  traverse_ (registerApiProviderWith reg) providers
  pure reg

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

-- | Startup preflight: throw 'Baikai.Error.ProviderUnavailable' listing every
-- requested API tag that has no registered handler.
assertRegistered :: ProviderRegistry -> [Api] -> IO ()
assertRegistered reg tags = do
  missing <-
    fmap concat $
      forM tags $ \tag -> do
        found <- lookupApiProviderWith reg tag
        pure $ case found of
          Nothing -> [tag]
          Just _ -> []
  unless (null missing) $
    Exception.throwIO
      ( providerUnavailable
          ( "no provider registered for: "
              <> Text.intercalate ", " (renderApi <$> missing)
          )
      )

-- | Look up the handler registered for an 'Api' tag.
lookupApiProviderWith :: ProviderRegistry -> Api -> IO (Maybe ApiProvider)
lookupApiProviderWith reg tag = Map.lookup tag <$> readIORef (registryRef reg)

-- | Look up the handler registered for an 'Api' tag in the process-global
-- registry.
lookupApiProvider :: Api -> IO (Maybe ApiProvider)
lookupApiProvider = lookupApiProviderWith globalProviderRegistry

-- | Dispatch a synchronous request through the registered handler
-- for the model's 'Api' tag. Returns an error-shaped 'Response' when
-- no handler is registered for that tag.
completeRequestWith :: ProviderRegistry -> Model -> Context -> Options -> IO Response
completeRequestWith reg m ctx opts = do
  mProvider <- lookupApiProviderWith reg (Model.api m)
  case mProvider of
    Just p -> complete p m ctx opts
    Nothing -> do
      now <- getCurrentTime
      -- "No provider was registered" is a fact about the call, so a
      -- caller who asked for evidence gets a record of it. Nothing was
      -- sent, so the digests are over 'Build.dispatchEnvelope'.
      let detail = "No provider registered for API: " <> renderApi (Model.api m)
          err = providerUnavailable detail
      ev <-
        Build.minimalEvidence
          m
          opts
          (Build.transportForModel m)
          noThinkingRequested
          (Build.dispatchEnvelope m opts)
          now
          now
          Evidence.CallFailed
          (Just err)
      let resp = errorResponse m now 0 err
      pure resp {evidence = ev}

-- | Dispatch a synchronous request through the process-global registry.
completeRequest :: Model -> Context -> Options -> IO Response
completeRequest = completeRequestWith globalProviderRegistry

-- | Drive a tool-using conversation through the process-global registry.
--
-- The returned 'Context' contains the input context plus only fully resolved
-- assistant/tool-result exchanges, so it is always valid to replay. The final
-- 'Response' is not appended; callers that want the full transcript can use
-- 'Baikai.Context.addResponse'. 'Options' is passed unchanged each turn, so
-- forcing tools in options can exhaust the budget; loops should usually let
-- the provider choose tools automatically.
runToolLoop ::
  Int ->
  (ToolCall -> IO ToolResult) ->
  Model ->
  Context ->
  Options ->
  IO (Context, Response)
runToolLoop = runToolLoopWith globalProviderRegistry

-- | Drive a tool-using conversation through an explicit registry.
--
-- The turn budget is clamped to at least one model call. Synchronous dispatcher
-- exceptions become error tool results so the model can recover; asynchronous
-- exceptions are rethrown. Dispatchers should return 'toolResultErrorText' for
-- unknown tool names rather than throwing.
runToolLoopWith ::
  ProviderRegistry ->
  Int ->
  (ToolCall -> IO ToolResult) ->
  Model ->
  Context ->
  Options ->
  IO (Context, Response)
runToolLoopWith reg budget dispatcher model ctx0 opts =
  go (max 1 budget) ctx0
  where
    go remaining ctx = do
      resp <- completeRequestWith reg model ctx opts
      if shouldStop remaining resp
        then pure (ctx, resp)
        else do
          ctx' <- appendToolResult ctx resp (safeDispatcher dispatcher)
          go (remaining - 1) ctx'

    shouldStop remaining resp =
      responseError resp /= Nothing
        || responseStopReason resp /= ToolUse
        || Vector.null (responseToolCalls resp)
        || remaining <= 1

-- | One-shot text completion through the global registry. Throws the
-- 'Baikai.Error.BaikaiError' when the response is error-shaped.
completeText :: Model -> Text -> IO Text
completeText model prompt = do
  resp <- completeRequest model (contextOf [user prompt]) emptyOptions
  case responseError resp of
    Just err -> Exception.throwIO err
    Nothing -> pure (flattenAssistantText (flattenAssistantBlocks resp))

safeDispatcher :: (ToolCall -> IO ToolResult) -> ToolCall -> IO ToolResult
safeDispatcher dispatcher tc = do
  result <- trySync (dispatcher tc)
  case result of
    Right ok -> pure ok
    Left e -> pure (toolResultErrorText (Text.pack (Exception.displayException e)))

trySync :: IO a -> IO (Either Exception.SomeException a)
trySync action = do
  result <- Exception.try action
  case result of
    Left e
      | Just (Exception.SomeAsyncException _) <-
          (Exception.fromException e :: Maybe Exception.SomeAsyncException) ->
          Exception.throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)

responseStopReason :: Response -> StopReason
responseStopReason Response {message = AssistantPayload {stopReason = sr}} = sr

responseToolCalls :: Response -> Vector.Vector ToolCall
responseToolCalls Response {message = AssistantPayload {content = blocks}} =
  Vector.mapMaybe toolCallOf blocks
  where
    toolCallOf (AssistantToolCall tc) = Just tc
    toolCallOf _ = Nothing
