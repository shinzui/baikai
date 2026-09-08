-- | CAP-24, docs/capabilities/inference-speed-control.md.
module Shape.Cap24 (shape) where

import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx)

shape :: IO Response
shape = do
  -- BEGIN CAP-24
  -- SpeedFast comes from Baikai, which re-exports Baikai.Speed.
  -- sent on a model whose catalog entry advertises fast mode; dropped with a
  -- FastModeDroppedUnsupportedModel evidence adjustment on one that does not
  let opts = emptyOptions & #speed .~ Just SpeedFast
  completeRequest Models.anthropic_claude_opus_5 ctx opts

-- END CAP-24
