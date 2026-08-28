{-# LANGUAGE LambdaCase #-}

-- | The streaming event algebra: 'AssistantMessageEvent'.
--
-- A provider call exposes its progress as a 'Streamly.Data.Stream.Stream
-- IO AssistantMessageEvent'. The stream begins with a single
-- 'EventStart' carrying an 'AssistantMessage' skeleton — empty content,
-- zero usage, no stop reason yet — interleaves per-content-block
-- lifecycle events
-- (@_Start@ / @_Delta@ / @_End@) keyed by 'contentIndex', and
-- terminates with exactly one 'EventDone' (success) or 'EventError'
-- (any failure that bubbled out of the producer). This EventStart-first
-- invariant includes error-only streams produced by core dispatch and
-- request-preparation failures; they emit a synthetic skeleton before
-- the terminal error. It holds without exception: both HTTP providers
-- pre-seed their skeleton before the first wire read, so a failure that
-- arrives before the provider has said anything about the response
-- still begins its stream with 'EventStart'.
-- The terminal event carries the fully assembled
-- 'AssistantMessage' so a consumer that only pattern-matches on the
-- terminal event still gets a correct response without folding deltas.
--
-- The algebra is closed and shared by every provider. Adding a new
-- variant is a breaking change to baikai's public surface. Consumers
-- that prefer source resilience over exhaustiveness can include a
-- final wildcard branch in their pattern match, but providers MUST NOT
-- emit untyped provider-specific events through this algebra. Providers
-- MUST emit @_Start@, then zero or more @_Delta@, then @_End@ for each
-- content block in increasing @contentIndex@ order; the reassembler
-- defends against missing @_End@ events but no built-in provider should
-- rely on the recovery path.
module Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    StartPayload (..),
    IndexPayload (..),
    DeltaPayload (..),
    BlockEndPayload (..),
    ThinkingEndPayload (..),
    ToolCallEndPayload (..),
    TerminalPayload (..),
    doneTerminal,
    errorTerminal,
    isTerminal,
  )
where

import Baikai.Content (ThinkingContent, ToolCall)
import Baikai.Error (BaikaiError)
import Baikai.Evidence (ModelCallEvidence)
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
-- 'ThinkingEndPayload', 'TerminalPayload'), so the payloads also
-- collapse the repetition the flat encoding spread across twelve
-- constructors.
data AssistantMessageEvent
  = -- | The first event in every stream. The payload's 'partial' is an
    -- 'AssistantMessage' skeleton: empty content, zero usage, and no
    -- stop reason yet. The api, provider and model id live on the
    -- 'Baikai.Response.Response', not on the message.
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
  | -- | The thinking block at @contentIndex@ is closed. The payload
    -- carries the full 'ThinkingContent', including provider
    -- signature and redacted flag when available.
    ThinkingEnd ThinkingEndPayload
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
    -- 'errorMessage' and @stopReason = ErrorReason@.
    EventError TerminalPayload
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of 'EventStart': the message skeleton observed up front,
-- plus the provider's message id when the provider knows it before its
-- first event.
--
-- Neither HTTP provider does: both pre-seed this event before the first
-- wire read, so that a failure arriving before the provider has said
-- anything still begins the stream the way the protocol says every
-- stream begins. The id, when it arrives, rides
-- 'TerminalPayload.responseId', which
-- 'Baikai.Stream.reassembleResponse' prefers over this one anyway. A
-- lifted or replaying provider that knows the id up front may still set
-- it here.
data StartPayload = StartPayload
  { partial :: !Message,
    responseId :: !(Maybe Text)
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

-- | Payload of the text @_End@ event: the closed block's fully
-- concatenated 'content'.
data BlockEndPayload = BlockEndPayload
  { contentIndex :: !Int,
    content :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Payload of 'ThinkingEnd': the closed thinking block in full —
-- concatenated reasoning text plus the provider 'signature' and
-- 'redacted' flag. The concatenation of the preceding
-- 'ThinkingDelta's equals the payload's @content.thinking@.
data ThinkingEndPayload = ThinkingEndPayload
  { contentIndex :: !Int,
    content :: !ThinkingContent
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
    message :: !Message,
    -- | The provider's message id when known by stream end. Consumers
    -- should prefer this over 'StartPayload.responseId'.
    responseId :: !(Maybe Text),
    -- | Structured error detail. Always 'Nothing' on 'EventDone' and
    -- always 'Just' on 'EventError'; use 'errorTerminal' to enforce the
    -- error-side invariant at construction sites.
    errorInfo :: !(Maybe BaikaiError),
    -- | The evidence the provider adapter built for this call, when the
    -- adapter produced any. This is the channel a provider uses to
    -- report what it actually put on the wire back to
    -- "Baikai.Trace", which otherwise only sees the caller's own
    -- 'Baikai.Model.Model' and 'Baikai.Options.Options'.
    --
    -- 'Nothing' means one of two things and a consumer must not try to
    -- tell them apart: the caller set no
    -- 'Baikai.Options.evidence' request, or this provider has not been
    -- taught to build evidence. Both are distinct from evidence whose
    -- observed fields are 'Baikai.Evidence.Unobserved', which is a
    -- positive statement that the provider reported nothing back.
    evidence :: !(Maybe ModelCallEvidence)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Build a success terminal payload ('errorInfo' is always 'Nothing').
-- Prefer this over the raw 'TerminalPayload' constructor so a new field
-- can never be left uninitialised at a construction site.
--
-- The evidence comes first because it is the argument most likely to be
-- supplied from a @let@-bound value at the call site; pass 'Nothing'
-- from a provider that does not build evidence.
doneTerminal ::
  Maybe ModelCallEvidence -> Maybe Text -> StopReason -> Message -> TerminalPayload
doneTerminal ev rid r m =
  TerminalPayload
    { reason = r,
      message = m,
      responseId = rid,
      errorInfo = Nothing,
      evidence = ev
    }

-- | Build an error terminal payload carrying structured error detail.
-- Prefer this over the raw 'TerminalPayload' constructor so an
-- 'EventError' cannot be constructed without 'errorInfo'.
--
-- A failed call still carries evidence when the caller asked for it: a
-- call that failed is a fact about the call, and a run record that
-- omits it is worse than one that records the failure.
errorTerminal ::
  Maybe ModelCallEvidence ->
  Maybe Text ->
  StopReason ->
  Message ->
  BaikaiError ->
  TerminalPayload
errorTerminal ev rid r m e =
  TerminalPayload
    { reason = r,
      message = m,
      responseId = rid,
      errorInfo = Just e,
      evidence = ev
    }

-- | 'True' when the event terminates the stream — exactly one
-- 'EventDone' or 'EventError' is emitted per call.
isTerminal :: AssistantMessageEvent -> Bool
isTerminal = \case
  EventDone {} -> True
  EventError {} -> True
  _ -> False
