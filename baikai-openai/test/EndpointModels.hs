-- | Explicit Chat capability fixture, independent of catalog routing.
module EndpointModels (chatRestrictedModel) where

import Baikai
import Control.Lens ((&), (.~))

chatRestrictedModel :: Model
chatRestrictedModel =
  emptyModel
    & #api .~ OpenAIChatCompletions
    & #provider .~ "openai"
    & #modelId .~ "restricted-chat-model"
    & #reasoning .~ True
    & #compat
      .~ CompatOpenAICompletions
        ( defaultOpenAICompletionsCompat
            & #supportsToolCalls .~ False
            & #supportsSamplingParameters .~ False
            & #supportedReasoningEfforts .~ Just [ThinkingLow, ThinkingMedium, ThinkingHigh, ThinkingXHigh, ThinkingMax]
        )
