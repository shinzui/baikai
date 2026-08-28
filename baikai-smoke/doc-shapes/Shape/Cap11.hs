-- | CAP-11, docs/capabilities/reasoning-effort-control.md.
module Shape.Cap11 (shape) where

import Baikai hiding (model)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model)

shape :: IO Response
shape = do
  -- BEGIN CAP-11
  let opts = emptyOptions & #thinking .~ Just ThinkingHigh
  completeRequest model ctx opts

-- END CAP-11
