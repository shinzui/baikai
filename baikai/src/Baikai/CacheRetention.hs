-- | Provider-agnostic prompt-cache retention preference.
--
-- Each provider maps the value to its own primitive: Anthropic's
-- 'long' becomes @cache_control.ttl: "1h"@, 'short' becomes the
-- ephemeral marker with no TTL; OpenAI Responses API's 'long' would
-- become 24h. Hosts that do not advertise prompt caching ignore the
-- preference.
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
  | -- | Long-retention bucket (Anthropic: @ttl: "1h"@; OpenAI
    --   Responses: 24h). Downgrades to short on hosts that report
    --   'supportsLongCacheRetention' as 'False'.
    CacheRetentionLong
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
