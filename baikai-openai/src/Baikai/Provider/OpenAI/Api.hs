{-# LANGUAGE LambdaCase #-}

-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAIChatCompletions' handler into the baikai
-- provider registry. After registration, any 'Baikai.Model.Model'
-- whose 'Baikai.Api.api' tag is 'OpenAIChatCompletions' dispatches
-- through this handler.
--
-- The handler reads its API key from 'Baikai.Options.apiKey' when
-- present, falling back to the @OPENAI_API_KEY@ env var via
-- 'Baikai.Auth.resolveApiKey'.
--
-- EP-3 promotes streaming to the primary entry point. The handler
-- exposes a 'streamly' 'Stream' of 'AssistantMessageEvent' values
-- bridged from the upstream SDK's raw
-- 'createChatCompletionStream' callback. We deliberately bypass
-- the typed variant because the typed @ChatCompletionChunk@
-- requires @id@ + @function.name@ on every tool-call delta — fields
-- that OpenAI omits on partial-argument continuation chunks — so a
-- tool-using stream fails to parse end-to-end. Parsing the raw
-- 'Aeson.Value' chunk manually lets us tolerate missing fields the
-- way the upstream wire protocol intends.
--
-- The synchronous 'complete' field is derived via
-- 'streamingComplete', so callers that drain the stream get the
-- same fully-assembled 'Response' they had before.
module Baikai.Provider.OpenAI.Api
  ( register
  , openaiChatStream
  ) where

import Baikai.Api (Api (..))
import Baikai.Auth qualified as Auth
import Baikai.Compat
  ( OpenAICompletionsCompat (..)
  , ThinkingFormat (..)
  )
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (_Cost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Message qualified as Msg
import Baikai.Model (Model, openaiCompletionsCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.Registry (ApiProvider (..), registerApiProvider)
import Baikai.StopReason qualified as Stop
import Baikai.Stream (streamingComplete)
import Baikai.Stream.Event (AssistantMessageEvent (..))
import Baikai.ThinkingLevel
  ( ThinkingLevel (..)
  )
import Baikai.Tool qualified as Tool
import Baikai.Usage qualified as Usage
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (SomeException, displayException, try)
import Control.Lens ((^.))
import Data.Aeson (Value (..), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Base64 qualified as Base64
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
import Numeric.Natural (Natural)
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as OpenAIModels
import OpenAI.V1.Tool qualified as OpenAITool
import OpenAI.V1.ToolCall qualified as ToolCall
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Install the OpenAI Chat Completions handler into the registry.
register :: IO ()
register =
  registerApiProvider
    ApiProvider
      { apiTag = OpenAIChatCompletions
      , stream = openaiChatStream
      , complete = streamingComplete openaiChatStream
      }

-- | Streaming producer for the OpenAI Chat Completions API.
--
-- Forks one worker thread per call that drives
-- 'OpenAI.createChatCompletionStream' (the raw 'Aeson.Value'
-- variant, not the typed one — see module docs for why). The
-- worker pushes raw chunk values onto a 'Chan' terminated by
-- 'Nothing'; the consumer translates each chunk into zero or more
-- baikai 'AssistantMessageEvent' values and terminates with exactly
-- one 'EventDone' or 'EventError'.
openaiChatStream
  :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiChatStream m ctx opts =
  Stream.concatEffect $ do
    setup <- prepareCall m ctx opts
    case setup of
      Left err -> pure (Stream.fromEffect (immediateError err))
      Right call -> do
        chan <- newChan :: IO (Chan (Maybe RawChunk))
        terminalRef <- newIORef False
        _ <- forkIO (worker call chan)
        startTime <- getCurrentTime
        let initialState =
              ProducerState
                { psChan = chan
                , psPending = [EventStart {partial = skeletonStart m startTime}]
                , psAssembler = emptyAssembler m startTime
                , psFinished = False
                , psTerminalRef = terminalRef
                }
        pure (Stream.unfoldrM step initialState)

skeletonStart :: Model -> UTCTime -> Msg.Message
skeletonStart _m start =
  Msg.AssistantMessage
    { Msg.assistantContent = Vector.empty
    , Msg.usage = Usage._Usage
    , Msg.stopReason = Stop.Stop
    , Msg.errorMessage = Nothing
    , Msg.timestamp = start
    }

-- | Per-call prepared values.
data OpenAICall = OpenAICall
  { ocMethods :: !OpenAI.Methods
  , ocRequest :: !Chat.CreateChatCompletion
  }

prepareCall :: Model -> Context -> Options -> IO (Either Text OpenAICall)
prepareCall m ctx opts = case mapRequest m ctx opts of
  Left e -> pure (Left e)
  Right req -> do
    key <- resolveKey opts
    let url = case m ^. #baseUrl of
          "" -> "https://api.openai.com"
          u -> u
    env <- OpenAI.getClientEnv url
    let methods = OpenAI.makeMethods env key Nothing Nothing
        req' =
          req
            { Chat.stream = Just True
            , Chat.stream_options =
                Just
                  Chat._ChatCompletionStreamOptions
                    {Chat.include_usage = Just True}
            }
    pure (Right OpenAICall {ocMethods = methods, ocRequest = req'})

resolveKey :: Options -> IO Text
resolveKey opts = case opts ^. #apiKey of
  Just k -> pure k
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv "OPENAI_API_KEY")

-- | A loose summary of one streamed chunk. The raw 'Aeson.Value' is
-- pre-parsed into the fields we care about; unknown fields are
-- ignored. Missing fields are 'Nothing' (we tolerate partial
-- tool-call deltas).
data RawChunk = RawChunk
  { rcContentDelta :: !(Maybe Text)
  , rcFinishReason :: !(Maybe Text)
  , rcToolDeltas :: ![RawToolDelta]
  , rcUsage :: !(Maybe RawUsage)
  , rcError :: !(Maybe Text)
  }
  deriving stock (Show)

data RawToolDelta = RawToolDelta
  { rtdIndex :: !Int
  , rtdId :: !(Maybe Text)
  , rtdName :: !(Maybe Text)
  , rtdArgs :: !(Maybe Text)
  }
  deriving stock (Show)

data RawUsage = RawUsage
  { ruInputTokens :: !Natural
  , ruOutputTokens :: !Natural
  , ruCacheReadTokens :: !Natural
  , ruReasoningTokens :: !(Maybe Natural)
  }
  deriving stock (Show)

worker
  :: OpenAICall -> Chan (Maybe RawChunk) -> IO ()
worker call chan = do
  let OpenAI.Methods {OpenAI.createChatCompletionStream = stream'} = ocMethods call
  r <-
    try @SomeException $
      stream' (ocRequest call) $ \case
        Left errText -> writeChan chan (Just (errorChunk errText))
        Right val -> case parseChunk val of
          Left err -> writeChan chan (Just (errorChunk (Text.pack err)))
          Right chunk -> writeChan chan (Just chunk)
  case r of
    Right () -> pure ()
    Left e ->
      writeChan chan (Just (errorChunk (Text.pack (displayException e))))
  writeChan chan Nothing

errorChunk :: Text -> RawChunk
errorChunk t =
  RawChunk
    { rcContentDelta = Nothing
    , rcFinishReason = Nothing
    , rcToolDeltas = []
    , rcUsage = Nothing
    , rcError = Just t
    }

-- | Aeson parser tolerant of partial tool-call fields.
parseChunk :: Value -> Either String RawChunk
parseChunk = Aeson.parseEither $ Aeson.withObject "ChatCompletionChunk" $ \o -> do
  choices <- o .:? "choices"
  let firstChoice :: Maybe Aeson.Object
      firstChoice = case choices of
        Just (Aeson.Array a)
          | Vector.length a > 0 ->
              case Vector.head a of
                Aeson.Object obj -> Just obj
                _ -> Nothing
        _ -> Nothing
  (contentDelta, finishR, toolDeltas) <- case firstChoice of
    Nothing -> pure (Nothing, Nothing, [])
    Just ch -> do
      finish <- ch .:? "finish_reason"
      delta <- ch .:? "delta"
      case delta of
        Nothing -> pure (Nothing, finish, [])
        Just (Aeson.Object dObj) -> do
          cd <- dObj .:? "content"
          tc <- dObj .:? "tool_calls"
          let tds = parseToolCallDeltas tc
          pure (cd, finish, tds)
        _ -> pure (Nothing, finish, [])
  usageM <- o .:? "usage"
  let ru = case usageM of
        Just (Aeson.Object uObj) -> parseUsage uObj
        _ -> Nothing
  pure
    RawChunk
      { rcContentDelta = contentDelta
      , rcFinishReason = finishR
      , rcToolDeltas = toolDeltas
      , rcUsage = ru
      , rcError = Nothing
      }

parseToolCallDeltas :: Maybe Value -> [RawToolDelta]
parseToolCallDeltas = \case
  Just (Aeson.Array v) -> Vector.toList (Vector.mapMaybe oneDelta v)
  _ -> []
  where
    oneDelta :: Value -> Maybe RawToolDelta
    oneDelta = \case
      Aeson.Object o ->
        let funcObj :: Maybe Aeson.Object
            funcObj = case lookupField "function" o of
              Just (Aeson.Object f) -> Just f
              _ -> Nothing
            getName = funcObj >>= lookupText "name"
            getArgs = funcObj >>= lookupText "arguments"
         in Just
              RawToolDelta
                { rtdIndex = maybe 0 fromInt (lookupField "index" o)
                , rtdId = lookupText "id" o
                , rtdName = getName
                , rtdArgs = getArgs
                }
      _ -> Nothing

parseUsage :: Aeson.Object -> Maybe RawUsage
parseUsage o =
  case Aeson.parseEither pUsage o of
    Right u -> Just u
    Left _ -> Nothing
  where
    pUsage obj = do
      i <- obj .:? "prompt_tokens"
      out <- obj .:? "completion_tokens"
      ptd <- obj .:? "prompt_tokens_details"
      ctd <- obj .:? "completion_tokens_details"
      let cached = case ptd of
            Just (Aeson.Object p) -> case lookupField "cached_tokens" p of
              Just (Aeson.Number n) -> truncate n
              _ -> 0 :: Natural
            _ -> 0
          reasoning = case ctd of
            Just (Aeson.Object c) -> case lookupField "reasoning_tokens" c of
              Just (Aeson.Number n) -> Just (truncate n)
              _ -> Nothing
            _ -> Nothing
      pure
        RawUsage
          { ruInputTokens = fromMaybe 0 i
          , ruOutputTokens = fromMaybe 0 out
          , ruCacheReadTokens = cached
          , ruReasoningTokens = reasoning
          }

lookupField :: Text -> Aeson.Object -> Maybe Value
lookupField k = KeyMap.lookup (AesonKey.fromText k)

-- Pull a Text-valued field out of an Aeson object; tolerates
-- absent or non-Text values by returning 'Nothing'.
lookupText :: Text -> Aeson.Object -> Maybe Text
lookupText k o = case lookupField k o of
  Just (Aeson.String t) -> Just t
  _ -> Nothing

fromInt :: Value -> Int
fromInt = \case
  Aeson.Number n -> truncate n
  _ -> 0

-- ============================================================
-- Streamly state machine
-- ============================================================

data ProducerState = ProducerState
  { psChan :: !(Chan (Maybe RawChunk))
  , psPending :: ![AssistantMessageEvent]
  , psAssembler :: !Assembler
  , psFinished :: !Bool
  , psTerminalRef :: !(IORef Bool)
  }

step :: ProducerState -> IO (Maybe (AssistantMessageEvent, ProducerState))
step s
  | (e : rest) <- psPending s = do
      writeTerminal s e
      pure
        ( Just
            ( e
            , s
                { psPending = rest
                , psFinished = psFinished s || terminal e
                }
            )
        )
  | psFinished s = pure Nothing
  | otherwise = do
      mRaw <- readChan (psChan s)
      case mRaw of
        Nothing -> do
          alreadyTerminal <- readIORef (psTerminalRef s)
          if alreadyTerminal
            then pure Nothing
            else do
              now <- getCurrentTime
              let (events, ass') = closeOpenStream now (psAssembler s)
              case events of
                [] -> pure Nothing
                (e : rest) -> do
                  writeTerminal s e
                  pure
                    ( Just
                        ( e
                        , s
                            { psPending = rest
                            , psAssembler = ass'
                            , psFinished = True
                            }
                        )
                    )
        Just raw -> do
          now <- getCurrentTime
          let (events, ass') = translate raw (psAssembler s) now
          case events of
            [] -> step (s {psAssembler = ass'})
            (e : rest) -> do
              writeTerminal s e
              pure
                ( Just
                    ( e
                    , s
                        { psPending = rest
                        , psAssembler = ass'
                        , psFinished = psFinished s || terminal e
                        }
                    )
                )

writeTerminal :: ProducerState -> AssistantMessageEvent -> IO ()
writeTerminal s ev
  | terminal ev = writeIORef (psTerminalRef s) True
  | otherwise = pure ()

terminal :: AssistantMessageEvent -> Bool
terminal = \case
  EventDone {} -> True
  EventError {} -> True
  _ -> False

-- ============================================================
-- Translation
-- ============================================================

-- | Translation state across one streaming call.
data Assembler = Assembler
  { abModel :: !Model
  , abStart :: !UTCTime
  , abTextOpen :: !(Maybe Int)
    -- ^ 'Just i' when a text block at baikai contentIndex @i@ is
    -- currently open; 'Nothing' when no text block is open.
  , abTextAccum :: !Text
  , abTextEverOpened :: !Bool
  , abToolIndexMap :: !(IntMap Int)
    -- ^ Maps OpenAI's per-call tool-call index to baikai's
    -- 'contentIndex'.
  , abToolMeta :: !(IntMap (Text, Text))
    -- ^ baikai contentIndex → (id, name).
  , abToolArgs :: !(IntMap Text)
    -- ^ baikai contentIndex → accumulated arguments JSON.
  , abClosed :: !(IntMap Content.AssistantContent)
  , abNextContentIndex :: !Int
  , abUsage :: !Usage.Usage
  , abStopReason :: !Stop.StopReason
  , abFinishSeen :: !Bool
    -- ^ 'True' once a chunk carrying @finish_reason@ has been
    -- observed. The terminal 'EventDone' fires on channel close so
    -- the post-@finish_reason@ usage chunk (when @include_usage@ is
    -- enabled) has a chance to land.
  , abErrorMsg :: !(Maybe Text)
  }

emptyAssembler :: Model -> UTCTime -> Assembler
emptyAssembler m start =
  Assembler
    { abModel = m
    , abStart = start
    , abTextOpen = Nothing
    , abTextAccum = Text.empty
    , abTextEverOpened = False
    , abToolIndexMap = IntMap.empty
    , abToolMeta = IntMap.empty
    , abToolArgs = IntMap.empty
    , abClosed = IntMap.empty
    , abNextContentIndex = 0
    , abUsage = Usage._Usage
    , abStopReason = Stop.Stop
    , abFinishSeen = False
    , abErrorMsg = Nothing
    }

translate
  :: RawChunk
  -> Assembler
  -> UTCTime
  -> ([AssistantMessageEvent], Assembler)
translate chunk ass now
  | Just errMsg <- rcError chunk =
      let msg = finalMessage ass now (Just errMsg) Stop.ErrorReason
       in ( [EventError {reason = Stop.ErrorReason, errorPartial = msg}]
          , ass {abErrorMsg = Just errMsg}
          )
  | otherwise =
      let -- 1. Apply content delta (open text block if needed).
          (textEvents, ass1) = applyContentDelta (rcContentDelta chunk) ass
          -- 2. Apply tool-call deltas.
          (toolEvents, ass2) = applyToolDeltas (rcToolDeltas chunk) ass1
          -- 3. Apply usage chunk if present.
          ass3 = applyUsage (rcUsage chunk) ass2
          -- 4. If finish_reason is set, close any open text/tool
          --    blocks and stash the reason. EventDone is deferred
          --    to channel close so the post-finish_reason usage
          --    chunk has a chance to land.
          (closeEvents, ass4) = case rcFinishReason chunk of
            Just fr -> closeOnFinish fr ass3
            Nothing -> ([], ass3)
       in (textEvents <> toolEvents <> closeEvents, ass4)

applyContentDelta
  :: Maybe Text -> Assembler -> ([AssistantMessageEvent], Assembler)
applyContentDelta Nothing ass = ([], ass)
applyContentDelta (Just "") ass = ([], ass)
applyContentDelta (Just d) ass =
  case abTextOpen ass of
    Just i ->
      ( [TextDelta {contentIndex = i, delta = d}]
      , ass {abTextAccum = abTextAccum ass <> d}
      )
    Nothing ->
      let i = abNextContentIndex ass
       in ( [TextStart {contentIndex = i}, TextDelta {contentIndex = i, delta = d}]
          , ass
              { abTextOpen = Just i
              , abTextAccum = d
              , abTextEverOpened = True
              , abNextContentIndex = i + 1
              }
          )

applyToolDeltas
  :: [RawToolDelta] -> Assembler -> ([AssistantMessageEvent], Assembler)
applyToolDeltas deltas ass = foldl' apply ([], ass) deltas
  where
    apply (acc, a) d =
      let (events, a') = applyOneToolDelta d a
       in (acc <> events, a')

applyOneToolDelta
  :: RawToolDelta -> Assembler -> ([AssistantMessageEvent], Assembler)
applyOneToolDelta d ass =
  let openaiIdx = rtdIndex d
      (baikaiIdx, ass1, opened) = case IntMap.lookup openaiIdx (abToolIndexMap ass) of
        Just i -> (i, ass, False)
        Nothing ->
          let i = abNextContentIndex ass
              ass' =
                ass
                  { abToolIndexMap = IntMap.insert openaiIdx i (abToolIndexMap ass)
                  , abToolMeta = IntMap.insert i ("", "") (abToolMeta ass)
                  , abToolArgs = IntMap.insert i Text.empty (abToolArgs ass)
                  , abNextContentIndex = i + 1
                  }
           in (i, ass', True)
      -- Update metadata (id/name first delta only).
      ass2 =
        ass1
          { abToolMeta =
              IntMap.adjust
                ( \(existingId, existingName) ->
                    ( maybe existingId (\x -> if Text.null existingId then x else existingId) (rtdId d)
                    , maybe existingName (\x -> if Text.null existingName then x else existingName) (rtdName d)
                    )
                )
                baikaiIdx
                (abToolMeta ass1)
          }
      -- Append args if present.
      argsDelta = fromMaybe "" (rtdArgs d)
      ass3 = ass2 {abToolArgs = IntMap.adjust (<> argsDelta) baikaiIdx (abToolArgs ass2)}
      events0 = if opened then [ToolCallStart {contentIndex = baikaiIdx}] else []
      events1 =
        if Text.null argsDelta
          then events0
          else events0 <> [ToolCallDelta {contentIndex = baikaiIdx, delta = argsDelta}]
   in (events1, ass3)

applyUsage :: Maybe RawUsage -> Assembler -> Assembler
applyUsage Nothing ass = ass
applyUsage (Just u) ass =
  let usage' =
        Usage.Usage
          { Usage.inputTokens = ruInputTokens u
          , Usage.outputTokens = ruOutputTokens u
          , Usage.cacheReadTokens = ruCacheReadTokens u
          , Usage.cacheWriteTokens = 0
          , Usage.reasoningTokens = ruReasoningTokens u
          , Usage.totalTokens = ruInputTokens u + ruOutputTokens u + ruCacheReadTokens u
          , Usage.cost = _Cost
          }
   in ass {abUsage = usage'}

-- | Close all open content blocks and stash the resolved stop
-- reason; defer 'EventDone' to channel close.
closeOnFinish
  :: Text -> Assembler -> ([AssistantMessageEvent], Assembler)
closeOnFinish finishReason ass =
  let (closeText, ass1) = closeOpenText ass
      (closeTools, ass2) = closeOpenTools ass1
      reason = mapFinishReason finishReason
      ass3 = ass2 {abStopReason = reason, abFinishSeen = True}
   in (closeText <> closeTools, ass3)

-- | Close the open text block, if any, by emitting a 'TextEnd' and
-- storing the assembled content in 'abClosed'.
closeOpenText :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenText ass = case abTextOpen ass of
  Nothing -> ([], ass)
  Just i ->
    let body = abTextAccum ass
        block = Content.AssistantText (Content.TextContent body)
     in ( [TextEnd {contentIndex = i, content = body}]
        , ass
            { abTextOpen = Nothing
            , abTextAccum = Text.empty
            , abClosed = IntMap.insert i block (abClosed ass)
            }
        )

-- | Close every open tool call by emitting 'ToolCallEnd' (with the
-- fully parsed 'ToolCall') in index order.
closeOpenTools :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenTools ass =
  let openTools = IntMap.toAscList (abToolArgs ass)
      (events, ass') = foldl' closeOne ([], ass) openTools
   in (events, ass')
  where
    closeOne (acc, a) (i, argsText) =
      let (tid, tn) = fromMaybe ("", "") (IntMap.lookup i (abToolMeta a))
          decoded :: Value
          decoded = case Aeson.eitherDecodeStrict (Text.encodeUtf8 argsText) of
            Right v -> v
            Left _ -> Aeson.Object mempty
          tc =
            Content.ToolCall
              { Content.id_ = tid
              , Content.name = tn
              , Content.arguments = decoded
              }
          block = Content.AssistantToolCall tc
       in ( acc <> [ToolCallEnd {contentIndex = i, toolCall = tc}]
          , a
              { abClosed = IntMap.insert i block (abClosed a)
              , abToolArgs = IntMap.delete i (abToolArgs a)
              , abToolMeta = IntMap.delete i (abToolMeta a)
              }
          )

closeOpenStream
  :: UTCTime -> Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenStream now ass
  | abFinishSeen ass =
      -- Channel closed cleanly after finish_reason. Emit
      -- EventDone with the accumulated content + usage.
      let reason = abStopReason ass
          msg = finalMessage ass now Nothing reason
       in ([EventDone {reason = reason, message = msg}], ass)
  | otherwise =
      -- Channel closed without a finish_reason. Force-close any
      -- still-open blocks and emit EventError with the accumulated
      -- content.
      let (closeText, ass1) = closeOpenText ass
          (closeTools, ass2) = closeOpenTools ass1
          reason = Stop.ErrorReason
          msg =
            finalMessage
              ass2
              now
              (Just "openai stream ended without finish_reason")
              reason
          errEv = EventError {reason = reason, errorPartial = msg}
       in (closeText <> closeTools <> [errEv], ass2)

finalMessage
  :: Assembler -> UTCTime -> Maybe Text -> Stop.StopReason -> Msg.Message
finalMessage ass now errMsg sr =
  let blocks = blocksInOrder ass
      m = abModel ass
      usageBare = abUsage ass
      computed = Pricing.computeCost m usageBare
      usage' = usageBare {Usage.cost = computed}
   in Msg.AssistantMessage
        { Msg.assistantContent = blocks
        , Msg.usage = usage'
        , Msg.stopReason = sr
        , Msg.errorMessage = errMsg
        , Msg.timestamp = now
        }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (abClosed ass))

-- | Immediate single-error stream emitted when the request itself
-- could not be built (e.g. message mapping failed).
immediateError :: Text -> IO AssistantMessageEvent
immediateError errText = do
  now <- getCurrentTime
  let msg =
        Msg.AssistantMessage
          { Msg.assistantContent = Vector.empty
          , Msg.usage = Usage._Usage
          , Msg.stopReason = Stop.ErrorReason
          , Msg.errorMessage = Just errText
          , Msg.timestamp = now
          }
  pure EventError {reason = Stop.ErrorReason, errorPartial = msg}

-- ============================================================
-- Request mapping (preserved from EP-2 with minor refactoring)
-- ============================================================

mapRequest
  :: Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
mapRequest m ctx opts = do
  body <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = openaiCompletionsCompatFor m
      prefix = case ctx ^. #systemPrompt of
        Nothing -> []
        Just sp ->
          [ Chat.System
              { Chat.content = Vector.singleton Chat.Text {Chat.text = sp}
              , Chat.name = Nothing
              }
          ]
      mt = fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
      toolsField =
        if Vector.null (ctx ^. #tools)
          then Nothing
          else Just (Vector.map (mkOpenAITool compat) (ctx ^. #tools))
      toolChoiceField = fmap mkOpenAIToolChoice (opts ^. #toolChoice)
      reasoningEffortField =
        applyThinkingFormat compat (opts ^. #thinking)
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body)
      , Chat.model = OpenAIModels.Model (m ^. #modelId)
      , Chat.max_completion_tokens = Just mt
      , Chat.temperature = opts ^. #temperature
      , Chat.tools = toolsField
      , Chat.tool_choice = toolChoiceField
      , Chat.reasoning_effort = reasoningEffortField
      }

-- | Map a 'Baikai.ThinkingLevel.ThinkingLevel' onto the OpenAI SDK's
-- 'Chat.ReasoningEffort' enum. Returns 'Nothing' when the caller did
-- not request a level, when the host's 'thinkingFormat' is
-- 'ThinkingFormatNone', or when the host expects a non-OpenAI shape
-- the SDK does not support natively.
--
-- The non-OpenAI thinking formats (DeepSeek, OpenRouter, Together,
-- Z.ai, Qwen) require additional top-level JSON keys the upstream
-- @openai@ Haskell SDK does not expose. They are silently dropped on
-- this revision; see the EP-5 Decision Log for the rationale and
-- pointers to the workaround when one is needed.
applyThinkingFormat
  :: OpenAICompletionsCompat
  -> Maybe ThinkingLevel
  -> Maybe Chat.ReasoningEffort
applyThinkingFormat _ Nothing = Nothing
applyThinkingFormat compat (Just lvl) = case thinkingFormat compat of
  ThinkingFormatOpenAI -> Just (toReasoningEffort lvl)
  _ -> Nothing

toReasoningEffort :: ThinkingLevel -> Chat.ReasoningEffort
toReasoningEffort = \case
  ThinkingMinimal -> Chat.ReasoningEffort_Minimal
  ThinkingLow -> Chat.ReasoningEffort_Low
  ThinkingMedium -> Chat.ReasoningEffort_Medium
  ThinkingHigh -> Chat.ReasoningEffort_High

-- | Map a baikai 'Tool.Tool' into the upstream OpenAI 'Tool_Function'
-- shape. The compat record's 'supportsStrictMode' flag controls
-- whether the @strict@ field is sent ('True') or dropped ('False');
-- some OpenAI-compatible hosts reject strict-mode tools entirely.
--
-- The default ('defaultOpenAICompletionsCompat') leaves strict
-- unset, which OpenAI treats as the default-permissive behaviour;
-- callers that want @strict: true@ on every tool can flip the field
-- on their compat record (a future enhancement; currently we pass
-- 'Nothing' even when 'supportsStrictMode' is 'True', matching the
-- pre-EP-5 behaviour).
mkOpenAITool :: OpenAICompletionsCompat -> Tool.Tool -> OpenAITool.Tool
mkOpenAITool _compat t =
  OpenAITool.Tool_Function
    { OpenAITool.function =
        OpenAITool.Function
          { OpenAITool.name = Tool.name t
          , OpenAITool.description = Just (Tool.description t)
          , OpenAITool.parameters = Just (Tool.parameters t)
          , OpenAITool.strict = Nothing
          }
    }

-- | Map a baikai 'Tool.ToolChoice' into the upstream OpenAI
-- 'ToolChoice'. OpenAI accepts @none@, @auto@, @required@, and a
-- specific function reference; the SDK's 'ToolChoiceTool' takes the
-- whole 'OpenAITool.Tool' value so we synthesise a stub function
-- tool carrying just the name (OpenAI ignores the schema in this
-- position).
mkOpenAIToolChoice :: Tool.ToolChoice -> OpenAITool.ToolChoice
mkOpenAIToolChoice = \case
  Tool.ToolChoiceAuto -> OpenAITool.ToolChoiceAuto
  Tool.ToolChoiceNone -> OpenAITool.ToolChoiceNone
  Tool.ToolChoiceRequired -> OpenAITool.ToolChoiceRequired
  Tool.ToolChoiceSpecific n ->
    OpenAITool.ToolChoiceTool
      ( OpenAITool.Tool_Function
          { OpenAITool.function =
              OpenAITool.Function
                { OpenAITool.name = n
                , OpenAITool.description = Nothing
                , OpenAITool.parameters = Nothing
                , OpenAITool.strict = Nothing
                }
          }
      )

mapMessage :: Msg.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage = \case
  Msg.UserMessage {Msg.userContent = uc} ->
    Right
      Chat.User
        { Chat.content = Vector.map userContentToPart uc
        , Chat.name = Nothing
        }
  Msg.AssistantMessage {Msg.assistantContent = ac} ->
    let textBody = collectAssistantText ac
        toolCalls = collectToolCalls ac
        content
          | Text.null textBody = Nothing
          | otherwise = Just (Vector.singleton Chat.Text {Chat.text = textBody})
        toolCallVec
          | Vector.null toolCalls = Nothing
          | otherwise = Just toolCalls
     in Right
          Chat.Assistant
            { Chat.assistant_content = content
            , Chat.refusal = Nothing
            , Chat.name = Nothing
            , Chat.assistant_audio = Nothing
            , Chat.tool_calls = toolCallVec
            }
  Msg.ToolResultMessage
    { Msg.toolCallId = tid
    , Msg.toolResultContent = trc
    , Msg.isError = err
    } ->
      let body = collectToolResultText trc
          decorated = if err then "[error] " <> body else body
       in Right
            Chat.Tool
              { Chat.content = Vector.singleton Chat.Text {Chat.text = decorated}
              , Chat.tool_call_id = tid
              }

userContentToPart :: Content.UserContent -> Chat.Content
userContentToPart = \case
  Content.UserText (Content.TextContent t) -> Chat.Text {Chat.text = t}
  Content.UserImage img ->
    let encoded = Text.decodeUtf8 (Base64.encode (Content.imageData img))
        uri = "data:" <> Content.mimeType img <> ";base64," <> encoded
     in Chat.Image_URL
          { Chat.image_url = Chat.ImageURL {Chat.url = uri, Chat.detail = Nothing}
          }

collectAssistantText :: Vector Content.AssistantContent -> Text
collectAssistantText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          Content.AssistantText (Content.TextContent t) -> Just t
          Content.AssistantThinking th ->
            if Content.redacted th
              then Nothing
              else Just ("<thinking>" <> Content.thinking th <> "</thinking>")
          Content.AssistantToolCall _ -> Nothing
      )

collectToolCalls :: Vector Content.AssistantContent -> Vector ToolCall.ToolCall
collectToolCalls =
  Vector.mapMaybe
    ( \case
        Content.AssistantToolCall tc ->
          Just
            ToolCall.ToolCall_Function
              { ToolCall.id = Content.id_ tc
              , ToolCall.function =
                  ToolCall.Function
                    { ToolCall.name = Content.name tc
                    , ToolCall.arguments =
                        Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
                    }
              }
        _ -> Nothing
    )

collectToolResultText :: Vector Content.ToolResultContent -> Text
collectToolResultText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          Content.ToolResultText (Content.TextContent t) -> Just t
          Content.ToolResultImage _ -> Nothing
      )

mapFinishReason :: Text -> Stop.StopReason
mapFinishReason r = case r of
  "stop" -> Stop.Stop
  "length" -> Stop.Length
  "tool_calls" -> Stop.ToolUse
  "function_call" -> Stop.ToolUse
  "content_filter" -> Stop.ErrorReason
  _ -> Stop.Stop
