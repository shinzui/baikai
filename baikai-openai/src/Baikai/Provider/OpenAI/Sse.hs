{-# LANGUAGE LambdaCase #-}

-- | Local SSE transport for OpenAI Chat Completions streams.
module Baikai.Provider.OpenAI.Sse
  ( openaiSseStream,
    openaiSseStreamValue,
    sseFromResponse,
  )
where

import Baikai.Error (BaikaiError, decodeError, httpError, parseRetryAfterSeconds)
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
import OpenAI.V1.Chat.Completions qualified as Chat
import Servant.Client qualified as Client

-- | POST the request to @/v1/chat/completions@ and feed decoded SSE
-- JSON payloads to the callback. A @data: [DONE]@ frame ends the
-- stream without producing a callback value.
openaiSseStream ::
  Client.ClientEnv ->
  Text ->
  Chat.CreateChatCompletion ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
openaiSseStream env apiKey req =
  openaiSseStreamValue env apiKey (Aeson.toJSON req)

openaiSseStreamValue ::
  Client.ClientEnv ->
  Text ->
  Aeson.Value ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()
openaiSseStreamValue env apiKey requestBody onEvent = do
  let base = Client.baseUrl env
      secure = case Client.baseUrlScheme base of
        Client.Http -> False
        Client.Https -> True
      request =
        HTTP.defaultRequest
          { HTTP.secure = secure,
            HTTP.host = S8.pack (Client.baseUrlHost base),
            HTTP.port = Client.baseUrlPort base,
            HTTP.method = "POST",
            HTTP.path = S8.pack (normalizePath (Client.baseUrlPath base) <> "/v1/chat/completions"),
            HTTP.requestHeaders =
              [ ("Authorization", Text.encodeUtf8 ("Bearer " <> apiKey)),
                ("Accept", "text/event-stream"),
                ("Content-Type", "application/json")
              ],
            HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode requestBody),
            -- EP-8 wires Options.timeoutMs through this local transport.
            HTTP.responseTimeout = HTTP.responseTimeoutNone
          }
  HTTP.withResponse request (Client.manager env) (`sseFromResponse` onEvent)

sseFromResponse ::
  HTTP.Response HTTP.BodyReader ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
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
