-- | CAP-20, docs/capabilities/effectful-binding.md.
module Shape.Cap20 (program) where

import Baikai.Effectful
import Effectful (Eff, (:>))
import Shape.Fixtures (ctx, model, opts)

-- BEGIN CAP-20
program :: (Baikai :> es) => Eff es Response
program = complete model ctx opts

-- END CAP-20
