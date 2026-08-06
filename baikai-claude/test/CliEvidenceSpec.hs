-- | End-to-end model-call evidence for the @claude -p@ subprocess
-- provider.
--
-- Every case here runs a real child process — a few lines of @sh@
-- written into a temporary directory that print recorded @claude@ JSON
-- and exit. Nothing is stubbed: the argument vector is rendered by
-- 'ClaudeCli.claudeCliCommand', the process is spawned by the real
-- provider, the output is decoded by the real parser, and the evidence
-- is assembled and emitted through the real trace path. No credential
-- and no coding-agent binary is required.
--
-- Assertions go through the encoded JSON rather than through Haskell
-- record accessors, because the JSON is the contract other systems pin
-- against, and it spells its fields in snake_case where a Haskell
-- mirror would silently paper over a rename.
module CliEvidenceSpec (tests) where

import Baikai
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Trace (withTraceStreamWith)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    -- Named so a documented @--test-options='--pattern CliEvidence'@
    -- actually selects it. A pattern that matches nothing reports
    -- "All 0 tests passed".
    "CliEvidenceSpec: Claude CLI model-call evidence"
    [ successEvidenceTest,
      silentToolTest,
      minimalCollapseTest,
      indistinguishableCallsTest,
      failedRunTest,
      optOutTest
    ]

-- ============================================================
-- The cases
-- ============================================================

successEvidenceTest :: TestTree
successEvidenceTest =
  testCase "a recorded run records what the tool reported" $ do
    outcome <- replay recordedResult baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "succeeded")
    field "run_id" ev @?= Just (String "run-55")
    field "requested_model" ev @?= Just (String "sonnet")

    -- The session identifier the provider used to decode and then throw
    -- away, one line before hardcoding responseId = Nothing.
    field "response_id" ev @?= Just (observedJson "01890000-0000-4000-8000-000000000001")

    -- The model the tool named as having consumed tokens, complete with
    -- its context-window variant marker, and demonstrably not the
    -- model the caller configured.
    field "observed_model" ev @?= Just (observedJson "claude-opus-5[1m]")
    assertBool
      "observed_model must not be the configured model"
      (field "observed_model" ev /= Just (observedJson "sonnet"))

    -- A subprocess cannot carry an HTTP correlation header, and the
    -- tool does not echo its effort setting. Neither is invented.
    field "provider_request_id" ev @?= Just (String "unobserved")
    field "observed_thinking" ev @?= Just (String "unobserved")

    field "strength" ev @?= Just (String "model_observed")
    assertDigest "request_commitment" ev
    assertDigest "request_configuration" ev
    assertObservedDigest "response_commitment" ev

    -- Not zeroUsage: the tool's own counts, with Anthropic's already
    -- disjoint prompt classes carried through unmodified.
    case observedObject "usage" ev of
      Nothing -> assertFailure ("expected an observed usage, got: " <> show (field "usage" ev))
      Just u -> do
        KeyMap.lookup "input_tokens" u @?= Just (Number 2)
        KeyMap.lookup "output_tokens" u @?= Just (Number 6)
        KeyMap.lookup "cache_read_input_tokens" u @?= Nothing
        KeyMap.lookup "cache_read_tokens" u @?= Just (Number 15185)
        KeyMap.lookup "cache_write_tokens" u @?= Just (Number 7455)

    -- A subprocess has no endpoint URL, so the resolved executable
    -- path stands in its place, and the tool's own version is the
    -- implementation version because for this transport the tool is
    -- the implementation.
    case field "endpoint" ev of
      Just (Object o) -> do
        KeyMap.lookup "transport" o @?= Just (String "subprocess")
        KeyMap.lookup "endpoint" o @?= Just (String (Text.pack (outcome ^. #executable)))
        KeyMap.lookup "implementation_version" o @?= Just (String "fake-claude 9.9.9")
      other -> assertFailure ("expected an endpoint object, got: " <> show other)

silentToolTest :: TestTree
silentToolTest =
  testCase "A ZERO EXIT WITH NO IDENTIFIER AND NO MODEL STAYS AT requested_only" $ do
    -- IR-3's rule and the reason this plan exists. A coding-agent CLI
    -- that exits zero has demonstrated that it ran and did not crash.
    -- Subprocess calls almost always exit zero, so encoding that as
    -- corroboration would make the weakest evidence in the system look
    -- like the strongest.
    outcome <- replay silentResult baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "succeeded")
    field "strength" ev @?= Just (String "requested_only")
    field "response_id" ev @?= Just (String "unobserved")
    field "observed_model" ev @?= Just (String "unobserved")
    field "usage" ev @?= Just (String "unobserved")

minimalCollapseTest :: TestTree
minimalCollapseTest =
  testCase "a minimal request records the --effort low collapse it actually sent" $ do
    -- The description and the argument vector are asserted together so
    -- they cannot drift apart.
    outcome <- replay recordedResult (baseOptions & #thinking .~ Just ThinkingMinimal)
    assertBool
      ("the argument vector must carry --effort low: " <> show (outcome ^. #argv))
      (["--effort", "low"] `isSublistOf` (outcome ^. #argv))
    ev <- oneEvidence (outcome ^. #events)
    case field "thinking" ev of
      Just (Object t) -> do
        KeyMap.lookup "requested" t @?= Just (String "minimal")
        KeyMap.lookup "mode" t @?= Just (String "flag")
        KeyMap.lookup "effort_text" t @?= Just (String "low")
        KeyMap.lookup "wire_field" t @?= Just (String "--effort")
        KeyMap.lookup "budget_tokens" t @?= Just Null
        KeyMap.lookup "adjustments" t
          @?= Just
            ( Array
                ( Vector.singleton
                    ( Object
                        ( KeyMap.fromList
                            [ ("kind", String "effort_clamped"),
                              ("requested", String "minimal"),
                              ("wire", String "low")
                            ]
                        )
                    )
                )
            )
      other -> assertFailure ("expected a thinking translation, got: " <> show other)

indistinguishableCallsTest :: TestTree
indistinguishableCallsTest =
  testCase "TWO CALLS THE TOOL CANNOT TELL APART PRODUCE EVIDENCE THAT CAN" $ do
    -- This is the case that demonstrates why the record exists rather
    -- than merely that a field is populated. A caller asking for
    -- minimal and a caller asking for low send byte-identical command
    -- lines, so nothing downstream of the argument vector could ever
    -- recover the difference — including the request commitment digest,
    -- which is computed over that vector. The translation is the only
    -- place the collapse survives.
    withFakeClaude recordedResult $ \runOnce -> do
      lowRun <- runOnce (baseOptions & #thinking .~ Just ThinkingLow)
      minimalRun <- runOnce (baseOptions & #thinking .~ Just ThinkingMinimal)
      minimalRun ^. #argv @?= lowRun ^. #argv

      lowEv <- oneEvidence (lowRun ^. #events)
      minimalEv <- oneEvidence (minimalRun ^. #events)
      field "request_commitment" minimalEv @?= field "request_commitment" lowEv

      requestedLevel lowEv @?= Just (String "low")
      requestedLevel minimalEv @?= Just (String "minimal")
      adjustmentCount lowEv @?= Just 0
      adjustmentCount minimalEv @?= Just 1

failedRunTest :: TestTree
failedRunTest =
  testCase "a tool that exits nonzero records the failure and commits to no response" $ do
    outcome <- replay Nothing baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "failed")
    case field "error_info" ev of
      Just (Object o) ->
        assertBool
          ("expected a populated error_info, got: " <> show o)
          (KeyMap.member "message" o)
      other -> assertFailure ("expected a populated error_info, got: " <> show other)
    -- No parseable result means nothing to commit to. A digest of an
    -- empty envelope would be a real-looking value standing for a
    -- response that never arrived.
    field "response_commitment" ev @?= Just (String "unobserved")
    field "usage" ev @?= Just (String "unobserved")
    field "strength" ev @?= Just (String "requested_only")

optOutTest :: TestTree
optOutTest =
  testCase "a call that asked for no evidence emits none" $ do
    outcome <- replay recordedResult emptyOptions
    [e | e@CallEvidence {} <- outcome ^. #events] @?= []
    length [e | e@CallStarted {} <- outcome ^. #events] @?= 1
    length [e | e@CallFinished {} <- outcome ^. #events] @?= 1

-- ============================================================
-- Replay harness
-- ============================================================

-- | What one replayed call produced.
data Replay = Replay
  { events :: ![TraceEvent],
    -- | The argument vector the fake executable actually received.
    argv :: ![Text],
    -- | The path the fake executable was written to.
    executable :: !FilePath
  }
  deriving stock (Generic)

-- | Run one call against a fake @claude@ that prints the given JSON on
-- standard output.
--
-- 'Nothing' makes the fake exit nonzero with a message on standard
-- error, which is how a failed run is replayed.
replay :: Maybe Text -> Options -> IO Replay
replay stdoutJson opts = withFakeClaude stdoutJson ($ opts)

-- | Write one fake @claude@ and hand back a function that runs calls
-- against it.
--
-- Two calls compared against each other must go through the __same__
-- fake, because the argument vector the request commitment digests
-- begins with the executable's path — so two fakes in two temporary
-- directories would differ for a reason that has nothing to do with
-- what the test is about.
withFakeClaude :: Maybe Text -> ((Options -> IO Replay) -> IO a) -> IO a
withFakeClaude stdoutJson k =
  withSystemTempDirectory "baikai-claude-cli-evidence" $ \dir -> do
    let argvPath = dir </> "argv"
    exe <- writeFakeExecutable dir "claude" (fakeClaude argvPath stdoutJson)
    k $ \opts -> do
      reg <- newProviderRegistry
      registerApiProviderWith
        reg
        ( ClaudeCli.claudeCliProvider
            ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = exe}
        )
      (ref, sink) <- memorySink
      _ <- Stream.fold Fold.drain (withTraceStreamWith reg sink testModel testContext opts)
      recorded <- reverse <$> readTVarIO ref
      received <- Text.lines <$> TextIO.readFile argvPath
      pure Replay {events = recorded, argv = received, executable = exe}

-- | A fake @claude@ in a few lines of @sh@.
--
-- It answers @--version@ before recording anything, exactly as the real
-- tool does. That is not decoration: the evidence path probes the
-- executable's version with a second invocation, and a fake that
-- recorded that invocation's argument vector would overwrite the one
-- the test is about to assert on.
fakeClaude :: FilePath -> Maybe Text -> String
fakeClaude argvPath stdoutJson =
  unlines
    ( [ "#!/bin/sh",
        "if [ \"$1\" = \"--version\" ]; then echo 'fake-claude 9.9.9'; exit 0; fi",
        "printf '%s\\n' \"$@\" > '" <> argvPath <> "'"
      ]
        <> case stdoutJson of
          Nothing -> ["echo 'the tool refused' >&2", "exit 3"]
          Just body -> ["cat <<'BAIKAI_FIXTURE'", Text.unpack body, "BAIKAI_FIXTURE"]
    )

writeFakeExecutable :: FilePath -> String -> String -> IO FilePath
writeFakeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

memorySink :: IO (TVar [TraceEvent], TraceSink)
memorySink = do
  ref <- newTVarIO []
  let step () e = atomically (modifyTVar' ref (e :))
  pure (ref, TraceSink (Fold.foldlM' step (pure ())))

-- ============================================================
-- Fixtures
-- ============================================================

testModel :: Model
testModel =
  emptyModel
    & #modelId .~ "sonnet"
    & #api .~ AnthropicMessagesCli
    & #provider .~ "anthropic"

testContext :: Context
testContext = emptyContext & #messages .~ Vector.singleton (user "PROMPT-BODY-MARKER")

baseOptions :: Options
baseOptions = emptyOptions & #evidence .~ Just (evidenceRequest "run-55")

-- | The event array @claude 2.1.222@ emits, trimmed to the fields the
-- provider reads and with the identifiers scrubbed.
recordedResult :: Maybe Text
recordedResult =
  Just
    "[{\"type\":\"system\",\"subtype\":\"init\",\
    \\"session_id\":\"01890000-0000-4000-8000-000000000001\"},\
    \{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"ok\",\
    \\"session_id\":\"01890000-0000-4000-8000-000000000001\",\
    \\"total_cost_usd\":0.0823025,\
    \\"usage\":{\"input_tokens\":2,\"output_tokens\":6,\
    \\"cache_read_input_tokens\":15185,\"cache_creation_input_tokens\":7455},\
    \\"modelUsage\":{\"claude-opus-5[1m]\":{\"inputTokens\":2,\"outputTokens\":6}}}]"

-- | A run that succeeded and said nothing about itself.
silentResult :: Maybe Text
silentResult = Just "[{\"type\":\"result\",\"is_error\":false,\"result\":\"ok\"}]"

-- ============================================================
-- Assertions on the encoded record
-- ============================================================

oneEvidence :: [TraceEvent] -> IO ModelCallEvidence
oneEvidence recorded = case [ev | CallEvidence {evidence = ev} <- recorded] of
  [ev] -> pure ev
  other ->
    assertFailure
      ("expected exactly one CallEvidence, got " <> show (length other) <> ": " <> show recorded)

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

requestedLevel :: ModelCallEvidence -> Maybe Value
requestedLevel ev = case field "thinking" ev of
  Just (Object t) -> KeyMap.lookup "requested" t
  _ -> Nothing

adjustmentCount :: ModelCallEvidence -> Maybe Int
adjustmentCount ev = case field "thinking" ev of
  Just (Object t) -> case KeyMap.lookup "adjustments" t of
    Just (Array a) -> Just (Vector.length a)
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

isSublistOf :: (Eq a) => [a] -> [a] -> Bool
isSublistOf needle haystack =
  any (\suffix -> needle == take (length needle) suffix) (suffixes haystack)
  where
    suffixes xs =
      xs : case xs of
        [] -> []
        (_ : rest) -> suffixes rest
