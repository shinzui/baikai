module Main (main) where

import Baikai
import Baikai.Cost qualified as Cost
import Baikai.Cost.Pricing (computeCost)
import Baikai.Provider.OpenAI.Api
  ( RawChunk (..),
    closeOpenStream,
    emptyAssembler,
    mapRequest,
    openaiChatStream,
    parseUsage,
    rawUsageToUsage,
    translate,
  )
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Baikai.Provider.OpenAI.Interactive
import Control.Exception (bracket)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import ErrorClassSpec qualified
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.ResponseFormat qualified as RF
import ReasoningSpec qualified
import ShapeSpec qualified
import SseSpec qualified
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.OpenAI"
      [ commandRenderingTest,
        batchCommandRenderingTest,
        batchSystemPromptTest,
        stderrFloodTest,
        usageMappingTests,
        promptRenderingTest,
        compatDetectionTest,
        rejectsImageToolResultsTest,
        noKeyStreamTest,
        codexMissingBinaryTest,
        finishReasonTests,
        responseFormatMappingTest,
        ErrorClassSpec.tests,
        ReasoningSpec.tests,
        ShapeSpec.tests,
        SseSpec.tests
      ]

-- | A 'JsonSchema' on 'Options.responseFormat' maps onto the
-- upstream OpenAI @response_format@ as a named, strict JSON schema,
-- forwarding the schema 'Value' verbatim. Pure: 'mapRequest' is
-- 'Either Text Chat.CreateChatCompletion'.
responseFormatMappingTest :: TestTree
responseFormatMappingTest =
  testCase "responseFormat JsonSchema maps onto OpenAI response_format" $ do
    let model =
          _Model
            & #modelId .~ "gpt-4o-mini"
            & #api .~ OpenAIChatCompletions
            & #provider .~ "openai"
        personSchema =
          Aeson.object
            [ "type" Aeson..= ("object" :: Text.Text),
              "properties"
                Aeson..= Aeson.object
                  [ "name" Aeson..= Aeson.object ["type" Aeson..= ("string" :: Text.Text)],
                    "age" Aeson..= Aeson.object ["type" Aeson..= ("integer" :: Text.Text)]
                  ],
              "required" Aeson..= (["name", "age"] :: [Text.Text]),
              "additionalProperties" Aeson..= False
            ]
        ctx = _Context
        opts =
          _Options
            & #responseFormat
              .~ Just (JsonSchema {name = "person", schema = personSchema, strict = True})
    case mapRequest model ctx opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right req -> case Chat.response_format req of
        Just (RF.JSON_Schema {RF.json_schema = js}) -> do
          RF.name js @?= "person"
          RF.schema js @?= Just personSchema
          RF.strict js @?= Just True
          RF.description js @?= Nothing
        other -> assertFailure ("expected JSON_Schema, got: " <> show other)

usageMappingTests :: TestTree
usageMappingTests =
  testGroup
    "usage mapping"
    [ testCase "cached prompt tokens map to disjoint fields" $ do
        u <- normalizedUsage cachedUsagePayload
        inputTokens u @?= 20
        cacheReadTokens u @?= 80
        outputTokens u @?= 50
        reasoningTokens u @?= Just 20
        cacheWriteTokens u @?= 0
        totalTokens u @?= 150,
      testCase "computeCost bills each token class exactly once" $ do
        u <- normalizedUsage cachedUsagePayload
        let c = computeCost usageCostModel u
        -- The double-billing bug produced 358 / 1000000 by charging
        -- cached tokens at both the input and cache-read rates.
        Cost.usd c @?= (139 / 500000 :: Rational)
        Cost.inputUsd (Cost.breakdown c) @?= (20 / 1000000 :: Rational)
        Cost.cachedInputUsd (Cost.breakdown c) @?= (8 / 1000000 :: Rational),
      testCase "clamps when a compatible host over-reports cached tokens" $ do
        u <- normalizedUsage overCachedUsagePayload
        inputTokens u @?= 0
        cacheReadTokens u @?= 120
        outputTokens u @?= 50
        totalTokens u @?= 170,
      testCase "no cache details means no cache tokens" $ do
        u <- normalizedUsage uncachedUsagePayload
        inputTokens u @?= 100
        cacheReadTokens u @?= 0
        outputTokens u @?= 50
        reasoningTokens u @?= Nothing
        totalTokens u @?= 150
    ]

cachedUsagePayload :: Aeson.Object
cachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int),
      "prompt_tokens_details" Aeson..= Aeson.object ["cached_tokens" Aeson..= (80 :: Int)],
      "completion_tokens_details" Aeson..= Aeson.object ["reasoning_tokens" Aeson..= (20 :: Int)]
    ]

overCachedUsagePayload :: Aeson.Object
overCachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int),
      "prompt_tokens_details" Aeson..= Aeson.object ["cached_tokens" Aeson..= (120 :: Int)]
    ]

uncachedUsagePayload :: Aeson.Object
uncachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int)
    ]

usageObject :: [AesonTypes.Pair] -> Aeson.Object
usageObject pairs =
  case Aeson.object pairs of
    Aeson.Object o -> o
    _ -> error "unreachable: Aeson.object builds an Object"

normalizedUsage :: Aeson.Object -> IO Usage
normalizedUsage payload =
  case parseUsage payload of
    Just raw -> pure (rawUsageToUsage raw)
    Nothing -> assertFailure "expected usage payload to parse"

usageCostModel :: Model
usageCostModel =
  _Model
    & #modelId .~ "gpt-test"
    & #api .~ OpenAIChatCompletions
    & #provider .~ "openai"
    & #cost
      .~ ModelCost
        { inputCost = 1,
          outputCost = 5,
          cacheReadCost = 1 / 10,
          cacheWriteCost = 5 / 4
        }

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, working directory, extra dirs, sandbox, approval, and extra args" $ do
    let cfg =
          defaultCodexInteractiveConfig
            { executable = "/bin/codex",
              extraArgs = Vector.fromList ["--no-alt-screen"]
            }
        req =
          (_InteractiveLaunchRequest "inspect the repo")
            & #systemPrompt .~ Just "Be precise."
            & #model .~ Just "gpt-5-codex"
            & #workingDir .~ Just "/work/project"
            & #extraDirs .~ ["/work/shared", "/work/docs"]
            & #safety .~ CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
            & #extraArgs .~ ["--search"]
    codexInteractiveCommand cfg req
      @?= ( "/bin/codex",
            [ "--model",
              "gpt-5-codex",
              "--cd",
              "/work/project",
              "--add-dir",
              "/work/shared",
              "--add-dir",
              "/work/docs",
              "--sandbox",
              "workspace-write",
              "--ask-for-approval",
              "on-request",
              "--no-alt-screen",
              "--search",
              "--",
              "System instructions:\nBe precise.\n\nUser request:\ninspect the repo"
            ]
          )

batchCommandRenderingTest :: TestTree
batchCommandRenderingTest =
  testCase "codex exec argv terminates options before a dash-leading prompt" $ do
    let model =
          _Model
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = _Context & #messages .~ Vector.singleton (user "-begin with a dash")
    CodexCli.codexCliCommand CodexCli.defaultCodexCliConfig model ctx
      @?= ( "codex",
            [ "exec",
              "--json",
              "--skip-git-repo-check",
              "--ephemeral",
              "--",
              "-begin with a dash"
            ]
          )

batchSystemPromptTest :: TestTree
batchSystemPromptTest =
  testCase "codex exec argv carries system prompt in the prompt text" $ do
    let model =
          _Model
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx =
          _Context
            & #systemPrompt .~ Just "Be terse."
            & #messages .~ Vector.singleton (user "ping")
    CodexCli.codexCliCommand CodexCli.defaultCodexCliConfig model ctx
      @?= ( "codex",
            [ "exec",
              "--json",
              "--skip-git-repo-check",
              "--ephemeral",
              "--",
              "System instructions:\nBe terse.\n\nUser request:\nping"
            ]
          )

stderrFloodTest :: TestTree
stderrFloodTest =
  testCase "codex batch provider survives a 1MiB stderr flood without deadlock" $ do
    dir <- getTemporaryDirectory
    let script = dir </> "baikai-codex-stderr-flood.sh"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "head -c 1048576 /dev/zero | tr '\\0' 'e' >&2",
          "printf '{\"type\":\"agent_message\",\"message\":\"pong\"}\\n'"
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    reg <- newProviderRegistry
    CodexCli.registerWithRegistryAndConfig reg CodexCli.defaultCodexCliConfig {CodexCli.executable = script}
    let model =
          _Model
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = _Context & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30000000 (completeRequestWith reg model ctx _Options)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"

promptRenderingTest :: TestTree
promptRenderingTest =
  testCase "omits the system-instruction wrapper when no system prompt is present" $ do
    codexInteractivePrompt (_InteractiveLaunchRequest "hello") @?= "hello"

compatDetectionTest :: TestTree
compatDetectionTest =
  testCase "OpenAI-compatible hosts auto-detect request-shaping compat flags" $ do
    let model =
          _Model
            & #api .~ OpenAIChatCompletions
            & #baseUrl .~ "https://api.deepseek.com"
        compat = openaiCompletionsCompatFor model
    compat ^. #thinkingFormat @?= ThinkingFormatDeepseek
    compat ^. #maxTokensField @?= MaxTokensField
    compat ^. #supportsStrictMode @?= False

rejectsImageToolResultsTest :: TestTree
rejectsImageToolResultsTest =
  testCase "OpenAI API mapping rejects image tool-result blocks instead of dropping them" $ do
    let model =
          _Model
            & #modelId .~ "gpt-test"
            & #api .~ OpenAIChatCompletions
            & #provider .~ "openai"
        image = ImageContent {imageData = BS8.pack "png-bytes", mimeType = "image/png"}
        ctx =
          _Context
            & #messages
              .~ Vector.singleton
                ( ToolResultMessage
                    ToolResultPayload
                      { toolCallId = "call_1",
                        toolName = "render",
                        content = Vector.singleton (ToolResultImage image),
                        isError = False,
                        timestamp = read "2026-06-05 00:00:00 UTC"
                      }
                )
    events <- Stream.toList (openaiChatStream model ctx _Options)
    assertErrorContract events
    case events of
      [ EventStart StartPayload {},
        EventError TerminalPayload {message = AssistantMessage AssistantPayload {errorMessage = Just msg}}
        ] ->
          assertBool
            ("expected ToolResultImage error, got: " <> Text.unpack msg)
            ("ToolResultImage" `Text.isInfixOf` msg)
      other -> error ("expected EventStart then EventError; got: " <> show other)

noKeyStreamTest :: TestTree
noKeyStreamTest =
  testCase "missing OPENAI_API_KEY yields one terminal EventError" $
    withUnsetEnv "OPENAI_API_KEY" $ do
      let model =
            _Model
              & #modelId .~ "gpt-test"
              & #api .~ OpenAIChatCompletions
              & #provider .~ "openai"
      events <- Stream.toList (openaiChatStream model _Context _Options)
      assertErrorContract events
      case last events of
        EventError TerminalPayload {errorInfo = Just be} ->
          be ^. #category @?= AuthError
        other -> assertFailure ("expected terminal EventError with AuthError, got: " <> show other)

codexMissingBinaryTest :: TestTree
codexMissingBinaryTest =
  testCase "codex CLI missing binary returns an error-shaped Response" $ do
    reg <- newProviderRegistry
    CodexCli.registerWithRegistryAndConfig
      reg
      CodexCli.defaultCodexCliConfig {CodexCli.executable = "/nonexistent/codex-binary"}
    let model =
          _Model
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = _Context & #messages .~ Vector.singleton (user "ping")
    resp <- completeRequestWith reg model ctx _Options
    case responseError resp of
      Just be -> be ^. #category @?= OtherError
      Nothing -> assertFailure "expected missing binary to be returned in-band"

finishReasonTests :: TestTree
finishReasonTests =
  testGroup
    "finish_reason handling"
    [ testCase "content_filter terminates as EventError" $ do
        let (_events1, ass1) =
              translate
                (Right RawChunk {contentDelta = Just "partial", reasoningDelta = Nothing, finishReason = Nothing, toolDeltas = [], usage = Nothing})
                (emptyAssembler openaiTestModel (read "2026-06-05 00:00:00 UTC"))
                (read "2026-06-05 00:00:01 UTC")
            (events2, ass2) =
              translate
                (Right RawChunk {contentDelta = Nothing, reasoningDelta = Nothing, finishReason = Just "content_filter", toolDeltas = [], usage = Nothing})
                ass1
                (read "2026-06-05 00:00:02 UTC")
            (events3, _) = closeOpenStream (read "2026-06-05 00:00:03 UTC") Nothing ass2
        let terminalEvents = events2 <> events3
        assertErrorContract terminalEvents
        case last terminalEvents of
          EventError TerminalPayload {errorInfo = Just be} -> do
            be ^. #category @?= OtherError
            assertBool "message mentions content_filter" ("content_filter" `Text.isInfixOf` (be ^. #message))
          other -> assertFailure ("expected EventError for content_filter, got: " <> show other),
      testCase "unknown finish_reason is a successful diagnostic" $ do
        let (_events, ass1) =
              translate
                (Right RawChunk {contentDelta = Nothing, reasoningDelta = Nothing, finishReason = Just "mystery", toolDeltas = [], usage = Nothing})
                (emptyAssembler openaiTestModel (read "2026-06-05 00:00:00 UTC"))
                (read "2026-06-05 00:00:01 UTC")
            (terminalEvents, _) = closeOpenStream (read "2026-06-05 00:00:02 UTC") Nothing ass1
        case terminalEvents of
          [EventDone TerminalPayload {message = AssistantMessage AssistantPayload {stopReason = Stop, errorMessage = Just msg}}] ->
            msg @?= "unrecognized finish_reason: mystery"
          other -> assertFailure ("expected successful diagnostic EventDone, got: " <> show other)
    ]

openaiTestModel :: Model
openaiTestModel =
  _Model
    & #modelId .~ "gpt-test"
    & #api .~ OpenAIChatCompletions
    & #provider .~ "openai"

withUnsetEnv :: String -> IO a -> IO a
withUnsetEnv name action =
  bracket
    (lookupEnv name)
    restore
    (const (unsetEnv name >> action))
  where
    restore = maybe (unsetEnv name) (setEnv name)

assertErrorContract :: [AssistantMessageEvent] -> Assertion
assertErrorContract events = do
  let terminals = filter isTerminal events
  length terminals @?= 1
  case terminals of
    [EventError TerminalPayload {errorInfo = Nothing}] ->
      assertFailure "terminal EventError omitted errorInfo"
    _ -> pure ()

assistantText :: Response -> Text.Text
assistantText resp =
  Text.concat
    [ t
    | AssistantText (TextContent t) <- Vector.toList (resp ^. #message ^. #content)
    ]
