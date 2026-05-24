module Main (main) where

import Baikai.Interactive
import Baikai.Provider.OpenAI.Interactive
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.OpenAI.Interactive"
      [ commandRenderingTest
      , promptRenderingTest
      ]

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, working directory, extra dirs, sandbox, approval, and extra args" $ do
    let cfg =
          defaultCodexInteractiveConfig
            { executable = "/bin/codex"
            , extraArgs = Vector.fromList ["--no-alt-screen"]
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
      @?= ( "/bin/codex"
          ,
            [ "--model"
            , "gpt-5-codex"
            , "--cd"
            , "/work/project"
            , "--add-dir"
            , "/work/shared"
            , "--add-dir"
            , "/work/docs"
            , "--sandbox"
            , "workspace-write"
            , "--ask-for-approval"
            , "on-request"
            , "--no-alt-screen"
            , "--search"
            , "System instructions:\nBe precise.\n\nUser request:\ninspect the repo"
            ]
          )

promptRenderingTest :: TestTree
promptRenderingTest =
  testCase "omits the system-instruction wrapper when no system prompt is present" $ do
    codexInteractivePrompt (_InteractiveLaunchRequest "hello") @?= "hello"
