-- | Tests for layered KDL job resolution and the operator policy
-- ceiling.
--
-- Every test constructs an 'AgentConfigPaths' explicitly and points it
-- at a temporary directory. None of them reads the real @HOME@ or
-- @XDG_CONFIG_HOME@: a developer with a real
-- @~\/.config\/baikai\/agents.kdl@ would otherwise get different results
-- from a clean machine, and the failure would be baffling.
module ConfigTests (configTests) where

import Baikai.Agent
  ( AgentOutputMode (..),
    AgentProvider (..),
    renderAgentRenderError,
  )
import Baikai.Agent.Config
  ( AgentConfigPaths (..),
    AgentConfigScope (..),
    AgentJob,
    agentEnvBindings,
    agentJobRequest,
    applyCeilingToJob,
    defaultOutputLimit,
    listAgentJobs,
    loadAgentCeiling,
    parseDuration,
    renderAgentConfigError,
    resolveAgentJob,
  )
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Settei.Env (EnvSnapshot, envSnapshot)
import Settei.Key (parseKey)
import Settei.Optparse (CliOverride, cliOverride)
import Settei.Render (renderErrorsText, renderResolutionJson, renderResolutionText)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

configTests :: TestTree
configTests =
  testGroup
    "Baikai.Agent.Config"
    [ testGroup
        "layering"
        [ repositoryBeatsUserTest,
          commandLineBeatsBothTest,
          environmentLayerTest,
          defaultsTest,
          singleArgumentListTest,
          missingFileTest
        ],
      testGroup
        "provenance and secrecy"
        [ provenanceTest,
          redactionTest
        ],
      testGroup
        "malformed input"
        [ noSilentFallbackTest,
          kdlSyntaxErrorTest,
          durationTests,
          invalidJobNameTest
        ],
      testGroup
        "the operator policy ceiling"
        [ defaultCeilingRefusesFullAccessTest,
          defaultCeilingPermitsEditWorkspaceTest,
          userFileRaisesCeilingTest,
          repositoryFileCannotRaiseTheCeilingTest,
          commandLineCannotRaiseTheCeilingTest
        ],
      testGroup
        "enumeration"
        [ listJobsTest
        ],
      environmentBindingsValidateTest
    ]

-- | Write the supplied documents into a temporary directory and hand
-- back paths pointing at them. Either scope may be absent, which is the
-- normal state for an operator who has written no policy file.
withConfigs :: Maybe Text -> Maybe Text -> (AgentConfigPaths -> IO a) -> IO a
withConfigs userDoc repoDoc action =
  withSystemTempDirectory "baikai-agent-config" $ \dir -> do
    userConfig <- traverse (writeDoc dir "user.kdl") userDoc
    repoConfig <- traverse (writeDoc dir "repo.kdl") repoDoc
    action AgentConfigPaths {userConfig, repoConfig}
  where
    writeDoc dir fileName body = do
      let path = dir </> fileName
      TextIO.writeFile path body
      pure path

noEnvironment :: EnvSnapshot
noEnvironment = envSnapshot []

-- | An override as the command line would supply it.
override :: Text -> Text -> CliOverride
override key value =
  cliOverride (either (error . show) id (parseKey key)) value

-- | Resolve a job, failing the test with the real diagnosis when either
-- loading or resolution fails.
resolveJob :: AgentConfigPaths -> EnvSnapshot -> [CliOverride] -> Text -> IO AgentJob
resolveJob paths snapshot overrides jobName = do
  loaded <- resolveAgentJob paths snapshot overrides jobName
  case loaded of
    Left problem ->
      assertFailure ("loading failed: " <> Text.unpack (renderAgentConfigError problem))
    Right resolved -> case resolved ^. #answer of
      Left problems ->
        assertFailure ("resolution failed: " <> Text.unpack (renderErrorsText problems))
      Right job -> pure job

-- | The rendered resolution failure, for tests that expect one.
resolutionFailure :: AgentConfigPaths -> Text -> IO Text
resolutionFailure paths jobName = do
  loaded <- resolveAgentJob paths noEnvironment [] jobName
  case loaded of
    Left problem -> pure (renderAgentConfigError problem)
    Right resolved -> case resolved ^. #answer of
      Left problems -> pure (renderErrorsText problems)
      Right job -> assertFailure ("expected a failure, got: " <> show job)

-- | A complete job that asks for the given capability.
jobDoc :: Text -> Text
jobDoc capability =
  Text.unlines
    [ "jobs {",
      "  demo {",
      "    provider \"claude\"",
      "    working-dir \"/tmp\"",
      "    safety {",
      "      capability \"" <> capability <> "\"",
      "    }",
      "  }",
      "}"
    ]

repositoryBeatsUserTest :: TestTree
repositoryBeatsUserTest =
  testCase "a repository value beats a user value"
    $ withConfigs
      (Just (Text.unlines ["jobs {", "  demo {", "    provider \"codex\"", "  }", "}"]))
      (Just (jobDoc "edit-workspace"))
    $ \paths -> do
      job <- resolveJob paths noEnvironment [] "demo"
      job ^. #provider @?= AgentClaude

commandLineBeatsBothTest :: TestTree
commandLineBeatsBothTest =
  testCase "a command-line override beats both files"
    $ withConfigs
      (Just (Text.unlines ["jobs {", "  demo {", "    provider \"codex\"", "  }", "}"]))
      (Just (jobDoc "edit-workspace"))
    $ \paths -> do
      job <-
        resolveJob paths noEnvironment [override "jobs.demo.provider" "codex"] "demo"
      job ^. #provider @?= AgentCodex

environmentLayerTest :: TestTree
environmentLayerTest =
  testCase "the environment beats a file but loses to the command line" $
    withConfigs Nothing (Just (jobDoc "read-only")) $ \paths -> do
      fromEnvironment <-
        resolveJob paths (envSnapshot [("BAIKAI_AGENT_PROVIDER", "codex")]) [] "demo"
      fromEnvironment ^. #provider @?= AgentCodex
      fromCommandLine <-
        resolveJob
          paths
          (envSnapshot [("BAIKAI_AGENT_PROVIDER", "codex")])
          [override "jobs.demo.provider" "claude"]
          "demo"
      fromCommandLine ^. #provider @?= AgentClaude

defaultsTest :: TestTree
defaultsTest =
  testCase "a minimal job resolves with the built-in defaults" $
    -- The counterpart to the runner's own defaults test: this is what
    -- makes a terse configuration file usable.
    withConfigs Nothing (Just (jobDoc "read-only")) $ \paths -> do
      job <- resolveJob paths noEnvironment [] "demo"
      job ^. #output @?= InheritOutput
      job ^. #outputLimit @?= Just defaultOutputLimit
      job ^. #extraDirs @?= []
      job ^. #allowedTools @?= []
      job ^. #providerArgs @?= []
      job ^. #envRequires @?= []
      job ^. #timeout @?= Nothing
      job ^. #executable @?= Nothing

singleArgumentListTest :: TestTree
singleArgumentListTest =
  testCase "a list setting accepts none, one, or many arguments"
    $
    -- A KDL node's raw shape depends on its argument count: none is a
    -- null, one is a scalar, and only two or more is an array. settei's
    -- own listDecoder accepts an array alone, so without the
    -- scalar-tolerant decoder the one-directory spelling below — the
    -- form the user guide documents — would fail to decode.
    withConfigs
      Nothing
      ( Just
          ( Text.unlines
              [ "jobs {",
                "  one { provider \"claude\"; working-dir \"/tmp\"",
                "    extra-dirs \"/only\"",
                "    safety { capability \"read-only\" }",
                "  }",
                "  many { provider \"claude\"; working-dir \"/tmp\"",
                "    extra-dirs \"/first\" \"/second\"",
                "    safety { capability \"read-only\" }",
                "  }",
                "  none { provider \"claude\"; working-dir \"/tmp\"",
                "    extra-dirs",
                "    safety { capability \"read-only\" }",
                "  }",
                "}"
              ]
          )
      )
    $ \paths -> do
      one <- resolveJob paths noEnvironment [] "one"
      one ^. #extraDirs @?= ["/only"]
      many <- resolveJob paths noEnvironment [] "many"
      many ^. #extraDirs @?= ["/first", "/second"]
      none <- resolveJob paths noEnvironment [] "none"
      none ^. #extraDirs @?= []
      -- A command-line override is always a scalar too.
      overridden <-
        resolveJob paths noEnvironment [override "jobs.none.extra-dirs" "/from-flag"] "none"
      overridden ^. #extraDirs @?= ["/from-flag"]

missingFileTest :: TestTree
missingFileTest =
  testCase "with no configuration at all the required settings are named" $
    withConfigs Nothing Nothing $ \paths -> do
      message <- resolutionFailure paths "demo"
      assertBool
        ("the provider key is named: " <> Text.unpack message)
        (Text.isInfixOf "jobs.demo.provider" message)
      assertBool
        ("the working directory key is named: " <> Text.unpack message)
        (Text.isInfixOf "jobs.demo.working-dir" message)
      assertBool
        ("the capability key is named: " <> Text.unpack message)
        (Text.isInfixOf "jobs.demo.safety.capability" message)

provenanceTest :: TestTree
provenanceTest =
  testCase "the report attributes each value to its own file, with a line number"
    $
    -- The headline capability of this plan, and improvement-request
    -- acceptance criterion 5.
    withConfigs
      (Just (Text.unlines ["jobs {", "  demo {", "    timeout \"45m\"", "  }", "}"]))
      (Just (jobDoc "edit-workspace"))
    $ \paths -> do
      loaded <- resolveAgentJob paths noEnvironment [] "demo"
      resolved <- case loaded of
        Left problem ->
          assertFailure ("loading failed: " <> Text.unpack (renderAgentConfigError problem))
        Right value -> pure value
      let asText = renderResolutionText (resolved ^. #report)
          asJson = renderResolutionJson (resolved ^. #report)
      assertBool
        ("the text report names the repository scope: " <> Text.unpack asText)
        (Text.isInfixOf "repository configuration" asText)
      assertBool
        ("the text report names the user scope: " <> Text.unpack asText)
        (Text.isInfixOf "user configuration" asText)
      -- renderResolutionText names the source but drops the location,
      -- so the line number is asserted against the JSON rendering,
      -- which carries path, line, and column. Without this the test
      -- would pass even if settei-kdl's span preservation were
      -- silently dropped on the way into the report.
      userPath <- maybe (assertFailure "expected a user file") pure (paths ^. #userConfig)
      repoPath <- maybe (assertFailure "expected a repository file") pure (paths ^. #repoConfig)
      assertBool
        ("the JSON report cites the repository file: " <> Text.unpack asJson)
        (Text.isInfixOf (Text.pack repoPath) asJson)
      assertBool
        ("the JSON report cites the user file: " <> Text.unpack asJson)
        (Text.isInfixOf (Text.pack userPath) asJson)
      assertBool
        ("the JSON report carries a line number: " <> Text.unpack asJson)
        (Text.isInfixOf "\"line\":" asJson)

redactionTest :: TestTree
redactionTest =
  testCase "raw provider arguments never reach a report"
    $
    -- This is what makes the secret classification real rather than
    -- decorative: provider-args is the one field an operator could write
    -- a credential into.
    withConfigs
      Nothing
      ( Just
          ( Text.unlines
              [ "jobs {",
                "  demo {",
                "    provider \"claude\"",
                "    working-dir \"/tmp\"",
                "    safety {",
                "      capability \"read-only\"",
                "      provider-args \"--api-key\" \"sk-not-a-real-key\"",
                "    }",
                "  }",
                "}"
              ]
          )
      )
    $ \paths -> do
      loaded <- resolveAgentJob paths noEnvironment [] "demo"
      resolved <- case loaded of
        Left problem ->
          assertFailure ("loading failed: " <> Text.unpack (renderAgentConfigError problem))
        Right value -> pure value
      let asText = renderResolutionText (resolved ^. #report)
          asJson = renderResolutionJson (resolved ^. #report)
      assertBool
        "the text report does not contain the credential"
        (not (Text.isInfixOf "sk-not-a-real-key" asText))
      assertBool
        "the JSON report does not contain the credential"
        (not (Text.isInfixOf "sk-not-a-real-key" asJson))
      -- Redacting the value must not hide that the setting was set.
      assertBool
        ("the key name still appears: " <> Text.unpack asText)
        (Text.isInfixOf "jobs.demo.safety.provider-args" asText)
      -- The resolved job still carries the real value; only reports redact.
      job <- resolveJob paths noEnvironment [] "demo"
      job ^. #providerArgs @?= ["--api-key", "sk-not-a-real-key"]

noSilentFallbackTest :: TestTree
noSilentFallbackTest =
  testCase "a misspelled value fails rather than falling back to a valid one"
    $
    -- Pins settei's no-silent-fallback behavior, which this module
    -- depends on and which a dependency upgrade could regress: a typo in
    -- an untrusted repository file must not quietly activate an
    -- operator's default.
    withConfigs
      (Just (jobDoc "read-only"))
      ( Just
          ( Text.unlines
              [ "jobs {",
                "  demo {",
                "    safety { capability \"edit-worksapce\" }",
                "  }",
                "}"
              ]
          )
      )
    $ \paths -> do
      message <- resolutionFailure paths "demo"
      assertBool
        ("the offending key is named: " <> Text.unpack message)
        (Text.isInfixOf "jobs.demo.safety.capability" message)

kdlSyntaxErrorTest :: TestTree
kdlSyntaxErrorTest =
  testCase "a syntax error is reported without echoing the document" $
    withConfigs Nothing (Just "jobs {\n  demo {\n    provider \"secret-looking-value\"\n") $ \paths -> do
      loaded <- resolveAgentJob paths noEnvironment [] "demo"
      case loaded of
        Right _ -> assertFailure "expected the malformed document to be refused"
        Left problem -> do
          let message = renderAgentConfigError problem
          -- settei-kdl errors carry a category, a name, a path, and a
          -- span, never an excerpt. Appending the document "for context"
          -- would defeat that redaction, so assert it was not.
          assertBool
            ("the message does not echo the document: " <> Text.unpack message)
            (not (Text.isInfixOf "secret-looking-value" message))

durationTests :: TestTree
durationTests =
  testGroup
    "durations"
    [ testCase "seconds" $ parseDuration "90s" @?= Just 90,
      testCase "minutes" $ parseDuration "45m" @?= Just 2700,
      testCase "hours" $ parseDuration "2h" @?= Just 7200,
      testCase "a bare number means seconds" $ parseDuration "45" @?= Just 45,
      -- Zero is refused rather than treated as "no timeout": it would
      -- mean "kill every run immediately", which no operator intends.
      testCase "zero is refused" $ parseDuration "0" @?= Nothing,
      testCase "a negative duration is refused" $ parseDuration "-5m" @?= Nothing,
      testCase "unparseable text is refused" $ parseDuration "soon" @?= Nothing,
      testCase "an unknown unit is refused" $ parseDuration "5d" @?= Nothing
    ]

invalidJobNameTest :: TestTree
invalidJobNameTest =
  testCase "a job name that cannot address a key is refused" $
    withConfigs Nothing (Just (jobDoc "read-only")) $ \paths -> do
      loaded <- resolveAgentJob paths noEnvironment [] "has.a.dot"
      case loaded of
        Right _ -> assertFailure "expected a dotted job name to be refused"
        Left problem ->
          assertBool
            "the message explains the dot"
            (Text.isInfixOf "dot" (renderAgentConfigError problem))

-- | Load the ceiling, failing the test with the real diagnosis.
ceilingFor :: AgentConfigPaths -> IO (Either Text Text)
ceilingFor paths = do
  loaded <- loadAgentCeiling paths
  case loaded of
    Left problem ->
      assertFailure ("loading the ceiling failed: " <> Text.unpack (renderAgentConfigError problem))
    Right ceiling' -> pure (Right (Text.pack (show ceiling')))

-- | Resolve a job, apply the ceiling, and report the refusal message if
-- there was one.
runAgainstCeiling :: AgentConfigPaths -> [CliOverride] -> Text -> IO (Either Text ())
runAgainstCeiling paths overrides jobName = do
  job <- resolveJob paths noEnvironment overrides jobName
  loaded <- loadAgentCeiling paths
  ceiling' <- case loaded of
    Left problem ->
      assertFailure ("loading the ceiling failed: " <> Text.unpack (renderAgentConfigError problem))
    Right value -> pure value
  pure $ case applyCeilingToJob ceiling' (agentJobRequest job "a prompt") of
    Left refusal -> Left (renderAgentRenderError refusal)
    Right _ -> Right ()

-- | A user document that raises the ceiling, and a repository document
-- that tries to.
raisingPolicyDoc :: Text
raisingPolicyDoc = Text.unlines ["policy {", "  max-capability \"full-access\"", "}"]

defaultCeilingRefusesFullAccessTest :: TestTree
defaultCeilingRefusesFullAccessTest =
  testCase "with no user file, full access is refused naming both values" $
    withConfigs Nothing (Just (jobDoc "full-access")) $ \paths -> do
      outcome <- runAgainstCeiling paths [] "demo"
      case outcome of
        Right () -> assertFailure "expected full access to be refused"
        Left message -> do
          assertBool
            ("the requested value is named: " <> Text.unpack message)
            (Text.isInfixOf "full-access" message)
          assertBool
            ("the permitted maximum is named: " <> Text.unpack message)
            (Text.isInfixOf "edit-workspace" message)

defaultCeilingPermitsEditWorkspaceTest :: TestTree
defaultCeilingPermitsEditWorkspaceTest =
  testCase "with no user file, editing the workspace is permitted" $
    -- The zero-configuration path the first consumer depends on: a job
    -- that changes files must work on a fresh machine with no
    -- out-of-band setup step.
    withConfigs Nothing (Just (jobDoc "edit-workspace")) $ \paths -> do
      outcome <- runAgainstCeiling paths [] "demo"
      outcome @?= Right ()

userFileRaisesCeilingTest :: TestTree
userFileRaisesCeilingTest =
  testCase "the operator's own file may raise the ceiling" $
    withConfigs (Just raisingPolicyDoc) (Just (jobDoc "full-access")) $ \paths -> do
      outcome <- runAgainstCeiling paths [] "demo"
      outcome @?= Right ()

repositoryFileCannotRaiseTheCeilingTest :: TestTree
repositoryFileCannotRaiseTheCeilingTest =
  testCase "A REPOSITORY FILE CANNOT RAISE THE CEILING" $
    -- The central security property of this module. A repository
    -- configuration file is untrusted input; if it could set
    -- policy.max-capability an untrusted checkout would grant itself
    -- whatever it liked. If this test fails, the repository source has
    -- leaked into loadAgentCeiling's source list.
    withConfigs Nothing (Just (jobDoc "full-access" <> raisingPolicyDoc)) $ \paths -> do
      shown <- ceilingFor paths
      case shown of
        Left problem -> assertFailure (Text.unpack problem)
        Right rendered ->
          assertBool
            ("the ceiling is unchanged: " <> Text.unpack rendered)
            (Text.isInfixOf "AgentEditWorkspace" rendered)
      outcome <- runAgainstCeiling paths [] "demo"
      case outcome of
        Right () -> assertFailure "the repository file raised the ceiling"
        Left message ->
          assertBool
            ("the refusal names the permitted maximum: " <> Text.unpack message)
            (Text.isInfixOf "edit-workspace" message)

commandLineCannotRaiseTheCeilingTest :: TestTree
commandLineCannotRaiseTheCeilingTest =
  testCase "A COMMAND-LINE OVERRIDE CANNOT RAISE THE CEILING" $
    -- The other half of the central security property.
    -- `--set policy.max-capability=full-access` is exactly the flag a
    -- compromised automation script would add, and it must change
    -- nothing. Note that loadAgentCeiling takes no overrides at all,
    -- which is the structural reason this holds; the test pins the
    -- behavior so a later signature change cannot quietly undo it.
    withConfigs Nothing (Just (jobDoc "full-access")) $ \paths -> do
      outcome <-
        runAgainstCeiling paths [override "policy.max-capability" "full-access"] "demo"
      case outcome of
        Right () -> assertFailure "a command-line override raised the ceiling"
        Left message ->
          assertBool
            ("the refusal names the permitted maximum: " <> Text.unpack message)
            (Text.isInfixOf "edit-workspace" message)

listJobsTest :: TestTree
listJobsTest =
  testCase "job names are sorted and attributed to the winning scope"
    $ withConfigs
      ( Just
          ( Text.unlines
              [ "jobs {",
                "  demo { provider \"codex\" }",
                "  user-only { provider \"codex\" }",
                "}"
              ]
          )
      )
      (Just (jobDoc "read-only"))
    $ \paths -> do
      listed <- listAgentJobs paths
      case listed of
        Left problem ->
          assertFailure ("listing failed: " <> Text.unpack (renderAgentConfigError problem))
        Right entries -> do
          map (^. #name) entries @?= ["demo", "user-only"]
          map (^. #scope) entries @?= [RepositoryScope, UserScope]
          -- A name defined in two files is reported once, with the
          -- count, because a bare name hides a real source of
          -- confusion.
          map (^. #definingScopes) entries @?= [2, 1]

environmentBindingsValidateTest :: TestTree
environmentBindingsValidateTest =
  testCase "the environment binding list is valid" $
    -- The binding list calls `error` on an invalid entry, so forcing it
    -- here makes a bad edit fail in tests rather than at start-up.
    agentEnvBindings "probe" `seq`
      pure ()
