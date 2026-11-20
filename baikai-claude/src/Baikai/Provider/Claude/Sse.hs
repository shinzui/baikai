{-# LANGUAGE LambdaCase #-}

-- | __Exposed with no stability guarantees.__ This module is exposed so
-- the test suites can drive the transport without a socket, and so
-- sibling packages can reuse its pieces; it is not part of the public
-- API and may change in /any/ release without a PVP major bump.
--
-- Adapt the Claude client stream and its response metadata to Baikai's
-- provider error contract.
module Baikai.Provider.Claude.Sse
  ( claudeSseStream,
    claudeSseStreamValue,
    claudeSseStreamValueWithHeaders,
    sseFromResponse,
    decodeFrame,
    ResponseMetadata (..),
    capturedHeaderNames,
  )
where

import Baikai.Error (BaikaiError, ErrorCategory (TransientError), decodeError, httpError, invalidRequest, parseHttpDate, providerError, retryAfterSecondsAt)
import Baikai.Error qualified as Error
import Baikai.Provider.Claude.Internal.ErrorClass (classifyErrorValue)
import Claude.Client qualified as Candidate
import Claude.Messages (MessageRequest)
import Claude.Streaming qualified as Candidate
import Control.Monad (when)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as SBS
import Data.ByteString.Char8 qualified as S8
import Data.CaseInsensitive (CI)
import Data.CaseInsensitive qualified as CI
import Data.IORef qualified as IORef
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Time.Clock (getCurrentTime)
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Header (RequestHeaders)
import Network.HTTP.Types.Status qualified as Status
import Servant.Client qualified as Client
import System.IO.Unsafe (unsafePerformIO)

-- | Response-level metadata captured once, before the first event.
--
-- Header capture is an allow-list: a response header is recorded only
-- if its name appears in 'capturedHeaderNames'. A denylist would leak
-- whatever header a future gateway decides to add.
--
-- Names are recorded folded to lowercase, so a reader can look one up
-- without case-folding first.
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }
  deriving stock (Eq, Show, Generic)

-- | The response headers worth recording. Anthropic issues
-- @request-id@; gateways in front of it commonly add @x-request-id@
-- and @cf-ray@. None of these can carry a credential: they are values
-- the server chose, not values baikai sent.
--
-- The order is a preference order as well as an allow-list. A consumer
-- picking one correlation identifier out of a response should take the
-- first of these that is present, so Anthropic's own identifier wins
-- over a gateway's when both are there.
capturedHeaderNames :: [CI SBS.ByteString]
capturedHeaderNames = ["request-id", "x-request-id", "cf-ray"]

-- | Status and allow-listed headers, read straight off the response.
responseMetadata :: HTTP.Response body -> ResponseMetadata
responseMetadata response =
  ResponseMetadata
    { httpStatus = Status.statusCode (HTTP.responseStatus response),
      headers =
        [ (decodeLenient (CI.foldedCase name), decodeLenient value)
        | (name, value) <- HTTP.responseHeaders response,
          name `elem` capturedHeaderNames
        ]
    }

-- | POST the request to @/v1/messages@ with @stream=true@ and feed each
-- decoded SSE event to the second callback. A non-2xx response is
-- classified from status, @Retry-After@, and body and delivered as one
-- 'Left'.
--
-- The first callback receives the response's 'ResponseMetadata' exactly
-- once, before any event. It is a separate callback rather than a
-- widening of the per-event one because the per-event callback runs
-- once per SSE event — potentially thousands of times per call — and
-- response-level data does not belong on that hot path.
claudeSseStream ::
  Client.BaseUrl ->
  Text ->
  Maybe Text ->
  MessageRequest ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Candidate.StreamPayload -> IO ()) ->
  IO ()
claudeSseStream env apiKey anthropicVersion req =
  claudeSseStreamValue env apiKey anthropicVersion (Aeson.toJSON req)

claudeSseStreamValue ::
  Client.BaseUrl ->
  Text ->
  Maybe Text ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Candidate.StreamPayload -> IO ()) ->
  IO ()
claudeSseStreamValue env apiKey anthropicVersion =
  claudeSseStreamValueWithHeaders env requestHeaders
  where
    requestHeaders =
      maybe
        id
        (\v -> (("anthropic-version", Text.encodeUtf8 v) :))
        anthropicVersion
        [ ("x-api-key", Text.encodeUtf8 apiKey),
          ("Accept", "text/event-stream"),
          ("Content-Type", "application/json")
        ]

claudeSseStreamValueWithHeaders ::
  Client.BaseUrl ->
  RequestHeaders ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Candidate.StreamPayload -> IO ()) ->
  IO ()
claudeSseStreamValueWithHeaders env requestHeaders requestBody onMetadata onEvent = do
  let config =
        (Candidate.defaultClientConfig (fromMaybe "" (lookup "x-api-key" requestHeaders)))
          { Candidate.endpoint = Client.showBaseUrl env,
            Candidate.apiVersion = lookup "anthropic-version" requestHeaders,
            Candidate.timeoutMicros = Nothing
          }
      options =
        Candidate.RequestOptions
          (maybe [] (S8.split ',') (lookup "anthropic-beta" requestHeaders))
          (filter ((`notElem` ["x-api-key", "anthropic-version", "anthropic-beta", "accept", "content-type"]) . fst) requestHeaders)
  created <- Candidate.newClientWithPool candidatePool config
  sentMetadata <- IORef.newIORef False
  let publish meta = do
        alreadySent <- IORef.atomicModifyIORef' sentMetadata (\sent -> (True, sent))
        when (not alreadySent) (onMetadata (candidateMetadata meta))
  case created of
    Left err -> onEvent (Left (candidateError err))
    Right client -> do
      result <- Candidate.streamMessageValue client options requestBody $ \meta event -> do
        publish meta
        forwardPayload onEvent (Candidate.eventPayload event)
        pure Candidate.Continue
      case result of
        Right response -> publish (Candidate.metadata response)
        Left (Candidate.ApiStatusError meta _ detail) -> do
          publish meta
          now <- getCurrentTime
          let reference = fromMaybe now (parseHttpDate . decodeLenient =<< Candidate.responseDate meta)
              retryAfter = retryAfterSecondsAt reference . decodeLenient =<< Candidate.retryAfter meta
          onEvent (Left (httpError (Candidate.status meta) retryAfter detail))
        Left err -> do
          mapM_ publish (failureMetadata err)
          onEvent (Left (candidateError err))

{-# NOINLINE candidatePool #-}
candidatePool :: Candidate.ClientPool
candidatePool = unsafePerformIO Candidate.newClientPool

candidateMetadata :: Candidate.ResponseMetadata -> ResponseMetadata
candidateMetadata meta =
  ResponseMetadata (Candidate.status meta) $
    [ (name, decodeLenient header)
    | (name, Just header) <-
        [ ("request-id", Candidate.requestId meta),
          ("x-request-id", Candidate.gatewayRequestId meta),
          ("cf-ray", Candidate.cloudflareRay meta)
        ]
    ]

failureMetadata :: Candidate.ClientError -> Maybe Candidate.ResponseMetadata
failureMetadata = \case
  Candidate.TransportError meta _ -> meta
  Candidate.DecodeError meta _ -> Just meta
  Candidate.StreamApiError meta _ -> Just meta
  _ -> Nothing

candidateError :: Candidate.ClientError -> BaikaiError
candidateError = \case
  Candidate.InvalidRequest detail -> invalidRequest detail
  Candidate.DecodeError _ "Stream ended before message_stop" -> providerError "claude stream ended without message_stop"
  Candidate.DecodeError _ detail -> decodeError detail
  Candidate.StreamApiError _ err -> classifyProviderError err
  Candidate.TransportError _ kind -> (providerError (Text.pack (show kind))) {Error.category = TransientError}
  err -> decodeError (Text.pack (show err))

classifyProviderError :: Candidate.ApiError -> BaikaiError
classifyProviderError err =
  let detail = Candidate.message err
      body = Aeson.object ["type" Aeson..= Candidate.errorType err, "message" Aeson..= detail]
   in fromMaybe (providerError detail) (classifyErrorValue body)

-- | Consume an @http-client@ response as an Anthropic SSE stream.
--
-- 'onMetadata' fires exactly once, before any event, on both the
-- success and the non-2xx path. A failed call's correlation identifier
-- is if anything more valuable than a successful one's, since it is
-- precisely what a provider support request needs.
sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Candidate.StreamPayload -> IO ()) ->
  IO ()
sseFromResponse response onMetadata onEvent = do
  let st = HTTP.responseStatus response
  onMetadata (responseMetadata response)
  if not (Status.statusIsSuccessful st)
    then do
      bodyChunks <- HTTP.brConsume (HTTP.responseBody response)
      now <- getCurrentTime
      let bodyText = decodeLenient (SBS.concat bodyChunks)
          headerText name = decodeLenient <$> lookup (CI.mk name) (HTTP.responseHeaders response)
          -- The server's own Date is the reference instant for an
          -- HTTP-date Retry-After, which CDN-fronted hosts send on a
          -- 429; the local clock is the fallback. Using the response's
          -- clock keeps this machine's skew out of the hint.
          reference = fromMaybe now (parseHttpDate =<< headerText "Date")
          retryAfter = retryAfterSecondsAt reference =<< headerText "Retry-After"
      onEvent (Left (httpError (Status.statusCode st) retryAfter bodyText))
    else do
      let header name = lookup name (HTTP.responseHeaders response)
          metadata =
            Candidate.ResponseMetadata
              { Candidate.requestId = header "request-id",
                Candidate.gatewayRequestId = header "x-request-id",
                Candidate.cloudflareRay = header "cf-ray",
                Candidate.status = Status.statusCode st,
                Candidate.retryAfter = header "retry-after",
                Candidate.responseDate = header "date"
              }
      result <- Candidate.consumeEventStream metadata (HTTP.brRead (HTTP.responseBody response)) $ \event -> do
        forwardPayload onEvent (Candidate.eventPayload event)
        pure Candidate.Continue
      case result of
        Left err -> onEvent (Left (candidateError err))
        Right _ -> pure ()

-- | Decode an individual recorded frame with the client codec.
decodeFrame :: SBS.ByteString -> Either BaikaiError (Maybe Candidate.StreamPayload)
decodeFrame payload = do
  raw <- either (Left . decodeError . Text.pack) Right (Aeson.eitherDecodeStrict payload)
  parsed <- either (Left . decodeError . Text.pack) Right (Candidate.decodeStreamEvent raw)
  case parsed of
    Left err -> Left (classifyProviderError err)
    Right event -> pure (knownPayload (Candidate.eventPayload event))

forwardPayload :: (Either BaikaiError Candidate.StreamPayload -> IO ()) -> Candidate.StreamPayload -> IO ()
forwardPayload send = mapM_ (send . Right) . knownPayload

knownPayload :: Candidate.StreamPayload -> Maybe Candidate.StreamPayload
knownPayload = \case
  Candidate.UnknownEvent _ -> Nothing
  Candidate.ContentBlockDelta _ (Candidate.UnknownDelta _ _) -> Nothing
  payload -> Just payload

decodeLenient :: SBS.ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode
