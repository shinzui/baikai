-- | CAP-26, docs/capabilities/tiered-cache-write-pricing.md.
module Shape.Cap26 (shape) where

import Baikai.CacheRetention (CacheRetention (CacheRetentionLong))
import Baikai.Cost.Pricing (resolveRates)
import Baikai.Models.Generated qualified as Models
import Baikai.Usage (zeroUsage)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()

shape :: IO ()
shape = do
  -- BEGIN CAP-26
  let usage = zeroUsage & #cacheWriteTokens .~ 100001
  print (resolveRates (Just CacheRetentionLong) Models.anthropic_claude_haiku_5_5 usage)

-- END CAP-26
