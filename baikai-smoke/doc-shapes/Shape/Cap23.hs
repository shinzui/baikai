-- | CAP-23, docs/capabilities/openai-responses-backend.md.
module Shape.Cap23 (shape) where

import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Responses qualified as OpenAIResponses
import Shape.Fixtures (ctx, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-23
  -- separate from the Chat Completions registration; without it an
  -- OpenAIResponses model has no handler and dispatch fails
  OpenAIResponses.register
  completeRequest Models.openai_gpt_6_astra ctx opts

-- END CAP-23
