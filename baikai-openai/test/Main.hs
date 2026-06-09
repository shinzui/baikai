module Main (main) where

import Baikai
import Baikai.Provider.OpenAI.Api
import Baikai.Provider.OpenAI.Interactive
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.ResponseFormat qualified as RF
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.OpenAI"
      [ commandRenderingTest,
        promptRenderingTest,
        compatDetectionTest,
        rejectsImageToolResultsTest,
        responseFormatMappingTest
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
    compat ^. #supportsDeveloperRole @?= False

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
