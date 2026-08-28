-- | CAP-1, docs/capabilities/unified-provider-calls.md. DocShapes.hs compares
-- the region between the markers, indent-stripped, with the record's block.
module Shape.Cap1 (main) where

import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as V

-- BEGIN CAP-1
main :: IO ()
main = do
  OpenAIApi.register
  prompt <- userNow "Say hi."
  let ctx = emptyContext & #messages .~ V.singleton prompt
      opts = emptyOptions & #maxTokens .~ Just 32
  resp <- completeRequest Models.openai_gpt_4o_mini ctx opts
  print (flattenAssistantText (flattenAssistantBlocks resp))

-- END CAP-1
