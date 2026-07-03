-- | The 'Context' record — the part of a request that defines the
-- conversation: the optional system prompt, the message vector, and
-- the declared tools the model may invoke.
--
-- 'Context' replaces the prior 'Baikai.Request.Request' record's
-- conversation-related fields. The per-call knobs that previously
-- lived alongside the messages (max tokens, temperature, API key)
-- now live on 'Baikai.Options.Options' instead.
--
-- EP-4 adds the @tools@ field and the 'appendToolResult' helper
-- that builds the follow-up request after the model invoked one or
-- more tools. The helper lives here rather than in 'Baikai.Tool' so
-- that 'Baikai.Tool' can stay imports-light (the 'Tool' type is
-- referenced by the @tools@ field, so 'Baikai.Tool' cannot itself
-- depend on 'Context').
module Baikai.Context
  ( Context (..),
    _Context,
    contextOf,
    systemUser,
    addUser,
    addMessage,
    addResponse,
    appendToolResult,
    appendToolResultText,
  )
where

import Baikai.Content (AssistantContent (..), ToolCall (..))
import Baikai.Message (Message (..), ToolResult, toolResultFromCallNow, toolResultText, user)
import Baikai.Response (Response (..), responseMessage)
import Baikai.Tool (Tool)
import Control.Applicative ((<|>))
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (ToJSON)
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data Context = Context
  { systemPrompt :: !(Maybe Text),
    messages :: !(Vector Message),
    tools :: !(Vector Tool)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

_Context :: Context
_Context =
  Context
    { systemPrompt = Nothing,
      messages = V.empty,
      tools = V.empty
    }

instance Semigroup Context where
  a <> b =
    Context
      { systemPrompt = systemPrompt a <|> systemPrompt b,
        messages = messages a <> messages b,
        tools = tools a <> tools b
      }

instance Monoid Context where
  mempty = _Context

-- | Build a context from an existing list of messages.
contextOf :: [Message] -> Context
contextOf msgs =
  _Context {messages = V.fromList msgs}

-- | Build a context with a system prompt and one user message.
systemUser :: Text -> Text -> Context
systemUser sys prompt =
  _Context
    { systemPrompt = Just sys,
      messages = V.singleton (user prompt)
    }

-- | Append a one-text-block user message.
addUser :: Text -> Context -> Context
addUser t = addMessage (user t)

-- | Append a message to the conversation.
addMessage :: Message -> Context -> Context
addMessage msg ctx =
  ctx {messages = V.snoc (messages ctx) msg}

-- | Append a provider response as an assistant message.
addResponse :: Response -> Context -> Context
addResponse resp = addMessage (responseMessage resp)

-- | Execute every 'AssistantToolCall' in @resp@'s message via the
-- caller-supplied dispatcher, then append the assistant message and
-- one 'Baikai.Message.ToolResultMessage' per call to @ctx@. The
-- returned 'Context' is ready to drive the follow-up request that
-- gives the model the tool results.
--
-- The dispatcher receives one 'ToolCall' at a time and returns a rich
-- 'ToolResult' carrying text blocks, image blocks, and an error flag.
-- Any error handling (timeouts, sandboxing, multi-call concurrency)
-- lives in the dispatcher.
appendToolResult ::
  Context ->
  Response ->
  (ToolCall -> IO ToolResult) ->
  IO Context
appendToolResult ctx resp dispatcher = do
  let respPayload = resp ^. #message
      respMsg = responseMessage resp
      toolCalls = [tc | AssistantToolCall tc <- V.toList (respPayload ^. #content)]
  results <-
    traverse
      ( \tc -> do
          result <- dispatcher tc
          toolResultFromCallNow tc result
      )
      toolCalls
  pure $
    ctx
      & #messages
        .~ ( (ctx ^. #messages)
               <> V.singleton respMsg
               <> V.fromList results
           )

-- | Text-only convenience wrapper for the common case where every
-- tool call returns one successful text block.
appendToolResultText ::
  Context ->
  Response ->
  (ToolCall -> IO Text) ->
  IO Context
appendToolResultText ctx resp dispatcher =
  appendToolResult ctx resp (fmap toolResultText . dispatcher)
