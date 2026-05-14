module Baikai.Response (Response (..), _Response) where

import Baikai.Cost (Cost)
import Baikai.Model (Model (..))
import Baikai.Usage (Usage)
import Data.Text (Text)
import GHC.Generics (Generic)

data Response = Response
  { content :: !Text
  , model :: !Model
  , usage :: !(Maybe Usage)
  , cost :: !(Maybe Cost)
  , provider :: !Text
  , latencyMs :: !Integer
  }
  deriving stock (Eq, Show, Generic)

_Response :: Response
_Response =
  Response
    { content = ""
    , model = Model ""
    , usage = Nothing
    , cost = Nothing
    , provider = ""
    , latencyMs = 0
    }
