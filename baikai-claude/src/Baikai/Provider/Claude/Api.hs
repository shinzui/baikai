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
    claudeMessagesStreamWith,
    SseDriver,
    anthropicStrength,
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
import Baikai.Evidence qualified as Ev
import Baikai.Evidence.Build qualified as Build
import Baikai.Message qualified as Msg
import Baikai.Model (Model, anthropicMessagesCompatFor)
import Baikai.Options (Options (..))
import Baikai.Provider.Claude.Internal.ErrorClass (classifyErrorValue, classifyException)
import Baikai.Provider.Claude.Internal.Request (describeThinkingFor, mapRequest)
import Baikai.Provider.Claude.Shape (streamRequestBody)
import Baikai.Provider.Claude.Sse (claudeSseStreamValueWithHeaders)
import Baikai.Provider.Claude.Sse qualified as Sse
import Baikai.Provider.Claude.Transport qualified as Transport
import Baikai.Provider.Internal.StreamWorker
  ( FrameQueue,
    newFrameQueue,
    pullFrame,
    pushFrame,
    withFrameWorker,
  )
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
import Baikai.Url qualified as Url
import Baikai.Usage qualified as Usage
import Claude.V1.Messages qualified as Messages
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Lens ((%~), (&), (.~), (^.))
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
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
import Data.Version (showVersion)
import GHC.Generics (Generic)
import Network.HTTP.Types.Header (RequestHeaders)
import Paths_baikai_claude qualified as Paths
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
      complete = streamingComplete claudeMessagesStream,
      -- The same function 'mapRequest' uses, so the gate's answer and
      -- the wire's behaviour cannot disagree.
      describeThinking = describeThinkingFor
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
-- Forks one worker thread per call that drives the local Claude SSE
-- transport, pushing classified errors and typed
-- 'Messages.MessageStreamEvent' values onto a bounded
-- 'Baikai.Provider.Internal.StreamWorker.FrameQueue'. The returned
-- 'Stream' is a translator: it pulls raw events off that queue and emits
-- zero or more 'AssistantMessageEvent' values per upstream event,
-- beginning with exactly one 'EventStart' and terminating with exactly
-- one 'EventDone' or 'EventError'.
--
-- The queue is bounded at
-- 'Baikai.Provider.Internal.StreamWorker.frameQueueCapacity' frames, so
-- a consumer that stops pulling stops the socket read after at most that
-- many further frames rather than letting the worker drain a whole
-- generation nobody will read.
--
-- The worker runs under a bracket, so the connection comes back
-- immediately when the stream ends normally or when an exception reaches
-- the draining thread (@Ctrl-C@, 'System.Timeout.timeout', @cancel@),
-- and at the next major garbage collection when a consumer simply
-- abandons the stream. "Baikai.Provider.Internal.StreamWorker" documents
-- why those three strengths differ and how a caller stops
-- deterministically.
--
-- Producer-side exceptions (HTTP failure, decode failure inside the
-- SDK, etc.) are caught with 'try' and re-encoded into an
-- 'EventError' carrying whatever content was already assembled —
-- the masterplan's "partial output is always recoverable" promise.
claudeMessagesStream ::
  Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStream = claudeMessagesStreamWith liveSseDriver

-- | How a call physically reaches Anthropic.
--
-- Production passes 'liveSseDriver'. A test passes one that replays a
-- recorded response through the same
-- 'Baikai.Provider.Claude.Sse.sseFromResponse' the live driver uses, so
-- header capture, status classification, and SSE frame decoding are all
-- the real implementations and only the socket is missing.
type SseDriver =
  ClaudeCall ->
  (Sse.ResponseMetadata -> IO ()) ->
  (Either BaikaiError Messages.MessageStreamEvent -> IO ()) ->
  IO ()

liveSseDriver :: SseDriver
liveSseDriver call =
  claudeSseStreamValueWithHeaders
    (call ^. #clientEnv)
    (call ^. #requestHeaders)
    (call ^. #requestBody)

-- | 'claudeMessagesStream' over an explicit transport driver.
claudeMessagesStreamWith ::
  SseDriver -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
claudeMessagesStreamWith driver m ctx opts =
  Stream.concatEffect $ do
    setupResult <- trySync (prepareCall m ctx opts)
    let setup = either (Left . exceptionToError) id setupResult
    case setup of
      Left err -> Stream.fromList <$> immediateError m opts err
      Right call -> do
        q <- newFrameQueue :: IO (FrameQueue (Either BaikaiError Messages.MessageStreamEvent))
        tref <- newIORef False
        mref <- newIORef Nothing
        startTime <- getCurrentTime
        -- The request body is the envelope the two digests commit to:
        -- it is exactly the JSON this call is about to put on the wire.
        -- Credentials are not in it — they travel in the headers built
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
                { chan = q,
                  -- Pre-seeded, exactly as the OpenAI producer does it,
                  -- so the first event reaches the consumer immediately
                  -- and carries the request-start timestamp, and so
                  -- every failure path is 'EventStart'-first without
                  -- per-path bookkeeping. Anthropic's message id is not
                  -- known yet; it rides the terminal's @responseId@,
                  -- which 'Baikai.Stream.reassembleResponse' prefers
                  -- anyway.
                  pending =
                    [ EventStart
                        StartPayload
                          { partial = skeletonMessage (emptyAssembler m startTime) startTime,
                            responseId = Nothing
                          }
                    ],
                  assembler = emptyAssembler m startTime,
                  finished = False,
                  terminalRef = tref,
                  metadataRef = mref,
                  evidence = mkEvidence
                }
        pure (withFrameWorker q (worker driver call mref q) (Stream.unfoldrM step initialState))

-- | Per-call prepared values, including the shaped JSON request body
-- passed to the local streaming transport.
data ClaudeCall = ClaudeCall
  { clientEnv :: !Client.ClientEnv,
    requestHeaders :: !RequestHeaders,
    timeoutMs :: !(Maybe Int),
    requestBody :: !Aeson.Value,
    -- | What the caller's reasoning-effort preference became on this
    -- request, as 'mapRequest' described it. Carried from here rather
    -- than recomputed at the terminal: only the request mapper knows
    -- the host compat lookup and the max-tokens interaction that
    -- produced it.
    thinking :: !Ev.ThinkingTranslation
  }
  deriving stock (Generic)

prepareCall ::
  Model -> Context -> Options -> IO (Either BaikaiError ClaudeCall)
prepareCall m ctx opts = do
  case mapRequest m ctx opts of
    Left e -> pure (Left (invalidRequest e))
    Right (req, translation) -> do
      let url = case m ^. #baseUrl of
            "" -> "https://api.anthropic.com"
            u -> u
          compat = anthropicMessagesCompatFor m
          version = Just "2023-06-01"
      -- Checked before the key is resolved, so a base URL baikai will
      -- not send to never causes a credential to be read out of the
      -- environment. The message names the problem and what to write
      -- instead; it renders the URL without its userinfo or query, so an
      -- error reaching a log cannot carry a key someone put in either.
      case Url.baseUrlProblem url of
        Just problem ->
          pure (Left (invalidRequest ("Model.baseUrl is not usable: " <> problem)))
        Nothing -> do
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
                    requestBody = body,
                    thinking = translation
                  }
            )

-- | Worker body: drive the SDK's typed callback, forwarding events onto
-- the frame queue. Any synchronous exception is converted into a
-- classified error frame so the consumer side can translate it through
-- the normal path.
--
-- Nothing here signals end-of-frames: that is the queue's closed flag,
-- set by 'Baikai.Provider.Internal.StreamWorker.forkFrameWorker''s
-- @finally@ however this body ends. A sentinel push would block on a
-- full queue, which is exactly the state a stopped consumer leaves
-- behind.
worker ::
  SseDriver ->
  ClaudeCall ->
  IORef (Maybe Sse.ResponseMetadata) ->
  FrameQueue (Either BaikaiError Messages.MessageStreamEvent) ->
  IO ()
worker driver call metaRef q = do
  r <-
    trySync $
      Transport.runWithTimeout (call ^. #timeoutMs) $
        driver
          call
          (writeIORef metaRef . Just)
          (pushFrame q)
  case r of
    Right Nothing -> pure ()
    Right (Just be) -> pushFrame q (Left be)
    Left e -> pushFrame q (Left (exceptionToError e))

-- | The streaming 'Stream' state.
data ProducerState = ProducerState
  { chan :: !(FrameQueue (Either BaikaiError Messages.MessageStreamEvent)),
    pending :: ![AssistantMessageEvent],
    assembler :: !Assembler,
    finished :: !Bool,
    terminalRef :: !(IORef Bool),
    -- | Where the worker leaves the response-level metadata it captured
    -- before the first event. Read on this side rather than pushed
    -- through 'chan' so the channel keeps carrying exactly one kind of
    -- thing; 'absorbMetadata' folds it into the assembler.
    metadataRef :: !(IORef (Maybe Sse.ResponseMetadata)),
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
      mRaw <- pullFrame (s ^. #chan)
      -- After the read, because the worker writes the metadata before it
      -- writes anything onto the channel: taking it here means every
      -- path out of this branch — including the one where the channel
      -- closed without ever producing an event — sees it.
      ass0 <- absorbMetadata (s ^. #metadataRef) (s ^. #assembler)
      let s' = s & #assembler .~ ass0
      case mRaw of
        Nothing -> do
          alreadyTerminal <- readIORef (s' ^. #terminalRef)
          if alreadyTerminal
            then pure Nothing
            else do
              now <- getCurrentTime
              let (ev, ass') = unexpectedEoS now ass0
              sealed <- sealTerminal (s' & #assembler .~ ass') ev
              pure
                ( Just
                    ( sealed,
                      s' & #assembler .~ ass' & #finished .~ True
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

-- | Mark the stream terminated and attach the call's evidence to the
-- terminal event.
--
-- Every event this producer yields goes through here, and the three
-- sites that can produce a terminal — a translated upstream event, a
-- queued event drained from 'pending', and the unexpected-end-of-stream
-- recovery — therefore all seal identically. Doing it here rather than
-- inside 'translate' keeps that function pure; evidence construction
-- needs 'IO' for the call identifier.
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
              record = observeAnthropic st (s ^. #assembler) (finish now st (errorOf ev))
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
-- Nothing here consults the request. An observation the provider did not
-- make stays 'Ev.Unobserved'.
observeAnthropic ::
  Ev.CallStatus -> Assembler -> Ev.ModelCallEvidence -> Ev.ModelCallEvidence
observeAnthropic st ass ev =
  ev
    & #endpoint . #implementationVersion .~ Just claudePackageVersion
    & #observedModel .~ (ass ^. #observedModel)
    & #providerRequestId .~ (ass ^. #providerRequestId)
    & #responseId .~ maybe Ev.Unobserved Ev.Observed (ass ^. #responseId)
    & #usage .~ observedUsage ass
    & #responseCommitment .~ responseCommitment st ass
    & #strength .~ anthropicStrength (ass ^. #observedModel) (ass ^. #providerRequestId)

-- | How much an Anthropic evidence record proves, derived only from
-- what was actually observed.
--
-- Anthropic does not echo the thinking configuration it applied, so
-- 'Ev.EvidenceFullyObserved' is unreachable on this transport. That is
-- a fact about Anthropic's response shape, not a gap to paper over: a
-- reasoning-token count corroborates output volume and says nothing
-- about which effort setting was in force.
--
-- A successful HTTP status deliberately does not raise the strength. A
-- 200 means the request was accepted, not that any particular model ran.
anthropicStrength :: Ev.Observed Text -> Ev.Observed Text -> Ev.EvidenceStrength
anthropicStrength observedModel providerRequestId =
  case (observedModel, providerRequestId) of
    (Ev.Observed _, Ev.Observed _) -> Ev.EvidenceModelObserved
    (_, Ev.Observed _) -> Ev.EvidenceCorrelated
    _ -> Ev.EvidenceRequestedOnly

-- | The token accounting, but only if Anthropic actually reported it.
--
-- The assembler initialises 'usage' to zeroes, so reporting it
-- unconditionally would tell a reader the provider said this call
-- consumed nothing — which for a call that failed before any usage
-- arrived is a fabrication, and exactly what 'Ev.Observed' exists to
-- stop.
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
-- identical responses split into different frames must produce the same
-- digest, and the frame boundaries are a transport detail no verifier
-- holding the response could reproduce.
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
claudePackageVersion :: Text
claudePackageVersion = Text.pack (showVersion Paths.version)

-- | Fold whatever response-level metadata the worker has captured into
-- the assembler.
--
-- Idempotent: applying it again overwrites the same fields with the same
-- values, which is what lets 'step' call it on every pass rather than
-- tracking whether it has run.
absorbMetadata :: IORef (Maybe Sse.ResponseMetadata) -> Assembler -> IO Assembler
absorbMetadata ref ass = do
  meta <- readIORef ref
  pure $ case meta of
    Nothing -> ass
    Just md ->
      ass
        & #httpStatus .~ Just (md ^. #httpStatus)
        & #providerRequestId .~ correlationId md

-- | Anthropic's correlation identifier for this response, or a
-- gateway's if Anthropic's own is absent.
--
-- The preference order is 'Sse.capturedHeaderNames' itself, so the
-- allow-list and the preference cannot disagree. Nothing is invented:
-- a response carrying none of those headers leaves this
-- 'Ev.Unobserved'.
correlationId :: Sse.ResponseMetadata -> Ev.Observed Text
correlationId md =
  case [v | n <- Sse.capturedHeaderNames, Just v <- [lookup (headerName n) (md ^. #headers)]] of
    (v : _) -> Ev.Observed v
    [] -> Ev.Unobserved
  where
    headerName = Text.decodeUtf8 . CI.foldedCase

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
--
-- The four fields below @stopReason@ are what this call /observed/, as
-- distinct from what it requested. They are kept here rather than
-- derived at the terminal because this record is the only state that
-- survives from the first event to the last, and because an observation
-- that never arrived must stay 'Ev.Unobserved' rather than falling back
-- to the caller's configuration.
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
    stopReason :: !Stop.StopReason,
    -- | Anthropic's own correlation identifier for this call, from the
    -- response headers.
    providerRequestId :: !(Ev.Observed Text),
    -- | The model identifier Anthropic reported running, from
    -- @message_start@. Never the configured model.
    observedModel :: !(Ev.Observed Text),
    -- | The response's HTTP status. Recorded because the transport has
    -- it; 'Baikai.Evidence.ModelCallEvidence' has no field for it, and
    -- inventing one is EP-1's decision to make, not this module's.
    httpStatus :: !(Maybe Int),
    -- | Whether Anthropic actually reported token counts, as opposed to
    -- 'usage' still holding the zeroes it was initialised with. Without
    -- this a failed call would claim the provider reported consuming
    -- nothing.
    usageReported :: !Bool
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
      stopReason = Stop.Stop,
      providerRequestId = Ev.Unobserved,
      observedModel = Ev.Unobserved,
      httpStatus = Nothing,
      usageReported = False
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
  -- Updates the assembler and emits nothing: the stream's one
  -- 'EventStart' was pre-seeded before the first wire read, so that a
  -- failure arriving before this frame — a 401, a rate limit, an
  -- in-band error event, an EOF — still begins the stream the way the
  -- protocol says every stream begins.
  Messages.Message_Start {Messages.message = mr} ->
    let usage0 = anthroUsageToBaikai (mr ^. #usage)
        ass' =
          ass
            & #responseId .~ Just (mr ^. #id)
            -- The provider's value, never the caller's. The SDK's
            -- @model@ field is not optional, so a @message_start@ that
            -- arrives at all is a genuine observation; a stream that
            -- fails before one arrives leaves this 'Ev.Unobserved'.
            & #observedModel .~ Ev.Observed (mr ^. #model)
            & #usage .~ usage0
            & #usageReported .~ True
     in ([], ass')
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
     in ([], ass & #stopReason .~ stopR & #usage .~ u' & #usageReported .~ True)
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

-- | The assembler's token accounting with this model's pricing applied.
-- Shared so the terminal message and the evidence record cannot report
-- two different figures for one call.
--
-- __Known limitation: cache writes are priced at one rate.__ Anthropic
-- bills a one-hour ('Baikai.CacheRetention.CacheRetentionLong') cache
-- write at roughly twice the five-minute rate, but the catalog carries a
-- single @cacheWriteCost@ — the five-minute one — and the SDK's
-- 'Messages.Usage' reports a single @cache_creation_input_tokens@ with
-- no per-TTL split (see 'anthroUsageToBaikai'). A long-retention write
-- is therefore /under-stated/ here. Token counts are unaffected; only
-- the dollar figure is low. Fixing it needs a second value carried off
-- the worker channel, a second field inside the evidence record, and a
-- second rate models.dev does not publish.
finalUsage :: Assembler -> Usage.Usage
finalUsage ass =
  let usageBare = ass ^. #usage
   in usageBare & #cost .~ Pricing.computeCost (ass ^. #model) usageBare

finalMessage :: Assembler -> UTCTime -> Msg.Message
finalMessage ass now =
  Msg.AssistantMessage
    Msg.AssistantPayload
      { Msg.content = blocksInOrder ass,
        Msg.usage = finalUsage ass,
        Msg.stopReason = ass ^. #stopReason,
        Msg.errorMessage = Nothing,
        Msg.timestamp = Just now
      }

finalMessageOnError :: Assembler -> UTCTime -> Text -> Msg.Message
finalMessageOnError ass now reason =
  Msg.AssistantMessage
    Msg.AssistantPayload
      { Msg.content = blocksInOrder ass,
        Msg.usage = finalUsage ass,
        Msg.stopReason = Stop.ErrorReason,
        Msg.errorMessage = Just reason,
        Msg.timestamp = Just now
      }

blocksInOrder :: Assembler -> Vector Content.AssistantContent
blocksInOrder ass = Vector.fromList (IntMap.elems (ass ^. #closed))

-- | The immediate "request invalid" stream — emitted when
-- 'mapRequest' fails or 'prepareCall' is otherwise unable to build
-- a valid SDK request.
-- | The immediate "request invalid" stream.
--
-- Nothing was sent, so there is no wire body to digest and the evidence
-- commits to 'Build.dispatchEnvelope' instead — see its documentation.
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
--
-- @cache_creation_input_tokens@ is one number covering both cache-write
-- TTLs. The SDK's 'Messages.Usage' has no per-TTL breakdown, so baikai
-- cannot tell a five-minute write from a one-hour one and prices both at
-- the catalog's single @cacheWriteCost@; see 'finalUsage' and
-- @docs\/user\/prompt-caching.md@.
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
