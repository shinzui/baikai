-- | A hand-rolled, network-free baikai provider used by the hermetic tests.
--
-- It builds an isolated 'ProviderRegistry' (never the global one) whose single
-- 'ApiProvider' serves a known 'Api' tag. The provider's @complete@ returns a
-- fixed 'Response' carrying caller-chosen text; its @stream@ is synthesized from
-- that same @complete@ via 'liftCompleteToStream', so the event sequence is a
-- valid @EventStart … TextDelta … EventDone@ run carrying the same text.
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
import Data.Text qualified as T
import Data.Vector qualified as V

-- | Concatenate the text of every 'AssistantText' block, ignoring thinking and
-- tool-call blocks. baikai has no library equivalent — its own smoke tests define
-- this same helper locally (see @baikai-smoke/test/Smoke.hs@).
flattenAssistantText :: V.Vector AssistantContent -> Text
flattenAssistantText = T.concat . V.toList . V.mapMaybe textOf
  where
    textOf (AssistantText (TextContent t)) = Just t
    textOf _ = Nothing

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

-- | A fixed assistant response carrying the given text as its single text block.
stubResponse :: Text -> Response
stubResponse t =
  _Response
    & #message
    . #content
    .~ V.singleton (AssistantText (_TextContent & #text .~ t))
    & #model
    .~ stubModel
    & #api
    .~ stubApi
    & #provider
    .~ "stub"

-- | The provider's blocking completion: ignore the request, return fixed text.
stubComplete :: Text -> Model -> Context -> Options -> IO Response
stubComplete t _ _ _ = pure (stubResponse t)

-- | Build an isolated registry whose stub provider's @complete@ returns @t@.
stubRegistry :: Text -> IO ProviderRegistry
stubRegistry t = do
  reg <- newProviderRegistry
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = stubApi,
        complete = stubComplete t,
        stream = liftCompleteToStream (stubComplete t)
      }
  pure reg
