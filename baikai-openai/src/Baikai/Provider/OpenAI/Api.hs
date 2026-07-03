{-# LANGUAGE LambdaCase #-}

-- | Provider wrapping the @openai@ package's Chat Completions API.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.OpenAIChatCompletions' handler into the baikai
-- provider registry. After registration, any 'Baikai.Model.Model'
-- whose 'Baikai.Api.api' tag is 'OpenAIChatCompletions' dispatches
-- through this handler.
--
-- The handler resolves 'Baikai.Options.apiKey' when present, falling
-- back to the @OPENAI_API_KEY@ env var via
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
  ( register,
    registerWithRegistry,
    openaiChatStream,
    mapRequest,
    RawChunk (..),
    RawToolDelta (..),
    Assembler (..),
    emptyAssembler,
    translate,
    closeOpenStream,

    -- * Usage mapping

    -- Exposed for tests; may move behind an .Internal namespace in a later plan.
    RawUsage (..),
    parseUsage,
    rawUsageToUsage,
  )
where

import Baikai.Api (Api (..))
import Baikai.Auth qualified as Auth
import Baikai.Compat
  ( OpenAICompletionsCompat (..),
    ThinkingFormat (..),
  )
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (_Cost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError, invalidRequest, providerError)
import Baikai.Message qualified as Msg
import Baikai.Model (Model, openaiCompletionsCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.OpenAI.ErrorClass (classifyException)
import Baikai.Provider.OpenAI.Sse (openaiSseStream)
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    globalProviderRegistry,
    registerApiProviderWith,
  )
import Baikai.ResponseFormat (ResponseFormat (..))
import Baikai.StopReason qualified as Stop
import Baikai.Stream (streamingComplete)
import Baikai.Stream.Event
  ( AssistantMessageEvent (..),
    BlockEndPayload (..),
    DeltaPayload (..),
    IndexPayload (..),
    StartPayload (..),
    ToolCallEndPayload (..),
    doneTerminal,
    errorTerminal,
  )
import Baikai.ThinkingLevel
  ( ThinkingLevel (..),
  )
import Baikai.Tool qualified as Tool
import Baikai.Usage qualified as Usage
import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (Chan, newChan, readChan, writeChan)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Lens ((%~), (&), (.~), (^.))
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
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import OpenAI.V1 qualified as OpenAI
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.Models qualified as OpenAIModels
import OpenAI.V1.ResponseFormat qualified as RF
import OpenAI.V1.Tool qualified as OpenAITool
import OpenAI.V1.ToolCall qualified as ToolCall
import Servant.Client qualified as Client
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Install the OpenAI Chat Completions handler into the registry.
register :: IO ()
register = registerWithRegistry globalProviderRegistry

-- | Install the OpenAI Chat Completions handler into an explicit registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg =
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = OpenAIChatCompletions,
        stream = openaiChatStream,
        complete = streamingComplete openaiChatStream
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
openaiChatStream ::
  Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiChatStream m ctx opts =
  Stream.concatEffect $ do
    setupResult <- trySync (prepareCall m ctx opts)
    let setup = either (Left . exceptionToError) id setupResult
    case setup of
      Left err -> Stream.fromList <$> immediateError err
      Right call -> do
        ch <- newChan :: IO (Chan (Maybe (Either BaikaiError RawChunk)))
        tref <- newIORef False
        _ <- forkIO (worker call ch)
        startTime <- getCurrentTime
        let initialState =
              ProducerState
                { chan = ch,
                  pending = [EventStart StartPayload {partial = skeletonStart m startTime, responseId = Nothing}],
                  assembler = emptyAssembler m startTime,
                  finished = False,
                  terminalRef = tref
                }
        pure (Stream.unfoldrM step initialState)

skeletonStart :: Model -> UTCTime -> Msg.Message
skeletonStart _m start =
  Msg.AssistantMessage
    Msg.AssistantPayload
      { Msg.content = Vector.empty,
        Msg.usage = Usage._Usage,
        Msg.stopReason = Stop.Stop,
        Msg.errorMessage = Nothing,
        Msg.timestamp = start
      }

-- | Per-call prepared values.
data OpenAICall = OpenAICall
  { clientEnv :: !Client.ClientEnv,
    apiKey :: !Text,
    request :: !Chat.CreateChatCompletion
  }
  deriving stock (Generic)

prepareCall :: Model -> Context -> Options -> IO (Either BaikaiError OpenAICall)
prepareCall m ctx opts = case mapRequest m ctx opts of
  Left e -> pure (Left (invalidRequest e))
  Right req -> do
    key <- resolveKey opts
    let url = case m ^. #baseUrl of
          "" -> "https://api.openai.com"
          u -> u
    env <- OpenAI.getClientEnv url
    let req' =
          req
            { Chat.stream = Just True,
              Chat.stream_options =
                Just
                  Chat._ChatCompletionStreamOptions
                    { Chat.include_usage = Just True
                    }
            }
    pure (Right OpenAICall {clientEnv = env, apiKey = key, request = req'})

resolveKey :: Options -> IO Text
resolveKey opts = case opts ^. #apiKey of
  Just source -> Auth.resolveApiKey source
  Nothing -> Auth.resolveApiKey (Auth.ApiKeyEnv "OPENAI_API_KEY")

-- | A loose summary of one streamed chunk. The raw 'Aeson.Value' is
-- pre-parsed into the fields we care about; unknown fields are
-- ignored. Missing fields are 'Nothing' (we tolerate partial
-- tool-call deltas).
data RawChunk = RawChunk
  { contentDelta :: !(Maybe Text),
    finishReason :: !(Maybe Text),
    toolDeltas :: ![RawToolDelta],
    usage :: !(Maybe RawUsage)
  }
  deriving stock (Show, Generic)

data RawToolDelta = RawToolDelta
  { index :: !Int,
    id_ :: !(Maybe Text),
    name :: !(Maybe Text),
    args :: !(Maybe Text)
  }
  deriving stock (Show, Generic)

data RawUsage = RawUsage
  { inputTokens :: !Natural,
    outputTokens :: !Natural,
    cacheReadTokens :: !Natural,
    reasoningTokens :: !(Maybe Natural)
  }
  deriving stock (Show, Generic)

worker ::
  OpenAICall -> Chan (Maybe (Either BaikaiError RawChunk)) -> IO ()
worker call ch = do
  r <-
    trySync $
      openaiSseStream (call ^. #clientEnv) (call ^. #apiKey) (call ^. #request) $ \case
        Left be -> writeChan ch (Just (Left be))
        Right val -> case parseChunk val of
          Left err -> writeChan ch (Just (Left (providerError (Text.pack err))))
          Right chunk -> writeChan ch (Just (Right chunk))
  case r of
    Right () -> pure ()
    Left e -> writeChan ch (Just (Left (exceptionToError e)))
  writeChan ch Nothing

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
      { contentDelta = contentDelta,
        finishReason = finishR,
        toolDeltas = toolDeltas,
        usage = ru
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
                { index = maybe 0 fromInt (lookupField "index" o),
                  id_ = lookupText "id" o,
                  name = getName,
                  args = getArgs
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
          { inputTokens = fromMaybe 0 i,
            outputTokens = fromMaybe 0 out,
            cacheReadTokens = cached,
            reasoningTokens = reasoning
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
  { chan :: !(Chan (Maybe (Either BaikaiError RawChunk))),
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
              let (events, ass') = closeOpenStream now Nothing (s ^. #assembler)
              case events of
                [] -> pure Nothing
                (e : rest) -> do
                  writeTerminal s e
                  pure
                    ( Just
                        ( e,
                          s
                            & #pending .~ rest
                            & #assembler .~ ass'
                            & #finished .~ True
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

-- ============================================================
-- Translation
-- ============================================================

-- | Translation state across one streaming call.
data Assembler = Assembler
  { model :: !Model,
    start :: !UTCTime,
    -- | 'Just i' when a text block at baikai contentIndex @i@ is
    -- currently open; 'Nothing' when no text block is open.
    textOpen :: !(Maybe Int),
    textAccum :: !Text,
    textEverOpened :: !Bool,
    -- | Maps OpenAI's per-call tool-call index to baikai's
    -- 'contentIndex'.
    toolIndexMap :: !(IntMap Int),
    -- | baikai contentIndex → (id, name).
    toolMeta :: !(IntMap (Text, Text)),
    -- | baikai contentIndex → accumulated arguments JSON.
    toolArgs :: !(IntMap Text),
    closed :: !(IntMap Content.AssistantContent),
    nextContentIndex :: !Int,
    usage :: !Usage.Usage,
    stopReason :: !Stop.StopReason,
    -- | 'True' once a chunk carrying @finish_reason@ has been
    -- observed. The terminal 'EventDone' fires on channel close so
    -- the post-@finish_reason@ usage chunk (when @include_usage@ is
    -- enabled) has a chance to land.
    finishSeen :: !Bool,
    pendingError :: !(Maybe BaikaiError),
    finishNote :: !(Maybe Text)
  }
  deriving stock (Generic)

emptyAssembler :: Model -> UTCTime -> Assembler
emptyAssembler m s =
  Assembler
    { model = m,
      start = s,
      textOpen = Nothing,
      textAccum = Text.empty,
      textEverOpened = False,
      toolIndexMap = IntMap.empty,
      toolMeta = IntMap.empty,
      toolArgs = IntMap.empty,
      closed = IntMap.empty,
      nextContentIndex = 0,
      usage = Usage._Usage,
      stopReason = Stop.Stop,
      finishSeen = False,
      pendingError = Nothing,
      finishNote = Nothing
    }

translate ::
  Either BaikaiError RawChunk ->
  Assembler ->
  UTCTime ->
  ([AssistantMessageEvent], Assembler)
translate chunk ass now
  | Left be <- chunk =
      let msg = finalMessage ass now (Just (be ^. #message)) Stop.ErrorReason
       in ([EventError (errorTerminal Nothing Stop.ErrorReason msg be)], ass)
  | Right raw <- chunk =
      let -- 1. Apply content delta (open text block if needed).
          (textEvents, ass1) = applyContentDelta (raw ^. #contentDelta) ass
          -- 2. Apply tool-call deltas.
          (toolEvents, ass2) = applyToolDeltas (raw ^. #toolDeltas) ass1
          -- 3. Apply usage chunk if present.
          ass3 = applyUsage (raw ^. #usage) ass2
          -- 4. If finish_reason is set, close any open text/tool
          --    blocks and stash the reason. EventDone is deferred
          --    to channel close so the post-finish_reason usage
          --    chunk has a chance to land.
          (closeEvents, ass4) = case raw ^. #finishReason of
            Just fr -> closeOnFinish fr ass3
            Nothing -> ([], ass3)
       in (textEvents <> toolEvents <> closeEvents, ass4)

applyContentDelta ::
  Maybe Text -> Assembler -> ([AssistantMessageEvent], Assembler)
applyContentDelta Nothing ass = ([], ass)
applyContentDelta (Just "") ass = ([], ass)
applyContentDelta (Just d) ass =
  case ass ^. #textOpen of
    Just i ->
      ( [TextDelta DeltaPayload {contentIndex = i, delta = d}],
        ass & #textAccum %~ (<> d)
      )
    Nothing ->
      let i = ass ^. #nextContentIndex
       in ( [TextStart IndexPayload {contentIndex = i}, TextDelta DeltaPayload {contentIndex = i, delta = d}],
            ass
              & #textOpen .~ Just i
              & #textAccum .~ d
              & #textEverOpened .~ True
              & #nextContentIndex .~ (i + 1)
          )

applyToolDeltas ::
  [RawToolDelta] -> Assembler -> ([AssistantMessageEvent], Assembler)
applyToolDeltas deltas ass = foldl' apply ([], ass) deltas
  where
    apply (acc, a) d =
      let (events, a') = applyOneToolDelta d a
       in (acc <> events, a')

applyOneToolDelta ::
  RawToolDelta -> Assembler -> ([AssistantMessageEvent], Assembler)
applyOneToolDelta d ass =
  let openaiIdx = d ^. #index
      (baikaiIdx, ass1, opened) = case IntMap.lookup openaiIdx (ass ^. #toolIndexMap) of
        Just i -> (i, ass, False)
        Nothing ->
          let i = ass ^. #nextContentIndex
              ass' =
                ass
                  & #toolIndexMap %~ IntMap.insert openaiIdx i
                  & #toolMeta %~ IntMap.insert i ("", "")
                  & #toolArgs %~ IntMap.insert i Text.empty
                  & #nextContentIndex .~ (i + 1)
           in (i, ass', True)
      -- Update metadata (id/name first delta only).
      ass2 =
        ass1
          & #toolMeta
            %~ IntMap.adjust
              ( \(existingId, existingName) ->
                  ( maybe existingId (\x -> if Text.null existingId then x else existingId) (d ^. #id_),
                    maybe existingName (\x -> if Text.null existingName then x else existingName) (d ^. #name)
                  )
              )
              baikaiIdx
      -- Append args if present.
      argsDelta = fromMaybe "" (d ^. #args)
      ass3 = ass2 & #toolArgs %~ IntMap.adjust (<> argsDelta) baikaiIdx
      events0 = if opened then [ToolCallStart IndexPayload {contentIndex = baikaiIdx}] else []
      events1 =
        if Text.null argsDelta
          then events0
          else events0 <> [ToolCallDelta DeltaPayload {contentIndex = baikaiIdx, delta = argsDelta}]
   in (events1, ass3)

-- | Normalize OpenAI's inclusive usage counters into baikai's
-- disjoint 'Usage.Usage' convention. OpenAI's @prompt_tokens@
-- includes @prompt_tokens_details.cached_tokens@, so the cached count
-- is subtracted out of 'Usage.inputTokens'. The subtraction is clamped
-- at zero because 'Natural' subtraction throws on underflow and because
-- OpenAI-compatible hosts can report inconsistent counters.
-- 'Usage.totalTokens' is recomputed from the normalized parts;
-- 'Usage.reasoningTokens' is a subset of 'Usage.outputTokens' and is
-- not added to the total. OpenAI does not bill cache writes, so
-- 'Usage.cacheWriteTokens' is always zero.
rawUsageToUsage :: RawUsage -> Usage.Usage
rawUsageToUsage u =
  let prompt = u ^. #inputTokens
      cached = u ^. #cacheReadTokens
      out = u ^. #outputTokens
      nonCached = if cached >= prompt then 0 else prompt - cached
   in Usage.Usage
        { Usage.inputTokens = nonCached,
          Usage.outputTokens = out,
          Usage.cacheReadTokens = cached,
          Usage.cacheWriteTokens = 0,
          Usage.reasoningTokens = u ^. #reasoningTokens,
          Usage.totalTokens = nonCached + out + cached,
          Usage.cost = _Cost
        }

applyUsage :: Maybe RawUsage -> Assembler -> Assembler
applyUsage Nothing ass = ass
applyUsage (Just u) ass = ass & #usage .~ rawUsageToUsage u

-- | Close all open content blocks and stash the resolved stop
-- reason; defer 'EventDone' to channel close.
closeOnFinish ::
  Text -> Assembler -> ([AssistantMessageEvent], Assembler)
closeOnFinish finishReason ass =
  let (closeText, ass1) = closeOpenText ass
      (closeTools, ass2) = closeOpenTools ass1
      (reason, note) = mapFinishReason finishReason
      pending =
        if reason == Stop.ErrorReason
          then Just (providerError ("provider stopped the response: finish_reason=" <> finishReason))
          else Nothing
      ass3 =
        ass2
          & #stopReason .~ reason
          & #finishSeen .~ True
          & #pendingError .~ pending
          & #finishNote .~ note
   in (closeText <> closeTools, ass3)

-- | Close the open text block, if any, by emitting a 'TextEnd' and
-- storing the assembled content in 'closed'.
closeOpenText :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenText ass = case ass ^. #textOpen of
  Nothing -> ([], ass)
  Just i ->
    let body = ass ^. #textAccum
        block = Content.AssistantText (Content.TextContent body)
     in ( [TextEnd BlockEndPayload {contentIndex = i, content = body}],
          ass
            & #textOpen .~ Nothing
            & #textAccum .~ Text.empty
            & #closed %~ IntMap.insert i block
        )

-- | Close every open tool call by emitting 'ToolCallEnd' (with the
-- fully parsed 'ToolCall') in index order.
closeOpenTools :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenTools ass =
  let openTools = IntMap.toAscList (ass ^. #toolArgs)
      (events, ass') = foldl' closeOne ([], ass) openTools
   in (events, ass')
  where
    closeOne (acc, a) (i, argsText) =
      let (tid, tn) = fromMaybe ("", "") (IntMap.lookup i (a ^. #toolMeta))
          decoded :: Value
          decoded = case Aeson.eitherDecodeStrict (Text.encodeUtf8 argsText) of
            Right v -> v
            Left _ -> Aeson.Object mempty
          tc =
            Content.ToolCall
              { Content.id_ = tid,
                Content.name = tn,
                Content.arguments = decoded
              }
          block = Content.AssistantToolCall tc
       in ( acc <> [ToolCallEnd ToolCallEndPayload {contentIndex = i, toolCall = tc}],
            a
              & #closed %~ IntMap.insert i block
              & #toolArgs %~ IntMap.delete i
              & #toolMeta %~ IntMap.delete i
          )

closeOpenStream ::
  UTCTime -> Maybe BaikaiError -> Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenStream now mErr ass
  | ass ^. #finishSeen =
      -- Channel closed cleanly after finish_reason.
      let reason = ass ^. #stopReason
          terminalErr =
            (ass ^. #pendingError)
              <|> if reason == Stop.ErrorReason
                then Just (providerError "provider stopped the response with an error finish_reason")
                else Nothing
          msg = finalMessage ass now (fmap (^. #message) terminalErr) reason
          terminalEvent = case terminalErr of
            Just be -> EventError (errorTerminal Nothing reason msg be)
            Nothing -> EventDone (doneTerminal Nothing reason msg)
       in ([terminalEvent], ass)
  | otherwise =
      -- Channel closed without a finish_reason. Force-close any
      -- still-open blocks and emit EventError. When the worker stored a
      -- classified HTTP error ('Just be'), surface it structurally;
      -- otherwise report the unexpected end of stream.
      let (closeText, ass1) = closeOpenText ass
          (closeTools, ass2) = closeOpenTools ass1
          reason = Stop.ErrorReason
          errText = case mErr of
            Just be -> be ^. #message
            Nothing -> "openai stream ended without finish_reason"
          msg = finalMessage ass2 now (Just errText) reason
          errInfo = fromMaybe (providerError errText) mErr
          errEv = EventError (errorTerminal Nothing reason msg errInfo)
       in (closeText <> closeTools <> [errEv], ass2)

finalMessage ::
  Assembler -> UTCTime -> Maybe Text -> Stop.StopReason -> Msg.Message
finalMessage ass now errMsg sr =
  let blocks = blocksInOrder ass
      m = ass ^. #model
      usageBare = ass ^. #usage
      computed = Pricing.computeCost m usageBare
      usage' = usageBare & #cost .~ computed
   in Msg.AssistantMessage
        Msg.AssistantPayload
          { Msg.content = blocks,
            Msg.usage = usage',
            Msg.stopReason = sr,
            Msg.errorMessage = errMsg <|> (ass ^. #finishNote),
            Msg.timestamp = now
          }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (ass ^. #closed))

-- | Immediate error stream emitted when the request itself could not
-- be built (e.g. message mapping failed).
immediateError :: BaikaiError -> IO [AssistantMessageEvent]
immediateError err = do
  now <- getCurrentTime
  let errText = err ^. #message
  let msg =
        Msg.AssistantMessage
          Msg.AssistantPayload
            { Msg.content = Vector.empty,
              Msg.usage = Usage._Usage,
              Msg.stopReason = Stop.ErrorReason,
              Msg.errorMessage = Just errText,
              Msg.timestamp = now
            }
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal Nothing Stop.ErrorReason msg err)
    ]

-- ============================================================
-- Request mapping (preserved from EP-2 with minor refactoring)
-- ============================================================

mapRequest ::
  Model -> Context -> Options -> Either Text Chat.CreateChatCompletion
mapRequest m ctx opts = do
  body <- traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = openaiCompletionsCompatFor m
      prefix = case ctx ^. #systemPrompt of
        Nothing -> []
        Just sp ->
          [ Chat.System
              { Chat.content = Vector.singleton Chat.Text {Chat.text = sp},
                Chat.name = Nothing
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
      responseFormatField =
        fmap mkOpenAIResponseFormat (opts ^. #responseFormat)
  pure
    Chat._CreateChatCompletion
      { Chat.messages = Vector.fromList (prefix <> body),
        Chat.model = OpenAIModels.Model (m ^. #modelId),
        Chat.max_completion_tokens = Just mt,
        Chat.temperature = opts ^. #temperature,
        Chat.tools = toolsField,
        Chat.tool_choice = toolChoiceField,
        Chat.reasoning_effort = reasoningEffortField,
        Chat.response_format = responseFormatField
      }

-- | Map a baikai 'ResponseFormat' onto the upstream OpenAI
-- 'RF.ResponseFormat'. 'JsonObject' becomes plain-JSON mode;
-- 'JsonSchema' becomes a named, optionally-strict schema. The
-- schema 'Value' is forwarded verbatim.
mkOpenAIResponseFormat :: ResponseFormat -> RF.ResponseFormat
mkOpenAIResponseFormat = \case
  JsonObject -> RF.JSON_Object
  JsonSchema {name = n, schema = s, strict = st} ->
    RF.JSON_Schema
      { RF.json_schema =
          RF.JSONSchema
            { RF.description = Nothing,
              RF.name = n,
              RF.schema = Just s,
              RF.strict = Just st
            }
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
applyThinkingFormat ::
  OpenAICompletionsCompat ->
  Maybe ThinkingLevel ->
  Maybe Chat.ReasoningEffort
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
          { OpenAITool.name = Tool.name t,
            OpenAITool.description = Just (Tool.description t),
            OpenAITool.parameters = Just (Tool.parameters t),
            OpenAITool.strict = Nothing
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
                { OpenAITool.name = n,
                  OpenAITool.description = Nothing,
                  OpenAITool.parameters = Nothing,
                  OpenAITool.strict = Nothing
                }
          }
      )

mapMessage :: Msg.Message -> Either Text (Chat.Message (Vector Chat.Content))
mapMessage = \case
  Msg.UserMessage Msg.UserPayload {Msg.content = uc} ->
    Right
      Chat.User
        { Chat.content = Vector.map userContentToPart uc,
          Chat.name = Nothing
        }
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
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
            { Chat.assistant_content = content,
              Chat.refusal = Nothing,
              Chat.name = Nothing,
              Chat.assistant_audio = Nothing,
              Chat.tool_calls = toolCallVec
            }
  Msg.ToolResultMessage
    Msg.ToolResultPayload
      { Msg.toolCallId = tid,
        Msg.content = trc,
        Msg.isError = err
      } ->
      case collectToolResultText trc of
        Left unsupported -> Left unsupported
        Right body ->
          let decorated = if err then "[error] " <> body else body
           in Right
                Chat.Tool
                  { Chat.content = Vector.singleton Chat.Text {Chat.text = decorated},
                    Chat.tool_call_id = tid
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
              { ToolCall.id = Content.id_ tc,
                ToolCall.function =
                  ToolCall.Function
                    { ToolCall.name = Content.name tc,
                      ToolCall.arguments =
                        Text.decodeUtf8 (BSL.toStrict (Aeson.encode (Content.arguments tc)))
                    }
              }
        _ -> Nothing
    )

collectToolResultText :: Vector Content.ToolResultContent -> Either Text Text
collectToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "OpenAI Chat Completions cannot encode ToolResultImage blocks in tool-result messages"

mapFinishReason :: Text -> (Stop.StopReason, Maybe Text)
mapFinishReason r = case r of
  "stop" -> (Stop.Stop, Nothing)
  "length" -> (Stop.Length, Nothing)
  "tool_calls" -> (Stop.ToolUse, Nothing)
  "function_call" -> (Stop.ToolUse, Nothing)
  "content_filter" -> (Stop.ErrorReason, Nothing)
  _ -> (Stop.Stop, Just ("unrecognized finish_reason: " <> r))

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
