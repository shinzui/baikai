module Baikai.Request (Request (..), _Request) where

import Baikai.Message (Message)
import Baikai.Model (Model (..))
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Request = Request
  { model :: !Model
  , messages :: !(Vector Message)
  , maxTokens :: !Natural
  , temperature :: !(Maybe Double)
  , systemPrompt :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

_Request :: Request
_Request =
  Request
    { model = Model ""
    , messages = V.empty
    , maxTokens = 1024
    , temperature = Nothing
    , systemPrompt = Nothing
    }
