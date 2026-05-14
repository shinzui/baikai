module Baikai.Error (BaikaiError (..)) where

import Control.Exception (Exception)
import Data.Text (Text)
import GHC.Generics (Generic)

data BaikaiError
  = ProviderError !Text
  | RequestInvalid !Text
  | DecodeError !Text
  | ProcessError !Int !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Exception)
