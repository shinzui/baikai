-- | CAP-7, docs/capabilities/usage-and-cost-accounting.md.
module Shape.Cap7 (shape) where

import Baikai hiding (model)
import Baikai.Cost.Log (callLogConfig, runRequestWithLog, withCallLog)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-7
  withCallLog (callLogConfig "/tmp/baikai.jsonl") $ \h -> do
    resp <- runRequestWithLog h model ctx opts
    print (resp ^. #message . #usage . #cost . #basis)
    pure resp

-- END CAP-7
