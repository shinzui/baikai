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
    stubModel,
    stubContext,
    stubOptions,
    flattenAssistantText,
  )
where

import Baikai
import Baikai.Prelude
import Data.Vector qualified as V
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | The 'Api' tag the stub provider serves. A 'Custom' tag needs no catalog entry.
stubApi :: Api
stubApi = Custom "stub"

-- | A hand-built 'Model' whose 'api' routes to the stub provider.
stubModel :: Model
stubModel =
  _Model
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
stubContext = _Context & #messages .~ V.singleton (user "ping")

-- | Default request options.
stubOptions :: Options
stubOptions = _Options

-- | A blank assistant payload with a fixed (epoch) timestamp, reused as the base
-- for both the streaming skeleton and the terminal message so nothing varies run
-- to run. Borrowed from baikai's '_Response' fixture base.
stubPayload :: AssistantPayload
stubPayload = _Response ^. #message

-- | An assistant payload carrying the given text as its single text block.
stubPayloadWith :: Text -> AssistantPayload
stubPayloadWith t =
  stubPayload & #content .~ V.singleton (AssistantText (_TextContent & #text .~ t))

-- | A fixed assistant response carrying the given text as its single text block.
stubResponse :: Text -> Response
stubResponse t =
  _Response
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
    EventDone (doneTerminal Nothing Stop (AssistantMessage (stubPayloadWith t)))
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
    ApiProvider
      { apiTag = stubApi,
        complete = stubComplete t,
        stream = stubStream t
      }
  pure reg
