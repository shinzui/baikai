{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal Responses request mapping; no stability guarantee.
-- The released SDK (mori://MercuryTechnologies/openai/packages/openai,
-- 2.5.4) supplies the ordinary request/tool types. Local JSON below covers
-- its missing assistant input role, json_object format, current
-- effort vocabulary, cache options, and lossless opaque replay items.
module Baikai.Provider.OpenAI.Responses.Request
  ( PreparedRequest (..),
    mapRequest,
    describeThinking,
    validateReplay,
    validateReplayItems,
  )
where

import Baikai.Api (Api (..), normaliseApi)
import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat (OpenAIResponsesCompat (..))
import Baikai.Content qualified as C
import Baikai.Context (Context (..))
import Baikai.Evidence qualified as E
import Baikai.Message qualified as M
import Baikai.Model (Model, api, maxOutputTokens, modelId, openaiResponsesCompatFor, reasoning)
import Baikai.Options (Options (..))
import Baikai.Provider.OpenAI.Shape (resolveSupportedEffort)
import Baikai.ResponseFormat (JsonSchemaFormat (..), ResponseFormat (..))
import Baikai.ThinkingLevel (renderThinkingLevel)
import Baikai.Tool qualified as T
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LBS
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as V
import GHC.Generics (Generic)
import OpenAI.V1.Models qualified as SDK
import OpenAI.V1.Responses qualified as R

-- | The exact wire body and the description derived while shaping it.
-- No Show instance: a prepared body can contain opaque continuation.
data PreparedRequest = PreparedRequest
  { requestBody :: !Value,
    translation :: !E.ThinkingTranslation
  }
  deriving stock (Eq, Generic)

mapRequest :: Model -> Context -> Options -> Either Text PreparedRequest
mapRequest m ctx opts = do
  unless (normaliseApi m.api == OpenAIResponses) (Left "Responses requires Model.api = OpenAIResponses")
  let compat = openaiResponsesCompatFor m
      unsupported = [name | (name, present) <- [("stopSequences", not (null opts.stopSequences)), ("seed", isJust opts.seed), ("frequencyPenalty", isJust opts.frequencyPenalty), ("presencePenalty", isJust opts.presencePenalty)], present]
  unless (null unsupported) (Left ("Responses cannot encode Options fields: " <> Text.intercalate ", " unsupported))
  case compat.supportedReasoningEfforts of
    Just xs | null xs || xs /= sort (nub xs) -> Left "supportedReasoningEfforts must be nonempty, unique and ordered"
    _ -> pure ()
  metadata <- traverse metadataText opts.metadata
  unless (Map.size metadata <= 16 && all ((<= 64) . Text.length) (Map.keys metadata)) (Left "Responses metadata allows at most 16 keys of at most 64 characters")
  items <- concat <$> traverse (messageItems m) (V.toList ctx.messages)
  let ids = [i | Object item <- items, Just (String i) <- [KM.lookup "id" item]]
  unless (length ids == length (nub ids)) (Left "Responses history contains duplicate item IDs")
  choice <- toolChoiceFields ctx opts
  cache <- cacheFields m opts
  let (reasoning, translation) = thinkingFields m opts
      cap = fromMaybe m.maxOutputTokens opts.maxTokens
      base =
        Aeson.toJSON
          R._CreateResponse
            { R.model = SDK.Model m.modelId,
              R.instructions = ctx.systemPrompt,
              R.store = Just False,
              R.stream = Just True,
              R.include = Just (V.singleton "reasoning.encrypted_content"),
              R.max_output_tokens = if cap == 0 then Nothing else Just cap,
              R.temperature = if compat.supportsSamplingParameters then opts.temperature else Nothing,
              R.top_p = if compat.supportsSamplingParameters then opts.topP else Nothing,
              R.metadata = if Map.null metadata then Nothing else Just metadata,
              R.tools = if V.null ctx.tools then Nothing else Just (V.map sdkTool ctx.tools)
            }
      extras = [("input", Aeson.toJSON items)] <> reasoning <> choice <> cache <> formatFields opts
  case base of
    Object obj -> pure (PreparedRequest (Object (KM.union (KM.fromList extras) obj)) translation)
    _ -> Left "Responses SDK request did not encode as an object"
  where
    metadataText (String t) | Text.length t <= 512 = Right t
    metadataText _ = Left "Responses metadata values must be strings of at most 512 characters"

-- | Both preflight and serialization use this same mapping.
describeThinking :: Model -> Options -> E.ThinkingTranslation
describeThinking m = snd . thinkingFields m

thinkingFields :: Model -> Options -> ([(Aeson.Key, Value)], E.ThinkingTranslation)
thinkingFields m opts = (fields, thought {E.adjustments = thought.adjustments <> sampling})
  where
    compat = openaiResponsesCompatFor m
    (fields, thought) = case opts.thinking of
      Nothing -> ([], E.noThinkingRequested)
      Just lvl | not m.reasoning -> ([], E.ThinkingTranslation (Just lvl) E.ThinkingModeUnsupported Nothing Nothing Nothing [E.ThinkingDroppedUnsupportedModel lvl])
      Just lvl ->
        let effort = renderThinkingLevel (resolveSupportedEffort compat.supportedReasoningEfforts lvl)
         in ([("reasoning", object ["effort" .= effort])], E.ThinkingTranslation (Just lvl) E.ThinkingModeAdaptive (Just effort) Nothing (Just "reasoning.effort") [E.EffortClamped lvl effort | effort /= renderThinkingLevel lvl])
    dropped = [name | (name, set) <- [("temperature", isJust opts.temperature), ("top_p", isJust opts.topP)], set]
    sampling = [E.SamplingDroppedUnsupportedModel dropped | not compat.supportsSamplingParameters, not (null dropped)]

sdkTool :: T.Tool -> R.Tool
sdkTool t =
  R.Tool_Function
    { R.name = t.name,
      R.description = Just t.description,
      R.parameters = Just t.parameters,
      R.strict = Just False
    }

toolChoiceFields :: Context -> Options -> Either Text [(Aeson.Key, Value)]
toolChoiceFields ctx opts = case opts.toolChoice of
  Nothing -> pure []
  Just T.ToolChoiceAuto -> pure []
  Just T.ToolChoiceNone -> pure [("tool_choice", String "none")]
  Just T.ToolChoiceRequired
    | V.null ctx.tools -> Left "Responses required tool choice needs at least one declared tool"
    | otherwise -> pure [("tool_choice", String "required")]
  Just (T.ToolChoiceSpecific name)
    | V.any ((== name) . T.name) ctx.tools -> pure [("tool_choice", object ["type" .= ("function" :: Text), "name" .= name])]
    | otherwise -> Left "Responses named tool choice must name a declared tool"

formatFields :: Options -> [(Aeson.Key, Value)]
formatFields opts = case opts.responseFormat of
  Nothing -> []
  Just JsonObject -> [("text", object ["format" .= object ["type" .= ("json_object" :: Text)]])]
  Just (JsonSchema schema) ->
    [ ( "text",
        object
          [ "format"
              .= Aeson.toJSON
                R.TextFormat_JSON_Schema
                  { R.name = schema.name,
                    R.description = Nothing,
                    R.schema = Just schema.schema,
                    R.strict = Just schema.strict
                  }
          ]
      )
    ]

cacheFields :: Model -> Options -> Either Text [(Aeson.Key, Value)]
cacheFields m opts = case opts.cacheRetention of
  Nothing -> pure []
  Just CacheRetentionNone -> pure []
  Just CacheRetentionShort
    | compat.supportsPromptCacheOptions -> pure [("prompt_cache_options", object ["ttl" .= ("30m" :: Text)])]
    | otherwise -> pure [("prompt_cache_retention", String "in_memory")]
  Just CacheRetentionLong
    | compat.supportsPromptCacheOptions || not compat.supportsLongCacheRetention -> Left "This Responses model cannot honor long cache retention"
    | otherwise -> pure [("prompt_cache_retention", String "24h")]
  where
    compat = openaiResponsesCompatFor m

messageItems :: Model -> M.Message -> Either Text [Value]
messageItems m = \case
  M.UserMessage p -> pure [object ["role" .= ("user" :: Text), "content" .= V.map userPart p.content]]
  M.AssistantMessage p -> concat <$> traverse assistantItem (V.toList p.content)
  M.ToolResultMessage p -> do
    parts <- traverse toolResultText p.content
    unless (not (Text.null p.toolCallId)) (Left "Responses tool results need a nonempty call_id")
    let output = (if p.isError then "[error] " else "") <> Text.concat (V.toList parts)
    pure [Aeson.toJSON R.Item_Input_Function_Call_Output {R.id = Nothing, R.call_id = p.toolCallId, R.output = output, R.status = Nothing}]
  where
    assistantItem = \case
      C.AssistantText t -> pure [object ["role" .= ("assistant" :: Text), "content" .= t.text]]
      C.AssistantToolCall tc -> do
        unless (not (Text.null tc.id_) && not (Text.null tc.name)) (Left "Responses tool calls need a nonempty call_id and name")
        unless (not (C.isCutOffToolCall tc)) (Left "Responses cannot replay an incomplete function call")
        pure [Aeson.toJSON R.Item_Input_Function_Call {R.id = Nothing, R.call_id = tc.id_, R.name = tc.name, R.arguments = Text.decodeUtf8 (LBS.toStrict (Aeson.encode tc.arguments)), R.status = Nothing}]
      C.AssistantThinking th -> do
        unless (not th.redacted && th.signature == Nothing) (Left "Responses cannot replay Anthropic thinking signatures or redacted blocks")
        case th.replayState of
          Nothing -> Left "Responses thinking requires its original opaque replay state"
          Just state -> validateReplay m state >> pure (V.toList state.replayItems)

userPart :: C.UserContent -> Value
userPart = \case
  C.UserText t -> Aeson.toJSON (R.Input_Text t.text)
  C.UserImage img ->
    Aeson.toJSON
      R.Input_Image
        { R.image_url = Just ("data:" <> img.mimeType <> ";base64," <> Text.decodeUtf8 (Base64.encode img.imageData)),
          R.file_id = Nothing,
          R.detail = Nothing
        }

toolResultText :: C.ToolResultContent -> Either Text Text
toolResultText = \case
  C.ToolResultText t -> Right t.text
  C.ToolResultImage _ -> Left "Responses adapter cannot encode ToolResultImage yet"

-- | Validate scope and minimum reasoning-item contract without rebuilding
-- the items: preserving original fields and array order is intentional.
validateReplay :: Model -> C.ThinkingReplay -> Either Text ()
validateReplay m state = do
  unless (normaliseApi state.replayApi == OpenAIResponses && state.replayModel == m.modelId) (Left "Reasoning replay belongs to another API or model")
  validateReplayItems state.replayItems

-- | The same wire invariant applies to completed output and next input.
validateReplayItems :: V.Vector Value -> Either Text ()
validateReplayItems items = do
  unless (not (V.null items)) (Left "Reasoning replay must contain at least one item")
  mapM_ item items
  where
    item (Object o)
      | KM.lookup "type" o == Just (String "reasoning"),
        Just (String ident) <- KM.lookup "id" o,
        not (Text.null ident),
        Just (String encrypted) <- KM.lookup "encrypted_content" o,
        not (Text.null encrypted),
        Just (Array summary) <- KM.lookup "summary" o,
        all summaryPart summary =
          pure ()
    item _ = Left "Malformed Responses reasoning replay: expected reasoning type, id, encrypted_content and summary"
    summaryPart (Object o) = KM.lookup "type" o == Just (String "summary_text") && case KM.lookup "text" o of Just (String _) -> True; _ -> False
    summaryPart _ = False
