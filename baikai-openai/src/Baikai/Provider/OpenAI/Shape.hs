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
    OpenAICompletionsCompat
      ( cacheControlFormat,
        maxTokensField,
        supportsLongCacheRetention,
        supportsStrictMode,
        supportsUsageInStreaming,
        thinkingFormat
      ),
    ThinkingFormat (..),
  )
import Baikai.Evidence
  ( ThinkingAdjustment (..),
    ThinkingMode (..),
    ThinkingTranslation (..),
    noThinkingRequested,
  )
import Baikai.Options (Options, cacheRetention, thinking)
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import OpenAI.V1.Chat.Completions qualified as Chat

-- | Reshape a request body for the target host, and describe what the
-- caller's reasoning-effort preference became while doing it.
--
-- The translation travels back out rather than staying inside
-- 'injectThinkingShape' because nothing downstream can recompute it: it
-- depends on the host's 'ThinkingFormat', which only the compat lookup
-- knows. Written as an explicit pipeline rather than the point-free
-- composition it used to be, so the description has somewhere to escape
-- to.
shapeRequestBody ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)
shapeRequestBody compat opts body =
  let renamed = renameMaxTokens compat body
      stripped = dropUnsupportedStrict compat renamed
      (thought, translation) = injectThinkingShape compat opts stripped
   in (injectCacheControl compat opts thought, translation)

streamRequestBody ::
  OpenAICompletionsCompat ->
  Options ->
  Chat.CreateChatCompletion ->
  (Aeson.Value, ThinkingTranslation)
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

-- | Place the caller's reasoning-effort preference in whichever of the
-- seven shapes the host accepts, and describe what that did to it.
--
-- The body this produces is byte-for-byte what it produced before the
-- description existed. The three shapes that express less than the
-- caller asked for now say so: the five non-native effort shapes clamp
-- through 'compatibleEffort', the two toggle shapes carry no depth at
-- all, and 'ThinkingFormatNone' drops the request entirely.
--
-- The native shape is the one that records __no__ adjustment, because
-- it forwards the canonical level verbatim and therefore expresses all
-- six exactly. That is deliberate and guarded by @nativeHigherEffortTests@
-- in @baikai-openai/test/ShapeSpec.hs@; 'compatibleEffort' is scoped by
-- its own documentation to the non-native shapes and must not be
-- applied here.
injectThinkingShape ::
  OpenAICompletionsCompat -> Options -> Aeson.Value -> (Aeson.Value, ThinkingTranslation)
injectThinkingShape compat opts body =
  case thinking opts of
    Nothing -> (body, noThinkingRequested)
    Just lvl -> case thinkingFormat compat of
      ThinkingFormatOpenAI ->
        let e = renderThinkingLevel lvl
         in ( insertTop "reasoning_effort" (String e) body,
              effortTranslation lvl e "reasoning_effort"
            )
      ThinkingFormatNone ->
        ( body,
          ThinkingTranslation
            { requested = Just lvl,
              mode = ThinkingModeUnsupported,
              effortText = Nothing,
              budgetTokens = Nothing,
              wireField = Nothing,
              adjustments = [ThinkingDroppedUnsupportedHost lvl]
            }
        )
      ThinkingFormatOpenRouter ->
        let e = compatibleEffort lvl
         in ( insertTop "reasoning" (Aeson.object ["effort" .= e]) body,
              effortTranslation lvl e "reasoning"
            )
      ThinkingFormatDeepseek ->
        let e = compatibleEffort lvl
         in ( insertTop "reasoning_effort" (String e) $
                insertTop "thinking" (Aeson.object ["type" .= ("enabled" :: Text)]) body,
              effortTranslation lvl e "reasoning_effort"
            )
      ThinkingFormatTogether ->
        let e = compatibleEffort lvl
         in ( insertTop "reasoning_effort" (String e) $
                insertTop "reasoning" (Aeson.object ["enabled" .= True]) body,
              effortTranslation lvl e "reasoning_effort"
            )
      ThinkingFormatZai ->
        ( insertTop "enable_thinking" (Bool True) body,
          toggleTranslation lvl
        )
      ThinkingFormatQwen ->
        ( insertTop "enable_thinking" (Bool True) body,
          toggleTranslation lvl
        )

-- | A host that steers its own depth from an effort word.
--
-- The adjustment list is derived from the word that actually went on
-- the wire, never from a second table beside the mapping: a word equal
-- to the canonical level name expressed the request exactly, and any
-- other word replaced it with something weaker the host accepts. Seven
-- wire shapes share this one derivation precisely so that adding an
-- eighth cannot leave a hand-written table behind.
effortTranslation :: ThinkingLevel -> Text -> Text -> ThinkingTranslation
effortTranslation lvl wire field =
  ThinkingTranslation
    { requested = Just lvl,
      mode = ThinkingModeAdaptive,
      effortText = Just wire,
      budgetTokens = Nothing,
      wireField = Just field,
      adjustments =
        [EffortClamped lvl wire | wire /= renderThinkingLevel lvl]
    }

-- | A host that accepts thinking on or off and nothing more.
--
-- Every level collapses, including the ones whose canonical name a
-- richer host would have accepted, because the wire carries no depth:
-- a caller asking for @max@ and a caller asking for @low@ produce
-- byte-identical requests here.
toggleTranslation :: ThinkingLevel -> ThinkingTranslation
toggleTranslation lvl =
  ThinkingTranslation
    { requested = Just lvl,
      mode = ThinkingModeToggle,
      effortText = Nothing,
      budgetTokens = Nothing,
      wireField = Just "enable_thinking",
      adjustments = [EffortCollapsedToToggle lvl]
    }

injectCacheControl :: OpenAICompletionsCompat -> Options -> Aeson.Value -> Aeson.Value
injectCacheControl compat opts body =
  case (cacheControlFormat compat, cacheRetention opts) of
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

-- | Common effort vocabulary supported by the non-native
-- OpenAI-compatible request shapes above.
compatibleEffort :: ThinkingLevel -> Text
compatibleEffort = \case
  ThinkingMinimal -> "low"
  ThinkingLow -> "low"
  ThinkingMedium -> "medium"
  ThinkingHigh -> "high"
  ThinkingXHigh -> "high"
  ThinkingMax -> "high"
