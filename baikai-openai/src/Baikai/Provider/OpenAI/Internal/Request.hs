{-# LANGUAGE LambdaCase #-}

-- | Internal request mapping for the OpenAI Chat Completions provider.
--
-- This module is exposed for provider tests and debugging but is not covered by PVP
-- compatibility guarantees. Import the public provider module for stable application code.
module Baikai.Provider.OpenAI.Internal.Request
  ( mapRequest,
  )
where

import Baikai.Compat
  ( OpenAICompletionsCompat (..),
    ThinkingFormat (..),
  )
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Message qualified as Msg
import Baikai.Model (Model, openaiCompletionsCompatFor)
import Baikai.Options (Options (..))
import Baikai.ResponseFormat (ResponseFormat (..))
import Baikai.ThinkingLevel (ThinkingLevel (..))
import Baikai.Tool qualified as Tool
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as OpenAIModels
import OpenAI.V1.ResponseFormat qualified as RF
import OpenAI.V1.Tool qualified as OpenAITool
import OpenAI.V1.ToolCall qualified as ToolCall

-- ============================================================
-- Request mapping (preserved from EP-2 with minor refactoring)
-- ============================================================

mapRequest ::
  Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
mapRequest m ctx opts = do
  body <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = openaiCompletionsCompatFor m
      prefix = case ctx ^. #systemPrompt of
        Nothing -> []
        Just sp ->
          [ Chat.System
              { Chat.content = Vector.singleton Chat.Text {Chat.text = sp},
                Chat.name = Nothing
              }
          ]
      mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
      maxTokensField =
        if mt == 0 then Nothing else Just mt
      toolsField =
        if Vector.null (ctx ^. #tools)
          then Nothing
          else Just (Vector.map (mkOpenAITool compat) (ctx ^. #tools))
      toolChoiceField = fmap mkOpenAIToolChoice (opts ^. #toolChoice)
      reasoningEffortField =
        applyThinkingFormat compat (opts ^. #thinking)
      responseFormatField =
        fmap (mkOpenAIResponseFormat compat) (opts ^. #responseFormat)
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body),
        Chat.model = OpenAIModels.Model (m ^. #modelId),
        Chat.max_completion_tokens = maxTokensField,
        Chat.temperature = opts ^. #temperature,
        Chat.top_p = opts ^. #topP,
        Chat.stop = opts ^. #stopSequences,
        Chat.seed = opts ^. #seed,
        Chat.frequency_penalty = opts ^. #frequencyPenalty,
        Chat.presence_penalty = opts ^. #presencePenalty,
        Chat.tools = toolsField,
        Chat.tool_choice = toolChoiceField,
        Chat.reasoning_effort = reasoningEffortField,
        Chat.response_format = responseFormatField
      }

-- | Map a baikai 'ResponseFormat' onto the upstream OpenAI
-- 'RF.ResponseFormat'. 'JsonObject' becomes plain-JSON mode;
-- 'JsonSchema' becomes a named, optionally-strict schema. The
-- schema 'Value' is forwarded verbatim.
mkOpenAIResponseFormat :: OpenAICompletionsCompat -> ResponseFormat -> RF.ResponseFormat
mkOpenAIResponseFormat _ JsonObject = RF.JSON_Object
mkOpenAIResponseFormat compat JsonSchema {name = n, schema = s, strict = st} =
  RF.JSON_Schema
    { RF.json_schema =
        RF.JSONSchema
          { RF.description = Nothing,
            RF.name = n,
            RF.schema = Just s,
            RF.strict = if supportsStrictMode compat then Just st else Nothing
          }
    }

-- | Map a 'Baikai.ThinkingLevel.ThinkingLevel' onto the OpenAI SDK's
-- 'Chat.ReasoningEffort' enum. Returns 'Nothing' when the caller did
-- not request a level, when the host's 'thinkingFormat' is
-- 'ThinkingFormatNone', or when the host expects a non-OpenAI shape
-- the SDK does not support natively.
--
-- The non-OpenAI thinking formats (DeepSeek, OpenRouter, Together,
-- Z.ai, Qwen) require additional top-level JSON keys the upstream
-- @openai@ Haskell SDK does not expose. They are silently dropped on
-- this revision; see the EP-5 Decision Log for the rationale and
-- pointers to the workaround when one is needed.
applyThinkingFormat ::
  OpenAICompletionsCompat ->
  Maybe ThinkingLevel ->
  Maybe Chat.ReasoningEffort
applyThinkingFormat _ Nothing = Nothing
applyThinkingFormat compat (Just lvl) = case thinkingFormat compat of
  ThinkingFormatOpenAI -> Just (toReasoningEffort lvl)
  _ -> Nothing

toReasoningEffort :: ThinkingLevel -> Chat.ReasoningEffort
toReasoningEffort = \case
  ThinkingMinimal -> Chat.ReasoningEffort_Minimal
  ThinkingLow -> Chat.ReasoningEffort_Low
  ThinkingMedium -> Chat.ReasoningEffort_Medium
  ThinkingHigh -> Chat.ReasoningEffort_High

-- | Map a baikai 'Tool.Tool' into the upstream OpenAI 'Tool_Function'
-- shape. The compat record's 'supportsStrictMode' flag controls
-- whether the @strict@ field is sent ('True') or dropped ('False');
-- some OpenAI-compatible hosts reject strict-mode tools entirely.
--
-- The default ('defaultOpenAICompletionsCompat') leaves strict
-- unset, which OpenAI treats as the default-permissive behaviour;
-- callers that want @strict: true@ on every tool can flip the field
-- on their compat record (a future enhancement; currently we pass
-- 'Nothing' even when 'supportsStrictMode' is 'True', matching the
-- pre-EP-5 behaviour).
mkOpenAITool :: OpenAICompletionsCompat -> Tool.Tool -> OpenAITool.Tool
mkOpenAITool _compat t =
  OpenAITool.Tool_Function
    { OpenAITool.function =
        OpenAITool.Function
          { OpenAITool.name = Tool.name t,
            OpenAITool.description = Just (Tool.description t),
            OpenAITool.parameters = Just (Tool.parameters t),
            OpenAITool.strict = Nothing
          }
    }

-- | Map a baikai 'Tool.ToolChoice' into the upstream OpenAI
-- 'ToolChoice'. OpenAI accepts @none@, @auto@, @required@, and a
-- specific function reference; the SDK's 'ToolChoiceTool' takes the
-- whole 'OpenAITool.Tool' value so we synthesise a stub function
-- tool carrying just the name (OpenAI ignores the schema in this
-- position).
mkOpenAIToolChoice :: Tool.ToolChoice -> OpenAITool.ToolChoice
mkOpenAIToolChoice = \case
  Tool.ToolChoiceAuto -> OpenAITool.ToolChoiceAuto
  Tool.ToolChoiceNone -> OpenAITool.ToolChoiceNone
  Tool.ToolChoiceRequired -> OpenAITool.ToolChoiceRequired
  Tool.ToolChoiceSpecific n ->
    OpenAITool.ToolChoiceTool
      ( OpenAITool.Tool_Function
          { OpenAITool.function =
              OpenAITool.Function
                { OpenAITool.name = n,
                  OpenAITool.description = Nothing,
                  OpenAITool.parameters = Nothing,
                  OpenAITool.strict = Nothing
                }
          }
      )

mapMessage :: Msg.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage = \case
  Msg.UserMessage Msg.UserPayload {Msg.content = uc} ->
    Right
      Chat.User
        { Chat.content = Vector.map userContentToPart uc,
          Chat.name = Nothing
        }
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
    let textBody = collectAssistantText ac
        toolCalls = collectToolCalls ac
        content
          | Text.null textBody = Nothing
          | otherwise = Just (Vector.singleton Chat.Text {Chat.text = textBody})
        toolCallVec
          | Vector.null toolCalls = Nothing
          | otherwise = Just toolCalls
     in Right
          Chat.Assistant
            { Chat.assistant_content = content,
              Chat.refusal = Nothing,
              Chat.name = Nothing,
              Chat.assistant_audio = Nothing,
              Chat.tool_calls = toolCallVec
            }
  Msg.ToolResultMessage
    Msg.ToolResultPayload
      { Msg.toolCallId = tid,
        Msg.content = trc,
        Msg.isError = err
      } ->
      case collectToolResultText trc of
        Left unsupported -> Left unsupported
        Right body ->
          let decorated = if err then "[error] " <> body else body
           in Right
                Chat.Tool
                  { Chat.content = Vector.singleton Chat.Text {Chat.text = decorated},
                    Chat.tool_call_id = tid
                  }

userContentToPart :: Content.UserContent -> Chat.Content
userContentToPart = \case
  Content.UserText (Content.TextContent t) -> Chat.Text {Chat.text = t}
  Content.UserImage img ->
    let encoded = Text.decodeUtf8 (Base64.encode (Content.imageData img))
        uri = "data:" <> Content.mimeType img <> ";base64," <> encoded
     in Chat.Image_URL
          { Chat.image_url = Chat.ImageURL {Chat.url = uri, Chat.detail = Nothing}
          }

collectAssistantText :: Vector Content.AssistantContent -> Text
collectAssistantText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          Content.AssistantText (Content.TextContent t) -> Just t
          Content.AssistantThinking _ -> Nothing
          Content.AssistantToolCall _ -> Nothing
      )

collectToolCalls :: Vector Content.AssistantContent -> Vector ToolCall.ToolCall
collectToolCalls =
  Vector.mapMaybe
    ( \case
        Content.AssistantToolCall tc ->
          Just
            ToolCall.ToolCall_Function
              { ToolCall.id = Content.id_ tc,
                ToolCall.function =
                  ToolCall.Function
                    { ToolCall.name = Content.name tc,
                      ToolCall.arguments =
                        Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
                    }
              }
        _ -> Nothing
    )

collectToolResultText :: Vector Content.ToolResultContent -> Either Text Text
collectToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "OpenAI Chat Completions cannot encode ToolResultImage blocks in tool-result messages"
