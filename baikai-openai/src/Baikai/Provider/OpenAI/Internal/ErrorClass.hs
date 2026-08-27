-- | Internal failure classification for the OpenAI provider.
--
-- This module is exposed for provider tests and debugging, but it is
-- not part of baikai's PVP-stable application surface. Names, types,
-- and semantics here may change in minor releases.
--
-- Two entry points cover the two ways a failure reaches the provider.
-- 'classifyException' handles any exception the worker catches from the
-- transport — @http-client@, TLS and socket failures, all delegated to
-- "Baikai.Provider.Transport.Classify" so both providers classify them
-- identically. 'classifyErrorFrame' handles an in-band error frame: a
-- decoded SSE payload on a @2xx@ stream that reports a failure instead
-- of a completion chunk, which is how OpenRouter, DeepSeek and Together
-- report an upstream failure they only learned about after committing
-- to a @200@.
module Baikai.Provider.OpenAI.Internal.ErrorClass
  ( classifyException,
    classifyErrorFrame,
  )
where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    bodyIndicatesOverflow,
    classifyHttpStatusWithBody,
    providerError,
  )
import Baikai.Provider.Transport.Classify (classifyTransportException)
import Control.Applicative ((<|>))
import Control.Exception (SomeException, displayException)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as Text

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

-- | Classify an in-band error frame: a decoded SSE payload on a @2xx@
-- stream whose JSON reports a failure instead of a completion chunk.
--
-- Returns 'Nothing' for anything without an @error@ key, so an ordinary
-- chunk passes through untouched. Detection keys on @error@ alone and
-- not on the absence of @choices@, because OpenRouter sends both: its
-- mid-stream failure frame carries the error object /and/ a @choices@
-- array whose element has @finish_reason: "error"@.
--
-- Precedence inside the frame, most specific first: a numeric @code@ or
-- @status@ of 400 or more is the upstream HTTP status and is classified
-- as one (and recorded in 'httpStatus'); else a string @code@, then a
-- string @type@, is looked up in the vocabulary the compatible hosts
-- share; else the message text is phrase-sniffed; else 'OtherError'. The
-- message always becomes the error's 'message'.
classifyErrorFrame :: Value -> Maybe BaikaiError
classifyErrorFrame (Object o) = do
  errVal <- KeyMap.lookup "error" o
  inner <- case errVal of
    Object e -> Just e
    -- Some hosts send a bare string where the object is documented.
    String s -> Just (KeyMap.singleton "message" (String s))
    _ -> Nothing
  let msg =
        fromMaybe
          "provider sent an error frame without a message"
          (nonEmpty =<< stringField "message" inner)
      status = numberField "code" inner <|> numberField "status" inner
      byName =
        (stringField "code" inner >>= codeToCategory msg)
          <|> (stringField "type" inner >>= codeToCategory msg)
      cat = case status of
        Just n | n >= 400 -> classifyHttpStatusWithBody n Nothing msg
        _ -> fromMaybe (categoryFromMessage msg) byName
  Just (providerError msg) {category = cat, httpStatus = status}
classifyErrorFrame _ = Nothing

nonEmpty :: Text -> Maybe Text
nonEmpty t = if Text.null (Text.strip t) then Nothing else Just t

stringField :: Text -> KeyMap Value -> Maybe Text
stringField k o = case KeyMap.lookup (Key.fromText k) o of
  Just (String t) -> Just t
  _ -> Nothing

-- | An integral JSON number only: a @code@ of @"429"@ as a string is a
-- code name, not a status, and is handled by 'codeToCategory'.
numberField :: Text -> KeyMap Value -> Maybe Int
numberField k o = case KeyMap.lookup (Key.fromText k) o of
  Just (Number n) -> toBoundedInteger (n :: Scientific)
  _ -> Nothing

-- | The @code@ and @type@ vocabulary the OpenAI-compatible hosts share.
-- The message is threaded through only for the overflow special case,
-- where the category depends on what the request actually hit.
codeToCategory :: Text -> Text -> Maybe ErrorCategory
codeToCategory msg raw = case Text.toLower (Text.strip raw) of
  "rate_limit_error" -> Just RateLimited
  "rate_limit_exceeded" -> Just RateLimited
  "tokens" -> Just RateLimited
  "requests" -> Just RateLimited
  "too_many_requests" -> Just RateLimited
  "authentication_error" -> Just AuthError
  "permission_error" -> Just AuthError
  "invalid_api_key" -> Just AuthError
  "insufficient_quota" -> Just AuthError
  "billing_not_active" -> Just AuthError
  "account_deactivated" -> Just AuthError
  "context_length_exceeded" -> Just ContextOverflow
  "request_too_large" -> Just ContextOverflow
  "server_error" -> Just TransientError
  "overloaded_error" -> Just TransientError
  "engine_overloaded" -> Just TransientError
  "service_unavailable" -> Just TransientError
  "timeout" -> Just TransientError
  "upstream_error" -> Just TransientError
  "provider_error" -> Just TransientError
  "invalid_request_error" -> Just (overflowOr InvalidRequest)
  "model_not_found" -> Just (overflowOr InvalidRequest)
  "invalid_value" -> Just (overflowOr InvalidRequest)
  "unsupported_value" -> Just (overflowOr InvalidRequest)
  "missing_required_parameter" -> Just (overflowOr InvalidRequest)
  _ -> Nothing
  where
    overflowOr fallback
      | bodyIndicatesOverflow msg = ContextOverflow
      | otherwise = fallback

-- | The last resort: what the message text says, when the frame named no
-- code or type this classifier knows.
categoryFromMessage :: Text -> ErrorCategory
categoryFromMessage t
  | bodyIndicatesOverflow t = ContextOverflow
  | has "rate limit" || has "rate_limit" = RateLimited
  | has "overloaded" || has "server_error" || has "service unavailable" = TransientError
  | has "insufficient_quota"
      || has "invalid api key"
      || has "incorrect api key"
      || has "invalid_api_key" =
      AuthError
  | otherwise = OtherError
  where
    lower = Text.toLower t
    has needle = needle `Text.isInfixOf` lower
