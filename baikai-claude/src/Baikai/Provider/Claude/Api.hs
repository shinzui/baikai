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
-- back to the @ANTHROPIC_API_KEY@ env var via
-- 'Baikai.Auth.resolveApiKey'.
--
-- EP-3 promotes streaming to the primary entry point. The handler
-- exposes a 'streamly' 'Stream' of 'AssistantMessageEvent' values
-- bridged from the upstream SDK's typed 'createMessageStreamTyped'
-- callback. The synchronous 'complete' field is derived via
-- 'streamingComplete', so callers that drain the stream get the
-- same fully-assembled 'Response' they had before.
module Baikai.Provider.Claude.Api
  ( register,
    registerWithRegistry,
    claudeMessagesStream,
  )
where

import Baikai.Api (Api (..))
import Baikai.Auth qualified as Auth
import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat (AnthropicMessagesCompat (..))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (_Cost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Message qualified as Msg
import Baikai.Model (Model, anthropicMessagesCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    globalProviderRegistry,
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
    TerminalPayload (..),
    ToolCallEndPayload (..),
  )
import Baikai.ThinkingLevel (ThinkingLevel, thinkingTokenBudget)
import Baikai.Tool qualified as Tool
import Baikai.Usage qualified as Usage
import Claude.V1 qualified as Claude
import Claude.V1.Messages qualified as Messages
import Claude.V1.Tool qualified as ClaudeTool
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (SomeException, displayException, try)
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAlphaNum, isAscii)
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
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Install the Anthropic Messages handler into the registry.
-- Calling 'register' twice keeps only the second handler — the
-- registry's insert-overwrites semantic.
register :: IO ()
register = registerWithRegistry globalProviderRegistry

-- | Install the Anthropic Messages handler into an explicit registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg =
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = AnthropicMessages,
        stream = claudeMessagesStream,
        complete = streamingComplete claudeMessagesStream
      }

-- | Streaming producer for the Anthropic Messages API.
--
-- Forks one worker thread per call that drives
-- 'Claude.createMessageStreamTyped'; the worker pushes typed
-- 'Messages.MessageStreamEvent' values onto a bounded 'Chan'
-- terminated by 'Nothing'. The returned 'Stream' is a translator:
-- it pulls raw events from the channel and emits zero or more
-- 'AssistantMessageEvent' values per upstream event, terminating
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
    setup <- prepareCall m ctx opts
    case setup of
      Left err -> pure (Stream.fromEffect (immediateError err))
      Right call -> do
        ch <- newChan :: IO (Chan (Maybe Messages.MessageStreamEvent))
        tref <- newIORef False
        _ <- forkIO (worker call ch tref)
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

-- | Per-call prepared values: the typed SDK request, plus the
-- methods record to invoke the streaming endpoint.
data ClaudeCall = ClaudeCall
  { methods :: !Claude.Methods,
    request :: !Messages.CreateMessage
  }
  deriving stock (Generic)

prepareCall ::
  Model -> Context -> Options -> IO (Either Text ClaudeCall)
prepareCall m ctx opts = do
  case mapRequest m ctx opts of
    Left e -> pure (Left e)
    Right req -> do
      key <- resolveKey opts
      let url = case m ^. #baseUrl of
            "" -> "https://api.anthropic.com"
            u -> u
      env <- Claude.getClientEnv url
      let mtds = Claude.makeMethods env key (Just "2023-06-01")
      pure (Right ClaudeCall {methods = mtds, request = req})

resolveKey :: Options -> IO Text
resolveKey opts = case opts ^. #apiKey of
  Just source -> Auth.resolveApiKey source
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv "ANTHROPIC_API_KEY")

-- | Worker body: drive the SDK's typed callback, forwarding events
-- onto the channel. Any exception is converted into a synthetic
-- @Error@ raw event so the consumer side can translate it through
-- the normal channel. After the SDK call returns (success or
-- handled failure) we close the channel with 'Nothing'.
worker ::
  ClaudeCall ->
  Chan (Maybe Messages.MessageStreamEvent) ->
  IORef Bool ->
  IO ()
worker call ch _terminalRef = do
  let Claude.Methods {Claude.createMessageStreamTyped = stream'} = call ^. #methods
  r <-
    try @SomeException $
      stream' (call ^. #request) $ \case
        Left errText -> writeChan ch (Just (errorEvent errText))
        Right ev -> writeChan ch (Just ev)
  case r of
    Right () -> pure ()
    Left e -> writeChan ch (Just (errorEvent (Text.pack (displayException e))))
  writeChan ch Nothing
  where
    errorEvent :: Text -> Messages.MessageStreamEvent
    errorEvent t = Messages.Error {Messages.error = Aeson.String t}

-- | The streaming 'Stream' state.
data ProducerState = ProducerState
  { chan :: !(Chan (Maybe Messages.MessageStreamEvent)),
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
unexpectedEoS :: UTCTime -> Assembler -> (AssistantMessageEvent, Assembler)
unexpectedEoS now ass =
  let msg =
        finalMessageOnError
          ass
          now
          "claude stream ended without message_stop"
   in (EventError TerminalPayload {reason = Stop.ErrorReason, message = msg}, ass)

-- | Translation state across one streaming call.
data Assembler = Assembler
  { model :: !Model,
    start :: !UTCTime,
    responseId :: !(Maybe Text),
    closed :: !(IntMap Content.AssistantContent),
    textBuf :: !(IntMap Text),
    thinkBuf :: !(IntMap Text),
    thinkSig :: !(IntMap Text),
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
      toolArgsBuf = IntMap.empty,
      toolMeta = IntMap.empty,
      usage = Usage._Usage,
      stopReason = Stop.Stop
    }

translate ::
  Messages.MessageStreamEvent ->
  Assembler ->
  UTCTime ->
  ([AssistantMessageEvent], Assembler)
translate raw ass now = case raw of
  Messages.Ping -> ([], ass)
  Messages.Message_Start {Messages.message = mr} ->
    let usage0 = anthroUsageToBaikai (mr ^. #usage)
        ass' = ass & #responseId .~ Just (mr ^. #id) & #usage .~ usage0
        skeleton = skeletonMessage ass' now
     in ([EventStart StartPayload {partial = skeleton}], ass')
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
    let msg = finalMessage ass now
     in ([EventDone TerminalPayload {reason = ass ^. #stopReason, message = msg}], ass)
  Messages.Error {Messages.error = errVal} ->
    let errText = renderAnthropicError errVal
        msg = finalMessageOnError ass now errText
     in ([EventError TerminalPayload {reason = Stop.ErrorReason, message = msg}], ass)

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
  Messages.ContentBlock_Redacted_Thinking {} ->
    ( [ThinkingStart IndexPayload {contentIndex = i}],
      ass & #thinkBuf %~ IntMap.insert i Text.empty
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
    ( [TextDelta DeltaPayload {contentIndex = i, delta = t}],
      ass & #textBuf %~ IntMap.insertWith (\new old -> old <> new) i t
    )
  Messages.Delta_Thinking_Delta {Messages.thinking = t} ->
    ( [ThinkingDelta DeltaPayload {contentIndex = i, delta = t}],
      ass & #thinkBuf %~ IntMap.insertWith (\new old -> old <> new) i t
    )
  Messages.Delta_Signature_Delta {Messages.signature = sig} ->
    -- Signatures are tail-end metadata on thinking blocks; they
    -- attach to the ThinkingEnd event's content build, not a public
    -- delta event.
    ( [],
      ass & #thinkSig %~ IntMap.insertWith (\new old -> old <> new) i sig
    )
  Messages.Delta_Input_Json_Delta {Messages.partial_json = j} ->
    ( [ToolCallDelta DeltaPayload {contentIndex = i, delta = j}],
      ass & #toolArgsBuf %~ IntMap.insertWith (\new old -> old <> new) i j
    )

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
  | Just body <- IntMap.lookup i (ass ^. #thinkBuf) =
      let sig = IntMap.lookup i (ass ^. #thinkSig)
          block =
            Content.AssistantThinking
              Content.ThinkingContent
                { Content.thinking = body,
                  Content.signature = if maybe True Text.null sig then Nothing else sig,
                  Content.redacted = False
                }
       in ( [ThinkingEnd BlockEndPayload {contentIndex = i, content = body}],
            ass
              & #closed %~ IntMap.insert i block
              & #thinkBuf %~ IntMap.delete i
              & #thinkSig %~ IntMap.delete i
          )
  | Just argsText <- IntMap.lookup i (ass ^. #toolArgsBuf) =
      let (tid, tn) = fromMaybe ("", "") (IntMap.lookup i (ass ^. #toolMeta))
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
        Msg.timestamp = ass ^. #start
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
            Msg.timestamp = now
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
            Msg.timestamp = now
          }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (ass ^. #closed))

-- | The immediate "request invalid" stream — emitted when
-- 'mapRequest' fails or 'prepareCall' is otherwise unable to build
-- a valid SDK request.
immediateError :: Text -> IO AssistantMessageEvent
immediateError errText = do
  now <- getCurrentTime
  let msg =
        Msg.AssistantMessage
          Msg.AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = Usage._Usage,
              Msg.stopReason = Stop.ErrorReason,
              Msg.errorMessage = Just errText,
              Msg.timestamp = now
            }
  pure (EventError TerminalPayload {reason = Stop.ErrorReason, message = msg})

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
          Usage.cost = _Cost
        }

-- ============================================================
-- Request mapping (preserved from EP-2 with minor refactoring to
-- accept Context/Options directly).
-- ============================================================

mapRequest :: Model -> Context -> Options -> Either Text Messages.CreateMessage
mapRequest m ctx opts = do
  msgs <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = anthropicMessagesCompatFor m
      baseTokens = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
      thinkingField = computeThinking m (opts ^. #thinking)
      -- When extended thinking is enabled, Anthropic requires that
      -- max_tokens be large enough to cover both the visible
      -- response and the thinking budget. Bump the cap by the
      -- requested budget so callers do not have to do the math.
      maxTokensField_ = case thinkingField of
        Just (Messages.ThinkingEnabled budget) -> baseTokens + budget
        _ -> baseTokens
      cacheControlField = computeCacheControl compat (opts ^. #cacheRetention)
      -- `ToolChoiceNone` is not a first-class Anthropic value; the
      -- standard way to disable tool use on a per-call basis is to
      -- omit the @tools@ field entirely. Suppress both fields when
      -- the caller asked for `None`.
      suppressTools = case opts ^. #toolChoice of
        Just Tool.ToolChoiceNone -> True
        _ -> False
      toolsVec = if suppressTools then Vector.empty else ctx ^. #tools
      toolsField =
        if Vector.null toolsVec
          then Nothing
          else Just (Vector.map (mkAnthropicTool compat) toolsVec)
      toolChoiceField = case opts ^. #toolChoice of
        Just Tool.ToolChoiceNone -> Nothing
        Just tc -> Just (mkAnthropicToolChoice tc)
        Nothing -> Nothing
  pure
    Messages._CreateMessage
      { Messages.model = m ^. #modelId,
        Messages.messages = Vector.fromList msgs,
        Messages.max_tokens = maxTokensField_,
        Messages.system = fmap Messages.SystemPromptText (ctx ^. #systemPrompt),
        Messages.temperature = opts ^. #temperature,
        Messages.tools = toolsField,
        Messages.tool_choice = toolChoiceField,
        Messages.cache_control = cacheControlField,
        Messages.thinking = thinkingField
      }

-- | Translate the call-time 'Baikai.CacheRetention' preference into
-- the Anthropic SDK's @cache_control@ shape.
--
-- 'CacheRetentionNone' (and 'Nothing') turn the field off entirely.
-- 'CacheRetentionShort' uses the ephemeral marker with no TTL (the
-- provider default). 'CacheRetentionLong' asks for the @"1h"@ TTL
-- when the host advertises 'supportsLongCacheRetention'; otherwise it
-- transparently downgrades to short retention.
computeCacheControl ::
  AnthropicMessagesCompat ->
  Maybe CacheRetention ->
  Maybe Messages.CacheControl
computeCacheControl _ Nothing = Nothing
computeCacheControl _ (Just CacheRetentionNone) = Nothing
computeCacheControl _ (Just CacheRetentionShort) =
  Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}
computeCacheControl compat (Just CacheRetentionLong)
  | supportsLongCacheRetention compat =
      Just
        Messages.CacheControl
          { Messages.type_ = "ephemeral",
            Messages.ttl = Just (Messages.CacheTTLDuration "1h")
          }
  | otherwise =
      Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}

-- | Translate the call-time 'Baikai.ThinkingLevel' preference into
-- the Anthropic SDK's 'Messages.Thinking' shape.
--
-- We only enable the thinking field when the chosen model advertises
-- 'reasoning' support — sending a thinking config to a non-reasoning
-- model is a 400 error from Anthropic, not a silent no-op. Callers
-- that asked for thinking on a non-reasoning model get the request
-- shaped without it (the request still succeeds and returns a normal
-- response).
computeThinking :: Model -> Maybe ThinkingLevel -> Maybe Messages.Thinking
computeThinking _ Nothing = Nothing
computeThinking m (Just lvl)
  | m ^. #reasoning =
      Just Messages.ThinkingEnabled {Messages.budget_tokens = thinkingTokenBudget lvl}
  | otherwise = Nothing

-- | Map a baikai 'Tool.Tool' into the upstream Anthropic
-- 'ClaudeTool.ToolDefinition'. The JSON Schema is passed through
-- verbatim; 'ClaudeTool.functionTool' extracts @properties@ and
-- @required@ off the top-level schema if present.
--
-- The compat record is threaded through so future revisions can
-- apply per-tool @cache_control@ markers (when
-- 'supportsCacheControlOnTools' is True) or per-tool eager input
-- streaming flags. EP-5 ships the parameter at its default, leaving
-- the upstream tool definition without cache markers.
mkAnthropicTool :: AnthropicMessagesCompat -> Tool.Tool -> ClaudeTool.ToolDefinition
mkAnthropicTool _compat t =
  ClaudeTool.inlineTool
    ( ClaudeTool.functionTool
        (Tool.name t)
        (Just (Tool.description t))
        (Tool.parameters t)
    )

-- | Map a baikai 'Tool.ToolChoice' into the upstream Anthropic
-- 'ClaudeTool.ToolChoice'. 'Tool.ToolChoiceNone' is handled at the
-- call site by suppressing the @tools@ field — it never reaches
-- this function. 'Tool.ToolChoiceRequired' maps to Anthropic's
-- @any@ which is the closest equivalent ("must call some tool").
mkAnthropicToolChoice :: Tool.ToolChoice -> ClaudeTool.ToolChoice
mkAnthropicToolChoice = \case
  Tool.ToolChoiceAuto -> ClaudeTool.ToolChoice_Auto
  Tool.ToolChoiceRequired -> ClaudeTool.ToolChoice_Any
  Tool.ToolChoiceSpecific n -> ClaudeTool.ToolChoice_Tool {ClaudeTool.name = n}
  -- Unreachable: ToolChoiceNone is suppressed in 'mapRequest'.
  Tool.ToolChoiceNone -> ClaudeTool.ToolChoice_Auto

-- | Anthropic enforces @[a-zA-Z0-9_-]+@ on tool-call ids and caps
-- their length at 64 characters. Callers may have used any
-- naming convention, so the provider boundary normalizes here
-- whenever an id is round-tripped back to Anthropic — both on
-- assistant turn replay ('Content_Tool_Use') and on tool-result
-- messages ('Content_Tool_Result').
normalizeToolCallId :: Text -> Text
normalizeToolCallId =
  Text.take 64 . Text.map sanitise
  where
    sanitise c
      | isAscii c && isAlphaNum c = c
      | c == '_' || c == '-' = c
      | otherwise = '_'

mapMessage :: Msg.Message -> Either Text Messages.Message
mapMessage = \case
  Msg.UserMessage Msg.UserPayload {Msg.content = uc} ->
    Right
      Messages.Message
        { Messages.role = Messages.User,
          Messages.content = Vector.mapMaybe userContentToBlock uc,
          Messages.cache_control = Nothing
        }
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
    Right
      Messages.Message
        { Messages.role = Messages.Assistant,
          Messages.content = Vector.mapMaybe assistantContentToBlock ac,
          Messages.cache_control = Nothing
        }
  Msg.ToolResultMessage
    Msg.ToolResultPayload
      { Msg.toolCallId = tid,
        Msg.content = trc,
        Msg.isError = err
      } ->
      case concatToolResultText trc of
        Left unsupported -> Left unsupported
        Right body ->
          Right
            Messages.Message
              { Messages.role = Messages.User,
                Messages.content =
                  Vector.singleton
                    Messages.Content_Tool_Result
                      { Messages.tool_use_id = normalizeToolCallId tid,
                        Messages.content = nonEmpty body,
                        Messages.is_error = Just err
                      },
                Messages.cache_control = Nothing
              }

userContentToBlock :: Content.UserContent -> Maybe Messages.Content
userContentToBlock = \case
  Content.UserText (Content.TextContent t) ->
    Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.UserImage img ->
    Just
      Messages.Content_Image
        { Messages.source =
            Messages.ImageSource
              { Messages.type_ = "base64",
                Messages.media_type = Content.mimeType img,
                Messages.data_ = Text.decodeUtf8 (Base64.encode (Content.imageData img))
              },
          Messages.cache_control = Nothing
        }

assistantContentToBlock :: Content.AssistantContent -> Maybe Messages.Content
assistantContentToBlock = \case
  Content.AssistantText (Content.TextContent t) ->
    Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.AssistantThinking th ->
    Just
      Messages.Content_Thinking
        { Messages.thinking = Content.thinking th,
          Messages.signature = fromMaybe "" (Content.signature th)
        }
  Content.AssistantToolCall tc ->
    Just
      Messages.Content_Tool_Use
        { Messages.id = normalizeToolCallId (Content.id_ tc),
          Messages.name = Content.name tc,
          Messages.input = Content.arguments tc,
          Messages.caller = Nothing
        }

concatToolResultText :: Vector Content.ToolResultContent -> Either Text Text
concatToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "Anthropic Messages cannot encode ToolResultImage blocks in tool-result messages"

nonEmpty :: Text -> Maybe Text
nonEmpty t
  | Text.null t = Nothing
  | otherwise = Just t

mapStopReason :: Maybe Messages.StopReason -> Stop.StopReason
mapStopReason = \case
  Just Messages.End_Turn -> Stop.Stop
  Just Messages.Max_Tokens -> Stop.Length
  Just Messages.Stop_Sequence -> Stop.Stop
  Just Messages.Tool_Use -> Stop.ToolUse
  Just Messages.Refusal -> Stop.ErrorReason
  Just Messages.Model_Context_Window_Exceeded -> Stop.Length
  Nothing -> Stop.Stop
