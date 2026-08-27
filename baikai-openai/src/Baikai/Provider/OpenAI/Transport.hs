module Baikai.Provider.OpenAI.Transport
  ( getClientEnvCached,
    cachedClientEnvCount,
    requestHeaders,
    resolveKey,
    runWithTimeout,
  )
where

import Baikai.Auth qualified as Auth
import Baikai.Error (BaikaiError (..), ErrorCategory (..), authError, invalidRequest)
import Baikai.Http (cachedClientEnvCount, getClientEnvCached)
import Baikai.Model (Model (..))
import Baikai.Options (Options (..))
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types.Header (RequestHeaders)
import System.Timeout qualified as Timeout

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

-- | Run the transport action under 'Baikai.Options.timeoutMs'.
--
-- 'Nothing' is no bound. A non-positive bound is a caller error and is
-- refused as 'InvalidRequest' /without running the action/, so no
-- connection is opened: 'System.Timeout.timeout' returns immediately at
-- zero and runs unbounded below it, and both spellings used to fail as
-- a retryable 'TransientError' — a classification a retry loop will
-- re-issue forever for a configuration mistake.
runWithTimeout :: Maybe Int -> IO () -> IO (Maybe BaikaiError)
runWithTimeout Nothing action = action >> pure Nothing
runWithTimeout (Just ms) action
  | ms <= 0 =
      pure . Just . invalidRequest $
        "Options.timeoutMs must be positive, got "
          <> Text.pack (show ms)
          <> "; use Nothing for no bound"
  -- ms * 1000 would wrap negative, and a negative interval is silently
  -- "no bound". A bound this large is one in practice.
  | ms > maxBound `div` 1000 = action >> pure Nothing
  | otherwise = do
      result <- Timeout.timeout (ms * 1000) action
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
