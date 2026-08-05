{-# LANGUAGE LambdaCase #-}

-- | Internal request mapping for the Anthropic Messages provider.
--
-- This module is exposed for provider tests and debugging but is not covered by PVP
-- compatibility guarantees. Import the public provider module for stable application code.
module Baikai.Provider.Claude.Internal.Request
  ( mapRequest,
    ThinkingPlan (..),
    computeThinking,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat (AnthropicMessagesCompat (..), AnthropicThinkingStyle (..))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Evidence
  ( ThinkingAdjustment (..),
    ThinkingMode (..),
    ThinkingTranslation (..),
    noThinkingRequested,
  )
import Baikai.Message qualified as Msg
import Baikai.Model (Model, anthropicMessagesCompatFor)
import Baikai.Options (Options (..))
import Baikai.ResponseFormat (ResponseFormat (..))
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel, thinkingTokenBudget)
import Baikai.Tool qualified as Tool
import Claude.V1.Messages qualified as Messages
import Claude.V1.Tool qualified as ClaudeTool
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAlphaNum, isAscii)
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- ============================================================
-- Request mapping (preserved from EP-2 with minor refactoring to
-- accept Context/Options directly).
-- ============================================================

-- | Map a baikai request onto the SDK's 'Messages.CreateMessage', and
-- describe what the caller's reasoning-effort preference became on the
-- way.
--
-- The 'ThinkingTranslation' is returned rather than reconstructed
-- downstream because this is the only place that knows all of it: the
-- host compatibility lookup, the model's reasoning capability, the
-- adaptive effort vocabulary, and the max-tokens interaction below all
-- feed into it. A trace sink asked to re-derive it would have to
-- reimplement every one of them.
mapRequest ::
  Model -> Context -> Options -> Either Text (Messages.CreateMessage, ThinkingTranslation)
mapRequest m ctx opts = do
  msgs <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = anthropicMessagesCompatFor m
      cap = m ^. #maxOutputTokens
      baseTokens = fromMaybe cap (opts ^. #maxTokens)
      clamp n = if cap == 0 then n else min n cap
      (plan0, translation0) = computeThinking compat m (opts ^. #thinking)
      -- The output-token ceiling this request resolves to while the
      -- thinking budget is still part of it. The budget has to fit
      -- inside this number, and when it does not the entire thinking
      -- plan is dropped — a caller who lowered maxTokens silently loses
      -- thinking, which is why the two colliding numbers are recorded.
      resolvedCeiling = clamp (baseTokens + fromMaybe 0 (budget plan0))
      (plan, translation) = case (budget plan0, translation0 ^. #requested) of
        (Just b, Just lvl)
          | resolvedCeiling <= b ->
              ( emptyThinkingPlan,
                dropThinking (ThinkingDroppedBudgetExceeded lvl b resolvedCeiling) translation0
              )
        _ -> (plan0, translation0)
      maxTokensField_ = case budget plan of
        Just b -> clamp (baseTokens + b)
        Nothing -> clamp baseTokens
      cacheControlField = computeCacheControl compat (opts ^. #cacheRetention)
      toolsVec = ctx ^. #tools
      toolsField =
        if Vector.null toolsVec
          then Nothing
          else Just (Vector.map (mkAnthropicTool compat) toolsVec)
      toolChoiceField = case opts ^. #toolChoice of
        Just Tool.ToolChoiceNone -> Nothing
        Just tc -> Just (mkAnthropicToolChoice tc)
        Nothing -> Nothing
      outputConfigField = mergeEffort (effort plan) (fmap mkAnthropicOutputConfig (opts ^. #responseFormat))
  pure
    ( Messages._CreateMessage
        { Messages.model = m ^. #modelId,
          Messages.messages = Vector.fromList msgs,
          Messages.max_tokens = maxTokensField_,
          Messages.system = fmap Messages.SystemPromptText (ctx ^. #systemPrompt),
          Messages.temperature = opts ^. #temperature,
          Messages.top_p = opts ^. #topP,
          Messages.stop_sequences = opts ^. #stopSequences,
          Messages.tools = toolsField,
          Messages.tool_choice = toolChoiceField,
          Messages.cache_control = cacheControlField,
          Messages.thinking = field plan,
          Messages.output_config = outputConfigField
        },
      translation
    )

mergeEffort :: Maybe Text -> Maybe Messages.OutputConfig -> Maybe Messages.OutputConfig
mergeEffort Nothing cfg = cfg
mergeEffort (Just e) Nothing = Just (Messages.effortConfig e)
mergeEffort (Just e) (Just cfg) = Just cfg {Messages.effort = Just e}

-- | Map a baikai 'ResponseFormat' onto the upstream Anthropic
-- 'Messages.OutputConfig'. 'JsonSchema' forwards the schema
-- verbatim via 'Messages.jsonSchemaConfig'. Anthropic's structured
-- outputs are always schema-enforcing, so the baikai 'strict' flag
-- has no wire analog and is dropped. 'JsonObject' (plain-JSON mode)
-- has no native Anthropic equivalent — 'output_config' requires a
-- schema — so it downgrades to a permissive @{"type":"object"}@
-- schema, which still forces the model to emit a JSON object.
mkAnthropicOutputConfig :: ResponseFormat -> Messages.OutputConfig
mkAnthropicOutputConfig = \case
  JsonSchema {schema = s} -> Messages.jsonSchemaConfig s
  JsonObject ->
    Messages.jsonSchemaConfig
      (Aeson.object ["type" .= ("object" :: Text)])

-- | Translate the call-time 'Baikai.CacheRetention' preference into
-- the Anthropic SDK's @cache_control@ shape.
--
-- 'CacheRetentionNone' (and 'Nothing') turn the field off entirely.
-- 'CacheRetentionShort' uses the ephemeral marker with no TTL (the
-- provider default). 'CacheRetentionLong' asks for the @"1h"@ TTL
-- when the host advertises 'supportsLongCacheRetention'; otherwise it
-- transparently downgrades to short retention.
computeCacheControl ::
  AnthropicMessagesCompat ->
  Maybe CacheRetention ->
  Maybe Messages.CacheControl
computeCacheControl _ Nothing = Nothing
computeCacheControl _ (Just CacheRetentionNone) = Nothing
computeCacheControl _ (Just CacheRetentionShort) =
  Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}
computeCacheControl compat (Just CacheRetentionLong)
  | supportsLongCacheRetention compat =
      Just
        Messages.CacheControl
          { Messages.type_ = "ephemeral",
            Messages.ttl = Just (Messages.CacheTTLDuration "1h")
          }
  | otherwise =
      Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}

-- | Translate the call-time 'Baikai.ThinkingLevel' preference into
-- the Anthropic SDK's 'Messages.Thinking' shape.
--
-- We only enable the thinking field when the chosen model advertises
-- 'reasoning' support — sending a thinking config to a non-reasoning
-- model is a 400 error from Anthropic, not a silent no-op. Callers
-- that asked for thinking on a non-reasoning model get the request
-- shaped without it (the request still succeeds and returns a normal
-- response).
data ThinkingPlan = ThinkingPlan
  { field :: !(Maybe Messages.Thinking),
    effort :: !(Maybe Text),
    budget :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

emptyThinkingPlan :: ThinkingPlan
emptyThinkingPlan =
  ThinkingPlan
    { field = Nothing,
      effort = Nothing,
      budget = Nothing
    }

-- | Build the SDK's thinking configuration and, beside it, the
-- provider-neutral description of what the caller's level became.
--
-- The two travel together because they are two views of one decision.
-- Returning only the first is what this provider used to do, and it is
-- why a caller could never tell an honoured request from a dropped one.
computeThinking ::
  AnthropicMessagesCompat ->
  Model ->
  Maybe ThinkingLevel ->
  (ThinkingPlan, ThinkingTranslation)
computeThinking _ _ Nothing = (emptyThinkingPlan, noThinkingRequested)
computeThinking compat m (Just lvl)
  | not (m ^. #reasoning) =
      ( emptyThinkingPlan,
        ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeUnsupported,
            effortText = Nothing,
            budgetTokens = Nothing,
            wireField = Nothing,
            adjustments = [ThinkingDroppedUnsupportedModel lvl]
          }
      )
  | thinkingStyle compat == AnthropicThinkingAdaptive =
      let e = adaptiveEffort lvl
       in ( ThinkingPlan
              { field = Just Messages.ThinkingAdaptive,
                effort = e,
                budget = Nothing
              },
            ThinkingTranslation
              { requested = Just lvl,
                mode = ThinkingModeAdaptive,
                effortText = e,
                budgetTokens = Nothing,
                wireField = Just "thinking",
                adjustments = adaptiveAdjustments lvl e
              }
          )
  | otherwise =
      let b = thinkingTokenBudget lvl
       in ( ThinkingPlan
              { field = Just Messages.ThinkingEnabled {Messages.budget_tokens = b},
                effort = Nothing,
                budget = Just b
              },
            ThinkingTranslation
              { requested = Just lvl,
                mode = ThinkingModeBudget,
                effortText = Nothing,
                budgetTokens = Just b,
                -- A budget expresses the requested level exactly, so
                -- there is nothing to adjust.
                wireField = Just "thinking",
                adjustments = []
              }
          )

adaptiveEffort :: ThinkingLevel -> Maybe Text
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing
  ThinkingXHigh -> Just "xhigh"
  ThinkingMax -> Just "max"

-- | What Anthropic's adaptive vocabulary did to the requested level.
--
-- Derived from what 'adaptiveEffort' actually produced rather than from
-- a second table beside it, so the two cannot drift. 'Nothing' means no
-- effort field is sent at all, which leaves the request
-- wire-indistinguishable from a caller who expressed no preference and
-- took Anthropic's own default depth. An effort word that differs from
-- the level's canonical name is a clamp onto the nearest word the
-- adaptive vocabulary has — Anthropic's has no @minimal@.
adaptiveAdjustments :: ThinkingLevel -> Maybe Text -> [ThinkingAdjustment]
adaptiveAdjustments lvl = \case
  Nothing -> [EffortOmitted lvl]
  Just wire
    | wire == renderThinkingLevel lvl -> []
    | otherwise -> [EffortClamped lvl wire]

-- | Record that, after all, nothing about thinking reached the wire.
--
-- Every field describing a wire value is cleared, because after the drop
-- there is none. The adjustment is appended rather than replacing the
-- list so a reader sees the order things were applied in.
dropThinking :: ThinkingAdjustment -> ThinkingTranslation -> ThinkingTranslation
dropThinking adj t =
  t
    & #mode .~ ThinkingModeUnsupported
    & #effortText .~ Nothing
    & #budgetTokens .~ Nothing
    & #wireField .~ Nothing
    & #adjustments %~ (<> [adj])

-- | Map a baikai 'Tool.Tool' into the upstream Anthropic
-- 'ClaudeTool.ToolDefinition'. The SDK helper is used to populate
-- the ordinary typed fields; the raw request shaper later restores
-- the caller's verbatim @input_schema@ because
-- 'ClaudeTool.functionTool' keeps only a subset of JSON Schema.
--
-- The compat record is accepted at this layer for call-site
-- consistency; per-tool @cache_control@ markers are applied by
-- 'Baikai.Provider.Claude.Shape.injectToolCacheControl'.
mkAnthropicTool :: AnthropicMessagesCompat -> Tool.Tool -> ClaudeTool.ToolDefinition
mkAnthropicTool _compat t =
  ClaudeTool.inlineTool
    ( ClaudeTool.functionTool
        (Tool.name t)
        (Just (Tool.description t))
        (Tool.parameters t)
    )

-- | Map a baikai 'Tool.ToolChoice' into the upstream Anthropic
-- 'ClaudeTool.ToolChoice'. 'Tool.ToolChoiceNone' is handled by the
-- raw request shaper because the SDK lacks a @none@ constructor.
-- 'Tool.ToolChoiceRequired' maps to Anthropic's
-- @any@ which is the closest equivalent ("must call some tool").
mkAnthropicToolChoice :: Tool.ToolChoice -> ClaudeTool.ToolChoice
mkAnthropicToolChoice = \case
  Tool.ToolChoiceAuto -> ClaudeTool.ToolChoice_Auto
  Tool.ToolChoiceRequired -> ClaudeTool.ToolChoice_Any
  Tool.ToolChoiceSpecific n -> ClaudeTool.ToolChoice_Tool {ClaudeTool.name = n}
  -- Unreachable in typed requests: ToolChoiceNone is injected by the shaper.
  Tool.ToolChoiceNone -> ClaudeTool.ToolChoice_Auto

-- | Anthropic enforces @[a-zA-Z0-9_-]+@ on tool-call ids and caps
-- their length at 64 characters. Callers may have used any
-- naming convention, so the provider boundary normalizes here
-- whenever an id is round-tripped back to Anthropic — both on
-- assistant turn replay ('Content_Tool_Use') and on tool-result
-- messages ('Content_Tool_Result').
normalizeToolCallId :: Text -> Text
normalizeToolCallId =
  Text.take 64 . Text.map sanitise
  where
    sanitise c
      | isAscii c && isAlphaNum c = c
      | c == '_' || c == '-' = c
      | otherwise = '_'

mapMessage :: Msg.Message -> Either Text Messages.Message
mapMessage = \case
  Msg.UserMessage Msg.UserPayload {Msg.content = uc} ->
    Right
      Messages.Message
        { Messages.role = Messages.User,
          Messages.content = Vector.mapMaybe userContentToBlock uc,
          Messages.cache_control = Nothing
        }
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
    Right
      Messages.Message
        { Messages.role = Messages.Assistant,
          Messages.content = Vector.mapMaybe assistantContentToBlock ac,
          Messages.cache_control = Nothing
        }
  Msg.ToolResultMessage
    Msg.ToolResultPayload
      { Msg.toolCallId = tid,
        Msg.content = trc,
        Msg.isError = err
      } ->
      case concatToolResultText trc of
        Left unsupported -> Left unsupported
        Right body ->
          Right
            Messages.Message
              { Messages.role = Messages.User,
                Messages.content =
                  Vector.singleton
                    Messages.Content_Tool_Result
                      { Messages.tool_use_id = normalizeToolCallId tid,
                        Messages.content = nonEmpty body,
                        Messages.is_error = Just err
                      },
                Messages.cache_control = Nothing
              }

userContentToBlock :: Content.UserContent -> Maybe Messages.Content
userContentToBlock = \case
  Content.UserText (Content.TextContent t) ->
    Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.UserImage img ->
    Just
      Messages.Content_Image
        { Messages.source =
            Messages.ImageSource
              { Messages.type_ = "base64",
                Messages.media_type = Content.mimeType img,
                Messages.data_ = Text.decodeUtf8 (Base64.encode (Content.imageData img))
              },
          Messages.cache_control = Nothing
        }

assistantContentToBlock :: Content.AssistantContent -> Maybe Messages.Content
assistantContentToBlock = \case
  Content.AssistantText (Content.TextContent t) ->
    Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.AssistantThinking th ->
    if Content.redacted th
      then Just Messages.Content_Redacted_Thinking {Messages.data_ = Content.thinking th}
      else case Content.signature th of
        Just sig ->
          Just
            Messages.Content_Thinking
              { Messages.thinking = Content.thinking th,
                Messages.signature = sig
              }
        Nothing -> Nothing
  Content.AssistantToolCall tc ->
    Just
      Messages.Content_Tool_Use
        { Messages.id = normalizeToolCallId (Content.id_ tc),
          Messages.name = Content.name tc,
          Messages.input = Content.arguments tc,
          Messages.caller = Nothing
        }

concatToolResultText :: Vector Content.ToolResultContent -> Either Text Text
concatToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "Anthropic Messages cannot encode ToolResultImage blocks in tool-result messages"

nonEmpty :: Text -> Maybe Text
nonEmpty t
  | Text.null t = Nothing
  | otherwise = Just t
