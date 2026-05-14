-- | Project-wide prelude for baikai. Re-exports the lens and
--   generic-lens vocabulary every module in this project is expected to
--   use, plus IO lifting, the scalar types used across the library, the
--   `Generic` class, and the aeson surface for deriving and writing
--   JSON instances.
--
--   `Data.Generics.Labels` is imported for its orphan `IsLabel` instance
--   only (no values are re-exported); the instance still propagates to
--   anything that imports this Prelude.
module Baikai.Prelude
  ( -- * Lens vocabulary
    module Control.Lens
    -- * Generic-lens vocabulary
  , module Data.Generics.Product
  , module Data.Generics.Sum
    -- * IO lifting (`liftIO` re-exported as a method of `MonadIO`)
  , MonadIO (..)
    -- * Scalar types
  , Text
  , Vector
  , Natural
    -- * Generics
  , Generic
    -- * JSON
  , FromJSON (..)
  , ToJSON (..)
  , genericParseJSON
  , genericToJSON
  ) where

import Control.Lens
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON (..), ToJSON (..), genericParseJSON, genericToJSON)
import Data.Generics.Labels ()
import Data.Generics.Product
import Data.Generics.Sum
import Data.Text (Text)
import Data.Vector (Vector)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
