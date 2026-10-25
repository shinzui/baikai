-- | CAP-31, docs/capabilities/explicit-reasoning-off.md.
module Shape.Cap31 (shape) where

import Baikai hiding (model)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model)

shape :: IO Response
shape = do
  -- BEGIN CAP-31
  let opts = emptyOptions & #thinking .~ Just ThinkingNone
  completeRequest model ctx opts

-- END CAP-31
