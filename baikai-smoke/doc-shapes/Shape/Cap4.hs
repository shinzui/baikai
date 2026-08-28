-- | CAP-4, docs/capabilities/tool-calling.md.
module Shape.Cap4 (shape) where

import Baikai hiding (model)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Vector qualified as V
import Shape.Fixtures (dispatcher, getTimeTool, model)

shape :: IO ()
shape = do
  -- BEGIN CAP-4
  let ctx =
        contextOf [user "What time is it? Use the tool."]
          & #tools .~ V.singleton getTimeTool
      opts = emptyOptions & #toolChoice .~ Just ToolChoiceAuto
  (finalCtx, resp) <- runToolLoop 8 dispatcher model ctx opts
  print (responseError resp, length (finalCtx ^. #messages))

-- END CAP-4
