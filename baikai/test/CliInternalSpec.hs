-- | Tests for the helpers the two subprocess providers share.
--
-- The two parser fixtures under @test/fixtures@ are trimmed recordings
-- of real output from @claude 2.1.222@ and @codex-cli 0.146.0@,
-- captured by running each tool once against a trivial prompt. They
-- keep the exact field spellings and nesting those versions emit;
-- identifiers are scrubbed and the local configuration the @claude@
-- init event carries is dropped, because none of it is what the parsers
-- read.
module CliInternalSpec (tests) where

import Baikai
import Baikai.Provider.Cli.Internal
import Control.Lens ((&), (.~), (^.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import System.Directory (doesFileExist, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout qualified as Timeout
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "CLI internal helpers"
    [ promptTests,
      codexParserTests,
      claudeParserTests,
      executableIdentityTests,
      evidenceHelperTests
    ]

-- ============================================================
-- Prompt rendering
-- ============================================================

promptTests :: TestTree
promptTests =
  testGroup
    "prompt rendering"
    [ testCase "renderPrompt returns a single user text message verbatim" $ do
        let ctx = emptyContext & #messages .~ Vector.singleton (user "hello")
        renderPrompt ctx @?= "hello",
      testCase "renderPrompt tags multi-message contexts" $ do
        let ctx =
              emptyContext
                & #messages
                  .~ Vector.fromList
                    [ user "hello",
                      assistant "hi"
                    ]
        renderPrompt ctx @?= "[user]: hello\n[assistant]: hi",
      testCase "wrapSystemPrompt leaves missing and blank prompts alone" $ do
        wrapSystemPrompt Nothing "hello" @?= "hello"
        wrapSystemPrompt (Just "  ") "hello" @?= "hello",
      testCase "wrapSystemPrompt prefixes nonblank system instructions" $
        wrapSystemPrompt (Just "Be terse.") "hi"
          @?= "System instructions:\nBe terse.\n\nUser request:\nhi"
    ]

-- ============================================================
-- The codex event stream
-- ============================================================

parseCodex :: [ByteString] -> IO CodexRunReport
parseCodex = parseCodexJsonlStream . Stream.fromList

codexParserTests :: TestTree
codexParserTests =
  testGroup
    "codex exec --json event stream"
    [ testCase "a recorded run yields its text, thread id, and token counts" $ do
        recorded <- BS.readFile "test/fixtures/codex-events.jsonl"
        report <- parseCodex [recorded]
        report ^. #message @?= "ok"
        report ^. #threadId @?= Just "019fd471-4a48-7c83-be67-6b7c49646e43"
        case report ^. #usage of
          Nothing -> assertFailure "the turn.completed event reports usage"
          Just u -> do
            -- codex reports OpenAI-style inclusive prompt counts, so
            -- the cached tokens come out of inputTokens: 16071 - 6912.
            u ^. #inputTokens @?= 9159
            u ^. #cacheReadTokens @?= 6912
            u ^. #cacheWriteTokens @?= 0
            u ^. #outputTokens @?= 5
            u ^. #reasoningTokens @?= Just 0
            u ^. #totalTokens @?= 9159 + 5 + 6912,
      -- codex-cli 0.146.0 names no model anywhere in its event stream.
      -- Recording the model baikai passed on the command line would be
      -- reporting the request as an observation.
      testCase "a recorded run reports no model, rather than the requested one" $ do
        recorded <- BS.readFile "test/fixtures/codex-events.jsonl"
        report <- parseCodex [recorded]
        report ^. #reportedModel @?= Nothing,
      testCase "a model is read only from an event that also counts tokens" $ do
        withModel <-
          parseCodex
            [ "{\"type\":\"turn.started\",\"model\":\"gpt-5.6-configured\"}\n\
              \{\"type\":\"turn.completed\",\"model\":\"gpt-5.6-ran\",\
              \\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}\n"
            ]
        withModel ^. #reportedModel @?= Just "gpt-5.6-ran",
      testCase "a stream with no thread and no usage reports absence, not zeroes" $ do
        report <-
          parseCodex
            ["{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hi\"}}\n"]
        report ^. #message @?= "hi"
        report ^. #threadId @?= Nothing
        report ^. #usage @?= Nothing,
      testCase "a non-JSON line is skipped rather than failing the run" $ do
        report <-
          parseCodex
            [ "not json at all\n\
              \{\"type\":\"thread.started\",\"thread_id\":\"t-1\"}\n\
              \{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"hi\"}}\n"
            ]
        report ^. #message @?= "hi"
        report ^. #threadId @?= Just "t-1",
      testCase "the older msg-nested and flat event schemas still parse" $ do
        nested <-
          parseCodex
            [ "{\"msg\":{\"type\":\"session.created\",\"session_id\":\"s-1\"}}\n\
              \{\"msg\":{\"type\":\"agent_message\",\"message\":\"nested\"}}\n"
            ]
        nested ^. #message @?= "nested"
        nested ^. #threadId @?= Just "s-1"
        flat <- parseCodex ["{\"type\":\"agent_message\",\"message\":\"flat\"}\n"]
        flat ^. #message @?= "flat",
      testCase "the first identifier wins and the last token count wins" $ do
        report <-
          parseCodex
            [ "{\"type\":\"thread.started\",\"thread_id\":\"first\"}\n\
              \{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}\n\
              \{\"type\":\"thread.started\",\"thread_id\":\"second\"}\n\
              \{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":50,\"output_tokens\":7}}\n"
            ]
        report ^. #threadId @?= Just "first"
        fmap (^. #outputTokens) (report ^. #usage) @?= Just 7,
      testCase "a cached count larger than the prompt total clamps at zero" $ do
        report <-
          parseCodex
            [ "{\"type\":\"turn.completed\",\
              \\"usage\":{\"input_tokens\":5,\"cached_input_tokens\":9,\"output_tokens\":1}}\n"
            ]
        fmap (^. #inputTokens) (report ^. #usage) @?= Just 0,
      -- Chunk boundaries are the operating system's business, not the
      -- codex event schema's: a pipe read returns whatever bytes had
      -- arrived, which for a long event is the middle of a line.
      testCase "a line spanning several chunks is one event" $ do
        report <-
          parseCodex
            [ "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_mess",
              "age\",\"text\":\"split\"}}\n"
            ]
        report ^. #message @?= "split",
      testCase "a final line without a newline is still parsed" $ do
        report <-
          parseCodex
            ["{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"last\"}}"]
        report ^. #message @?= "last",
      -- The previous implementation appended one byte at a time with
      -- BS.snoc, copying the whole accumulator per byte: quadratic in
      -- line length, so a two-million-character message cost on the
      -- order of a trillion byte moves and never finished. The bound is
      -- what makes this a test rather than a benchmark.
      testCase "a multi-megabyte event is assembled in linear time" $ do
        let body = Text.replicate 2000000 "a"
            event =
              Text.encodeUtf8
                ( "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\""
                    <> body
                    <> "\"}}\n"
                )
        finished <- Timeout.timeout 10000000 (parseCodex [event])
        case finished of
          Nothing ->
            assertFailure
              "assembling one two-megabyte event did not finish within ten seconds"
          Just report -> Text.length (report ^. #message) @?= 2000000
    ]

-- ============================================================
-- The claude result document
-- ============================================================

claudeParserTests :: TestTree
claudeParserTests =
  testGroup
    "claude -p --output-format json result"
    [ testCase "a recorded run yields its text, session id, model, usage, and cost" $ do
        recorded <- BS.readFile "test/fixtures/claude-cli-result.json"
        case decodeClaudeCliResult recorded of
          Left err -> assertFailure ("expected the recording to decode: " <> show err)
          Right r -> do
            r ^. #result @?= "ok"
            r ^. #isError @?= False
            r ^. #sessionId @?= Just "01890000-0000-4000-8000-000000000001"
            -- The context-window variant marker is kept: baikai can
            -- request the 1m variant separately, so truncating it to
            -- the canonical name would discard a real distinction.
            r ^. #reportedModel @?= Just "claude-opus-5[1m]"
            case r ^. #usage of
              Nothing -> assertFailure "the result event reports usage"
              Just u -> do
                -- Anthropic's prompt classes are already disjoint, so
                -- nothing is subtracted here.
                u ^. #inputTokens @?= 2
                u ^. #outputTokens @?= 6
                u ^. #cacheReadTokens @?= 15185
                u ^. #cacheWriteTokens @?= 7455
                u ^. #totalTokens @?= 2 + 6 + 15185 + 7455
                -- The tool's total_cost_usd, carried exactly. Written
                -- as a ratio rather than @toRational (0.0823025 ::
                -- Double)@ because that would be the binary-float
                -- approximation, and the whole reason 'Cost' holds a
                -- 'Rational' is that it does not have to be.
                (u ^. #cost) ^. #usd @?= 823025 / 10000000,
      testCase "the older bare-object shape still decodes" $
        case decodeClaudeCliResult "{\"result\":\"pong\",\"is_error\":false}" of
          Left err -> assertFailure ("expected a bare object to decode: " <> show err)
          Right r -> do
            r ^. #result @?= "pong"
            r ^. #sessionId @?= Nothing
            r ^. #reportedModel @?= Nothing
            r ^. #usage @?= Nothing,
      testCase "an error-shaped result keeps its session id" $
        case decodeClaudeCliResult
          "{\"type\":\"result\",\"result\":\"boom\",\"is_error\":true,\"session_id\":\"s-9\"}" of
          Left err -> assertFailure ("expected an error result to decode: " <> show err)
          Right r -> do
            r ^. #isError @?= True
            r ^. #sessionId @?= Just "s-9",
      -- Several models means several models ran, and evidence has one
      -- observedModel slot. Picking one would fabricate specificity.
      testCase "two modelUsage keys report no model rather than one of them" $
        case decodeClaudeCliResult
          "{\"result\":\"ok\",\"is_error\":false,\
          \\"modelUsage\":{\"claude-opus-5\":{},\"claude-haiku-4-5\":{}}}" of
          Left err -> assertFailure ("expected the document to decode: " <> show err)
          Right r -> r ^. #reportedModel @?= Nothing,
      testCase "a result event is found inside an array of events" $
        case decodeClaudeCliResult
          "[{\"type\":\"system\"},{\"type\":\"result\",\"result\":\"found\",\"is_error\":false}]" of
          Left err -> assertFailure ("expected the array to decode: " <> show err)
          Right r -> r ^. #result @?= "found",
      testCase "an array with no result event is a decode error" $
        case decodeClaudeCliResult "[{\"type\":\"system\"}]" of
          Left _ -> pure ()
          Right r -> assertFailure ("expected a decode error, got: " <> show r),
      testCase "malformed stdout is a decode error rather than an exception" $
        case decodeClaudeCliResult "not json" of
          Left _ -> pure ()
          Right r -> assertFailure ("expected a decode error, got: " <> show r)
    ]

-- ============================================================
-- Executable identity
-- ============================================================

-- | Write a shell script into a directory and make it executable.
writeFakeExecutable :: FilePath -> String -> String -> IO FilePath
writeFakeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

executableIdentityTests :: TestTree
executableIdentityTests =
  testGroup
    "executable identity"
    [ testCase "a resolvable tool reports its path and its --version line" $
        withSystemTempDirectory "baikai-cli-identity" $ \dir -> do
          exe <- writeFakeExecutable dir "faketool" "#!/bin/sh\necho 'faketool 9.9.9'\n"
          identity <- executableIdentity exe
          identity ^. #configured @?= Text.pack exe
          identity ^. #resolvedPath @?= Just (Text.pack exe)
          identity ^. #version @?= Just "faketool 9.9.9",
      testCase "a missing tool records absence rather than failing" $
        withSystemTempDirectory "baikai-cli-identity" $ \dir -> do
          let absent = dir </> "not-installed"
          identity <- executableIdentity absent
          identity ^. #configured @?= Text.pack absent
          identity ^. #resolvedPath @?= Nothing
          identity ^. #version @?= Nothing,
      testCase "a tool with no --version flag records absence rather than failing" $
        withSystemTempDirectory "baikai-cli-identity" $ \dir -> do
          exe <- writeFakeExecutable dir "grumpy" "#!/bin/sh\necho 'unknown flag' >&2\nexit 2\n"
          identity <- executableIdentity exe
          identity ^. #resolvedPath @?= Just (Text.pack exe)
          identity ^. #version @?= Nothing,
      -- The whole reason for the cache: a version probe spawns a
      -- process, and paying that per model call would roughly double
      -- the process cost of the cheapest possible call.
      --
      -- The assertion that carries the weight is that the second call
      -- left the ledger untouched. Asserting "exactly one line" instead
      -- would also fail when the first probe was killed by its own
      -- timeout on a loaded machine, which says nothing about caching.
      testCase "the version is probed once per executable, not once per call" $
        withSystemTempDirectory "baikai-cli-identity" $ \dir -> do
          let ledger = dir </> "probes"
              probeCount = length . lines <$> readFileIfPresent ledger
          exe <-
            writeFakeExecutable
              dir
              "counted"
              ("#!/bin/sh\necho x >> '" <> ledger <> "'\necho 'counted 1.0'\n")
          first <- executableIdentity exe
          afterFirst <- probeCount
          second <- executableIdentity exe
          afterSecond <- probeCount
          second @?= first
          afterSecond @?= afterFirst
          assertBool
            ("the first call must probe at most once, saw " <> show afterFirst)
            (afterFirst <= 1)
    ]

readFileIfPresent :: FilePath -> IO String
readFileIfPresent path = do
  here <- doesFileExist path
  if here then readFile path else pure ""

-- ============================================================
-- Evidence helpers
-- ============================================================

evidenceHelperTests :: TestTree
evidenceHelperTests =
  testGroup
    "evidence helpers"
    [ testCase "strength rises only with what the tool reported" $ do
        subprocessStrength (Observed "s-1") (Observed "m-1") @?= EvidenceModelObserved
        subprocessStrength (Observed "s-1") Unobserved @?= EvidenceCorrelated
        subprocessStrength Unobserved Unobserved @?= EvidenceRequestedOnly
        -- A model without a correlation identifier cannot be located in
        -- the vendor's records, so it does not reach 'correlated'.
        subprocessStrength Unobserved (Observed "m-1") @?= EvidenceRequestedOnly,
      -- The API transports spell their response envelope with these
      -- three keys by hand. A verifier holding a response must be able
      -- to recompute the digest without knowing which transport served
      -- it, so the subprocess spelling has to agree.
      testCase "the response envelope spells the same three keys the API transports do" $ do
        let encoded = BS8.unpack (canonicalEncode (cliResponseEnvelope "pong" zeroUsage))
        mapM_
          (\k -> assertBool (k <> " must appear in the envelope") (k `isInfixOf` encoded))
          ["\"content\"", "\"stop_reason\"", "\"usage\""]
        assertBool
          "the assistant text must be committed to"
          ("pong" `isInfixOf` encoded),
      testCase "an argv envelope commits to the prompt and its projection keeps nothing" $ do
        let argv = argvEnvelope "claude" ["-p", "--effort", "low", "--", "PROMPT-BODY-MARKER"]
        assertBool
          "the commitment input must contain the prompt"
          ("PROMPT-BODY-MARKER" `isInfixOf` BS8.unpack (canonicalEncode argv))
        BS8.unpack (canonicalEncode (configurationProjection argv)) @?= "null"
    ]
