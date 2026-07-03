-- | The provider response envelope.
--
-- A 'Response' wraps the model's assistant payload ('message') with
-- metadata baikai owns: the originating 'Api' tag (now typed via
-- 'Baikai.Api'), the input 'Model' echoed back, the provider name,
-- an optional 'responseId', and the measured 'latencyMs'. The
-- 'message' carries only assistant content blocks, 'Usage' (with
-- 'Cost' embedded), 'StopReason', optional error text, and timestamp.
--
-- 'flattenAssistantBlocks' is a convenience accessor that flattens
-- the message's content blocks.
module Baikai.Response
  ( Response (..),
    _Response,
    responseMessage,
    flattenAssistantBlocks,
    responseError,
    errorResponse,
  )
where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent)
import Baikai.Error (BaikaiError, providerError)
import Baikai.Error qualified as Error
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model (..), _Model)
import Baikai.Model qualified as Model
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (_Usage)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data Response = Response
  { -- | Assistant-only payload returned by the provider.
    message :: !AssistantPayload,
    model :: !Model,
    api :: !Api,
    provider :: !Text,
    responseId :: !(Maybe Text),
    latencyMs :: !Integer,
    -- | Structured error detail when the call failed in-band
    -- (@stopReason = ErrorReason@): the category, HTTP status, and any
    -- retry-after hint. 'Nothing' on success or when the provider could
    -- not classify the failure. Lets a caller branch on
    -- 'Baikai.Error.category' / 'Baikai.Error.isRetryable' without
    -- parsing 'errorMessage' text.
    errorInfo :: !(Maybe BaikaiError)
  }
  deriving stock (Eq, Show, Generic)

-- | A blank assistant turn at epoch start. Useful as a fixture base
-- for tests and as the default in error paths where no message was
-- received.
_Response :: Response
_Response =
  Response
    { message =
        AssistantPayload
          { content = V.empty,
            usage = _Usage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = read "2000-01-01 00:00:00 UTC" :: UTCTime
          },
      model = _Model,
      api = Custom "",
      provider = "",
      responseId = Nothing,
      latencyMs = 0,
      errorInfo = Nothing
    }

-- | Wrap the response payload as a conversation 'AssistantMessage'.
responseMessage :: Response -> Message
responseMessage r = AssistantMessage (message r)

-- | Pull the response's assistant content blocks out.
flattenAssistantBlocks :: Response -> Vector AssistantContent
flattenAssistantBlocks Response {message = AssistantPayload {content = c}} = c

-- | The single question callers ask about failure. Returns 'Just'
-- exactly when the response is error-shaped (@stopReason =
-- ErrorReason@): the provider's classified 'errorInfo' when present,
-- otherwise a synthesized 'OtherError' carrying the response's
-- 'errorMessage' text.
responseError :: Response -> Maybe BaikaiError
responseError Response {message = AssistantPayload {stopReason = sr, errorMessage = em}, errorInfo = ei}
  | sr == ErrorReason = Just (maybe (providerError fallback) id ei)
  | otherwise = Nothing
  where
    fallback = maybe "call failed with no error detail" id em

-- | Build a conformant error-shaped 'Response' for a failed call.
errorResponse :: Model -> UTCTime -> Integer -> BaikaiError -> Response
errorResponse m ts latency err =
  Response
    { message =
        AssistantPayload
          { content = V.empty,
            usage = _Usage,
            stopReason = ErrorReason,
            errorMessage = Just (Error.message err),
            timestamp = ts
          },
      model = m,
      api = Model.api m,
      provider = Model.provider m,
      responseId = Nothing,
      latencyMs = latency,
      errorInfo = Just err
    }
