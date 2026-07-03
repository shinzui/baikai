{-# LANGUAGE LambdaCase #-}

-- | Pure request-body shaping for OpenAI-compatible Chat Completions hosts.
module Baikai.Provider.OpenAI.Shape
  ( shapeRequestBody,
    streamRequestBody,
    renameMaxTokens,
    dropUnsupportedStrict,
    injectThinkingShape,
    injectCacheControl,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat
  ( CacheControlFormat (..),
    MaxTokensField (..),
    OpenAICompletionsCompat (..),
    ThinkingFormat (..),
  )
import Baikai.Options (Options (..))
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import OpenAI.V1.Chat.Completions qualified as Chat

shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
shapeRequestBody compat opts =
  injectCacheControl compat opts
    . injectThinkingShape compat opts
    . dropUnsupportedStrict compat
    . renameMaxTokens compat

streamRequestBody ::
  OpenAICompletionsCompat ->
  Options ->
  Chat.CreateChatCompletion ->
  Aeson.Value
streamRequestBody compat opts req =
  shapeRequestBody compat opts (Aeson.toJSON req')
  where
    req' =
      req
        { Chat.stream = Just True,
          Chat.stream_options =
            if supportsUsageInStreaming compat
              then
                Just
                  Chat._ChatCompletionStreamOptions
                    { Chat.include_usage = Just True
                    }
              else Nothing
        }

renameMaxTokens :: OpenAICompletionsCompat -> Aeson.Value -> Aeson.Value
renameMaxTokens compat
  | maxTokensField compat /= MaxTokensField = id
  | otherwise =
      mapObject $ \obj ->
        case KeyMap.lookup (key "max_completion_tokens") obj of
          Nothing -> obj
          Just v ->
            KeyMap.insert (key "max_tokens") v $
              KeyMap.delete (key "max_completion_tokens") obj

dropUnsupportedStrict :: OpenAICompletionsCompat -> Aeson.Value -> Aeson.Value
dropUnsupportedStrict compat
  | supportsStrictMode compat = id
  | otherwise =
      mapObject $
        adjustKey (key "response_format") $
          mapObject $
            adjustKey (key "json_schema") $
              mapObject (KeyMap.delete (key "strict"))

injectThinkingShape :: OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
injectThinkingShape compat Options {thinking = thinkingOpt} body =
  case thinkingOpt of
    Nothing -> body
    Just lvl -> case thinkingFormat compat of
      ThinkingFormatOpenAI -> body
      ThinkingFormatNone -> body
      ThinkingFormatOpenRouter ->
        insertTop "reasoning" (Aeson.object ["effort" .= effort lvl]) body
      ThinkingFormatDeepseek ->
        insertTop "reasoning_effort" (String (effort lvl)) $
          insertTop "thinking" (Aeson.object ["type" .= ("enabled" :: Text)]) body
      ThinkingFormatTogether ->
        insertTop "reasoning_effort" (String (effort lvl)) $
          insertTop "reasoning" (Aeson.object ["enabled" .= True]) body
      ThinkingFormatZai ->
        insertTop "enable_thinking" (Bool True) body
      ThinkingFormatQwen ->
        insertTop "enable_thinking" (Bool True) body

injectCacheControl :: OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
injectCacheControl compat Options {cacheRetention = retentionOpt} body =
  case (cacheControlFormat compat, retentionOpt) of
    (Just CacheControlFormatAnthropic, Just retention)
      | Just marker <- cacheControlMarker compat retention ->
          mapObject
            (adjustKey (key "messages") (shapeMessages marker))
            body
    _ -> body

cacheControlMarker :: OpenAICompletionsCompat -> CacheRetention -> Maybe Aeson.Value
cacheControlMarker compat = \case
  CacheRetentionNone -> Nothing
  CacheRetentionShort -> Just (Aeson.object ["type" .= ("ephemeral" :: Text)])
  CacheRetentionLong ->
    if supportsLongCacheRetention compat
      then
        Just
          ( Aeson.object
              [ "type" .= ("ephemeral" :: Text),
                "ttl" .= ("1h" :: Text)
              ]
          )
      else Just (Aeson.object ["type" .= ("ephemeral" :: Text)])

shapeMessages :: Aeson.Value -> Aeson.Value -> Aeson.Value
shapeMessages marker = \case
  Array messages ->
    let target =
          findLastIndex isSystemMessage messages
            `orElse` findLastIndex isUserMessage messages
     in case target of
          Nothing -> Array messages
          Just i ->
            Array (messages Vector.// [(i, shapeMessage marker (messages Vector.! i))])
  other -> other

shapeMessage :: Aeson.Value -> Aeson.Value -> Aeson.Value
shapeMessage marker =
  mapObject (adjustKey (key "content") (shapeContent marker))

shapeContent :: Aeson.Value -> Aeson.Value -> Aeson.Value
shapeContent marker = \case
  Array parts
    | not (Vector.null parts) ->
        let i = Vector.length parts - 1
         in Array (parts Vector.// [(i, shapeContentPart marker (parts Vector.! i))])
  other -> other

shapeContentPart :: Aeson.Value -> Aeson.Value -> Aeson.Value
shapeContentPart marker =
  mapObject (KeyMap.insert (key "cache_control") marker)

isSystemMessage :: Aeson.Value -> Bool
isSystemMessage = hasRole "system"

isUserMessage :: Aeson.Value -> Bool
isUserMessage = hasRole "user"

hasRole :: Text -> Aeson.Value -> Bool
hasRole role = \case
  Object obj -> KeyMap.lookup (key "role") obj == Just (String role)
  _ -> False

findLastIndex :: (Aeson.Value -> Bool) -> Vector Aeson.Value -> Maybe Int
findLastIndex p =
  fmap fst
    . lastMay
    . filter (p . snd)
    . zip [0 ..]
    . Vector.toList

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y

insertTop :: Text -> Aeson.Value -> Aeson.Value -> Aeson.Value
insertTop k v = mapObject (KeyMap.insert (key k) v)

mapObject :: (KeyMap Aeson.Value -> KeyMap Aeson.Value) -> Aeson.Value -> Aeson.Value
mapObject f = \case
  Object obj -> Object (f obj)
  other -> other

adjustKey ::
  AesonKey.Key ->
  (Aeson.Value -> Aeson.Value) ->
  KeyMap Aeson.Value ->
  KeyMap Aeson.Value
adjustKey k f obj =
  case KeyMap.lookup k obj of
    Nothing -> obj
    Just old -> KeyMap.insert k (f old) obj

key :: Text -> AesonKey.Key
key = AesonKey.fromText

effort :: ThinkingLevel -> Text
effort = \case
  ThinkingMinimal -> "low"
  ThinkingLow -> "low"
  ThinkingMedium -> "medium"
  ThinkingHigh -> "high"
