-- | CAP-7, docs/capabilities/usage-and-cost-accounting.md.
module Shape.Cap7 (shape) where

import Baikai hiding (model)
import Baikai.Cost.Log (callLogConfig, runRequestWithLog, withCallLog)
import Shape.Fixtures (ctx, model, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-7
  withCallLog (callLogConfig "/tmp/baikai.jsonl") $ \h ->
    runRequestWithLog h model ctx opts

-- END CAP-7
