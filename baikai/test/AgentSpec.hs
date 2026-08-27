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
      toolGrantCeilingTest,
      impliedGrantsTest,
      timeoutCeilingTest,
      outputLimitCeilingTest,
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

-- | A request carrying a per-stream output limit.
--
-- 'agentRunRequest' defaults 'outputLimit' to 'Nothing', which means
-- \"capture without bound\", and the default ceiling's
-- 'defaultMaxOutputLimit' refuses exactly that. Every case below that is
-- not itself about the output limit starts from this helper, so the
-- violation it asserts is the only one in the list. Jobs resolved
-- through @baikai-agent@ never hit this, because that layer's own
-- default supplies a finite limit.
bounded :: AgentRunRequest -> AgentRunRequest
bounded request = request & #outputLimit .~ Just 4096

-- | Accepting a request must return it byte-identical. The equality
-- assertion against the original value is what proves no clamping
-- happened.
ceilingAcceptanceTest :: TestTree
ceilingAcceptanceTest =
  testCase "the default ceiling accepts read-only and edit-workspace unchanged" $ do
    let readOnly = bounded (agentRunRequest AgentClaude "/tmp/work" "look around")
        editing =
          readOnly
            & #safety
            .~ (agentSafety AgentEditWorkspace & #allowedTools .~ ["Read", "Edit"])
            & #timeout
            .~ Just 600
            & #outputLimit
            .~ Just 1024
    applyAgentCeiling defaultAgentCeiling readOnly @?= Right readOnly
    -- Grants the capability already implies, a timeout under an
    -- unlimited maximum, and a limit under the default maximum all pass
    -- through untouched.
    applyAgentCeiling defaultAgentCeiling editing @?= Right editing

ceilingRefusalTest :: TestTree
ceilingRefusalTest =
  testCase "the ceiling refuses with the exact violation for each closed channel" $ do
    let base = bounded (agentRunRequest AgentClaude "/tmp/work" "rewrite everything")
        greedy = base & #safety .~ agentSafety AgentFullAccess
        rawArgs =
          base
            & #safety
            . #providerArgs
            .~ ["--dangerously-skip-permissions", "--verbose"]
        claudeOnly = defaultAgentCeiling & #allowedProviders .~ [AgentClaude]
        codexRequest = bounded (agentRunRequest AgentCodex "/tmp/work" "rewrite everything")
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
          bounded (agentRunRequest AgentCodex "/tmp/work" "rewrite everything")
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
        claudeRequest = bounded (agentRunRequest AgentClaude "/tmp/work" "hello")
        codexRequest = bounded (agentRunRequest AgentCodex "/tmp/work" "hello")
    applyAgentCeiling closed claudeRequest
      @?= Left [ProviderForbidden AgentClaude []]
    applyAgentCeiling closed codexRequest
      @?= Left [ProviderForbidden AgentCodex []]

providerArgsCeilingTest :: TestTree
providerArgsCeilingTest =
  testCase "raw provider arguments pass only when the operator opens the channel" $ do
    let req =
          bounded (agentRunRequest AgentClaude "/tmp/work" "hello")
            & #safety
            . #providerArgs
            .~ ["--some-vendor-flag"]
        permissive = defaultAgentCeiling & #allowProviderArgs .~ True
    applyAgentCeiling defaultAgentCeiling req
      @?= Left [ProviderArgsForbidden ["--some-vendor-flag"]]
    applyAgentCeiling permissive req @?= Right req

-- | A tool grant is authority, so the capability decides which grants
-- need no operator involvement and the operator's allow-list supplies
-- the rest. @Bash@ is in neither implied set, which is the whole point
-- of the finding this pins: a repository file granting itself shell
-- access under @edit-workspace@ must be refused.
toolGrantCeilingTest :: TestTree
toolGrantCeilingTest =
  testCase "a tool grant needs the capability to imply it or the operator to grant it" $ do
    let granting names =
          bounded (agentRunRequest AgentClaude "/tmp/work" "look around")
            & #safety
            .~ (agentSafety AgentEditWorkspace & #allowedTools .~ names)
        bash = granting ["Bash"]
    applyAgentCeiling defaultAgentCeiling bash
      @?= Left [ToolGrantForbidden ["Bash"] AgentEditWorkspace]
    applyAgentCeiling (defaultAgentCeiling & #allowedTools .~ ["Bash"]) bash @?= Right bash
    applyAgentCeiling (defaultAgentCeiling & #maxCapability .~ AgentFullAccess) bash
      @?= Right bash
    -- Matching is exact on the whole string. A pattern-scoped grant is a
    -- different grant, so granting the bare name does not permit it and
    -- an operator who wants it writes it out.
    let scoped = granting ["Bash(git *)"]
    applyAgentCeiling (defaultAgentCeiling & #allowedTools .~ ["Bash"]) scoped
      @?= Left [ToolGrantForbidden ["Bash(git *)"] AgentEditWorkspace]
    -- Grants the capability already implies need no operator at all,
    -- and only the forbidden ones are named in the refusal.
    applyAgentCeiling defaultAgentCeiling (granting ["Read", "Write", "Bash", "WebFetch"])
      @?= Left [ToolGrantForbidden ["Bash", "WebFetch"] AgentEditWorkspace]

-- | The implied grant lists are a security boundary, so they are pinned
-- name by name rather than by a property. A name added here widens every
-- ceiling in existence, which should require editing this test.
impliedGrantsTest :: TestTree
impliedGrantsTest =
  testCase "each capability implies exactly the documented grants" $ do
    toolGrantsImpliedBy AgentReadOnly
      @?= Just ["Read", "Glob", "Grep", "NotebookRead", "TodoWrite"]
    toolGrantsImpliedBy AgentEditWorkspace
      @?= Just
        [ "Read",
          "Glob",
          "Grep",
          "NotebookRead",
          "TodoWrite",
          "Edit",
          "MultiEdit",
          "Write",
          "NotebookEdit"
        ]
    toolGrantsImpliedBy AgentFullAccess @?= Nothing

-- | A finite maximum bounds a requested timeout and also refuses a job
-- that requests none, because a maximum an operator can defeat by
-- omitting the setting is not a maximum.
timeoutCeilingTest :: TestTree
timeoutCeilingTest =
  testCase "a finite max-timeout refuses a longer run and an untimed one" $ do
    let twoHours = defaultAgentCeiling & #maxTimeout .~ Just 7200
        asking limit = bounded (agentRunRequest AgentClaude "/tmp/work" "work") & #timeout .~ limit
    applyAgentCeiling twoHours (asking (Just 3600)) @?= Right (asking (Just 3600))
    applyAgentCeiling twoHours (asking (Just 7200)) @?= Right (asking (Just 7200))
    applyAgentCeiling twoHours (asking (Just 10800))
      @?= Left [TimeoutExceeded (Just 10800) 7200]
    applyAgentCeiling twoHours (asking Nothing) @?= Left [TimeoutExceeded Nothing 7200]
    -- The default maximum is unlimited, so an untimed run passes.
    applyAgentCeiling defaultAgentCeiling (asking Nothing) @?= Right (asking Nothing)

-- | The default maximum is finite, so @unlimited@ is refused until the
-- operator opens it. The memory belongs to the operator's host.
outputLimitCeilingTest :: TestTree
outputLimitCeilingTest =
  testCase "a finite max-output-limit refuses a larger capture and an unlimited one" $ do
    let asking limit =
          bounded (agentRunRequest AgentClaude "/tmp/work" "work") & #outputLimit .~ limit
        unbounded = defaultAgentCeiling & #maxOutputLimit .~ Nothing
    defaultMaxOutputLimit @?= 67108864
    applyAgentCeiling defaultAgentCeiling (asking (Just 1024))
      @?= Right (asking (Just 1024))
    applyAgentCeiling defaultAgentCeiling (asking (Just defaultMaxOutputLimit))
      @?= Right (asking (Just defaultMaxOutputLimit))
    applyAgentCeiling defaultAgentCeiling (asking (Just (defaultMaxOutputLimit + 1)))
      @?= Left [OutputLimitExceeded (Just (defaultMaxOutputLimit + 1)) defaultMaxOutputLimit]
    applyAgentCeiling defaultAgentCeiling (asking Nothing)
      @?= Left [OutputLimitExceeded Nothing defaultMaxOutputLimit]
    applyAgentCeiling unbounded (asking Nothing) @?= Right (asking Nothing)

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

    -- A grant refusal must name what to do about it, because the fix is
    -- in a file the person reading the message may not know exists.
    let grantMessage =
          renderCeilingViolation (ToolGrantForbidden ["Bash", "Skill"] AgentEditWorkspace)
    mapM_
      ( \fragment ->
          assertBool
            ("expected " <> Text.unpack fragment <> " in: " <> Text.unpack grantMessage)
            (fragment `Text.isInfixOf` grantMessage)
      )
      ["Bash", "Skill", "edit-workspace", "policy.allowed-tools"]

    -- Durations are rendered in the spellings the configuration parser
    -- accepts, so an operator can paste the maximum back into their file.
    let overTime = renderCeilingViolation (TimeoutExceeded (Just 10800) 7200)
        untimed = renderCeilingViolation (TimeoutExceeded Nothing 7200)
    assertBool
      ("expected both durations in: " <> Text.unpack overTime)
      ("3h" `Text.isInfixOf` overTime && "2h" `Text.isInfixOf` overTime)
    assertBool
      ("expected the permitted maximum in: " <> Text.unpack untimed)
      ("2h" `Text.isInfixOf` untimed && "no timeout" `Text.isInfixOf` untimed)

    let overBytes = renderCeilingViolation (OutputLimitExceeded (Just 99999999) 67108864)
        unlimitedBytes = renderCeilingViolation (OutputLimitExceeded Nothing 67108864)
    assertBool
      ("expected both byte counts in: " <> Text.unpack overBytes)
      ("99999999" `Text.isInfixOf` overBytes && "67108864" `Text.isInfixOf` overBytes)
    assertBool
      ("expected the word unlimited in: " <> Text.unpack unlimitedBytes)
      ("unlimited" `Text.isInfixOf` unlimitedBytes && "67108864" `Text.isInfixOf` unlimitedBytes)

    let scopeMessage = renderCeilingViolation (RepositoryScopeForbidden "executable")
    assertBool
      ("expected the setting name in: " <> Text.unpack scopeMessage)
      ("executable" `Text.isInfixOf` scopeMessage)
    let outsideMessage =
          renderCeilingViolation (WorkingDirOutsideRepository "/etc" "/tmp/checkout")
    assertBool
      ("expected both paths in: " <> Text.unpack outsideMessage)
      ("/etc" `Text.isInfixOf` outsideMessage && "/tmp/checkout" `Text.isInfixOf` outsideMessage)

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
            RunTimedOut (AgentTimedOut 90 OutputNotCaptured OutputNotCaptured),
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
