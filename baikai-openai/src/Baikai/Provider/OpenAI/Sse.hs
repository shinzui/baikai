{-# LANGUAGE LambdaCase #-}

-- | Local SSE transport for OpenAI Chat Completions streams.
module Baikai.Provider.OpenAI.Sse
  ( openaiSseStream,
    openaiSseStreamValue,
    openaiSseStreamValueWithHeaders,
    sseFromResponse,
    buildRequest,
    ResponseMetadata (..),
    capturedHeaderNames,
  )
where

import Baikai.Error (BaikaiError, decodeError, httpError, parseHttpDate, retryAfterSecondsAt)
import Control.Monad (foldM, when)
import Data.Aeson qualified as Aeson
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
import OpenAI.V1.Chat.Completions qualified as Chat
import Servant.Client qualified as Client

-- | Response-level metadata captured once, before the first chunk.
--
-- Header capture is an allow-list: a response header is recorded only
-- if its name appears in 'capturedHeaderNames'. A denylist would leak
-- whatever header a future gateway decides to add, and this transport
-- speaks to an open-ended set of hosts.
--
-- Names are recorded folded to lowercase, so a reader can look one up
-- without case-folding first.
data ResponseMetadata = ResponseMetadata
  { httpStatus :: !Int,
    headers :: ![(Text, Text)]
  }
  deriving stock (Eq, Show, Generic)

-- | The response headers worth recording across the OpenAI-compatible
-- ecosystem. OpenAI itself issues @x-request-id@; other hosts spell
-- their own identifier @request-id@, and the gateways commonly sitting
-- in front of one of them add @x-amzn-requestid@, @x-ms-request-id@, or
-- @cf-ray@. None can carry a credential: they are values the server
-- chose, not values baikai sent.
--
-- The order is a preference order as well as an allow-list, matching
-- the discipline @Baikai.Provider.Claude.Sse@ established. A consumer
-- picking one correlation identifier out of a response takes the first
-- of these that is present, so the host's own identifier wins over a
-- gateway's when both are there.
capturedHeaderNames :: [CI SBS.ByteString]
capturedHeaderNames =
  [ "x-request-id",
    "request-id",
    "x-amzn-requestid",
    "x-ms-request-id",
    "cf-ray"
  ]

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

-- | POST the request to @/v1/chat/completions@ and feed decoded SSE
-- JSON payloads to the second callback. A @data: [DONE]@ frame ends the
-- stream without producing a callback value.
--
-- The first callback receives the response's 'ResponseMetadata' exactly
-- once, before any chunk. It is a separate callback rather than a
-- widening of the per-chunk one because the per-chunk callback runs once
-- per SSE frame — potentially thousands of times per call — and
-- response-level data does not belong on that hot path.
openaiSseStream ::
  Client.ClientEnv ->
  Text ->
  Chat.CreateChatCompletion ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
openaiSseStream env apiKey req =
  openaiSseStreamValue env apiKey (Aeson.toJSON req)

openaiSseStreamValue ::
  Client.ClientEnv ->
  Text ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
openaiSseStreamValue env apiKey =
  openaiSseStreamValueWithHeaders
    env
    [ ("Authorization", Text.encodeUtf8 ("Bearer " <> apiKey)),
      ("Accept", "text/event-stream"),
      ("Content-Type", "application/json")
    ]

openaiSseStreamValueWithHeaders ::
  Client.ClientEnv ->
  RequestHeaders ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
openaiSseStreamValueWithHeaders env requestHeaders requestBody onMetadata onEvent = do
  HTTP.withResponse (buildRequest (Client.baseUrl env) requestHeaders requestBody) (Client.manager env) $ \response ->
    sseFromResponse response onMetadata onEvent

-- | The exact request this transport sends.
--
-- Pure and exported so that what goes on the wire — the method, the
-- composed path, and the redirect policy — is assertable without opening
-- a connection.
--
-- The path is the base URL's path plus @/v1/chat/completions@. The base URL
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
      HTTP.path = S8.pack (normalizePath (Client.baseUrlPath base) <> "/v1/chat/completions"),
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

-- | Consume an @http-client@ response as an OpenAI-compatible SSE
-- stream.
--
-- 'onMetadata' fires exactly once, before any chunk, on both the success
-- and the non-2xx path. A failed call's correlation identifier is if
-- anything more valuable than a successful one's, since it is precisely
-- what a provider support request needs.
sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
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
                -- Trailing whitespace is trimmed before the comparison:
                -- hosts send @data: [DONE] @ and @data: [DONE]\r@, and
                -- an exact match against those turned the end of a
                -- healthy stream into a decode error. An empty payload
                -- is a heartbeat, not a frame.
                let payload = S8.dropWhileEnd isSpace (S8.concat es)
                if SBS.null payload
                  then pure False
                  else
                    if payload == "[DONE]"
                      then pure True
                      else case Aeson.eitherDecodeStrict payload of
                        Left err -> onEvent (Left (decodeError (Text.pack err))) >> pure False
                        Right val -> onEvent (Right val) >> pure False

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
