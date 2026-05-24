module Main (main) where

import Baikai.Interactive
import Baikai.Provider.Claude.Interactive
import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.Claude.Interactive"
      [ commandRenderingTest
      ]

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, prompt, directories, allowed tools, and extra args" $ do
    let cfg =
          defaultClaudeInteractiveConfig
            { executable = "/bin/claude"
            , extraArgs = Vector.fromList ["--debug"]
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
      @?= ( "/bin/claude"
          ,
            [ "--model"
            , "sonnet"
            , "--system-prompt"
            , "Be terse."
            , "--add-dir"
            , "/work/shared"
            , "--add-dir"
            , "/work/docs"
            , "--allowedTools"
            , "Read,Bash(git status)"
            , "--debug"
            , "--permission-mode"
            , "plan"
            , "inspect the repo"
            ]
          )
