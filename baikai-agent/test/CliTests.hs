-- | Tests for the @baikai agent@ command-line surface.
--
-- The centerpiece is the @sync-keiro-dsl@ fixture: a fake @claude@
-- executable, a real KDL job file, and the real command-line entry
-- point, asserting the exact argument vector and the exact bytes the
-- fake received on standard input. No model is ever called and no
-- coding-agent binary is ever required.
--
-- Every test builds an 'AgentConfigPaths' explicitly and drives
-- 'runAgentCliWithPaths' rather than 'runAgentCli'. A developer with a
-- real @~\/.config\/baikai\/agents.kdl@ would otherwise get different
-- results from a clean machine, and the failure would be baffling.
module CliTests (cliTests) where

import Baikai.Agent (AgentCommand, agentRunRequest)
import Baikai.Agent.Cli
  ( AgentCliCommand (..),
    AgentCliOptions (..),
    AgentCliRun,
    PromptSource (..),
    agentCliParserInfo,
    configExitCode,
    readPromptSource,
    refusedExitCode,
    renderJobCommand,
    runAgentCliWithPaths,
    usageExitCode,
  )
import Baikai.Agent.Config (AgentConfigPaths (..), AgentJob, resolveAgentJob)
import Baikai.Evidence (evidenceSchemaVersion)
import Control.Lens ((^.))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Options.Applicative qualified as Options
import Settei.Env (EnvSnapshot, envSnapshot)
import Settei.Key (parseKey)
import Settei.Optparse (cliOverride)
import System.Directory
  ( doesFileExist,
    getPermissions,
    setOwnerExecutable,
    setPermissions,
  )
import System.Environment (setEnv)
import System.FilePath ((</>))
import System.IO (IOMode (..), hClose, openFile, stdin)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

cliTests :: TestTree
cliTests =
  testGroup
    "Baikai.Agent.Cli"
    [ testGroup
        "provider dispatch"
        [ dispatchesToClaudeTest,
          dispatchesToCodexTest,
          honorsExecutableOverrideTest
        ],
      testGroup
        "agent list"
        [ listsNothingWhenUnconfiguredTest,
          listsConfiguredJobsTest
        ],
      testGroup
        "agent show"
        [ showExplainsWithProvenanceTest,
          showRedactsProviderArgumentsTest,
          showPrintsConfigurationBeforeRefusalTest,
          showReportsAnUnreadableFileTest
        ],
      testGroup
        "the sync-keiro-dsl fixture"
        [ syncKeiroDslRunsTest,
          swappingTheProviderIsAConfigurationChangeTest,
          swappingTheProviderRefusesATheToolListTest,
          theCeilingRefusesBeforeAnythingIsStartedTest
        ],
      testGroup
        "agent run"
        [ propagatesTheAgentExitCodeTest,
          inheritModeCapturesNothingTest,
          reportsAMissingExecutableTest,
          refusesAnEmptyPromptTest,
          writesTheEvidenceFileTest,
          writesNoEvidenceFileByDefaultTest
        ],
      testGroup
        "prompts"
        [ readsThePromptFromStandardInputTest,
          readsThePromptFromAFileTest,
          rejectsAMissingPromptFileTest
        ],
      testGroup
        "the parser"
        [ twoPromptSourcesAreAUsageErrorTest,
          parsesTheMotivatingInvocationTest
        ]
    ]

-- --------------------------------------------------------------------
-- Harness
-- --------------------------------------------------------------------

noEnvironment :: EnvSnapshot
noEnvironment = envSnapshot []

-- | Options naming one command, with no overrides and neither
-- configuration scope. Tests supply the paths separately, so the two
-- path fields stay 'Nothing' here and are never consulted.
options :: AgentCliCommand -> AgentCliOptions
options command =
  AgentCliOptions
    { command,
      overrides = [],
      userConfig = Nothing,
      repoConfig = Nothing,
      jsonOutput = False,
      evidenceFile = Nothing,
      runId = Nothing,
      requiredEvidence = Nothing
    }

withOverride :: Text -> Text -> AgentCliOptions -> AgentCliOptions
withOverride key value opts =
  opts
    { overrides =
        (opts ^. #overrides) <> [cliOverride (either (error . show) id (parseKey key)) value]
    }

-- | Ask for evidence, naming both a destination and an outer run.
withEvidence :: FilePath -> Text -> AgentCliOptions -> AgentCliOptions
withEvidence path outerRun opts =
  opts {evidenceFile = Just path, runId = Just outerRun}

-- | Paths naming only a repository document, which is the normal state
-- for an operator who has written no policy file.
repositoryOnly :: FilePath -> AgentConfigPaths
repositoryOnly path = AgentConfigPaths {userConfig = Nothing, repoConfig = Just path}

-- | Write a KDL document into a temporary directory and hand back the
-- workspace directory and the document's path.
withWorkspace :: (FilePath -> IO a) -> IO a
withWorkspace = withSystemTempDirectory "baikai-agent-cli"

writeDocument :: FilePath -> String -> Text -> IO FilePath
writeDocument dir name body = do
  let path = dir </> name
  TextIO.writeFile path body
  pure path

-- | Write a tiny shell script and make it executable. Every behavior
-- these tests need from a coding agent is a few lines of @sh@, which is
-- what keeps the suite free of any coding-agent binary, any
-- authentication, and any model.
writeFakeAgent :: FilePath -> String -> Text -> IO FilePath
writeFakeAgent dir name body = do
  path <- writeDocument dir name body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

-- | A fake agent that records its argument vector and its standard
-- input into the files named by two environment variables, then behaves
-- like a coding agent that succeeded.
recordingAgent :: Text -> Text -> Text
recordingAgent argvVariable stdinVariable =
  Text.unlines
    [ "#!/bin/sh",
      "printf '%s\\n' \"$@\" > \"$" <> argvVariable <> "\"",
      "cat > \"$" <> stdinVariable <> "\"",
      "echo 'reconciled the lexical surface'"
    ]

-- | The recorded argument vector, one element per line.
recordedArgv :: FilePath -> IO [Text]
recordedArgv path = Text.lines <$> TextIO.readFile path

run :: AgentConfigPaths -> AgentCliOptions -> IO AgentCliRun
run paths = runAgentCliWithPaths paths noEnvironment

-- | The prompt the fixture sends: multi-line, with a dash-leading line
-- and a non-ASCII character, because the transport decision exists to
-- make exactly that safe.
fixturePrompt :: Text
fixturePrompt =
  Text.unlines
    [ "--reconcile the lexical surface against the grammar",
      "réconcilier la grammaire — 文法",
      "leave the test gate to the script"
    ]

-- --------------------------------------------------------------------
-- Provider dispatch
-- --------------------------------------------------------------------

-- | Resolve one job from a document, failing the test with the real
-- diagnosis.
resolveOne :: Text -> Text -> IO AgentJob
resolveOne document jobName =
  withWorkspace $ \dir -> do
    path <- writeDocument dir "repo.kdl" document
    loaded <- resolveAgentJob (repositoryOnly path) noEnvironment [] jobName
    case loaded of
      Left problem -> assertFailure ("loading failed: " <> show problem)
      Right resolved -> case resolved ^. #answer of
        Left problems -> assertFailure ("resolution failed: " <> show problems)
        Right job -> pure job

minimalJob :: Text -> Text -> Text
minimalJob provider extra =
  Text.unlines
    [ "jobs {",
      "  demo {",
      "    provider \"" <> provider <> "\"",
      "    working-dir \"/tmp\"",
      extra,
      "    safety { capability \"edit-workspace\" }",
      "  }",
      "}"
    ]

renderedFor :: Text -> Text -> IO AgentCommand
renderedFor provider extra = do
  job <- resolveOne (minimalJob provider extra) "demo"
  let request = agentRunRequest (job ^. #provider) (job ^. #workingDir) "a prompt"
  case renderJobCommand job request of
    Left refusal -> assertFailure ("expected a rendered command: " <> show refusal)
    Right (command, _) -> pure command

dispatchesToClaudeTest :: TestTree
dispatchesToClaudeTest =
  testCase "a claude job renders a claude argument vector" $ do
    command <- renderedFor "claude" ""
    take 1 (command ^. #arguments) @?= ["-p"]
    command ^. #executable @?= "claude"

dispatchesToCodexTest :: TestTree
dispatchesToCodexTest =
  testCase "a codex job renders a codex argument vector" $ do
    command <- renderedFor "codex" ""
    take 1 (command ^. #arguments) @?= ["exec"]
    command ^. #executable @?= "codex"

honorsExecutableOverrideTest :: TestTree
honorsExecutableOverrideTest =
  testCase "the job's executable override becomes the program" $ do
    command <- renderedFor "claude" "    executable \"/opt/bin/claude\""
    command ^. #executable @?= "/opt/bin/claude"

-- --------------------------------------------------------------------
-- agent list
-- --------------------------------------------------------------------

listsNothingWhenUnconfiguredTest :: TestTree
listsNothingWhenUnconfiguredTest =
  testCase "an empty list exits 0 and keeps standard output empty" $ do
    -- An empty list is a normal state, not an error, and a script
    -- piping the output should never have to filter prose out of data.
    finished <- run AgentConfigPaths {userConfig = Nothing, repoConfig = Nothing} (options AgentList)
    finished ^. #exitCode @?= 0
    finished ^. #standardOutput @?= ""
    assertBool
      ("the note explains the empty list: " <> Text.unpack (finished ^. #standardError))
      ("no jobs are configured" `Text.isInfixOf` (finished ^. #standardError))

listsConfiguredJobsTest :: TestTree
listsConfiguredJobsTest =
  testCase "configured jobs are listed, sorted, with their scope" $
    withWorkspace $ \dir -> do
      path <-
        writeDocument
          dir
          "repo.kdl"
          ( Text.unlines
              [ "jobs {",
                "  zebra { provider \"claude\" }",
                "  alpha { provider \"codex\" }",
                "}"
              ]
          )
      finished <- run (repositoryOnly path) (options AgentList)
      finished ^. #exitCode @?= 0
      let listed = Text.lines (finished ^. #standardOutput)
      map (take 1 . Text.words) listed @?= [["alpha"], ["zebra"]]
      assertBool
        ("the scope is named: " <> Text.unpack (finished ^. #standardOutput))
        ("repository configuration" `Text.isInfixOf` (finished ^. #standardOutput))

-- --------------------------------------------------------------------
-- agent show
-- --------------------------------------------------------------------

showExplainsWithProvenanceTest :: TestTree
showExplainsWithProvenanceTest =
  testCase "show names each value's file and line, and the rendered command" $
    -- Improvement-request acceptance criterion 5. settei's own
    -- renderResolutionText drops the location, so this is also the test
    -- that the command-line layer walks the report itself.
    withWorkspace $ \dir -> do
      path <- writeDocument dir "repo.kdl" (minimalJob "claude" "")
      finished <- run (repositoryOnly path) (options (AgentShow "demo"))
      let output = finished ^. #standardOutput
      finished ^. #exitCode @?= 0
      assertBool
        ("the provider is named: " <> Text.unpack output)
        ("jobs.demo.provider" `Text.isInfixOf` output && "claude" `Text.isInfixOf` output)
      assertBool
        ("the file is cited: " <> Text.unpack output)
        (Text.pack path `Text.isInfixOf` output)
      assertBool
        ("a line and column follow the path: " <> Text.unpack output)
        ((Text.pack path <> ":3:") `Text.isInfixOf` output)
      assertBool
        ("the ceiling is shown: " <> Text.unpack output)
        ("max-capability" `Text.isInfixOf` output)
      assertBool
        ("the rendered vector is shown: " <> Text.unpack output)
        ("--permission-mode acceptEdits" `Text.isInfixOf` output)
      assertBool
        ("the prompt transport is shown: " <> Text.unpack output)
        ("prompt transport: standard input" `Text.isInfixOf` output)

showRedactsProviderArgumentsTest :: TestTree
showRedactsProviderArgumentsTest =
  testCase "show never prints a raw provider argument" $
    -- provider-args is the one setting an operator could write a
    -- credential into. It must not appear in the effective
    -- configuration and it must not appear in the rendered argument
    -- vector either, which is the easier of the two to overlook.
    withWorkspace $
      \dir -> do
        userPath <-
          writeDocument
            dir
            "user.kdl"
            (Text.unlines ["policy {", "  allow-provider-args #true", "}"])
        repoPath <-
          writeDocument
            dir
            "repo.kdl"
            ( Text.unlines
                [ "jobs {",
                  "  demo {",
                  "    provider \"claude\"",
                  "    working-dir \"/tmp\"",
                  "    safety {",
                  "      capability \"edit-workspace\"",
                  "      provider-args \"--api-key\" \"sk-not-a-real-key\"",
                  "    }",
                  "  }",
                  "}"
                ]
            )
        finished <-
          run
            AgentConfigPaths {userConfig = Just userPath, repoConfig = Just repoPath}
            (options (AgentShow "demo"))
        let output = finished ^. #standardOutput <> finished ^. #standardError
        finished ^. #exitCode @?= 0
        assertBool
          ("the credential does not appear: " <> Text.unpack output)
          (not ("sk-not-a-real-key" `Text.isInfixOf` output))
        assertBool
          ("the redaction marker appears: " <> Text.unpack output)
          ("<redacted>" `Text.isInfixOf` output)
        assertBool
          ("the setting is still named: " <> Text.unpack output)
          ("jobs.demo.safety.provider-args" `Text.isInfixOf` output)

showPrintsConfigurationBeforeRefusalTest :: TestTree
showPrintsConfigurationBeforeRefusalTest =
  testCase "a refused job still shows its configuration" $
    -- A job the ceiling refuses is precisely the case an operator most
    -- needs `show` for; printing nothing would hide it.
    withWorkspace $ \dir -> do
      path <-
        writeDocument
          dir
          "repo.kdl"
          ( Text.unlines
              [ "jobs {",
                "  demo {",
                "    provider \"claude\"",
                "    working-dir \"/tmp\"",
                "    safety { capability \"full-access\" }",
                "  }",
                "}"
              ]
          )
      finished <- run (repositoryOnly path) (options (AgentShow "demo"))
      finished ^. #exitCode @?= refusedExitCode
      assertBool
        ("the configuration was printed: " <> Text.unpack (finished ^. #standardOutput))
        ("jobs.demo.safety.capability" `Text.isInfixOf` (finished ^. #standardOutput))
      assertBool
        ("the refusal names both values: " <> Text.unpack (finished ^. #standardError))
        ( "full-access" `Text.isInfixOf` (finished ^. #standardError)
            && "edit-workspace" `Text.isInfixOf` (finished ^. #standardError)
        )

showReportsAnUnreadableFileTest :: TestTree
showReportsAnUnreadableFileTest =
  testCase "a malformed document exits with the configuration code" $
    withWorkspace $ \dir -> do
      path <- writeDocument dir "repo.kdl" "jobs {\n  demo {\n    provider \"claude\"\n"
      finished <- run (repositoryOnly path) (options (AgentShow "demo"))
      finished ^. #exitCode @?= configExitCode
      assertBool
        ("the file is named: " <> Text.unpack (finished ^. #standardError))
        (Text.pack path `Text.isInfixOf` (finished ^. #standardError))

-- --------------------------------------------------------------------
-- The sync-keiro-dsl fixture
-- --------------------------------------------------------------------

-- | The translation of the motivating script's launch into
-- configuration.
--
-- The real consumer would use @inherit@, and the migration guide shows
-- it that way; this fixture uses @capture@ so the test can observe the
-- output. The extra directory is deliberately __not__ here: it arrives
-- on the command line as a single @--set@, which is what makes the
-- "no provider flags in the script" claim testable.
syncKeiroDslDocument :: FilePath -> FilePath -> Text
syncKeiroDslDocument workingDir executable =
  Text.unlines
    [ "jobs {",
      "  sync-keiro-dsl {",
      "    provider     \"claude\"",
      "    working-dir  \"" <> Text.pack workingDir <> "\"",
      "    executable   \"" <> Text.pack executable <> "\"",
      "    output       \"capture\"",
      "    env-requires \"BAIKAI_TEST_CLAUDE_ARGV\" \"BAIKAI_TEST_CLAUDE_STDIN\"",
      "    safety {",
      "      capability    \"edit-workspace\"",
      "      allowed-tools \"Read\" \"Write\" \"Edit\" \"Glob\" \"Grep\" \"Bash\" \"Skill\" \"TodoWrite\"",
      "    }",
      "  }",
      "}"
    ]

syncKeiroDslRunsTest :: TestTree
syncKeiroDslRunsTest =
  testCase "THE MOTIVATING LAUNCH RUNS WITH NO PROVIDER FLAGS IN THE INVOCATION" $
    -- The initiative's central acceptance criterion. The invocation
    -- below names a job and one --set and nothing else; every Claude
    -- flag in the asserted vector came from configuration.
    withWorkspace $ \dir -> do
      let argvRecord = dir </> "argv"
          stdinRecord = dir </> "stdin"
          keiroPath = dir </> "keiro"
      setEnv "BAIKAI_TEST_CLAUDE_ARGV" argvRecord
      setEnv "BAIKAI_TEST_CLAUDE_STDIN" stdinRecord
      executable <-
        writeFakeAgent
          dir
          "claude"
          (recordingAgent "BAIKAI_TEST_CLAUDE_ARGV" "BAIKAI_TEST_CLAUDE_STDIN")
      promptPath <- writeDocument dir "prompt.txt" fixturePrompt
      configPath <- writeDocument dir "repo.kdl" (syncKeiroDslDocument dir executable)
      finished <-
        run
          (repositoryOnly configPath)
          ( withOverride
              "extra-dirs"
              (Text.pack keiroPath)
              (options (AgentRun "sync-keiro-dsl" (PromptFile promptPath)))
          )
      finished ^. #exitCode @?= 0
      argv <- recordedArgv argvRecord
      -- The whole vector, not individual members: a test that checks
      -- only membership would pass with an extra flag nobody asked for.
      argv
        @?= [ "-p",
              "--no-session-persistence",
              "--permission-mode",
              "acceptEdits",
              "--allowedTools",
              "Read,Write,Edit,Glob,Grep,Bash,Skill,TodoWrite",
              "--add-dir",
              Text.pack keiroPath
            ]
      delivered <- TextIO.readFile stdinRecord
      delivered @?= fixturePrompt
      assertBool
        ("the agent's answer is on standard output: " <> Text.unpack (finished ^. #standardOutput))
        ("reconciled the lexical surface" `Text.isInfixOf` (finished ^. #standardOutput))

swappingTheProviderIsAConfigurationChangeTest :: TestTree
swappingTheProviderIsAConfigurationChangeTest =
  testCase "changing only the provider line moves the run to codex" $
    -- The initiative's headline claim. The tool allow-list is removed
    -- too, because codex exec has no such flag; the next test covers
    -- what happens when it is left in.
    withWorkspace $ \dir -> do
      let argvRecord = dir </> "argv"
          stdinRecord = dir </> "stdin"
      setEnv "BAIKAI_TEST_CODEX_ARGV" argvRecord
      setEnv "BAIKAI_TEST_CODEX_STDIN" stdinRecord
      executable <-
        writeFakeAgent
          dir
          "codex"
          (recordingAgent "BAIKAI_TEST_CODEX_ARGV" "BAIKAI_TEST_CODEX_STDIN")
      promptPath <- writeDocument dir "prompt.txt" fixturePrompt
      configPath <-
        writeDocument
          dir
          "repo.kdl"
          ( Text.unlines
              [ "jobs {",
                "  sync-keiro-dsl {",
                "    provider     \"codex\"",
                "    working-dir  \"" <> Text.pack dir <> "\"",
                "    executable   \"" <> Text.pack executable <> "\"",
                "    output       \"capture\"",
                "    safety { capability \"edit-workspace\" }",
                "  }",
                "}"
              ]
          )
      finished <-
        run
          (repositoryOnly configPath)
          (options (AgentRun "sync-keiro-dsl" (PromptFile promptPath)))
      finished ^. #exitCode @?= 0
      argv <- recordedArgv argvRecord
      argv
        @?= [ "exec",
              "--sandbox",
              "workspace-write",
              "--cd",
              Text.pack dir,
              "--skip-git-repo-check",
              "--ephemeral"
            ]
      delivered <- TextIO.readFile stdinRecord
      delivered @?= fixturePrompt

swappingTheProviderRefusesATheToolListTest :: TestTree
swappingTheProviderRefusesATheToolListTest =
  testCase "keeping the tool allow-list on codex is refused, loudly" $
    -- The honest half of "switching providers is a configuration
    -- change": where it is not, you are told rather than silently given
    -- weaker isolation.
    withWorkspace $ \dir -> do
      let argvRecord = dir </> "argv"
      executable <- writeFakeAgent dir "codex" "#!/bin/sh\ntouch \"$1\"\n"
      promptPath <- writeDocument dir "prompt.txt" fixturePrompt
      configPath <-
        writeDocument
          dir
          "repo.kdl"
          ( Text.unlines
              [ "jobs {",
                "  sync-keiro-dsl {",
                "    provider     \"codex\"",
                "    working-dir  \"" <> Text.pack dir <> "\"",
                "    executable   \"" <> Text.pack executable <> "\"",
                "    safety {",
                "      capability    \"edit-workspace\"",
                "      allowed-tools \"Read\" \"Write\"",
                "    }",
                "  }",
                "}"
              ]
          )
      finished <-
        run
          (repositoryOnly configPath)
          (options (AgentRun "sync-keiro-dsl" (PromptFile promptPath)))
      finished ^. #exitCode @?= refusedExitCode
      assertBool
        ("the message names the sandbox alternative: " <> Text.unpack (finished ^. #standardError))
        ("sandbox" `Text.isInfixOf` (finished ^. #standardError))
      started <- doesFileExist argvRecord
      assertBool "nothing was started" (not started)

theCeilingRefusesBeforeAnythingIsStartedTest :: TestTree
theCeilingRefusesBeforeAnythingIsStartedTest =
  testCase "A REFUSED JOB NEVER REACHES PROCESS CREATION" $
    -- Improvement-request acceptance criterion 6. The assertion that
    -- carries the weight is the last one: the fake's record file does
    -- not exist, so the fake was never run.
    withWorkspace $ \dir -> do
      let argvRecord = dir </> "argv"
      executable <-
        writeFakeAgent dir "claude" ("#!/bin/sh\ntouch '" <> Text.pack argvRecord <> "'\n")
      promptPath <- writeDocument dir "prompt.txt" fixturePrompt
      configPath <-
        writeDocument
          dir
          "repo.kdl"
          ( Text.unlines
              [ "jobs {",
                "  sync-keiro-dsl {",
                "    provider    \"claude\"",
                "    working-dir \"" <> Text.pack dir <> "\"",
                "    executable  \"" <> Text.pack executable <> "\"",
                "    safety { capability \"full-access\" }",
                "  }",
                "}"
              ]
          )
      finished <-
        run
          (repositoryOnly configPath)
          (options (AgentRun "sync-keiro-dsl" (PromptFile promptPath)))
      finished ^. #exitCode @?= refusedExitCode
      assertBool
        ("the refusal names both values: " <> Text.unpack (finished ^. #standardError))
        ( "full-access" `Text.isInfixOf` (finished ^. #standardError)
            && "edit-workspace" `Text.isInfixOf` (finished ^. #standardError)
        )
      started <- doesFileExist argvRecord
      assertBool "the executable was never invoked" (not started)

-- --------------------------------------------------------------------
-- agent run
-- --------------------------------------------------------------------

-- | A job rooted in the workspace, running the given script, capturing
-- output unless told otherwise.
scriptedJob :: FilePath -> FilePath -> Text -> Text
scriptedJob dir executable outputMode =
  Text.unlines
    [ "jobs {",
      "  demo {",
      "    provider    \"claude\"",
      "    working-dir \"" <> Text.pack dir <> "\"",
      "    executable  \"" <> Text.pack executable <> "\"",
      "    output      \"" <> outputMode <> "\"",
      "    safety { capability \"edit-workspace\" }",
      "  }",
      "}"
    ]

propagatesTheAgentExitCodeTest :: TestTree
propagatesTheAgentExitCodeTest =
  testCase "the agent's own exit code passes through unchanged" $
    -- The motivating script ends its launch with `|| die`, and a script
    -- that wants to tell "the agent failed the task" from "the tool
    -- could not start" needs the codes to stay separate.
    withWorkspace $ \dir -> do
      executable <- writeFakeAgent dir "claude" "#!/bin/sh\ncat > /dev/null\nexit 3\n"
      configPath <- writeDocument dir "repo.kdl" (scriptedJob dir executable "capture")
      finished <-
        run (repositoryOnly configPath) (options (AgentRun "demo" (PromptInline "do the thing")))
      finished ^. #exitCode @?= 3
      -- Nothing extra is narrated: the agent has already explained
      -- itself on its own standard error.
      finished ^. #standardError @?= ""

inheritModeCapturesNothingTest :: TestTree
inheritModeCapturesNothingTest =
  testCase "inherit mode leaves the record empty" $
    -- The agent's line goes to the test runner's own output, which is
    -- expected: under inherit the child writes to the real streams and
    -- bypasses AgentCliRun entirely.
    withWorkspace $ \dir -> do
      executable <-
        writeFakeAgent dir "claude" "#!/bin/sh\ncat > /dev/null\necho 'inherited line'\n"
      configPath <- writeDocument dir "repo.kdl" (scriptedJob dir executable "inherit")
      finished <-
        run (repositoryOnly configPath) (options (AgentRun "demo" (PromptInline "do the thing")))
      finished ^. #exitCode @?= 0
      finished ^. #standardOutput @?= ""
      finished ^. #standardError @?= ""

reportsAMissingExecutableTest :: TestTree
reportsAMissingExecutableTest =
  testCase "a missing coding-agent binary exits 69" $
    withWorkspace $ \dir -> do
      configPath <-
        writeDocument dir "repo.kdl" (scriptedJob dir (dir </> "not-installed") "capture")
      finished <-
        run (repositoryOnly configPath) (options (AgentRun "demo" (PromptInline "do the thing")))
      finished ^. #exitCode @?= 69
      assertBool
        ("the missing program is named: " <> Text.unpack (finished ^. #standardError))
        ("not-installed" `Text.isInfixOf` (finished ^. #standardError))

writesTheEvidenceFileTest :: TestTree
writesTheEvidenceFileTest =
  testCase "--evidence-file writes one schema-valid record for the run" $
    -- The point of the option: an automation job gets a reviewable
    -- record as a side effect of running, without the script having to
    -- know anything about evidence.
    withWorkspace $ \dir -> do
      let evidencePath = dir </> "evidence.json"
      executable <-
        writeFakeAgent
          dir
          "claude"
          "#!/bin/sh\ncat > /dev/null\necho 'the task is done'\n"
      configPath <- writeDocument dir "repo.kdl" (scriptedJob dir executable "capture")
      finished <-
        run
          (repositoryOnly configPath)
          (withEvidence evidencePath "outer-run-7" (options (AgentRun "demo" (PromptInline "do the thing"))))
      finished ^. #exitCode @?= 0
      -- Nothing about the evidence file leaks onto the agent's own
      -- output, which a script may be capturing.
      finished ^. #standardOutput @?= "the task is done\n"
      recorded <- Aeson.eitherDecodeFileStrict evidencePath
      case recorded of
        Left problem -> assertFailure ("the record did not parse as JSON: " <> problem)
        Right (Aeson.Object o) -> do
          KeyMap.lookup "schema_version" o @?= Just (Aeson.String evidenceSchemaVersion)
          KeyMap.lookup "run_id" o @?= Just (Aeson.String "outer-run-7")
          KeyMap.lookup "status" o @?= Just (Aeson.String "succeeded")
          -- The fake reports nothing about itself, so the record says so
          -- rather than inferring anything from its clean exit.
          KeyMap.lookup "strength" o @?= Just (Aeson.String "requested_only")
          assertBool
            ("a call id was generated: " <> show (KeyMap.lookup "call_id" o))
            (KeyMap.lookup "call_id" o /= Nothing)
        Right other -> assertFailure ("expected one JSON object, got: " <> show other)
      -- The write is atomic through a staging file, which must not be
      -- left behind.
      leftover <- doesFileExist (evidencePath <> ".partial")
      assertBool "the staging file was renamed away" (not leftover)

writesNoEvidenceFileByDefaultTest :: TestTree
writesNoEvidenceFileByDefaultTest =
  testCase "a run that named no evidence destination writes nothing" $
    withWorkspace $ \dir -> do
      let evidencePath = dir </> "evidence.json"
      executable <-
        writeFakeAgent dir "claude" "#!/bin/sh\ncat > /dev/null\necho 'the task is done'\n"
      configPath <- writeDocument dir "repo.kdl" (scriptedJob dir executable "capture")
      finished <-
        run (repositoryOnly configPath) (options (AgentRun "demo" (PromptInline "do the thing")))
      finished ^. #exitCode @?= 0
      written <- doesFileExist evidencePath
      assertBool "no evidence file appeared" (not written)

refusesAnEmptyPromptTest :: TestTree
refusesAnEmptyPromptTest =
  testCase "an empty prompt is a usage error, not an expensive run" $
    withWorkspace $ \dir -> do
      executable <- writeFakeAgent dir "claude" "#!/bin/sh\nexit 0\n"
      configPath <- writeDocument dir "repo.kdl" (scriptedJob dir executable "capture")
      emptyPrompt <- writeDocument dir "empty.txt" ""
      finished <-
        run (repositoryOnly configPath) (options (AgentRun "demo" (PromptFile emptyPrompt)))
      finished ^. #exitCode @?= usageExitCode
      assertBool
        ("the empty source is named: " <> Text.unpack (finished ^. #standardError))
        (Text.pack emptyPrompt `Text.isInfixOf` (finished ^. #standardError))

-- --------------------------------------------------------------------
-- Prompts
-- --------------------------------------------------------------------

readsThePromptFromStandardInputTest :: TestTree
readsThePromptFromStandardInputTest =
  testCase "the standard-input reader decodes UTF-8 explicitly" $
    -- The fixture above uses a file, because standard input cannot be
    -- piped in-process; this is the narrow test of the transport the
    -- motivating script actually uses. The real handle is duplicated
    -- and restored so no other test is affected.
    withWorkspace $ \dir -> do
      path <- writeDocument dir "prompt.txt" fixturePrompt
      saved <- hDuplicate stdin
      source <- openFile path ReadMode
      hDuplicateTo source stdin
      hClose source
      outcome <- readPromptSource PromptStdin
      hDuplicateTo saved stdin
      hClose saved
      outcome @?= Right fixturePrompt

readsThePromptFromAFileTest :: TestTree
readsThePromptFromAFileTest =
  testCase "a prompt file is read byte for byte" $
    withWorkspace $ \dir -> do
      path <- writeDocument dir "prompt.txt" fixturePrompt
      outcome <- readPromptSource (PromptFile path)
      outcome @?= Right fixturePrompt

rejectsAMissingPromptFileTest :: TestTree
rejectsAMissingPromptFileTest =
  testCase "a missing prompt file is named rather than read as empty" $
    withWorkspace $ \dir -> do
      outcome <- readPromptSource (PromptFile (dir </> "absent.txt"))
      case outcome of
        Right value -> assertFailure ("expected a failure, got: " <> show value)
        Left message ->
          assertBool
            ("the path is named: " <> Text.unpack message)
            (Text.pack (dir </> "absent.txt") `Text.isInfixOf` message)

-- --------------------------------------------------------------------
-- The parser
-- --------------------------------------------------------------------

parse :: [String] -> Options.ParserResult AgentCliOptions
parse = Options.execParserPure Options.defaultPrefs agentCliParserInfo

twoPromptSourcesAreAUsageErrorTest :: TestTree
twoPromptSourcesAreAUsageErrorTest =
  testCase "supplying two prompt sources is a usage error" $
    case parse ["agent", "run", "demo", "--prompt-stdin", "--prompt", "also this"] of
      Options.Success _ -> assertFailure "expected two prompt sources to be refused"
      _ -> pure ()

parsesTheMotivatingInvocationTest :: TestTree
parsesTheMotivatingInvocationTest =
  testCase "the motivating invocation parses to a job, a prompt source, and one override" $
    case parse ["agent", "run", "sync-keiro-dsl", "--prompt-stdin", "--set", "extra-dirs=/keiro"] of
      Options.Success parsed -> do
        parsed ^. #command @?= AgentRun "sync-keiro-dsl" PromptStdin
        length (parsed ^. #overrides) @?= 1
      _ -> assertFailure "expected the motivating invocation to parse"
