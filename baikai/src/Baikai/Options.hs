-- | The 'Options' record — the per-call knobs that vary between
-- requests on the same conversation.
--
-- 'apiKey' is 'Nothing' by default; the registered handler then
-- consults a provider-specific env var
-- (@ANTHROPIC_API_KEY@ for Anthropic, @OPENAI_API_KEY@ for OpenAI).
-- 'maxTokens' defaults to 'Nothing'; the handler falls back to the
-- chosen model's 'Baikai.Model.maxOutputTokens'.
--
-- EP-4 added @toolChoice@. EP-5 adds @cacheRetention@ and @thinking@
-- (provider-agnostic preferences that each provider maps to its own
-- primitive — see 'Baikai.CacheRetention' and 'Baikai.ThinkingLevel'
-- for the mappings).
module Baikai.Options
  ( Options (..),
    _Options,
  )
where

import Baikai.Auth (ApiKeySource)
import Baikai.CacheRetention (CacheRetention)
import Baikai.ThinkingLevel (ThinkingLevel)
import Baikai.Tool (ToolChoice)
import Data.Aeson (ToJSON, Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Options = Options
  { maxTokens :: !(Maybe Natural),
    temperature :: !(Maybe Double),
    apiKey :: !(Maybe ApiKeySource),
    timeoutMs :: !(Maybe Int),
    headers :: !(Map Text Text),
    metadata :: !(Map Text Value),
    toolChoice :: !(Maybe ToolChoice),
    cacheRetention :: !(Maybe CacheRetention),
    thinking :: !(Maybe ThinkingLevel)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

_Options :: Options
_Options =
  Options
    { maxTokens = Nothing,
      temperature = Nothing,
      apiKey = Nothing,
      timeoutMs = Nothing,
      headers = Map.empty,
      metadata = Map.empty,
      toolChoice = Nothing,
      cacheRetention = Nothing,
      thinking = Nothing
    }
