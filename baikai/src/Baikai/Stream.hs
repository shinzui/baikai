{-# LANGUAGE LambdaCase #-}

-- | The streaming entry point.
--
-- 'streamRequest' looks up the per-API handler registered for a
-- model's 'Api' tag and returns its event stream. When no handler is
-- registered the function returns a synthetic 'EventStart' followed by
-- a terminal 'EventError' with @stopReason = ErrorReason@, preserving
-- the protocol that every core-owned stream starts with 'EventStart'.
--
-- 'streamingComplete' folds an event stream into the synchronous
-- 'Response' shape. Vendor providers register both the @stream@
-- handler and a @complete@ handler derived as
-- @streamingComplete . stream@, so a caller that does not care about
-- deltas keeps the original single-shot ergonomics with no new
-- ceremony.
module Baikai.Stream
  ( streamRequest,
    streamRequestWith,
    streamRequestEach,
    streamRequestEachWith,
    streamRequestList,
    streamRequestListWith,
    streamingComplete,
    reassembleResponse,
    liftCompleteToStream,
  )
where

import Baikai.Api (renderApi)
import Baikai.Content
  ( AssistantContent (..),
    TextContent (..),
    ThinkingContent (..),
  )
import Baikai.Content qualified as Content
import Baikai.Context (Context)
import Baikai.Error (BaikaiError, providerError, providerUnavailable)
import Baikai.Evidence (ModelCallEvidence, noThinkingRequested)
import Baikai.Evidence qualified as Evidence
import Baikai.Evidence.Build qualified as Build
import Baikai.Message (AssistantPayload (..), Message (AssistantMessage))
import Baikai.Message qualified as Msg
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    evidenceRefusals,
    globalProviderRegistry,
    lookupApiProviderWith,
  )
import Baikai.Response (Response (..), responseError, responseMessage)
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    BlockEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    StartPayload (..),
    TerminalPayload (..),
    ThinkingEndPayload (..),
    ToolCallEndPayload (..),
    doneTerminal,
    errorTerminal,
  )
import Baikai.Usage (zeroUsage)
import Control.Applicative ((<|>))
import Control.Exception (fromException)
import Control.Exception qualified
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Clock qualified
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Streamly.Data.Fold (Fold)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Dispatch a streaming call through the registered handler for the
-- model's 'Api' tag. Returns an 'EventStart' then 'EventError' stream
-- when no handler is registered for that tag.
streamRequest :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
streamRequest = streamRequestWith globalProviderRegistry

-- | Dispatch a streaming call through the selected provider registry.
-- Returns an 'EventStart' then 'EventError' stream when no handler is
-- registered for that tag.
streamRequestWith ::
  ProviderRegistry ->
  Model ->
  Context ->
  Options ->
  Stream IO AssistantMessageEvent
streamRequestWith reg m ctx opts =
  Stream.concatEffect $ do
    mProvider <- lookupApiProviderWith reg (m ^. #api)
    case mProvider of
      Nothing -> Stream.fromList <$> noProviderEvents m opts
      Just p -> case evidenceRefusals p m opts of
        [] -> pure (stream p m ctx opts)
        refusals ->
          Stream.fromList <$> refusedEvents m opts (describeThinking p m opts) refusals

-- | Stream a request through the process-global registry, invoking the
-- callback once per event, then return the same reassembled 'Response'
-- that 'streamingComplete' would produce. Callback exceptions propagate.
streamRequestEach ::
  (AssistantMessageEvent -> IO ()) ->
  Model ->
  Context ->
  Options ->
  IO Response
streamRequestEach = streamRequestEachWith globalProviderRegistry

-- | Stream a request through an explicit registry, invoking the callback once
-- per event. The underlying event protocol is the same as 'streamRequest':
-- provider streams emit exactly one terminal event.
streamRequestEachWith ::
  ProviderRegistry ->
  (AssistantMessageEvent -> IO ()) ->
  Model ->
  Context ->
  Options ->
  IO Response
streamRequestEachWith reg callback m ctx opts =
  Stream.fold
    (reassembleResponse m)
    ( Stream.mapM
        ( \event -> do
            callback event
            pure event
        )
        (streamRequestWith reg m ctx opts)
    )

-- | Collect the event stream from the process-global registry into a list.
streamRequestList :: Model -> Context -> Options -> IO [AssistantMessageEvent]
streamRequestList = streamRequestListWith globalProviderRegistry

-- | Collect the event stream from an explicit registry into a list.
streamRequestListWith ::
  ProviderRegistry ->
  Model ->
  Context ->
  Options ->
  IO [AssistantMessageEvent]
streamRequestListWith reg m ctx opts =
  Stream.toList (streamRequestWith reg m ctx opts)

-- | Drain an event stream into a 'Response' by folding events into
-- the assembled message.
streamingComplete ::
  (Model -> Context -> Options -> Stream IO AssistantMessageEvent) ->
  Model ->
  Context ->
  Options ->
  IO Response
streamingComplete f m ctx opts =
  Stream.fold (reassembleResponse m) (f m ctx opts)

-- | The fold used to reassemble a 'Response' from an event stream.
-- Exposed for the trace bridge so it does not duplicate the
-- reassembly logic.
reassembleResponse :: Model -> Fold IO AssistantMessageEvent Response
reassembleResponse m =
  Fold.rmapM
    finalizeState
    (Fold.foldlM' (\s e -> pure (step s e)) (initialState m <$> getCurrentTime))

-- | One frozen-in-time view of the partial assembly.
data ReassemblyState = ReassemblyState
  { model :: !Model,
    -- | 'Just' once 'EventStart' has been observed.
    skeleton :: !(Maybe Message),
    -- | Captured by the reassembler when the fold starts driving the stream.
    wallStart :: !UTCTime,
    -- | Provider message id, preferring the terminal payload over the start payload.
    responseId :: !(Maybe Text),
    -- | Content blocks closed so far, keyed by @contentIndex@.
    blocks :: !(IntMap AssistantContent),
    -- | Open text accumulators, indexed by @contentIndex@.
    textBuf :: !(IntMap Text),
    thinkBuf :: !(IntMap Text),
    toolArgsBuf :: !(IntMap Text),
    -- | 'Just' once 'EventDone' or 'EventError' fires.
    terminal :: !(Maybe TerminalSeen)
  }
  deriving stock (Show, Generic)

-- | What the terminal event told us, plus which terminal it was.
data TerminalSeen = TerminalSeen
  { reason :: !StopReason,
    message :: !Message,
    errorInfo :: !(Maybe BaikaiError),
    -- | The evidence the provider adapter attached to its terminal
    -- event, copied onto the assembled 'Response' by 'finalizeState'.
    evidence :: !(Maybe ModelCallEvidence),
    failed :: !Bool
  }
  deriving stock (Show, Generic)

initialState :: Model -> UTCTime -> ReassemblyState
initialState m start =
  ReassemblyState
    { model = m,
      skeleton = Nothing,
      wallStart = start,
      responseId = Nothing,
      blocks = IntMap.empty,
      textBuf = IntMap.empty,
      thinkBuf = IntMap.empty,
      toolArgsBuf = IntMap.empty,
      terminal = Nothing
    }

step :: ReassemblyState -> AssistantMessageEvent -> ReassemblyState
step s = \case
  EventStart StartPayload {partial = sk, responseId = rid} ->
    s & #skeleton .~ Just sk & #responseId .~ rid
  TextStart IndexPayload {contentIndex = i} ->
    s & #textBuf %~ IntMap.insert i Text.empty
  TextDelta DeltaPayload {contentIndex = i, delta = d} ->
    s & #textBuf %~ IntMap.insertWith (\new old -> old <> new) i d
  TextEnd BlockEndPayload {contentIndex = i, content = body} ->
    s
      & #blocks %~ IntMap.insert i (AssistantText (TextContent body))
      & #textBuf %~ IntMap.delete i
  ThinkingStart IndexPayload {contentIndex = i} ->
    s & #thinkBuf %~ IntMap.insert i Text.empty
  ThinkingDelta DeltaPayload {contentIndex = i, delta = d} ->
    s & #thinkBuf %~ IntMap.insertWith (\new old -> old <> new) i d
  ThinkingEnd ThinkingEndPayload {contentIndex = i, content = tc} ->
    s
      & #blocks
        %~ IntMap.insert
          i
          (AssistantThinking tc)
      & #thinkBuf %~ IntMap.delete i
  ToolCallStart IndexPayload {contentIndex = i} ->
    s & #toolArgsBuf %~ IntMap.insert i Text.empty
  ToolCallDelta DeltaPayload {contentIndex = i, delta = d} ->
    s & #toolArgsBuf %~ IntMap.insertWith (\new old -> old <> new) i d
  ToolCallEnd ToolCallEndPayload {contentIndex = i, toolCall = tc} ->
    s
      & #blocks %~ IntMap.insert i (AssistantToolCall tc)
      & #toolArgsBuf %~ IntMap.delete i
  EventDone TerminalPayload {reason = r, message = msg, responseId = rid, evidence = ev} ->
    s
      & #terminal
        .~ Just
          TerminalSeen
            { reason = r,
              message = msg,
              errorInfo = Nothing,
              evidence = ev,
              failed = False
            }
      & #responseId %~ (\old -> rid <|> old)
  EventError TerminalPayload {reason = r, message = msg, responseId = rid, errorInfo = ei, evidence = ev} ->
    s
      & #terminal
        .~ Just
          TerminalSeen
            { reason = r,
              message = msg,
              errorInfo = ei,
              evidence = ev,
              failed = True
            }
      & #responseId %~ (\old -> rid <|> old)

finalizeState :: ReassemblyState -> IO Response
finalizeState s = do
  now <- getCurrentTime
  let m = s ^. #model
      assembled = assembledBlocks s
      dangling = danglingBlocks s
      (terminalMsg, terminalReason, terminalError, terminalFailed, sawTerminal) =
        case s ^. #terminal of
          Just TerminalSeen {reason = r, message = msg, errorInfo = ei, failed = failed'} ->
            (msg, r, ei, failed', True)
          Nothing -> (synthesizeTerminal now assembled, Stop, Nothing, False, False)
      terminalEvidence = s ^. #terminal >>= \TerminalSeen {evidence = ev} -> ev
      terminalContent = messageContent terminalMsg
      normalizedError = case (terminalReason, terminalError) of
        (ErrorReason, Nothing) -> Just (providerError (messageErrorText terminalMsg))
        _ -> terminalError
      finalContent
        | not sawTerminal = assembled
        | Vector.null terminalContent = assembled
        | terminalFailed = terminalContent <> Vector.fromList (IntMap.elems dangling)
        | otherwise = terminalContent
      message' = overrideBlocksAndReason terminalReason terminalMsg finalContent now
      latency = case (s ^. #skeleton >>= messageTimestamp, assistantPayloadTimestamp message') of
        (Just startTs, Just endTs) -> millisBetween startTs endTs
        _ -> 0
  pure
    Response
      { message = message',
        model = m,
        api = m ^. #api,
        provider = m ^. #provider,
        responseId = s ^. #responseId,
        latencyMs = latency,
        errorInfo = normalizedError,
        evidence = terminalEvidence
      }

-- | Project the event-assembled content in 'contentIndex' order,
-- including still-open buffers as best-effort recovery content.
assembledBlocks :: ReassemblyState -> Vector AssistantContent
assembledBlocks s =
  Vector.fromList (IntMap.elems (IntMap.union (s ^. #blocks) (danglingBlocks s)))

-- | Convert any still-open buffers into inspectable content. This is
-- the recovery path for streams that die before an @_End@ event. Partial
-- tool arguments are preserved as decoded JSON when possible, otherwise
-- as an 'Aeson.String' carrying the raw accumulated text.
danglingBlocks :: ReassemblyState -> IntMap AssistantContent
danglingBlocks s =
  IntMap.unions
    [ IntMap.mapMaybe textBlock (s ^. #textBuf),
      IntMap.mapMaybe thinkingBlock (s ^. #thinkBuf),
      IntMap.mapMaybe toolBlock (s ^. #toolArgsBuf)
    ]
  where
    textBlock t
      | Text.null t = Nothing
      | otherwise = Just (AssistantText (TextContent t))

    thinkingBlock t
      | Text.null t = Nothing
      | otherwise =
          Just (AssistantThinking ThinkingContent {thinking = t, signature = Nothing, redacted = False})

    toolBlock raw
      | Text.null raw = Nothing
      | otherwise =
          let decoded = Content.toolArgumentsFromText raw
           in Just
                ( AssistantToolCall
                    Content.ToolCall
                      { Content.id_ = "",
                        Content.name = "",
                        Content.arguments = decoded
                      }
                )

messageContent :: Message -> Vector AssistantContent
messageContent = \case
  AssistantMessage AssistantPayload {Msg.content = c} -> c
  _ -> Vector.empty

messageErrorText :: Message -> Text
messageErrorText = \case
  AssistantMessage AssistantPayload {Msg.errorMessage = Just em} -> em
  _ -> "call failed with no error detail"

messageTimestamp :: Message -> Maybe UTCTime
messageTimestamp = \case
  AssistantMessage AssistantPayload {Msg.timestamp = ts} -> ts
  _ -> Nothing

assistantPayloadTimestamp :: AssistantPayload -> Maybe UTCTime
assistantPayloadTimestamp AssistantPayload {Msg.timestamp = ts} = ts

millisBetween :: UTCTime -> UTCTime -> Int
millisBetween start end =
  max 0 (round (realToFrac (Data.Time.Clock.diffUTCTime end start) * (1000 :: Double)))

-- | Replace the content vector and stop reason of an assistant
-- message, preserving usage, errorMessage, and timestamp.
overrideBlocksAndReason ::
  StopReason -> Message -> Vector AssistantContent -> UTCTime -> AssistantPayload
overrideBlocksAndReason sr msg blocks fallbackTs = case msg of
  AssistantMessage AssistantPayload {usage = u, errorMessage = em, timestamp = ts} ->
    AssistantPayload
      { Msg.content = blocks,
        Msg.usage = u,
        Msg.stopReason = sr,
        Msg.errorMessage = em,
        Msg.timestamp = ts
      }
  _ ->
    AssistantPayload
      { Msg.content = blocks,
        Msg.usage = zeroUsage,
        Msg.stopReason = sr,
        Msg.errorMessage = Just "stream terminated with a non-assistant message",
        Msg.timestamp = Just fallbackTs
      }

-- | Build a placeholder 'AssistantMessage' for streams that ended
-- without a terminal event (a producer bug; the recovery path).
synthesizeTerminal :: UTCTime -> Vector AssistantContent -> Message
synthesizeTerminal now blocks =
  AssistantMessage
    AssistantPayload
      { Msg.content = blocks,
        Msg.usage = zeroUsage,
        Msg.stopReason = Stop,
        Msg.errorMessage = Just "stream ended without terminal event",
        Msg.timestamp = Just now
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
-- * 'EventDone' carrying the fully assembled assistant message, or
--   'EventError' when the response is error-shaped according to
--   'responseError'.
--
-- A synchronous exception from @complete@ becomes a synthetic
-- 'EventStart' followed by 'EventError' with @stopReason = ErrorReason@
-- and 'errorMessage' set from the exception's display. Asynchronous
-- exceptions are rethrown so cancellation works.
liftCompleteToStream ::
  (Model -> Context -> Options -> IO Response) ->
  Model ->
  Context ->
  Options ->
  Stream IO AssistantMessageEvent
liftCompleteToStream f m ctx opts =
  Stream.concatEffect $ do
    startTs <- getCurrentTime
    er <- trySync (f m ctx opts)
    case er of
      Right resp -> pure (Stream.fromList (eventsFor startTs resp))
      Left e -> Stream.fromList <$> errorEvents m opts startTs e

-- | 'try' for synchronous exceptions only. Anything delivered
-- asynchronously (wrapped in 'Control.Exception.SomeAsyncException' by
-- 'Control.Exception.throwTo', 'System.Timeout.timeout', Ctrl-C) is
-- rethrown so cancellation works; converting it into an 'EventError'
-- would defeat it.
trySync :: IO a -> IO (Either Control.Exception.SomeException a)
trySync action = do
  r <- Control.Exception.try action
  case r of
    Left e
      | Just (Control.Exception.SomeAsyncException _) <-
          (fromException e :: Maybe Control.Exception.SomeAsyncException) ->
          Control.Exception.throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)

-- | Build the synthetic event list for a fully resolved 'Response'.
-- The 'EventStart' carries the supplied @startTs@ on its message
-- skeleton so 'reassembleResponse' can recover 'latencyMs' from the
-- start/end timestamps.
eventsFor :: UTCTime -> Response -> [AssistantMessageEvent]
eventsFor startTs resp =
  let payload = resp ^. #message
      msg = responseMessage resp
      skeleton =
        AssistantMessage
          AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = payload ^. #usage,
              Msg.stopReason = payload ^. #stopReason,
              Msg.errorMessage = payload ^. #errorMessage,
              Msg.timestamp = Just startTs
            }
      blocks = Vector.toList (payload ^. #content)
      blockEvents =
        concat
          [ blockEvent i b
          | (i, b) <- zip [0 ..] blocks
          ]
      reason = payload ^. #stopReason
      rid = resp ^. #responseId
      -- Carry the wrapped response's evidence onto the synthetic
      -- terminal event. Without this the two subprocess providers,
      -- which reach the stream surface only through this function,
      -- would build evidence and then drop it on the floor.
      ev = resp ^. #evidence
      terminalEvent = case responseError resp of
        Just be -> EventError (errorTerminal ev rid reason msg be)
        Nothing -> EventDone (doneTerminal ev rid reason msg)
   in [EventStart StartPayload {partial = skeleton, responseId = rid}]
        <> blockEvents
        <> [terminalEvent]

blockEvent :: Int -> AssistantContent -> [AssistantMessageEvent]
blockEvent i = \case
  AssistantText (TextContent t) ->
    [ TextStart IndexPayload {contentIndex = i},
      TextDelta DeltaPayload {contentIndex = i, delta = t},
      TextEnd BlockEndPayload {contentIndex = i, content = t}
    ]
  AssistantThinking th@ThinkingContent {thinking = t} ->
    [ ThinkingStart IndexPayload {contentIndex = i},
      ThinkingDelta DeltaPayload {contentIndex = i, delta = t},
      ThinkingEnd ThinkingEndPayload {contentIndex = i, content = th}
    ]
  AssistantToolCall tc ->
    let argsText =
          Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
     in [ ToolCallStart IndexPayload {contentIndex = i},
          ToolCallDelta DeltaPayload {contentIndex = i, delta = argsText},
          ToolCallEnd ToolCallEndPayload {contentIndex = i, toolCall = tc}
        ]

-- | The synthetic error stream for a @complete@ handler that threw
-- instead of returning an error-shaped 'Response'.
--
-- The handler may well have sent a request before it threw, but it
-- never returned one for this layer to digest, so the digests are over
-- 'Build.dispatchEnvelope' — see its documentation.
errorEvents ::
  Model -> Options -> UTCTime -> Control.Exception.SomeException -> IO [AssistantMessageEvent]
errorEvents m opts startTs e = do
  now <- getCurrentTime
  -- When a @complete@ handler threw a typed 'BaikaiError' (the CLI,
  -- 'Baikai.Auth', and registry paths do), preserve it structurally so a
  -- caller draining this lifted stream still gets the category and any
  -- retry hint. Otherwise fall back to the displayed exception text.
  let mErr = fromException e :: Maybe BaikaiError
      errText = case mErr of
        Just be -> be ^. #message
        Nothing -> Text.pack (Control.Exception.displayException e)
      msg =
        AssistantMessage
          AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = zeroUsage,
              Msg.stopReason = ErrorReason,
              Msg.errorMessage = Just errText,
              Msg.timestamp = Just now
            }
      err = maybe (providerError errText) id mErr
  ev <-
    Build.minimalEvidence
      m
      opts
      (Build.transportForModel m)
      noThinkingRequested
      (Build.dispatchEnvelope m opts)
      startTs
      now
      Evidence.CallFailed
      (Just err)
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal ev Nothing ErrorReason msg err)
    ]

-- | The synthetic error stream used when no provider is registered for
-- the model's API tag.
--
-- This carries evidence when the caller asked for it. "No provider was
-- registered" is a fact about the call, and a run record that silently
-- omits it is worse than one that records the failure. There is no wire
-- request body to digest here because nothing was ever sent, so the
-- digests are over 'Build.dispatchEnvelope'.
-- | The 'EventStart' then 'EventError' stream a strict call refused
-- before dispatch returns.
--
-- Shaped exactly like 'noProviderEvents', because from a consumer's
-- point of view both are the same thing: a call that produced a terminal
-- error without a provider ever running. The evidence carries the very
-- translation that caused the refusal rather than
-- 'noThinkingRequested', so a caller told their request would be
-- downgraded can read which downgrade in the record and not only in the
-- message.
refusedEvents ::
  Model ->
  Options ->
  Evidence.ThinkingTranslation ->
  [Build.EvidenceRefusal] ->
  IO [AssistantMessageEvent]
refusedEvents m opts translation refusals = do
  now <- getCurrentTime
  let be = Build.refusalError refusals
      detail = be ^. #message
      msg =
        AssistantMessage
          AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = zeroUsage,
              Msg.stopReason = ErrorReason,
              Msg.errorMessage = Just detail,
              Msg.timestamp = Just now
            }
  ev <-
    Build.minimalEvidence
      m
      opts
      (Build.transportForModel m)
      translation
      (Build.dispatchEnvelope m opts)
      now
      now
      Evidence.CallFailed
      (Just be)
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal ev Nothing ErrorReason msg be)
    ]

noProviderEvents :: Model -> Options -> IO [AssistantMessageEvent]
noProviderEvents m opts = do
  now <- getCurrentTime
  let detail = "No provider registered for API: " <> renderApi (m ^. #api)
      be = providerUnavailable detail
      msg =
        AssistantMessage
          AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = zeroUsage,
              Msg.stopReason = ErrorReason,
              Msg.errorMessage = Just detail,
              Msg.timestamp = Just now
            }
  ev <-
    Build.minimalEvidence
      m
      opts
      (Build.transportForModel m)
      noThinkingRequested
      (Build.dispatchEnvelope m opts)
      now
      now
      Evidence.CallFailed
      (Just be)
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal ev Nothing ErrorReason msg be)
    ]
