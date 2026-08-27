-- | Transport-failure classification, shared by every HTTP provider.
--
-- The rule is /where/ the failure happened, not what type it is. A
-- failure after the request went out that breaks or ends the connection
-- is 'TransientError': the same call may well succeed on the next
-- attempt. A failure that says the caller's request or the process's
-- configuration is wrong — a bad URL, an unsendable header, a proxy or
-- TLS setup that cannot work, a server that does not speak HTTP — is
-- not retryable. A programming error is neither, and stays
-- 'OtherError' so it is not silently retried forever.
--
-- Three exception types reach a provider's worker, because
-- @http-client@ delivers the same underlying failure differently
-- depending on the phase it happened in. At connect time the manager's
-- exception wrapper turns a socket or TLS failure into
-- @HttpExceptionRequest _ (InternalException _)@ or
-- @ConnectionFailure@. While the response body is streaming, only
-- @http-client@'s own thin wrapper is in play, so an 'IOException' from
-- the socket or a 'TLS.TLSException' from the session reaches the
-- caller /raw/ — which is why a classifier that understood
-- 'HTTP.HttpException' alone called a mid-stream reset 'OtherError'
-- while calling the identical reset at connect time transient.
--
-- Providers call 'classifyTransportException' and keep their own
-- fallback for a 'Nothing'; see
-- @Baikai.Provider.Claude.Internal.ErrorClass.classifyException@.
module Baikai.Provider.Transport.Classify
  ( classifyTransportException,
    classifyHttpException,
    classifyHttpExceptionContent,
    classifyIOException,
    classifyTlsException,
  )
where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    httpError,
    invalidRequest,
    parseHttpDate,
    parseRetryAfterSeconds,
    providerError,
    retryAfterSecondsAt,
  )
import Control.Exception (SomeException, displayException, fromException)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Foreign.C.Error
  ( Errno (..),
    eCONNABORTED,
    eCONNRESET,
    eHOSTDOWN,
    eHOSTUNREACH,
    eNETDOWN,
    eNETRESET,
    eNETUNREACH,
    ePIPE,
    eTIMEDOUT,
  )
-- Qualified: its 'IOErrorType' has a constructor named @OtherError@,
-- which collides with the 'ErrorCategory' constructor of that name.
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (hDate, hRetryAfter)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS qualified as TLS

-- | Classify any exception a transport can raise. 'Nothing' means "not
-- a transport failure at all" — the caller keeps its own fallback,
-- which is what makes a @userError@ from a buggy callback stay
-- 'OtherError' instead of being reported as a network blip.
classifyTransportException :: SomeException -> Maybe BaikaiError
classifyTransportException ex
  | Just httpEx <- fromException ex = Just (classifyHttpException httpEx)
  | Just tlsEx <- fromException ex = Just (classifyTlsException tlsEx)
  | Just ioEx <- fromException ex = classifyIOException ioEx
  | otherwise = Nothing

-- | Classify an @http-client@ 'HTTP.HttpException'.
classifyHttpException :: HTTP.HttpException -> BaikaiError
classifyHttpException = \case
  HTTP.InvalidUrlException url reason ->
    invalidRequest (Text.pack (url <> ": " <> reason))
  HTTP.HttpExceptionRequest _ content -> classifyHttpExceptionContent content

-- | Classify the payload of an 'HTTP.HttpExceptionRequest'.
classifyHttpExceptionContent :: HTTP.HttpExceptionContent -> BaikaiError
classifyHttpExceptionContent = \case
  -- A response arrived and carried a failing status. Unreachable from
  -- baikai's own transports, which never install
  -- 'throwErrorStatusCodes'; mapped for third-party providers built on
  -- http-client.
  HTTP.StatusCodeException resp body ->
    let hdrs = HTTP.responseHeaders resp
        headerText name = decodeLenient <$> lookup name hdrs
        -- The server's own Date is the reference instant, so an
        -- HTTP-date Retry-After does not inherit this machine's clock
        -- skew. Falling back to epoch would be worse than falling back
        -- to the integer form alone, so a missing Date leaves the date
        -- form unconverted here; the transports, which are in IO, use
        -- the local clock instead.
        retryAfter = case parseHttpDate =<< headerText hDate of
          Just reference -> retryAfterSecondsAt reference =<< headerText hRetryAfter
          Nothing -> parseRetryAfterSeconds =<< headerText hRetryAfter
     in httpError (statusCode (HTTP.responseStatus resp)) retryAfter (decodeLenient body)
  -- The connection could not be made, or went quiet, or went away.
  HTTP.ConnectionFailure e -> transient ("connection failure: " <> Text.pack (displayException e))
  HTTP.ConnectionTimeout -> transient "connection timeout"
  HTTP.ResponseTimeout -> transient "response timeout"
  HTTP.ConnectionClosed -> transient "connection closed"
  HTTP.NoResponseDataReceived -> transient "no response data received"
  HTTP.IncompleteHeaders -> transient "incomplete response headers"
  -- The body broke after the status line: framing, declared length, or
  -- inflation. A server that closes the socket mid-chunk surfaces here.
  HTTP.InvalidChunkHeaders -> transient "chunked response body ended or broke mid-chunk"
  HTTP.ResponseBodyTooShort expected actual ->
    transient
      ( "response body too short: expected "
          <> tshow expected
          <> " bytes, got "
          <> tshow actual
      )
  HTTP.HttpZlibException e ->
    transient ("compressed response body could not be inflated: " <> tshow e)
  -- http-client-tls's wrapper for a socket or TLS failure at connect
  -- time. The constructor is documented as carrying exactly those, so
  -- an unrecognised inner exception is still a connection failure.
  HTTP.InternalException inner
    | Just tlsEx <- fromException inner -> classifyTlsException tlsEx
    | Just ioEx <- fromException inner ->
        transient (Text.pack (displayException (ioEx :: IOE.IOException)))
    | otherwise -> transient (Text.pack (displayException inner))
  -- The caller's request cannot be sent as written.
  HTTP.InvalidRequestHeader h -> invalidRequest ("invalid request header: " <> decodeLenient h)
  HTTP.InvalidDestinationHost h -> invalidRequest ("invalid destination host: " <> decodeLenient h)
  HTTP.WrongRequestBodyStreamSize expected actual ->
    invalidRequest
      ( "request body size mismatch: declared "
          <> tshow expected
          <> ", sent "
          <> tshow actual
      )
  -- Everything else is a server that does not speak HTTP, or a proxy or
  -- redirect configuration that cannot work. Retrying changes nothing.
  other -> providerError (Text.take 300 (tshow other))
  where
    tshow :: (Show a) => a -> Text
    tshow = Text.pack . show

-- | Classify a raw 'IOE.IOException', which is what a socket failure
-- during the body read looks like.
--
-- Both the error /type/ and the errno are consulted, because @base@
-- maps @ECONNABORTED@ to the 'IOE.OtherError' error type: a type-only
-- rule would call an aborted connection a programming error.
classifyIOException :: IOE.IOException -> Maybe BaikaiError
classifyIOException ioe
  | IOE.ioe_type ioe `elem` [IOE.ResourceVanished, IOE.EOF, IOE.TimeExpired] =
      Just (transient detail)
  | Just n <- IOE.ioe_errno ioe, Errno n `elem` socketErrnos = Just (transient detail)
  | otherwise = Nothing
  where
    detail = Text.pack (displayException ioe)
    socketErrnos =
      [ eCONNABORTED,
        eCONNRESET,
        eNETRESET,
        eNETDOWN,
        eNETUNREACH,
        eHOSTDOWN,
        eHOSTUNREACH,
        eTIMEDOUT,
        ePIPE
      ]

-- | Classify a 'TLS.TLSException'. The constructor names encode /when/
-- the failure happened, which is exactly the fact the rule needs: a
-- session that existed and broke is transient, a session that never
-- existed is a trust-store, protocol or library-misuse problem that a
-- retry will reproduce.
classifyTlsException :: TLS.TLSException -> BaikaiError
classifyTlsException = \case
  TLS.Terminated _ why err ->
    transient ("TLS session terminated: " <> Text.pack why <> " (" <> tshow err <> ")")
  TLS.PostHandshake err -> transient ("TLS failure after handshake: " <> tshow err)
  TLS.Uncontextualized err -> transient ("TLS failure: " <> tshow err)
  TLS.HandshakeFailed err -> providerError ("TLS handshake failed: " <> tshow err)
  TLS.ConnectionNotEstablished -> providerError "TLS connection not established"
  TLS.MissingHandshake -> providerError "TLS handshake missing"
  where
    tshow :: (Show a) => a -> Text
    tshow = Text.pack . show

transient :: Text -> BaikaiError
transient t = (providerError ("connection error: " <> t)) {category = TransientError}

decodeLenient :: ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode
