-- | CAP-12, docs/capabilities/prompt-cache-retention.md.
module Shape.Cap12 (shape) where

import Baikai hiding (model)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model)

shape :: IO ()
shape = do
  -- BEGIN CAP-12
  let opts = emptyOptions & #cacheRetention .~ Just CacheRetentionLong
  resp <- completeRequest model ctx opts
  print (resp ^. #message . #usage . #cacheReadTokens)

-- END CAP-12
