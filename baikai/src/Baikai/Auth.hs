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
  )
where

import Baikai.Compat (hostMatchesSuffix, urlHost)
import Baikai.Error (authError)
import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (ToJSON (toJSON), object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment qualified as Environment

data ApiKeySource
  = ApiKeyLiteral !Text
  | ApiKeyEnv !String
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

-- | Render a credential source for logs, test failures, and debugging without
-- exposing literal secret material.
renderApiKeySourceForDebug :: ApiKeySource -> Text
renderApiKeySourceForDebug (ApiKeyLiteral _) = "ApiKeyLiteral <redacted>"
renderApiKeySourceForDebug (ApiKeyEnv name) =
  "ApiKeyEnv " <> Text.pack (show name)

-- | Resolve a key source to a plain 'Text'. Throws a 'BaikaiError' in the
-- 'Baikai.Error.AuthError' category if 'ApiKeyEnv' is used and the named variable
-- is unset.
resolveApiKey :: (MonadIO m) => ApiKeySource -> m Text
resolveApiKey (ApiKeyLiteral t) = pure t
resolveApiKey (ApiKeyEnv name) =
  liftIO $
    Environment.lookupEnv name >>= \case
      Just v -> pure (Text.pack v)
      Nothing -> throwIO (authError ("env var " <> Text.pack name <> " is not set"))
