-- | Native OpenAI Responses provider. Register explicitly alongside the
-- Chat Completions provider for a registry supporting both protocols.
module Baikai.Provider.OpenAI.Responses
  ( register,
    openaiResponsesProvider,
    openaiResponsesStream,
  )
where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.Context (Context)
import Baikai.Evidence qualified as Ev
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider (ApiProvider, apiProvider)
import Baikai.Provider.OpenAI.Responses.Request (describeThinking)
import Baikai.Provider.OpenAI.Responses.Stream (liveResponsesDriver, openaiResponsesStreamWith)
import Baikai.Provider.Registry (registerApiProvider)
import Baikai.Stream.Event (AssistantMessageEvent)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Streamly.Data.Stream (Stream)

register :: IO ()
register = registerApiProvider openaiResponsesProvider

-- | Completion folds the same event stream, as for other API providers.
openaiResponsesProvider :: ApiProvider
openaiResponsesProvider =
  apiProvider OpenAIResponses openaiResponsesStream
    & #describeThinking .~ describeThinking
    & #strengthCeiling .~ Ev.declaredStrength OpenAIResponses

openaiResponsesStream :: Model -> Context -> Options -> Stream IO AssistantMessageEvent
openaiResponsesStream = openaiResponsesStreamWith liveResponsesDriver
