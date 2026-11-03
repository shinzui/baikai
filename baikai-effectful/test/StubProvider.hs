-- | A hand-rolled, network-free baikai provider used by the hermetic tests.
--
-- It builds an isolated 'ProviderRegistry' (never the global one) whose single
-- 'ApiProvider' serves a known 'Api' tag. The provider's @complete@ returns a
-- fixed 'Response' carrying caller-chosen text; its @stream@ emits a fixed,
-- deterministic @EventStart … TextDelta … EventDone@ sequence carrying the same
-- text. The stream is hand-rolled (rather than synthesized from @complete@ via
-- 'liftCompleteToStream') so it carries no wall-clock timestamp — two separate
-- stream runs produce byte-identical event lists, which the streamEach/streamCollect
-- agreement test depends on.
module StubProvider
  ( stubRegistry,
    evidenceRegistry,
    blockingRegistry,
    stubModel,
    stubContext,
    stubOptions,
    flattenAssistantText,
  )
where

import Baikai
import Baikai.Evidence.Build qualified as Build
import Baikai.Prelude
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar)
import Control.Exception (finally)
import Control.Monad (forever)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Time (getCurrentTime)
import Data.Vector qualified as V
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | The 'Api' tag the stub provider serves. A 'Custom' tag needs no catalog entry.
stubApi :: Api
stubApi = Custom "stub"

-- | A hand-built 'Model' whose 'api' routes to the stub provider.
stubModel :: Model
stubModel =
  emptyModel
    & #api
    .~ stubApi
    & #modelId
    .~ "stub-model"
    & #name
    .~ "stub"
    & #provider
    .~ "stub"

-- | A minimal request context (one user turn).
stubContext :: Context
stubContext = emptyContext & #messages .~ V.singleton (user "ping")

-- | Default request options.
stubOptions :: Options
stubOptions = emptyOptions

-- | A blank assistant payload with a fixed (epoch) timestamp, reused as the base
-- for both the streaming skeleton and the terminal message so nothing varies run
-- to run. Borrowed from baikai's 'emptyResponse' fixture base.
stubPayload :: AssistantPayload
stubPayload = emptyResponse ^. #message

-- | An assistant payload carrying the given text as its single text block.
stubPayloadWith :: Text -> AssistantPayload
stubPayloadWith t =
  stubPayload & #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ t))

-- | A fixed assistant response carrying the given text as its single text block.
stubResponse :: Text -> Response
stubResponse t =
  emptyResponse
    & #message
    .~ stubPayloadWith t
    & #model
    .~ stubModel
    & #api
    .~ stubApi
    & #provider
    .~ "stub"

-- | The provider's blocking completion: ignore the request, return fixed text.
stubComplete :: Text -> Model -> Context -> Options -> IO Response
stubComplete t _ _ _ = pure (stubResponse t)

-- | A deterministic, valid event sequence for the given text: exactly one
-- 'EventStart' first, one text block, and one 'EventDone' last.
stubEvents :: Text -> [AssistantMessageEvent]
stubEvents t =
  [ EventStart StartPayload {partial = AssistantMessage stubPayload, responseId = Nothing},
    TextStart IndexPayload {contentIndex = 0},
    TextDelta DeltaPayload {contentIndex = 0, delta = t},
    TextEnd BlockEndPayload {contentIndex = 0, content = t},
    EventDone (doneTerminal Nothing Nothing Stop (AssistantMessage (stubPayloadWith t)))
  ]

-- | The provider's streaming completion: ignore the request, emit fixed events.
stubStream :: Text -> Model -> Context -> Options -> Stream IO AssistantMessageEvent
stubStream t _ _ _ = Stream.fromList (stubEvents t)

-- | Build an isolated registry whose stub provider returns/streams @t@.
stubRegistry :: Text -> IO ProviderRegistry
stubRegistry t = do
  reg <- newProviderRegistry
  registerApiProviderWith
    reg
    ( apiProviderWith
        stubApi
        (stubStream t)
        (stubComplete t)
    )
  pure reg

-- | An evidence-aware fixture. Counts actual dispatches, so refusal tests can
-- distinguish a core refusal from an error emitted by the provider.
evidenceRegistry :: Bool -> IO (ProviderRegistry, IO Int)
evidenceRegistry failCall = do
  counter <- newIORef 0
  reg <- newProviderRegistry
  let handler m _ opts = do
        modifyIORef' counter (+ 1)
        now <- getCurrentTime
        let err = if failCall then Just (providerError "fixture failure") else Nothing
        ev <-
          Build.minimalEvidence
            m
            opts
            (Build.transportForModel m)
            (Build.requestedTranslation opts)
            (Build.dispatchEnvelope m opts)
            now
            now
            (if failCall then CallFailed else CallSucceeded)
            err
        pure
          ( stubResponse "evidence"
              & #evidence
              .~ ev
              & #errorInfo
              .~ err
              & #message
              . #stopReason
              .~ (if failCall then ErrorReason else Stop)
              & #message
              . #errorMessage
              .~ fmap (^. #message) err
          )
  registerApiProviderWith reg (apiProviderWith stubApi (liftCompleteToStream handler) handler)
  pure (reg, readIORef counter)

-- | Block inside provider execution until cancelled; the cleanup barrier proves
-- the provider was released before the caller handles its exception.
blockingRegistry :: IO (ProviderRegistry, MVar (), MVar ())
blockingRegistry = do
  entered <- newEmptyMVar
  released <- newEmptyMVar
  reg <- newProviderRegistry
  let handler _ _ _ = do
        putMVar entered ()
        (forever (threadDelay 1000000)) `finally` putMVar released ()
  registerApiProviderWith reg (apiProviderWith stubApi (liftCompleteToStream handler) handler)
  pure (reg, entered, released)
