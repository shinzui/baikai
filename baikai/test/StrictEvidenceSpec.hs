-- | The pre-dispatch strictness gate.
--
-- Strict evidence mode is the only place in baikai that refuses to make
-- a call the caller asked for, so these cases split cleanly in two. The
-- first half proves it refuses what it must: every place baikai weakens
-- a reasoning request, and every transport that cannot reach a demanded
-- strength. The second half proves it refuses nothing else — which is
-- the harder guarantee, because it is the one every existing caller
-- depends on without knowing the feature exists.
module StrictEvidenceSpec (tests) where

import Baikai
import Baikai.Evidence.Build (minimalEvidence)
import Control.Exception (evaluate, try)
import Control.Exception qualified as Exception
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "StrictEvidenceSpec: pre-dispatch strict evidence"
    [ declaredStrengthTests,
      strengthGateTests,
      downgradeGateTests,
      bestEffortIsNeverRefusedTests,
      lazinessTests,
      dispatchTests
    ]

-- ============================================================
-- Declared strength
-- ============================================================

declaredStrengthTests :: TestTree
declaredStrengthTests =
  testGroup
    -- Each of these is separately proved reachable by a test that drives
    -- that transport to it: the Anthropic and OpenAI-compatible API
    -- cases live in each vendor package's EvidenceSpec, and the two CLI
    -- cases in its CliEvidenceSpec. This group pins the declarations
    -- themselves so a change to one is a change someone had to mean.
    "declared strength"
    [ testCase "the two API transports declare model_observed" $ do
        declaredStrength AnthropicMessages @?= EvidenceModelObserved
        declaredStrength OpenAIChatCompletions @?= EvidenceModelObserved,
      testCase "the claude CLI declares model_observed, the codex CLI correlated" $ do
        -- Not symmetry: claude names the model that consumed tokens in
        -- its result event, and codex-cli 0.146.0 names no model
        -- anywhere in its event stream.
        declaredStrength AnthropicMessagesCli @?= EvidenceModelObserved
        declaredStrength OpenAICompletionsCli @?= EvidenceCorrelated,
      testCase "a custom transport declares requested_only" $
        -- Baikai knows nothing about a caller-supplied transport and
        -- must not assume on its behalf.
        declaredStrength (Custom "someone-elses-gateway") @?= EvidenceRequestedOnly,
      testCase "NO TRANSPORT DECLARES fully_observed" $
        -- Reaching it would need a provider that echoes the thinking
        -- configuration it applied, and none of them does. A
        -- reasoning-token count corroborates output volume and says
        -- nothing about which effort setting was in force.
        assertBool
          "fully_observed must stay unreachable until a provider echoes its thinking config"
          ( all
              ((< EvidenceFullyObserved) . declaredStrength)
              [ AnthropicMessages,
                OpenAIChatCompletions,
                AnthropicMessagesCli,
                OpenAICompletionsCli,
                Custom "x"
              ]
          )
    ]

-- ============================================================
-- The strength half of the gate
-- ============================================================

strengthGateTests :: TestTree
strengthGateTests =
  testGroup
    "a transport that cannot reach the required strength is refused"
    [ testCase "a custom transport cannot supply model_observed" $
        case checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          (declaredStrength (Custom "someone-elses-gateway"))
          noThinkingRequested of
          [StrengthUnreachable needed declared] -> do
            needed @?= EvidenceModelObserved
            declared @?= EvidenceRequestedOnly
          other -> assertFailure ("expected one StrengthUnreachable, got: " <> show other),
      testCase "the codex CLI cannot supply model_observed, because it names no model" $
        case checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          (declaredStrength OpenAICompletionsCli)
          noThinkingRequested of
          [StrengthUnreachable _ declared] -> declared @?= EvidenceCorrelated
          other -> assertFailure ("expected one StrengthUnreachable, got: " <> show other),
      testCase "the codex CLI can supply correlated" $
        checkEvidenceRequirements
          (EvidenceRequired EvidenceCorrelated)
          (declaredStrength OpenAICompletionsCli)
          noThinkingRequested
          @?= [],
      testCase "an exactly-met requirement is not a refusal" $
        -- The comparison is >=, not >. A transport that declares exactly
        -- what was asked for satisfies it.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          (declaredStrength AnthropicMessages)
          noThinkingRequested
          @?= [],
      testCase "both halves of the gate report together, not one per attempt" $
        -- An operator fixing a configuration should see all of it in one
        -- run, which is what Baikai.Agent.applyAgentCeiling already does
        -- for policy violations.
        length
          ( checkEvidenceRequirements
              (EvidenceRequired EvidenceModelObserved)
              (declaredStrength (Custom "gateway"))
              (downgradedBy (EffortClamped ThinkingMax "high"))
          )
          @?= 2
    ]

-- ============================================================
-- The downgrade half: one named case per site
-- ============================================================

-- | A translation carrying one adjustment, standing in for what a
-- provider's own translation function would produce at that site. The
-- provider-side proof that each site really produces its adjustment
-- lives in that provider's own test suite; this file proves the gate
-- refuses each one.
downgradedBy :: ThinkingAdjustment -> ThinkingTranslation
downgradedBy adjustment =
  noThinkingRequested
    & #requested .~ Just ThinkingMax
    & #adjustments .~ [adjustment]

-- | Assert the gate refuses this translation and names the adjustment.
refusesDowngrade :: String -> ThinkingAdjustment -> Text -> TestTree
refusesDowngrade name adjustment expectedPhrase =
  testCase name $
    case checkEvidenceRequirements
      (EvidenceRequired EvidenceRequestedOnly)
      (declaredStrength AnthropicMessages)
      (downgradedBy adjustment) of
      [ThinkingWouldDowngrade [reported]] -> do
        reported @?= adjustment
        let message = renderEvidenceRefusal (ThinkingWouldDowngrade [adjustment])
        assertBool
          ("the refusal must explain itself, got: " <> Text.unpack message)
          (expectedPhrase `Text.isInfixOf` message)
      other -> assertFailure ("expected one ThinkingWouldDowngrade, got: " <> show other)

downgradeGateTests :: TestTree
downgradeGateTests =
  testGroup
    -- Six separate named cases rather than one parameterised test: when
    -- one breaks later, its name should say which site regressed.
    --
    -- The requirement used throughout is EvidenceRequestedOnly, the
    -- weakest there is, so each case proves the downgrade alone refuses
    -- rather than the strength check doing the work.
    "every site where baikai weakens a thinking request refuses a strict call"
    [ refusesDowngrade
        "compatibleEffort clamps a level to a weaker word"
        (EffortClamped ThinkingMax "high")
        "would be sent as high",
      refusesDowngrade
        "a Z.ai or Qwen host collapses every level to a bare toggle"
        (EffortCollapsedToToggle ThinkingMax)
        "bare on/off toggle",
      refusesDowngrade
        "an adaptive high sends no effort field at all"
        (EffortOmitted ThinkingHigh)
        "indistinguishable on the wire",
      refusesDowngrade
        "a model that does not advertise reasoning drops the whole configuration"
        (ThinkingDroppedUnsupportedModel ThinkingMax)
        "does not advertise reasoning support",
      refusesDowngrade
        "a host with no reasoning controls drops the whole configuration"
        (ThinkingDroppedUnsupportedHost ThinkingMax)
        "exposes no reasoning controls",
      refusesDowngrade
        "a thinking budget that will not fit the output ceiling is discarded"
        (ThinkingDroppedBudgetExceeded ThinkingMax 32000 8192)
        "does not fit inside the resolved output ceiling",
      testCase "several downgrades on one call are reported together" $
        case checkEvidenceRequirements
          (EvidenceRequired EvidenceRequestedOnly)
          (declaredStrength AnthropicMessages)
          ( noThinkingRequested
              & #requested .~ Just ThinkingMax
              & #adjustments
                .~ [EffortClamped ThinkingMax "high", EffortOmitted ThinkingMax]
          ) of
          [ThinkingWouldDowngrade reported] -> length reported @?= 2
          other -> assertFailure ("expected one ThinkingWouldDowngrade, got: " <> show other),
      testCase "REQUESTING NO LEVEL IS NOT A DOWNGRADE" $
        -- The judgement that is not obvious. A caller who asked for
        -- nothing has had nothing weakened, so a strict call that names
        -- no thinking level must still run.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          (declaredStrength AnthropicMessages)
          noThinkingRequested
          @?= [],
      testCase "A DROPPED SAMPLING PARAMETER IS NOT A THINKING DOWNGRADE" $
        -- The documented contract is refusing a call that would weaken
        -- the requested thinking level. A sampling parameter the model
        -- generation or the API has nowhere to put is recorded in the
        -- evidence — that is what the adjustment is for — but it is not
        -- a thinking downgrade, and a caller who set `temperature` on a
        -- Claude model must not have every strict call refused over it.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceRequestedOnly)
          (declaredStrength AnthropicMessages)
          ( noThinkingRequested
              & #adjustments .~ [SamplingDroppedUnsupportedModel ["temperature"]]
          )
          @?= [],
      testCase "a sampling drop alongside a real downgrade reports only the downgrade" $
        case checkEvidenceRequirements
          (EvidenceRequired EvidenceRequestedOnly)
          (declaredStrength AnthropicMessages)
          ( noThinkingRequested
              & #requested .~ Just ThinkingMax
              & #adjustments
                .~ [ EffortOmitted ThinkingMax,
                     SamplingDroppedUnsupportedModel ["temperature", "top_p"]
                   ]
          ) of
          [ThinkingWouldDowngrade reported] ->
            reported @?= [EffortOmitted ThinkingMax]
          other -> assertFailure ("expected one ThinkingWouldDowngrade, got: " <> show other),
      testCase "a level expressed exactly is not a downgrade" $
        -- The native OpenAI shape sends every canonical level verbatim
        -- and codex accepts all six. Refusing those would reject the
        -- configurations that honour the caller in full.
        checkEvidenceRequirements
          (EvidenceRequired EvidenceModelObserved)
          (declaredStrength OpenAIChatCompletions)
          ( noThinkingRequested
              & #requested .~ Just ThinkingXHigh
              & #mode .~ ThinkingModeAdaptive
              & #effortText .~ Just "xhigh"
          )
          @?= []
    ]

-- ============================================================
-- The guarantee every existing caller depends on
-- ============================================================

bestEffortIsNeverRefusedTests :: TestTree
bestEffortIsNeverRefusedTests =
  testGroup
    -- Exhaustive rather than representative on purpose. This is the
    -- "no existing caller is affected" promise, and a promise proved by
    -- a sample is a promise about the sample.
    "a best-effort caller is never refused, on any transport at any level"
    [ testCase (Text.unpack (renderApi api) <> " / " <> label) $
        checkEvidenceRequirements EvidenceBestEffort (declaredStrength api) translation @?= []
    | api <-
        [ AnthropicMessages,
          OpenAIChatCompletions,
          AnthropicMessagesCli,
          OpenAICompletionsCli,
          Custom "someone-elses-gateway"
        ],
      (label, translation) <-
        ("no level requested", noThinkingRequested)
          : [ ( Text.unpack (renderThinkingLevel lvl) <> " / " <> adjustmentName adjustment,
                downgradedBy adjustment
              )
            | lvl <-
                [ ThinkingMinimal,
                  ThinkingLow,
                  ThinkingMedium,
                  ThinkingHigh,
                  ThinkingXHigh,
                  ThinkingMax
                ],
              adjustment <-
                [ EffortClamped lvl "low",
                  EffortCollapsedToToggle lvl,
                  EffortOmitted lvl,
                  ThinkingDroppedUnsupportedModel lvl,
                  ThinkingDroppedUnsupportedHost lvl,
                  ThinkingDroppedBudgetExceeded lvl 32000 8192,
                  SamplingDroppedUnsupportedModel ["temperature"],
                  SamplingDroppedUnsupportedApi ["seed"]
                ]
            ]
    ]

-- | A short name for one adjustment, so each case in the exhaustive
-- group above is separately identifiable when it fails.
adjustmentName :: ThinkingAdjustment -> String
adjustmentName = \case
  EffortClamped {} -> "clamped"
  EffortCollapsedToToggle {} -> "collapsed"
  EffortOmitted {} -> "omitted"
  ThinkingDroppedUnsupportedModel {} -> "dropped-model"
  ThinkingDroppedUnsupportedHost {} -> "dropped-host"
  ThinkingDroppedBudgetExceeded {} -> "dropped-budget"
  SamplingDroppedUnsupportedModel {} -> "sampling-dropped-model"
  SamplingDroppedUnsupportedApi {} -> "sampling-dropped-api"

-- ============================================================
-- The gate does no work on the default path
-- ============================================================

lazinessTests :: TestTree
lazinessTests =
  testGroup
    -- Computing a translation means a host-compatibility lookup and a
    -- model-capability check. Doing that on every dispatch, for a
    -- feature only strict callers use, would put the cost of strict mode
    -- on the people who declined it.
    "the gate never computes a translation it does not need"
    [ testCase "A BEST-EFFORT CALL NEVER FORCES THE TRANSLATION" $ do
        outcome <-
          try
            ( evaluate
                ( length
                    ( checkEvidenceRequirements
                        EvidenceBestEffort
                        (declaredStrength AnthropicMessages)
                        explodes
                    )
                )
            )
        case outcome :: Either Exception.SomeException Int of
          Right n -> n @?= 0
          Left e -> assertFailure ("the translation was forced: " <> show e),
      testCase "a strict call does force it, so the test above means something" $ do
        outcome <-
          try
            ( evaluate
                ( length
                    ( checkEvidenceRequirements
                        (EvidenceRequired EvidenceRequestedOnly)
                        (declaredStrength AnthropicMessages)
                        explodes
                    )
                )
            )
        case outcome :: Either Exception.SomeException Int of
          Right n -> assertFailure ("expected the translation to be forced, got " <> show n)
          Left _ -> pure ()
    ]
  where
    explodes = error "the strictness gate forced a translation it should not have"

-- ============================================================
-- End to end through both dispatch points
-- ============================================================

dispatchTests :: TestTree
dispatchTests =
  testGroup
    "dispatch refuses before the provider runs"
    [ testCase "THE REFUSAL ARRIVES WITHOUT THE PROVIDER BEING CALLED" $ do
        -- The economic point of a pre-dispatch gate: a caller who cannot
        -- get the evidence they require wants to know before paying.
        -- The provider here throws if it is reached at all, so a
        -- returned error-shaped response is proof it was not.
        reg <- newProviderRegistry
        registerApiProviderWith reg explodingProvider
        resp <- completeRequestWith reg customModel testContext (strictly EvidenceModelObserved)
        case responseError resp of
          Nothing -> assertFailure "expected a refusal"
          Just err -> do
            err ^. #category @?= InvalidRequest
            assertBool
              ("the message names both strengths: " <> Text.unpack (err ^. #message))
              ( "model_observed" `Text.isInfixOf` (err ^. #message)
                  && "requested_only" `Text.isInfixOf` (err ^. #message)
              ),
      testCase "the streaming path refuses identically" $ do
        reg <- newProviderRegistry
        registerApiProviderWith reg explodingProvider
        events <-
          Stream.toList
            (streamRequestWith reg customModel testContext (strictly EvidenceModelObserved))
        case events of
          [EventStart _, EventError p] -> (p ^. #errorInfo) /= Nothing @?= True
          other -> assertFailure ("expected a start and one terminal error, got: " <> show other),
      testCase "a refused call still records the evidence explaining itself" $ do
        -- A caller told their call was refused should be able to read
        -- which requirement failed out of the record, not only out of
        -- the message.
        reg <- newProviderRegistry
        registerApiProviderWith reg explodingProvider
        resp <- completeRequestWith reg customModel testContext (strictly EvidenceModelObserved)
        case resp ^. #evidence of
          Nothing -> assertFailure "a strict caller opted into evidence and must get a record"
          Just ev -> do
            ev ^. #status @?= CallFailed
            ev ^. #strength @?= EvidenceRequestedOnly,
      testCase "a best-effort caller reaches the provider unchanged" $ do
        -- Same registry, same model, same everything but the strictness.
        reg <- newProviderRegistry
        registerApiProviderWith reg countingProvider
        resp <- completeRequestWith reg customModel testContext bestEffortOptions
        responseError resp @?= Nothing
        flattenAssistantText (flattenAssistantBlocks resp) @?= "the provider ran",
      testCase "a caller who asked for no evidence reaches the provider unchanged" $ do
        reg <- newProviderRegistry
        registerApiProviderWith reg countingProvider
        resp <- completeRequestWith reg customModel testContext emptyOptions
        responseError resp @?= Nothing
        flattenAssistantText (flattenAssistantBlocks resp) @?= "the provider ran",
      testCase "a strict completeRequest with a record-less provider fails after the call" $ do
        -- The gate lets this through: a custom provider declaring
        -- requested_only can satisfy a requested_only requirement, and
        -- one that builds a minimal record does. This one does not, and
        -- the failure is caught at the terminal instead — with no sink
        -- anywhere, which is the point of enforcing at dispatch.
        reg <- newProviderRegistry
        registerApiProviderWith reg countingProvider
        resp <- completeRequestWith reg customModel testContext (strictly EvidenceRequestedOnly)
        case responseError resp of
          Nothing -> assertFailure "expected the missing record to fail the call"
          Just err ->
            assertBool
              ("the message names the missing record: " <> Text.unpack (err ^. #message))
              ("attached no evidence record" `Text.isInfixOf` (err ^. #message))
        -- The provider was reached and its content is kept, so a caller
        -- reading the failure can still see what came back.
        flattenAssistantText (flattenAssistantBlocks resp) @?= "the provider ran",
      testCase "A CUSTOM PROVIDER DECLARING correlated SATISFIES A STRICT correlated CALL" $ do
        -- Under the tag-keyed table this was impossible: every Custom
        -- transport was capped at requested_only whatever its evidence
        -- actually reached, so a gateway that observes a response id
        -- could never serve a strict correlated caller.
        reg <- newProviderRegistry
        registerApiProviderWith reg correlatingProvider
        resp <- completeRequestWith reg customModel testContext (strictly EvidenceCorrelated)
        responseError resp @?= Nothing
        case resp ^. #evidence of
          Nothing -> assertFailure "a strict caller opted into evidence and must get a record"
          Just ev -> ev ^. #strength @?= EvidenceCorrelated,
      testCase "a declaration is still a ceiling, not a blank cheque" $ do
        reg <- newProviderRegistry
        registerApiProviderWith reg correlatingProvider
        resp <- completeRequestWith reg customModel testContext (strictly EvidenceModelObserved)
        case responseError resp of
          Nothing -> assertFailure "expected a refusal"
          Just err ->
            assertBool
              ("the message names both strengths: " <> Text.unpack (err ^. #message))
              ( "model_observed" `Text.isInfixOf` (err ^. #message)
                  && "correlated" `Text.isInfixOf` (err ^. #message)
              )
    ]

-- ============================================================
-- Fixtures
-- ============================================================

customApi :: Api
customApi = Custom "someone-elses-gateway"

customModel :: Model
customModel =
  emptyModel
    & #modelId .~ "gateway-model"
    & #api .~ customApi
    & #provider .~ "someone-else"

testContext :: Context
testContext = emptyContext & #messages .~ Vector.singleton (user "ping")

strictly :: EvidenceStrength -> Options
strictly needed =
  emptyOptions
    & #evidence .~ Just (evidenceRequest "run-57" & #strictness .~ EvidenceRequired needed)

bestEffortOptions :: Options
bestEffortOptions = emptyOptions & #evidence .~ Just (evidenceRequest "run-57")

-- | A custom transport that declares, and delivers, 'EvidenceCorrelated'
-- — a response id it observed. Its ceiling is its own declaration, which
-- the tag-keyed table could never express.
correlatingProvider :: ApiProvider
correlatingProvider =
  ApiProvider
    { apiTag = customApi,
      stream = liftCompleteToStream handler,
      complete = handler,
      describeThinking = \_ _ -> noThinkingRequested,
      strengthCeiling = EvidenceCorrelated
    }
  where
    handler m _ opts = do
      now <- getCurrentTime
      ev <-
        minimalEvidence
          m
          opts
          TransportHttpApi
          noThinkingRequested
          (Aeson.object ["model" Aeson..= (m ^. #modelId :: Text)])
          now
          now
          CallSucceeded
          Nothing
      let seen = Observed "gateway-response-1" :: Observed Text
          observed e =
            e
              & #responseId .~ seen
              & #strength .~ deriveStrength Unobserved Unobserved seen
      pure
        ( emptyResponse
            & #model .~ m
            & #evidence .~ fmap observed ev
            & #message . #content
              .~ Vector.singleton (AssistantText (TextContent "the provider ran"))
        )

-- | A provider that fails loudly if it is reached. Used to prove the
-- gate refuses /before/ dispatch rather than annotating afterwards.
explodingProvider :: ApiProvider
explodingProvider =
  ApiProvider
    { apiTag = customApi,
      stream = \_ _ _ -> error "the provider was dispatched despite a strict refusal",
      complete = \_ _ _ -> error "the provider was dispatched despite a strict refusal",
      describeThinking = \_ _ -> noThinkingRequested,
      strengthCeiling = EvidenceRequestedOnly
    }

-- | The same shape, but it answers.
countingProvider :: ApiProvider
countingProvider =
  ApiProvider
    { apiTag = customApi,
      stream = liftCompleteToStream handler,
      complete = handler,
      describeThinking = \_ _ -> noThinkingRequested,
      strengthCeiling = EvidenceRequestedOnly
    }
  where
    handler m _ _ =
      pure
        ( emptyResponse
            & #model .~ m
            & #message . #content
              .~ Vector.singleton (AssistantText (TextContent "the provider ran"))
        )
