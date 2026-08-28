-- | The 'Context' record — the part of a request that defines the
-- conversation: the optional system prompt, the message vector, and
-- the declared tools the model may invoke.
--
-- The per-call knobs — max tokens, temperature, API key — live on
-- 'Baikai.Options.Options' instead, so a conversation and the settings
-- it is dispatched with are separate values.
--
-- The @tools@ field is on the context because the same tool set applies
-- to every turn, and so is 'appendToolResult', which builds the
-- follow-up request after the model invoked one or more tools. The
-- helper lives here rather than in 'Baikai.Tool' so
-- that 'Baikai.Tool' can stay imports-light (the 'Tool' type is
-- referenced by the @tools@ field, so 'Baikai.Tool' cannot itself
-- depend on 'Context').
module Baikai.Context
  ( Context,
    systemPrompt,
    messages,
    tools,
    emptyContext,
    contextOf,
    systemUser,
    addUser,
    addMessage,
    addResponse,
    appendToolResult,
    appendToolResultText,
  )
where

import Baikai.Content (AssistantContent (..), ToolCall (..), isCutOffToolCall)
import Baikai.Message (Message (..), ToolResult, toolResultErrorText, toolResultFromCallNow, toolResultText, user)
import Baikai.Response (Response (..), responseError, responseMessage)
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

emptyContext :: Context
emptyContext =
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
  mempty = emptyContext

-- | Build a context from an existing list of messages.
contextOf :: [Message] -> Context
contextOf msgs =
  emptyContext {messages = V.fromList msgs}

-- | Build a context with a system prompt and one user message.
systemUser :: Text -> Text -> Context
systemUser sys prompt =
  emptyContext
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
-- Calls are dispatched one at a time, in the order they appear, and the
-- dispatcher returns a rich 'ToolResult' carrying text blocks, image
-- blocks, and an error flag. Any timeout or sandboxing lives in the
-- dispatcher.
--
-- An __error-shaped response__ (one whose 'Baikai.Response.responseError'
-- is 'Just') appends nothing and dispatches nothing: the context comes
-- back unchanged. A failed call has no assistant turn worth replaying
-- and no tool calls to answer, and appending its empty message would put
-- a turn into the transcript that the model never took.
-- 'Baikai.Provider.Registry.runToolLoop' has always stopped on such a
-- response; the documented direct round trip in @docs\/user\/tools.md@
-- reaches here instead, and now behaves the same way.
--
-- A tool call cut off by the output cap
-- ('Baikai.Content.isCutOffToolCall') is __never dispatched__: its
-- arguments are the raw text the model got as far as sending, not a
-- request it finished making. It still gets a
-- 'Baikai.Message.ToolResultMessage', with @isError = True@ explaining
-- why, because a caller driving the exchange by hand expects one result
-- per call and must not silently lose the turn.
-- 'Baikai.Provider.Registry.runToolLoop' stops on such a response
-- instead of reaching here.
appendToolResult ::
  Context ->
  Response ->
  (ToolCall -> IO ToolResult) ->
  IO Context
appendToolResult ctx resp _dispatcher
  | Just _ <- responseError resp = pure ctx
appendToolResult ctx resp dispatcher = do
  let respPayload = resp ^. #message
      respMsg = responseMessage resp
      toolCalls = [tc | AssistantToolCall tc <- V.toList (respPayload ^. #content)]
  results <-
    traverse
      ( \tc -> do
          result <-
            if isCutOffToolCall tc
              then pure cutOffToolResult
              else dispatcher tc
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

-- | What 'appendToolResult' reports instead of dispatching a call the
-- model never finished asking for.
cutOffToolResult :: ToolResult
cutOffToolResult =
  toolResultErrorText
    "tool call arguments were cut off by the output limit; the call was not dispatched — raise maxTokens and retry"

-- | Text-only convenience wrapper for the common case where every
-- tool call returns one successful text block.
appendToolResultText ::
  Context ->
  Response ->
  (ToolCall -> IO Text) ->
  IO Context
appendToolResultText ctx resp dispatcher =
  appendToolResult ctx resp (fmap toolResultText . dispatcher)
