-- | Project-wide prelude for baikai. Re-exports the lens and
--   generic-lens vocabulary every module in this project is expected to
--   use, so consumers can `import Baikai.Prelude` and get
--   the standard toolkit without per-module import noise.
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
  ) where

import Control.Lens
import Data.Generics.Labels ()
import Data.Generics.Product
import Data.Generics.Sum
