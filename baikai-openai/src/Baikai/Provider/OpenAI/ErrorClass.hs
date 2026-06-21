-- | Map failures from the OpenAI SDK onto baikai's typed 'BaikaiError'.
-- 'classifyException' handles an exception thrown by the
-- @servant-client@ HTTP layer (carrying an HTTP status);
-- 'classifyErrorText' handles an error that arrives mid-stream as a
-- plain text message (the OpenAI streaming chunk's @error@ field).
module Baikai.Provider.OpenAI.ErrorClass
  ( classifyException,
    classifyErrorText,
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

-- | Convert any exception caught from the OpenAI SDK into a categorised
-- 'BaikaiError'. Recognises @servant-client@ 'ClientError'; anything
-- else degrades to a generic provider error carrying the displayed
-- exception text.
classifyException :: SomeException -> BaikaiError
classifyException ex = case fromException ex of
  Just clientErr -> fromClientError clientErr
  Nothing -> providerError (Text.pack (displayException ex))

fromClientError :: ClientError -> BaikaiError
fromClientError clientErr = case clientErr of
  Servant.FailureResponse _req resp -> responseToError resp
  Servant.DecodeFailure detail _ -> decodeError detail
  Servant.UnsupportedContentType _ _ -> decodeError "unsupported content type in OpenAI response"
  Servant.InvalidContentTypeHeader _ -> decodeError "invalid content-type header in OpenAI response"
  Servant.ConnectionError exc ->
    (providerError ("connection error: " <> Text.pack (displayException exc)))
      { category = TransientError
      }

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

parseRetryAfter :: Seq (CI.CI ByteString, ByteString) -> Maybe Int
parseRetryAfter headers = do
  raw <- lookup (CI.mk "Retry-After") (toList headers)
  readMaybe (Text.unpack (Text.strip (decodeLenient raw)))

decodeLenient :: ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode

-- | Best-effort classification of an OpenAI streamed error message,
-- which arrives as plain text without an HTTP status. Returns 'Nothing'
-- for empty text (the caller keeps the raw message and 'errorInfo'
-- stays absent).
classifyErrorText :: Text -> Maybe BaikaiError
classifyErrorText t
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
