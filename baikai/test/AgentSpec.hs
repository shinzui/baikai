module AgentSpec (tests) where

import Baikai.Agent
import Baikai.Prelude
import Data.Text qualified as Text
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Agent"
    [ requestDefaultTest,
      canonicalRenderingTest,
      ceilingAcceptanceTest,
      ceilingRefusalTest,
      multipleViolationTest,
      emptyAllowedProvidersTest,
      providerArgsCeilingTest,
      violationRenderingTest,
      capturedOutputTest,
      failureRenderingTest,
      resultConstructorTest
    ]

-- | A request built by the smart constructor must default every
-- optional field to the least-authority value. Asserting all of them
-- means a later plan adding a field has to decide its default
-- consciously rather than inherit an accident.
requestDefaultTest :: TestTree
requestDefaultTest =
  testCase "agentRunRequest defaults to read-only, inherited output, and no limits" $ do
    let req = agentRunRequest AgentClaude "/tmp/work" "do the thing"
    req ^. #provider @?= AgentClaude
    req ^. #prompt @?= "do the thing"
    req ^. #workingDir @?= "/tmp/work"
    req ^. #modelId @?= Nothing
    req ^. #effort @?= Nothing
    req ^. #extraDirs @?= []
    req ^. #safety . #capability @?= AgentReadOnly
    req ^. #safety . #allowedTools @?= []
    req ^. #safety . #providerArgs @?= []
    req ^. #timeout @?= Nothing
    req ^. #output @?= InheritOutput
    req ^. #outputLimit @?= Nothing
    req ^. #envPassthrough @?= []

canonicalRenderingTest :: TestTree
canonicalRenderingTest =
  testCase "provider, capability, and output-mode names round-trip exactly" $ do
    renderAgentProvider AgentClaude @?= "claude"
    renderAgentProvider AgentCodex @?= "codex"
    parseAgentProvider "claude" @?= Just AgentClaude
    parseAgentProvider "codex" @?= Just AgentCodex
    parseAgentProvider "Claude" @?= Nothing
    parseAgentProvider "" @?= Nothing

    renderAgentCapability AgentReadOnly @?= "read-only"
    renderAgentCapability AgentEditWorkspace @?= "edit-workspace"
    renderAgentCapability AgentFullAccess @?= "full-access"
    parseAgentCapability "read-only" @?= Just AgentReadOnly
    parseAgentCapability "edit-workspace" @?= Just AgentEditWorkspace
    parseAgentCapability "full-access" @?= Just AgentFullAccess
    parseAgentCapability "Read-Only" @?= Nothing
    parseAgentCapability "readonly" @?= Nothing

    renderAgentOutputMode InheritOutput @?= "inherit"
    renderAgentOutputMode CaptureOutput @?= "capture"
    renderAgentOutputMode TeeOutput @?= "tee"
    parseAgentOutputMode "inherit" @?= Just InheritOutput
    parseAgentOutputMode "capture" @?= Just CaptureOutput
    parseAgentOutputMode "tee" @?= Just TeeOutput
    parseAgentOutputMode "Tee" @?= Nothing

-- | Accepting a request must return it byte-identical. The equality
-- assertion against the original value is what proves no clamping
-- happened.
ceilingAcceptanceTest :: TestTree
ceilingAcceptanceTest =
  testCase "the default ceiling accepts read-only and edit-workspace unchanged" $ do
    let readOnly = agentRunRequest AgentClaude "/tmp/work" "look around"
        editing = readOnly & #safety .~ agentSafety AgentEditWorkspace
    applyAgentCeiling defaultAgentCeiling readOnly @?= Right readOnly
    applyAgentCeiling defaultAgentCeiling editing @?= Right editing

ceilingRefusalTest :: TestTree
ceilingRefusalTest =
  testCase "the ceiling refuses with the exact violation for each closed channel" $ do
    let base = agentRunRequest AgentClaude "/tmp/work" "rewrite everything"
        greedy = base & #safety .~ agentSafety AgentFullAccess
        rawArgs =
          base
            & #safety
            . #providerArgs
            .~ ["--dangerously-skip-permissions", "--verbose"]
        claudeOnly = defaultAgentCeiling & #allowedProviders .~ [AgentClaude]
        codexRequest = agentRunRequest AgentCodex "/tmp/work" "rewrite everything"
    applyAgentCeiling defaultAgentCeiling greedy
      @?= Left [CapabilityExceeded AgentFullAccess AgentEditWorkspace]
    applyAgentCeiling defaultAgentCeiling rawArgs
      @?= Left
        [ProviderArgsForbidden ["--dangerously-skip-permissions", "--verbose"]]
    applyAgentCeiling claudeOnly codexRequest
      @?= Left [ProviderForbidden AgentCodex [AgentClaude]]

-- | Every violation is reported, not just the first one, so an
-- operator fixing a job description sees all of them in one run.
multipleViolationTest :: TestTree
multipleViolationTest =
  testCase "a request that breaks three rules reports all three violations" $ do
    let restrictive =
          defaultAgentCeiling
            & #maxCapability
            .~ AgentReadOnly
            & #allowProviderArgs
            .~ False
            & #allowedProviders
            .~ [AgentClaude]
        req =
          agentRunRequest AgentCodex "/tmp/work" "rewrite everything"
            & #safety
            .~ ( agentSafety AgentFullAccess
                   & #providerArgs
                   .~ ["--dangerously-bypass-approvals-and-sandbox"]
               )
    applyAgentCeiling restrictive req
      @?= Left
        [ ProviderForbidden AgentCodex [AgentClaude],
          CapabilityExceeded AgentFullAccess AgentReadOnly,
          ProviderArgsForbidden ["--dangerously-bypass-approvals-and-sandbox"]
        ]

-- | An empty permitted-provider list means no provider is permitted.
-- The opposite reading would be a security hole, so it is pinned.
emptyAllowedProvidersTest :: TestTree
emptyAllowedProvidersTest =
  testCase "an empty allowedProviders list permits no provider" $ do
    let closed = defaultAgentCeiling & #allowedProviders .~ []
        claudeRequest = agentRunRequest AgentClaude "/tmp/work" "hello"
        codexRequest = agentRunRequest AgentCodex "/tmp/work" "hello"
    applyAgentCeiling closed claudeRequest
      @?= Left [ProviderForbidden AgentClaude []]
    applyAgentCeiling closed codexRequest
      @?= Left [ProviderForbidden AgentCodex []]

providerArgsCeilingTest :: TestTree
providerArgsCeilingTest =
  testCase "raw provider arguments pass only when the operator opens the channel" $ do
    let req =
          agentRunRequest AgentClaude "/tmp/work" "hello"
            & #safety
            . #providerArgs
            .~ ["--some-vendor-flag"]
        permissive = defaultAgentCeiling & #allowProviderArgs .~ True
    applyAgentCeiling defaultAgentCeiling req
      @?= Left [ProviderArgsForbidden ["--some-vendor-flag"]]
    applyAgentCeiling permissive req @?= Right req

-- | Pin that both the requested and the permitted value appear, not
-- the exact sentence, so wording can improve without breaking tests.
violationRenderingTest :: TestTree
violationRenderingTest =
  testCase "violation text names both the requested and the permitted value" $ do
    let message = renderCeilingViolation (CapabilityExceeded AgentFullAccess AgentEditWorkspace)
    assertBool
      ("expected the requested capability in: " <> Text.unpack message)
      ("full-access" `Text.isInfixOf` message)
    assertBool
      ("expected the permitted maximum in: " <> Text.unpack message)
      ("edit-workspace" `Text.isInfixOf` message)
    -- Raw provider arguments are the one part of a job description an
    -- operator could write a credential into, so the refusal says how
    -- many were requested and never what they were. Asserting the
    -- absence is the point: a "helpful" edit that quoted them would
    -- defeat the secret classification the configuration layer applies.
    let argsMessage =
          renderCeilingViolation (ProviderArgsForbidden ["--api-key", "sk-not-a-real-key"])
    assertBool
      ("expected the count in: " <> Text.unpack argsMessage)
      ("2" `Text.isInfixOf` argsMessage)
    assertBool
      ("expected no argument value in: " <> Text.unpack argsMessage)
      (not ("sk-not-a-real-key" `Text.isInfixOf` argsMessage))
    let providerMessage = renderCeilingViolation (ProviderForbidden AgentCodex [AgentClaude])
    assertBool
      ("expected both providers in: " <> Text.unpack providerMessage)
      ("codex" `Text.isInfixOf` providerMessage && "claude" `Text.isInfixOf` providerMessage)

capturedOutputTest :: TestTree
capturedOutputTest =
  testCase "capturedBytes distinguishes uncaptured output from empty output" $ do
    capturedBytes OutputNotCaptured @?= Nothing
    capturedBytes (OutputCaptured "all of it") @?= Just "all of it"
    capturedBytes (OutputTruncated "the first part") @?= Just "the first part"
    capturedBytes (OutputCaptured "") @?= Just ""

failureRenderingTest :: TestTree
failureRenderingTest =
  testCase "every render error and run failure produces actionable text" $ do
    let renderErrors =
          [ UnsupportedCapability AgentCodex AgentFullAccess "the sandbox cannot be disabled here",
            UnsupportedToolRestriction AgentCodex "codex exec has no tool allow-list flag",
            SafetyNotExpressible AgentClaude "claude has no sandbox mode",
            ProviderMismatch AgentClaude AgentCodex,
            CeilingRejected [CapabilityExceeded AgentFullAccess AgentReadOnly]
          ]
        runFailures =
          [ SpawnFailed "/usr/local/bin/claude" "no such file or directory",
            RunTimedOut 90,
            MissingEnvironment ["KEIRO_PATH", "ANTHROPIC_API_KEY"],
            WorkingDirMissing "/tmp/gone",
            OutputMalformed "expected JSON, got a banner"
          ]
    mapM_
      ( \e ->
          assertBool
            ("expected non-empty text for " <> show e)
            (not (Text.null (renderAgentRenderError e)))
      )
      renderErrors
    mapM_
      ( \f ->
          assertBool
            ("expected non-empty text for " <> show f)
            (not (Text.null (renderAgentRunFailure f)))
      )
      runFailures

    let mismatch = renderAgentRenderError (ProviderMismatch AgentClaude AgentCodex)
    assertBool
      ("expected both providers in: " <> Text.unpack mismatch)
      ("claude" `Text.isInfixOf` mismatch && "codex" `Text.isInfixOf` mismatch)

    let unsupported =
          renderAgentRenderError
            (UnsupportedCapability AgentCodex AgentFullAccess "the sandbox cannot be disabled here")
    assertBool
      ("expected the supplied explanation in: " <> Text.unpack unsupported)
      ("the sandbox cannot be disabled here" `Text.isInfixOf` unsupported)

    let missing = renderAgentRunFailure (MissingEnvironment ["KEIRO_PATH", "ANTHROPIC_API_KEY"])
    assertBool
      ("expected every missing variable in: " <> Text.unpack missing)
      ("KEIRO_PATH" `Text.isInfixOf` missing && "ANTHROPIC_API_KEY" `Text.isInfixOf` missing)

resultConstructorTest :: TestTree
resultConstructorTest =
  testCase "agentRunResult records the process outcome and captures nothing" $ do
    let result = agentRunResult AgentCodex (ExitFailure 3) 1.5
    result ^. #provider @?= AgentCodex
    result ^. #exitCode @?= ExitFailure 3
    result ^. #duration @?= 1.5
    result ^. #stdout @?= OutputNotCaptured
    result ^. #stderr @?= OutputNotCaptured
