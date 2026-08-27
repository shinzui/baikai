-- | __Exposed with no stability guarantees.__ This module is exposed so
-- the test suites can drive the transport without a socket, and so
-- sibling packages can reuse its pieces; it is not part of the public
-- API and may change in /any/ release without a PVP major bump.
--
-- Transport settings, header assembly and key resolution for the
-- Anthropic Messages API.
module Baikai.Provider.Claude.Transport
  ( getClientEnvCached,
    cachedClientEnvCount,
    requestHeaders,
    resolveKey,
    runWithTimeout,
    sessionAffinityValue,
  )
where

import Baikai.Auth qualified as Auth
import Baikai.Compat (AnthropicMessagesCompat (..))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Error (BaikaiError (..), ErrorCategory (..), authError, invalidRequest)
import Baikai.Http (cachedClientEnvCount, getClientEnvCached)
import Baikai.Message qualified as Msg
import Baikai.Model (Model (..))
import Baikai.Options (Options (..))
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Network.HTTP.Types.Header (RequestHeaders)
import System.Timeout qualified as Timeout

requestHeaders ::
  Text ->
  Maybe Text ->
  AnthropicMessagesCompat ->
  Context ->
  Model ->
  Options ->
  RequestHeaders
requestHeaders apiKey anthropicVersion compat ctx m opts =
  applyHeaderOverrides providerHeaders (Map.toList (m ^. #headers) <> Map.toList (opts ^. #headers))
  where
    providerHeaders =
      maybe
        id
        (\v -> (("anthropic-version", Text.encodeUtf8 v) :))
        anthropicVersion
        ( sessionHeaders
            <> [ ("x-api-key", Text.encodeUtf8 apiKey),
                 ("Accept", "text/event-stream"),
                 ("Content-Type", "application/json")
               ]
        )
    sessionHeaders =
      if sendSessionAffinityHeaders compat
        then [("x-session-affinity", Text.encodeUtf8 (sessionAffinityValue ctx))]
        else []

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

sessionAffinityValue :: Context -> Text
sessionAffinityValue ctx =
  let digest = Hash.hash (Text.encodeUtf8 (affinitySeed ctx)) :: Digest SHA256
   in Text.pack (show digest)

affinitySeed :: Context -> Text
affinitySeed ctx =
  Text.intercalate
    "\n"
    [ maybe "" id (ctx ^. #systemPrompt),
      firstUserText (ctx ^. #messages)
    ]

firstUserText :: Vector.Vector Msg.Message -> Text
firstUserText =
  maybe "" id . foldr firstText Nothing . Vector.toList
  where
    firstText msg acc =
      case msg of
        Msg.UserMessage Msg.UserPayload {Msg.content = content} ->
          case firstTextContent content of
            Just t -> Just t
            Nothing -> acc
        _ -> acc

firstTextContent :: Vector.Vector Content.UserContent -> Maybe Text
firstTextContent =
  foldr firstText Nothing . Vector.toList
  where
    firstText block acc =
      case block of
        Content.UserText Content.TextContent {Content.text = t} -> Just t
        _ -> acc

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
