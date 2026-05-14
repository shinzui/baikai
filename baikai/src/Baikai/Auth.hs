{-# LANGUAGE LambdaCase #-}

-- | API key sourcing for provider constructors.
--
-- Providers accept an 'ApiKeySource' rather than a raw 'Text' so test code can
-- supply a literal token and production code can defer to an environment variable.
-- The lookup happens lazily inside 'resolveApiKey'; constructing an 'ApiKeyEnv'
-- value does not read the environment.
module Baikai.Auth
  ( ApiKeySource (..)
  , resolveApiKey
  ) where

import Baikai.Error (BaikaiError (..))
import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified System.Environment as Environment

data ApiKeySource
  = ApiKeyLiteral !Text
  | ApiKeyEnv !String
  deriving stock (Eq, Show)

-- | Resolve a key source to a plain 'Text'. Throws 'ProviderError' (a
-- constructor of 'BaikaiError') if 'ApiKeyEnv' is used and the named variable
-- is unset.
resolveApiKey :: MonadIO m => ApiKeySource -> m Text
resolveApiKey (ApiKeyLiteral t) = pure t
resolveApiKey (ApiKeyEnv name) = liftIO $
  Environment.lookupEnv name >>= \case
    Just v -> pure (Text.pack v)
    Nothing -> throwIO (ProviderError ("env var " <> Text.pack name <> " is not set"))
