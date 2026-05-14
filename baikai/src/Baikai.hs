-- | Public surface of the baikai library. Importing this module
-- gives a downstream consumer everything needed to declare a
-- 'Model', build a 'Context' and 'Options', and dispatch a call
-- through the registered handler.
module Baikai
  ( -- * Types
    module Baikai.Api
  , module Baikai.Model
  , module Baikai.Content
  , module Baikai.StopReason
  , module Baikai.Message
  , module Baikai.Tool
  , module Baikai.Context
  , module Baikai.Options
  , module Baikai.Response
  , module Baikai.Usage
  , module Baikai.Cost
  , module Baikai.Error

    -- * Per-API compat shims and call-time options
  , module Baikai.Compat
  , module Baikai.CacheRetention
  , module Baikai.ThinkingLevel

    -- * Provider registry
  , module Baikai.Provider

    -- * Streaming
  , module Baikai.Stream
  , module Baikai.Stream.Event
  ) where

import Baikai.Api
import Baikai.CacheRetention
import Baikai.Compat
import Baikai.Content
import Baikai.Context
import Baikai.Cost
import Baikai.Error
import Baikai.Message
import Baikai.Model
import Baikai.Options
import Baikai.Provider
import Baikai.Response
import Baikai.StopReason
import Baikai.Stream
import Baikai.Stream.Event
import Baikai.ThinkingLevel
import Baikai.Tool
import Baikai.Usage
