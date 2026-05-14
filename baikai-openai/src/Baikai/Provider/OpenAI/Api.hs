-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Construct an 'OpenAIApi' with 'openaiApi' and a 'Baikai.Auth.ApiKeySource'.
-- The provider name is @"openai.chat.api"@.
--
-- Contract: 'Baikai.Request.Request.messages' carries User and Assistant turns
-- only. 'Baikai.Request.Request.systemPrompt', when present, is prepended to
-- the upstream @messages@ array as a 'System' message.
module Baikai.Provider.OpenAI.Api
  ( OpenAIApi (..)
  , openaiApi
  ) where

import Baikai.Auth qualified as Auth
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError (..))
import Baikai.Message qualified as Msg
import Baikai.Model qualified as Model
import Baikai.Provider (Provider (..))
import Baikai.Request qualified as Req
import Baikai.Response qualified as Resp
import Baikai.Usage qualified as Usage
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as OpenAIModels
import OpenAI.V1.Usage qualified as OpenAIUsage

-- | A configured OpenAI Chat Completions provider. 'pricing' defaults to
-- 'Pricing.defaultPricing'; override per-provider by constructing the record
-- by hand to model negotiated discounts or to add unknown models.
data OpenAIApi = OpenAIApi
  { methods :: !OpenAI.Methods
  , pricing :: !(Map Text Pricing.PricingRate)
  }

-- | Build an 'OpenAIApi' from a key source. Performs no network I/O.
openaiApi :: MonadIO m => Auth.ApiKeySource -> m OpenAIApi
openaiApi src = do
  key <- Auth.resolveApiKey src
  env <- liftIO (OpenAI.getClientEnv "https://api.openai.com")
  pure
    OpenAIApi
      { methods = OpenAI.makeMethods env key Nothing Nothing
      , pricing = Pricing.defaultPricing
      }

instance Provider OpenAIApi where
  providerName _ = "openai.chat.api"
  runRequest api req = liftIO $ do
    let OpenAI.Methods {OpenAI.createChatCompletion} = methods api
    create <- either (throwIO . RequestInvalid) pure (mapRequest req)
    start <- getCurrentTime
    obj <- createChatCompletion create
    end <- getCurrentTime
    pure (Pricing.attachCost (pricing api) (mapResponse start end obj))

mapRequest :: Req.Request -> Either Text Chat.CreateChatCompletion
mapRequest req = do
  body <- traverse mapMessage (Vector.toList (req ^. #messages))
  let prefix = case req ^. #systemPrompt of
        Nothing -> []
        Just sp ->
          [ Chat.System
              { Chat.content = Vector.singleton Chat.Text {Chat.text = sp}
              , Chat.name = Nothing
              }
          ]
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body)
      , Chat.model = OpenAIModels.Model (Model.unModel (req ^. #model))
      , Chat.max_completion_tokens = Just (req ^. #maxTokens)
      , Chat.temperature = req ^. #temperature
      }

mapMessage :: Msg.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage m =
  let payload = Vector.singleton Chat.Text {Chat.text = m ^. #content}
   in case m ^. #role of
        Msg.User -> Right Chat.User {Chat.content = payload, Chat.name = Nothing}
        Msg.Assistant ->
          Right
            Chat.Assistant
              { Chat.assistant_content = Just payload
              , Chat.refusal = Nothing
              , Chat.name = Nothing
              , Chat.assistant_audio = Nothing
              , Chat.tool_calls = Nothing
              }
        Msg.System -> Left "system role belongs in Request.systemPrompt, not Request.messages"

mapResponse :: UTCTime -> UTCTime -> Chat.ChatCompletionObject -> Resp.Response
mapResponse start end obj =
  Resp.Response
    { Resp.content = extractText (obj ^. #choices)
    , Resp.model = Model.Model (modelText (obj ^. #model))
    , Resp.usage = Just (mapUsage (obj ^. #usage))
    , Resp.cost = Nothing
    , Resp.provider = "openai.chat.api"
    , Resp.latencyMs = millisBetween start end
    }

modelText :: OpenAIModels.Model -> Text
modelText (OpenAIModels.Model t) = t

extractText :: Vector Chat.Choice -> Text
extractText = Text.concat . map (Chat.messageToContent . choiceMessage) . Vector.toList
  where
    choiceMessage :: Chat.Choice -> Chat.Message Text
    choiceMessage Chat.Choice {Chat.message} = message

mapUsage ::
  OpenAIUsage.Usage OpenAIUsage.CompletionTokensDetails OpenAIUsage.PromptTokensDetails ->
  Usage.Usage
mapUsage u =
  Usage.Usage
    { Usage.inputTokens = u ^. #prompt_tokens
    , Usage.outputTokens = u ^. #completion_tokens
    , Usage.cachedInputTokens = (u ^. #prompt_tokens_details) >>= (^. #cached_tokens)
    , Usage.reasoningTokens = (u ^. #completion_tokens_details) >>= (^. #reasoning_tokens)
    }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
