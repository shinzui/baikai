-- | A 'Model' is the data record callers hand to baikai when
-- dispatching a call. It carries everything baikai needs to know up
-- front to talk to a provider: the 'Api' tag (used to look up the
-- registered handler), the provider name, the base URL, the
-- per-million-token pricing rates, the context window and max output
-- cap, default per-call headers, and a per-API 'Compat' record (a
-- placeholder until EP-5 populates the real shims).
--
-- The previous newtype @Model = Model Text@ — a thin tag for the
-- model id — is retired. The 'unModel' accessor is preserved as a
-- convenience until callers fully migrate to 'modelId'.
module Baikai.Model
  ( -- * Model
    Model (..)
  , _Model
  , unModel

    -- * Cost rates
  , ModelCost (..)
  , _ModelCost

    -- * Capabilities
  , InputModality (..)

    -- * Compatibility shim
  , Compat (..)
  ) where

import Baikai.Api (Api (..))
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
  { inputCost :: !Rational
  , outputCost :: !Rational
  , cacheReadCost :: !Rational
  , cacheWriteCost :: !Rational
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Per-API compatibility shim. Currently only 'CompatNone' exists;
-- EP-5 introduces 'CompatOpenAICompletions' and
-- 'CompatAnthropicMessages' constructors.
data Compat
  = CompatNone
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The data record baikai dispatches on.
data Model = Model
  { modelId :: !Text
  , name :: !Text
  , api :: !Api
  , provider :: !Text
  , baseUrl :: !Text
  , reasoning :: !Bool
  , input :: ![InputModality]
  , cost :: !ModelCost
  , contextWindow :: !Natural
  , maxOutputTokens :: !Natural
  , headers :: !(Map Text Text)
  , compat :: !Compat
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The model id as 'Text'. Kept for ergonomic access from call
-- sites that previously held a newtype-wrapped 'Text'.
unModel :: Model -> Text
unModel = modelId

-- | A zero 'ModelCost' across all rates. Useful as a default for
-- models without published pricing (CLI providers, custom hosts).
_ModelCost :: ModelCost
_ModelCost =
  ModelCost
    { inputCost = 0
    , outputCost = 0
    , cacheReadCost = 0
    , cacheWriteCost = 0
    }

-- | A blank 'Model'. Useful as a record-update base for hand-rolled
-- 'Model' values in tests and one-shot scripts.
_Model :: Model
_Model =
  Model
    { modelId = ""
    , name = ""
    , api = Custom ""
    , provider = ""
    , baseUrl = ""
    , reasoning = False
    , input = [InputText]
    , cost = _ModelCost
    , contextWindow = 0
    , maxOutputTokens = 0
    , headers = Map.empty
    , compat = CompatNone
    }
