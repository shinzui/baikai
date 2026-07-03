module Main (main) where

import Baikai
import Baikai.Provider.Claude.Api
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.Claude.Interactive
import Claude.V1.Messages qualified as Messages
import Control.Exception (bracket)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import ErrorClassSpec qualified
import ShapeSpec qualified
import SseSpec qualified
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import ThinkingSpec qualified
import TransportSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.Claude"
      [ commandRenderingTest,
        batchCommandRenderingTest,
        stderrFloodTest,
        compatDetectionTest,
        rejectsImageToolResultsTest,
        noKeyStreamTest,
        cliMissingBinaryTest,
        responseFormatMappingTest,
        optionsMappingTest,
        ErrorClassSpec.tests,
        ShapeSpec.tests,
        SseSpec.tests,
        ThinkingSpec.tests,
        TransportSpec.tests
      ]

-- | A 'JsonSchema' on 'Options.responseFormat' maps onto Anthropic's
-- native @output_config@, forwarding the schema 'Value' verbatim via
-- 'Messages.jsonSchemaConfig'. Pure: 'mapRequest' is
-- 'Either Text Messages.CreateMessage'.
responseFormatMappingTest :: TestTree
responseFormatMappingTest =
  testCase "responseFormat JsonSchema maps onto Anthropic output_config" $ do
    let model =
          emptyModel
            & #modelId .~ "claude-haiku-4-5-20251001"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
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
        ctx = emptyContext
        opts =
          emptyOptions
            & #responseFormat
              .~ Just (JsonSchema {name = "person", schema = personSchema, strict = True})
    case mapRequest model ctx opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right req ->
        Messages.output_config req
          @?= Just (Messages.jsonSchemaConfig personSchema)

optionsMappingTest :: TestTree
optionsMappingTest =
  testCase "sampling Options map onto Anthropic request fields" $ do
    let model =
          emptyModel
            & #modelId .~ "claude-haiku-4-5-20251001"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
        opts =
          emptyOptions
            & #topP .~ Just 0.9
            & #stopSequences .~ Just (Vector.fromList ["END", "STOP"])
            & #seed .~ Just 7
            & #frequencyPenalty .~ Just 0.2
            & #presencePenalty .~ Just 0.3
    case mapRequest model emptyContext opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right req -> do
        Messages.top_p req @?= Just 0.9
        Messages.stop_sequences req @?= Just (Vector.fromList ["END", "STOP"])

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, prompt, directories, allowed tools, and extra args" $ do
    let cfg =
          defaultClaudeInteractiveConfig
            { executable = "/bin/claude",
              extraArgs = ["--debug"]
            }
        req =
          (interactiveLaunchRequest "inspect the repo")
            & #systemPrompt .~ Just "Be terse."
            & #modelId .~ Just "sonnet"
            & #workingDir .~ Just "/work/project"
            & #extraDirs .~ ["/work/shared", "/work/docs"]
            & #safety .~ ClaudeAllowedTools ["Read", "Bash(git status)"]
            & #extraArgs .~ ["--permission-mode", "plan"]
    claudeInteractiveCommand cfg req
      @?= ( "/bin/claude",
            [ "--model",
              "sonnet",
              "--system-prompt",
              "Be terse.",
              "--add-dir",
              "/work/shared",
              "--add-dir",
              "/work/docs",
              "--allowedTools",
              "Read,Bash(git status)",
              "--debug",
              "--permission-mode",
              "plan",
              "--",
              "inspect the repo"
            ]
          )

batchCommandRenderingTest :: TestTree
batchCommandRenderingTest =
  testCase "claude -p argv terminates options before a dash-leading prompt" $ do
    let cfg =
          ClaudeCli.defaultClaudeCliConfig
            { ClaudeCli.executable = "/bin/claude",
              ClaudeCli.extraArgs = ["--allowedTools", "Read"]
            }
        model =
          emptyModel
            & #modelId .~ "sonnet"
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx =
          emptyContext
            & #systemPrompt .~ Just "Be terse."
            & #messages .~ Vector.singleton (user "-begin with a dash")
    ClaudeCli.claudeCliCommand cfg model ctx
      @?= ( "/bin/claude",
            [ "-p",
              "--model",
              "sonnet",
              "--output-format",
              "json",
              "--no-session-persistence",
              "--system-prompt",
              "Be terse.",
              "--allowedTools",
              "Read",
              "--",
              "-begin with a dash"
            ]
          )

stderrFloodTest :: TestTree
stderrFloodTest =
  testCase "claude batch provider survives a 1MiB stderr flood without deadlock" $ do
    dir <- getTemporaryDirectory
    let script = dir </> "baikai-claude-stderr-flood.sh"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "head -c 1048576 /dev/zero | tr '\\0' 'e' >&2",
          "printf '{\"result\":\"pong\",\"is_error\":false}\\n'"
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    reg <- newProviderRegistry
    registerApiProviderWith reg (ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = script})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30000000 (completeRequestWith reg model ctx emptyOptions)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"

compatDetectionTest :: TestTree
compatDetectionTest =
  testCase "Anthropic-compatible hosts auto-detect request-shaping compat flags" $ do
    let model =
          emptyModel
            & #api .~ AnthropicMessages
            & #baseUrl .~ "https://api.fireworks.ai/inference/v1"
        compat = anthropicMessagesCompatFor model
    compat ^. #supportsCacheControlOnTools @?= False
    compat ^. #sendSessionAffinityHeaders @?= True
    compat ^. #supportsLongCacheRetention @?= False

rejectsImageToolResultsTest :: TestTree
rejectsImageToolResultsTest =
  testCase "Claude API mapping rejects image tool-result blocks instead of dropping them" $ do
    let model =
          emptyModel
            & #modelId .~ "claude-test"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
        image = ImageContent {imageData = BS8.pack "png-bytes", mimeType = "image/png"}
        ctx =
          emptyContext
            & #messages
              .~ Vector.singleton
                ( ToolResultMessage
                    ToolResultPayload
                      { toolCallId = "call_1",
                        toolName = "render",
                        content = Vector.singleton (ToolResultImage image),
                        isError = False,
                        timestamp = Just (read "2026-06-05 00:00:00 UTC")
                      }
                )
    events <- Stream.toList (claudeMessagesStream model ctx emptyOptions)
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
  testCase "missing ANTHROPIC_API_KEY yields one terminal EventError" $
    withUnsetEnv "ANTHROPIC_API_KEY" $ do
      let model =
            emptyModel
              & #modelId .~ "claude-test"
              & #api .~ AnthropicMessages
              & #provider .~ "anthropic"
      events <- Stream.toList (claudeMessagesStream model emptyContext emptyOptions)
      assertErrorContract events
      case last events of
        EventError TerminalPayload {errorInfo = Just be} ->
          be ^. #category @?= AuthError
        other -> assertFailure ("expected terminal EventError with AuthError, got: " <> show other)

cliMissingBinaryTest :: TestTree
cliMissingBinaryTest =
  testCase "claude CLI missing binary returns an error-shaped Response" $ do
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      (ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = "/nonexistent/claude-binary"})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    resp <- completeRequestWith reg model ctx emptyOptions
    case responseError resp of
      Just be -> be ^. #category @?= OtherError
      Nothing -> assertFailure "expected missing binary to be returned in-band"

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
