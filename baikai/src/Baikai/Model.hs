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
    Model,
    modelId,
    name,
    api,
    provider,
    baseUrl,
    reasoning,
    input,
    cost,
    contextWindow,
    maxOutputTokens,
    headers,
    compat,
    emptyModel,
    _Model,
    mkModel,

    -- * Cost rates
    ModelCost (..),
    zeroModelCost,
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
import Baikai.Auth qualified as Auth
import Baikai.Compat
  ( AnthropicMessagesCompat (..),
    OpenAICompletionsCompat,
    autoDetectAnthropicMessages,
    autoDetectOpenAICompletions,
    defaultAnthropicThinkingStyle,
  )
import Data.Aeson
  ( FromJSON,
    ToJSON (toEncoding, toJSON),
    defaultOptions,
    genericToEncoding,
    genericToJSON,
  )
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
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON)

-- | Rendered field by field rather than derived, so that the value of a
-- credential-carrying header prints as 'Auth.redactedMarker'. A 'Model'
-- is the record most likely to reach a log: it is embedded in every
-- 'Baikai.Response.Response', and the guides tell people to @print@
-- one.
--
-- The format is exactly what @deriving stock Show@ produces — the same
-- record syntax, field order and precedence — because the point is to
-- redact one value, not to invent a rendering. A test in
-- @baikai\/test\/Main.hs@ walks the 'Generic' representation and asserts
-- that every field name appears here, so a field added later cannot
-- silently vanish from 'show'.
--
-- 'Eq' is untouched, and so is 'FromJSON': the field itself still holds
-- what the caller put there and the header is still sent. The one lossy
-- path is a JSON round trip — 'toJSON' writes the marker, so decoding
-- the result gives a 'Model' whose credential header /is/ the marker.
-- That is deliberate; a serialised 'Model' is exactly the thing that
-- should not carry a key.
instance Show Model where
  showsPrec d m =
    showParen (d >= 11) $
      showString "Model {"
        . field "modelId" (modelId m)
        . next "name" (name m)
        . next "api" (api m)
        . next "provider" (provider m)
        . next "baseUrl" (baseUrl m)
        . next "reasoning" (reasoning m)
        . next "input" (input m)
        . next "cost" (cost m)
        . next "contextWindow" (contextWindow m)
        . next "maxOutputTokens" (maxOutputTokens m)
        . next "headers" (Auth.redactHeaderValues (headers m))
        . next "compat" (compat m)
        . showChar '}'
    where
      field label v = showString label . showString " = " . showsPrec 0 v
      next label v = showString ", " . field label v

-- | Encoded through the 'Generic' representation of a copy whose
-- credential headers have been replaced, so the output is byte-identical
-- to the derived instance's for every model that carries none, and there
-- is no recursion back into this instance.
instance ToJSON Model where
  toJSON = genericToJSON defaultOptions . redactModel
  toEncoding = genericToEncoding defaultOptions . redactModel

redactModel :: Model -> Model
redactModel m = m {headers = Auth.redactHeaderValues (headers m)}

-- | A zero 'ModelCost' across all rates. Useful as a default for
-- models without published pricing (CLI providers, custom hosts).
zeroModelCost :: ModelCost
zeroModelCost =
  ModelCost
    { inputCost = 0,
      outputCost = 0,
      cacheReadCost = 0,
      cacheWriteCost = 0
    }

-- | A blank 'Model'. Useful as a record-update base for hand-rolled
-- 'Model' values in tests and one-shot scripts.
emptyModel :: Model
emptyModel =
  Model
    { modelId = "",
      name = "",
      api = Custom "",
      provider = "",
      baseUrl = "",
      reasoning = False,
      input = [InputText],
      cost = zeroModelCost,
      contextWindow = 0,
      maxOutputTokens = 0,
      headers = Map.empty,
      compat = CompatNone
    }

-- | Build a dispatchable 'Model' from its three discriminators: the
-- 'Api' tag used for handler lookup, the upstream model id, and the
-- base URL. 'name' defaults to the model id, 'provider' defaults to
-- 'renderApi' of the tag, and all other fields come from 'emptyModel'.
mkModel :: Api -> Text -> Text -> Model
mkModel apiTag modelId_ baseUrl_ =
  emptyModel
    { modelId = modelId_,
      name = modelId_,
      api = apiTag,
      provider = renderApi apiTag,
      baseUrl = baseUrl_
    }

{-# DEPRECATED _ModelCost "Use zeroModelCost instead." #-}
_ModelCost :: ModelCost
_ModelCost = zeroModelCost

{-# DEPRECATED _Model "Use emptyModel instead." #-}
_Model :: Model
_Model = emptyModel
