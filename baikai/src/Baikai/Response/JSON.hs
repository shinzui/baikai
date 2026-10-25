-- | Named full-response persistence, without global response/usage instances.
-- Decimal costs use the existing encoder's precision; arbitrary rationals
-- are not promised to round-trip exactly. Optional evidence is preserved.
module Baikai.Response.JSON (responseToJSON, responseFromJSON) where

import Baikai.Internal.JSON (parseAssistant, parseEvidence)
import Baikai.Response (Response (..))
import Data.Aeson
import Data.Aeson.Types (Parser)

responseToJSON :: Response -> Value
responseToJSON r =
  object $
    [ "message" .= message r,
      "model" .= model r,
      "api" .= api r,
      "provider" .= provider r,
      "responseId" .= responseId r,
      "latencyMs" .= latencyMs r,
      "errorInfo" .= errorInfo r
    ]
      <> maybe [] (\e -> ["evidence" .= e]) (evidence r)

responseFromJSON :: Value -> Parser Response
responseFromJSON = withObject "Response" $ \o ->
  Response
    <$> (o .: "message" >>= parseAssistant)
    <*> o .: "model"
    <*> o .: "api"
    <*> o .: "provider"
    <*> o .:? "responseId"
    <*> o .: "latencyMs"
    <*> o .:? "errorInfo"
    <*> (o .:? "evidence" >>= traverse parseEvidence)
