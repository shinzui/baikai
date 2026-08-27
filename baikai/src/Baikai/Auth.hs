{-# LANGUAGE LambdaCase #-}

-- | API key sourcing for provider constructors.
--
-- Providers accept an 'ApiKeySource' rather than a raw 'Text' so test code can
-- supply a literal token and production code can defer to an environment variable.
-- The lookup happens lazily inside 'resolveApiKey'; constructing an 'ApiKeyEnv'
-- value does not read the environment.
module Baikai.Auth
  ( ApiKeySource (..),
    defaultApiKeyEnvForBaseUrl,
    renderApiKeySourceForDebug,
    resolveApiKey,

    -- * Redacting credentials that travel in headers
    redactedMarker,
    isCredentialHeader,
    redactHeaderValues,
  )
where

import Baikai.Error (authError)
import Baikai.Header (HeaderName, renderHeaderName)
import Baikai.Url (hostMatchesSuffix, urlHost)
import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment qualified as Environment

data ApiKeySource
  = ApiKeyLiteral !Text
  | -- | 'String' rather than 'Text' because
    -- 'System.Environment.lookupEnv' takes one; converting here would
    -- only move the conversion to every call site.
    ApiKeyEnv !String
  | ApiKeyEnvChain ![String]
  deriving stock (Eq)

instance Show ApiKeySource where
  show = Text.unpack . renderApiKeySourceForDebug

instance ToJSON ApiKeySource where
  toJSON (ApiKeyLiteral _) =
    object
      [ "source" .= ("literal-redacted" :: Text)
      ]
  toJSON (ApiKeyEnv name) =
    object
      [ "source" .= ("env" :: Text),
        "name" .= name
      ]
  toJSON (ApiKeyEnvChain names) =
    object
      [ "source" .= ("env-chain" :: Text),
        "names" .= names
      ]

-- | Conventional API-key environment variable for a known provider
-- host. Unknown hosts return 'Nothing' so callers can require an
-- explicit 'ApiKeySource' instead of leaking another provider's
-- credential.
defaultApiKeyEnvForBaseUrl :: Text -> Maybe String
defaultApiKeyEnvForBaseUrl baseUrl = do
  host <- urlHost baseUrl
  match host
  where
    match host
      | hostMatchesSuffix host "api.openai.com" = Just "OPENAI_API_KEY"
      | hostMatchesSuffix host "api.deepseek.com" = Just "DEEPSEEK_API_KEY"
      | hostMatchesSuffix host "openrouter.ai" = Just "OPENROUTER_API_KEY"
      | hostMatchesSuffix host "together.xyz" = Just "TOGETHER_API_KEY"
      | hostMatchesSuffix host "together.ai" = Just "TOGETHER_API_KEY"
      | hostMatchesSuffix host "z.ai" = Just "ZAI_API_KEY"
      | hostMatchesSuffix host "dashscope.aliyuncs.com" = Just "DASHSCOPE_API_KEY"
      | hostMatchesSuffix host "dashscope-intl.aliyuncs.com" = Just "DASHSCOPE_API_KEY"
      | hostMatchesSuffix host "qwen.ai" = Just "DASHSCOPE_API_KEY"
      | hostMatchesSuffix host "api.anthropic.com" = Just "ANTHROPIC_API_KEY"
      | hostMatchesSuffix host "fireworks.ai" = Just "FIREWORKS_API_KEY"
      | otherwise = Nothing

-- | What baikai prints where a credential would otherwise appear.
--
-- One marker everywhere, so a reader who has seen it once in an
-- @ApiKeyLiteral@ recognises it in a header map.
redactedMarker :: Text
redactedMarker = "<redacted>"

-- | Whether a header name carries a credential, by convention.
--
-- Case-insensitive, and deliberately generous: it matches
-- @authorization@, @api-key@, @apikey@, @token@, @secret@, @cookie@ and
-- @password@ anywhere in the name, and any name ending in @-key@. That
-- over-matches — a header called @x-idempotency-key@ prints as the
-- marker — and over-matching is the safe direction, because this only
-- decides what is /printed/. The header itself is untouched and is still
-- sent exactly as the caller wrote it.
isCredentialHeader :: Text -> Bool
isCredentialHeader name =
  any (`Text.isInfixOf` lowered) needles || "-key" `Text.isSuffixOf` lowered
  where
    lowered = Text.toLower (Text.strip name)
    needles =
      [ "authorization",
        "api-key",
        "apikey",
        "token",
        "secret",
        "cookie",
        "password"
      ]

-- | Replace the value of every credential-carrying header with
-- 'redactedMarker', leaving the names and every other value alone.
redactHeaderValues :: Map HeaderName Text -> Map HeaderName Text
redactHeaderValues =
  Map.mapWithKey
    ( \name value ->
        if isCredentialHeader (renderHeaderName name) then redactedMarker else value
    )

-- | Render a credential source for logs, test failures, and debugging without
-- exposing literal secret material.
renderApiKeySourceForDebug :: ApiKeySource -> Text
renderApiKeySourceForDebug (ApiKeyLiteral _) = "ApiKeyLiteral " <> redactedMarker
renderApiKeySourceForDebug (ApiKeyEnv name) =
  "ApiKeyEnv " <> Text.pack (show name)
renderApiKeySourceForDebug (ApiKeyEnvChain names) =
  "ApiKeyEnvChain " <> Text.pack (show names)

-- | Resolve a key source to a plain 'Text'. Throws a 'BaikaiError' in the
-- 'Baikai.Error.AuthError' category when no variable yields a key.
--
-- A variable whose value is empty, or is only whitespace, counts as
-- __unset__. An empty key can never authenticate, so reporting it here
-- as an error that names the variable is strictly better than sending
-- @Authorization: Bearer @ and reading a provider's 401 back. A
-- non-empty value is passed through exactly as it was set, whitespace
-- and all: trimming a real key would be a different behaviour change,
-- and one that could silently break a key with a meaningful edge
-- character.
resolveApiKey :: (MonadIO m) => ApiKeySource -> m Text
resolveApiKey (ApiKeyLiteral t) = pure t
resolveApiKey (ApiKeyEnv name) =
  liftIO $
    lookupNonEmptyEnv name >>= \case
      Just v -> pure v
      Nothing ->
        throwIO
          (authError ("env var " <> Text.pack name <> " is not set or is empty"))
resolveApiKey (ApiKeyEnvChain names) =
  liftIO (go names)
  where
    go [] =
      throwIO
        ( authError
            ( "none of the env vars "
                <> renderedNames
                <> " are set (an empty value counts as unset)"
            )
        )
    go (name : rest) = lookupNonEmptyEnv name >>= maybe (go rest) pure
    renderedNames = case names of
      [] -> "<empty>"
      _ -> Text.intercalate ", " (Text.pack <$> names)

-- | 'Environment.lookupEnv' that treats a blank value as absent.
lookupNonEmptyEnv :: String -> IO (Maybe Text)
lookupNonEmptyEnv name = do
  found <- Environment.lookupEnv name
  pure $ case found of
    Just raw | not (Text.null (Text.strip (Text.pack raw))) -> Just (Text.pack raw)
    _ -> Nothing
