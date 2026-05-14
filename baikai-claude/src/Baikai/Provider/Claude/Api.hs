-- | Provider wrapping the @claude@ package's Messages API.
--
-- Construct a 'ClaudeApi' with 'claudeApi' and a 'Baikai.Auth.ApiKeySource',
-- then pass it to 'Baikai.Provider.runRequest' as you would any other provider.
-- The provider name is @"anthropic.claude.api"@.
--
-- The provider maps the typed 'Baikai.Message.Message' ADT (introduced
-- in EP-1) onto Anthropic's content-block shapes:
--
-- * 'UserMessage' → @role = User@ with one Claude content block per
--   'UserContent' block. 'UserText' → @Content_Text@; 'UserImage' →
--   @Content_Image@ with the bytes base64-encoded into 'ImageSource'.
-- * 'AssistantMessage' → @role = Assistant@. 'AssistantText' →
--   @Content_Text@; 'AssistantThinking' → @Content_Thinking@;
--   'AssistantToolCall' → @Content_Tool_Use@.
-- * 'ToolResultMessage' → a 'User'-role Claude message whose only
--   content block is @Content_Tool_Result@. Per Anthropic's protocol,
--   tool results live inside a user turn.
module Baikai.Provider.Claude.Api
  ( ClaudeApi (..)
  , claudeApi
  ) where

import Baikai.Auth qualified as Auth
import Baikai.Content qualified as Content
import Baikai.Cost (_Cost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError (..))
import Baikai.Message qualified as Msg
import Baikai.Model qualified as Model
import Baikai.Provider (Provider (..))
import Baikai.Request qualified as Req
import Baikai.Response qualified as Resp
import Baikai.StopReason qualified as Stop
import Baikai.Usage qualified as Usage
import Claude.V1 qualified as Claude
import Claude.V1.Messages qualified as Messages
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString.Base64 qualified as Base64
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector

-- | A configured Anthropic Messages API provider. 'pricing' defaults to
-- 'Pricing.defaultPricing'; override per-provider by constructing the record
-- by hand to model negotiated discounts or to add unknown models.
data ClaudeApi = ClaudeApi
  { methods :: !Claude.Methods
  , pricing :: !(Map Text Pricing.PricingRate)
  }

-- | Build a 'ClaudeApi' from a key source. Performs no network I/O.
claudeApi :: MonadIO m => Auth.ApiKeySource -> m ClaudeApi
claudeApi src = do
  key <- Auth.resolveApiKey src
  env <- liftIO (Claude.getClientEnv "https://api.anthropic.com")
  pure
    ClaudeApi
      { methods = Claude.makeMethods env key (Just "2023-06-01")
      , pricing = Pricing.defaultPricing
      }

instance Provider ClaudeApi where
  providerName _ = "anthropic.claude.api"
  runRequest api req = liftIO $ do
    let Claude.Methods {Claude.createMessage} = methods api
    createReq <- either (throwIO . RequestInvalid) pure (mapRequest req)
    start <- getCurrentTime
    resp <- createMessage createReq
    end <- getCurrentTime
    pure (Pricing.attachCost (pricing api) (mapResponse start end resp))

-- | Translate a 'Baikai.Request.Request' to Anthropic's
-- 'Messages.CreateMessage'.
mapRequest :: Req.Request -> Either Text Messages.CreateMessage
mapRequest req = do
  msgs <- traverse mapMessage (Vector.toList (req ^. #messages))
  pure
    Messages._CreateMessage
      { Messages.model = Model.unModel (req ^. #model)
      , Messages.messages = Vector.fromList msgs
      , Messages.max_tokens = req ^. #maxTokens
      , Messages.system = fmap Messages.SystemPromptText (req ^. #systemPrompt)
      , Messages.temperature = req ^. #temperature
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
  Msg.ToolResultMessage {Msg.toolCallId = tid, Msg.toolResultContent = trc, Msg.isError = err} ->
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

-- Reduce a vector of tool-result blocks to a single plain-text payload;
-- image blocks are dropped because Anthropic's tool_result content is a
-- single optional string. EP-4 may extend the upstream Claude SDK to
-- accept the richer typed-block form.
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

mapResponse :: UTCTime -> UTCTime -> Messages.MessageResponse -> Resp.Response
mapResponse start end resp =
  Resp.Response
    { Resp.message =
        Msg.AssistantMessage
          { Msg.assistantContent = Vector.mapMaybe contentBlockToAssistant (resp ^. #content)
          , Msg.usage = mapUsage (resp ^. #usage)
          , Msg.stopReason = mapStopReason (resp ^. #stop_reason)
          , Msg.errorMessage = Nothing
          , Msg.timestamp = end
          }
    , Resp.model = Model.Model (resp ^. #model)
    , Resp.api = "anthropic.messages"
    , Resp.provider = "anthropic.claude.api"
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
