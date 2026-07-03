module Main (main) where

import Baikai
import Baikai.Provider.Claude.Api
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.Claude.Interactive
import Claude.V1.Messages qualified as Messages
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import ErrorClassSpec qualified
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
        responseFormatMappingTest,
        ErrorClassSpec.tests
      ]

-- | A 'JsonSchema' on 'Options.responseFormat' maps onto Anthropic's
-- native @output_config@, forwarding the schema 'Value' verbatim via
-- 'Messages.jsonSchemaConfig'. Pure: 'mapRequest' is
-- 'Either Text Messages.CreateMessage'.
responseFormatMappingTest :: TestTree
responseFormatMappingTest =
  testCase "responseFormat JsonSchema maps onto Anthropic output_config" $ do
    let model =
          _Model
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
        ctx = _Context
        opts =
          _Options
            & #responseFormat
              .~ Just (JsonSchema {name = "person", schema = personSchema, strict = True})
    case mapRequest model ctx opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right req ->
        Messages.output_config req
          @?= Just (Messages.jsonSchemaConfig personSchema)

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, prompt, directories, allowed tools, and extra args" $ do
    let cfg =
          defaultClaudeInteractiveConfig
            { executable = "/bin/claude",
              extraArgs = Vector.fromList ["--debug"]
            }
        req =
          (_InteractiveLaunchRequest "inspect the repo")
            & #systemPrompt .~ Just "Be terse."
            & #model .~ Just "sonnet"
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
              ClaudeCli.extraArgs = Vector.fromList ["--allowedTools", "Read"]
            }
        model =
          _Model
            & #modelId .~ "sonnet"
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx =
          _Context
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
    ClaudeCli.registerWithRegistryAndConfig reg ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = script}
    let model =
          _Model
            & #modelId .~ ""
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx = _Context & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30000000 (completeRequestWith reg model ctx _Options)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"

compatDetectionTest :: TestTree
compatDetectionTest =
  testCase "Anthropic-compatible hosts auto-detect request-shaping compat flags" $ do
    let model =
          _Model
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
          _Model
            & #modelId .~ "claude-test"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
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
    events <- Stream.toList (claudeMessagesStream model ctx _Options)
    case events of
      [EventError TerminalPayload {message = AssistantMessage AssistantPayload {errorMessage = Just msg}}] ->
        assertBool
          ("expected ToolResultImage error, got: " <> Text.unpack msg)
          ("ToolResultImage" `Text.isInfixOf` msg)
      other -> error ("expected one EventError; got: " <> show other)

assistantText :: Response -> Text.Text
assistantText resp =
  Text.concat
    [ t
    | AssistantText (TextContent t) <- Vector.toList (resp ^. #message ^. #content)
    ]
