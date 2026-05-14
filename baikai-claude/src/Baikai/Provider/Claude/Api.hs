{-# LANGUAGE LambdaCase #-}

-- | Provider wrapping the @claude@ package's Messages API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.AnthropicMessages' handler into the baikai provider
-- registry. After registration, any 'Baikai.Model.Model' whose
-- 'Baikai.Api.api' tag is 'AnthropicMessages' dispatches through
-- this handler.
--
-- The handler reads its API key from 'Baikai.Options.apiKey' when
-- present, falling back to the @ANTHROPIC_API_KEY@ env var via
-- 'Baikai.Auth.resolveApiKey'.
--
-- Message mapping (unchanged from EP-1):
--
-- * 'UserMessage' → @role = User@ with one Claude content block per
--   'UserContent' block.
-- * 'AssistantMessage' → @role = Assistant@.
-- * 'ToolResultMessage' → a 'User'-role Claude message whose only
--   content block is @Content_Tool_Result@.
module Baikai.Provider.Claude.Api
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
import Baikai.Stream (liftCompleteToStream)
import Baikai.Response qualified as Resp
import Baikai.StopReason qualified as Stop
import Baikai.Usage qualified as Usage
import Claude.V1 qualified as Claude
import Claude.V1.Messages qualified as Messages
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Data.ByteString.Base64 qualified as Base64
import Data.Generics.Labels ()
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector

-- | Install the Anthropic Messages handler into the registry.
-- Calling 'register' twice keeps only the second handler — the
-- registry's insert-overwrites semantic.
register :: IO ()
register =
  registerApiProvider
    ApiProvider
      { apiTag = AnthropicMessages
      , stream = liftCompleteToStream runClaudeMessages
      , complete = runClaudeMessages
      }

runClaudeMessages :: Model -> Context -> Options -> IO Resp.Response
runClaudeMessages m ctx opts = do
  key <- resolveKey opts
  let url = case m ^. #baseUrl of
        "" -> "https://api.anthropic.com"
        u -> u
  env <- Claude.getClientEnv url
  let methods = Claude.makeMethods env key (Just "2023-06-01")
      Claude.Methods {Claude.createMessage} = methods
  createReq <- either (throwIO . RequestInvalid) pure (mapRequest m ctx opts)
  start <- getCurrentTime
  resp <- createMessage createReq
  end <- getCurrentTime
  pure (Pricing.attachCost m (mapResponse m start end resp))

-- | Resolve the per-call API key. 'Options.apiKey' wins when set;
-- otherwise read @ANTHROPIC_API_KEY@ from the environment.
resolveKey :: Options -> IO Text
resolveKey opts = case opts ^. #apiKey of
  Just k -> pure k
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv "ANTHROPIC_API_KEY")

mapRequest :: Model -> Context -> Options -> Either Text Messages.CreateMessage
mapRequest m ctx opts = do
  msgs <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
  pure
    Messages._CreateMessage
      { Messages.model = m ^. #modelId
      , Messages.messages = Vector.fromList msgs
      , Messages.max_tokens = mt
      , Messages.system = fmap Messages.SystemPromptText (ctx ^. #systemPrompt)
      , Messages.temperature = opts ^. #temperature
      }

mapMessage :: Msg.Message -> Either Text Messages.Message
mapMessage = \case
  Msg.UserMessage {Msg.userContent = uc} ->
    Right
      Messages.Message
        { Messages.role = Messages.User
        , Messages.content = Vector.mapMaybe userContentToBlock uc
        , Messages.cache_control = Nothing
        }
  Msg.AssistantMessage {Msg.assistantContent = ac} ->
    Right
      Messages.Message
        { Messages.role = Messages.Assistant
        , Messages.content = Vector.mapMaybe assistantContentToBlock ac
        , Messages.cache_control = Nothing
        }
  Msg.ToolResultMessage
    { Msg.toolCallId = tid
    , Msg.toolResultContent = trc
    , Msg.isError = err
    } ->
      Right
        Messages.Message
          { Messages.role = Messages.User
          , Messages.content =
              Vector.singleton
                Messages.Content_Tool_Result
                  { Messages.tool_use_id = tid
                  , Messages.content = nonEmpty (concatToolResultText trc)
                  , Messages.is_error = Just err
                  }
          , Messages.cache_control = Nothing
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
              { Messages.type_ = "base64"
              , Messages.media_type = Content.mimeType img
              , Messages.data_ = Text.decodeUtf8 (Base64.encode (Content.imageData img))
              }
        , Messages.cache_control = Nothing
        }

assistantContentToBlock :: Content.AssistantContent -> Maybe Messages.Content
assistantContentToBlock = \case
  Content.AssistantText (Content.TextContent t) ->
    Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.AssistantThinking th ->
    Just
      Messages.Content_Thinking
        { Messages.thinking = Content.thinking th
        , Messages.signature = fromMaybe "" (Content.signature th)
        }
  Content.AssistantToolCall tc ->
    Just
      Messages.Content_Tool_Use
        { Messages.id = Content.id_ tc
        , Messages.name = Content.name tc
        , Messages.input = Content.arguments tc
        , Messages.caller = Nothing
        }

concatToolResultText :: Vector Content.ToolResultContent -> Text
concatToolResultText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          Content.ToolResultText (Content.TextContent t) -> Just t
          Content.ToolResultImage _ -> Nothing
      )

nonEmpty :: Text -> Maybe Text
nonEmpty t
  | Text.null t = Nothing
  | otherwise = Just t

mapResponse :: Model -> UTCTime -> UTCTime -> Messages.MessageResponse -> Resp.Response
mapResponse m start end resp =
  Resp.Response
    { Resp.message =
        Msg.AssistantMessage
          { Msg.assistantContent = Vector.mapMaybe contentBlockToAssistant (resp ^. #content)
          , Msg.usage = mapUsage (resp ^. #usage)
          , Msg.stopReason = mapStopReason (resp ^. #stop_reason)
          , Msg.errorMessage = Nothing
          , Msg.timestamp = end
          }
    , Resp.model = m
    , Resp.api = AnthropicMessages
    , Resp.provider = m ^. #provider
    , Resp.responseId = Just (resp ^. #id)
    , Resp.latencyMs = millisBetween start end
    }

contentBlockToAssistant :: Messages.ContentBlock -> Maybe Content.AssistantContent
contentBlockToAssistant = \case
  Messages.ContentBlock_Text t ->
    Just (Content.AssistantText (Content.TextContent t))
  Messages.ContentBlock_Thinking t sig ->
    Just
      ( Content.AssistantThinking
          Content.ThinkingContent
            { Content.thinking = t
            , Content.signature = if Text.null sig then Nothing else Just sig
            , Content.redacted = False
            }
      )
  Messages.ContentBlock_Redacted_Thinking _ ->
    Just
      ( Content.AssistantThinking
          Content.ThinkingContent
            { Content.thinking = ""
            , Content.signature = Nothing
            , Content.redacted = True
            }
      )
  Messages.ContentBlock_Tool_Use toolId toolName toolInput _caller ->
    Just
      ( Content.AssistantToolCall
          Content.ToolCall
            { Content.id_ = toolId
            , Content.name = toolName
            , Content.arguments = toolInput
            }
      )
  Messages.ContentBlock_Server_Tool_Use {} -> Nothing
  Messages.ContentBlock_Tool_Search_Tool_Result {} -> Nothing
  Messages.ContentBlock_Code_Execution_Tool_Result {} -> Nothing
  Messages.ContentBlock_Unknown {} -> Nothing

mapUsage :: Messages.Usage -> Usage.Usage
mapUsage u =
  let i = u ^. #input_tokens
      o = u ^. #output_tokens
      cr = fromMaybe 0 (u ^. #cache_read_input_tokens)
      cw = fromMaybe 0 (u ^. #cache_creation_input_tokens)
   in Usage.Usage
        { Usage.inputTokens = i
        , Usage.outputTokens = o
        , Usage.cacheReadTokens = cr
        , Usage.cacheWriteTokens = cw
        , Usage.reasoningTokens = Nothing
        , Usage.totalTokens = i + o + cr + cw
        , Usage.cost = _Cost
        }

mapStopReason :: Maybe Messages.StopReason -> Stop.StopReason
mapStopReason = \case
  Just Messages.End_Turn -> Stop.Stop
  Just Messages.Max_Tokens -> Stop.Length
  Just Messages.Stop_Sequence -> Stop.Stop
  Just Messages.Tool_Use -> Stop.ToolUse
  Just Messages.Refusal -> Stop.ErrorReason
  Just Messages.Model_Context_Window_Exceeded -> Stop.Length
  Nothing -> Stop.Stop

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
