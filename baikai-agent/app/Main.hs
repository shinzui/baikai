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
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Options.Applicative qualified as Options
import Settei.Env (EnvSnapshot, envSnapshot)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, stderr, stdout)

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

-- | Write both streams as UTF-8 bytes.
--
-- Explicitly encoded rather than written with 'Data.Text.IO.hPutStr',
-- which encodes through the handle's locale encoding: under @LANG=C@ —
-- cron, systemd, a minimal container — a single non-ASCII character in
-- the agent's answer made that throw @invalid argument@ after the run
-- had already finished, losing the answer and exiting 1.
--
-- Nothing here can throw on encoding. Invalid UTF-8 in the child's
-- output became U+FFFD when 'Baikai.Agent.Cli.decoded' decoded it
-- leniently, so what arrives is always encodable, and this is the same
-- discipline the prompt read and the prompt write already use.
emit :: AgentCliRun -> IO ()
emit finished = do
  BS.hPut stdout (Text.encodeUtf8 (finished ^. #standardOutput))
  BS.hPut stderr (Text.encodeUtf8 (finished ^. #standardError))
  hFlush stdout
  hFlush stderr

exitCodeFrom :: Int -> ExitCode
exitCodeFrom 0 = ExitSuccess
exitCodeFrom code = ExitFailure code
