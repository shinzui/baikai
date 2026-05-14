{-# LANGUAGE LambdaCase #-}

-- | The 'Api' tag — a typed discriminator that identifies which
-- upstream API a 'Baikai.Model.Model' speaks.
--
-- 'Api' is a closed sum with an open 'Custom' escape hatch. The
-- closed constructors enable exhaustiveness checking inside the
-- library when a new built-in API is added; the 'Custom' constructor
-- preserves the open-world property so third-party callers can
-- register handlers under any tag without modifying baikai itself.
--
-- The wire form is a single kebab-cased string
-- (@anthropic-messages@, @openai-chat-completions@, …). Round-trips
-- between 'Api' and 'Text' go through 'renderApi' and 'parseApi';
-- any unknown tag becomes 'Custom !Text'.
module Baikai.Api
  ( Api (..)
  , renderApi
  , parseApi
  ) where

import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), withText)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | The supported upstream API surfaces, plus an open escape hatch.
data Api
  = OpenAIChatCompletions
  | AnthropicMessages
  | OpenAICompletionsCli
  | AnthropicMessagesCli
  | Custom !Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Render an 'Api' tag as its canonical kebab-cased wire string.
renderApi :: Api -> Text
renderApi = \case
  OpenAIChatCompletions -> "openai-chat-completions"
  AnthropicMessages -> "anthropic-messages"
  OpenAICompletionsCli -> "openai-completions-cli"
  AnthropicMessagesCli -> "anthropic-messages-cli"
  Custom t -> t

-- | Parse a wire string into an 'Api' tag. Unknown strings become
-- 'Custom' values so callers can use the same tag space.
parseApi :: Text -> Api
parseApi = \case
  "openai-chat-completions" -> OpenAIChatCompletions
  "anthropic-messages" -> AnthropicMessages
  "openai-completions-cli" -> OpenAICompletionsCli
  "anthropic-messages-cli" -> AnthropicMessagesCli
  t -> Custom t

instance ToJSON Api where
  toJSON = toJSON . renderApi

instance FromJSON Api where
  parseJSON = withText "Api" (pure . parseApi)
