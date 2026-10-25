-- | Explicitly registered, non-streaming HTTP judgments with atomic data events.
module Baikai.Provider.TypeSafe.Api (register, typesafeProvider, typesafeStream) where

import Baikai
import Baikai.Evidence qualified as E
import Baikai.Evidence.Build qualified as Build
import Baikai.Http qualified as Http
import Baikai.Provider.Transport.Classify (classifyTransportException)
import Baikai.Provider.TypeSafe.Internal.Request qualified as R
import Baikai.Provider.TypeSafe.Internal.Response qualified as D
import Baikai.Url qualified as Url
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as V
import Data.Version (showVersion)
import Network.HTTP.Client qualified as H
import Network.HTTP.Types.Header (ResponseHeaders)
import Network.HTTP.Types.Status (statusCode)
import Paths_baikai_typesafe qualified as Paths
import Servant.Client qualified as Client
import Streamly.Data.Stream (Stream)
import System.Timeout (timeout)
import TypeSafe.Wire qualified as W

register :: IO ()
register = registerApiProvider typesafeProvider

typesafeProvider :: ApiProvider
typesafeProvider =
  apiProvider TypeSafeSystemOne typesafeStream
    & #describeThinking .~ (\_ opts -> Build.requestedTranslation opts)
    & #strengthCeiling .~ E.declaredStrength TypeSafeSystemOne
    & #structuredOutput .~ declaredStructuredOutput TypeSafeSystemOne

typesafeStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
typesafeStream = liftCompleteToStream completeTypeSafe

completeTypeSafe :: Model -> Context -> Options -> IO Response
completeTypeSafe m ctx opts = do
  started <- getCurrentTime
  headerRef <- newIORef []
  bodyRef <- newIORef Nothing
  envelopeRef <- newIORef (Build.dispatchEnvelope m opts)
  let base = if T.null (m ^. #baseUrl) then W.defaultBaseUrl else m ^. #baseUrl
      action = do
        (js, wire) <- either throwIO pure (R.prepareRequest m ctx opts)
        let bytes = R.requestBytes wire
            envelope = fromMaybe A.Null (A.decode bytes)
        writeIORef envelopeRef envelope
        case opts ^. #timeoutMs of
          Just ms | ms <= 0 -> throwIO (unsupportedFeature "Options.timeoutMs" "timeoutMs must be positive")
          _ -> pure ()
        case Url.baseUrlProblem base of
          Just why -> throwIO (invalidRequest ("Model.baseUrl is not usable: " <> why))
          Nothing -> pure ()
        canonical <- either (throwIO . invalidRequest) pure (Http.canonicalBaseUrl base)
        key <- case opts ^. #apiKey of
          Just source -> resolveApiKey source
          Nothing -> case defaultApiKeyEnvForBaseUrl base of
            Just env -> resolveApiKey (ApiKeyEnv env)
            Nothing -> throwIO (authError "Custom TypeSafe hosts require an explicit Options.apiKey source")
        env <- Http.getClientEnvCached base
        request <- H.parseRequest (Client.showBaseUrl canonical <> "/v1/systemone")
        let headers = Map.unions [opts ^. #headers, m ^. #headers, Map.fromList [("Authorization", "Bearer " <> key), ("Content-Type", "application/json")]]
            req =
              request
                { H.method = "POST",
                  H.requestBody = H.RequestBodyLBS bytes,
                  H.requestHeaders = [(CI.mk (TE.encodeUtf8 (renderHeaderName k)), TE.encodeUtf8 v) | (k, v) <- Map.toList headers],
                  H.redirectCount = 0,
                  H.checkResponse = \_ _ -> pure (),
                  H.responseTimeout = H.responseTimeoutNone
                }
        H.withResponse req (Client.manager env) $ \response -> do
          writeIORef headerRef (H.responseHeaders response)
          body <- BL.fromChunks <$> H.brConsume (H.responseBody response)
          writeIORef bodyRef (Just body)
          let status = statusCode (H.responseStatus response)
          if status >= 200 && status < 300
            then either throwIO pure (D.decodeResponse m js body)
            else do
              now <- getCurrentTime
              throwIO (statusError m now status (H.responseHeaders response) body)
      bounded = case opts ^. #timeoutMs of
        Just ms | ms > 0 -> do
          result <- timeout (fromInteger (min (toInteger (maxBound :: Int)) (toInteger ms * 1000))) action
          maybe (throwIO ((providerError ("TypeSafe call exceeded timeoutMs=" <> T.pack (show ms))) & #category .~ TransientError)) pure result
        _ -> action
  result <- trySync bounded
  ended <- getCurrentTime
  headers <- readIORef headerRef
  body <- readIORef bodyRef
  envelope <- readIORef envelopeRef
  let latency = max 0 (round (diffUTCTime ended started * 1000))
      err = either Just (const Nothing) result
      response = case result of
        Left e -> errorResponse m ended latency e
        Right (dat, _, u) ->
          emptyResponse
            & #model .~ m
            & #api .~ (m ^. #api)
            & #provider .~ (m ^. #provider)
            & #latencyMs .~ latency
            & #message .~ AssistantPayload (V.singleton (AssistantData dat)) u Stop Nothing (Just ended)
      (observedModel, observedUsage) = maybe (Unobserved, Unobserved) (D.responseObservations m) body
      requestId = maybe Unobserved (Observed . TE.decodeUtf8With lenientDecode) (lookup W.requestIdHeader headers)
      responseCommitment = case result of
        Right _ -> Observed (commitmentDigest (A.object ["content" A..= (response ^. #message . #content), "stop_reason" A..= Stop, "usage" A..= E.usageEnvelope (response ^. #message . #usage)]))
        Left _ -> maybe Unobserved (\bytes -> Observed (commitmentDigest (fromMaybe (A.String (TE.decodeUtf8With lenientDecode (BL.toStrict bytes))) (A.decode bytes)))) body
  evidence <- Build.minimalEvidenceAt base m opts TransportHttpApi (Build.requestedTranslation opts) envelope started ended (if isJustError err then E.CallFailed else CallSucceeded) err
  let enrich e =
        e
          & #observedModel .~ observedModel
          & #usage .~ observedUsage
          & #providerRequestId .~ requestId
          & #responseCommitment .~ responseCommitment
          & #strength .~ E.deriveStrength observedModel requestId Unobserved
          & #endpoint . #implementationVersion .~ Just (T.pack (showVersion Paths.version))
  pure (response & #evidence .~ fmap enrich evidence)
  where
    isJustError Nothing = False; isJustError (Just _) = True

trySync :: IO a -> IO (Either BaikaiError a)
trySync action = do
  result <- try action
  case result of
    Right x -> pure (Right x)
    Left e
      | Just async <- (fromException e :: Maybe SomeAsyncException) -> throwIO async
      | otherwise -> pure (Left (exceptionError e))

exceptionError :: SomeException -> BaikaiError
exceptionError e = case fromException e of
  Just be -> be
  Nothing -> fromMaybe (providerError (T.pack (displayException e))) (classifyTransportException e)

statusError :: Model -> UTCTime -> Int -> ResponseHeaders -> BL.ByteString -> BaikaiError
statusError m now status headers bytes =
  let reference = fromMaybe now (lookup "Date" headers >>= parseHttpDate . TE.decodeUtf8With lenientDecode)
      retry = lookup "Retry-After" headers >>= retryAfterSecondsAt reference . TE.decodeUtf8With lenientDecode
      wire = W.parseErrorBody bytes
      detail = case wire of
        W.ErrorBodyDetail d -> d ^. #message
        W.ErrorBodyDetailText t -> t
        W.ErrorBodyValidation v -> case v ^. #detail >>= (V.!? 0) of
          Just d -> T.intercalate "." [case x of { W.LocationField t -> t; W.LocationIndex i -> T.pack (show i) } | x <- V.toList (d ^. #loc)] <> ": " <> d ^. #msg
          Nothing -> "TypeSafe validation error"
        _ -> TE.decodeUtf8With lenientDecode (BL.toStrict bytes)
      base = httpError status retry detail
   in case wire of
        W.ErrorBodyDetail d | status == 400, d ^. #errorType == Just "api_usage_error", "Unknown model:" `T.isPrefixOf` (d ^. #message) -> base & #requestProblem .~ Just (UnsupportedModel (m ^. #modelId))
        _ -> base
