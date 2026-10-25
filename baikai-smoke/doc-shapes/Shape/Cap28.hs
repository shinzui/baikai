-- | CAP-28, docs/capabilities/structured-answer-content.md.
module Shape.Cap28 (shape) where

import Baikai (AssistantContent (AssistantData), DataContent (..), emptyResponse)
import Baikai.Response.JSON (responseToJSON)
import Control.Lens ((&), (.~))
import Data.Aeson (Value)
import Data.Generics.Labels ()
import Data.Vector qualified as V

state :: Value
state = error "CAP-28: caller-supplied state; compiled, never executed"

shape :: IO ()
shape = do
  -- BEGIN CAP-28
  let answer = DataContent state Nothing Nothing Nothing
      response = emptyResponse & #message . #content .~ V.singleton (AssistantData answer)
  print (responseToJSON response)

-- END CAP-28
