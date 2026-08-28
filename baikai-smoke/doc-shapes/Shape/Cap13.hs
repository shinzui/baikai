-- | CAP-13, docs/capabilities/anthropic-messages-backend.md.
module Shape.Cap13 (shape) where

import Baikai
import Baikai.Provider.Claude.Api qualified as ClaudeApi

shape :: IO ()
shape = do
  -- BEGIN CAP-13
  ClaudeApi.register
  -- or, keeping registration out of global state:
  registry <- newProviderRegistryFrom [ClaudeApi.claudeMessagesProvider]
  assertRegistered registry [AnthropicMessages]

-- END CAP-13
