{-# LANGUAGE LambdaCase #-}

-- | The streaming event algebra: 'AssistantMessageEvent'.
--
-- A provider call exposes its progress as a 'Streamly.Data.Stream.Stream
-- IO AssistantMessageEvent'. The stream begins with a single
-- 'EventStart' carrying an empty 'AssistantMessage' skeleton (api,
-- provider, model id), interleaves per-content-block lifecycle events
-- (@_Start@ / @_Delta@ / @_End@) keyed by 'contentIndex', and
-- terminates with exactly one 'EventDone' (success) or 'EventError'
-- (any failure that bubbled out of the producer). The terminal event
-- carries the fully assembled 'AssistantMessage' so a consumer that
-- only pattern-matches on the terminal event still gets a correct
-- response without folding deltas.
--
-- The algebra is closed and shared by every provider. Adding a new
-- variant is a breaking change to baikai's public surface. Providers
-- MUST emit @_Start@, then zero or more @_Delta@, then @_End@ for
-- each content block in increasing @contentIndex@ order; the
-- reassembler defends against missing @_End@ events but no built-in
-- provider should rely on the recovery path.
module Baikai.Stream.Event
  ( AssistantMessageEvent (..)
  , isTerminal
  ) where

import Baikai.Content (ToolCall)
import Baikai.Message (Message)
import Baikai.StopReason (StopReason)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | One observable step of an assistant turn.
--
-- @contentIndex@ identifies which content block a per-block event
-- refers to. Indices are non-negative and strictly increasing in the
-- order blocks are opened; gaps are permitted (an OpenAI stream that
-- emits a text block at index 0 then a tool call at index 2 is
-- legal, as long as the @_Start@ of index 2 follows the @_End@ of
-- index 0).
data AssistantMessageEvent
  = -- | The first event in every stream. @partial@ is an
    -- 'AssistantMessage' with empty 'assistantContent'; downstream
    -- consumers that care only about the message skeleton (api,
    -- provider, model id) can read it here.
    EventStart
      { partial :: !Message
      }
  | -- | A text content block is about to receive deltas.
    TextStart
      { contentIndex :: !Int
      }
  | -- | A chunk of text appended to the text block at @contentIndex@.
    TextDelta
      { contentIndex :: !Int
      , delta :: !Text
      }
  | -- | The text block at @contentIndex@ is closed; @content@ is the
    -- concatenation of every preceding 'TextDelta' for the same
    -- index.
    TextEnd
      { contentIndex :: !Int
      , content :: !Text
      }
  | -- | A thinking content block is about to receive deltas.
    ThinkingStart
      { contentIndex :: !Int
      }
  | -- | A chunk of reasoning text appended to the thinking block.
    ThinkingDelta
      { contentIndex :: !Int
      , delta :: !Text
      }
  | -- | The thinking block at @contentIndex@ is closed.
    ThinkingEnd
      { contentIndex :: !Int
      , content :: !Text
      }
  | -- | A tool-call content block is about to receive argument-JSON
    -- chunks. The tool's @id_@ and @name@ become known on this event
    -- when the upstream API delivers them up front (Anthropic), or on
    -- subsequent deltas otherwise (OpenAI).
    ToolCallStart
      { contentIndex :: !Int
      }
  | -- | A chunk of the tool call's arguments JSON. Concatenating
    -- every 'ToolCallDelta' for a given @contentIndex@ yields a
    -- syntactically valid JSON value.
    ToolCallDelta
      { contentIndex :: !Int
      , delta :: !Text
      }
  | -- | The tool call at @contentIndex@ is closed; @toolCall@ is the
    -- fully parsed call ('id_', 'name', and decoded 'arguments').
    ToolCallEnd
      { contentIndex :: !Int
      , toolCall :: !ToolCall
      }
  | -- | The stream's terminal success event. @message@ is the fully
    -- assembled 'AssistantMessage' carrying all content blocks, the
    -- final 'Usage', and the resolved 'StopReason'.
    EventDone
      { reason :: !StopReason
      , message :: !Message
      }
  | -- | The stream's terminal failure event. @error@ is an
    -- 'AssistantMessage' carrying whatever content blocks were
    -- already closed before the failure, plus a populated
    -- 'errorMessage' and @stopReason = ErrorReason@ or
    -- @stopReason = Aborted@.
    EventError
      { reason :: !StopReason
      , errorPartial :: !Message
      }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | 'True' when the event terminates the stream — exactly one
-- 'EventDone' or 'EventError' is emitted per call.
isTerminal :: AssistantMessageEvent -> Bool
isTerminal = \case
  EventDone {} -> True
  EventError {} -> True
  _ -> False
