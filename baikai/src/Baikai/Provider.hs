-- | The provider surface.
--
-- The prior 'Provider' typeclass and 'SomeProvider' existential are
-- removed. Dispatch now goes through 'Baikai.Provider.Registry':
-- the caller picks a 'Baikai.Model.Model' record and calls
-- 'completeRequest'; the registry looks up the right handler by the
-- model's 'Baikai.Api.Api' tag.
--
-- This module re-exports the registry surface so the
-- @import Baikai.Provider@ habit still resolves the symbols a
-- caller cares about.
module Baikai.Provider
  ( ApiProvider (..)
  , registerApiProvider
  , lookupApiProvider
  , completeRequest
  ) where

import Baikai.Provider.Registry
  ( ApiProvider (..)
  , completeRequest
  , lookupApiProvider
  , registerApiProvider
  )
