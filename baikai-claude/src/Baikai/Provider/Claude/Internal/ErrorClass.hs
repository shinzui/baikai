-- | Internal failure classification for the Anthropic provider.
--
-- This module is exposed for provider tests and debugging, but it is
-- not part of baikai's PVP-stable application surface. Names, types,
-- and semantics here may change in minor releases.
--
-- Two entry points cover the two ways a failure reaches the provider:
-- 'classifyException' for any exception the worker catches from the
-- transport — @http-client@, TLS and socket failures, all delegated to
-- "Baikai.Provider.Transport.Classify" so both providers classify them
-- identically — and 'classifyErrorValue' for an Anthropic @error@ event
-- that arrives mid-stream as a JSON 'Value'.
module Baikai.Provider.Claude.Internal.ErrorClass
  ( classifyException,
    classifyErrorText,
    classifyErrorValue,
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
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Text.Read (readMaybe)

-- | Convert any exception caught while driving the Anthropic transport
-- into a categorised 'BaikaiError'.
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

-- | Classify a mid-stream Anthropic @error@ event. The value is the
-- inner error object, e.g. @{"type":"overloaded_error","message":"…"}@;
-- it may also arrive wrapped under an @"error"@ key. Returns 'Nothing'
-- when no error @type@ can be found (the caller keeps the plain text).
classifyErrorValue :: Value -> Maybe BaikaiError
classifyErrorValue v = do
  let obj = unwrap v
  ty <- stringField "type" obj
  let detail = maybe ty id (stringField "message" obj)
      cat = anthropicTypeToCategory ty detail
  Just (providerError detail) {category = cat}
  where
    unwrap (Object o) = case KeyMap.lookup "error" o of
      Just (Object inner) -> inner
      _ -> o
    unwrap _ = KeyMap.empty
    stringField k o = case KeyMap.lookup k o of
      Just (String t) -> Just t
      _ -> Nothing

-- | Recover HTTP classification from the text shape emitted by the
-- upstream SDK's non-2xx path. The local SSE transport preserves
-- headers and should be preferred; this is a defense-in-depth parser.
classifyErrorText :: Text -> Maybe BaikaiError
classifyErrorText raw = do
  rest <- Text.stripPrefix "HTTP error " raw
  let (codeText, afterCode) = Text.breakOn " " rest
  code <- readMaybe (Text.unpack codeText)
  let body = case Text.breakOn ": " afterCode of
        (_, sepBody)
          | not (Text.null sepBody) -> Text.drop 2 sepBody
        _ -> ""
  pure (httpError code Nothing body)

-- | Map an Anthropic error @type@ string (plus its message, for the
-- overflow special case) to a category.
anthropicTypeToCategory :: Text -> Text -> ErrorCategory
anthropicTypeToCategory ty detail = case ty of
  "authentication_error" -> AuthError
  "permission_error" -> AuthError
  "rate_limit_error" -> RateLimited
  "overloaded_error" -> TransientError
  "api_error" -> TransientError
  "timeout_error" -> TransientError
  "not_found_error" -> InvalidRequest
  "request_too_large" -> ContextOverflow
  "invalid_request_error"
    | bodyIndicatesOverflow detail -> ContextOverflow
    | otherwise -> InvalidRequest
  _
    | bodyIndicatesOverflow detail -> ContextOverflow
    | otherwise -> OtherError
