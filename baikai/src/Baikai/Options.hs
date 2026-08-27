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
-- intentionally fronting a gateway. Because that is an invitation to
-- put a credential here, the 'Show' and 'ToJSON' instances below print
-- 'Baikai.Auth.redactedMarker' in place of the value of any header
-- whose name looks credential-carrying. The field itself is untouched
-- and the header is still sent exactly as written.
--
-- EP-4 added @toolChoice@. EP-5 adds @cacheRetention@ and @thinking@
-- (provider-agnostic preferences that each provider maps to its own
-- primitive — see 'Baikai.CacheRetention' and 'Baikai.ThinkingLevel'
-- for the mappings). EP-2 (shikumi) adds @responseFormat@, the
-- provider-agnostic structured-output preference — see
-- 'Baikai.ResponseFormat'.
--
-- 'evidence' is the per-call request for verifiable model-call
-- evidence — see 'Baikai.Evidence.EvidenceRequest'. It carries the
-- caller's run identifier and how strictly they need the evidence.
-- A call whose 'evidence' is 'Nothing', which is every call that does
-- not opt in, behaves exactly as it did before the field existed: no
-- digest is computed, no evidence is emitted, and the trace output is
-- unchanged.
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
    evidence,
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
import Baikai.Auth qualified as Auth
import Baikai.CacheRetention (CacheRetention)
import Baikai.Evidence (EvidenceRequest)
import Baikai.ResponseFormat (ResponseFormat)
import Baikai.ThinkingLevel (ThinkingLevel)
import Baikai.Tool (ToolChoice)
import Data.Aeson
  ( ToJSON (toEncoding, toJSON),
    Value,
    defaultOptions,
    genericToEncoding,
    genericToJSON,
  )
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
    evidence :: !(Maybe EvidenceRequest),
    topP :: !(Maybe Double),
    stopSequences :: !(Maybe (Vector Text)),
    seed :: !(Maybe Integer),
    frequencyPenalty :: !(Maybe Double),
    presencePenalty :: !(Maybe Double)
  }
  deriving stock (Eq, Generic)

-- | Rendered field by field rather than derived, so that the value of a
-- credential-carrying header prints as 'Auth.redactedMarker'.
--
-- The format is exactly what @deriving stock Show@ produces — the same
-- record syntax, the same field order, the same @showsPrec@ precedence
-- — because the point is to redact one value, not to invent a new
-- rendering. A test in @baikai\/test\/Main.hs@ walks the 'Generic'
-- representation and asserts that every field name appears here, so a
-- field added later cannot silently vanish from 'show'.
--
-- 'Eq' is untouched: two 'Options' whose credential headers differ are
-- still unequal.
instance Show Options where
  showsPrec d o =
    showParen (d >= 11) $
      showString "Options {"
        . field "maxTokens" (maxTokens o)
        . next "temperature" (temperature o)
        . next "apiKey" (apiKey o)
        . next "timeoutMs" (timeoutMs o)
        . next "headers" (Auth.redactHeaderValues (headers o))
        . next "metadata" (metadata o)
        . next "toolChoice" (toolChoice o)
        . next "cacheRetention" (cacheRetention o)
        . next "thinking" (thinking o)
        . next "responseFormat" (responseFormat o)
        . next "evidence" (evidence o)
        . next "topP" (topP o)
        . next "stopSequences" (stopSequences o)
        . next "seed" (seed o)
        . next "frequencyPenalty" (frequencyPenalty o)
        . next "presencePenalty" (presencePenalty o)
        . showChar '}'
    where
      field name v = showString name . showString " = " . showsPrec 0 v
      next name v = showString ", " . field name v

-- | Encoded through the 'Generic' representation of a copy whose
-- credential headers have been replaced, so the output is byte-identical
-- to the derived instance's for every record that carries none, and
-- there is no recursion back into this instance.
instance ToJSON Options where
  toJSON = genericToJSON defaultOptions . redactOptions
  toEncoding = genericToEncoding defaultOptions . redactOptions

redactOptions :: Options -> Options
redactOptions o = o {headers = Auth.redactHeaderValues (headers o)}

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
      evidence = Nothing,
      topP = Nothing,
      stopSequences = Nothing,
      seed = Nothing,
      frequencyPenalty = Nothing,
      presencePenalty = Nothing
    }

{-# DEPRECATED _Options "Use emptyOptions instead." #-}
_Options :: Options
_Options = emptyOptions
