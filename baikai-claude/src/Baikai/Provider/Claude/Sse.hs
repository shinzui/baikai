{-# LANGUAGE LambdaCase #-}

-- | Local SSE transport for Anthropic Messages streams.
--
-- The upstream @claude@ SDK exposes the right event decoder, but its
-- non-2xx path collapses status, headers, and body into plain text. This
-- wrapper keeps the SDK's request and SSE parsing shape while surfacing
-- classified 'BaikaiError' values.
module Baikai.Provider.Claude.Sse
  ( claudeSseStream,
    claudeSseStreamValue,
    claudeSseStreamValueWithHeaders,
    sseFromResponse,
    decodeFrame,
    buildRequest,
    ResponseMetadata (..),
    capturedHeaderNames,
  )
where

import Baikai.Error (BaikaiError, decodeError, httpError, parseHttpDate, retryAfterSecondsAt)
import Claude.V1.Messages qualified as Messages
import Control.Monad (foldM, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as Aeson.Key
import Data.ByteString qualified as SBS
import Data.ByteString.Char8 qualified as S8
import Data.CaseInsensitive (CI)
import Data.CaseInsensitive qualified as CI
import Data.Char (isSpace)
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
  Client.ClientEnv ->
  Text ->
  Maybe Text ->
  Messages.CreateMessage ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
claudeSseStream env apiKey anthropicVersion req =
  claudeSseStreamValue env apiKey anthropicVersion (Aeson.toJSON req {Messages.stream = Just True})

claudeSseStreamValue ::
  Client.ClientEnv ->
  Text ->
  Maybe Text ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
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
  Client.ClientEnv ->
  RequestHeaders ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
claudeSseStreamValueWithHeaders env requestHeaders requestBody onMetadata onEvent = do
  HTTP.withResponse (buildRequest (Client.baseUrl env) requestHeaders requestBody) (Client.manager env) $ \response ->
    sseFromResponse response onMetadata onEvent

-- | The exact request this transport sends.
--
-- Pure and exported so that what goes on the wire — the method, the
-- composed path, and the redirect policy — is assertable without opening
-- a connection.
--
-- The path is the base URL's path plus @/v1/messages@. The base URL
-- reaching here has already been through
-- 'Baikai.Http.canonicalBaseUrl', which strips a trailing @\/v1@
-- segment, so a caller who writes the base URL the way every OpenAI SDK
-- teaches it — @https:\/\/api.deepseek.com\/v1@ — gets one @\/v1@ here
-- rather than two.
buildRequest :: Client.BaseUrl -> RequestHeaders -> Aeson.Value -> HTTP.Request
buildRequest base requestHeaders requestBody =
  HTTP.defaultRequest
    { HTTP.secure = case Client.baseUrlScheme base of
        Client.Http -> False
        Client.Https -> True,
      HTTP.host = S8.pack (Client.baseUrlHost base),
      HTTP.port = Client.baseUrlPort base,
      HTTP.method = "POST",
      HTTP.path = S8.pack (normalizePath (Client.baseUrlPath base) <> "/v1/messages"),
      HTTP.requestHeaders = requestHeaders,
      HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode requestBody),
      -- This POST has no legitimate redirect, and http-client's default
      -- is to follow up to ten of them with every header intact — which
      -- would re-send the credential to whatever host a Location names.
      -- At zero the 3xx comes back untouched and 'sseFromResponse'
      -- delivers it as the one in-band terminal error, carrying its
      -- status.
      HTTP.redirectCount = 0,
      -- No per-response bound here: Options.timeoutMs is enforced around
      -- the whole call by Transport.runWithTimeout.
      HTTP.responseTimeout = HTTP.responseTimeoutNone
    }

-- | Consume an @http-client@ response as an Anthropic SSE stream.
--
-- 'onMetadata' fires exactly once, before any event, on both the
-- success and the non-2xx path. A failed call's correlation identifier
-- is if anything more valuable than a successful one's, since it is
-- precisely what a provider support request needs.
sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
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
      lineBufRef <- IORef.newIORef SBS.empty
      eventBufRef <- IORef.newIORef ([] :: [SBS.ByteString])
      let flushEvent = do
            es <- IORef.atomicModifyIORef' eventBufRef (\buf -> ([], reverse buf))
            case es of
              [] -> pure False
              _ -> do
                let payload = S8.dropWhileEnd isSpace (S8.concat es)
                if SBS.null payload
                  then -- An empty @data:@ line is a heartbeat, not a frame.
                    pure False
                  else case decodeFrame payload of
                    Left e -> onEvent (Left e) >> pure False
                    Right Nothing -> pure False
                    Right (Just ev) -> onEvent (Right ev) >> pure False

          handleLine line =
            let l = stripCR line
             in if S8.null l
                  then flushEvent
                  else
                    if "data:" `S8.isPrefixOf` l
                      then do
                        let d = S8.dropWhile (== ' ') (S8.drop 5 l)
                        IORef.modifyIORef' eventBufRef (d :)
                        pure False
                      else pure False

          loop = do
            chunk <- HTTP.brRead (HTTP.responseBody response)
            if SBS.null chunk
              then do
                pendingLine <- IORef.readIORef lineBufRef
                when (not (SBS.null pendingLine)) $ do
                  _ <- handleLine pendingLine
                  IORef.writeIORef lineBufRef SBS.empty
                _ <- flushEvent
                pure ()
              else do
                prev <- IORef.readIORef lineBufRef
                let combined = prev <> chunk
                    ls = S8.split '\n' combined
                case unsnoc ls of
                  Nothing -> loop
                  Just (completeLines, lastLine) -> do
                    IORef.writeIORef lineBufRef lastLine
                    stop <- foldM (\acc ln -> if acc then pure True else handleLine ln) False completeLines
                    if stop then pure () else loop
      loop

-- | Decode one SSE frame.
--
-- @Right Nothing@ is a frame this transport deliberately skips: an event
-- @type@, or a @content_block_delta@ whose @delta.type@, that the SDK
-- has no constructor for. The SDK decodes both with aeson's tagged-object
-- encoding and no unknown-tag fallback, so an unrecognised tag is a
-- decode /failure/ there — and a new frame type from Anthropic must not
-- end an otherwise healthy stream. A frame of a __known__ type that
-- still fails to decode is a genuine fault and stays a 'decodeError'.
--
-- Both tag lists are copied from the SDK's @constructorTagModifier@
-- tables in @Claude.V1.Messages@. A frame carrying no @type@ field at
-- all is not "unknown" — it is malformed, and fails as before.
decodeFrame :: SBS.ByteString -> Either BaikaiError (Maybe Messages.MessageStreamEvent)
decodeFrame payload = case Aeson.eitherDecodeStrict payload of
  Left err -> Left (decodeError (Text.pack err))
  Right val
    | frameIsUnknown val -> Right Nothing
    | otherwise -> case Aeson.fromJSON val of
        Aeson.Error err -> Left (decodeError (Text.pack err))
        Aeson.Success ev -> Right (Just ev)

-- | Whether this frame names a type the SDK has no constructor for.
frameIsUnknown :: Aeson.Value -> Bool
frameIsUnknown val = case val of
  Aeson.Object o -> case Aeson.Key.lookup "type" o of
    Just (Aeson.String "content_block_delta") ->
      case Aeson.Key.lookup "delta" o of
        Just (Aeson.Object d) -> case Aeson.Key.lookup "type" d of
          Just (Aeson.String dt) -> dt `notElem` knownDeltaTypes
          _ -> False
        _ -> False
    Just (Aeson.String t) -> t `notElem` knownEventTypes
    _ -> False
  _ -> False

knownEventTypes :: [Text]
knownEventTypes =
  [ "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
    "ping",
    "error"
  ]

knownDeltaTypes :: [Text]
knownDeltaTypes =
  [ "text_delta",
    "input_json_delta",
    "thinking_delta",
    "signature_delta"
  ]

normalizePath :: String -> String
normalizePath = \case
  "" -> ""
  p@('/' : _) -> p
  p -> '/' : p

stripCR :: SBS.ByteString -> SBS.ByteString
stripCR bs = case S8.unsnoc bs of
  Just (initBs, '\r') -> initBs
  _ -> bs

unsnoc :: [a] -> Maybe ([a], a)
unsnoc [] = Nothing
unsnoc xs = Just (init xs, last xs)

decodeLenient :: SBS.ByteString -> Text
decodeLenient = Text.decodeUtf8With Text.lenientDecode
