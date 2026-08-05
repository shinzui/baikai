-- | The @baikai@ executable.
--
-- Deliberately thin. Everything real lives in "Baikai.Agent.Cli", which
-- returns an 'AgentCliRun' rather than writing to streams or exiting, so
-- the whole command-line surface is reachable from the test suite
-- without spawning this binary. This module's only job is to interpret
-- that record into real streams and a real exit code.
module Main (main) where

import Baikai.Agent.Cli
  ( AgentCliRun,
    agentCliParserInfo,
    runAgentCli,
  )
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Options.Applicative qualified as Options
import Settei.Env (EnvSnapshot, envSnapshot)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (stderr, stdout)

main :: IO ()
main = do
  options <- Options.execParser agentCliParserInfo
  snapshot <- captureEnvironment
  finished <- runAgentCli snapshot options
  emit finished
  exitWith (exitCodeFrom (finished ^. #exitCode))

-- | Snapshot the real environment once. @settei@ takes the snapshot as
-- a value rather than reading the environment itself, which is what
-- makes the layer testable without mutating the process.
captureEnvironment :: IO EnvSnapshot
captureEnvironment = do
  values <- getEnvironment
  pure (envSnapshot [(Text.pack name, Text.pack value) | (name, value) <- values])

emit :: AgentCliRun -> IO ()
emit finished = do
  TextIO.hPutStr stdout (finished ^. #standardOutput)
  TextIO.hPutStr stderr (finished ^. #standardError)

exitCodeFrom :: Int -> ExitCode
exitCodeFrom 0 = ExitSuccess
exitCodeFrom code = ExitFailure code
