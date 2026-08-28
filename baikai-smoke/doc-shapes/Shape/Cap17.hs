-- | CAP-17, docs/capabilities/unattended-agent-runs.md.
module Shape.Cap17 (shape) where

import Baikai.Agent
import Baikai.Agent.Run (runAgentCommand)
import Baikai.Provider.Claude.Agent (claudeAgentCommand)
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Shape.Fixtures (config, reportFailure, reportRefusal, request)
import System.Exit (exitWith)

shape :: IO ()
shape = do
  -- BEGIN CAP-17
  case claudeAgentCommand config request of
    Left refusal -> reportRefusal (renderAgentRenderError refusal) -- nothing was started
    Right (cmd, thinking) -> do
      outcome <- runAgentCommand Nothing thinking request cmd
      case outcome ^. #outcome of
        Right result -> exitWith (result ^. #exitCode)
        Left failure -> reportFailure (renderAgentRunFailure failure)

-- END CAP-17
