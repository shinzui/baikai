-- | A 'Model' is the data record callers hand to baikai when
-- dispatching a call. It carries everything baikai needs to know up
-- front to talk to a provider: the 'Api' tag (used to look up the
-- registered handler), the provider name, the base URL, the
-- per-million-token pricing rates, the context window and max output
-- cap, default per-call headers, and a per-API 'Compat' record (a
-- placeholder until EP-5 populates the real shims).
--
-- The previous newtype @Model = Model Text@ — a thin tag for the
-- model id — is retired. Use 'modelId' to read the selected upstream
-- model identifier, or 'mkModel' to build a dispatchable record.
module Baikai.Model
  ( -- * Model
    Model (..),
    _Model,
    mkModel,

    -- * Cost rates
    ModelCost (..),
    _ModelCost,

    -- * Capabilities
    InputModality (..),

    -- * Compatibility shim
    Compat (..),
    openaiCompletionsCompatFor,
    anthropicMessagesCompatFor,
  )
where

import Baikai.Api (Api (..), renderApi)
import Baikai.Compat
  ( AnthropicMessagesCompat (..),
    OpenAICompletionsCompat,
    autoDetectAnthropicMessages,
    autoDetectOpenAICompletions,
    defaultAnthropicThinkingStyle,
  )
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | What kinds of input a model accepts. EP-1 introduced the typed
-- content blocks; this field documents which of them the chosen
-- 'Model' is allowed to consume.
data InputModality
  = InputText
  | InputImage
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Per-million-token prices in USD as exact 'Rational' values.
data ModelCost = ModelCost
  { inputCost :: !Rational,
    outputCost :: !Rational,
    cacheReadCost :: !Rational,
    cacheWriteCost :: !Rational
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Per-API compatibility shim. 'CompatNone' tells the provider to
-- pick a sensible record by inspecting 'baseUrl'; the two real
-- constructors carry an explicit per-host record that overrides the
-- auto-detection. The records themselves live in 'Baikai.Compat' so
-- this module does not pull in every compat field as a transitive
-- dependency.
data Compat
  = CompatNone
  | CompatOpenAICompletions !OpenAICompletionsCompat
  | CompatAnthropicMessages !AnthropicMessagesCompat
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Project the 'OpenAICompletionsCompat' that applies to a 'Model':
-- the explicit one if 'compat' is 'CompatOpenAICompletions', otherwise
-- the result of inspecting 'baseUrl' via 'autoDetectOpenAICompletions'.
openaiCompletionsCompatFor :: Model -> OpenAICompletionsCompat
openaiCompletionsCompatFor m = case compat m of
  CompatOpenAICompletions c -> c
  _ -> autoDetectOpenAICompletions (baseUrl m)

-- | Project the 'AnthropicMessagesCompat' that applies to a 'Model':
-- the explicit one if 'compat' is 'CompatAnthropicMessages',
-- otherwise the result of inspecting 'baseUrl' via
-- 'autoDetectAnthropicMessages'.
anthropicMessagesCompatFor :: Model -> AnthropicMessagesCompat
anthropicMessagesCompatFor m = case compat m of
  CompatAnthropicMessages c -> c
  _ ->
    (autoDetectAnthropicMessages (baseUrl m))
      { thinkingStyle = defaultAnthropicThinkingStyle (modelId m)
      }

-- | The data record baikai dispatches on.
data Model = Model
  { modelId :: !Text,
    name :: !Text,
    api :: !Api,
    provider :: !Text,
    baseUrl :: !Text,
    reasoning :: !Bool,
    input :: ![InputModality],
    cost :: !ModelCost,
    contextWindow :: !Natural,
    maxOutputTokens :: !Natural,
    headers :: !(Map Text Text),
    compat :: !Compat
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A zero 'ModelCost' across all rates. Useful as a default for
-- models without published pricing (CLI providers, custom hosts).
_ModelCost :: ModelCost
_ModelCost =
  ModelCost
    { inputCost = 0,
      outputCost = 0,
      cacheReadCost = 0,
      cacheWriteCost = 0
    }

-- | A blank 'Model'. Useful as a record-update base for hand-rolled
-- 'Model' values in tests and one-shot scripts.
_Model :: Model
_Model =
  Model
    { modelId = "",
      name = "",
      api = Custom "",
      provider = "",
      baseUrl = "",
      reasoning = False,
      input = [InputText],
      cost = _ModelCost,
      contextWindow = 0,
      maxOutputTokens = 0,
      headers = Map.empty,
      compat = CompatNone
    }

-- | Build a dispatchable 'Model' from its three discriminators: the
-- 'Api' tag used for handler lookup, the upstream model id, and the
-- base URL. 'name' defaults to the model id, 'provider' defaults to
-- 'renderApi' of the tag, and all other fields come from '_Model'.
mkModel :: Api -> Text -> Text -> Model
mkModel apiTag modelId_ baseUrl_ =
  _Model
    { modelId = modelId_,
      name = modelId_,
      api = apiTag,
      provider = renderApi apiTag,
      baseUrl = baseUrl_
    }
