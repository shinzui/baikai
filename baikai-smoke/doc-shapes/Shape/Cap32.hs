-- | CAP-32, docs/capabilities/traced-effectful-collection.md.
module Shape.Cap32 (program) where

import Baikai.Effectful
import Effectful (Eff, (:>))
import Shape.Fixtures (ctx, model, opts)

-- BEGIN CAP-32
program :: (Baikai :> es) => TraceSink -> Eff es [AssistantMessageEvent]
program sink = streamCollectTraced sink model ctx opts

-- END CAP-32
