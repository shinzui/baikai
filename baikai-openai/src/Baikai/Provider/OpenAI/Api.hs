{-# LANGUAGE LambdaCase #-}

-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAIChatCompletions' handler into the baikai
-- provider registry. After registration, any 'Baikai.Model.Model'
-- whose 'Baikai.Api.api' tag is 'OpenAIChatCompletions' dispatches
-- through this handler.
--
-- The handler reads its API key from 'Baikai.Options.apiKey' when
-- present, falling back to the @OPENAI_API_KEY@ env var via
-- 'Baikai.Auth.resolveApiKey'.
module Baikai.Provider.OpenAI.Api
  ( register
  ) where

import Baikai.Api (Api (..))
import Baikai.Auth qualified as Auth
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (_Cost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError (..))
import Baikai.Message qualified as Msg
import Baikai.Model (Model)
import Baikai.Options (Options (..))
import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.Response qualified as Resp
import Baikai.StopReason qualified as Stop
import Baikai.Usage qualified as Usage
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as OpenAIModels
import OpenAI.V1.ToolCall qualified as ToolCall
import OpenAI.V1.Usage qualified as OpenAIUsage

-- | Install the OpenAI Chat Completions handler into the registry.
register :: IO ()
register =
  registerApiProvider
    ApiProvider
      { apiTag = OpenAIChatCompletions
      , complete = runOpenAIChat
      }

runOpenAIChat :: Model -> Context -> Options -> IO Resp.Response
runOpenAIChat m ctx opts = do
  key <- resolveKey opts
  let url = case m ^. #baseUrl of
        "" -> "https://api.openai.com"
        u -> u
  env <- OpenAI.getClientEnv url
  let methods = OpenAI.makeMethods env key Nothing Nothing
      OpenAI.Methods {OpenAI.createChatCompletion} = methods
  create <- either (throwIO . RequestInvalid) pure (mapRequest m ctx opts)
  start <- getCurrentTime
  obj <- createChatCompletion create
  end <- getCurrentTime
  pure (Pricing.attachCost m (mapResponse m start end obj))

resolveKey :: Options -> IO Text
resolveKey opts = case opts ^. #apiKey of
  Just k -> pure k
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv "OPENAI_API_KEY")

mapRequest :: Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
mapRequest m ctx opts = do
  body <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let prefix = case ctx ^. #systemPrompt of
        Nothing -> []
        Just sp ->
          [ Chat.System
              { Chat.content = Vector.singleton Chat.Text {Chat.text = sp}
              , Chat.name = Nothing
              }
          ]
      mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body)
      , Chat.model = OpenAIModels.Model (m ^. #modelId)
      , Chat.max_completion_tokens = Just mt
      , Chat.temperature = opts ^. #temperature
      }

mapMessage :: Msg.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage = \case
  Msg.UserMessage {Msg.userContent = uc} ->
    Right
      Chat.User
        { Chat.content = Vector.map userContentToPart uc
        , Chat.name = Nothing
        }
  Msg.AssistantMessage {Msg.assistantContent = ac} ->
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
            { Chat.assistant_content = content
            , Chat.refusal = Nothing
            , Chat.name = Nothing
            , Chat.assistant_audio = Nothing
            , Chat.tool_calls = toolCallVec
            }
  Msg.ToolResultMessage
    { Msg.toolCallId = tid
    , Msg.toolResultContent = trc
    , Msg.isError = err
    } ->
      let body = collectToolResultText trc
          decorated = if err then "[error] " <> body else body
       in Right
            Chat.Tool
              { Chat.content = Vector.singleton Chat.Text {Chat.text = decorated}
              , Chat.tool_call_id = tid
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
          Content.AssistantThinking th ->
            if Content.redacted th
              then Nothing
              else Just ("<thinking>" <> Content.thinking th <> "</thinking>")
          Content.AssistantToolCall _ -> Nothing
      )

collectToolCalls :: Vector Content.AssistantContent -> Vector ToolCall.ToolCall
collectToolCalls =
  Vector.mapMaybe
    ( \case
        Content.AssistantToolCall tc ->
          Just
            ToolCall.ToolCall_Function
              { ToolCall.id = Content.id_ tc
              , ToolCall.function =
                  ToolCall.Function
                    { ToolCall.name = Content.name tc
                    , ToolCall.arguments =
                        Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
                    }
              }
        _ -> Nothing
    )

collectToolResultText :: Vector Content.ToolResultContent -> Text
collectToolResultText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          Content.ToolResultText (Content.TextContent t) -> Just t
          Content.ToolResultImage _ -> Nothing
      )

mapResponse :: Model -> UTCTime -> UTCTime -> Chat.ChatCompletionObject -> Resp.Response
mapResponse m start end obj =
  let pickedChoice = pickChoice (obj ^. #choices)
      blocks = maybe Vector.empty choiceToBlocks pickedChoice
      stopReason = maybe Stop.Stop (mapFinishReason . (^. #finish_reason)) pickedChoice
   in Resp.Response
        { Resp.message =
            Msg.AssistantMessage
              { Msg.assistantContent = blocks
              , Msg.usage = mapUsage (obj ^. #usage)
              , Msg.stopReason = stopReason
              , Msg.errorMessage = Nothing
              , Msg.timestamp = end
              }
        , Resp.model = m
        , Resp.api = OpenAIChatCompletions
        , Resp.provider = m ^. #provider
        , Resp.responseId = Just (obj ^. #id)
        , Resp.latencyMs = millisBetween start end
        }

pickChoice :: Vector Chat.Choice -> Maybe Chat.Choice
pickChoice cs
  | Vector.null cs = Nothing
  | otherwise = Just (Vector.head cs)

choiceToBlocks :: Chat.Choice -> Vector Content.AssistantContent
choiceToBlocks ch =
  let mm = ch ^. #message
      body = Chat.messageToContent mm
      textBlock =
        if Text.null body
          then Vector.empty
          else Vector.singleton (Content.AssistantText (Content.TextContent body))
      toolBlocks = case mm of
        Chat.Assistant {Chat.tool_calls = Just tcs} -> Vector.map toolCallToBlock tcs
        _ -> Vector.empty
   in textBlock <> toolBlocks

toolCallToBlock :: ToolCall.ToolCall -> Content.AssistantContent
toolCallToBlock = \case
  ToolCall.ToolCall_Function {ToolCall.id = i, ToolCall.function = f} ->
    Content.AssistantToolCall
      Content.ToolCall
        { Content.id_ = i
        , Content.name = ToolCall.name f
        , Content.arguments =
            fromMaybe
              (Aeson.Object mempty)
              (Aeson.decodeStrict (Text.encodeUtf8 (ToolCall.arguments f)))
        }

mapUsage
  :: OpenAIUsage.Usage OpenAIUsage.CompletionTokensDetails OpenAIUsage.PromptTokensDetails
  -> Usage.Usage
mapUsage u =
  let i = u ^. #prompt_tokens
      o = u ^. #completion_tokens
      cr = fromMaybe 0 ((u ^. #prompt_tokens_details) >>= (^. #cached_tokens))
      rt = (u ^. #completion_tokens_details) >>= (^. #reasoning_tokens)
   in Usage.Usage
        { Usage.inputTokens = i
        , Usage.outputTokens = o
        , Usage.cacheReadTokens = cr
        , Usage.cacheWriteTokens = 0
        , Usage.reasoningTokens = rt
        , Usage.totalTokens = i + o + cr
        , Usage.cost = _Cost
        }

mapFinishReason :: Text -> Stop.StopReason
mapFinishReason r = case r of
  "stop" -> Stop.Stop
  "length" -> Stop.Length
  "tool_calls" -> Stop.ToolUse
  "function_call" -> Stop.ToolUse
  "content_filter" -> Stop.ErrorReason
  _ -> Stop.Stop

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
