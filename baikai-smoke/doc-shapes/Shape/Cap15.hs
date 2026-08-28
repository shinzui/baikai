-- | CAP-15, docs/capabilities/subscription-cli-backends.md.
module Shape.Cap15 (shape) where

import Baikai
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Shape.Fixtures (ctx, modelWithCliTag, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-15
  ClaudeCli.register
  completeRequest modelWithCliTag ctx opts -- spawns `claude -p`
  -- END CAP-15
