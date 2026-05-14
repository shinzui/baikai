module Baikai.Message
  ( Role (..)
  , Message (..)
  , user
  , assistant
  , system
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

data Role = User | Assistant | System
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data Message = Message
  { role :: !Role
  , content :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

user, assistant, system :: Text -> Message
user t = Message {role = User, content = t}
assistant t = Message {role = Assistant, content = t}
system t = Message {role = System, content = t}
