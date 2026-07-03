module Baikai.Provider.OpenAI.Transport
  ( getClientEnvCached,
    cachedClientEnvCount,
    requestHeaders,
    resolveKey,
    runWithTimeout,
  )
where

import Baikai.Auth qualified as Auth
import Baikai.Error (BaikaiError (..), ErrorCategory (..), authError)
import Baikai.Model (Model (..))
import Baikai.Options (Options (..))
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as TLS
import Network.HTTP.Types.Header (RequestHeaders)
import Servant.Client qualified as Client
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout qualified as Timeout

getClientEnvCached :: Text -> IO Client.ClientEnv
getClientEnvCached baseUrl =
  modifyMVar clientEnvCache $ \cache ->
    case Map.lookup baseUrl cache of
      Just env -> pure (cache, env)
      Nothing -> do
        env <- newClientEnv baseUrl
        pure (Map.insert baseUrl env cache, env)

cachedClientEnvCount :: IO Int
cachedClientEnvCount =
  modifyMVar clientEnvCache $ \cache -> pure (cache, Map.size cache)

requestHeaders :: Text -> Model -> Options -> RequestHeaders
requestHeaders apiKey m opts =
  applyHeaderOverrides
    [ ("Authorization", Text.encodeUtf8 ("Bearer " <> apiKey)),
      ("Accept", "text/event-stream"),
      ("Content-Type", "application/json")
    ]
    (Map.toList (m ^. #headers) <> Map.toList (opts ^. #headers))

resolveKey :: Text -> Options -> IO Text
resolveKey baseUrl opts = case opts ^. #apiKey of
  Just source -> Auth.resolveApiKey source
  Nothing -> case Auth.defaultApiKeyEnvForBaseUrl baseUrl of
    Just name -> Auth.resolveApiKey (Auth.ApiKeyEnv name)
    Nothing ->
      throwIO $
        authError $
          "no default API key env is known for " <> baseUrl <> "; set Options.apiKey explicitly"

runWithTimeout :: Maybe Int -> IO () -> IO (Maybe BaikaiError)
runWithTimeout Nothing action = action >> pure Nothing
runWithTimeout (Just ms) action = do
  result <- Timeout.timeout (max 0 ms * 1000) action
  pure $ case result of
    Just () -> Nothing
    Nothing -> Just (timeoutError ms)

timeoutError :: Int -> BaikaiError
timeoutError ms =
  BaikaiError
    { category = TransientError,
      message = "provider stream exceeded timeoutMs=" <> Text.pack (show ms),
      httpStatus = Nothing,
      retryAfterSeconds = Nothing,
      exitCode = Nothing
    }

newClientEnv :: Text -> IO Client.ClientEnv
newClientEnv baseUrl = do
  parsed <- Client.parseBaseUrl (Text.unpack baseUrl)
  manager <-
    TLS.newTlsManagerWith
      TLS.tlsManagerSettings
        { HTTP.managerResponseTimeout = HTTP.responseTimeoutNone
        }
  pure (Client.mkClientEnv manager parsed)

applyHeaderOverrides ::
  RequestHeaders ->
  [(Text, Text)] ->
  RequestHeaders
applyHeaderOverrides =
  foldl addHeader
  where
    addHeader headers (name, value) =
      let nameBytes = Text.encodeUtf8 name
          ciName = CI.mk nameBytes
       in (ciName, Text.encodeUtf8 value) : filter ((/= ciName) . fst) headers

{-# NOINLINE clientEnvCache #-}
clientEnvCache :: MVar (Map.Map Text Client.ClientEnv)
clientEnvCache = unsafePerformIO (newMVar Map.empty)
