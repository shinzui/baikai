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
-- back to the host-specific env var from
-- 'Baikai.Auth.defaultApiKeyEnvForBaseUrl'. Unknown hosts require an
-- explicit key source.
--
-- EP-3 promotes streaming to the primary entry point. The handler
-- exposes a 'streamly' 'Stream' of 'AssistantMessageEvent' values
-- bridged from a local SSE transport. Requests start as the SDK's
-- typed 'OpenAI.V1.Chat.Completions.CreateChatCompletion' value, then
-- 'Baikai.Provider.OpenAI.Shape.streamRequestBody' rewrites the raw
-- JSON body for OpenAI-compatible host quirks before
-- 'Baikai.Provider.OpenAI.Sse.openaiSseStreamValueWithHeaders' sends
-- it with cached transport settings and caller headers. Streaming
-- responses are parsed from raw 'Aeson.Value' chunks so partial
-- tool-call deltas may omit fields such as @id@ and @function.name@.
--
-- The synchronous 'complete' field is derived via
-- 'streamingComplete', so callers that drain the stream get the
-- same fully-assembled 'Response' they had before.
module Baikai.Provider.OpenAI.Api
  ( register,
    registerWithRegistry,
    openaiChatProvider,
    openaiChatStream,
    openaiChatStreamWith,
    SseDriver,
    openaiStrength,
    RawChunk (..),
    RawToolDelta (..),
    parseChunk,
    TagScanState (..),
    _TagScanState,
    scanThinkTags,
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
import Baikai.Compat (OpenAICompletionsCompat (requiresThinkingAsText))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Cost (zeroCost)
import Baikai.Cost.Pricing qualified as Pricing
import Baikai.Error (BaikaiError, invalidRequest, providerError)
import Baikai.Evidence qualified as Ev
import Baikai.Evidence.Build qualified as Build
import Baikai.Message qualified as Msg
import Baikai.Model (Model, openaiCompletionsCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.OpenAI.Internal.ErrorClass (classifyException)
import Baikai.Provider.OpenAI.Internal.Request (mapRequest)
import Baikai.Provider.OpenAI.Shape (streamRequestBody)
import Baikai.Provider.OpenAI.Sse (ResponseMetadata, capturedHeaderNames, openaiSseStreamValueWithHeaders)
import Baikai.Provider.OpenAI.Transport qualified as Transport
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
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Version (showVersion)
import GHC.Generics (Generic)
import Network.HTTP.Types.Header (RequestHeaders)
import Numeric.Natural (Natural)
import Paths_baikai_openai qualified as Paths
import Servant.Client qualified as Client
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Install the OpenAI Chat Completions handler into the registry.
register :: IO ()
register = registerApiProvider openaiChatProvider

-- | First-class OpenAI Chat Completions provider value. Use with
-- 'registerApiProviderWith' or 'newProviderRegistryFrom' for explicit
-- registries.
openaiChatProvider :: ApiProvider
openaiChatProvider =
  ApiProvider
    { apiTag = OpenAIChatCompletions,
      stream = openaiChatStream,
      complete = streamingComplete openaiChatStream
    }

-- | Install the OpenAI Chat Completions handler into an explicit registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg =
  registerApiProviderWith
    reg
    openaiChatProvider
{-# DEPRECATED registerWithRegistry "use registerApiProviderWith reg openaiChatProvider" #-}

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
openaiChatStream = openaiChatStreamWith liveSseDriver

-- | How a call physically reaches the host.
--
-- The arguments are exactly those of
-- 'Baikai.Provider.OpenAI.Sse.openaiSseStreamValueWithHeaders', which is
-- what 'liveSseDriver' is. A test passes a driver that replays a
-- recorded response through the same
-- 'Baikai.Provider.OpenAI.Sse.sseFromResponse' the live one uses, so the
-- request shaping, header allow-list, status classification, and chunk
-- decoding under test are all the real implementations and only the
-- socket is missing.
--
-- The request body arrives as an argument rather than inside a per-call
-- record, so a test driver can capture exactly what went out without
-- this module exporting the record that also holds the resolved API key.
type SseDriver =
  Client.ClientEnv ->
  RequestHeaders ->
  Aeson.Value ->
  (ResponseMetadata -> IO ()) ->
  (Either BaikaiError Aeson.Value -> IO ()) ->
  IO ()

liveSseDriver :: SseDriver
liveSseDriver = openaiSseStreamValueWithHeaders

-- | 'openaiChatStream' over an explicit transport driver.
openaiChatStreamWith ::
  SseDriver -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiChatStreamWith driver m ctx opts =
  Stream.concatEffect $ do
    setupResult <- trySync (prepareCall m ctx opts)
    let setup = either (Left . exceptionToError) id setupResult
    case setup of
      Left err -> Stream.fromList <$> immediateError m opts err
      Right call -> do
        ch <- newChan :: IO (Chan (Maybe (Either BaikaiError RawChunk)))
        tref <- newIORef False
        mref <- newIORef Nothing
        _ <- forkIO (worker driver call mref ch)
        startTime <- getCurrentTime
        -- The request body is the envelope the two digests commit to:
        -- it is exactly the JSON this call is about to put on the wire.
        -- Credentials are not in it -- they travel in the headers built
        -- separately by 'Transport.requestHeaders'.
        mkEvidence <-
          Build.prepareEvidence
            m
            opts
            Ev.TransportHttpApi
            (call ^. #thinking)
            (call ^. #requestBody)
            startTime
        let initialState =
              ProducerState
                { chan = ch,
                  pending = [EventStart StartPayload {partial = skeletonStart m startTime, responseId = Nothing}],
                  assembler = emptyAssembler m startTime,
                  finished = False,
                  terminalRef = tref,
                  metadataRef = mref,
                  evidence = mkEvidence
                }
        pure (Stream.unfoldrM step initialState)

skeletonStart :: Model -> UTCTime -> Msg.Message
skeletonStart _m start =
  Msg.AssistantMessage
    Msg.AssistantPayload
      { Msg.content = Vector.empty,
        Msg.usage = Usage.zeroUsage,
        Msg.stopReason = Stop.Stop,
        Msg.errorMessage = Nothing,
        Msg.timestamp = Just start
      }

-- | Per-call prepared values.
data OpenAICall = OpenAICall
  { clientEnv :: !Client.ClientEnv,
    requestHeaders :: !RequestHeaders,
    timeoutMs :: !(Maybe Int),
    requestBody :: !Aeson.Value,
    -- | What the caller's reasoning-effort preference became on this
    -- request, as 'streamRequestBody' described it. Carried from here
    -- rather than recomputed at the terminal: only the shaping step
    -- knows which of the seven host wire shapes was used.
    thinking :: !Ev.ThinkingTranslation
  }
  deriving stock (Generic)

prepareCall :: Model -> Context -> Options -> IO (Either BaikaiError OpenAICall)
prepareCall m ctx opts = case mapRequest m ctx opts of
  Left e -> pure (Left (invalidRequest e))
  Right req -> do
    let url = case m ^. #baseUrl of
          "" -> "https://api.openai.com"
          u -> u
    key <- Transport.resolveKey url opts
    env <- Transport.getClientEnvCached url
    let compat = openaiCompletionsCompatFor m
        (body, translation) = streamRequestBody compat opts req
        headers = Transport.requestHeaders key m opts
    pure
      ( Right
          OpenAICall
            { clientEnv = env,
              requestHeaders = headers,
              timeoutMs = opts ^. #timeoutMs,
              requestBody = body,
              thinking = translation
            }
      )

-- | A loose summary of one streamed chunk. The raw 'Aeson.Value' is
-- pre-parsed into the fields we care about; unknown fields are
-- ignored. Missing fields are 'Nothing' (we tolerate partial
-- tool-call deltas).
data RawChunk = RawChunk
  { contentDelta :: !(Maybe Text),
    reasoningDelta :: !(Maybe Text),
    finishReason :: !(Maybe Text),
    toolDeltas :: ![RawToolDelta],
    usage :: !(Maybe RawUsage),
    -- | The model the host says produced this chunk, from the chunk's
    -- top-level @model@ field. 'Nothing' means the host did not report
    -- one — never that it reported the configured model.
    model :: !(Maybe Text),
    -- | The host's identifier for this response, from the chunk's
    -- top-level @id@ field.
    responseId :: !(Maybe Text)
  }
  deriving stock (Show, Generic)

data RawToolDelta = RawToolDelta
  { index :: !(Maybe Int),
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
  SseDriver ->
  OpenAICall ->
  IORef (Maybe ResponseMetadata) ->
  Chan (Maybe (Either BaikaiError RawChunk)) ->
  IO ()
worker driver call metaRef ch = do
  r <-
    trySync
      $ Transport.runWithTimeout (call ^. #timeoutMs)
      $ driver
        (call ^. #clientEnv)
        (call ^. #requestHeaders)
        (call ^. #requestBody)
        (writeIORef metaRef . Just)
      $ \case
        Left be -> writeChan ch (Just (Left be))
        Right val -> case parseChunk val of
          Left err -> writeChan ch (Just (Left (providerError (Text.pack err))))
          Right chunk -> writeChan ch (Just (Right chunk))
  case r of
    Right Nothing -> pure ()
    Right (Just be) -> writeChan ch (Just (Left be))
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
  (contentDelta, reasoningDelta, finishR, toolDeltas) <- case firstChoice of
    Nothing -> pure (Nothing, Nothing, Nothing, [])
    Just ch -> do
      finish <- ch .:? "finish_reason"
      delta <- ch .:? "delta"
      case delta of
        Nothing -> parseMessageObject ch finish
        Just (Aeson.Object dObj) -> do
          cd <- dObj .:? "content"
          let rd = reasoningText dObj
          tc <- dObj .:? "tool_calls"
          let tds = parseToolCallDeltas tc
          pure (cd, rd, finish, tds)
        _ -> parseMessageObject ch finish
  usageM <- o .:? "usage"
  let ru = case usageM of
        Just (Aeson.Object uObj) -> parseUsage uObj
        _ -> Nothing
  pure
    RawChunk
      { contentDelta = contentDelta,
        reasoningDelta = reasoningDelta,
        finishReason = finishR,
        toolDeltas = toolDeltas,
        usage = ru,
        -- Read as a lookup yielding 'Maybe' rather than a required
        -- field: chunks are decoded as raw JSON precisely because
        -- compatible hosts vary, and a host that omits either of these
        -- has reported nothing, which is not a decode failure.
        model = lookupText "model" o,
        responseId = lookupText "id" o
      }

parseMessageObject ::
  Aeson.Object ->
  Maybe Text ->
  Aeson.Parser (Maybe Text, Maybe Text, Maybe Text, [RawToolDelta])
parseMessageObject ch finish = do
  msg <- ch .:? "message"
  case msg of
    Just (Aeson.Object mObj) -> do
      cd <- mObj .:? "content"
      pure (cd, reasoningText mObj, finish, [])
    _ -> pure (Nothing, Nothing, finish, [])

reasoningText :: Aeson.Object -> Maybe Text
reasoningText obj =
  lookupText "reasoning_content" obj <|> lookupText "reasoning" obj

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
                { index = fromInt <$> lookupField "index" o,
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
    terminalRef :: !(IORef Bool),
    -- | Where the worker leaves the response-level metadata it captured
    -- before the first chunk. Read on this side rather than pushed
    -- through 'chan' so the channel keeps carrying exactly one kind of
    -- thing; 'absorbMetadata' folds it into the assembler.
    metadataRef :: !(IORef (Maybe ResponseMetadata)),
    -- | Everything about this call's evidence that was knowable before
    -- the first byte came back, waiting on the terminal timestamp and
    -- outcome. 'Nothing' when the caller did not ask for evidence.
    -- 'sealTerminal' applies it.
    evidence ::
      !(Maybe (UTCTime -> Ev.CallStatus -> Maybe BaikaiError -> Ev.ModelCallEvidence))
  }
  deriving stock (Generic)

step :: ProducerState -> IO (Maybe (AssistantMessageEvent, ProducerState))
step s
  | (e : rest) <- s ^. #pending = do
      sealed <- sealTerminal s e
      pure
        ( Just
            ( sealed,
              s
                & #pending .~ rest
                & #finished .~ (s ^. #finished || terminal sealed)
            )
        )
  | s ^. #finished = pure Nothing
  | otherwise = do
      mRaw <- readChan (s ^. #chan)
      -- After the read, because the worker writes the metadata before it
      -- writes anything onto the channel: taking it here means every
      -- path out of this branch — including the one where the channel
      -- closed without ever producing a chunk — sees it.
      ass0 <- absorbMetadata (s ^. #metadataRef) (s ^. #assembler)
      let s' = s & #assembler .~ ass0
      case mRaw of
        Nothing -> do
          alreadyTerminal <- readIORef (s' ^. #terminalRef)
          if alreadyTerminal
            then pure Nothing
            else do
              now <- getCurrentTime
              let (events, ass') = closeOpenStream now Nothing ass0
              case events of
                [] -> pure Nothing
                (e : rest) -> do
                  sealed <- sealTerminal (s' & #assembler .~ ass') e
                  pure
                    ( Just
                        ( sealed,
                          s'
                            & #pending .~ rest
                            & #assembler .~ ass'
                            & #finished .~ True
                        )
                    )
        Just raw -> do
          now <- getCurrentTime
          let (events, ass') = translate raw ass0 now
          case events of
            [] -> step (s' & #assembler .~ ass')
            (e : rest) -> do
              sealed <- sealTerminal (s' & #assembler .~ ass') e
              pure
                ( Just
                    ( sealed,
                      s'
                        & #pending .~ rest
                        & #assembler .~ ass'
                        & #finished .~ (s' ^. #finished || terminal sealed)
                    )
                )

-- | Fold whatever response-level metadata the worker has captured into
-- the assembler.
--
-- Idempotent: applying it again overwrites the same fields with the same
-- values, which is what lets 'step' call it on every pass rather than
-- tracking whether it has run.
absorbMetadata :: IORef (Maybe ResponseMetadata) -> Assembler -> IO Assembler
absorbMetadata ref ass = do
  meta <- readIORef ref
  pure $ case meta of
    Nothing -> ass
    Just md ->
      ass
        & #httpStatus .~ Just (md ^. #httpStatus)
        & #providerRequestId .~ correlationId md

-- | The host's correlation identifier for this response, or a gateway's
-- if the host's own is absent.
--
-- The preference order is
-- 'Baikai.Provider.OpenAI.Sse.capturedHeaderNames' itself, so the
-- allow-list and the preference cannot disagree. Nothing is invented: a
-- response carrying none of those headers leaves this 'Ev.Unobserved'.
correlationId :: ResponseMetadata -> Ev.Observed Text
correlationId md =
  case [v | n <- capturedHeaderNames, Just v <- [lookup (headerName n) (md ^. #headers)]] of
    (v : _) -> Ev.Observed v
    [] -> Ev.Unobserved
  where
    headerName = Text.decodeUtf8 . CI.foldedCase

-- | Mark the stream terminated and attach the call's evidence to the
-- terminal event.
--
-- Every event this producer yields goes through here, so the three
-- sites that can produce a terminal -- a translated upstream chunk, a
-- queued event drained from 'pending', and the channel-close path --
-- all seal identically. Doing it here rather than inside 'translate'
-- keeps that function pure; evidence construction needs 'IO' for the
-- call identifier.
--
-- A non-terminal event passes through unchanged, and so does a terminal
-- on a call whose caller asked for no evidence.
sealTerminal :: ProducerState -> AssistantMessageEvent -> IO AssistantMessageEvent
sealTerminal s ev
  | not (terminal ev) = pure ev
  | otherwise = do
      writeIORef (s ^. #terminalRef) True
      case s ^. #evidence of
        Nothing -> pure ev
        Just finish -> do
          now <- getCurrentTime
          let st = statusOf ev
              record = observeOpenAI st (s ^. #assembler) (finish now st (errorOf ev))
          pure (withEvidence record ev)
  where
    statusOf = \case
      EventDone {} -> Ev.CallSucceeded
      _ -> Ev.CallFailed
    -- The terminal payload already carries the normalized error, and
    -- 'errorTerminal' guarantees it is 'Just' on every 'EventError'.
    errorOf = \case
      EventError p -> p ^. #errorInfo
      _ -> Nothing
    -- Set through the generic-lens label rather than a record update:
    -- 'Baikai.Options.Options' also has an @evidence@ field, so under
    -- @DuplicateRecordFields@ a bare @p {evidence = ...}@ has no unique
    -- constructor to resolve to.
    withEvidence record = \case
      EventDone p -> EventDone (p & #evidence .~ Just record)
      EventError p -> EventError (p & #evidence .~ Just record)
      other -> other

-- | Replace the observed fields of a prepared evidence record with what
-- this call actually saw, and derive the strength from that.
--
-- Only ever reached on a call whose caller asked for evidence, which is
-- what makes it safe to compute the response commitment here: that
-- digest hashes the model's entire output and is the most expensive
-- thing this provider adds. The observations it reads were gathered
-- unconditionally, because each costs a lookup and each improves the
-- 'Baikai.Response.Response' for every caller.
--
-- Nothing here consults the request. An observation the host did not
-- make stays 'Ev.Unobserved'.
observeOpenAI ::
  Ev.CallStatus -> Assembler -> Ev.ModelCallEvidence -> Ev.ModelCallEvidence
observeOpenAI st ass ev =
  ev
    & #endpoint . #implementationVersion .~ Just openaiPackageVersion
    & #observedModel .~ (ass ^. #observedModel)
    & #providerRequestId .~ (ass ^. #providerRequestId)
    & #responseId .~ maybe Ev.Unobserved Ev.Observed (ass ^. #responseId)
    & #usage .~ observedUsage ass
    & #responseCommitment .~ responseCommitment st ass
    & #strength .~ openaiStrength (ass ^. #observedModel) (ass ^. #providerRequestId)

-- | How much an OpenAI-compatible evidence record proves, derived only
-- from what was actually observed.
--
-- No host in this ecosystem echoes the reasoning configuration it
-- applied, so 'Ev.EvidenceFullyObserved' is unreachable on this
-- transport. Reasoning-token counts in the usage block corroborate
-- output volume; they are not a statement of which effort setting was in
-- force and must not raise the strength.
--
-- A successful HTTP status deliberately does not raise it either. A 200
-- means the request was accepted, not that any particular model ran.
openaiStrength :: Ev.Observed Text -> Ev.Observed Text -> Ev.EvidenceStrength
openaiStrength observedModel providerRequestId =
  case (observedModel, providerRequestId) of
    (Ev.Observed _, Ev.Observed _) -> Ev.EvidenceModelObserved
    (_, Ev.Observed _) -> Ev.EvidenceCorrelated
    _ -> Ev.EvidenceRequestedOnly

-- | The token accounting, but only if the host actually reported it.
--
-- The assembler initialises 'usage' to zeroes, so reporting it
-- unconditionally would tell a reader the host said this call consumed
-- nothing — which for a call that failed before any usage arrived is a
-- fabrication, and exactly what 'Ev.Observed' exists to stop.
observedUsage :: Assembler -> Ev.Observed Usage.Usage
observedUsage ass
  | ass ^. #usageReported = Ev.Observed (finalUsage ass)
  | otherwise = Ev.Unobserved

-- | A commitment to what came back, on a call that produced a response.
--
-- Left 'Ev.Unobserved' otherwise: a digest of an empty envelope is a
-- real-looking value standing for a response that never arrived.
responseCommitment :: Ev.CallStatus -> Assembler -> Ev.Observed Text
responseCommitment Ev.CallSucceeded ass =
  Ev.Observed (Ev.commitmentDigest (responseEnvelope ass))
responseCommitment _ _ = Ev.Unobserved

-- | What that digest commits to: the assembled content blocks in order,
-- the stop reason, and the reported usage.
--
-- Deliberately the assembled response rather than the raw SSE bytes. Two
-- identical responses split into different chunks must produce the same
-- digest, and the chunk boundaries are a transport detail no verifier
-- holding the response could reproduce. The key names match the
-- Anthropic adapter's envelope so a consumer reading both does not have
-- to learn two spellings.
responseEnvelope :: Assembler -> Value
responseEnvelope ass =
  Aeson.object
    [ "content" Aeson..= blocksInOrder ass,
      "stop_reason" Aeson..= (ass ^. #stopReason),
      "usage" Aeson..= finalUsage ass
    ]

-- | The version of this package, for the evidence record's endpoint
-- identity. Read from the cabal-generated module rather than written as
-- a literal, which becomes a lie the first time a release misses it.
openaiPackageVersion :: Text
openaiPackageVersion = Text.pack (showVersion Paths.version)

terminal :: AssistantMessageEvent -> Bool
terminal = \case
  EventDone {} -> True
  EventError {} -> True
  _ -> False

-- ============================================================
-- Translation
-- ============================================================

data TagMode
  = TagVisible
  | TagReasoning
  deriving stock (Eq, Show, Generic)

-- | Incremental scanner state for hosts that stream reasoning in
-- assistant text using @<think>@ or @<thinking>@ tags.
data TagScanState = TagScanState
  { tagMode :: !TagMode,
    tagPending :: !Text
  }
  deriving stock (Eq, Show, Generic)

_TagScanState :: TagScanState
_TagScanState =
  TagScanState
    { tagMode = TagVisible,
      tagPending = Text.empty
    }

-- | Split one text delta into reasoning fragments ('Left') and
-- visible text fragments ('Right'), preserving partial tag prefixes
-- across chunk boundaries.
scanThinkTags :: TagScanState -> Text -> (TagScanState, [Either Text Text])
scanThinkTags st input =
  let (mode', pending', parts) = go (tagMode st) (tagPending st <> input) []
   in (TagScanState {tagMode = mode', tagPending = pending'}, parts)
  where
    go mode txt acc =
      case findTag mode txt of
        Just (before, after, nextMode) ->
          go nextMode after (appendPart mode before acc)
        Nothing ->
          let (emitNow, pending) = splitPending mode txt
           in (mode, pending, appendPart mode emitNow acc)

    appendPart _ "" acc = acc
    appendPart TagVisible t acc = acc <> [Right t]
    appendPart TagReasoning t acc = acc <> [Left t]

findTag :: TagMode -> Text -> Maybe (Text, Text, TagMode)
findTag mode txt =
  case earliest markers of
    Nothing -> Nothing
    Just (idx, marker) ->
      Just
        ( Text.take idx txt,
          Text.drop (idx + Text.length marker) txt,
          nextMode
        )
  where
    (markers, nextMode) = case mode of
      TagVisible -> (openingTags, TagReasoning)
      TagReasoning -> (closingTags, TagVisible)
    earliest =
      foldr
        ( \marker best ->
            case Text.breakOn marker txt of
              (_, "") -> best
              (before, _) ->
                let candidate = (Text.length before, marker)
                 in case best of
                      Nothing -> Just candidate
                      Just (oldIdx, _) | Text.length before < oldIdx -> Just candidate
                      _ -> best
        )
        Nothing

splitPending :: TagMode -> Text -> (Text, Text)
splitPending mode txt =
  let suffix = longestTagPrefix (case mode of TagVisible -> openingTags; TagReasoning -> closingTags) txt
   in (Text.dropEnd (Text.length suffix) txt, suffix)

longestTagPrefix :: [Text] -> Text -> Text
longestTagPrefix markers txt =
  foldr longer Text.empty candidates
  where
    candidates =
      [ suffix
      | n <- [1 .. Text.length txt],
        let suffix = Text.takeEnd n txt,
        any (suffix `Text.isPrefixOf`) markers
      ]
    longer a b
      | Text.length a > Text.length b = a
      | otherwise = b

openingTags :: [Text]
openingTags = ["<think>", "<thinking>"]

closingTags :: [Text]
closingTags = ["</think>", "</thinking>"]

-- | Translation state across one streaming call.
data Assembler = Assembler
  { model :: !Model,
    start :: !UTCTime,
    -- | 'Just i' when a text block at baikai contentIndex @i@ is
    -- currently open; 'Nothing' when no text block is open.
    textOpen :: !(Maybe Int),
    textAccum :: !Text,
    textEverOpened :: !Bool,
    reasoningOpen :: !(Maybe Int),
    reasoningAccum :: !Text,
    tagScanState :: !TagScanState,
    -- | Maps OpenAI's per-call tool-call index to baikai's
    -- 'contentIndex'.
    toolIndexMap :: !(IntMap Int),
    toolIdMap :: !(Map Text Int),
    lastToolIdx :: !(Maybe Int),
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
    finishNote :: !(Maybe Text),
    -- The five fields below are what this call /observed/, as distinct
    -- from what it requested. They live here because this record is the
    -- only state that survives from the first chunk to the last, and
    -- because an observation that never arrived must stay
    -- 'Ev.Unobserved' rather than falling back to the caller's
    -- configuration.

    -- | The host's own correlation identifier for this call, from the
    -- response headers.
    providerRequestId :: !(Ev.Observed Text),
    -- | The model identifier the host reported running, from the first
    -- chunk that carried one. Never the configured model.
    observedModel :: !(Ev.Observed Text),
    -- | The host's identifier for this response, from the first chunk
    -- that carried one.
    responseId :: !(Maybe Text),
    -- | The response's HTTP status. Recorded because the transport has
    -- it; 'Baikai.Evidence.ModelCallEvidence' has no field for it, and
    -- inventing one belongs to the vocabulary's plan, not to this
    -- module.
    httpStatus :: !(Maybe Int),
    -- | Whether the host actually reported token counts, as opposed to
    -- 'usage' still holding the zeroes it was initialised with. Without
    -- this a failed call would claim the host reported consuming
    -- nothing.
    usageReported :: !Bool
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
      reasoningOpen = Nothing,
      reasoningAccum = Text.empty,
      tagScanState = _TagScanState,
      toolIndexMap = IntMap.empty,
      toolIdMap = Map.empty,
      lastToolIdx = Nothing,
      toolMeta = IntMap.empty,
      toolArgs = IntMap.empty,
      closed = IntMap.empty,
      nextContentIndex = 0,
      usage = Usage.zeroUsage,
      stopReason = Stop.Stop,
      finishSeen = False,
      pendingError = Nothing,
      finishNote = Nothing,
      providerRequestId = Ev.Unobserved,
      observedModel = Ev.Unobserved,
      responseId = Nothing,
      httpStatus = Nothing,
      usageReported = False
    }

translate ::
  Either BaikaiError RawChunk ->
  Assembler ->
  UTCTime ->
  ([AssistantMessageEvent], Assembler)
translate chunk ass now
  | Left be <- chunk =
      let msg = finalMessage ass now (Just (be ^. #message)) Stop.ErrorReason
       in ([EventError (errorTerminal Nothing (ass ^. #responseId) Stop.ErrorReason msg be)], ass)
  | Right raw <- chunk =
      let -- 0. Record what the host said about itself.
          ass0 = observeChunk raw ass
          -- 1. Apply field-based reasoning delta.
          (reasoningEvents, ass1) = applyReasoningDelta (raw ^. #reasoningDelta) ass0
          -- 2. Apply content delta (open text block if needed).
          (textEvents, ass2) = applyContentDelta (raw ^. #contentDelta) ass1
          -- 3. Apply tool-call deltas.
          (toolEvents, ass3) = applyToolDeltas (raw ^. #toolDeltas) ass2
          -- 4. Apply usage chunk if present.
          ass4 = applyUsage (raw ^. #usage) ass3
          -- 5. If finish_reason is set, close any open text/tool
          --    blocks and stash the reason. EventDone is deferred
          --    to channel close so the post-finish_reason usage
          --    chunk has a chance to land.
          (closeEvents, ass5) = case raw ^. #finishReason of
            Just fr -> closeOnFinish fr ass4
            Nothing -> ([], ass4)
       in (reasoningEvents <> textEvents <> toolEvents <> closeEvents, ass5)

-- | Record what the host reported about itself on this chunk.
--
-- Both values come from the /first/ chunk that carries them and are
-- never overwritten. Compatible hosts repeat both fields on every chunk
-- and they are expected to agree; a host where they disagree is a
-- genuine discovery worth recording rather than something to resolve
-- silently by last-write-wins.
--
-- A missing field means the host reported nothing, so the observation
-- stays 'Ev.Unobserved'. The configured model is never substituted —
-- that is the specific mistake 'Ev.Observed' exists to prevent.
observeChunk :: RawChunk -> Assembler -> Assembler
observeChunk raw ass =
  ass
    & #observedModel .~ firstObserved (ass ^. #observedModel) (raw ^. #model)
    & #responseId .~ ((ass ^. #responseId) <|> (raw ^. #responseId))

firstObserved :: Ev.Observed a -> Maybe a -> Ev.Observed a
firstObserved (Ev.Observed a) _ = Ev.Observed a
firstObserved Ev.Unobserved m = maybe Ev.Unobserved Ev.Observed m

applyReasoningDelta ::
  Maybe Text -> Assembler -> ([AssistantMessageEvent], Assembler)
applyReasoningDelta Nothing ass = ([], ass)
applyReasoningDelta (Just "") ass = ([], ass)
applyReasoningDelta (Just d) ass =
  case ass ^. #reasoningOpen of
    Just i ->
      ( [ThinkingDelta DeltaPayload {contentIndex = i, delta = d}],
        ass & #reasoningAccum %~ (<> d)
      )
    Nothing ->
      let i = ass ^. #nextContentIndex
       in ( [ThinkingStart IndexPayload {contentIndex = i}, ThinkingDelta DeltaPayload {contentIndex = i, delta = d}],
            ass
              & #reasoningOpen .~ Just i
              & #reasoningAccum .~ d
              & #nextContentIndex .~ (i + 1)
          )

applyContentDelta ::
  Maybe Text -> Assembler -> ([AssistantMessageEvent], Assembler)
applyContentDelta Nothing ass = ([], ass)
applyContentDelta (Just "") ass = ([], ass)
applyContentDelta (Just d) ass =
  if requiresThinkingAsText (openaiCompletionsCompatFor (ass ^. #model))
    then
      let (tagState', parts) = scanThinkTags (ass ^. #tagScanState) d
          (events, ass') = foldl' applyTaggedPart ([], ass & #tagScanState .~ tagState') parts
       in (events, ass')
    else applyVisibleTextDelta d ass

applyTaggedPart ::
  ([AssistantMessageEvent], Assembler) ->
  Either Text Text ->
  ([AssistantMessageEvent], Assembler)
applyTaggedPart (acc, ass) = \case
  Left reasoning ->
    let (events, ass') = applyReasoningDelta (Just reasoning) ass
     in (acc <> events, ass')
  Right visible ->
    let (events, ass') = applyVisibleTextDelta visible ass
     in (acc <> events, ass')

applyVisibleTextDelta ::
  Text -> Assembler -> ([AssistantMessageEvent], Assembler)
applyVisibleTextDelta "" ass = ([], ass)
applyVisibleTextDelta d ass =
  case ass ^. #textOpen of
    Just i ->
      let (reasoningEvents, ass1) = closeOpenReasoning ass
       in ( reasoningEvents <> [TextDelta DeltaPayload {contentIndex = i, delta = d}],
            ass1 & #textAccum %~ (<> d)
          )
    Nothing ->
      let (reasoningEvents, ass1) = closeOpenReasoning ass
          i = ass1 ^. #nextContentIndex
       in ( reasoningEvents <> [TextStart IndexPayload {contentIndex = i}, TextDelta DeltaPayload {contentIndex = i, delta = d}],
            ass1
              & #textOpen .~ Just i
              & #textAccum .~ d
              & #textEverOpened .~ True
              & #nextContentIndex .~ (i + 1)
          )

applyToolDeltas ::
  [RawToolDelta] -> Assembler -> ([AssistantMessageEvent], Assembler)
applyToolDeltas [] ass = ([], ass)
applyToolDeltas deltas ass =
  let (reasoningEvents, ass0) = closeOpenReasoning ass
      (toolEvents, ass') = foldl' apply ([], ass0) deltas
   in (reasoningEvents <> toolEvents, ass')
  where
    apply (acc, a) d =
      let (events, a') = applyOneToolDelta d a
       in (acc <> events, a')

applyOneToolDelta ::
  RawToolDelta -> Assembler -> ([AssistantMessageEvent], Assembler)
applyOneToolDelta d ass =
  let mOpenaiIdx = d ^. #index
      mToolId = d ^. #id_
      byIndex = mOpenaiIdx >>= \idx -> IntMap.lookup idx (ass ^. #toolIndexMap)
      byId = mToolId >>= \tid -> Map.lookup tid (ass ^. #toolIdMap)
      byLast =
        case (mOpenaiIdx, mToolId) of
          (Nothing, Nothing) -> ass ^. #lastToolIdx
          _ -> Nothing
      (baikaiIdx, ass1, opened) = case byIndex <|> byId <|> byLast of
        Just i ->
          ( i,
            ass
              & #toolIdMap %~ maybe id (`Map.insert` i) mToolId
              & #lastToolIdx .~ Just i,
            False
          )
        Nothing ->
          let i = ass ^. #nextContentIndex
              ass' =
                ass
                  & #toolIndexMap %~ maybe id (`IntMap.insert` i) mOpenaiIdx
                  & #toolIdMap %~ maybe id (`Map.insert` i) mToolId
                  & #lastToolIdx .~ Just i
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
          Usage.cost = zeroCost
        }

applyUsage :: Maybe RawUsage -> Assembler -> Assembler
applyUsage Nothing ass = ass
applyUsage (Just u) ass =
  ass
    & #usage .~ rawUsageToUsage u
    -- A host that sent a usage block reported its counts, even if every
    -- one of them is zero. That is what distinguishes a reported zero
    -- from silence in the evidence record.
    & #usageReported .~ True

-- | Close all open content blocks and stash the resolved stop
-- reason; defer 'EventDone' to channel close.
closeOnFinish ::
  Text -> Assembler -> ([AssistantMessageEvent], Assembler)
closeOnFinish finishReason ass =
  let (tagEvents, ass0) = flushTagScanPending ass
      (closeReasoning, ass1) = closeOpenReasoning ass0
      (closeText, ass2) = closeOpenText ass1
      (closeTools, ass3) = closeOpenTools ass2
      (reason, note) = mapFinishReason finishReason
      pending =
        if reason == Stop.ErrorReason
          then Just (providerError ("provider stopped the response: finish_reason=" <> finishReason))
          else Nothing
      ass4 =
        ass3
          & #stopReason .~ reason
          & #finishSeen .~ True
          & #pendingError .~ pending
          & #finishNote .~ note
   in (tagEvents <> closeReasoning <> closeText <> closeTools, ass4)

flushTagScanPending :: Assembler -> ([AssistantMessageEvent], Assembler)
flushTagScanPending ass =
  let st = ass ^. #tagScanState
      pending = tagPending st
      ass0 = ass & #tagScanState .~ st {tagPending = Text.empty}
   in case (tagMode st, pending) of
        (_, "") -> ([], ass0)
        (TagVisible, t) -> applyVisibleTextDelta t ass0
        (TagReasoning, t) -> applyReasoningDelta (Just t) ass0

closeOpenReasoning :: Assembler -> ([AssistantMessageEvent], Assembler)
closeOpenReasoning ass = case ass ^. #reasoningOpen of
  Nothing -> ([], ass)
  Just i ->
    let body = ass ^. #reasoningAccum
        thinkingContent =
          Content.ThinkingContent
            { Content.thinking = body,
              Content.signature = Nothing,
              Content.redacted = False
            }
        block = Content.AssistantThinking thinkingContent
     in ( [ThinkingEnd ThinkingEndPayload {contentIndex = i, content = thinkingContent}],
          ass
            & #reasoningOpen .~ Nothing
            & #reasoningAccum .~ Text.empty
            & #closed %~ IntMap.insert i block
        )

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
              & #toolIdMap %~ (if Text.null tid then id else Map.delete tid)
              & #lastToolIdx .~ Nothing
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
            Just be -> EventError (errorTerminal Nothing (ass ^. #responseId) reason msg be)
            Nothing -> EventDone (doneTerminal Nothing (ass ^. #responseId) reason msg)
       in ([terminalEvent], ass)
  | otherwise =
      -- Channel closed without a finish_reason. Force-close any
      -- still-open blocks and emit EventError. When the worker stored a
      -- classified HTTP error ('Just be'), surface it structurally;
      -- otherwise report the unexpected end of stream.
      let (tagEvents, ass0) = flushTagScanPending ass
          (closeReasoning, ass1) = closeOpenReasoning ass0
          (closeText, ass2) = closeOpenText ass1
          (closeTools, ass3) = closeOpenTools ass2
          reason = Stop.ErrorReason
          errText = case mErr of
            Just be -> be ^. #message
            Nothing -> "openai stream ended without finish_reason"
          msg = finalMessage ass3 now (Just errText) reason
          errInfo = fromMaybe (providerError errText) mErr
          errEv = EventError (errorTerminal Nothing (ass3 ^. #responseId) reason msg errInfo)
       in (tagEvents <> closeReasoning <> closeText <> closeTools <> [errEv], ass3)

-- | The accumulated token counts with this model's price applied.
--
-- Shared by the assistant message and the evidence record so the two
-- cannot report different numbers for the same call.
finalUsage :: Assembler -> Usage.Usage
finalUsage ass =
  let usageBare = ass ^. #usage
   in usageBare & #cost .~ Pricing.computeCost (ass ^. #model) usageBare

finalMessage ::
  Assembler -> UTCTime -> Maybe Text -> Stop.StopReason -> Msg.Message
finalMessage ass now errMsg sr =
  let blocks = blocksInOrder ass
   in Msg.AssistantMessage
        Msg.AssistantPayload
          { Msg.content = blocks,
            Msg.usage = finalUsage ass,
            Msg.stopReason = sr,
            Msg.errorMessage = errMsg <|> (ass ^. #finishNote),
            Msg.timestamp = Just now
          }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (ass ^. #closed))

-- | Immediate error stream emitted when the request itself could not
-- be built (e.g. message mapping failed).
-- Nothing was sent, so there is no wire body to digest and the evidence
-- commits to 'Build.dispatchEnvelope' instead -- see its documentation.
immediateError :: Model -> Options -> BaikaiError -> IO [AssistantMessageEvent]
immediateError m opts err = do
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
  ev <-
    Build.minimalEvidence
      m
      opts
      Ev.TransportHttpApi
      Ev.noThinkingRequested
      (Build.dispatchEnvelope m opts)
      now
      now
      Ev.CallFailed
      (Just err)
  pure
    [ EventStart StartPayload {partial = msg, responseId = Nothing},
      EventError (errorTerminal ev Nothing Stop.ErrorReason msg err)
    ]

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
