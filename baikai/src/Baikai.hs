-- | Public surface of the baikai library. Importing this module
-- gives a downstream consumer everything needed to declare a
-- 'Model', build a 'Context' and 'Options', and dispatch a call
-- through the registered handler.
--
-- This umbrella intentionally omits opt-in subsystems with their own
-- vocabularies: tracing, OpenTelemetry sinks, embeddings, call-log
-- plumbing, pricing lookup internals, the generated model catalog, and
-- "Baikai.Prelude". Import those modules directly when you need them.
--
-- Evolvable configuration records expose their type, field selectors,
-- and an @empty*@ or @default*@ base value rather than their data
-- constructor. Build those records by record update so adding fields in
-- a later release does not force source changes. Closed sums and
-- provider-produced payload records remain constructible where callers
-- need to pattern match or build fixtures.
module Baikai
  ( -- * Types
    module Baikai.AgentAssets,
    module Baikai.Api,
    module Baikai.Auth,
    module Baikai.Header,
    module Baikai.Model,
    module Baikai.Content,
    module Baikai.StopReason,
    module Baikai.Message,
    module Baikai.Tool,
    module Baikai.Context,
    module Baikai.Options,
    module Baikai.Response,
    module Baikai.Usage,
    module Baikai.Cost,
    module Baikai.Error,
    module Baikai.Evidence,
    module Baikai.Evidence.Build,
    module Baikai.Interactive,

    -- * Per-API compat shims and call-time options
    module Baikai.Compat,
    module Baikai.CacheRetention,
    module Baikai.ResponseFormat,
    module Baikai.ThinkingLevel,

    -- * Provider registry
    module Baikai.Provider,

    -- * Streaming
    module Baikai.Stream,
    module Baikai.Stream.Event,
  )
where

import Baikai.AgentAssets
import Baikai.Api
import Baikai.Auth
import Baikai.CacheRetention
import Baikai.Compat
import Baikai.Content
import Baikai.Context
import Baikai.Cost
import Baikai.Error
import Baikai.Evidence
import Baikai.Evidence.Build
import Baikai.Header
import Baikai.Interactive
import Baikai.Message
import Baikai.Model
import Baikai.Options
import Baikai.Provider
import Baikai.Response
import Baikai.ResponseFormat
import Baikai.StopReason
import Baikai.Stream
import Baikai.Stream.Event
import Baikai.ThinkingLevel
import Baikai.Tool
import Baikai.Usage
