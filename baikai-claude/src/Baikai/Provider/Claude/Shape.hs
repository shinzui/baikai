{-# LANGUAGE LambdaCase #-}

-- | __Exposed with no stability guarantees.__ This module is exposed so
-- the test suites can drive the transport without a socket, and so
-- sibling packages can reuse its pieces; it is not part of the public
-- API and may change in /any/ release without a PVP major bump.
--
-- Pure request-body shaping for Anthropic-compatible Messages hosts.
module Baikai.Provider.Claude.Shape
  ( shapeRequestBody,
    streamRequestBody,
    replaceToolSchemas,
    injectToolChoiceNone,
    injectToolCacheControl,
    injectSystemCacheControl,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat (AnthropicMessagesCompat (supportsCacheControlOnTools, supportsLongCacheRetention))
import Baikai.Context (Context, tools)
import Baikai.Options (Options, cacheRetention, toolChoice)
import Baikai.Tool qualified as Tool
import Claude.V1.Messages qualified as Messages
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Vector qualified as Vector

shapeRequestBody ::
  AnthropicMessagesCompat ->
  Context ->
  Options ->
  Aeson.Value ->
  Aeson.Value
shapeRequestBody compat ctx opts =
  injectSystemCacheControl compat opts
    . injectToolCacheControl compat opts
    . injectToolChoiceNone opts
    . replaceToolSchemas ctx

streamRequestBody ::
  AnthropicMessagesCompat ->
  Context ->
  Options ->
  Messages.CreateMessage ->
  Aeson.Value
streamRequestBody compat ctx opts req =
  shapeRequestBody compat ctx opts (Aeson.toJSON req {Messages.stream = Just True})

replaceToolSchemas :: Context -> Aeson.Value -> Aeson.Value
replaceToolSchemas ctx
  | Vector.null toolsVec = id
  | otherwise =
      mapObject $
        adjustKey (key "tools") $
          mapTools (Vector.toList toolsVec)
  where
    toolsVec = tools ctx

injectToolChoiceNone :: Options -> Aeson.Value -> Aeson.Value
injectToolChoiceNone opts
  | Just Tool.ToolChoiceNone <- toolChoice opts =
      mapObject (KeyMap.insert (key "tool_choice") (Aeson.object ["type" .= ("none" :: Text)]))
  | otherwise = id

injectToolCacheControl :: AnthropicMessagesCompat -> Options -> Aeson.Value -> Aeson.Value
injectToolCacheControl compat opts body =
  case (supportsCacheControlOnTools compat, cacheRetention opts) of
    (True, Just retention)
      | Just marker <- cacheControlMarker compat retention ->
          mapObject (adjustKey (key "tools") (markLastTool marker)) body
    _ -> body

-- | Put a @cache_control@ breakpoint on the system prompt when the
-- caller asked for cache retention.
--
-- The top-level marker that
-- 'Baikai.Provider.Claude.Internal.Request.computeCacheControl' sends is
-- Anthropic's automatic caching: it places its breakpoint on the last
-- cacheable block. Without a breakpoint on the shared prefix, changing
-- the first user message prevents reuse of an earlier end-of-request
-- entry. The system-block breakpoint caches that shared prefix
-- (tools, then system) on its own.
--
-- A plain-string @system@ becomes a one-element array of text blocks
-- carrying the same marker, with the same TTL as the top-level one, so
-- Anthropic's "longer TTL first" ordering rule holds. Together with the
-- automatic and the last-tool breakpoints this uses three of the four
-- slots Anthropic allows. An absent or empty system prompt is left
-- alone: Anthropic rejects empty text blocks.
injectSystemCacheControl :: AnthropicMessagesCompat -> Options -> Aeson.Value -> Aeson.Value
injectSystemCacheControl compat opts body =
  case cacheRetention opts of
    Just retention
      | Just marker <- cacheControlMarker compat retention ->
          mapObject (adjustKey (key "system") (markSystem marker)) body
    _ -> body

markSystem :: Aeson.Value -> Aeson.Value -> Aeson.Value
markSystem marker = \case
  String txt
    | txt /= "" ->
        Array
          ( Vector.singleton
              ( Aeson.object
                  [ "type" .= ("text" :: Text),
                    "text" .= txt,
                    "cache_control" .= marker
                  ]
              )
          )
  other -> other

mapTools :: [Tool.Tool] -> Aeson.Value -> Aeson.Value
mapTools toolDefs = \case
  Array toolsJson ->
    Array (Vector.imap patchTool toolsJson)
  other -> other
  where
    patchTool i =
      case drop i toolDefs of
        t : _ -> replaceInputSchema (Tool.parameters t)
        [] -> id

replaceInputSchema :: Aeson.Value -> Aeson.Value -> Aeson.Value
replaceInputSchema schema =
  mapObject (KeyMap.insert (key "input_schema") schema)

markLastTool :: Aeson.Value -> Aeson.Value -> Aeson.Value
markLastTool marker = \case
  Array toolsJson
    | not (Vector.null toolsJson) ->
        let i = Vector.length toolsJson - 1
         in Array (toolsJson Vector.// [(i, markTool marker (toolsJson Vector.! i))])
  other -> other

markTool :: Aeson.Value -> Aeson.Value -> Aeson.Value
markTool marker =
  mapObject (KeyMap.insert (key "cache_control") marker)

cacheControlMarker :: AnthropicMessagesCompat -> CacheRetention -> Maybe Aeson.Value
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
