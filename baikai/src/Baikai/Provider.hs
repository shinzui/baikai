{-# LANGUAGE ExistentialQuantification #-}

module Baikai.Provider
  ( Provider (..)
  , SomeProvider (..)
  , runSome
  ) where

import Baikai.Request (Request)
import Baikai.Response (Response)
import Control.Monad.IO.Class (MonadIO)
import Data.Text (Text)

class Provider p where
  providerName :: p -> Text
  runRequest :: MonadIO m => p -> Request -> m Response

data SomeProvider = forall p. (Provider p) => SomeProvider p

runSome :: MonadIO m => SomeProvider -> Request -> m Response
runSome (SomeProvider p) = runRequest p
