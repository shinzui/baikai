{-# LANGUAGE LambdaCase #-}

-- | Provider wrapping the @claude@ package's Messages API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.AnthropicMessages' handler into the baikai provider
-- registry. After registration, any 'Baikai.Model.Model' whose
-- 'Baikai.Api.api' tag is 'AnthropicMessages' dispatches through
-- this handler.
--
-- The handler resolves 'Baikai.Options.apiKey' when present, falling
-- back to the host-specific env var from
-- 'Baikai.Auth.defaultApiKeyEnvForBaseUrl'. Unknown hosts require an
-- explicit key source.
--
-- EP-3 promotes streaming to the primary entry point. The handler
-- exposes a 'streamly' 'Stream' of 'AssistantMessageEvent' values
-- bridged from a local SSE transport that preserves HTTP status,
-- headers, and body for error classification. Requests start as the
-- SDK's typed 'Claude.V1.Messages.CreateMessage' value, then
-- 'Baikai.Provider.Claude.Shape.streamRequestBody' patches the raw
-- JSON body for tool-schema, @tool_choice@, and tool-cache compat
-- before 'Baikai.Provider.Claude.Sse.claudeSseStreamValueWithHeaders'
-- sends it with cached transport settings and caller headers. The
-- synchronous 'complete' field is derived via 'streamingComplete',
-- so callers that drain the stream get the same fully-assembled
-- 'Response' they had before.
module Baikai.Provider.Claude.Api
  ( register,
    registerWithRegistry,
    claudeMessagesProvider,
    claudeMessagesStream,
    Assembler (..),
    emptyAssembler,
    translate,
  )
where

import Baikai.Api (Api (..))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (zeroCost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError, invalidRequest, providerError)
import Baikai.Message qualified as Msg
import Baikai.Model (Model, anthropicMessagesCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.Claude.Internal.ErrorClass (classifyErrorValue, classifyException)
import Baikai.Provider.Claude.Internal.Request (mapRequest)
import Baikai.Provider.Claude.Shape (streamRequestBody)
import Baikai.Provider.Claude.Sse (claudeSseStreamValueWithHeaders)
import Baikai.Provider.Claude.Transport qualified as Transport
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    registerApiProvider,
    registerApiProviderWith,
  )
import Baikai.StopReason qualified as Stop
import Baikai.Stream (streamingComplete)
import Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    BlockEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    StartPayload (..),
    ThinkingEndPayload (..),
    ToolCallEndPayload (..),
    doneTerminal,
    errorTerminal,
  )
import Baikai.Usage qualified as Usage
import Claude.V1.Messages qualified as Messages
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Network.HTTP.Types.Header (RequestHeaders)
import Servant.Client qualified as Client
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Install the Anthropic Messages handler into the registry.
-- Calling 'register' twice keeps only the second handler — the
-- registry's insert-overwrites semantic.
register :: IO ()
register = registerApiProvider claudeMessagesProvider

-- | First-class Anthropic Messages provider value. Use with
-- 'registerApiProviderWith' or 'newProviderRegistryFrom' for explicit
-- registries.
claudeMessagesProvider :: ApiProvider
claudeMessagesProvider =
  ApiProvider
    { apiTag = AnthropicMessages,
      stream = claudeMessagesStream,
      complete = streamingComplete claudeMessagesStream
    }

-- | Install the Anthropic Messages handler into an explicit registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg =
  registerApiProviderWith
    reg
    claudeMessagesProvider
{-# DEPRECATED registerWithRegistry "use registerApiProviderWith reg claudeMessagesProvider" #-}

-- | Streaming producer for the Anthropic Messages API.
--
-- Forks one worker thread per call that drives
-- the local Claude SSE transport; the worker pushes classified
-- errors or typed 'Messages.MessageStreamEvent' values onto a bounded
-- 'Chan' terminated by 'Nothing'. The returned 'Stream' is a
-- translator: it pulls raw events from the channel and emits zero or
-- more 'AssistantMessageEvent' values per upstream event, terminating
-- with exactly one 'EventDone' or 'EventError'.
--
-- Producer-side exceptions (HTTP failure, decode failure inside the
-- SDK, etc.) are caught with 'try' and re-encoded into an
-- 'EventError' carrying whatever content was already assembled —
-- the masterplan's "partial output is always recoverable" promise.
claudeMessagesStream ::
  Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStream m ctx opts =
  Stream.concatEffect $ do
    setupResult <- trySync (prepareCall m ctx opts)
    let setup = either (Left . exceptionToError) id setupResult
    case setup of
      Left err -> Stream.fromList <$> immediateError err
      Right call -> do
        ch <- newChan :: IO (Chan (Maybe (Either BaikaiError Messages.MessageStreamEvent)))
        tref <- newIORef False
        _ <- forkIO (worker call ch)
        startTime <- getCurrentTime
        let initialState =
              ProducerState
                { chan = ch,
                  pending = [],
                  assembler = emptyAssembler m startTime,
                  finished = False,
                  terminalRef = tref
                }
        pure (Stream.unfoldrM step initialState)

-- | Per-call prepared values, including the shaped JSON request body
-- passed to the local streaming transport.
data ClaudeCall = ClaudeCall
  { clientEnv :: !Client.ClientEnv,
    requestHeaders :: !RequestHeaders,
    timeoutMs :: !(Maybe Int),
    requestBody :: !Aeson.Value
  }
  deriving stock (Generic)

prepareCall ::
  Model -> Context -> Options -> IO (Either BaikaiError ClaudeCall)
prepareCall m ctx opts = do
  case mapRequest m ctx opts of
    Left e -> pure (Left (invalidRequest e))
    Right req -> do
      let url = case m ^. #baseUrl of
            "" -> "https://api.anthropic.com"
            u -> u
          compat = anthropicMessagesCompatFor m
          version = Just "2023-06-01"
      key <- Transport.resolveKey url opts
      env <- Transport.getClientEnvCached url
      let body = streamRequestBody compat ctx opts req
          headers = Transport.requestHeaders key version compat ctx m opts
      pure
        ( Right
            ClaudeCall
              { clientEnv = env,
                requestHeaders = headers,
                timeoutMs = opts ^. #timeoutMs,
                requestBody = body
              }
        )

-- | Worker body: drive the SDK's typed callback, forwarding events
-- onto the channel. Any exception is converted into a synthetic
-- @Error@ raw event so the consumer side can translate it through
-- the normal channel. After the SDK call returns (success or
-- handled failure) we close the channel with 'Nothing'.
worker ::
  ClaudeCall ->
  Chan (Maybe (Either BaikaiError Messages.MessageStreamEvent)) ->
  IO ()
worker call ch = do
  r <-
    trySync $
      Transport.runWithTimeout (call ^. #timeoutMs) $
        claudeSseStreamValueWithHeaders
          (call ^. #clientEnv)
          (call ^. #requestHeaders)
          (call ^. #requestBody)
          (writeChan ch . Just)
  case r of
    Right Nothing -> pure ()
    Right (Just be) -> writeChan ch (Just (Left be))
    Left e -> writeChan ch (Just (Left (exceptionToError e)))
  writeChan ch Nothing

-- | The streaming 'Stream' state.
data ProducerState = ProducerState
  { chan :: !(Chan (Maybe (Either BaikaiError Messages.MessageStreamEvent))),
    pending :: ![AssistantMessageEvent],
    assembler :: !Assembler,
    finished :: !Bool,
    terminalRef :: !(IORef Bool)
  }
  deriving stock (Generic)

step :: ProducerState -> IO (Maybe (AssistantMessageEvent, ProducerState))
step s
  | (e : rest) <- s ^. #pending = do
      writeTerminal s e
      pure
        ( Just
            ( e,
              s
                & #pending .~ rest
                & #finished .~ (s ^. #finished || terminal e)
            )
        )
  | s ^. #finished = pure Nothing
  | otherwise = do
      mRaw <- readChan (s ^. #chan)
      case mRaw of
        Nothing -> do
          alreadyTerminal <- readIORef (s ^. #terminalRef)
          if alreadyTerminal
            then pure Nothing
            else do
              now <- getCurrentTime
              let (ev, ass') = unexpectedEoS now (s ^. #assembler)
              writeTerminal s ev
              pure
                ( Just
                    ( ev,
                      s & #assembler .~ ass' & #finished .~ True
                    )
                )
        Just raw -> do
          now <- getCurrentTime
          let (events, ass') = translate raw (s ^. #assembler) now
          case events of
            [] -> step (s & #assembler .~ ass')
            (e : rest) -> do
              writeTerminal s e
              pure
                ( Just
                    ( e,
                      s
                        & #pending .~ rest
                        & #assembler .~ ass'
                        & #finished .~ (s ^. #finished || terminal e)
                    )
                )

writeTerminal :: ProducerState -> AssistantMessageEvent -> IO ()
writeTerminal s ev
  | terminal ev = writeIORef (s ^. #terminalRef) True
  | otherwise = pure ()

terminal :: AssistantMessageEvent -> Bool
terminal = \case
  EventDone {} -> True
  EventError {} -> True
  _ -> False

-- | The recovery path: channel closed before any terminal event.
unexpectedEoS ::
  UTCTime -> Assembler -> (AssistantMessageEvent, Assembler)
unexpectedEoS now ass =
  let errText = "claude stream ended without message_stop"
      msg = finalMessageOnError ass now errText
   in (EventError (errorTerminal Nothing (ass ^. #responseId) Stop.ErrorReason msg (providerError errText)), ass)

-- | Translation state across one streaming call.
data Assembler = Assembler
  { model :: !Model,
    start :: !UTCTime,
    responseId :: !(Maybe Text),
    closed :: !(IntMap Content.AssistantContent),
    textBuf :: !(IntMap Text),
    thinkBuf :: !(IntMap Text),
    thinkSig :: !(IntMap Text),
    redactedBuf :: !(IntMap Text),
    toolArgsBuf :: !(IntMap Text),
    toolMeta :: !(IntMap (Text, Text)),
    usage :: !Usage.Usage,
    stopReason :: !Stop.StopReason
  }
  deriving stock (Generic)

emptyAssembler :: Model -> UTCTime -> Assembler
emptyAssembler m s =
  Assembler
    { model = m,
      start = s,
      responseId = Nothing,
      closed = IntMap.empty,
      textBuf = IntMap.empty,
      thinkBuf = IntMap.empty,
      thinkSig = IntMap.empty,
      redactedBuf = IntMap.empty,
      toolArgsBuf = IntMap.empty,
      toolMeta = IntMap.empty,
      usage = Usage.zeroUsage,
      stopReason = Stop.Stop
    }

translate ::
  Either BaikaiError Messages.MessageStreamEvent ->
  Assembler ->
  UTCTime ->
  ([AssistantMessageEvent], Assembler)
translate raw ass now = case raw of
  Left be ->
    let msg = finalMessageOnError ass now (be ^. #message)
     in ([EventError (errorTerminal Nothing (ass ^. #responseId) Stop.ErrorReason msg be)], ass)
  Right ev -> translateEvent ev ass now

translateEvent ::
  Messages.MessageStreamEvent ->
  Assembler ->
  UTCTime ->
  ([AssistantMessageEvent], Assembler)
translateEvent raw ass now = case raw of
  Messages.Ping -> ([], ass)
  Messages.Message_Start {Messages.message = mr} ->
    let usage0 = anthroUsageToBaikai (mr ^. #usage)
        ass' = ass & #responseId .~ Just (mr ^. #id) & #usage .~ usage0
        skeleton = skeletonMessage ass' now
     in ([EventStart StartPayload {partial = skeleton, responseId = Just (mr ^. #id)}], ass')
  Messages.Content_Block_Start {Messages.index = idx, Messages.content_block = block} ->
    handleBlockStart (fromIntegral idx) block ass
  Messages.Content_Block_Delta {Messages.index = idx, Messages.delta = d} ->
    handleBlockDelta (fromIntegral idx) d ass
  Messages.Content_Block_Stop {Messages.index = idx} ->
    handleBlockStop (fromIntegral idx) ass
  Messages.Message_Delta {Messages.message_delta = md, Messages.usage = su} ->
    let stopR = mapStopReason (md ^. #stop_reason)
        u = ass ^. #usage
        outputTokensFinal = fromMaybe (u ^. #outputTokens) (Just (su ^. #output_tokens))
        u' =
          u
            & #outputTokens .~ outputTokensFinal
            & #totalTokens
              .~ ((u ^. #inputTokens) + outputTokensFinal + (u ^. #cacheReadTokens) + (u ^. #cacheWriteTokens))
     in ([], ass & #stopReason .~ stopR & #usage .~ u')
  Messages.Message_Stop ->
    let reason = ass ^. #stopReason
        refusal = providerError "Anthropic refused to generate a response (stop_reason=refusal)"
        msg =
          if reason == Stop.ErrorReason
            then finalMessageOnError ass now (refusal ^. #message)
            else finalMessage ass now
        terminalEvent =
          if reason == Stop.ErrorReason
            then EventError (errorTerminal Nothing (ass ^. #responseId) reason msg refusal)
            else EventDone (doneTerminal Nothing (ass ^. #responseId) reason msg)
     in ([terminalEvent], ass)
  Messages.Error {Messages.error = errVal} ->
    let errText = renderAnthropicError errVal
        mErr = classifyErrorValue errVal
        msg = finalMessageOnError ass now errText
        errInfo = fromMaybe (providerError errText) mErr
     in ([EventError (errorTerminal Nothing (ass ^. #responseId) Stop.ErrorReason msg errInfo)], ass)

handleBlockStart ::
  Int ->
  Messages.ContentBlock ->
  Assembler ->
  ([AssistantMessageEvent], Assembler)
handleBlockStart i block ass = case block of
  Messages.ContentBlock_Text {} ->
    ( [TextStart IndexPayload {contentIndex = i}],
      ass & #textBuf %~ IntMap.insert i Text.empty
    )
  Messages.ContentBlock_Thinking {} ->
    ( [ThinkingStart IndexPayload {contentIndex = i}],
      ass & #thinkBuf %~ IntMap.insert i Text.empty
    )
  Messages.ContentBlock_Redacted_Thinking {Messages.data_ = payload} ->
    ( [ThinkingStart IndexPayload {contentIndex = i}],
      ass & #redactedBuf %~ IntMap.insert i payload
    )
  Messages.ContentBlock_Tool_Use {Messages.id = tid, Messages.name = tn} ->
    ( [ToolCallStart IndexPayload {contentIndex = i}],
      ass
        & #toolArgsBuf %~ IntMap.insert i Text.empty
        & #toolMeta %~ IntMap.insert i (tid, tn)
    )
  _ ->
    -- Server-tool, code-execution-tool, unknown — pass-through with no events.
    ([], ass)

handleBlockDelta ::
  Int ->
  Messages.ContentBlockDelta ->
  Assembler ->
  ([AssistantMessageEvent], Assembler)
handleBlockDelta i d ass = case d of
  Messages.Delta_Text_Delta {Messages.text = t} ->
    if IntMap.member i (ass ^. #textBuf)
      then
        ( [TextDelta DeltaPayload {contentIndex = i, delta = t}],
          ass & #textBuf %~ IntMap.adjust (<> t) i
        )
      else ([], ass)
  Messages.Delta_Thinking_Delta {Messages.thinking = t} ->
    if IntMap.member i (ass ^. #thinkBuf)
      then
        ( [ThinkingDelta DeltaPayload {contentIndex = i, delta = t}],
          ass & #thinkBuf %~ IntMap.adjust (<> t) i
        )
      else ([], ass)
  Messages.Delta_Signature_Delta {Messages.signature = sig} ->
    -- Signatures are tail-end metadata on thinking blocks; they
    -- attach to the ThinkingEnd event's content build, not a public
    -- delta event.
    if IntMap.member i (ass ^. #thinkBuf)
      then
        ( [],
          ass & #thinkSig %~ IntMap.insertWith (\new old -> old <> new) i sig
        )
      else ([], ass)
  Messages.Delta_Input_Json_Delta {Messages.partial_json = j} ->
    if IntMap.member i (ass ^. #toolArgsBuf)
      then
        ( [ToolCallDelta DeltaPayload {contentIndex = i, delta = j}],
          ass & #toolArgsBuf %~ IntMap.adjust (<> j) i
        )
      else ([], ass)

handleBlockStop ::
  Int -> Assembler -> ([AssistantMessageEvent], Assembler)
handleBlockStop i ass
  | Just body <- IntMap.lookup i (ass ^. #textBuf) =
      let block = Content.AssistantText (Content.TextContent body)
       in ( [TextEnd BlockEndPayload {contentIndex = i, content = body}],
            ass
              & #closed %~ IntMap.insert i block
              & #textBuf %~ IntMap.delete i
          )
  | Just payload <- IntMap.lookup i (ass ^. #redactedBuf) =
      let thinkingContent =
            Content.ThinkingContent
              { Content.thinking = payload,
                Content.signature = Nothing,
                Content.redacted = True
              }
          block = Content.AssistantThinking thinkingContent
       in ( [ThinkingEnd ThinkingEndPayload {contentIndex = i, content = thinkingContent}],
            ass
              & #closed %~ IntMap.insert i block
              & #redactedBuf %~ IntMap.delete i
          )
  | Just body <- IntMap.lookup i (ass ^. #thinkBuf) =
      let sig = IntMap.lookup i (ass ^. #thinkSig)
          thinkingContent =
            Content.ThinkingContent
              { Content.thinking = body,
                Content.signature = if maybe True Text.null sig then Nothing else sig,
                Content.redacted = False
              }
          block = Content.AssistantThinking thinkingContent
       in ( [ThinkingEnd ThinkingEndPayload {contentIndex = i, content = thinkingContent}],
            ass
              & #closed %~ IntMap.insert i block
              & #thinkBuf %~ IntMap.delete i
              & #thinkSig %~ IntMap.delete i
          )
  | Just argsText <- IntMap.lookup i (ass ^. #toolArgsBuf) =
      let (tid, tn) =
            -- A tool args buffer is opened together with metadata in
            -- handleBlockStart; the fallback is defensive only.
            fromMaybe ("", "") (IntMap.lookup i (ass ^. #toolMeta))
          decoded :: Value
          decoded = case Aeson.eitherDecodeStrict (Text.encodeUtf8 argsText) of
            Right v -> v
            Left _ ->
              -- Anthropic sometimes opens a tool_use block with an
              -- empty input that never streams any delta. Fall back
              -- to an empty object so the resulting ToolCall is
              -- well-formed.
              Aeson.Object mempty
          tc =
            Content.ToolCall
              { Content.id_ = tid,
                Content.name = tn,
                Content.arguments = decoded
              }
          block = Content.AssistantToolCall tc
       in ( [ToolCallEnd ToolCallEndPayload {contentIndex = i, toolCall = tc}],
            ass
              & #closed %~ IntMap.insert i block
              & #toolArgsBuf %~ IntMap.delete i
              & #toolMeta %~ IntMap.delete i
          )
  | otherwise = ([], ass)

-- | The 'EventStart' message skeleton (empty content; usage/etc.
-- carried for downstream consumers that want metadata up front).
skeletonMessage :: Assembler -> UTCTime -> Msg.Message
skeletonMessage ass _now =
  Msg.AssistantMessage
    Msg.AssistantPayload
      { Msg.content = Vector.empty,
        Msg.usage = ass ^. #usage,
        Msg.stopReason = Stop.Stop,
        Msg.errorMessage = Nothing,
        Msg.timestamp = Just (ass ^. #start)
      }

finalMessage :: Assembler -> UTCTime -> Msg.Message
finalMessage ass now =
  let blocks = blocksInOrder ass
      m = ass ^. #model
      usageBare = ass ^. #usage
      computed = Pricing.computeCost m usageBare
      usage' = usageBare & #cost .~ computed
   in Msg.AssistantMessage
        Msg.AssistantPayload
          { Msg.content = blocks,
            Msg.usage = usage',
            Msg.stopReason = ass ^. #stopReason,
            Msg.errorMessage = Nothing,
            Msg.timestamp = Just now
          }

finalMessageOnError :: Assembler -> UTCTime -> Text -> Msg.Message
finalMessageOnError ass now reason =
  let blocks = blocksInOrder ass
      m = ass ^. #model
      usageBare = ass ^. #usage
      computed = Pricing.computeCost m usageBare
      usage' = usageBare & #cost .~ computed
   in Msg.AssistantMessage
        Msg.AssistantPayload
          { Msg.content = blocks,
            Msg.usage = usage',
            Msg.stopReason = Stop.ErrorReason,
            Msg.errorMessage = Just reason,
            Msg.timestamp = Just now
          }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (ass ^. #closed))

-- | The immediate "request invalid" stream — emitted when
-- 'mapRequest' fails or 'prepareCall' is otherwise unable to build
-- a valid SDK request.
immediateError :: BaikaiError -> IO [AssistantMessageEvent]
immediateError err = do
  now <- getCurrentTime
  let errText = err ^. #message
  let msg =
        Msg.AssistantMessage
          Msg.AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = Usage.zeroUsage,
              Msg.stopReason = Stop.ErrorReason,
              Msg.errorMessage = Just errText,
              Msg.timestamp = Just now
            }
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal Nothing Nothing Stop.ErrorReason msg err)
    ]

trySync :: IO a -> IO (Either SomeException a)
trySync action = do
  r <- try action
  case r of
    Left e
      | Just (SomeAsyncException _) <- (fromException e :: Maybe SomeAsyncException) ->
          throwIO e
      | otherwise -> pure (Left e)
    Right a -> pure (Right a)

exceptionToError :: SomeException -> BaikaiError
exceptionToError e = fromMaybe (classifyException e) (fromException e)

renderAnthropicError :: Value -> Text
renderAnthropicError v = case v of
  Aeson.String t -> t
  _ -> Text.decodeUtf8 (BSL.toStrict (Aeson.encode v))

-- | Map the Anthropic streaming 'Message_Start.message.usage' value
-- into baikai's 'Usage' shape. Cache-related counters are populated
-- where present; cost is left at zero (the terminal event
-- recomputes it).
anthroUsageToBaikai :: Messages.Usage -> Usage.Usage
anthroUsageToBaikai u =
  let i = u ^. #input_tokens
      o = u ^. #output_tokens
      cr = fromMaybe 0 (u ^. #cache_read_input_tokens)
      cw = fromMaybe 0 (u ^. #cache_creation_input_tokens)
   in Usage.Usage
        { Usage.inputTokens = i,
          Usage.outputTokens = o,
          Usage.cacheReadTokens = cr,
          Usage.cacheWriteTokens = cw,
          Usage.reasoningTokens = Nothing,
          Usage.totalTokens = i + o + cr + cw,
          Usage.cost = zeroCost
        }

mapStopReason :: Maybe Messages.StopReason -> Stop.StopReason
mapStopReason = \case
  Just Messages.End_Turn -> Stop.Stop
  Just Messages.Max_Tokens -> Stop.Length
  Just Messages.Stop_Sequence -> Stop.Stop
  Just Messages.Tool_Use -> Stop.ToolUse
  Just Messages.Refusal -> Stop.ErrorReason
  Just Messages.Model_Context_Window_Exceeded -> Stop.Length
  Nothing -> Stop.Stop
