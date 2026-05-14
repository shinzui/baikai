{-# LANGUAGE LambdaCase #-}

-- | The streaming entry point.
--
-- 'streamRequest' looks up the per-API handler registered for a
-- model's 'Api' tag and returns its event stream. When no handler is
-- registered the function returns a one-event error stream (a single
-- 'EventError' with @stopReason = ErrorReason@) so a caller iterating
-- the stream always gets at least one terminal event.
--
-- 'streamingComplete' folds an event stream into the synchronous
-- 'Response' shape. Vendor providers register both the @stream@
-- handler and a @complete@ handler derived as
-- @streamingComplete . stream@, so a caller that does not care about
-- deltas keeps the original single-shot ergonomics with no new
-- ceremony.
module Baikai.Stream
  ( streamRequest
  , streamingComplete
  , reassembleResponse
  , liftCompleteToStream
  ) where

import Baikai.Api (renderApi)
import Baikai.Content
  ( AssistantContent (..)
  , TextContent (..)
  , ThinkingContent (..)
  )
import Baikai.Content qualified as Content
import Baikai.Context (Context)
import Baikai.Message (Message (AssistantMessage))
import Baikai.Message qualified as Msg
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Registry (ApiProvider (..), lookupApiProvider)
import Baikai.Response (Response (..))
import Baikai.Response qualified as Resp
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event (AssistantMessageEvent (..))
import Baikai.Usage (_Usage)
import Control.Exception qualified
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Streamly.Data.Fold (Fold)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Dispatch a streaming call through the registered handler for the
-- model's 'Api' tag. Returns a one-event error stream when no handler
-- is registered for that tag — the caller always sees at least one
-- terminal event.
streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequest m ctx opts =
  Stream.concatEffect $ do
    mProvider <- lookupApiProvider (m ^. #api)
    case mProvider of
      Just p -> pure (stream p m ctx opts)
      Nothing -> pure (Stream.fromEffect (noProviderEvent m))

-- | Drain an event stream into a 'Response' by folding events into
-- the assembled message.
streamingComplete
  :: (Model -> Context -> Options -> Stream IO AssistantMessageEvent)
  -> Model
  -> Context
  -> Options
  -> IO Response
streamingComplete f m ctx opts =
  Stream.fold (reassembleResponse m) (f m ctx opts)

-- | The fold used to reassemble a 'Response' from an event stream.
-- Exposed for the trace bridge so it does not duplicate the
-- reassembly logic.
reassembleResponse :: Model -> Fold IO AssistantMessageEvent Response
reassembleResponse m =
  Fold.rmapM finalizeState (Fold.foldl' step (initialState m))

-- | One frozen-in-time view of the partial assembly.
data ReassemblyState = ReassemblyState
  { rsModel :: !Model
  , rsSkeleton :: !(Maybe Message)
    -- ^ 'Just' once 'EventStart' has been observed.
  , rsBlocks :: !(IntMap AssistantContent)
    -- ^ Content blocks closed so far, keyed by @contentIndex@.
  , rsTextBuf :: !(IntMap Text)
    -- ^ Open text accumulators, indexed by @contentIndex@.
  , rsThinkBuf :: !(IntMap Text)
  , rsToolArgsBuf :: !(IntMap Text)
  , rsTerminal :: !(Maybe (StopReason, Message))
    -- ^ 'Just (reason, msg)' once 'EventDone' or 'EventError' fires.
  }
  deriving stock (Show)

initialState :: Model -> ReassemblyState
initialState m =
  ReassemblyState
    { rsModel = m
    , rsSkeleton = Nothing
    , rsBlocks = IntMap.empty
    , rsTextBuf = IntMap.empty
    , rsThinkBuf = IntMap.empty
    , rsToolArgsBuf = IntMap.empty
    , rsTerminal = Nothing
    }

step :: ReassemblyState -> AssistantMessageEvent -> ReassemblyState
step s = \case
  EventStart {partial = sk} ->
    s {rsSkeleton = Just sk}
  TextStart {contentIndex = i} ->
    s {rsTextBuf = IntMap.insert i Text.empty (rsTextBuf s)}
  TextDelta {contentIndex = i, delta = d} ->
    s {rsTextBuf = IntMap.insertWith (\new old -> old <> new) i d (rsTextBuf s)}
  TextEnd {contentIndex = i, content = body} ->
    s
      { rsBlocks = IntMap.insert i (AssistantText (TextContent body)) (rsBlocks s)
      , rsTextBuf = IntMap.delete i (rsTextBuf s)
      }
  ThinkingStart {contentIndex = i} ->
    s {rsThinkBuf = IntMap.insert i Text.empty (rsThinkBuf s)}
  ThinkingDelta {contentIndex = i, delta = d} ->
    s {rsThinkBuf = IntMap.insertWith (\new old -> old <> new) i d (rsThinkBuf s)}
  ThinkingEnd {contentIndex = i, content = body} ->
    s
      { rsBlocks =
          IntMap.insert
            i
            ( AssistantThinking
                ThinkingContent {thinking = body, signature = Nothing, redacted = False}
            )
            (rsBlocks s)
      , rsThinkBuf = IntMap.delete i (rsThinkBuf s)
      }
  ToolCallStart {contentIndex = i} ->
    s {rsToolArgsBuf = IntMap.insert i Text.empty (rsToolArgsBuf s)}
  ToolCallDelta {contentIndex = i, delta = d} ->
    s
      { rsToolArgsBuf =
          IntMap.insertWith (\new old -> old <> new) i d (rsToolArgsBuf s)
      }
  ToolCallEnd {contentIndex = i, toolCall = tc} ->
    s
      { rsBlocks = IntMap.insert i (AssistantToolCall tc) (rsBlocks s)
      , rsToolArgsBuf = IntMap.delete i (rsToolArgsBuf s)
      }
  EventDone {reason = r, message = msg} ->
    s {rsTerminal = Just (r, msg)}
  EventError {reason = r, errorPartial = msg} ->
    s {rsTerminal = Just (r, msg)}

finalizeState :: ReassemblyState -> IO Response
finalizeState s = do
  now <- getCurrentTime
  let m = rsModel s
      assembled = assembleBlocks s
      (terminalMsg, terminalReason) = case rsTerminal s of
        Just (r, msg) -> (msg, r)
        Nothing -> (synthesizeTerminal now assembled, Stop)
      message' = overrideBlocksAndReason terminalReason terminalMsg assembled
  pure
    Response
      { Resp.message = message'
      , Resp.model = m
      , Resp.api = m ^. #api
      , Resp.provider = m ^. #provider
      , Resp.responseId = Nothing
      , Resp.latencyMs = 0
      }

-- | Project the closed content blocks in 'contentIndex' order, plus
-- any still-open text/thinking accumulators flushed as best-effort
-- content (recovery path; providers should not exercise this).
assembleBlocks :: ReassemblyState -> Vector AssistantContent
assembleBlocks s =
  let closed = IntMap.elems (rsBlocks s)
      danglingText =
        [ AssistantText (TextContent t)
        | (_, t) <- IntMap.toAscList (rsTextBuf s)
        , not (Text.null t)
        ]
      danglingThink =
        [ AssistantThinking
            ThinkingContent {thinking = t, signature = Nothing, redacted = False}
        | (_, t) <- IntMap.toAscList (rsThinkBuf s)
        , not (Text.null t)
        ]
   in Vector.fromList (closed <> danglingText <> danglingThink)

-- | Replace the content vector and stop reason of an assistant
-- message, preserving usage, errorMessage, and timestamp.
overrideBlocksAndReason
  :: StopReason -> Message -> Vector AssistantContent -> Message
overrideBlocksAndReason sr msg blocks = case msg of
  AssistantMessage {usage = u, errorMessage = em, timestamp = ts} ->
    AssistantMessage
      { Msg.assistantContent = blocks
      , Msg.usage = u
      , Msg.stopReason = sr
      , Msg.errorMessage = em
      , Msg.timestamp = ts
      }
  other -> other

-- | Build a placeholder 'AssistantMessage' for streams that ended
-- without a terminal event (a producer bug; the recovery path).
synthesizeTerminal :: UTCTime -> Vector AssistantContent -> Message
synthesizeTerminal now blocks =
  AssistantMessage
    { Msg.assistantContent = blocks
    , Msg.usage = _Usage
    , Msg.stopReason = Stop
    , Msg.errorMessage = Just "stream ended without terminal event"
    , Msg.timestamp = now
    }

-- | Wrap a synchronous @complete@ handler in a one-shot event
-- stream. Used by vendor providers (notably the CLI providers and
-- as a stepping stone for the API providers before they grow native
-- streaming producers) so a 'Baikai.Provider.Registry.ApiProvider'
-- can always populate its 'stream' field. The emitted event
-- sequence is:
--
-- * 'EventStart' carrying the response's message skeleton (empty
--   content vector; api/provider/model id only).
-- * For each closed content block in the resolved 'Response', a
--   matching @_Start@ / @_Delta@ / @_End@ trio. Text blocks emit
--   one 'TextDelta' with the whole text; tool calls emit one
--   'ToolCallDelta' with the JSON-encoded arguments.
-- * 'EventDone' carrying the fully assembled assistant message.
--
-- An exception from @complete@ becomes a single-'EventError' stream
-- with @stopReason = ErrorReason@ and 'errorMessage' set from the
-- exception's display.
liftCompleteToStream
  :: (Model -> Context -> Options -> IO Response)
  -> Model
  -> Context
  -> Options
  -> Stream IO AssistantMessageEvent
liftCompleteToStream f m ctx opts =
  Stream.concatEffect $ do
    er <- tryAny (f m ctx opts)
    case er of
      Right resp -> pure (Stream.fromList (eventsFor resp))
      Left e -> pure (Stream.fromEffect (errorEvent e))

-- | A typed 'try' over any synchronous exception.
tryAny :: IO a -> IO (Either Control.Exception.SomeException a)
tryAny = Control.Exception.try

-- | Build the synthetic event list for a fully resolved 'Response'.
eventsFor :: Response -> [AssistantMessageEvent]
eventsFor resp =
  let msg = Resp.message resp
      skeleton = case msg of
        AssistantMessage {Msg.usage = u, Msg.stopReason = sr, Msg.errorMessage = em, Msg.timestamp = ts} ->
          AssistantMessage
            { Msg.assistantContent = Vector.empty
            , Msg.usage = u
            , Msg.stopReason = sr
            , Msg.errorMessage = em
            , Msg.timestamp = ts
            }
        other -> other
      blocks = case msg of
        AssistantMessage {Msg.assistantContent = c} -> Vector.toList c
        _ -> []
      blockEvents =
        concat
          [ blockEvent i b
          | (i, b) <- zip [0 ..] blocks
          ]
      reason = case msg of
        AssistantMessage {Msg.stopReason = sr} -> sr
        _ -> Stop
   in [EventStart {partial = skeleton}]
        <> blockEvents
        <> [EventDone {reason = reason, message = msg}]

blockEvent :: Int -> AssistantContent -> [AssistantMessageEvent]
blockEvent i = \case
  AssistantText (TextContent t) ->
    [ TextStart {contentIndex = i}
    , TextDelta {contentIndex = i, delta = t}
    , TextEnd {contentIndex = i, content = t}
    ]
  AssistantThinking ThinkingContent {thinking = t} ->
    [ ThinkingStart {contentIndex = i}
    , ThinkingDelta {contentIndex = i, delta = t}
    , ThinkingEnd {contentIndex = i, content = t}
    ]
  AssistantToolCall tc ->
    let argsText =
          Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
     in [ ToolCallStart {contentIndex = i}
        , ToolCallDelta {contentIndex = i, delta = argsText}
        , ToolCallEnd {contentIndex = i, toolCall = tc}
        ]

errorEvent :: Control.Exception.SomeException -> IO AssistantMessageEvent
errorEvent e = do
  now <- getCurrentTime
  let msg =
        AssistantMessage
          { Msg.assistantContent = Vector.empty
          , Msg.usage = _Usage
          , Msg.stopReason = ErrorReason
          , Msg.errorMessage = Just (Text.pack (Control.Exception.displayException e))
          , Msg.timestamp = now
          }
  pure EventError {reason = ErrorReason, errorPartial = msg}

-- | The single 'EventError' value used when no provider is
-- registered for the model's API tag.
noProviderEvent :: Model -> IO AssistantMessageEvent
noProviderEvent m = do
  now <- getCurrentTime
  let msg =
        AssistantMessage
          { Msg.assistantContent = Vector.empty
          , Msg.usage = _Usage
          , Msg.stopReason = ErrorReason
          , Msg.errorMessage =
              Just ("No provider registered for API: " <> renderApi (m ^. #api))
          , Msg.timestamp = now
          }
  pure EventError {reason = ErrorReason, errorPartial = msg}
