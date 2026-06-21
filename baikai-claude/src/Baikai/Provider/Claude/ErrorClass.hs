-- | Map failures from the Anthropic SDK onto baikai's typed
-- 'BaikaiError'. Two entry points cover the two ways a failure reaches
-- the provider: 'classifyException' for an exception thrown by the
-- @servant-client@ HTTP layer (carrying an HTTP status), and
-- 'classifyErrorValue' for an Anthropic @error@ event that arrives
-- mid-stream as a JSON 'Value'.
module Baikai.Provider.Claude.ErrorClass
  ( classifyException,
    classifyErrorValue,
    -- | Exposed for testing the HTTP-status mapping without a live call.
    responseToError,
  )
where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    bodyIndicatesOverflow,
    classifyHttpStatusWithBody,
    decodeError,
    providerError,
  )
import Control.Exception (SomeException, displayException, fromException)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Foldable (toList)
import Data.Sequence (Seq)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Network.HTTP.Types.Status (statusCode)
import Servant.Client (ClientError, ResponseF (..))
import Servant.Client qualified as Servant
import Text.Read (readMaybe)

-- | Convert any exception caught from the Anthropic SDK into a
-- categorised 'BaikaiError'. Recognises @servant-client@ 'ClientError';
-- anything else degrades to a generic provider error carrying the
-- displayed exception text.
classifyException :: SomeException -> BaikaiError
classifyException ex = case fromException ex of
  Just clientErr -> fromClientError clientErr
  Nothing -> providerError (Text.pack (displayException ex))

fromClientError :: ClientError -> BaikaiError
fromClientError clientErr = case clientErr of
  Servant.FailureResponse _req resp -> responseToError resp
  Servant.DecodeFailure detail _ -> decodeError detail
  Servant.UnsupportedContentType _ _ -> decodeError "unsupported content type in Anthropic response"
  Servant.InvalidContentTypeHeader _ -> decodeError "invalid content-type header in Anthropic response"
  Servant.ConnectionError exc ->
    (providerError ("connection error: " <> Text.pack (displayException exc)))
      { category = TransientError
      }

-- | Build a 'BaikaiError' from a non-2xx HTTP response: status code,
-- @Retry-After@ header (when integer-valued), and a snippet of the body
-- (which also feeds context-overflow detection).
responseToError :: ResponseF LBS.ByteString -> BaikaiError
responseToError resp =
  BaikaiError
    { category = classifyHttpStatusWithBody status retryAfter body,
      message = msg,
      httpStatus = Just status,
      retryAfterSeconds = retryAfter,
      exitCode = Nothing
    }
  where
    status = statusCode (responseStatusCode resp)
    body = decodeLenient (LBS.toStrict (responseBody resp))
    retryAfter = parseRetryAfter (responseHeaders resp)
    snippet = Text.take 300 (Text.strip body)
    msg =
      "HTTP "
        <> Text.pack (show status)
        <> (if Text.null snippet then "" else ": " <> snippet)

-- | Look up an integer @Retry-After@ header value (seconds). The HTTP
-- date form is not parsed and yields 'Nothing'.
parseRetryAfter :: Seq (CI.CI ByteString, ByteString) -> Maybe Int
parseRetryAfter headers = do
  raw <- lookup (CI.mk "Retry-After") (toList headers)
  readMaybe (Text.unpack (Text.strip (decodeLenient raw)))

decodeLenient :: ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode

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
