-- | CAP-25, docs/capabilities/batch-cli-cancellation.md.
module Shape.Cap25 (shape) where

import Baikai
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Control.Concurrent (forkFinally, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (throwIO)
import Shape.Fixtures (ctx, modelWithCliTag, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-25
  ClaudeCli.register
  finished <- newEmptyMVar
  worker <- forkFinally (completeRequest modelWithCliTag ctx opts) (putMVar finished)
  killThread worker
  result <- takeMVar finished
  either throwIO pure result

-- END CAP-25
