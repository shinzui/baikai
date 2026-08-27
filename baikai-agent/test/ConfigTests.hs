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
  ( AgentCapability (..),
    AgentOutputMode (..),
    AgentProvider (..),
    CeilingViolation (..),
    renderAgentRenderError,
  )
import Baikai.Agent.Config
  ( AgentConfigError (..),
    AgentConfigPaths (..),
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
    repositoryScopeViolations,
    resolveAgentJob,
  )
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.List (isPrefixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Settei.Env (EnvSnapshot, envSnapshot)
import Settei.Key (parseKey)
import Settei.Optparse (CliOverride, cliOverride)
import Settei.Render (renderErrorsText, renderResolutionJson, renderResolutionText)
import System.Directory
  ( createDirectoryIfMissing,
    createDirectoryLink,
  )
import System.FilePath (takeDirectory, (</>))
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
          commandLineCannotRaiseTheCeilingTest,
          ceilingFileInsideRepositoryIsRefusedTest,
          ceilingFileOutsideTheRepositoryLoadsTest,
          unknownPolicyKeyIsAnErrorTest
        ],
      testGroup
        "repository scope"
        [ repositoryExecutableIsRefusedTest,
          repositoryExtraDirsAreRefusedTest,
          operatorScopeMaySetBothTest,
          workingDirMustStayInsideTheRootTest,
          executableIsNotEnvBoundTest,
          ceilingPolicyKeysTest
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
--
-- The two documents go into __different__ directories, laid out the way
-- a real machine lays them out: the repository document under a checkout
-- root, and the operator document in a sibling directory outside it.
-- That is not cosmetic. A repository-supplied @working-dir@ is confined
-- to the root, and an operator file that lies inside the root is refused
-- outright, so a layout that put both files in one directory would make
-- every scope test assert against a shape the code refuses.
withConfigs :: Maybe Text -> Maybe Text -> (AgentConfigPaths -> IO a) -> IO a
withConfigs userDoc repoDoc action =
  withSystemTempDirectory "baikai-agent-config" $ \dir -> do
    let repositoryRoot = dir </> "repo"
    createDirectoryIfMissing True repositoryRoot
    userConfig <- traverse (writeDoc (dir </> "operator" </> "agents.kdl")) userDoc
    repoConfig <-
      traverse (writeDoc (repositoryRoot </> ".baikai" </> "agents.kdl")) repoDoc
    action AgentConfigPaths {userConfig, repoConfig, repositoryRoot}
  where
    writeDoc path body = do
      createDirectoryIfMissing True (takeDirectory path)
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
jobDoc capability = jobDocWith capability []

-- | The same job with extra lines inside its @demo@ node.
--
-- The extras go inside rather than into a second document, because two
-- top-level @jobs@ nodes in one KDL document are a /repeated/ node,
-- which settei reads as an array and then cannot traverse — the failure
-- reads @cannot traverse jobs through array@ and looks like a resolution
-- bug rather than a malformed fixture.
jobDocWith :: Text -> [Text] -> Text
jobDocWith capability extras =
  Text.unlines
    ( [ "jobs {",
        "  demo {",
        "    provider \"claude\"",
        -- The repository root, which is where a repository-supplied
        -- working directory has to stay.
        "    working-dir \".\""
      ]
        <> map ("    " <>) extras
        <> [ "    safety {",
             "      capability \"" <> capability <> "\"",
             "    }",
             "  }",
             "}"
           ]
    )

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

-- --------------------------------------------------------------------
-- Repository scope
-- --------------------------------------------------------------------

-- | The violations that depend on which file supplied a value.
--
-- These cannot come from the pure ceiling check, which sees a request
-- and not its provenance, so they are computed from the resolution
-- report instead.
scopeViolationsFor :: AgentConfigPaths -> Text -> IO [CeilingViolation]
scopeViolationsFor paths jobName = do
  loaded <- resolveAgentJob paths noEnvironment [] jobName
  case loaded of
    Left problem ->
      assertFailure ("loading failed: " <> Text.unpack (renderAgentConfigError problem))
    Right resolved -> case resolved ^. #answer of
      Left problems ->
        assertFailure ("resolution failed: " <> Text.unpack (renderErrorsText problems))
      Right job -> repositoryScopeViolations paths (resolved ^. #report) jobName job

repositoryExecutableIsRefusedTest :: TestTree
repositoryExecutableIsRefusedTest =
  testCase "A REPOSITORY FILE CANNOT SET THE EXECUTABLE"
    $
    -- `executable` turns a configuration file into code execution: the
    -- named program inherits the operator's environment and receives the
    -- prompt on its standard input. A checkout must not choose it.
    withConfigs
      Nothing
      (Just (jobDocWith "edit-workspace" ["executable \"/opt/bin/claude\""]))
    $ \paths -> do
      violations <- scopeViolationsFor paths "demo"
      violations @?= [RepositoryScopeForbidden "executable"]

repositoryExtraDirsAreRefusedTest :: TestTree
repositoryExtraDirsAreRefusedTest =
  testCase "a repository file cannot grant itself extra directories"
    $
    -- Inside the root `extra-dirs` adds nothing the working directory
    -- does not already give, so the only ones a repository would ask for
    -- are outside it.
    withConfigs
      Nothing
      (Just (jobDocWith "edit-workspace" ["extra-dirs \"/Users/op/.ssh\""]))
    $ \paths -> do
      violations <- scopeViolationsFor paths "demo"
      violations @?= [RepositoryScopeForbidden "extra-dirs"]

operatorScopeMaySetBothTest :: TestTree
operatorScopeMaySetBothTest =
  testCase "the operator's own file may set the executable and extra directories"
    $ withConfigs
      ( Just
          ( operatorSettingsDoc
              ["executable \"/opt/bin/claude\"", "extra-dirs \"/Users/op/.ssh\""]
          )
      )
      (Just (jobDoc "edit-workspace"))
    $ \paths -> do
      violations <- scopeViolationsFor paths "demo"
      violations @?= []

workingDirMustStayInsideTheRootTest :: TestTree
workingDirMustStayInsideTheRootTest =
  testCase "a repository working directory must resolve inside the repository" $
    withSystemTempDirectory "baikai-agent-workdir" $ \dir -> do
      let repositoryRoot = dir </> "repo"
      createDirectoryIfMissing True (repositoryRoot </> ".baikai")
      -- A checkout could commit a symbolic link out of itself, so the
      -- check canonicalises before comparing; a textual prefix test
      -- would let this through.
      createDirectoryLink "/" (repositoryRoot </> "escape")
      let check workingDir = do
            TextIO.writeFile
              (repositoryRoot </> ".baikai" </> "agents.kdl")
              (workingDirJobDoc workingDir)
            scopeViolationsFor
              AgentConfigPaths
                { userConfig = Nothing,
                  repoConfig = Just (repositoryRoot </> ".baikai" </> "agents.kdl"),
                  repositoryRoot
                }
              "demo"
      check "." >>= (@?= [])
      check "sub" >>= (@?= [])
      inParent <- check ".."
      case inParent of
        [WorkingDirOutsideRepository _ _] -> pure ()
        other -> assertFailure ("expected one out-of-root violation, got: " <> show other)
      throughLink <- check "escape/etc"
      case throughLink of
        [WorkingDirOutsideRepository resolved reportedRoot] -> do
          -- The violation names where the link actually led, not the
          -- spelling the document used, so an operator reading it sees
          -- the escape. The exact string is the fully canonical one,
          -- which on macOS makes @\/etc@ read @\/private\/etc@ — hence
          -- the suffix rather than an equality.
          assertBool
            ("expected the link's target in the violation: " <> resolved)
            ("etc" `isSuffixOf` resolved)
          assertBool
            ("expected a directory outside the root: " <> resolved)
            (not ((reportedRoot <> "/") `isPrefixOf` resolved))
        other -> assertFailure ("expected one out-of-root violation, got: " <> show other)

executableIsNotEnvBoundTest :: TestTree
executableIsNotEnvBoundTest =
  testCase "no environment variable names the executable" $
    -- An environment variable is inherited by every child process and is
    -- easy to set by accident, so the one setting that chooses which
    -- program runs is not bound to one.
    withConfigs Nothing (Just (jobDoc "read-only")) $ \paths -> do
      job <-
        resolveJob paths (envSnapshot [("BAIKAI_AGENT_EXECUTABLE", "/evil")]) [] "demo"
      job ^. #executable @?= Nothing

ceilingPolicyKeysTest :: TestTree
ceilingPolicyKeysTest =
  testCase "the operator's file sets the grant list and both maxima"
    $ withConfigs
      ( Just
          ( Text.unlines
              [ "policy {",
                "  allowed-tools \"Bash\"",
                "  max-timeout \"2h\"",
                "  max-output-limit \"unlimited\"",
                "}"
              ]
          )
      )
      (Just (jobDoc "read-only"))
    $ \paths -> do
      loaded <- loadAgentCeiling paths
      case loaded of
        Left problem ->
          assertFailure
            ("loading the ceiling failed: " <> Text.unpack (renderAgentConfigError problem))
        Right ceiling' -> do
          ceiling' ^. #allowedTools @?= ["Bash"]
          ceiling' ^. #maxTimeout @?= Just 7200
          ceiling' ^. #maxOutputLimit @?= Nothing
          -- The unset keys keep their defaults, so an operator who
          -- writes one line still gets a complete ceiling.
          ceiling' ^. #maxCapability @?= AgentEditWorkspace

-- | An operator document supplying the given lines to the @demo@ job.
operatorSettingsDoc :: [Text] -> Text
operatorSettingsDoc settings =
  Text.unlines
    (["jobs {", "  demo {"] <> map ("    " <>) settings <> ["  }", "}"])

-- | A complete job rooted at the given working directory.
workingDirJobDoc :: Text -> Text
workingDirJobDoc workingDir =
  Text.unlines
    [ "jobs {",
      "  demo {",
      "    provider \"claude\"",
      "    working-dir \"" <> workingDir <> "\"",
      "    safety { capability \"read-only\" }",
      "  }",
      "}"
    ]

ceilingFileInsideRepositoryIsRefusedTest :: TestTree
ceilingFileInsideRepositoryIsRefusedTest =
  testCase "A CEILING FILE INSIDE THE REPOSITORY IS REFUSED" $
    -- The other half of "no repository file can raise the ceiling". The
    -- source list already refuses the repository *document*; this closes
    -- the shape where the repository supplies the *operator* document,
    -- which `--user-config .baikai/policy.kdl` and
    -- `XDG_CONFIG_HOME=$PWD/.baikai` both produce.
    withSystemTempDirectory "baikai-agent-ceiling-inside" $ \dir -> do
      let repositoryRoot = dir </> "repo"
          insidePath = repositoryRoot </> ".baikai" </> "policy.kdl"
      createDirectoryIfMissing True (takeDirectory insidePath)
      TextIO.writeFile insidePath raisingPolicyDoc
      loaded <-
        loadAgentCeiling
          AgentConfigPaths
            { userConfig = Just insidePath,
              repoConfig = Nothing,
              repositoryRoot
            }
      case loaded of
        Right ceiling' ->
          assertFailure ("the checkout supplied its own ceiling: " <> show ceiling')
        Left problem -> do
          case problem of
            CeilingFileInsideRepository _ _ -> pure ()
            other -> assertFailure ("expected a location refusal, got: " <> show other)
          let message = renderAgentConfigError problem
          assertBool
            ("both paths are named: " <> Text.unpack message)
            ( Text.isInfixOf "policy.kdl" message
                && Text.isInfixOf "repo" message
            )

ceilingFileOutsideTheRepositoryLoadsTest :: TestTree
ceilingFileOutsideTheRepositoryLoadsTest =
  testCase "the same file one directory above the repository loads" $
    -- The companion to the case above: the refusal is about where the
    -- file is, not about what it says.
    withSystemTempDirectory "baikai-agent-ceiling-outside" $ \dir -> do
      let repositoryRoot = dir </> "repo"
          outsidePath = dir </> "policy.kdl"
      createDirectoryIfMissing True repositoryRoot
      TextIO.writeFile outsidePath raisingPolicyDoc
      loaded <-
        loadAgentCeiling
          AgentConfigPaths
            { userConfig = Just outsidePath,
              repoConfig = Nothing,
              repositoryRoot
            }
      case loaded of
        Left problem ->
          assertFailure
            ("expected the ceiling to load: " <> Text.unpack (renderAgentConfigError problem))
        Right ceiling' -> ceiling' ^. #maxCapability @?= AgentFullAccess

unknownPolicyKeyIsAnErrorTest :: TestTree
unknownPolicyKeyIsAnErrorTest =
  testCase "a misspelled policy key is an error, not a warning"
    $
    -- Everywhere else an unrecognised key is a warning. Under `policy` a
    -- typo would silently leave the default in force, which for the one
    -- node whose purpose is limiting authority is indefensible.
    withConfigs
      (Just (Text.unlines ["policy {", "  max-capabilty \"read-only\"", "}"]))
      (Just (jobDoc "read-only"))
    $ \paths -> do
      loaded <- loadAgentCeiling paths
      case loaded of
        Right ceiling' ->
          assertFailure ("the typo was ignored: " <> show ceiling')
        Left (UnknownPolicySetting _ keys) -> keys @?= ["policy.max-capabilty"]
        Left other -> assertFailure ("expected an unknown-key refusal, got: " <> show other)

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
