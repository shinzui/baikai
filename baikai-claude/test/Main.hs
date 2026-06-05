module Main (main) where

import Baikai
import Baikai.Provider.Claude.Api
import Baikai.Provider.Claude.Interactive
import Control.Lens ((&), (.~), (^.))
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.Claude.Interactive"
      [ commandRenderingTest,
        compatDetectionTest,
        rejectsImageToolResultsTest
      ]

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
              "inspect the repo"
            ]
          )

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
