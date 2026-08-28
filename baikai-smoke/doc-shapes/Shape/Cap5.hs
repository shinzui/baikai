-- | CAP-5, docs/capabilities/structured-output.md.
module Shape.Cap5 (shape) where

import Baikai hiding (model)
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Shape.Fixtures (ctx, model, personSchema)

shape :: IO Response
shape = do
  -- BEGIN CAP-5
  let opts =
        emptyOptions
          & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "person" personSchema))
  completeRequest model ctx opts

-- END CAP-5
