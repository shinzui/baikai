-- | CAP-2, docs/capabilities/typed-streaming.md.
module Shape.Cap2 (shape) where

import Baikai hiding (model)
import Shape.Fixtures (ctx, initial, model, opts, registry, step)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream

shape :: IO ()
shape = do
  -- BEGIN CAP-2
  total <- Stream.fold (Fold.foldl' step initial) (streamRequest model ctx opts)
  -- or, without importing streamly:
  events <- streamRequestListWith registry model ctx opts
  print (total, length events)

-- END CAP-2
