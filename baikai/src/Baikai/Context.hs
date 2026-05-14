-- | The 'Context' record — the part of a request that defines the
-- conversation: the optional system prompt and the message vector.
--
-- 'Context' replaces the prior 'Baikai.Request.Request' record's
-- conversation-related fields. The per-call knobs that previously
-- lived alongside the messages (max tokens, temperature, API key)
-- now live on 'Baikai.Options.Options' instead. EP-4 will extend
-- 'Context' with a @tools@ vector.
module Baikai.Context
  ( Context (..)
  , _Context
  ) where

import Baikai.Message (Message)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data Context = Context
  { systemPrompt :: !(Maybe Text)
  , messages :: !(Vector Message)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

_Context :: Context
_Context = Context {systemPrompt = Nothing, messages = V.empty}
