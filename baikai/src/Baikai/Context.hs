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
    appendToolResult,
    appendToolResultText,
  )
where

import Baikai.Content (AssistantContent (..), ToolCall (..))
import Baikai.Message (AssistantPayload (..), Message (..), ToolResult, toolResultFromCall, toolResultText)
import Baikai.Response (Response (..))
import Baikai.Tool (Tool)
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
  let respMsg = resp ^. #message
      toolCalls = case respMsg of
        AssistantMessage AssistantPayload {content = blocks} ->
          [tc | AssistantToolCall tc <- V.toList blocks]
        _ -> []
  results <-
    traverse
      ( \tc -> do
          result <- dispatcher tc
          pure (toolResultFromCall tc result)
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
