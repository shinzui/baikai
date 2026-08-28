-- | Provider-agnostic prompt-cache retention preference.
--
-- Each provider maps the value to its own primitive: on Anthropic,
-- 'CacheRetentionLong' becomes @cache_control.ttl: "1h"@ and
-- 'CacheRetentionShort' the ephemeral marker with no TTL. The
-- OpenAI-compatible provider emits Anthropic-style markers only where
-- the host's compat record sets
-- 'Baikai.Compat.cacheControlFormat'; hosts that do not advertise
-- prompt caching under a marker ignore the preference.
module Baikai.CacheRetention
  ( CacheRetention (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

-- | The three buckets pi-mono settled on.
data CacheRetention
  = -- | Do not request prompt caching at all.
    CacheRetentionNone
  | -- | Provider-default ephemeral retention (Anthropic: 5 minutes).
    CacheRetentionShort
  | -- | Long-retention bucket (Anthropic: @ttl: "1h"@). Downgrades to
    --   short on hosts that report 'supportsLongCacheRetention' as
    --   'False'.
    CacheRetentionLong
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
