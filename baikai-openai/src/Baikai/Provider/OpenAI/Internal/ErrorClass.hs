-- | Internal failure classification for the OpenAI provider.
--
-- This module is exposed for provider tests and debugging, but it is
-- not part of baikai's PVP-stable application surface. Names, types,
-- and semantics here may change in minor releases.
--
-- 'classifyException' handles any exception the worker catches from the
-- transport — @http-client@, TLS and socket failures, all delegated to
-- "Baikai.Provider.Transport.Classify" so both providers classify them
-- identically. 'classifyErrorText' handles an error that arrives
-- mid-stream as a plain text message.
module Baikai.Provider.OpenAI.Internal.ErrorClass
  ( classifyException,
    classifyErrorText,
  )
where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    bodyIndicatesOverflow,
    httpError,
    providerError,
  )
import Baikai.Provider.Transport.Classify (classifyTransportException)
import Control.Exception (SomeException, displayException)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | Convert any exception caught while driving the OpenAI-compatible
-- transport into a categorised 'BaikaiError'.
--
-- Recognised transport failures — every @http-client@ 'HttpException'
-- constructor, a raw socket 'IOException' from the body read, and a raw
-- or wrapped TLS exception — are classified by the shared core rule.
-- Anything else is not a transport failure at all (a programming error
-- in a callback, say) and degrades to a generic provider error carrying
-- the displayed exception text, so it is never reported as retryable.
classifyException :: SomeException -> BaikaiError
classifyException ex =
  fromMaybe
    (providerError (Text.pack (displayException ex)))
    (classifyTransportException ex)

-- | Best-effort classification of an OpenAI streamed error message,
-- which arrives as plain text without an HTTP status. Returns 'Nothing'
-- for empty text (the caller keeps the raw message and 'errorInfo'
-- stays absent).
classifyErrorText :: Text -> Maybe BaikaiError
classifyErrorText t
  | Just e <- classifySdkHttpText t = Just e
  | Text.null (Text.strip t) = Nothing
  | otherwise = Just (providerError t) {category = cat}
  where
    lower = Text.toLower t
    has needle = needle `Text.isInfixOf` lower
    cat
      | bodyIndicatesOverflow t = ContextOverflow
      | has "rate limit" || has "rate_limit" = RateLimited
      | has "overloaded" || has "server_error" || has "service unavailable" = TransientError
      | has "insufficient_quota"
          || has "invalid api key"
          || has "incorrect api key"
          || has "invalid_api_key" =
          AuthError
      | otherwise = OtherError

classifySdkHttpText :: Text -> Maybe BaikaiError
classifySdkHttpText raw = do
  rest <- Text.stripPrefix "HTTP error " raw
  let (codeText, afterCode) = Text.breakOn " " rest
  code <- readMaybe (Text.unpack codeText)
  let body = case Text.breakOn ": " afterCode of
        (_, sepBody)
          | not (Text.null sepBody) -> Text.drop 2 sepBody
        _ -> ""
  pure (httpError code Nothing body)
