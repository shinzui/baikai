{-# LANGUAGE LambdaCase #-}

-- | Local SSE transport for Anthropic Messages streams.
--
-- The upstream @claude@ SDK exposes the right event decoder, but its
-- non-2xx path collapses status, headers, and body into plain text. This
-- wrapper keeps the SDK's request and SSE parsing shape while surfacing
-- classified 'BaikaiError' values.
module Baikai.Provider.Claude.Sse
  ( claudeSseStream,
    sseFromResponse,
  )
where

import Baikai.Error (BaikaiError, decodeError, httpError, parseRetryAfterSeconds)
import Claude.V1.Messages qualified as Messages
import Control.Monad (foldM, when)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as SBS
import Data.ByteString.Char8 qualified as S8
import Data.CaseInsensitive qualified as CI
import Data.IORef qualified as IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status qualified as Status
import Servant.Client qualified as Client

-- | POST the request to @/v1/messages@ with @stream=true@ and feed each
-- decoded SSE event to the callback. A non-2xx response is classified
-- from status, @Retry-After@, and body and delivered as one 'Left'.
claudeSseStream ::
  Client.ClientEnv ->
  Text ->
  Maybe Text ->
  Messages.CreateMessage ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
claudeSseStream env apiKey anthropicVersion req onEvent = do
  let base = Client.baseUrl env
      secure = case Client.baseUrlScheme base of
        Client.Http -> False
        Client.Https -> True
      req' = req {Messages.stream = Just True}
      request =
        HTTP.defaultRequest
          { HTTP.secure = secure,
            HTTP.host = S8.pack (Client.baseUrlHost base),
            HTTP.port = Client.baseUrlPort base,
            HTTP.method = "POST",
            HTTP.path = S8.pack (normalizePath (Client.baseUrlPath base) <> "/v1/messages"),
            HTTP.requestHeaders = requestHeaders,
            HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode req'),
            -- EP-8 wires Options.timeoutMs through this local transport.
            HTTP.responseTimeout = HTTP.responseTimeoutNone
          }
      requestHeaders =
        maybe
          id
          (\v -> (("anthropic-version", Text.encodeUtf8 v) :))
          anthropicVersion
          [ ("x-api-key", Text.encodeUtf8 apiKey),
            ("Accept", "text/event-stream"),
            ("Content-Type", "application/json")
          ]
  HTTP.withResponse request (Client.manager env) (`sseFromResponse` onEvent)

-- | Consume an @http-client@ response as an Anthropic SSE stream.
sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()
sseFromResponse response onEvent = do
  let st = HTTP.responseStatus response
  if not (Status.statusIsSuccessful st)
    then do
      bodyChunks <- HTTP.brConsume (HTTP.responseBody response)
      let bodyText = decodeLenient (SBS.concat bodyChunks)
          retryAfter =
            parseRetryAfterSeconds . decodeLenient
              =<< lookup (CI.mk "Retry-After") (HTTP.responseHeaders response)
      onEvent (Left (httpError (Status.statusCode st) retryAfter bodyText))
    else do
      lineBufRef <- IORef.newIORef SBS.empty
      eventBufRef <- IORef.newIORef ([] :: [SBS.ByteString])
      let flushEvent = do
            es <- IORef.atomicModifyIORef' eventBufRef (\buf -> ([], reverse buf))
            case es of
              [] -> pure False
              _ -> do
                let payload = S8.concat es
                case Aeson.eitherDecodeStrict payload of
                  Left err -> onEvent (Left (decodeError (Text.pack err))) >> pure False
                  Right val -> case Aeson.fromJSON val of
                    Aeson.Error err -> onEvent (Left (decodeError (Text.pack err))) >> pure False
                    Aeson.Success ev -> onEvent (Right ev) >> pure False

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
