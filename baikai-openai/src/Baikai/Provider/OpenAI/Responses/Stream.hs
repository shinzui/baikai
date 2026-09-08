{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal Responses transport integration; no stability guarantee.
module Baikai.Provider.OpenAI.Responses.Stream
  ( openaiResponsesStreamWith,
    liveResponsesDriver,
  )
where

import Baikai.Content qualified as C
import Baikai.Context (Context)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError, invalidRequest, providerError)
import Baikai.Evidence qualified as Ev
import Baikai.Evidence.Build qualified as Build
import Baikai.Message qualified as M
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Internal.StreamWorker
import Baikai.Provider.OpenAI.Internal.ErrorClass (classifyErrorFrame, classifyException)
import Baikai.Provider.OpenAI.Internal.Stream (SseDriver)
import Baikai.Provider.OpenAI.Internal.Usage qualified as Billing
import Baikai.Provider.OpenAI.Responses.Assembler qualified as A
import Baikai.Provider.OpenAI.Responses.Request qualified as R
import Baikai.Provider.OpenAI.Sse (ResponseMetadata, capturedHeaderNames, responsesSseStreamValueWithHeaders)
import Baikai.Provider.OpenAI.Transport qualified as Transport
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event qualified as E
import Baikai.Url qualified as Url
import Baikai.Usage qualified as U
import Control.Applicative ((<|>))
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Vector qualified as V
import Data.Version (showVersion)
import Paths_baikai_openai qualified as Paths
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

liveResponsesDriver :: SseDriver
liveResponsesDriver = responsesSseStreamValueWithHeaders

openaiResponsesStreamWith :: SseDriver -> Model -> Context -> Options -> Stream IO E.AssistantMessageEvent
openaiResponsesStreamWith driver m ctx opts = Stream.concatEffect $ do
  setup <- trySync $ do
    req <- either (throwIO . invalidRequest) pure (R.mapRequest m ctx opts)
    let url = resolvedUrl m
    case Url.baseUrlProblem url of
      Just problem -> throwIO (invalidRequest ("Model.baseUrl is not usable: " <> problem))
      Nothing -> pure ()
    key <- Transport.resolveKey url opts
    env <- Transport.getClientEnvCached url
    pure (req, env, Transport.requestHeaders key m opts)
  case setup of
    Left ex -> Stream.fromList <$> immediateError m opts (exceptionToError ex)
    Right (req, env, headers) -> do
      q <- newFrameQueue
      meta <- newIORef Nothing
      start <- getCurrentTime
      evidence <- Build.prepareEvidenceAt (resolvedUrl m) m opts Ev.TransportHttpApi req.translation req.requestBody start
      let worker = do
            result <-
              trySync $
                Transport.runWithTimeout (opts ^. #timeoutMs) $
                  driver env headers req.requestBody (writeIORef meta . Just) (pushFrame q)
            case result of
              Left ex -> pushFrame q (Left (exceptionToError ex))
              Right (Just err) -> pushFrame q (Left err)
              Right Nothing -> pure ()
          initial = State q meta m (A.emptyAssembler (m ^. #modelId)) Nothing [E.EventStart (E.StartPayload (message V.empty U.zeroUsage Stop Nothing start) Nothing)] False evidence
      pure (withFrameWorker q worker (Stream.unfoldrM step initial))

data State = State
  { queue :: !(FrameQueue (Either BaikaiError Value)),
    metadata :: !(IORef (Maybe ResponseMetadata)),
    model :: !Model,
    assembler :: !A.Assembler,
    observed :: !(Maybe Value),
    pending :: ![E.AssistantMessageEvent],
    finished :: !Bool,
    evidence :: !(Maybe (UTCTime -> Ev.CallStatus -> Maybe BaikaiError -> Ev.ModelCallEvidence))
  }

step :: State -> IO (Maybe (E.AssistantMessageEvent, State))
step s
  | e : rest <- s.pending = pure (Just (e, s {pending = rest}))
  | s.finished = pure Nothing
  | otherwise = do
      next <- pullFrame s.queue
      case next of
        Nothing -> terminate (Just (providerError "Responses stream ended without a terminal response")) s
        Just (Left err) -> terminate (Just err) s
        Just (Right raw) -> do
          let obs = mergeObservation s.observed (lookupField "response" raw)
              current = s {observed = obs}
          case responseError raw of
            Just err -> terminate (Just err) current
            Nothing -> case A.advance raw s.assembler of
              Left err -> terminate (Just (providerError err)) current
              Right (assembled, events) -> do
                let updated = current {assembler = assembled, pending = events}
                case A.terminalReason assembled of
                  Nothing -> step updated
                  Just _ -> terminate Nothing updated

-- The terminal is conclusive for Responses: releasing the stream also
-- cancels a driver that keeps waiting after response.completed.
terminate :: Maybe BaikaiError -> State -> IO (Maybe (E.AssistantMessageEvent, State))
terminate err s = do
  now <- getCurrentTime
  md <- readIORef s.metadata
  let (assembled, closes) = case err of
        Nothing -> (s.assembler, [])
        Just _ -> A.closePartial s.assembler
      reason = maybe (fromMaybe Stop (A.terminalReason assembled)) (const ErrorReason) err
      usage = responseUsage s.model s.observed
      payload = M.AssistantPayload (A.assembledContent assembled) usage reason (fmap (^. #message) err) (Just now)
      msg = M.AssistantMessage payload
      rid = s.observed >>= textField "id"
      status = maybe Ev.CallSucceeded (const Ev.CallFailed) err
      proof = fmap (\finish -> observe status md s.observed payload (finish now status err)) s.evidence
      terminal = case err of
        Nothing -> E.EventDone (E.doneTerminal proof rid reason msg)
        Just be -> E.EventError (E.errorTerminal proof rid reason msg be)
  step s {assembler = assembled, pending = s.pending <> closes <> [terminal], finished = True}

message :: V.Vector C.AssistantContent -> U.Usage -> StopReason -> Maybe Text -> UTCTime -> M.Message
message content usage reason note now = M.AssistantMessage (M.AssistantPayload content usage reason note (Just now))

resolvedUrl :: Model -> Text
resolvedUrl m = case m ^. #baseUrl of "" -> "https://api.openai.com"; u -> u

immediateError :: Model -> Options -> BaikaiError -> IO [E.AssistantMessageEvent]
immediateError m opts err = do
  now <- getCurrentTime
  let msg = message V.empty U.zeroUsage ErrorReason (Just (err ^. #message)) now
  proof <- Build.minimalEvidenceAt (resolvedUrl m) m opts Ev.TransportHttpApi (R.describeThinking m opts) (Build.dispatchEnvelope m opts) now now Ev.CallFailed (Just err)
  pure [E.EventStart (E.StartPayload msg Nothing), E.EventError (E.errorTerminal proof Nothing ErrorReason msg err)]

responseError :: Value -> Maybe BaikaiError
responseError raw = case textField "type" raw of
  Just "error" -> classifyErrorFrame (object ["error" .= raw]) <|> Just (providerError "Responses error event")
  Just "response.failed" -> (lookupField "response" raw >>= classifyErrorFrame) <|> Just (providerError "Responses response.failed")
  _ -> classifyErrorFrame raw

mergeObservation :: Maybe Value -> Maybe Value -> Maybe Value
mergeObservation old Nothing = old
mergeObservation (Just (Object old)) (Just (Object new)) =
  let merged = KM.union new old
      usage = Billing.mergeUsage (KM.lookup "usage" old) (KM.lookup "usage" new)
   in Just (Object (maybe merged (\u -> KM.insert "usage" u merged) usage))
mergeObservation _ new = new

-- Known counts and their availability travel together into payload and evidence.
responseUsage :: Model -> Maybe Value -> U.Usage
responseUsage m raw =
  let normalized = U.observeBilling [U.BillingServiceTier tier | Just tier <- [raw >>= textField "service_tier"]] (fromMaybe Billing.unreportedUsage (raw >>= lookupField "usage" >>= Billing.readUsage Billing.ResponsesUsage))
   in normalized & #cost .~ Pricing.computeCostForService Nothing Nothing m normalized

observe :: Ev.CallStatus -> Maybe ResponseMetadata -> Maybe Value -> M.AssistantPayload -> Ev.ModelCallEvidence -> Ev.ModelCallEvidence
observe status md raw payload ev =
  let seenModel = maybe Ev.Unobserved Ev.Observed (raw >>= textField "model")
      rid = maybe Ev.Unobserved Ev.Observed (raw >>= textField "id")
      requestId = case md of
        Nothing -> Ev.Unobserved
        Just meta -> case [v | n <- capturedHeaderNames, Just v <- [lookup (T.decodeUtf8 (CI.foldedCase n)) (meta ^. #headers)]] of
          v : _ -> Ev.Observed v
          [] -> Ev.Unobserved
      allCounts = do
        _ <- raw >>= lookupField "usage" >>= Billing.readUsage Billing.ResponsesUsage
        pure (payload ^. #usage)
      commitment =
        if status == Ev.CallSucceeded
          then Ev.Observed (Ev.commitmentDigest (object ["content" .= (payload ^. #content), "stop_reason" .= (payload ^. #stopReason), "usage" .= Ev.usageEnvelope (payload ^. #usage)]))
          else Ev.Unobserved
   in ev
        & #endpoint . #implementationVersion .~ Just (T.pack (showVersion Paths.version))
        & #observedModel .~ seenModel
        & #responseId .~ rid
        & #providerRequestId .~ requestId
        & #usage .~ maybe Ev.Unobserved Ev.Observed allCounts
        & #responseCommitment .~ commitment
        & #strength .~ Ev.deriveStrength seenModel requestId rid

lookupField :: Key -> Value -> Maybe Value
lookupField k (Object o) = KM.lookup k o
lookupField _ _ = Nothing

textField :: Key -> Value -> Maybe Text
textField k v = lookupField k v >>= \case String t | not (T.null t) -> Just t; _ -> Nothing

trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  result <- try action
  case result of
    Left ex | Just _ <- (fromException ex :: Maybe SomeAsyncException) -> throwIO ex
    _ -> pure result

exceptionToError :: SomeException -> BaikaiError
exceptionToError ex = fromMaybe (classifyException ex) (fromException ex)
