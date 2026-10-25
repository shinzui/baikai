-- | Local persistence parsers. These deliberately introduce no orphan instances.
module Baikai.Internal.JSON (parseAssistant, parseMessage, parseUsage, parseEvidence) where

import Baikai.Cost qualified as C
import Baikai.Evidence qualified as E
import Baikai.Message qualified as M
import Baikai.Usage qualified as U
import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Scientific (Scientific)
import Data.Text (Text)

parseAssistant :: Value -> Parser M.AssistantPayload
parseAssistant = withObject "AssistantPayload" $ \o ->
  M.AssistantPayload
    <$> o .: "content"
    <*> (o .: "usage" >>= parseUsage)
    <*> o .: "stopReason"
    <*> o .:? "errorMessage"
    <*> o .:? "timestamp"

parseMessage :: Value -> Parser M.Message
parseMessage = withObject "Message" $ \o -> do
  tag <- o .: "tag"
  v <- o .: "contents"
  case tag :: Text of
    "AssistantMessage" -> M.AssistantMessage <$> parseAssistant v
    "UserMessage" -> withObject "UserPayload" (\d -> M.UserMessage <$> (M.UserPayload <$> d .: "content" <*> d .:? "timestamp")) v
    "ToolResultMessage" -> withObject "ToolResultPayload" (\d -> M.ToolResultMessage <$> (M.ToolResultPayload <$> d .: "toolCallId" <*> d .: "toolName" <*> d .: "content" <*> d .: "isError" <*> d .:? "timestamp")) v
    _ -> fail "unknown message tag"

parseUsage :: Value -> Parser U.Usage
parseUsage = withObject "Usage" $ \o ->
  U.Usage
    <$> o .: "input_tokens"
    <*> o .: "output_tokens"
    <*> o .: "cache_read_tokens"
    <*> o .: "cache_write_tokens"
    <*> o .:? "reasoning_tokens"
    <*> o .: "total_tokens"
    <*> o .:? "availability"
    <*> (o .: "cost" >>= parseCost)

parseCost :: Value -> Parser C.Cost
parseCost = withObject "Cost" $ \o ->
  C.Cost
    <$> (toRational <$> (o .: "usd" :: Parser Scientific))
    <*> (o .: "breakdown" >>= parseBreakdown)
    <*> o .:? "basis" .!= mempty

parseBreakdown :: Value -> Parser C.CostBreakdown
parseBreakdown = withObject "CostBreakdown" $ \o ->
  let rat k = toRational <$> (o .: k :: Parser Scientific)
   in C.CostBreakdown <$> rat "input_usd" <*> rat "output_usd" <*> rat "cached_input_usd" <*> rat "cached_write_usd"

parseEvidence :: Value -> Parser E.ModelCallEvidence
parseEvidence = withObject "ModelCallEvidence" $ \o ->
  build
    <$> o .: "schema_version"
    <*> o .: "run_id"
    <*> o .: "call_id"
    <*> o .: "attempt"
    <*> o .:? "supersedes"
    <*> o .: "endpoint"
    <*> o .: "requested_model"
    <*> o .: "thinking"
    <*> o .: "observed_model"
    <*> o .: "observed_thinking"
    <*> o .: "response_id"
    <*> o .: "provider_request_id"
    <*> o .:? "client_request_id"
    <*> o .: "started_at"
    <*> o .: "ended_at"
    <*> o .: "latency_ms"
    <*> o .: "status"
    <*> o .:? "error_info"
    <*> (o .: "usage" >>= parseObservedUsage)
    <*> o .: "strength"
    <*> o .: "request_commitment"
    <*> o .: "request_configuration"
    <*> o .: "response_commitment"
  where
    build v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15 v16 v17 v18 v19 v20 v21 v22 =
      (E.baseEvidence (E.evidenceRequest v1) v2 v5 v6 v7 v13 v14 v16 v20 v21)
        { E.schemaVersion = v0,
          E.runId = v1,
          E.callId = v2,
          E.attempt = v3,
          E.supersedes = v4,
          E.endpoint = v5,
          E.requestedModel = v6,
          E.thinking = v7,
          E.observedModel = v8,
          E.observedThinking = v9,
          E.responseId = v10,
          E.providerRequestId = v11,
          E.clientRequestId = v12,
          E.startedAt = v13,
          E.endedAt = v14,
          E.latencyMs = v15,
          E.status = v16,
          E.errorInfo = v17,
          E.usage = v18,
          E.strength = v19,
          E.requestCommitment = v20,
          E.requestConfiguration = v21,
          E.responseCommitment = v22
        }

parseObservedUsage :: Value -> Parser (E.Observed U.Usage)
parseObservedUsage (String "unobserved") = pure E.Unobserved
parseObservedUsage v = withObject "Observed Usage" (\o -> E.Observed <$> (o .: "observed" >>= parseUsage)) v
