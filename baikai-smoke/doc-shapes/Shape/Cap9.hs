-- | CAP-9, docs/capabilities/call-tracing.md.
module Shape.Cap9 (shape) where

import Baikai hiding (model)
import Baikai.Trace (withTrace)
import Baikai.Trace.Sink (fileSink)
import Shape.Fixtures (ctx, model, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-9
  sink <- fileSink "/tmp/baikai-trace.jsonl"
  withTrace sink model ctx opts

-- END CAP-9
