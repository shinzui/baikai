module Main (main) where

import Baikai
import Baikai.Agent
  ( AgentCapability (..),
    AgentCommand,
    AgentPromptTransport (..),
    AgentProvider (..),
    AgentRenderError (..),
    AgentRunRequest,
    agentRunRequest,
    agentSafety,
    renderAgentRenderError,
  )
import Baikai.Cost qualified as Cost
import Baikai.Cost.Pricing (computeCost)
import Baikai.Provider.OpenAI.Agent qualified as CodexAgent
import Baikai.Provider.OpenAI.Api
  ( RawChunk (..),
    closeOpenStream,
    emptyAssembler,
    openaiChatStream,
    parseUsage,
    rawUsageToUsage,
    translate,
  )
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Baikai.Provider.OpenAI.Interactive
import Baikai.Provider.OpenAI.Internal.Request (mapRequest)
import Baikai.Provider.OpenAI.Shape (describeThinkingShape)
import CliEvidenceSpec qualified
import Contract (assertErrorContract, assertOneErrorTerminal)
import Control.Exception (bracket)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import ErrorClassSpec qualified
import EvidenceSpec qualified
import LifecycleSpec qualified
import MidStreamSpec qualified
import OpenAI.V1.Chat.Completions qualified as Chat
import OpenAI.V1.ResponseFormat qualified as RF
import ReasoningSpec qualified
import ShapeSpec qualified
import SseSpec qualified
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TransportSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.OpenAI"
      [ commandRenderingTest,
        effortRenderingTests,
        safetyRefusalTest,
        refusesRejectedApprovalPoliciesTest,
        safetyStillRendersTest,
        agentCommandRenderingTest,
        agentCapabilityRenderingTests,
        agentEffortRenderingTests,
        agentThinkingTranslationTests,
        strictEvidenceTests,
        agentToolRestrictionRefusalTest,
        agentPromptTransportTest,
        agentBlankModelTest,
        agentConfigBooleanTest,
        agentProviderGuardTest,
        batchCommandRenderingTest,
        batchEffortRenderingTest,
        batchSystemPromptTest,
        stderrFloodTest,
        usageMappingTests,
        promptRenderingTest,
        compatDetectionTest,
        rejectsImageToolResultsTest,
        noKeyStreamTest,
        codexMissingBinaryTest,
        finishReasonTests,
        responseFormatMappingTest,
        optionsMappingTest,
        CliEvidenceSpec.tests,
        ErrorClassSpec.tests,
        EvidenceSpec.tests,
        LifecycleSpec.tests,
        MidStreamSpec.tests,
        ReasoningSpec.tests,
        ShapeSpec.tests,
        SseSpec.tests,
        TransportSpec.tests
      ]

-- | A 'JsonSchema' on 'Options.responseFormat' maps onto the
-- upstream OpenAI @response_format@ as a named, strict JSON schema,
-- forwarding the schema 'Value' verbatim. Pure: 'mapRequest' is
-- 'Either Text Chat.CreateChatCompletion'.
responseFormatMappingTest :: TestTree
responseFormatMappingTest =
  testCase "responseFormat JsonSchema maps onto OpenAI response_format" $ do
    let model =
          emptyModel
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
        ctx = emptyContext
        opts =
          emptyOptions
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

optionsMappingTest :: TestTree
optionsMappingTest =
  testCase "sampling Options map onto OpenAI request fields" $ do
    let model =
          emptyModel
            & #modelId .~ "gpt-4o-mini"
            & #api .~ OpenAIChatCompletions
            & #provider .~ "openai"
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
        Chat.top_p req @?= Just 0.9
        Chat.stop req @?= Just (Vector.fromList ["END", "STOP"])
        Chat.seed req @?= Just 7
        Chat.frequency_penalty req @?= Just 0.2
        Chat.presence_penalty req @?= Just 0.3

usageMappingTests :: TestTree
usageMappingTests =
  testGroup
    "usage mapping"
    [ testCase "cached prompt tokens map to disjoint fields" $ do
        u <- normalizedUsage cachedUsagePayload
        inputTokens u @?= 20
        cacheReadTokens u @?= 80
        outputTokens u @?= 50
        reasoningTokens u @?= Just 20
        cacheWriteTokens u @?= 0
        totalTokens u @?= 150,
      testCase "computeCost bills each token class exactly once" $ do
        u <- normalizedUsage cachedUsagePayload
        let c = computeCost usageCostModel u
        -- The double-billing bug produced 358 / 1000000 by charging
        -- cached tokens at both the input and cache-read rates.
        Cost.usd c @?= (139 / 500000 :: Rational)
        Cost.inputUsd (Cost.breakdown c) @?= (20 / 1000000 :: Rational)
        Cost.cachedInputUsd (Cost.breakdown c) @?= (8 / 1000000 :: Rational),
      testCase "clamps when a compatible host over-reports cached tokens" $ do
        u <- normalizedUsage overCachedUsagePayload
        inputTokens u @?= 0
        cacheReadTokens u @?= 120
        outputTokens u @?= 50
        totalTokens u @?= 170,
      testCase "no cache details means no cache tokens" $ do
        u <- normalizedUsage uncachedUsagePayload
        inputTokens u @?= 100
        cacheReadTokens u @?= 0
        outputTokens u @?= 50
        reasoningTokens u @?= Nothing
        totalTokens u @?= 150
    ]

cachedUsagePayload :: Aeson.Object
cachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int),
      "prompt_tokens_details" Aeson..= Aeson.object ["cached_tokens" Aeson..= (80 :: Int)],
      "completion_tokens_details" Aeson..= Aeson.object ["reasoning_tokens" Aeson..= (20 :: Int)]
    ]

overCachedUsagePayload :: Aeson.Object
overCachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int),
      "prompt_tokens_details" Aeson..= Aeson.object ["cached_tokens" Aeson..= (120 :: Int)]
    ]

uncachedUsagePayload :: Aeson.Object
uncachedUsagePayload =
  usageObject
    [ "prompt_tokens" Aeson..= (100 :: Int),
      "completion_tokens" Aeson..= (50 :: Int),
      "total_tokens" Aeson..= (150 :: Int)
    ]

usageObject :: [AesonTypes.Pair] -> Aeson.Object
usageObject pairs =
  case Aeson.object pairs of
    Aeson.Object o -> o
    _ -> error "unreachable: Aeson.object builds an Object"

normalizedUsage :: Aeson.Object -> IO Usage
normalizedUsage payload =
  case parseUsage payload of
    Just raw -> pure (rawUsageToUsage raw)
    Nothing -> assertFailure "expected usage payload to parse"

usageCostModel :: Model
usageCostModel =
  emptyModel
    & #modelId .~ "gpt-test"
    & #api .~ OpenAIChatCompletions
    & #provider .~ "openai"
    & #cost
      .~ ModelCost
        { inputCost = 1,
          outputCost = 5,
          cacheReadCost = 1 / 10,
          cacheWriteCost = 5 / 4
        }

-- | Render an unattended command or fail the test with the refusal's
-- own message.
renderedAgentCommand ::
  CodexAgent.CodexAgentConfig -> AgentRunRequest -> IO AgentCommand
renderedAgentCommand cfg req = fst <$> renderedAgentPair cfg req

-- | The command and the reasoning-effort translation the renderer
-- produced together.
renderedAgentPair ::
  CodexAgent.CodexAgentConfig ->
  AgentRunRequest ->
  IO (AgentCommand, ThinkingTranslation)
renderedAgentPair cfg req =
  either
    (assertFailure . Text.unpack . renderAgentRenderError)
    pure
    (CodexAgent.codexAgentCommand cfg req)

agentCommandRenderingTest :: TestTree
agentCommandRenderingTest =
  testCase "unattended codex argv renders every structured flag in a fixed order" $ do
    let cfg =
          CodexAgent.defaultCodexAgentConfig
            & #executable .~ "/bin/codex"
            & #extraArgs .~ ["--color", "never"]
        req =
          agentRunRequest AgentCodex "/work/project" "reconcile the grammar"
            & #modelId .~ Just "gpt-5.6-terra"
            & #effort .~ Just ThinkingMedium
            & #extraDirs .~ ["/work/shared"]
            & #safety .~ agentSafety AgentEditWorkspace
    cmd <- renderedAgentCommand cfg req
    cmd ^. #executable @?= "/bin/codex"
    cmd ^. #arguments
      @?= [ "exec",
            "--model",
            "gpt-5.6-terra",
            "-c",
            "model_reasoning_effort=medium",
            "--sandbox",
            "workspace-write",
            "--cd",
            "/work/project",
            "--add-dir",
            "/work/shared",
            "--skip-git-repo-check",
            "--ephemeral",
            "--color",
            "never"
          ]
    cmd ^. #promptTransport @?= PromptOnStdin
    cmd ^. #promptText @?= "reconcile the grammar"

agentCapabilityRenderingTests :: TestTree
agentCapabilityRenderingTests =
  testGroup
    "unattended codex argv maps every capability onto a sandbox mode"
    [ testCase name $ do
        let req =
              agentRunRequest AgentCodex "/work/project" "prompt"
                & #safety .~ agentSafety cap
        cmd <- renderedAgentCommand CodexAgent.defaultCodexAgentConfig req
        cmd ^. #arguments
          @?= [ "exec",
                "--sandbox",
                expected,
                "--cd",
                "/work/project",
                "--skip-git-repo-check",
                "--ephemeral"
              ]
    | (name, cap, expected) <-
        [ ("read-only", AgentReadOnly, "read-only"),
          ("edit-workspace as workspace-write", AgentEditWorkspace, "workspace-write"),
          ("full-access as danger-full-access", AgentFullAccess, "danger-full-access")
        ]
    ]

-- | Codex accepts all six canonical levels through its config
-- override, so nothing is clamped here — unlike Claude, whose
-- @--effort@ has no @minimal@ value. Pinning both sides stops someone
-- later \"unifying\" them.
agentEffortRenderingTests :: TestTree
agentEffortRenderingTests =
  testGroup
    "unattended codex argv passes every reasoning level through unclamped"
    [ testCase name $ do
        let req =
              agentRunRequest AgentCodex "/work/project" "prompt"
                & #effort .~ Just level
        cmd <- renderedAgentCommand CodexAgent.defaultCodexAgentConfig req
        cmd ^. #arguments
          @?= [ "exec",
                "-c",
                "model_reasoning_effort=" <> expected,
                "--sandbox",
                "read-only",
                "--cd",
                "/work/project",
                "--skip-git-repo-check",
                "--ephemeral"
              ]
    | (name, level, expected) <-
        [ ("minimal", ThinkingMinimal, "minimal"),
          ("low", ThinkingLow, "low"),
          ("medium", ThinkingMedium, "medium"),
          ("high", ThinkingHigh, "high"),
          ("xhigh", ThinkingXHigh, "xhigh"),
          ("max", ThinkingMax, "max")
        ]
    ]

-- | @codex exec@ has no tool allow-list flag, so a narrowed tool set is
-- refused rather than run with every tool available. The message must
-- name the alternative.
agentToolRestrictionRefusalTest :: TestTree
agentToolRestrictionRefusalTest =
  testCase "the codex renderer refuses a tool allow-list it cannot express" $ do
    let req =
          agentRunRequest AgentCodex "/work/project" "prompt"
            & #safety .~ (agentSafety AgentEditWorkspace & #allowedTools .~ ["Read", "Edit"])
    case CodexAgent.codexAgentCommand CodexAgent.defaultCodexAgentConfig req of
      Right (cmd, _) ->
        assertFailure ("expected a refusal, rendered: " <> show (cmd ^. #arguments))
      Left (UnsupportedToolRestriction provider message) -> do
        provider @?= AgentCodex
        assertBool
          ("expected the sandbox alternative in: " <> Text.unpack message)
          ("sandbox" `Text.isInfixOf` message)
      Left other ->
        assertFailure ("unexpected refusal: " <> Text.unpack (renderAgentRenderError other))

-- | The prompt travels on standard input, so a prompt that begins with
-- a dash cannot be parsed as a flag, and Codex's documented
-- @\<stdin\>@-block behavior — which appends piped input when a
-- positional prompt is also given — can never be triggered.
agentPromptTransportTest :: TestTree
agentPromptTransportTest =
  testCase "unattended codex argv never contains the prompt, even a dash-leading one" $ do
    let dashPrompt = "-rm -rf /"
        req =
          agentRunRequest AgentCodex "-/work/dashdir" dashPrompt
            & #extraDirs .~ ["-/work/dashshared"]
    cmd <- renderedAgentCommand CodexAgent.defaultCodexAgentConfig req
    assertBool
      ("prompt leaked into argv: " <> show (cmd ^. #arguments))
      (Text.unpack dashPrompt `notElem` cmd ^. #arguments)
    cmd ^. #promptText @?= dashPrompt
    cmd ^. #promptTransport @?= PromptOnStdin
    cmd ^. #arguments
      @?= [ "exec",
            "--sandbox",
            "read-only",
            "--cd",
            "-/work/dashdir",
            "--add-dir",
            "-/work/dashshared",
            "--skip-git-repo-check",
            "--ephemeral"
          ]

agentBlankModelTest :: TestTree
agentBlankModelTest =
  testCase "unattended codex argv omits --model for a blank model value" $ do
    let req =
          agentRunRequest AgentCodex "/work/project" "prompt"
            & #modelId .~ Just "   "
    cmd <- renderedAgentCommand CodexAgent.defaultCodexAgentConfig req
    cmd ^. #arguments
      @?= [ "exec",
            "--sandbox",
            "read-only",
            "--cd",
            "/work/project",
            "--skip-git-repo-check",
            "--ephemeral"
          ]

agentConfigBooleanTest :: TestTree
agentConfigBooleanTest =
  testCase "unattended codex argv omits the git-check and ephemeral flags when disabled" $ do
    let cfg =
          CodexAgent.defaultCodexAgentConfig
            & #skipGitRepoCheck .~ False
            & #ephemeral .~ False
        req = agentRunRequest AgentCodex "/work/project" "prompt"
    cmd <- renderedAgentCommand cfg req
    cmd ^. #arguments
      @?= ["exec", "--sandbox", "read-only", "--cd", "/work/project"]

-- | The unattended renderer describes what it did with the caller's
-- reasoning-effort request, and the description agrees with the argument
-- vector it produced.
--
-- Every level records an empty adjustment list, because codex is the one
-- tool baikai drives that accepts all six verbatim. That is worth
-- asserting precisely because every other transport clamps, collapses,
-- or drops something.
agentThinkingTranslationTests :: TestTree
agentThinkingTranslationTests =
  testGroup
    "the unattended codex renderer records what model_reasoning_effort received"
    ( testCase
        "no effort requested is not a downgrade"
        ( do
            (cmd, translation) <- renderedAgentPair CodexAgent.defaultCodexAgentConfig (effortRequest Nothing)
            assertBool
              ("no effort override is rendered: " <> show (cmd ^. #arguments))
              (not (any (Text.isInfixOf "model_reasoning_effort" . Text.pack) (cmd ^. #arguments)))
            translation @?= noThinkingRequested
        )
        : [ testCase (Text.unpack (renderThinkingLevel level)) $ do
              (cmd, translation) <-
                renderedAgentPair CodexAgent.defaultCodexAgentConfig (effortRequest (Just level))
              let override = "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel level)
              assertBool
                ("-c " <> override <> " in " <> show (cmd ^. #arguments))
                (["-c", override] `isConsecutiveIn` (cmd ^. #arguments))
              translation
                @?= ThinkingTranslation
                  { requested = Just level,
                    mode = ThinkingModeFlag,
                    effortText = Just (renderThinkingLevel level),
                    budgetTokens = Nothing,
                    wireField = Just "model_reasoning_effort",
                    adjustments = []
                  }
          | level <-
              [ ThinkingMinimal,
                ThinkingLow,
                ThinkingMedium,
                ThinkingHigh,
                ThinkingXHigh,
                ThinkingMax
              ]
          ]
    )
  where
    effortRequest level =
      agentRunRequest AgentCodex "/work/project" "prompt" & #effort .~ level

-- | Whether the needle appears as consecutive elements of the haystack.
isConsecutiveIn :: (Eq a) => [a] -> [a] -> Bool
isConsecutiveIn needle haystack =
  any (\suffix -> needle == take (length needle) suffix) (suffixes haystack)
  where
    suffixes xs =
      xs : case xs of
        [] -> []
        (_ : rest) -> suffixes rest

-- | The pre-dispatch strictness gate, fed by this package's __real__
-- shaping function rather than by hand-built adjustments.
--
-- The generic gate is exhaustively covered in
-- @baikai/test/StrictEvidenceSpec.hs@; what only this package can prove
-- is that its own seven wire shapes actually reach the gate — and,
-- just as importantly, which of them do not.
strictEvidenceTests :: TestTree
strictEvidenceTests =
  testGroup
    "strict evidence refuses this provider's real downgrades"
    [ testCase "a non-native host clamping max to high is refused" $
        expectDowngrade
          (EffortClamped ThinkingMax "high")
          (shapeFor "https://api.deepseek.com" ThinkingMax),
      testCase "a toggle-only host is refused at every level, including max" $
        -- Z.ai accepts a bare enable_thinking with no depth, so a caller
        -- asking for max and a caller asking for low send byte-identical
        -- requests. Only the evidence can tell them apart, which is
        -- exactly what a strict caller is refusing to accept.
        expectDowngrade
          (EffortCollapsedToToggle ThinkingMax)
          (shapeFor "https://api.z.ai/api/paas/v4" ThinkingMax),
      testCase "a host with no reasoning controls is refused" $
        -- No host in the auto-detect table selects ThinkingFormatNone,
        -- so this shape is reachable only through an explicitly
        -- configured compat record. That is exactly the caller who most
        -- needs the refusal: they told baikai the host has no reasoning
        -- controls, and baikai would otherwise drop their level in
        -- silence.
        expectDowngrade
          (ThinkingDroppedUnsupportedHost ThinkingMax)
          ( describeThinkingShape
              (defaultOpenAICompletionsCompat {thinkingFormat = ThinkingFormatNone})
              True
              (emptyOptions & #thinking .~ Just ThinkingMax)
          ),
      testCase "THE NATIVE OPENAI SHAPE IS NOT A DOWNGRADE AND MUST NOT BE REFUSED" $ do
        -- The one OpenAI-compatible configuration that honours every
        -- level in full. It looks like a seventh downgrade site beside
        -- the six real ones, and refusing it would reject the caller
        -- baikai serves best. See plan 54's Decision Log.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          OpenAIChatCompletions
          (shapeFor "https://api.openai.com/v1" ThinkingXHigh)
          @?= []
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          OpenAIChatCompletions
          (shapeFor "https://api.openai.com/v1" ThinkingMax)
          @?= [],
      testCase "the codex CLI expresses every level, so only its strength refuses" $ do
        -- Nothing is downgraded at any level, but codex names no model,
        -- so a caller requiring model_observed is refused on strength
        -- alone.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceCorrelated)
          OpenAICompletionsCli
          (CodexCli.codexCliThinking (emptyOptions & #thinking .~ Just ThinkingMax))
          @?= []
        case checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          OpenAICompletionsCli
          (CodexCli.codexCliThinking (emptyOptions & #thinking .~ Just ThinkingMax)) of
          [StrengthUnreachable _ declared] -> declared @?= EvidenceCorrelated
          other -> assertFailure ("expected a strength refusal, got: " <> show other)
    ]
  where
    -- reasoning = True throughout: every case in this group is about
    -- what a /host/ shape does to a level. A model that cannot reason
    -- drops the level before the host is consulted at all, which
    -- ShapeSpec.nonReasoningModelGateTest covers separately.
    shapeFor url lvl =
      describeThinkingShape
        (openaiCompletionsCompatFor (emptyModel & #baseUrl .~ url & #api .~ OpenAIChatCompletions))
        True
        (emptyOptions & #thinking .~ Just lvl)
    expectDowngrade expected translation =
      case checkEvidenceRequirements
        (EvidenceRequired EvidenceRequestedOnly)
        OpenAIChatCompletions
        translation of
        [ThinkingWouldDowngrade [reported]] -> reported @?= expected
        other -> assertFailure ("expected one downgrade refusal, got: " <> show other)

agentProviderGuardTest :: TestTree
agentProviderGuardTest =
  testCase "the codex renderer refuses a request that names claude" $ do
    let req = agentRunRequest AgentClaude "/work/project" "prompt"
    fmap fst (CodexAgent.codexAgentCommand CodexAgent.defaultCodexAgentConfig req)
      @?= Left (ProviderMismatch AgentCodex AgentClaude)

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, working directory, extra dirs, sandbox, approval, and extra args" $ do
    let cfg =
          defaultCodexInteractiveConfig
            { executable = "/bin/codex",
              extraArgs = ["--no-alt-screen"]
            }
        req =
          (interactiveLaunchRequest "inspect the repo")
            & #systemPrompt .~ Just "Be precise."
            & #modelId .~ Just "gpt-5-codex"
            & #workingDir .~ Just "/work/project"
            & #extraDirs .~ ["/work/shared", "/work/docs"]
            & #safety .~ CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
            & #extraArgs .~ ["--search"]
    codexInteractiveCommand cfg req
      @?= Right
        ( "/bin/codex",
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
            "--",
            "System instructions:\nBe precise.\n\nUser request:\ninspect the repo"
          ]
        )

safetyRefusalTest :: TestTree
safetyRefusalTest =
  testCase "refuses a Claude tool allow-list instead of launching unrestricted" $ do
    let req =
          interactiveLaunchRequest "inspect the repo"
            & #safety .~ ClaudeAllowedTools ["Read"]
    case codexInteractiveCommand defaultCodexInteractiveConfig req of
      Right rendered -> assertFailure ("expected refusal, rendered: " <> show rendered)
      Left err -> do
        case err of
          SafetyNotExpressible p _ -> p @?= AgentCodex
          other -> assertFailure ("expected SafetyNotExpressible, got: " <> show other)
        let message = renderAgentRenderError err
        assertBool "names the provider" ("codex" `Text.isInfixOf` message)
        assertBool "names the rejected tools" ("Read" `Text.isInfixOf` message)
        assertBool "suggests an alternative" ("CodexSandbox" `Text.isInfixOf` message)

-- | An approval policy the installed CLI rejects is refused before a
-- process is created.
--
-- @codex --help@ at 0.149.1 lists exactly two possible values for
-- @--ask-for-approval@. Rendering @untrusted@ or @on-failure@ made the
-- CLI exit with a usage error, which reaches a caller as @Right@
-- carrying a non-zero exit code — a session that ran — rather than as
-- the refusal this module promises. The message has to name both the
-- value that was rejected and one that would work, because an operator
-- reading it is choosing a replacement.
refusesRejectedApprovalPoliciesTest :: TestTree
refusesRejectedApprovalPoliciesTest =
  testGroup
    "refuses the approval policies the installed codex CLI rejects"
    ( [ testCase (Text.unpack spelling) $ do
          let req =
                interactiveLaunchRequest "inspect the repo"
                  & #safety .~ CodexSandbox CodexReadOnly policy
          case codexInteractiveCommand defaultCodexInteractiveConfig req of
            Right rendered -> assertFailure ("expected refusal, rendered: " <> show rendered)
            Left err -> do
              case err of
                SafetyNotExpressible p _ -> p @?= AgentCodex
                other -> assertFailure ("expected SafetyNotExpressible, got: " <> show other)
              let message = renderAgentRenderError err
              assertBool
                ("names the rejected value: " <> Text.unpack message)
                (spelling `Text.isInfixOf` message)
              assertBool
                ("names a policy that works: " <> Text.unpack message)
                ("CodexApprovalOnRequest" `Text.isInfixOf` message)
      | (spelling, policy) <-
          [ ("untrusted", CodexApprovalUntrusted),
            ("on-failure", CodexApprovalOnFailure)
          ]
      ]
        <> [ testCase "an accepted policy still renders" $ do
               let req =
                     interactiveLaunchRequest "inspect"
                       & #safety .~ CodexSandbox CodexWorkspaceWrite CodexApprovalOnRequest
               fmap snd (codexInteractiveCommand defaultCodexInteractiveConfig req)
                 @?= Right
                   [ "--sandbox",
                     "workspace-write",
                     "--ask-for-approval",
                     "on-request",
                     "--",
                     "inspect"
                   ]
           ]
    )

-- | The fix refuses only what Codex cannot express. A sandbox policy is
-- expressible and must still render, and an empty allow-list restricts
-- nothing so it renders no safety flag rather than being refused.
safetyStillRendersTest :: TestTree
safetyStillRendersTest =
  testGroup
    "still renders every safety policy Codex can express"
    [ testCase "a sandbox policy" $ do
        let req =
              interactiveLaunchRequest "inspect"
                & #safety .~ CodexSandbox CodexReadOnly CodexApprovalNever
        fmap snd (codexInteractiveCommand defaultCodexInteractiveConfig req)
          @?= Right
            [ "--sandbox",
              "read-only",
              "--ask-for-approval",
              "never",
              "--",
              "inspect"
            ],
      testCase "an empty allow-list renders no safety flag" $ do
        let req = interactiveLaunchRequest "inspect" & #safety .~ ClaudeAllowedTools []
        fmap snd (codexInteractiveCommand defaultCodexInteractiveConfig req)
          @?= Right ["--", "inspect"],
      testCase "DefaultSafety renders no safety flag" $ do
        let req = interactiveLaunchRequest "inspect" & #safety .~ DefaultSafety
        fmap snd (codexInteractiveCommand defaultCodexInteractiveConfig req)
          @?= Right ["--", "inspect"]
    ]

effortRenderingTests :: TestTree
effortRenderingTests =
  testGroup
    "renders interactive reasoning effort"
    [ testCase name $ do
        let req = interactiveLaunchRequest "prompt" & #effort .~ Just level
        codexInteractiveCommand defaultCodexInteractiveConfig req
          @?= Right
            ( "codex",
              ["-c", "model_reasoning_effort=" <> expected, "--", "prompt"]
            )
    | (name, level, expected) <-
        [ ("minimal", ThinkingMinimal, "minimal"),
          ("low", ThinkingLow, "low"),
          ("medium", ThinkingMedium, "medium"),
          ("high", ThinkingHigh, "high"),
          ("xhigh", ThinkingXHigh, "xhigh"),
          ("max", ThinkingMax, "max")
        ]
    ]

batchCommandRenderingTest :: TestTree
batchCommandRenderingTest =
  testCase "codex exec argv terminates options before a dash-leading prompt" $ do
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = emptyContext & #messages .~ Vector.singleton (user "-begin with a dash")
    CodexCli.codexCliCommand CodexCli.defaultCodexCliConfig model ctx emptyOptions
      @?= ( "codex",
            [ "exec",
              "--json",
              "--skip-git-repo-check",
              "--ephemeral",
              "--",
              "-begin with a dash"
            ]
          )

batchEffortRenderingTest :: TestTree
batchEffortRenderingTest =
  testCase "codex exec argv renders reasoning effort before the prompt terminator" $ do
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
        opts = emptyOptions & #thinking .~ Just ThinkingXHigh
    CodexCli.codexCliCommand CodexCli.defaultCodexCliConfig model ctx opts
      @?= ( "codex",
            [ "exec",
              "--json",
              "--skip-git-repo-check",
              "--ephemeral",
              "-c",
              "model_reasoning_effort=xhigh",
              "--",
              "ping"
            ]
          )

batchSystemPromptTest :: TestTree
batchSystemPromptTest =
  testCase "codex exec argv carries system prompt in the prompt text" $ do
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx =
          emptyContext
            & #systemPrompt .~ Just "Be terse."
            & #messages .~ Vector.singleton (user "ping")
    CodexCli.codexCliCommand CodexCli.defaultCodexCliConfig model ctx emptyOptions
      @?= ( "codex",
            [ "exec",
              "--json",
              "--skip-git-repo-check",
              "--ephemeral",
              "--",
              "System instructions:\nBe terse.\n\nUser request:\nping"
            ]
          )

stderrFloodTest :: TestTree
stderrFloodTest =
  testCase "codex batch provider survives a 1MiB stderr flood without deadlock" $ do
    dir <- getTemporaryDirectory
    let script = dir </> "baikai-codex-stderr-flood.sh"
    writeFile script $
      unlines
        [ "#!/bin/sh",
          "head -c 1048576 /dev/zero | tr '\\0' 'e' >&2",
          "printf '{\"type\":\"agent_message\",\"message\":\"pong\"}\\n'"
        ]
    perms <- getPermissions script
    setPermissions script (setOwnerExecutable True perms)
    reg <- newProviderRegistry
    registerApiProviderWith reg (CodexCli.codexCliProvider CodexCli.defaultCodexCliConfig {CodexCli.executable = script})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30000000 (completeRequestWith reg model ctx emptyOptions)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"

promptRenderingTest :: TestTree
promptRenderingTest =
  testCase "omits the system-instruction wrapper when no system prompt is present" $ do
    codexInteractivePrompt (interactiveLaunchRequest "hello") @?= "hello"

compatDetectionTest :: TestTree
compatDetectionTest =
  testCase "OpenAI-compatible hosts auto-detect request-shaping compat flags" $ do
    let model =
          emptyModel
            & #api .~ OpenAIChatCompletions
            & #baseUrl .~ "https://api.deepseek.com"
        compat = openaiCompletionsCompatFor model
    compat ^. #thinkingFormat @?= ThinkingFormatDeepseek
    compat ^. #maxTokensField @?= MaxTokensField
    compat ^. #supportsStrictMode @?= False

rejectsImageToolResultsTest :: TestTree
rejectsImageToolResultsTest =
  testCase "OpenAI API mapping rejects image tool-result blocks instead of dropping them" $ do
    let model =
          emptyModel
            & #modelId .~ "gpt-test"
            & #api .~ OpenAIChatCompletions
            & #provider .~ "openai"
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
    events <- Stream.toList (openaiChatStream model ctx emptyOptions)
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
  testCase "missing OPENAI_API_KEY yields one terminal EventError" $
    withUnsetEnv "OPENAI_API_KEY" $ do
      let model =
            emptyModel
              & #modelId .~ "gpt-test"
              & #api .~ OpenAIChatCompletions
              & #provider .~ "openai"
      events <- Stream.toList (openaiChatStream model emptyContext emptyOptions)
      assertErrorContract events
      case last events of
        EventError TerminalPayload {errorInfo = Just be} ->
          be ^. #category @?= AuthError
        other -> assertFailure ("expected terminal EventError with AuthError, got: " <> show other)

codexMissingBinaryTest :: TestTree
codexMissingBinaryTest =
  testCase "codex CLI missing binary returns an error-shaped Response" $ do
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      (CodexCli.codexCliProvider CodexCli.defaultCodexCliConfig {CodexCli.executable = "/nonexistent/codex-binary"})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    resp <- completeRequestWith reg model ctx emptyOptions
    case responseError resp of
      Just be -> be ^. #category @?= OtherError
      Nothing -> assertFailure "expected missing binary to be returned in-band"

finishReasonTests :: TestTree
finishReasonTests =
  testGroup
    "finish_reason handling"
    [ testCase "content_filter terminates as EventError" $ do
        let (_events1, ass1) =
              translate
                (Right RawChunk {contentDelta = Just "partial", reasoningDelta = Nothing, finishReason = Nothing, toolDeltas = [], usage = Nothing, model = Nothing, responseId = Nothing})
                (emptyAssembler openaiTestModel (read "2026-06-05 00:00:00 UTC"))
                (read "2026-06-05 00:00:01 UTC")
            (events2, ass2) =
              translate
                (Right RawChunk {contentDelta = Nothing, reasoningDelta = Nothing, finishReason = Just "content_filter", toolDeltas = [], usage = Nothing, model = Nothing, responseId = Nothing})
                ass1
                (read "2026-06-05 00:00:02 UTC")
            (events3, _) = closeOpenStream (read "2026-06-05 00:00:03 UTC") Nothing ass2
        let terminalEvents = events2 <> events3
        assertOneErrorTerminal terminalEvents
        case last terminalEvents of
          EventError TerminalPayload {errorInfo = Just be} -> do
            be ^. #category @?= OtherError
            assertBool "message mentions content_filter" ("content_filter" `Text.isInfixOf` (be ^. #message))
          other -> assertFailure ("expected EventError for content_filter, got: " <> show other),
      testCase "unknown finish_reason is a successful diagnostic" $ do
        let (_events, ass1) =
              translate
                (Right RawChunk {contentDelta = Nothing, reasoningDelta = Nothing, finishReason = Just "mystery", toolDeltas = [], usage = Nothing, model = Nothing, responseId = Nothing})
                (emptyAssembler openaiTestModel (read "2026-06-05 00:00:00 UTC"))
                (read "2026-06-05 00:00:01 UTC")
            (terminalEvents, _) = closeOpenStream (read "2026-06-05 00:00:02 UTC") Nothing ass1
        case terminalEvents of
          [EventDone TerminalPayload {message = AssistantMessage AssistantPayload {stopReason = Stop, errorMessage = Just msg}}] ->
            msg @?= "unrecognized finish_reason: mystery"
          other -> assertFailure ("expected successful diagnostic EventDone, got: " <> show other)
    ]

openaiTestModel :: Model
openaiTestModel =
  emptyModel
    & #modelId .~ "gpt-test"
    & #api .~ OpenAIChatCompletions
    & #provider .~ "openai"

withUnsetEnv :: String -> IO a -> IO a
withUnsetEnv name action =
  bracket
    (lookupEnv name)
    restore
    (const (unsetEnv name >> action))
  where
    restore = maybe (unsetEnv name) (setEnv name)

assistantText :: Response -> Text.Text
assistantText resp =
  Text.concat
    [ t
    | AssistantText (TextContent t) <- Vector.toList (resp ^. #message ^. #content)
    ]
