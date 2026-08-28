-- | CAP-19, docs/capabilities/model-call-evidence.md.
module Shape.Cap19 (shape) where

import Baikai hiding (model)
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink (fileSink)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model)

shape :: IO Response
shape = do
  -- BEGIN CAP-19
  let opts = emptyOptions & #evidence .~ Just (evidenceRequest "nightly-review-2026-08-10")
  sink <- fileSink "/tmp/evidence.jsonl"
  withTrace sink model ctx opts

-- END CAP-19
