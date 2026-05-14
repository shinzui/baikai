-- | Provider wrapping the @claude@ package's Messages API.
--
-- Construct a 'ClaudeApi' with 'claudeApi' and a 'Baikai.Auth.ApiKeySource',
-- then pass it to 'Baikai.Provider.runRequest' as you would any other provider.
-- The provider name is @"anthropic.claude.api"@.
--
-- Contract: 'Baikai.Request.Request.messages' must contain only 'User' and
-- 'Assistant' roles. A 'System' role inside the messages vector causes
-- 'runRequest' to throw 'RequestInvalid'; use 'Baikai.Request.Request.systemPrompt'
-- instead.
module Baikai.Provider.Claude.Api
  ( ClaudeApi (..)
  , claudeApi
  ) where

import qualified Baikai.Auth as Auth
import qualified Baikai.Cost.Pricing as Pricing
import Baikai.Error (BaikaiError (..))
import qualified Baikai.Message as Msg
import qualified Baikai.Model as Model
import Baikai.Provider (Provider (..))
import qualified Baikai.Request as Req
import qualified Baikai.Response as Resp
import qualified Baikai.Usage as Usage
import qualified Claude.V1 as Claude
import qualified Claude.V1.Messages as Messages
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Generics.Labels ()
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import qualified Data.Vector as Vector

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

-- | Translate a 'Baikai.Request.Request' to Anthropic's 'Messages.CreateMessage'.
--
-- Rejects messages whose role is 'Msg.System'; those belong in
-- 'Req.systemPrompt'.
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
mapMessage m = case m ^. #role of
  Msg.User -> Right (mkMessage Messages.User (m ^. #content))
  Msg.Assistant -> Right (mkMessage Messages.Assistant (m ^. #content))
  Msg.System -> Left "system role belongs in Request.systemPrompt, not Request.messages"

mkMessage :: Messages.Role -> Text -> Messages.Message
mkMessage r t =
  Messages.Message
    { Messages.role = r
    , Messages.content = Vector.singleton (Messages.textContent t)
    , Messages.cache_control = Nothing
    }

mapResponse :: UTCTime -> UTCTime -> Messages.MessageResponse -> Resp.Response
mapResponse start end resp =
  Resp.Response
    { Resp.content = extractText (resp ^. #content)
    , Resp.model = Model.Model (resp ^. #model)
    , Resp.usage = Just (mapUsage (resp ^. #usage))
    , Resp.cost = Nothing
    , Resp.provider = "anthropic.claude.api"
    , Resp.latencyMs = millisBetween start end
    }

extractText :: Vector Messages.ContentBlock -> Text
extractText = Text.concat . Vector.toList . Vector.mapMaybe textOf
  where
    textOf (Messages.ContentBlock_Text t) = Just t
    textOf _ = Nothing

mapUsage :: Messages.Usage -> Usage.Usage
mapUsage u =
  Usage.Usage
    { Usage.inputTokens = u ^. #input_tokens
    , Usage.outputTokens = u ^. #output_tokens
    , Usage.cachedInputTokens = u ^. #cache_read_input_tokens
    , Usage.reasoningTokens = Nothing
    }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
