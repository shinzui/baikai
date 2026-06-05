module Main (main) where

import Baikai
import Baikai.Provider.OpenAI.Api
import Baikai.Provider.OpenAI.Interactive
import Control.Lens ((&), (.~))
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
      "Baikai.Provider.OpenAI.Interactive"
      [ commandRenderingTest,
        promptRenderingTest,
        rejectsImageToolResultsTest
      ]

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
              "System instructions:\nBe precise.\n\nUser request:\ninspect the repo"
            ]
          )

promptRenderingTest :: TestTree
promptRenderingTest =
  testCase "omits the system-instruction wrapper when no system prompt is present" $ do
    codexInteractivePrompt (_InteractiveLaunchRequest "hello") @?= "hello"

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
    case events of
      [EventError TerminalPayload {message = AssistantMessage AssistantPayload {errorMessage = Just msg}}] ->
        assertBool
          ("expected ToolResultImage error, got: " <> Text.unpack msg)
          ("ToolResultImage" `Text.isInfixOf` msg)
      other -> error ("expected one EventError; got: " <> show other)
