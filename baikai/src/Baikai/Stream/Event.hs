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
-- The algebra is closed and shared by every provider in baikai 0.1.
-- Adding a new variant is a breaking change to baikai's public
-- surface. Consumers that prefer source resilience over exhaustiveness
-- can include a final wildcard branch in their pattern match, but
-- providers MUST NOT emit untyped provider-specific events through
-- this algebra. Providers MUST emit @_Start@, then zero or more
-- @_Delta@, then @_End@ for each content block in increasing
-- @contentIndex@ order; the reassembler defends against missing
-- @_End@ events but no built-in provider should rely on the recovery
-- path.
module Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    StartPayload (..),
    IndexPayload (..),
    DeltaPayload (..),
    BlockEndPayload (..),
    ToolCallEndPayload (..),
    TerminalPayload (..),
    isTerminal,
  )
where

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
-- Each constructor wraps a dedicated single-constructor payload record
-- rather than carrying record fields directly on the sum. A field
-- selector defined across this multi-constructor algebra would be
-- partial (e.g. a @delta@ that throws on 'EventStart'); @-Wpartial-fields@
-- flags that latent runtime hazard. Same-shaped constructors share one
-- payload type ('IndexPayload', 'DeltaPayload', 'BlockEndPayload',
-- 'TerminalPayload'), so the payloads also collapse the repetition the
-- flat encoding spread across twelve constructors.
data AssistantMessageEvent
  = -- | The first event in every stream. The payload's 'partial' is an
    -- 'AssistantMessage' with empty content; downstream consumers that
    -- care only about the message skeleton (api, provider, model id)
    -- can read it here.
    EventStart StartPayload
  | -- | A text content block is about to receive deltas.
    TextStart IndexPayload
  | -- | A chunk of text appended to the text block at @contentIndex@.
    TextDelta DeltaPayload
  | -- | The text block at @contentIndex@ is closed; the payload's
    -- 'content' is the concatenation of every preceding 'TextDelta'
    -- for the same index.
    TextEnd BlockEndPayload
  | -- | A thinking content block is about to receive deltas.
    ThinkingStart IndexPayload
  | -- | A chunk of reasoning text appended to the thinking block.
    ThinkingDelta DeltaPayload
  | -- | The thinking block at @contentIndex@ is closed.
    ThinkingEnd BlockEndPayload
  | -- | A tool-call content block is about to receive argument-JSON
    -- chunks. The tool's @id_@ and @name@ become known on this event
    -- when the upstream API delivers them up front (Anthropic), or on
    -- subsequent deltas otherwise (OpenAI).
    ToolCallStart IndexPayload
  | -- | A chunk of the tool call's arguments JSON. Concatenating
    -- every 'ToolCallDelta' for a given @contentIndex@ yields a
    -- syntactically valid JSON value.
    ToolCallDelta DeltaPayload
  | -- | The tool call at @contentIndex@ is closed; the payload's
    -- 'toolCall' is the fully parsed call ('id_', 'name', and decoded
    -- 'arguments').
    ToolCallEnd ToolCallEndPayload
  | -- | The stream's terminal success event. The payload's 'message'
    -- is the fully assembled 'AssistantMessage' carrying all content
    -- blocks, the final 'Usage', and the resolved 'StopReason'.
    EventDone TerminalPayload
  | -- | The stream's terminal failure event. The payload's 'message'
    -- is an 'AssistantMessage' carrying whatever content blocks were
    -- already closed before the failure, plus a populated
    -- 'errorMessage' and @stopReason = ErrorReason@ or
    -- @stopReason = Aborted@.
    EventError TerminalPayload
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of 'EventStart': the message skeleton observed up front.
newtype StartPayload = StartPayload
  { partial :: Message
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of the @_Start@ events: which content block is opening.
newtype IndexPayload = IndexPayload
  { contentIndex :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of the @_Delta@ events: a chunk appended to the block at
-- @contentIndex@.
data DeltaPayload = DeltaPayload
  { contentIndex :: !Int,
    delta :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of the text/thinking @_End@ events: the closed block's
-- fully concatenated 'content'.
data BlockEndPayload = BlockEndPayload
  { contentIndex :: !Int,
    content :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of 'ToolCallEnd': the fully parsed 'toolCall'.
data ToolCallEndPayload = ToolCallEndPayload
  { contentIndex :: !Int,
    toolCall :: !ToolCall
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of the terminal events 'EventDone' and 'EventError': the
-- resolved 'StopReason' and the assembled 'message'.
data TerminalPayload = TerminalPayload
  { reason :: !StopReason,
    message :: !Message
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
