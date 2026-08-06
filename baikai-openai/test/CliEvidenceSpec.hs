-- | End-to-end model-call evidence for the @codex exec --json@
-- subprocess provider.
--
-- Every case here runs a real child process — a few lines of @sh@
-- written into a temporary directory that print a recorded @codex@
-- event stream and exit. Nothing is stubbed: the argument vector is
-- rendered by 'CodexCli.codexCliCommand', the process is spawned by the
-- real provider, the event stream is folded by the real parser, and the
-- evidence is assembled and emitted through the real trace path. No
-- credential and no coding-agent binary is required.
--
-- Assertions go through the encoded JSON rather than through Haskell
-- record accessors, because the JSON is the contract other systems pin
-- against, and it spells its fields in snake_case where a Haskell
-- mirror would silently paper over a rename.
module CliEvidenceSpec (tests) where

import Baikai
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
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
    "CliEvidenceSpec: Codex CLI model-call evidence"
    [ successEvidenceTest,
      silentToolTest,
      everyLevelSurvivesTest,
      partiallyObservedFailureTest,
      optOutTest
    ]

-- ============================================================
-- The cases
-- ============================================================

successEvidenceTest :: TestTree
successEvidenceTest =
  testCase "a recorded run records what the tool reported, and no more" $ do
    outcome <- replay recordedEvents baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "succeeded")
    field "run_id" ev @?= Just (String "run-55")
    field "requested_model" ev @?= Just (String "gpt-5.6")

    -- The thread identifier the parser used to filter out of the event
    -- stream along with everything that was not an agent_message.
    field "response_id" ev @?= Just (observedJson "019fd471-4a48-7c83-be67-6b7c49646e43")

    -- THE CODEX-SPECIFIC LIMIT. codex-cli 0.146.0 names no model
    -- anywhere in its event stream, so no codex run can reach
    -- model_observed however well it goes. Backfilling the --model
    -- flag baikai passed would report the request as an observation,
    -- and would make this transport look as strong as the API one.
    field "observed_model" ev @?= Just (String "unobserved")
    field "strength" ev @?= Just (String "correlated")

    field "provider_request_id" ev @?= Just (String "unobserved")
    field "observed_thinking" ev @?= Just (String "unobserved")

    assertDigest "request_commitment" ev
    assertDigest "request_configuration" ev
    assertObservedDigest "response_commitment" ev

    -- Not zeroUsage, and normalized: codex reports OpenAI-style
    -- inclusive prompt counts, so the cached tokens come out of
    -- input_tokens (16071 - 6912).
    case observedObject "usage" ev of
      Nothing -> assertFailure ("expected an observed usage, got: " <> show (field "usage" ev))
      Just u -> do
        KeyMap.lookup "input_tokens" u @?= Just (Number 9159)
        KeyMap.lookup "cache_read_tokens" u @?= Just (Number 6912)
        KeyMap.lookup "output_tokens" u @?= Just (Number 5)
        KeyMap.lookup "reasoning_tokens" u @?= Just (Number 0)

    case field "endpoint" ev of
      Just (Object o) -> do
        KeyMap.lookup "transport" o @?= Just (String "subprocess")
        KeyMap.lookup "endpoint" o @?= Just (String (Text.pack (outcome ^. #executable)))
        KeyMap.lookup "implementation_version" o @?= Just (String "codex-cli 9.9.9")
      other -> assertFailure ("expected an endpoint object, got: " <> show other)

silentToolTest :: TestTree
silentToolTest =
  testCase "A ZERO EXIT WITH NO IDENTIFIER AND NO MODEL STAYS AT requested_only" $ do
    -- IR-3's rule and the reason this plan exists. A coding-agent CLI
    -- that exits zero has demonstrated that it ran and did not crash.
    -- Subprocess calls almost always exit zero, so encoding that as
    -- corroboration would make the weakest evidence in the system look
    -- like the strongest.
    outcome <- replay silentEvents baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "succeeded")
    field "strength" ev @?= Just (String "requested_only")
    field "response_id" ev @?= Just (String "unobserved")
    field "observed_model" ev @?= Just (String "unobserved")
    field "usage" ev @?= Just (String "unobserved")

everyLevelSurvivesTest :: TestTree
everyLevelSurvivesTest =
  testGroup
    -- Codex is the only transport in baikai that expresses all six
    -- levels exactly, which is worth asserting precisely because every
    -- other transport clamps, collapses, or drops something.
    "every canonical level reaches the command line verbatim"
    [ testCase (Text.unpack (renderThinkingLevel level)) $ do
        outcome <- replay recordedEvents (baseOptions & #thinking .~ Just level)
        let expected = "model_reasoning_effort=" <> renderThinkingLevel level
        assertBool
          ("the argument vector must carry " <> Text.unpack expected <> ": " <> show (outcome ^. #argv))
          (["-c", expected] `isSublistOf` (outcome ^. #argv))
        ev <- oneEvidence (outcome ^. #events)
        case field "thinking" ev of
          Just (Object t) -> do
            KeyMap.lookup "requested" t @?= Just (String (renderThinkingLevel level))
            KeyMap.lookup "mode" t @?= Just (String "flag")
            KeyMap.lookup "effort_text" t @?= Just (String (renderThinkingLevel level))
            KeyMap.lookup "wire_field" t @?= Just (String "model_reasoning_effort")
            KeyMap.lookup "budget_tokens" t @?= Just Null
            -- Nothing happened to the request on the way to the wire.
            KeyMap.lookup "adjustments" t @?= Just (Array Vector.empty)
          other -> assertFailure ("expected a thinking translation, got: " <> show other)
    | level <-
        [ ThinkingMinimal,
          ThinkingLow,
          ThinkingMedium,
          ThinkingHigh,
          ThinkingXHigh,
          ThinkingMax
        ]
    ]

partiallyObservedFailureTest :: TestTree
partiallyObservedFailureTest =
  testCase "a failed run keeps the identifier it saw and commits to no response" $ do
    -- The event stream is drained before the exit status is known, so a
    -- run that named its thread and then failed really did name it.
    -- Discarding that would throw away the single most useful thing to
    -- have when opening a vendor support request.
    outcome <- replay failingEvents baseOptions
    ev <- oneEvidence (outcome ^. #events)
    field "status" ev @?= Just (String "failed")
    field "response_id" ev @?= Just (observedJson "019fd471-dead-7c83-be67-6b7c49646e43")
    field "strength" ev @?= Just (String "correlated")
    -- No complete response exists, so there is nothing to commit to. A
    -- digest of an empty envelope would be a real-looking value
    -- standing for a response that never arrived.
    field "response_commitment" ev @?= Just (String "unobserved")
    field "usage" ev @?= Just (String "unobserved")

optOutTest :: TestTree
optOutTest =
  testCase "a call that asked for no evidence emits none" $ do
    outcome <- replay recordedEvents emptyOptions
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

-- | Run one call against a fake @codex@ that prints the given
-- newline-delimited event stream on standard output.
replay :: ([Text], Int) -> Options -> IO Replay
replay recording opts =
  withSystemTempDirectory "baikai-openai-cli-evidence" $ \dir -> do
    let argvPath = dir </> "argv"
    exe <- writeFakeExecutable dir "codex" (fakeCodex argvPath recording)
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      ( CodexCli.codexCliProvider
          CodexCli.defaultCodexCliConfig {CodexCli.executable = exe}
      )
    (ref, sink) <- memorySink
    _ <- Stream.fold Fold.drain (withTraceStreamWith reg sink testModel testContext opts)
    recorded <- reverse <$> readTVarIO ref
    received <- Text.lines <$> TextIO.readFile argvPath
    pure Replay {events = recorded, argv = received, executable = exe}

-- | A fake @codex@ in a few lines of @sh@: the recorded event lines and
-- the exit status to leave with.
--
-- It answers @--version@ before recording anything, exactly as the real
-- tool does. That is not decoration: the evidence path probes the
-- executable's version with a second invocation, and a fake that
-- recorded that invocation's argument vector would overwrite the one
-- the test is about to assert on.
fakeCodex :: FilePath -> ([Text], Int) -> String
fakeCodex argvPath (eventLines, status) =
  unlines
    ( [ "#!/bin/sh",
        "if [ \"$1\" = \"--version\" ]; then echo 'codex-cli 9.9.9'; exit 0; fi",
        "printf '%s\\n' \"$@\" > '" <> argvPath <> "'",
        "cat <<'BAIKAI_FIXTURE'"
      ]
        <> map Text.unpack eventLines
        <> [ "BAIKAI_FIXTURE",
             "exit " <> show status
           ]
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
    & #modelId .~ "gpt-5.6"
    & #api .~ OpenAICompletionsCli
    & #provider .~ "openai"

testContext :: Context
testContext = emptyContext & #messages .~ Vector.singleton (user "PROMPT-BODY-MARKER")

baseOptions :: Options
baseOptions = emptyOptions & #evidence .~ Just (evidenceRequest "run-55")

-- | The event stream @codex-cli 0.146.0@ emits, with the thread
-- identifier kept exactly as recorded.
recordedEvents :: ([Text], Int)
recordedEvents =
  ( [ "{\"type\":\"thread.started\",\"thread_id\":\"019fd471-4a48-7c83-be67-6b7c49646e43\"}",
      "{\"type\":\"turn.started\"}",
      "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"ok\"}}",
      "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":16071,\"cached_input_tokens\":6912,\
      \\"cache_write_input_tokens\":0,\"output_tokens\":5,\"reasoning_output_tokens\":0}}"
    ],
    0
  )

-- | A run that succeeded and said nothing about itself.
silentEvents :: ([Text], Int)
silentEvents =
  ( ["{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok\"}}"],
    0
  )

-- | A run that named its thread and then failed.
failingEvents :: ([Text], Int)
failingEvents =
  ( ["{\"type\":\"thread.started\",\"thread_id\":\"019fd471-dead-7c83-be67-6b7c49646e43\"}"],
    4
  )

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
