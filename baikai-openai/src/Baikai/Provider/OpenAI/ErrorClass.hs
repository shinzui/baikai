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
    decodeError,
    httpError,
    invalidRequest,
    parseRetryAfterSeconds,
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
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status (statusCode)
import Servant.Client (ClientError, ResponseF (..))
import Servant.Client qualified as Servant
import Text.Read (readMaybe)

-- | Convert any exception caught from the OpenAI SDK into a categorised
-- 'BaikaiError'. Recognises @servant-client@ 'ClientError' and raw
-- @http-client@ 'HttpException'; anything else degrades to a generic
-- provider error carrying the displayed exception text.
classifyException :: SomeException -> BaikaiError
classifyException ex
  | Just clientErr <- fromException ex = fromClientError clientErr
  | Just httpEx <- fromException ex = fromHttpException httpEx
  | otherwise = providerError (Text.pack (displayException ex))

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
responseToError resp = httpError status retryAfter body
  where
    status = statusCode (responseStatusCode resp)
    body = decodeLenient (LBS.toStrict (responseBody resp))
    retryAfter = parseRetryAfter (responseHeaders resp)

parseRetryAfter :: Seq (CI.CI ByteString, ByteString) -> Maybe Int
parseRetryAfter headers = do
  raw <- lookup (CI.mk "Retry-After") (toList headers)
  parseRetryAfterSeconds (decodeLenient raw)

fromHttpException :: HTTP.HttpException -> BaikaiError
fromHttpException = \case
  HTTP.InvalidUrlException url reason ->
    invalidRequest (Text.pack (url <> ": " <> reason))
  HTTP.HttpExceptionRequest _ content -> fromHttpExceptionContent content

fromHttpExceptionContent :: HTTP.HttpExceptionContent -> BaikaiError
fromHttpExceptionContent = \case
  HTTP.StatusCodeException resp body ->
    httpError
      (statusCode (HTTP.responseStatus resp))
      (parseRetryAfterHttp (HTTP.responseHeaders resp))
      (decodeLenient body)
  HTTP.ConnectionFailure e -> transient (Text.pack (displayException e))
  HTTP.ConnectionTimeout -> transient "connection timeout"
  HTTP.ResponseTimeout -> transient "response timeout"
  HTTP.ConnectionClosed -> transient "connection closed"
  HTTP.NoResponseDataReceived -> transient "no response data received"
  HTTP.IncompleteHeaders -> transient "incomplete response headers"
  other -> providerError (Text.pack (show other))
  where
    transient t = (providerError ("connection error: " <> t)) {category = TransientError}

parseRetryAfterHttp :: [(CI.CI ByteString, ByteString)] -> Maybe Int
parseRetryAfterHttp headers = do
  raw <- lookup (CI.mk "Retry-After") headers
  parseRetryAfterSeconds (decodeLenient raw)

decodeLenient :: ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode

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
