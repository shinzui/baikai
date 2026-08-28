-- | CAP-6, docs/capabilities/text-embeddings.md.
module Shape.Cap6 (shape) where

import Baikai.Embedding (embedOne, openAIEmbeddingModel)
import Data.Vector (Vector)

shape :: IO (Vector Double)
shape = do
  -- BEGIN CAP-6
  embedOne (openAIEmbeddingModel "text-embedding-3-small") "some text"

-- END CAP-6
