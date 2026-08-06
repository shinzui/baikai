module Main (main) where

import Baikai.Agent
  ( AgentCapturedOutput (..),
    AgentCommand (..),
    AgentOutputMode (..),
    AgentPromptTransport (..),
    AgentProvider (..),
    AgentRunFailure (..),
    AgentRunRequest,
    AgentRunResult,
    agentRunRequest,
    capturedBytes,
  )
import Baikai.Agent.Run (runAgentCommand, timeoutMicros)
import Baikai.Evidence (noThinkingRequested)
import CliTests (cliTests)
import ConfigTests (configTests)
import Control.Concurrent (threadDelay)
import Control.Lens ((&), (.~), (^.))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import EvidenceTests (evidenceTests)
import System.Directory
  ( doesFileExist,
    getPermissions,
    setOwnerExecutable,
    setPermissions,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "baikai-agent"
      [ runTests,
        configTests,
        cliTests
      ]

runTests :: TestTree
runTests =
  testGroup
    "Baikai.Agent.Run"
    [ promptRoundTripTest,
      streamSeparationTest,
      workingDirectoryTest,
      nonZeroExitTest,
      spawnFailureTest,
      missingWorkingDirectoryTest,
      missingEnvironmentTest,
      timeoutTest,
      processGroupTest,
      outputLimitTest,
      inheritOutputTest,
      promptAsArgumentTest,
      timeoutMicrosTests,
      evidenceTests
    ]

-- | Write a tiny shell script into a temporary directory, make it
-- executable, and hand its path to the action. Every process-level
-- behavior this package implements can be reproduced by a few lines of
-- @sh@, which is what keeps the suite free of any coding-agent binary,
-- any authentication, and any model.
withFakeExecutable :: String -> String -> (FilePath -> FilePath -> IO a) -> IO a
withFakeExecutable name body action =
  withSystemTempDirectory "baikai-agent-test" $ \dir -> do
    let path = dir </> name
    writeFile path body
    perms <- getPermissions path
    setPermissions path (setOwnerExecutable True perms)
    action dir path

-- | A request rooted in the given directory, capturing output.
capturingRequest :: FilePath -> Text.Text -> AgentRunRequest
capturingRequest dir promptBody =
  agentRunRequest AgentClaude dir promptBody & #output .~ CaptureOutput

-- | A command that delivers the prompt on standard input, the transport
-- both shipped vendor renderers select.
stdinCommand :: FilePath -> [String] -> Text.Text -> AgentCommand
stdinCommand exe args promptBody =
  AgentCommand
    { executable = exe,
      arguments = args,
      promptTransport = PromptOnStdin,
      promptText = promptBody
    }

-- | Unwrap a run that was expected to start, reporting the failure's own
-- message when it did not.
expectRan ::
  Either AgentRunFailure AgentRunResult -> IO AgentRunResult
expectRan (Left failure) =
  assertFailure ("expected the run to start: " <> show failure)
expectRan (Right result) = pure result

-- | The runner as every case in this module uses it: no evidence
-- requested, and therefore no reasoning-effort translation to describe.
--
-- The evidence path has its own module. Keeping it out of here means
-- these cases still assert exactly what they asserted before evidence
-- existed, which is what makes them a regression guard for it.
runPlain ::
  AgentRunRequest -> AgentCommand -> IO (Either AgentRunFailure AgentRunResult)
runPlain req cmd =
  (^. #outcome) <$> runAgentCommand Nothing noThinkingRequested req cmd

promptRoundTripTest :: TestTree
promptRoundTripTest =
  testCase "delivers the prompt on stdin and captures stdout" $
    -- A non-ASCII prompt on purpose: a locale-dependent write would
    -- corrupt it, so this also pins the explicit UTF-8 encoding.
    withFakeExecutable "echo-stdin" "#!/bin/sh\nexec cat\n" $ \dir exe -> do
      let promptBody = "réconcilier la grammaire — 文法" :: Text.Text
      result <-
        runPlain
          (capturingRequest dir promptBody)
          (stdinCommand exe [] promptBody)
          >>= expectRan
      result ^. #exitCode @?= ExitSuccess
      capturedBytes (result ^. #stdout) @?= Just (Text.encodeUtf8 promptBody)

streamSeparationTest :: TestTree
streamSeparationTest =
  testCase "separates stdout from stderr"
    $ withFakeExecutable
      "two-streams"
      "#!/bin/sh\nprintf 'to-stdout' \nprintf 'to-stderr' >&2\n"
    $ \dir exe -> do
      result <-
        runPlain (capturingRequest dir "ignored") (stdinCommand exe [] "ignored")
          >>= expectRan
      capturedBytes (result ^. #stdout) @?= Just "to-stdout"
      capturedBytes (result ^. #stderr) @?= Just "to-stderr"

workingDirectoryTest :: TestTree
workingDirectoryTest =
  testCase "honors the request working directory" $
    -- AgentCommand carries no working directory, so this is the only
    -- evidence that the request's one reaches the child.
    withFakeExecutable "print-cwd" "#!/bin/sh\nexec pwd\n" $ \dir exe -> do
      result <-
        runPlain (capturingRequest dir "ignored") (stdinCommand exe [] "ignored")
          >>= expectRan
      let reported = maybe "" (BS8.unpack . stripTrailingNewline) (capturedBytes (result ^. #stdout))
      -- Compare on the basename: macOS resolves /var to /private/var, so
      -- the child's pwd is the same directory by a different path.
      basename reported @?= basename dir

nonZeroExitTest :: TestTree
nonZeroExitTest =
  testCase "reports a non-zero exit as a successful run, intentionally" $
    -- Intentional, and the behavior most likely to be "fixed" into a
    -- Left by someone who has not read the plan: a coding agent that
    -- attempts its task and fails has still run.
    withFakeExecutable "exit-three" "#!/bin/sh\nexit 3\n" $ \dir exe -> do
      result <-
        runPlain (capturingRequest dir "ignored") (stdinCommand exe [] "ignored")
          >>= expectRan
      result ^. #exitCode @?= ExitFailure 3

spawnFailureTest :: TestTree
spawnFailureTest =
  testCase "reports a missing executable as SpawnFailed" $
    withSystemTempDirectory "baikai-agent-test" $ \dir -> do
      let missing = dir </> "not-installed"
      outcome <-
        runPlain (capturingRequest dir "ignored") (stdinCommand missing [] "ignored")
      case outcome of
        Left (SpawnFailed path _) -> path @?= missing
        other -> assertFailure ("expected SpawnFailed, got: " <> show other)

missingWorkingDirectoryTest :: TestTree
missingWorkingDirectoryTest =
  testCase "checks the working directory before spawning" $
    withSystemTempDirectory "baikai-agent-test" $ \dir -> do
      -- The executable is missing too, so a spawn attempt would have
      -- produced SpawnFailed. Getting WorkingDirMissing proves the
      -- precondition ran first.
      let absentDir = dir </> "no-such-directory"
          absentExe = dir </> "no-such-executable"
      outcome <-
        runPlain
          (capturingRequest absentDir "ignored")
          (stdinCommand absentExe [] "ignored")
      case outcome of
        Left (WorkingDirMissing path) -> path @?= absentDir
        other -> assertFailure ("expected WorkingDirMissing, got: " <> show other)

missingEnvironmentTest :: TestTree
missingEnvironmentTest =
  testCase "reports every missing declared variable at once" $
    withSystemTempDirectory "baikai-agent-test" $ \dir -> do
      -- Names chosen to be absent rather than unset here, so the test
      -- never mutates the suite's own environment.
      let names = ["BAIKAI_AGENT_TEST_ABSENT_ONE", "BAIKAI_AGENT_TEST_ABSENT_TWO"]
          req = capturingRequest dir "ignored" & #envPassthrough .~ names
      outcome <- runPlain req (stdinCommand (dir </> "unused") [] "ignored")
      case outcome of
        Left (MissingEnvironment missing) -> missing @?= names
        other -> assertFailure ("expected MissingEnvironment, got: " <> show other)

timeoutTest :: TestTree
timeoutTest =
  testCase "times out and terminates rather than waiting the script out" $
    withFakeExecutable "sleeper" "#!/bin/sh\nsleep 5\n" $ \dir exe -> do
      let req = capturingRequest dir "ignored" & #timeout .~ Just 1
      start <- getCurrentTime
      outcome <- runPlain req (stdinCommand exe [] "ignored")
      end <- getCurrentTime
      case outcome of
        Left (RunTimedOut limit) -> limit @?= 1
        other -> assertFailure ("expected RunTimedOut, got: " <> show other)
      -- Without this assertion the test would pass just as well by
      -- waiting for the script to finish, which proves nothing about
      -- termination.
      assertBool
        "returned well before the script would have finished"
        (diffUTCTime end start < 4)

processGroupTest :: TestTree
processGroupTest =
  testCase "kills grandchildren when the group is terminated"
    $
    -- The most valuable test here and the easiest to omit: it is what
    -- proves a coding agent's own child processes die with it.
    withFakeExecutable
      "spawns-a-child"
      "#!/bin/sh\n(sleep 3; touch \"$1\") &\nsleep 5\n"
    $ \dir exe -> do
      let marker = dir </> "grandchild-survived"
          req = capturingRequest dir "ignored" & #timeout .~ Just 1
      outcome <- runPlain req (stdinCommand exe [marker] "ignored")
      case outcome of
        Left (RunTimedOut _) -> pure ()
        other -> assertFailure ("expected RunTimedOut, got: " <> show other)
      -- Wait past the grandchild's delay before checking, or the file
      -- would be absent merely because it is early.
      waitSeconds 4
      survived <- doesFileExist marker
      assertBool "the grandchild was terminated with its group" (not survived)

outputLimitTest :: TestTree
outputLimitTest =
  testCase "truncates captured output at the byte limit"
    $ withFakeExecutable
      "flood"
      "#!/bin/sh\ni=0\nwhile [ $i -lt 2000 ]; do printf '0123456789'; i=$((i+1)); done\n"
    $ \dir exe -> do
      let req = capturingRequest dir "ignored" & #outputLimit .~ Just 1024
      result <-
        runPlain req (stdinCommand exe [] "ignored") >>= expectRan
      case result ^. #stdout of
        OutputTruncated bytes -> BS.length bytes @?= 1024
        other -> assertFailure ("expected OutputTruncated, got: " <> show other)
      -- Proves the excess was discarded rather than the pipe closed:
      -- closing it would have made the child's next write fail.
      result ^. #exitCode @?= ExitSuccess

inheritOutputTest :: TestTree
inheritOutputTest =
  testCase "captures nothing in inherit mode" $
    withFakeExecutable "chatty" "#!/bin/sh\nprintf 'inherited line\\n'\n" $ \dir exe -> do
      -- The line goes to the test runner's own output, which is expected.
      let req = agentRunRequest AgentClaude dir "ignored"
      result <- runPlain req (stdinCommand exe [] "ignored") >>= expectRan
      result ^. #stdout @?= OutputNotCaptured
      result ^. #stderr @?= OutputNotCaptured
      result ^. #exitCode @?= ExitSuccess

promptAsArgumentTest :: TestTree
promptAsArgumentTest =
  testCase "supports the prompt-as-argument transport"
    $
    -- No shipped renderer selects this transport, so a fixture is the
    -- only place the two-sided contract can be observed. The script
    -- echoes its argument and appends whatever standard input it can
    -- read, which must be nothing.
    withFakeExecutable
      "echo-arg"
      -- Shift past the -- separator the way a real tool's own argument
      -- parser would, then echo the prompt and append whatever standard
      -- input can be read, which must be nothing. Reading fails outright
      -- because this transport gives the child no standard input at all,
      -- and that failure is tolerated so the script's own exit code
      -- still reports success.
      "#!/bin/sh\n[ \"$1\" = \"--\" ] && shift\nprintf '%s' \"$1\"\ncat 2>/dev/null || true\n"
    $ \dir exe -> do
      let promptBody = "the prompt is an argument" :: Text.Text
          cmd =
            AgentCommand
              { executable = exe,
                arguments = ["--", Text.unpack promptBody],
                promptTransport = PromptAsArgument,
                promptText = promptBody
              }
      result <-
        runPlain (capturingRequest dir promptBody) cmd >>= expectRan
      capturedBytes (result ^. #stdout) @?= Just (Text.encodeUtf8 promptBody)
      result ^. #exitCode @?= ExitSuccess

timeoutMicrosTests :: TestTree
timeoutMicrosTests =
  testGroup
    "timeout conversion"
    [ testCase "no timeout stays absent" $ timeoutMicros Nothing @?= Nothing,
      testCase "zero means no timeout, not expire immediately" $
        timeoutMicros (Just 0) @?= Nothing,
      testCase "a negative duration means no timeout" $
        timeoutMicros (Just (-5)) @?= Nothing,
      testCase "an ordinary duration converts to microseconds" $
        timeoutMicros (Just 1.5) @?= Just 1500000,
      testCase "a duration too large for an Int means no timeout" $
        timeoutMicros (Just 1e30) @?= Nothing
    ]

stripTrailingNewline :: BS.ByteString -> BS.ByteString
stripTrailingNewline bytes
  | not (BS.null bytes) && BS.last bytes == 10 = BS.init bytes
  | otherwise = bytes

basename :: FilePath -> FilePath
basename = reverse . takeWhile (/= '/') . reverse

waitSeconds :: Int -> IO ()
waitSeconds seconds = threadDelay (seconds * 1000000)
