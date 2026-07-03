-- | The 'Options' record — the per-call knobs that vary between
-- requests on the same conversation.
--
-- 'apiKey' is 'Nothing' by default; API providers then consult the
-- host-specific env var from 'Baikai.Auth.defaultApiKeyEnvForBaseUrl'
-- after substituting their default base URL. Unknown hosts require an
-- explicit key source instead of falling back to another provider's
-- credential.
-- 'maxTokens' defaults to 'Nothing'; the handler falls back to the
-- chosen model's 'Baikai.Model.maxOutputTokens'.
-- 'topP' and 'stopSequences' are honored by the Anthropic and
-- OpenAI-compatible API providers. 'seed', 'frequencyPenalty', and
-- 'presencePenalty' are honored by the OpenAI-compatible API
-- provider. Providers with no corresponding upstream parameter
-- silently omit the field, matching the existing drop policy for
-- unsupported per-call knobs on CLI providers.
--
-- 'timeoutMs' is a wall-clock bound on the entire API streaming call
-- in the OpenAI and Claude providers: connection setup, response
-- headers, and full stream drain. On expiry the stream terminates
-- in-band with a retryable transient 'Baikai.Error.BaikaiError'.
--
-- 'headers' are per-call HTTP header overrides for API providers.
-- Provider defaults are built first, then 'Baikai.Model.headers',
-- then this field; later values replace earlier ones by
-- case-insensitive header name, including auth headers for callers
-- intentionally fronting a gateway.
--
-- EP-4 added @toolChoice@. EP-5 adds @cacheRetention@ and @thinking@
-- (provider-agnostic preferences that each provider maps to its own
-- primitive — see 'Baikai.CacheRetention' and 'Baikai.ThinkingLevel'
-- for the mappings). EP-2 (shikumi) adds @responseFormat@, the
-- provider-agnostic structured-output preference — see
-- 'Baikai.ResponseFormat'.
module Baikai.Options
  ( Options,
    maxTokens,
    temperature,
    apiKey,
    timeoutMs,
    headers,
    metadata,
    toolChoice,
    cacheRetention,
    thinking,
    responseFormat,
    topP,
    stopSequences,
    seed,
    frequencyPenalty,
    presencePenalty,
    emptyOptions,
    _Options,
  )
where

import Baikai.Auth (ApiKeySource)
import Baikai.CacheRetention (CacheRetention)
import Baikai.ResponseFormat (ResponseFormat)
import Baikai.ThinkingLevel (ThinkingLevel)
import Baikai.Tool (ToolChoice)
import Data.Aeson (ToJSON, Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector (Vector)
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
    thinking :: !(Maybe ThinkingLevel),
    responseFormat :: !(Maybe ResponseFormat),
    topP :: !(Maybe Double),
    stopSequences :: !(Maybe (Vector Text)),
    seed :: !(Maybe Integer),
    frequencyPenalty :: !(Maybe Double),
    presencePenalty :: !(Maybe Double)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

emptyOptions :: Options
emptyOptions =
  Options
    { maxTokens = Nothing,
      temperature = Nothing,
      apiKey = Nothing,
      timeoutMs = Nothing,
      headers = Map.empty,
      metadata = Map.empty,
      toolChoice = Nothing,
      cacheRetention = Nothing,
      thinking = Nothing,
      responseFormat = Nothing,
      topP = Nothing,
      stopSequences = Nothing,
      seed = Nothing,
      frequencyPenalty = Nothing,
      presencePenalty = Nothing
    }

{-# DEPRECATED _Options "Use emptyOptions instead." #-}
_Options :: Options
_Options = emptyOptions
