-- | CAP-14, docs/capabilities/openai-chat-completions-backend.md.
module Shape.Cap14 (shape) where

import Baikai
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Shape.Fixtures (ctx, opts)

shape :: IO Response
shape = do
  -- BEGIN CAP-14
  OpenAIApi.register
  -- a non-OpenAI host is just a Model with a different baseUrl:
  let m = mkModel OpenAIChatCompletions "deepseek-chat" "https://api.deepseek.com"
  completeRequest m ctx opts

-- END CAP-14
