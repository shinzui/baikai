-- | Model-call evidence for an unattended coding-agent run.
--
-- Every case here spawns a real child process — a few lines of @sh@
-- written into a temporary directory — and reads the evidence back off
-- the 'AgentRunOutcome' the real runner returns. Nothing is stubbed: the
-- process is spawned, drained, and timed by production code, and the
-- record is assembled by it too. No credential and no coding-agent
-- binary is required.
--
-- Assertions go through the encoded JSON rather than through Haskell
-- record accessors, because the JSON is the contract other systems pin
-- against, and it spells its fields in snake_case where a Haskell mirror
-- would silently paper over a rename.
module EvidenceTests (evidenceTests) where

import Baikai.Agent
  ( AgentCommand (..),
    AgentOutputMode (..),
    AgentPromptTransport (..),
    AgentProvider (..),
    AgentRunFailure (..),
    AgentRunOutcome (..),
    AgentRunRequest,
    agentRunRequest,
  )
import Baikai.Agent.Run
  ( agentConfigurationEnvelope,
    agentRequestEnvelope,
    errorInfoStderrTailBytes,
    runAgentCommand,
  )
import Baikai.Evidence
  ( EvidenceRequest,
    EvidenceStrength (..),
    EvidenceStrictness (..),
    ModelCallEvidence,
    ThinkingTranslation,
    canonicalEncode,
    evidenceRequest,
    noThinkingRequested,
  )
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getPermissions,
    setOwnerExecutable,
    setPermissions,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

evidenceTests :: TestTree
evidenceTests =
  testGroup
    "unattended run evidence"
    [ reportedRunTest,
      silentToolTest,
      nonZeroExitTest,
      timedOutRunTest,
      inheritedOutputTest,
      nothingStartedTest,
      relativeExecutableEndpointTest,
      errorInfoIsBoundedTest,
      optOutTest,
      strictRefusalTests,
      digestTests
    ]

-- ====================================================================
-- The cases
-- ====================================================================

reportedRunTest :: TestTree
reportedRunTest =
  testCase "a tool that reports a session and a model is recorded as saying so" $
    -- Neither vendor renderer asks its tool for structured output, so
    -- this is the shape an operator gets only after configuring
    -- `--output-format json` through the job's extra arguments. That is
    -- a real constraint and the runner's documentation states it.
    withFake "#!/bin/sh\ncat > /dev/null\necho '" claudeResultJson "'\n" $ \dir exe -> do
      ev <- oneEvidence =<< run (wanted "run-56") dir exe []
      field "status" ev @?= Just (String "succeeded")
      field "run_id" ev @?= Just (String "run-56")
      field "response_id" ev @?= Just (observedJson "sess-abc123")
      field "observed_model" ev @?= Just (observedJson "claude-opus-5[1m]")
      field "strength" ev @?= Just (String "model_observed")
      case observedObject "usage" ev of
        Nothing -> assertFailure ("expected an observed usage, got: " <> show (field "usage" ev))
        Just u -> do
          KeyMap.lookup "input_tokens" u @?= Just (Number 11)
          KeyMap.lookup "output_tokens" u @?= Just (Number 5)
      -- A subprocess has no endpoint URL and no wire protocol; the
      -- resolved executable path and this surface's own name stand in.
      case field "endpoint" ev of
        Just (Object o) -> do
          KeyMap.lookup "transport" o @?= Just (String "agent_run")
          KeyMap.lookup "api" o @?= Just (String "agent_run")
          KeyMap.lookup "provider" o @?= Just (String "claude")
          KeyMap.lookup "endpoint" o @?= Just (String (Text.pack exe))
        other -> assertFailure ("expected an endpoint object, got: " <> show other)
      assertDigest "request_commitment" ev
      assertDigest "request_configuration" ev
      assertObservedDigest "response_commitment" ev

silentToolTest :: TestTree
silentToolTest =
  testCase "A ZERO EXIT WITH NO IDENTIFIER AND NO MODEL STAYS AT requested_only" $
    -- IR-3's rule, and the one this surface is most likely to violate by
    -- accident: almost every unattended run exits zero. A coding agent
    -- that exits zero has demonstrated that it ran, not which model
    -- served it.
    withFake "#!/bin/sh\ncat > /dev/null\necho '" "the task is done" "'\n" $ \dir exe -> do
      ev <- oneEvidence =<< run (wanted "run-56") dir exe []
      field "status" ev @?= Just (String "succeeded")
      field "strength" ev @?= Just (String "requested_only")
      field "response_id" ev @?= Just (String "unobserved")
      field "observed_model" ev @?= Just (String "unobserved")
      field "usage" ev @?= Just (String "unobserved")
      -- The run still produced output, so the commitment to it is real.
      assertObservedDigest "response_commitment" ev

nonZeroExitTest :: TestTree
nonZeroExitTest =
  testCase "a non-zero exit is recorded as failed, and the exit code changes no strength" $
    withFake "#!/bin/sh\ncat > /dev/null\necho '" claudeResultJson "'\nexit 3\n" $ \dir exe -> do
      ev <- oneEvidence =<< run (wanted "run-56") dir exe []
      field "status" ev @?= Just (String "failed")
      case field "error_info" ev of
        Just (Object o) ->
          assertBool
            ("expected a populated error_info, got: " <> show o)
            (KeyMap.member "message" o)
        other -> assertFailure ("expected a populated error_info, got: " <> show other)
      -- The tool named itself before it failed, so the strength is what
      -- it reported — not something derived from exiting 3.
      field "response_id" ev @?= Just (observedJson "sess-abc123")
      field "strength" ev @?= Just (String "model_observed")
      -- No successful run means nothing complete to commit to.
      field "response_commitment" ev @?= Just (String "unobserved")

timedOutRunTest :: TestTree
timedOutRunTest =
  testCase "A RUN KILLED BY ITS OWN TIMEOUT STILL PRODUCES A RECORD" $
    -- The reason evidence travels beside the outcome rather than inside
    -- AgentRunResult. A timed-out run started, consumed tokens, and may
    -- have changed the working tree; it reports Left RunTimedOut, so a
    -- record hanging off the Right would be unreachable exactly here.
    withFake "#!/bin/sh\n" "sleep 30" "\n" $ \dir exe -> do
      outcome <- runWith (wanted "run-56") dir exe [] (\req -> req & #timeout .~ Just 1)
      case outcome ^. #outcome of
        Right ran -> assertFailure ("expected a timeout, the run finished: " <> show ran)
        Left _ -> pure ()
      ev <- oneEvidence outcome
      field "status" ev @?= Just (String "aborted")
      field "strength" ev @?= Just (String "requested_only")
      field "response_commitment" ev @?= Just (String "unobserved")
      case field "error_info" ev of
        Just (Object o) -> assertBool ("names the timeout: " <> show o) (KeyMap.member "message" o)
        other -> assertFailure ("expected a populated error_info, got: " <> show other)

inheritedOutputTest :: TestTree
inheritedOutputTest =
  testCase "an inherited run observes nothing, because there are no bytes to read" $
    -- Under `inherit` the agent's output went to this process's own
    -- terminal and baikai never held it. Every tool-reported field is
    -- therefore Unobserved — which is the honest answer, and is why the
    -- runner's documentation tells an operator who needs correlated
    -- evidence to capture output.
    withFake "#!/bin/sh\necho '" claudeResultJson "'\n" $ \dir exe -> do
      outcome <- runWith (wanted "run-56") dir exe [] (\req -> req & #output .~ InheritOutput)
      ev <- oneEvidence outcome
      field "status" ev @?= Just (String "succeeded")
      field "response_id" ev @?= Just (String "unobserved")
      field "observed_model" ev @?= Just (String "unobserved")
      field "usage" ev @?= Just (String "unobserved")
      field "response_commitment" ev @?= Just (String "unobserved")
      field "strength" ev @?= Just (String "requested_only")

nothingStartedTest :: TestTree
nothingStartedTest =
  testCase "a run that never started produces no evidence at all" $
    -- There is nothing to describe. An evidence record for a process
    -- that was never created would assert a run happened.
    withSystemTempDirectory "baikai-agent-evidence" $ \dir -> do
      let missing = dir </> "not-installed"
      outcome <- run (wanted "run-56") dir missing []
      case outcome ^. #outcome of
        Right ran -> assertFailure ("expected a spawn failure, got: " <> show ran)
        Left _ -> pure ()
      outcome ^. #evidence @?= Nothing

relativeExecutableEndpointTest :: TestTree
relativeExecutableEndpointTest =
  testCase "a relative executable is resolved against the working directory" $
    -- The child execs relative to the working directory the runner sets,
    -- so the evidence probe — which runs in the parent, whose working
    -- directory is somewhere else entirely — has to resolve the same
    -- way. Before this it probed the parent's own directory and reported
    -- a path that does not exist.
    withSystemTempDirectory "baikai-agent-relative" $ \dir -> do
      createDirectoryIfMissing True (dir </> "bin")
      _ <- writeFakeExecutable (dir </> "bin") "fake" "#!/bin/sh\ncat > /dev/null\nexit 0\n"
      outcome <- run (wanted "run-relative") dir ("." </> "bin" </> "fake") []
      ev <- oneEvidence outcome
      case field "endpoint" ev of
        Just (Object o) ->
          KeyMap.lookup "endpoint" o
            @?= Just (String (Text.pack (dir </> "bin" </> "fake")))
        other -> assertFailure ("expected an endpoint object, got: " <> show other)

errorInfoIsBoundedTest :: TestTree
errorInfoIsBoundedTest =
  testCase "a failing run's error message keeps the tail of its standard error"
    $
    -- The output limit lets a captured stream reach mebibytes, and
    -- before this the whole of it went into one error message. The last
    -- few kibibytes are where a failing tool's actual reason lives, and
    -- the prefix says what was dropped so the message does not read as a
    -- corrupted record.
    withFake
      "#!/bin/sh\ncat > /dev/null\n"
      "i=0; while [ $i -lt 2000 ]; do \
      \printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' >&2; \
      \i=$((i+1)); done; printf 'final: reason\\n' >&2"
      "\nexit 1\n"
    $ \dir exe -> do
      ev <- oneEvidence =<< run (wanted "run-noisy") dir exe []
      case field "error_info" ev of
        Just (Object o) -> case KeyMap.lookup "message" o of
          Just (String message) -> do
            assertBool
              ("expected a bounded message, got " <> show (Text.length message) <> " characters")
              (Text.length message < errorInfoStderrTailBytes + 80)
            assertBool
              ("expected the tool's last line in: " <> Text.unpack message)
              ("final: reason" `Text.isInfixOf` message)
            assertBool
              ("expected the truncation prefix in: " <> Text.unpack message)
              ("[stderr truncated" `Text.isPrefixOf` message)
          other -> assertFailure ("expected a message string, got: " <> show other)
        other -> assertFailure ("expected an error_info object, got: " <> show other)

optOutTest :: TestTree
optOutTest =
  testCase "A RUN THAT ASKED FOR NO EVIDENCE SPAWNS EXACTLY ONE PROCESS" $
    -- The absent field is the easy half. The process count is the half
    -- that catches a --version probe firing on a path it must never
    -- reach: the probe is a whole extra subprocess, and an unattended
    -- run can be one short invocation.
    withSystemTempDirectory "baikai-agent-evidence" $ \dir -> do
      let ledger = dir </> "invocations"
      exe <-
        writeFakeExecutable
          dir
          "counted"
          ("#!/bin/sh\ncat > /dev/null\necho x >> '" <> ledger <> "'\necho done\n")
      optedOut <- run Nothing dir exe []
      optedOut ^. #evidence @?= Nothing
      afterOptOut <- invocationCount ledger
      afterOptOut @?= 1

      -- And the contrast, so the assertion above cannot pass because
      -- the fake was never run at all: opting in probes the executable
      -- as well as running it.
      optedIn <- run (wanted "run-56") dir exe []
      assertBool "the opted-in run built evidence" (optedIn ^. #evidence /= Nothing)
      afterOptIn <- invocationCount ledger
      assertBool
        ("the opted-in run also probed the executable, saw " <> show afterOptIn)
        (afterOptIn > afterOptOut + 1)

-- ====================================================================
-- Strict evidence on this surface
-- ====================================================================

strictRefusalTests :: TestTree
strictRefusalTests =
  testGroup
    -- The agent surface never touches ApiProvider and has no trace
    -- sink, so neither of the gates the completion path uses reaches
    -- it. These prove its own.
    "a run that cannot produce the required evidence is refused before it starts"
    [ testCase "AN INHERIT JOB DEMANDING A CORRELATED RECORD IS REFUSED" $
        -- The most useful refusal on this surface. Under inherit the
        -- agent's bytes go to the operator's terminal and baikai never
        -- holds them, so nothing the tool says can be observed however
        -- well the run goes. Finding that out before the run rather than
        -- from an empty record is the point.
        withFake "#!/bin/sh\ncat > /dev/null\necho '" "ok" "'\n" $ \dir exe -> do
          let ledger = dir </> "invocations"
          recording <- writeFakeExecutable dir "counted" ("#!/bin/sh\necho x >> '" <> ledger <> "'\n")
          outcome <-
            runWith
              (requiring EvidenceCorrelated)
              dir
              recording
              []
              (\req -> req & #output .~ InheritOutput)
          case outcome ^. #outcome of
            Right ran -> assertFailure ("expected a refusal, the run started: " <> show ran)
            Left failure -> case failure of
              EvidenceRefused reasons ->
                assertBool
                  ("the refusal explains itself: " <> show reasons)
                  (any ("requested_only" `Text.isInfixOf`) reasons)
              other -> assertFailure ("expected EvidenceRefused, got: " <> show other)
          outcome ^. #evidence @?= Nothing
          started <- invocationCount ledger
          started @?= 0
          -- `exe` is unused on this path; naming it keeps withFake's
          -- shape rather than adding a second helper.
          assertBool "the fixture executable exists" (not (null exe)),
      testCase "a codex job demanding a model is refused, because codex names none" $
        withFake "#!/bin/sh\n" "exit 0" "\n" $ \dir exe -> do
          outcome <-
            runWith
              (requiring EvidenceModelObserved)
              dir
              exe
              []
              (\req -> req & #provider .~ AgentCodex)
          case outcome ^. #outcome of
            Left (EvidenceRefused _) -> pure ()
            other -> assertFailure ("expected EvidenceRefused, got: " <> show other),
      testCase "a capturing claude job demanding a model is allowed to try" $
        -- Structural, not predictive: this run may or may not report a
        -- model, and the gate must not pretend to know. The record's own
        -- strength is where the caller reads what actually happened.
        withFake "#!/bin/sh\ncat > /dev/null\necho '" claudeResultJson "'\n" $ \dir exe -> do
          outcome <- run (requiring EvidenceModelObserved) dir exe []
          case outcome ^. #outcome of
            Left failure -> assertFailure ("expected the run to start: " <> show failure)
            Right _ -> pure ()
          ev <- oneEvidence outcome
          field "strength" ev @?= Just (String "model_observed"),
      testCase "a best-effort caller is never refused, whatever the configuration" $
        withFake "#!/bin/sh\n" "exit 0" "\n" $ \dir exe -> do
          outcome <-
            runWith (wanted "run-56") dir exe [] (\req -> req & #output .~ InheritOutput)
          case outcome ^. #outcome of
            Left failure -> assertFailure ("a best-effort run must not be refused: " <> show failure)
            Right _ -> pure ()
    ]

requiring :: EvidenceStrength -> Maybe EvidenceRequest
requiring needed =
  Just (evidenceRequest "run-57" & #strictness .~ EvidenceRequired needed)

-- ====================================================================
-- The digests
-- ====================================================================

digestTests :: TestTree
digestTests =
  testGroup
    -- The subtlest part of this surface. Both vendor renderers put the
    -- prompt on standard input, so a commitment computed over the
    -- argument vector alone would give two runs with identical flags and
    -- completely different instructions the same digest.
    "the prompt is committed to under both transports and excluded from the configuration"
    [ testCase (label transport) $ do
        let one = command transport "first instruction"
            two = command transport "second instruction"
        assertBool
          "two prompts must not share a request commitment"
          (encoded (agentRequestEnvelope one) /= encoded (agentRequestEnvelope two))
        encoded (agentConfigurationEnvelope one) @?= encoded (agentConfigurationEnvelope two)
        assertBool
          "the commitment input must contain the prompt"
          ("PROMPT-BODY-MARKER" `isInfixOf` encoded (agentRequestEnvelope (command transport marker)))
        assertBool
          "the configuration input must not contain the prompt"
          ( not
              ( "PROMPT-BODY-MARKER"
                  `isInfixOf` encoded (agentConfigurationEnvelope (command transport marker))
              )
          )
    | transport <- [PromptOnStdin, PromptAsArgument]
    ]
  where
    marker = "PROMPT-BODY-MARKER"
    label PromptOnStdin = "prompt on standard input"
    label PromptAsArgument = "prompt as an argument"
    encoded = BS8.unpack . canonicalEncode
    -- Under PromptAsArgument the prompt is in the vector too, which is
    -- what makes excluding it from the configuration a real operation
    -- rather than a no-op.
    command transport promptBody =
      AgentCommand
        { executable = "/bin/agent",
          arguments =
            ["-p", "--effort", "high"]
              <> case transport of
                PromptAsArgument -> ["--", Text.unpack promptBody]
                PromptOnStdin -> [],
          promptTransport = transport,
          promptText = promptBody
        }

-- ====================================================================
-- Harness
-- ====================================================================

-- | Run one command against a fake executable rooted in a directory.
run :: Maybe EvidenceRequest -> FilePath -> FilePath -> [String] -> IO AgentRunOutcome
run evidenceReq dir exe args = runWith evidenceReq dir exe args id

runWith ::
  Maybe EvidenceRequest ->
  FilePath ->
  FilePath ->
  [String] ->
  (AgentRunRequest -> AgentRunRequest) ->
  IO AgentRunOutcome
runWith evidenceReq dir exe args adjust =
  runAgentCommand evidenceReq translation (adjust request) command
  where
    request =
      agentRunRequest AgentClaude dir "PROMPT-BODY-MARKER" & #output .~ CaptureOutput
    command =
      AgentCommand
        { executable = exe,
          arguments = args,
          promptTransport = PromptOnStdin,
          promptText = "PROMPT-BODY-MARKER"
        }

-- | Every case here drives the runner directly rather than through a
-- vendor renderer, so there is no translation to carry. The renderers'
-- own translations are asserted in each vendor package's test suite.
translation :: ThinkingTranslation
translation = noThinkingRequested

wanted :: Text -> Maybe EvidenceRequest
wanted = Just . evidenceRequest

-- | Write a fake tool from three pieces, so a case can wrap recorded
-- JSON in shell quoting without escaping it twice.
withFake :: String -> String -> String -> (FilePath -> FilePath -> IO a) -> IO a
withFake before body after action =
  withSystemTempDirectory "baikai-agent-evidence" $ \dir -> do
    exe <- writeFakeExecutable dir "fake-agent" (before <> body <> after)
    action dir exe

writeFakeExecutable :: FilePath -> String -> String -> IO FilePath
writeFakeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

invocationCount :: FilePath -> IO Int
invocationCount path = do
  here <- doesFileExist path
  if here then length . lines <$> readFile path else pure 0

-- | A @claude -p --output-format json@ result, as the tool emits one
-- when an operator has configured that format through the job's extra
-- arguments. Single-quote-free so it survives the shell wrapping above.
claudeResultJson :: String
claudeResultJson =
  "{\"type\":\"result\",\"is_error\":false,\"result\":\"done\",\
  \\"session_id\":\"sess-abc123\",\
  \\"usage\":{\"input_tokens\":11,\"output_tokens\":5},\
  \\"modelUsage\":{\"claude-opus-5[1m]\":{\"inputTokens\":11}}}"

-- ====================================================================
-- Assertions on the encoded record
-- ====================================================================

oneEvidence :: AgentRunOutcome -> IO ModelCallEvidence
oneEvidence outcome = case outcome ^. #evidence of
  Just ev -> pure ev
  Nothing -> assertFailure "expected the run to produce evidence"

field :: Text -> ModelCallEvidence -> Maybe Value
field k ev = case Aeson.toJSON ev of
  Object o -> KeyMap.lookup (Key.fromText k) o
  _ -> Nothing

-- | How 'Baikai.Evidence.Observed' encodes a present value.
observedJson :: Text -> Value
observedJson v = Object (KeyMap.singleton "observed" (String v))

observedObject :: Text -> ModelCallEvidence -> Maybe (KeyMap.KeyMap Value)
observedObject k ev = case field k ev of
  Just (Object o) -> case KeyMap.lookup "observed" o of
    Just (Object inner) -> Just inner
    _ -> Nothing
  _ -> Nothing

assertDigest :: Text -> ModelCallEvidence -> IO ()
assertDigest k ev = case field k ev of
  Just (String d) -> assertSha256 k d
  other -> assertFailure (Text.unpack k <> " missing or not a string: " <> show other)

assertObservedDigest :: Text -> ModelCallEvidence -> IO ()
assertObservedDigest k ev = case field k ev of
  Just (Object o) -> case KeyMap.lookup "observed" o of
    Just (String d) -> assertSha256 k d
    other -> assertFailure (Text.unpack k <> " not a digest: " <> show other)
  other -> assertFailure ("expected an observed " <> Text.unpack k <> ", got: " <> show other)

assertSha256 :: Text -> Text -> IO ()
assertSha256 k d =
  assertBool
    (Text.unpack k <> " must be a sha256 digest, got: " <> show d)
    ("sha256:" `Text.isPrefixOf` d && Text.length d == 71)
