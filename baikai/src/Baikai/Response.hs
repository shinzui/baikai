-- | The provider response envelope.
--
-- A 'Response' wraps the model's assistant turn ('message') with
-- metadata baikai owns: the originating API tag (free 'Text' until EP-2
-- introduces 'Baikai.Api.Api'), the provider name, the model id echoed
-- back by the server, an optional 'responseId', and the measured
-- 'latencyMs'. The 'message' carries the assistant content blocks,
-- 'Usage' (with 'Cost' embedded), 'StopReason', and optional error text.
--
-- EP-2 will collapse 'Response' into the new envelope around the
-- registry; for now the shape stays close to the prior 'Response' so
-- existing call sites migrate with a single field rename
-- ('content' → 'message'). 'assistantContent' is a convenience accessor
-- that flattens the message's content blocks.
module Baikai.Response
  ( Response (..)
  , _Response
  , flattenAssistantBlocks
  ) where

import Baikai.Content (AssistantContent)
import Baikai.Message (Message (..))
import Baikai.Model (Model (..))
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (_Usage)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data Response = Response
  { message :: !Message
    -- ^ Always built with the 'AssistantMessage' constructor.
  , model :: !Model
  , api :: !Text
    -- ^ Free text for now (e.g. "anthropic.messages", "openai.chat").
    --   EP-2 promotes this to a typed 'Api' tag.
  , provider :: !Text
  , responseId :: !(Maybe Text)
  , latencyMs :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | A blank assistant turn at epoch start. Useful as a fixture base
-- for tests and as the default in error paths where no message was
-- received.
_Response :: Response
_Response =
  Response
    { message =
        AssistantMessage
          { assistantContent = V.empty
          , usage = _Usage
          , stopReason = Stop
          , errorMessage = Nothing
          , timestamp = read "2000-01-01 00:00:00 UTC" :: UTCTime
          }
    , model = Model ""
    , api = ""
    , provider = ""
    , responseId = Nothing
    , latencyMs = 0
    }

-- | Pull the response's assistant content blocks out. The result is
-- empty when 'message' is not an 'AssistantMessage' — providers never
-- produce a different constructor in practice.
flattenAssistantBlocks :: Response -> Vector AssistantContent
flattenAssistantBlocks r = case message r of
  AssistantMessage {assistantContent = c} -> c
  _ -> V.empty
