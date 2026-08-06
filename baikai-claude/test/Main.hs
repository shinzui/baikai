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
import Baikai.Evidence.Build
  ( EvidenceRefusal (..),
    checkEvidenceRequirements,
  )
import Baikai.Provider.Claude.Agent qualified as ClaudeAgent
import Baikai.Provider.Claude.Api
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.Claude.Interactive
import Baikai.Provider.Claude.Internal.Request (describeThinkingFor, mapRequest)
import Claude.V1.Messages qualified as Messages
import CliEvidenceSpec qualified
import Control.Exception (bracket)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BS8
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import ErrorClassSpec qualified
import EvidenceSpec qualified
import ShapeSpec qualified
import SseSpec qualified
import Streamly.Data.Stream qualified as Stream
import System.Directory (getPermissions, getTemporaryDirectory, setOwnerExecutable, setPermissions)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import ThinkingSpec qualified
import TransportSpec qualified

main :: IO ()
main =
  defaultMain $
    testGroup
      "Baikai.Provider.Claude"
      [ commandRenderingTest,
        effortRenderingTests,
        safetyRefusalTest,
        safetyStillRendersTest,
        agentCommandRenderingTest,
        agentCapabilityRenderingTests,
        agentEffortRenderingTests,
        agentThinkingTranslationTests,
        strictEvidenceTests,
        agentPromptTransportTest,
        agentBlankModelTest,
        agentSessionPersistenceTest,
        agentProviderGuardTest,
        agentKeiroFixtureTest,
        batchCommandRenderingTest,
        batchEffortRenderingTests,
        stderrFloodTest,
        compatDetectionTest,
        rejectsImageToolResultsTest,
        noKeyStreamTest,
        cliMissingBinaryTest,
        responseFormatMappingTest,
        optionsMappingTest,
        CliEvidenceSpec.tests,
        ErrorClassSpec.tests,
        EvidenceSpec.tests,
        ShapeSpec.tests,
        SseSpec.tests,
        ThinkingSpec.tests,
        TransportSpec.tests
      ]

-- | A 'JsonSchema' on 'Options.responseFormat' maps onto Anthropic's
-- native @output_config@, forwarding the schema 'Value' verbatim via
-- 'Messages.jsonSchemaConfig'. Pure: 'mapRequest' is
-- 'Either Text (Messages.CreateMessage, ThinkingTranslation)'.
responseFormatMappingTest :: TestTree
responseFormatMappingTest =
  testCase "responseFormat JsonSchema maps onto Anthropic output_config" $ do
    let model =
          emptyModel
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
        ctx = emptyContext
        opts =
          emptyOptions
            & #responseFormat
              .~ Just (JsonSchema {name = "person", schema = personSchema, strict = True})
    case mapRequest model ctx opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right (req, _) ->
        Messages.output_config req
          @?= Just (Messages.jsonSchemaConfig personSchema)

optionsMappingTest :: TestTree
optionsMappingTest =
  testCase "sampling Options map onto Anthropic request fields" $ do
    let model =
          emptyModel
            & #modelId .~ "claude-haiku-4-5-20251001"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
        opts =
          emptyOptions
            & #topP .~ Just 0.9
            & #stopSequences .~ Just (Vector.fromList ["END", "STOP"])
            & #seed .~ Just 7
            & #frequencyPenalty .~ Just 0.2
            & #presencePenalty .~ Just 0.3
    case mapRequest model emptyContext opts of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right (req, _) -> do
        Messages.top_p req @?= Just 0.9
        Messages.stop_sequences req @?= Just (Vector.fromList ["END", "STOP"])

commandRenderingTest :: TestTree
commandRenderingTest =
  testCase "renders model, prompt, directories, allowed tools, and extra args" $ do
    let cfg =
          defaultClaudeInteractiveConfig
            { executable = "/bin/claude",
              extraArgs = ["--debug"]
            }
        req =
          (interactiveLaunchRequest "inspect the repo")
            & #systemPrompt .~ Just "Be terse."
            & #modelId .~ Just "sonnet"
            & #workingDir .~ Just "/work/project"
            & #extraDirs .~ ["/work/shared", "/work/docs"]
            & #safety .~ ClaudeAllowedTools ["Read", "Bash(git status)"]
            & #extraArgs .~ ["--permission-mode", "plan"]
    claudeInteractiveCommand cfg req
      @?= Right
        ( "/bin/claude",
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

effortRenderingTests :: TestTree
effortRenderingTests =
  testGroup
    "renders interactive reasoning effort"
    [ testCase name $ do
        let req = interactiveLaunchRequest "prompt" & #effort .~ Just level
        claudeInteractiveCommand defaultClaudeInteractiveConfig req
          @?= Right ("claude", ["--effort", expected, "--", "prompt"])
    | (name, level, expected) <-
        [ ("minimal as low", ThinkingMinimal, "low"),
          ("low", ThinkingLow, "low"),
          ("medium", ThinkingMedium, "medium"),
          ("high", ThinkingHigh, "high"),
          ("xhigh", ThinkingXHigh, "xhigh"),
          ("max", ThinkingMax, "max")
        ]
    ]

safetyRefusalTest :: TestTree
safetyRefusalTest =
  testCase "refuses a Codex sandbox policy instead of launching unrestricted" $ do
    let req =
          interactiveLaunchRequest "inspect the repo"
            & #safety .~ CodexSandbox CodexReadOnly CodexApprovalNever
    case claudeInteractiveCommand defaultClaudeInteractiveConfig req of
      Right rendered -> assertFailure ("expected refusal, rendered: " <> show rendered)
      Left err -> do
        case err of
          SafetyNotExpressible p _ -> p @?= AgentClaude
          other -> assertFailure ("expected SafetyNotExpressible, got: " <> show other)
        let message = renderAgentRenderError err
        assertBool "names the provider" ("Claude" `Text.isInfixOf` message)
        assertBool "names the rejected sandbox mode" ("read-only" `Text.isInfixOf` message)
        assertBool "names the rejected approval policy" ("never" `Text.isInfixOf` message)
        assertBool "suggests an alternative" ("ClaudeAllowedTools" `Text.isInfixOf` message)

-- | The fix refuses only what Claude cannot express. An allow-list is
-- expressible and must still render, and an empty allow-list restricts
-- nothing so it renders no safety flag rather than being refused.
safetyStillRendersTest :: TestTree
safetyStillRendersTest =
  testGroup
    "still renders every safety policy Claude can express"
    [ testCase "a non-empty allow-list" $ do
        let req =
              interactiveLaunchRequest "inspect"
                & #safety .~ ClaudeAllowedTools ["Read", "Grep"]
        fmap snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)
          @?= Right ["--allowedTools", "Read,Grep", "--", "inspect"],
      testCase "an empty allow-list renders no safety flag" $ do
        let req = interactiveLaunchRequest "inspect" & #safety .~ ClaudeAllowedTools []
        fmap snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)
          @?= Right ["--", "inspect"],
      testCase "DefaultSafety renders no safety flag" $ do
        let req = interactiveLaunchRequest "inspect" & #safety .~ DefaultSafety
        fmap snd (claudeInteractiveCommand defaultClaudeInteractiveConfig req)
          @?= Right ["--", "inspect"]
    ]

-- | Render an unattended command or fail the test with the refusal's
-- own message.
renderedAgentCommand ::
  ClaudeAgent.ClaudeAgentConfig -> AgentRunRequest -> IO AgentCommand
renderedAgentCommand cfg req = fst <$> renderedAgentPair cfg req

-- | The command and the reasoning-effort translation the renderer
-- produced together.
renderedAgentPair ::
  ClaudeAgent.ClaudeAgentConfig ->
  AgentRunRequest ->
  IO (AgentCommand, ThinkingTranslation)
renderedAgentPair cfg req =
  either
    (assertFailure . Text.unpack . renderAgentRenderError)
    pure
    (ClaudeAgent.claudeAgentCommand cfg req)

agentCommandRenderingTest :: TestTree
agentCommandRenderingTest =
  testCase "unattended claude argv renders every structured flag in a fixed order" $ do
    let cfg =
          ClaudeAgent.defaultClaudeAgentConfig
            & #executable .~ "/bin/claude"
            & #extraArgs .~ ["--debug"]
        req =
          agentRunRequest AgentClaude "/work/project" "reconcile the grammar"
            & #modelId .~ Just "sonnet"
            & #effort .~ Just ThinkingHigh
            & #extraDirs .~ ["/work/shared", "/work/docs"]
            & #safety .~ (agentSafety AgentEditWorkspace & #allowedTools .~ ["Read", "Write"])
            & #safety . #providerArgs .~ ["--betas", "context-1m"]
    cmd <- renderedAgentCommand cfg req
    cmd ^. #executable @?= "/bin/claude"
    cmd ^. #arguments
      @?= [ "-p",
            "--no-session-persistence",
            "--model",
            "sonnet",
            "--effort",
            "high",
            "--permission-mode",
            "acceptEdits",
            "--allowedTools",
            "Read,Write",
            "--add-dir",
            "/work/shared",
            "--add-dir",
            "/work/docs",
            "--debug",
            "--betas",
            "context-1m"
          ]
    cmd ^. #promptTransport @?= PromptOnStdin
    cmd ^. #promptText @?= "reconcile the grammar"

agentCapabilityRenderingTests :: TestTree
agentCapabilityRenderingTests =
  testGroup
    "unattended claude argv maps every capability onto a permission mode"
    [ testCase name $ do
        let req =
              agentRunRequest AgentClaude "/work/project" "prompt"
                & #safety .~ agentSafety cap
        cmd <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
        cmd ^. #arguments
          @?= ["-p", "--no-session-persistence", "--permission-mode", expected]
    | (name, cap, expected) <-
        [ ("read-only as plan", AgentReadOnly, "plan"),
          ("edit-workspace as acceptEdits", AgentEditWorkspace, "acceptEdits"),
          ("full-access as bypassPermissions", AgentFullAccess, "bypassPermissions")
        ]
    ]

-- | Claude's @--effort@ has no @minimal@ value, so the lowest level
-- maps up to @low@. Codex passes all six through unchanged; pinning
-- both sides stops someone later \"unifying\" them.
agentEffortRenderingTests :: TestTree
agentEffortRenderingTests =
  testGroup
    "unattended claude argv clamps minimal effort up to low"
    [ testCase name $ do
        let req =
              agentRunRequest AgentClaude "/work/project" "prompt"
                & #effort .~ Just level
        cmd <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
        cmd ^. #arguments
          @?= [ "-p",
                "--no-session-persistence",
                "--effort",
                expected,
                "--permission-mode",
                "plan"
              ]
    | (name, level, expected) <-
        [ ("minimal as low", ThinkingMinimal, "low"),
          ("low", ThinkingLow, "low"),
          ("medium", ThinkingMedium, "medium"),
          ("high", ThinkingHigh, "high"),
          ("xhigh", ThinkingXHigh, "xhigh"),
          ("max", ThinkingMax, "max")
        ]
    ]

-- | The prompt travels on standard input, so a prompt that begins with
-- a dash cannot be parsed as a flag and cannot be swallowed by a
-- preceding variadic flag. Dash-leading directories still appear as
-- ordinary arguments following their own flag.
agentPromptTransportTest :: TestTree
agentPromptTransportTest =
  testCase "unattended claude argv never contains the prompt, even a dash-leading one" $ do
    let dashPrompt = "-rm -rf /"
        req =
          agentRunRequest AgentClaude "-/work/dashdir" dashPrompt
            & #extraDirs .~ ["-/work/dashshared"]
            & #safety .~ (agentSafety AgentEditWorkspace & #allowedTools .~ ["Read"])
    cmd <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
    assertBool
      ("prompt leaked into argv: " <> show (cmd ^. #arguments))
      (Text.unpack dashPrompt `notElem` cmd ^. #arguments)
    cmd ^. #promptText @?= dashPrompt
    cmd ^. #promptTransport @?= PromptOnStdin
    cmd ^. #arguments
      @?= [ "-p",
            "--no-session-persistence",
            "--permission-mode",
            "acceptEdits",
            "--allowedTools",
            "Read",
            "--add-dir",
            "-/work/dashshared"
          ]

agentBlankModelTest :: TestTree
agentBlankModelTest =
  testCase "unattended claude argv omits --model for a blank model value" $ do
    let req =
          agentRunRequest AgentClaude "/work/project" "prompt"
            & #modelId .~ Just "   "
    cmd <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
    cmd ^. #arguments
      @?= ["-p", "--no-session-persistence", "--permission-mode", "plan"]

agentSessionPersistenceTest :: TestTree
agentSessionPersistenceTest =
  testCase "unattended claude argv persists a session only when asked" $ do
    let req = agentRunRequest AgentClaude "/work/project" "prompt"
        persisting = ClaudeAgent.defaultClaudeAgentConfig & #persistSession .~ True
    byDefault <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
    byDefault ^. #arguments
      @?= ["-p", "--no-session-persistence", "--permission-mode", "plan"]
    persisted <- renderedAgentCommand persisting req
    persisted ^. #arguments @?= ["-p", "--permission-mode", "plan"]

-- | The unattended renderer describes what it did with the caller's
-- reasoning-effort request, and the description agrees with the argument
-- vector it produced.
--
-- Asserted together on purpose: the whole value of the translation is
-- that it survives a collapse the command line cannot express, and two
-- separate tests could drift apart without either failing.
agentThinkingTranslationTests :: TestTree
agentThinkingTranslationTests =
  testGroup
    "the unattended claude renderer records what --effort actually received"
    ( testCase
        "no effort requested is not a downgrade"
        ( do
            (cmd, translation) <- renderedAgentPair ClaudeAgent.defaultClaudeAgentConfig (effortRequest Nothing)
            assertBool
              ("no --effort flag is rendered: " <> show (cmd ^. #arguments))
              ("--effort" `notElem` (cmd ^. #arguments))
            translation @?= noThinkingRequested
        )
        : [ testCase (Text.unpack (renderThinkingLevel level)) $ do
              (cmd, translation) <-
                renderedAgentPair ClaudeAgent.defaultClaudeAgentConfig (effortRequest (Just level))
              assertBool
                ("--effort " <> Text.unpack wire <> " in " <> show (cmd ^. #arguments))
                (["--effort", Text.unpack wire] `isConsecutiveIn` (cmd ^. #arguments))
              translation
                @?= ThinkingTranslation
                  { requested = Just level,
                    mode = ThinkingModeFlag,
                    effortText = Just wire,
                    budgetTokens = Nothing,
                    wireField = Just "--effort",
                    adjustments = expected
                  }
          | (level, wire, expected) <-
              [ -- claude's --effort has no minimal, so the lowest level
                -- collapses and a run at minimal is wire-identical to a
                -- run at low.
                (ThinkingMinimal, "low", [EffortClamped ThinkingMinimal "low"]),
                (ThinkingLow, "low", []),
                (ThinkingMedium, "medium", []),
                (ThinkingHigh, "high", []),
                (ThinkingXHigh, "xhigh", []),
                (ThinkingMax, "max", [])
              ]
          ]
    )
  where
    effortRequest level =
      agentRunRequest AgentClaude "/work/project" "prompt" & #effort .~ level

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
-- translation functions rather than by hand-built adjustments.
--
-- The generic gate is exhaustively covered in
-- @baikai/test/StrictEvidenceSpec.hs@; what only this package can prove
-- is that its own downgrade sites actually reach the gate.
strictEvidenceTests :: TestTree
strictEvidenceTests =
  testGroup
    "strict evidence refuses this provider's real downgrades"
    [ testCase "a model that does not advertise reasoning is refused" $ do
        let m =
              emptyModel
                & #modelId .~ "claude-no-reasoning"
                & #api .~ AnthropicMessages
                & #reasoning .~ False
            opts = emptyOptions & #thinking .~ Just ThinkingHigh
        expectDowngrade
          (ThinkingDroppedUnsupportedModel ThinkingHigh)
          (describeThinkingFor m opts),
      testCase "A THINKING BUDGET THAT WILL NOT FIT max_tokens IS REFUSED" $ do
        -- The least discoverable downgrade in baikai: a caller lowered
        -- maxTokens and silently lost thinking on a reasoning model.
        let m =
              emptyModel
                & #modelId .~ "claude-reasoning"
                & #api .~ AnthropicMessages
                & #reasoning .~ True
                & #maxOutputTokens .~ 8192
            opts =
              emptyOptions
                & #thinking .~ Just ThinkingMax
                & #maxTokens .~ Just 128
        case describeThinkingFor m opts ^. #adjustments of
          [ThinkingDroppedBudgetExceeded lvl _ _] -> lvl @?= ThinkingMax
          other -> assertFailure ("expected a budget drop, got: " <> show other)
        assertBool
          "the gate must refuse it"
          (not (null (checkEvidenceRequirements (EvidenceRequired EvidenceRequestedOnly) AnthropicMessages (describeThinkingFor m opts)))),
      testCase "the claude CLI's minimal collapse is refused" $
        expectDowngrade
          (EffortClamped ThinkingMinimal "low")
          (ClaudeCli.claudeCliThinking (emptyOptions & #thinking .~ Just ThinkingMinimal)),
      testCase "a level this transport expresses exactly is not refused" $ do
        let m =
              emptyModel
                & #modelId .~ "claude-reasoning"
                & #api .~ AnthropicMessages
                & #reasoning .~ True
                & #maxOutputTokens .~ 64000
            opts = emptyOptions & #thinking .~ Just ThinkingMedium
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          AnthropicMessages
          (describeThinkingFor m opts)
          @?= []
    ]
  where
    expectDowngrade expected translation =
      case checkEvidenceRequirements
        (EvidenceRequired EvidenceRequestedOnly)
        AnthropicMessages
        translation of
        [ThinkingWouldDowngrade [reported]] -> reported @?= expected
        other -> assertFailure ("expected one downgrade refusal, got: " <> show other)

agentProviderGuardTest :: TestTree
agentProviderGuardTest =
  testCase "the claude renderer refuses a request that names codex" $ do
    let req = agentRunRequest AgentCodex "/work/project" "prompt"
    fmap fst (ClaudeAgent.claudeAgentCommand ClaudeAgent.defaultClaudeAgentConfig req)
      @?= Left (ProviderMismatch AgentClaude AgentCodex)

-- | The launch shape this initiative's first consumer embeds today in
-- @scripts/sync-keiro-dsl.sh@ in the @shinzui/keiro-syntax@ repository,
-- rendered from a provider-neutral request instead of Claude-specific
-- flags written into the script.
agentKeiroFixtureTest :: TestTree
agentKeiroFixtureTest =
  testCase "the sync-keiro-dsl launch shape renders without script-level claude flags" $ do
    let req =
          agentRunRequest AgentClaude "/work/keiro-syntax" "reconcile the Keiro DSL"
            & #extraDirs .~ ["/work/keiro"]
            & #safety
              .~ ( agentSafety AgentEditWorkspace
                     & #allowedTools
                       .~ [ "Read",
                            "Write",
                            "Edit",
                            "Glob",
                            "Grep",
                            "Bash",
                            "Skill",
                            "TodoWrite"
                          ]
                 )
    cmd <- renderedAgentCommand ClaudeAgent.defaultClaudeAgentConfig req
    cmd ^. #executable @?= "claude"
    cmd ^. #arguments
      @?= [ "-p",
            "--no-session-persistence",
            "--permission-mode",
            "acceptEdits",
            "--allowedTools",
            "Read,Write,Edit,Glob,Grep,Bash,Skill,TodoWrite",
            "--add-dir",
            "/work/keiro"
          ]
    cmd ^. #promptTransport @?= PromptOnStdin
    cmd ^. #promptText @?= "reconcile the Keiro DSL"

batchCommandRenderingTest :: TestTree
batchCommandRenderingTest =
  testCase "claude -p argv terminates options before a dash-leading prompt" $ do
    let cfg =
          ClaudeCli.defaultClaudeCliConfig
            { ClaudeCli.executable = "/bin/claude",
              ClaudeCli.extraArgs = ["--allowedTools", "Read"]
            }
        model =
          emptyModel
            & #modelId .~ "sonnet"
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx =
          emptyContext
            & #systemPrompt .~ Just "Be terse."
            & #messages .~ Vector.singleton (user "-begin with a dash")
    ClaudeCli.claudeCliCommand cfg model ctx emptyOptions
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

batchEffortRenderingTests :: TestTree
batchEffortRenderingTests =
  testGroup
    "claude -p argv renders reasoning effort between the system prompt and extra args"
    [ testCase name $ do
        let cfg =
              ClaudeCli.defaultClaudeCliConfig
                { ClaudeCli.executable = "/bin/claude",
                  ClaudeCli.extraArgs = ["--allowedTools", "Read"]
                }
            model =
              emptyModel
                & #modelId .~ "sonnet"
                & #api .~ AnthropicMessagesCli
                & #provider .~ "anthropic"
            ctx =
              emptyContext
                & #systemPrompt .~ Just "Be terse."
                & #messages .~ Vector.singleton (user "ping")
            opts = emptyOptions & #thinking .~ Just level
        ClaudeCli.claudeCliCommand cfg model ctx opts
          @?= ( "/bin/claude",
                [ "-p",
                  "--model",
                  "sonnet",
                  "--output-format",
                  "json",
                  "--no-session-persistence",
                  "--system-prompt",
                  "Be terse.",
                  "--effort",
                  expected,
                  "--allowedTools",
                  "Read",
                  "--",
                  "ping"
                ]
              )
    | (name, level, expected) <-
        [ ("minimal as low", ThinkingMinimal, "low"),
          ("max", ThinkingMax, "max")
        ]
    ]

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
    registerApiProviderWith reg (ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = script})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    mResp <- timeout 30000000 (completeRequestWith reg model ctx emptyOptions)
    case mResp of
      Nothing -> assertFailure "deadlock: stderr was not drained concurrently"
      Just resp -> assistantText resp @?= "pong"

compatDetectionTest :: TestTree
compatDetectionTest =
  testCase "Anthropic-compatible hosts auto-detect request-shaping compat flags" $ do
    let model =
          emptyModel
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
          emptyModel
            & #modelId .~ "claude-test"
            & #api .~ AnthropicMessages
            & #provider .~ "anthropic"
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
    events <- Stream.toList (claudeMessagesStream model ctx emptyOptions)
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
  testCase "missing ANTHROPIC_API_KEY yields one terminal EventError" $
    withUnsetEnv "ANTHROPIC_API_KEY" $ do
      let model =
            emptyModel
              & #modelId .~ "claude-test"
              & #api .~ AnthropicMessages
              & #provider .~ "anthropic"
      events <- Stream.toList (claudeMessagesStream model emptyContext emptyOptions)
      assertErrorContract events
      case last events of
        EventError TerminalPayload {errorInfo = Just be} ->
          be ^. #category @?= AuthError
        other -> assertFailure ("expected terminal EventError with AuthError, got: " <> show other)

cliMissingBinaryTest :: TestTree
cliMissingBinaryTest =
  testCase "claude CLI missing binary returns an error-shaped Response" $ do
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      (ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = "/nonexistent/claude-binary"})
    let model =
          emptyModel
            & #modelId .~ ""
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
        ctx = emptyContext & #messages .~ Vector.singleton (user "ping")
    resp <- completeRequestWith reg model ctx emptyOptions
    case responseError resp of
      Just be -> be ^. #category @?= OtherError
      Nothing -> assertFailure "expected missing binary to be returned in-band"

withUnsetEnv :: String -> IO a -> IO a
withUnsetEnv name action =
  bracket
    (lookupEnv name)
    restore
    (const (unsetEnv name >> action))
  where
    restore = maybe (unsetEnv name) (setEnv name)

assertErrorContract :: [AssistantMessageEvent] -> Assertion
assertErrorContract events = do
  let terminals = filter isTerminal events
  length terminals @?= 1
  case terminals of
    [EventError TerminalPayload {errorInfo = Nothing}] ->
      assertFailure "terminal EventError omitted errorInfo"
    _ -> pure ()

assistantText :: Response -> Text.Text
assistantText resp =
  Text.concat
    [ t
    | AssistantText (TextContent t) <- Vector.toList (resp ^. #message ^. #content)
    ]
