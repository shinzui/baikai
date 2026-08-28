-- | CAP-16, docs/capabilities/interactive-launches.md.
module Shape.Cap16 (shape) where

import Baikai
import Baikai.Agent (renderAgentRenderError)
import Baikai.Provider.Claude.Interactive (defaultClaudeInteractiveConfig, launchClaudeInteractive)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Shape.Fixtures (reportRefusal)
import System.Exit (exitWith)

shape :: IO ()
shape = do
  -- BEGIN CAP-16
  result <-
    launchClaudeInteractive
      defaultClaudeInteractiveConfig
      ( interactiveLaunchRequest "Inspect this project and suggest next steps."
          & #modelId .~ Just "claude-opus-5"
          & #safety .~ ClaudeAllowedTools ["Read", "Grep"]
      )
  case result of
    Left refusal -> reportRefusal (renderAgentRenderError refusal) -- nothing was started
    Right done -> exitWith (done ^. #exitCode)

-- END CAP-16
