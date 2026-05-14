module Baikai.Model (Model (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.String (IsString)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype Model = Model {unModel :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString, FromJSON, ToJSON)
