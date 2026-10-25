-- | CAP-27, docs/capabilities/typesafe-judgments.md.
module Shape.Cap27 (shape) where

import Baikai hiding (model, opts, schema)
import Baikai.Provider.TypeSafe.Api qualified as TypeSafe
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Vector qualified as V
import Shape.Fixtures (model, personSchema)

shape :: IO (V.Vector DataContent)
shape = do
  -- BEGIN CAP-27
  reg <- newProviderRegistry
  registerApiProviderWith reg TypeSafe.typesafeProvider
  let state = Aeson.object ["ticket" Aeson..= ("Checkout is unavailable." :: Text)]
      ctx = contextOf [userData state]
      opts = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "ticket" personSchema))
  response <- completeRequestWith reg model ctx opts
  pure (flattenAssistantData (response ^. #message . #content))

-- END CAP-27
