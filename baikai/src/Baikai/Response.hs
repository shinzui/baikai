-- | The provider response envelope.
--
-- A 'Response' wraps the model's assistant payload ('message') with
-- metadata baikai owns: the originating 'Api' tag (now typed via
-- 'Baikai.Api'), the input 'Model' echoed back, the provider name,
-- an optional 'responseId', and the measured 'latencyMs'. The
-- 'message' carries only assistant content blocks, 'Usage' (with
-- 'Cost' embedded), 'StopReason', optional error text, and an optional
-- timestamp.
--
-- 'flattenAssistantBlocks' and 'flattenAssistantText' are convenience
-- accessors for the message's content blocks.
module Baikai.Response
  ( Response (..),
    emptyResponse,
    responseMessage,
    flattenAssistantBlocks,
    flattenAssistantText,
    responseError,
    errorResponse,
  )
where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Error (BaikaiError, providerError)
import Baikai.Error qualified as Error
import Baikai.Evidence (ModelCallEvidence)
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model, emptyModel)
import Baikai.Model qualified as Model
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (zeroUsage)
import Data.Text (Text)
import Data.Text qualified as Text
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
    latencyMs :: !Int,
    -- | Structured error detail when the call failed in-band
    -- (@stopReason = ErrorReason@): the category, HTTP status, and any
    -- retry-after hint. Conforming providers set this to 'Just' for
    -- error-shaped responses and 'Nothing' on success. Use
    -- 'responseError' for the normalized failure view; it synthesizes
    -- an 'OtherError' if a nonconforming provider omits this field.
    errorInfo :: !(Maybe BaikaiError),
    -- | The evidence the provider adapter built for this call, when the
    -- caller asked for evidence and the provider builds it.
    --
    -- This is a convenience for synchronous callers. A caller who needs
    -- evidence should prefer reading it from their
    -- 'Baikai.Trace.Sink.TraceSink': the trace path emits exactly one
    -- record per call under every way a call can end, whereas this
    -- field is 'Nothing' on every path that never assembles a full
    -- response — a consumer that abandoned the stream early, or a
    -- dispatch that failed before any provider ran.
    evidence :: !(Maybe ModelCallEvidence)
  }
  deriving stock (Eq, Show, Generic)

-- | A blank assistant turn with no timestamp. Useful as a fixture base
-- for tests and as the default in error paths where no message was
-- received.
emptyResponse :: Response
emptyResponse =
  Response
    { message =
        AssistantPayload
          { content = V.empty,
            usage = zeroUsage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = Nothing
          },
      model = emptyModel,
      api = Custom "",
      provider = "",
      responseId = Nothing,
      latencyMs = 0,
      errorInfo = Nothing,
      evidence = Nothing
    }

-- | Wrap the response payload as a conversation 'AssistantMessage'.
responseMessage :: Response -> Message
responseMessage r = AssistantMessage (message r)

-- | Pull the response's assistant content blocks out.
flattenAssistantBlocks :: Response -> Vector AssistantContent
flattenAssistantBlocks Response {message = AssistantPayload {content = c}} = c

-- | Concatenate all assistant text blocks, ignoring thinking and tool
-- call blocks.
flattenAssistantText :: Vector AssistantContent -> Text
flattenAssistantText =
  Text.concat . V.toList . V.mapMaybe textOf
  where
    textOf (AssistantText (TextContent t)) = Just t
    textOf _ = Nothing

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
errorResponse :: Model -> UTCTime -> Int -> BaikaiError -> Response
errorResponse m ts latency err =
  Response
    { message =
        AssistantPayload
          { content = V.empty,
            usage = zeroUsage,
            stopReason = ErrorReason,
            errorMessage = Just (Error.message err),
            timestamp = Just ts
          },
      model = m,
      api = Model.api m,
      provider = Model.provider m,
      responseId = Nothing,
      latencyMs = latency,
      errorInfo = Just err,
      evidence = Nothing
    }
