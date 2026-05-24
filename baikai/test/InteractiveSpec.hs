module InteractiveSpec (tests) where

import Baikai.Interactive
import Baikai.Prelude
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Interactive"
    [ requestDefaultTest
    , providerRenderingTest
    , codexSafetyRenderingTest
    , resultConstructorTest
    ]

requestDefaultTest :: TestTree
requestDefaultTest =
  testCase "_InteractiveLaunchRequest keeps optional launch settings empty" $ do
    let req = _InteractiveLaunchRequest "start here"
    req ^. #systemPrompt @?= Nothing
    req ^. #userPrompt @?= "start here"
    req ^. #model @?= Nothing
    req ^. #workingDir @?= Nothing
    req ^. #extraDirs @?= []
    req ^. #safety @?= DefaultSafety
    req ^. #extraArgs @?= []

providerRenderingTest :: TestTree
providerRenderingTest =
  testCase "provider and scope values render to stable names" $ do
    renderInteractiveProvider InteractiveClaude @?= "claude"
    renderInteractiveProvider InteractiveCodex @?= "codex"
    renderInteractiveScope InteractiveUserScope @?= "user"
    renderInteractiveScope InteractiveProjectScope @?= "project"

codexSafetyRenderingTest :: TestTree
codexSafetyRenderingTest =
  testCase "codex sandbox and approval values render to CLI-ready names" $ do
    renderCodexSandboxMode CodexReadOnly @?= "read-only"
    renderCodexSandboxMode CodexWorkspaceWrite @?= "workspace-write"
    renderCodexSandboxMode CodexDangerFullAccess @?= "danger-full-access"
    renderCodexApprovalPolicy CodexApprovalUntrusted @?= "untrusted"
    renderCodexApprovalPolicy CodexApprovalOnFailure @?= "on-failure"
    renderCodexApprovalPolicy CodexApprovalOnRequest @?= "on-request"
    renderCodexApprovalPolicy CodexApprovalNever @?= "never"

resultConstructorTest :: TestTree
resultConstructorTest =
  testCase "_InteractiveLaunchResult records provider identity and process status" $ do
    let result = _InteractiveLaunchResult InteractiveCodex ExitSuccess
    result ^. #provider @?= InteractiveCodex
    result ^. #exitCode @?= ExitSuccess
