module Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),

    -- * Smart constructors
    providerError,
    invalidRequest,
    decodeError,
    processError,
    rateLimited,
    authError,
    providerUnavailable,

    -- * Accessors
    isRetryable,

    -- * Pure classification helpers for provider packages
    classifyHttpStatus,
    classifyHttpStatusWithBody,
    bodyIndicatesOverflow,
  )
where

import Control.Exception (Exception (displayException))
import Data.Aeson
  ( Options (constructorTagModifier, fieldLabelModifier),
    ToJSON (toJSON),
    camelTo2,
    defaultOptions,
    genericToJSON,
  )
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | A provider-neutral category for a failed call. Callers switch on
-- this to decide policy (retry, surface to user, abort). The set is
-- closed and stable; new HTTP nuances map onto an existing member
-- rather than growing this type.
data ErrorCategory
  = -- | Authentication/authorization failure: missing or rejected
    -- credentials (HTTP 401/403, or a missing API-key env var).
    AuthError
  | -- | The provider rate-limited the request (HTTP 429). Usually
    -- retryable after a delay; see 'retryAfterSeconds'.
    RateLimited
  | -- | The request exceeded the model's context window or a related
    -- size limit. Not retryable as-is; the caller must shrink input.
    ContextOverflow
  | -- | The request was malformed or otherwise rejected as invalid
    -- (HTTP 400/404/422). Not retryable without changes.
    InvalidRequest
  | -- | A transient server-side or network failure (HTTP 408/5xx, or a
    -- connection error). Safe to retry, ideally with backoff.
    TransientError
  | -- | The response could not be decoded/parsed into the expected
    -- shape.
    DecodeFailure
  | -- | A subprocess (the @claude -p@ or @codex exec@ CLI provider)
    -- exited non-zero. The exit code is in 'exitCode'.
    ProcessFailure
  | -- | No provider handler was registered for the model's API tag.
    ProviderUnavailable
  | -- | Anything not covered above.
    OtherError
  deriving stock (Eq, Show, Generic)

-- | Categories serialize as snake_case strings (e.g. @"rate_limited"@).
instance ToJSON ErrorCategory where
  toJSON =
    genericToJSON
      defaultOptions {constructorTagModifier = camelTo2 '_'}

-- | A failed baikai call. The 'category' drives caller policy; the
-- remaining fields carry optional structured hints. No record-field
-- prefixes (project convention): fields are plain names.
data BaikaiError = BaikaiError
  { category :: !ErrorCategory,
    -- | Human-readable detail, safe to log.
    message :: !Text,
    -- | The HTTP status code, when the failure came from an HTTP call.
    httpStatus :: !(Maybe Int),
    -- | Seconds to wait before retrying, parsed from a @Retry-After@
    -- header when present and integer-valued.
    retryAfterSeconds :: !(Maybe Int),
    -- | The subprocess exit code, for 'ProcessFailure'.
    exitCode :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

-- | Fields serialize as snake_case (e.g. @http_status@, @retry_after_seconds@).
instance ToJSON BaikaiError where
  toJSON =
    genericToJSON
      defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance Exception BaikaiError where
  displayException e =
    "BaikaiError(" <> show (category e) <> "): " <> Text.unpack (message e)

-- | Base value with everything absent; used by smart constructors.
baseError :: ErrorCategory -> Text -> BaikaiError
baseError c m =
  BaikaiError
    { category = c,
      message = m,
      httpStatus = Nothing,
      retryAfterSeconds = Nothing,
      exitCode = Nothing
    }

-- Smart constructors. These keep call sites close to the old API: an
-- old @ProviderError "x"@ becomes @providerError "x"@, etc.

-- | A generic provider failure with no further classification.
providerError :: Text -> BaikaiError
providerError = baseError OtherError

-- | A request rejected as invalid.
invalidRequest :: Text -> BaikaiError
invalidRequest = baseError InvalidRequest

-- | A response that failed to decode.
decodeError :: Text -> BaikaiError
decodeError = baseError DecodeFailure

-- | A subprocess that exited non-zero. First argument is the exit code.
processError :: Int -> Text -> BaikaiError
processError code m = (baseError ProcessFailure m) {exitCode = Just code}

-- | A rate-limit failure with an optional retry-after hint (seconds).
rateLimited :: Maybe Int -> Text -> BaikaiError
rateLimited secs m =
  (baseError RateLimited m) {retryAfterSeconds = secs, httpStatus = Just 429}

-- | An authentication/authorization or credential-configuration failure.
authError :: Text -> BaikaiError
authError = baseError AuthError

-- | No provider handler registered for a model's API tag.
providerUnavailable :: Text -> BaikaiError
providerUnavailable = baseError ProviderUnavailable

-- | Whether the application may sensibly retry this error. True for
-- rate limits and transient server/network failures; False otherwise.
-- (Note: 'retryAfterSeconds' may still be 'Nothing' even when this is
-- True, meaning "retryable but no server-suggested delay".)
isRetryable :: BaikaiError -> Bool
isRetryable e = case category e of
  RateLimited -> True
  TransientError -> True
  _ -> False

-- | Map an HTTP status code (and an optional already-parsed
-- retry-after-seconds value) to a category. Pure and network-free so it
-- can be unit-tested in the core package; provider packages call it
-- after extracting the status from their SDK's exception type.
--
-- The body of a 400 may indicate a context-window overflow, but this
-- helper only sees the status code; callers that can inspect the body
-- should special-case overflow before falling back here.
classifyHttpStatus :: Int -> Maybe Int -> ErrorCategory
classifyHttpStatus status _retryAfter
  | status == 401 || status == 403 = AuthError
  | status == 429 = RateLimited
  | status == 408 = TransientError
  | status == 400 || status == 404 || status == 422 = InvalidRequest
  | status >= 500 = TransientError
  | otherwise = OtherError

-- | Like 'classifyHttpStatus', but also inspects the response body so a
-- 400/422 whose body signals a context-window overflow is categorised
-- as 'ContextOverflow' rather than the plain 'InvalidRequest' the status
-- alone would give. All other statuses defer to 'classifyHttpStatus'.
classifyHttpStatusWithBody :: Int -> Maybe Int -> Text -> ErrorCategory
classifyHttpStatusWithBody status retryAfter body
  | (status == 400 || status == 422) && bodyIndicatesOverflow body =
      ContextOverflow
  | otherwise = classifyHttpStatus status retryAfter

-- | Whether an error body's text contains a known context-window
-- overflow marker (case-insensitive). Covers the phrasings used by the
-- Anthropic and OpenAI APIs.
bodyIndicatesOverflow :: Text -> Bool
bodyIndicatesOverflow body =
  any (`Text.isInfixOf` lower) markers
  where
    lower = Text.toLower body
    markers =
      [ "context length",
        "context_length_exceeded",
        "maximum context",
        "context window",
        "prompt is too long",
        "too many tokens",
        "request_too_large",
        "too many total text bytes"
      ]
