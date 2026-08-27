-- | The @baikai agent@ command-line surface: @run@, @show@, and
-- @list@.
--
-- This module is where the five earlier pieces of the unattended
-- surface meet. It resolves a named job from layered KDL configuration,
-- caps it against the operator's policy ceiling, dispatches it to the
-- vendor renderer for its provider, and hands the rendered command to
-- the process runner. It is also the only place in the codebase that
-- knows both providers.
--
-- Everything real lives here rather than in @app\/Main.hs@ so the whole
-- surface is reachable from a test without spawning the built binary.
-- 'runAgentCli' returns an 'AgentCliRun' — an exit code and two captured
-- streams — and the executable's only job is to interpret that record.
--
-- __Stream discipline__, because a shell script depends on it. Baikai's
-- own diagnostics always go to standard error. The agent's own output
-- follows the job's configured output mode: under @inherit@ it goes
-- straight to the real streams and never enters 'AgentCliRun' at all,
-- under @capture@ Baikai holds it and returns it, and under @tee@ both
-- happen. That is what makes @response=$(baikai agent run job)@ yield
-- the agent's answer and nothing else for a capturing job, while a human
-- watching still sees diagnostics.
module Baikai.Agent.Cli
  ( -- * The parsed command line
    AgentCliCommand (..),
    PromptSource (..),
    AgentCliOptions
      ( command,
        overrides,
        userConfig,
        repoConfig,
        jsonOutput,
        evidenceFile,
        runId,
        requiredEvidence
      ),
    agentCliOptions,
    agentCliParser,
    agentCliParserInfo,

    -- * Running it
    AgentCliRun (exitCode, standardOutput, standardError),
    agentCliRun,
    runAgentCli,
    runAgentCliWithPaths,

    -- * Provider dispatch
    renderJobCommand,

    -- * Exit codes
    usageExitCode,
    unavailableExitCode,
    timeoutExitCode,
    refusedExitCode,
    configExitCode,

    -- * Exposed for testing
    readPromptSource,
    renderEffectiveConfig,
  )
where

import Baikai.Agent
  ( AgentCapturedOutput (..),
    AgentCeiling,
    AgentCommand,
    AgentOutputMode (..),
    AgentPromptTransport (..),
    AgentProvider (..),
    AgentRenderError (..),
    AgentRunFailure (..),
    AgentRunRequest,
    AgentRunResult,
    CeilingViolation,
    renderAgentCapability,
    renderAgentProvider,
    renderAgentRenderError,
    renderAgentRunFailure,
  )
import Baikai.Agent.Config
  ( AgentConfigPaths (..),
    AgentJob,
    agentJobRequest,
    ceilingViolations,
    defaultAgentConfigPaths,
    emptyAgentConfigPaths,
    listAgentJobs,
    loadAgentCeiling,
    relevantWarnings,
    renderAgentConfigError,
    renderAgentConfigScope,
    repositoryPolicyNotice,
    repositoryScopeViolations,
    resolveAgentJob,
  )
import Baikai.Agent.Run (runAgentCommand)
import Baikai.Evidence
  ( EvidenceRequest (..),
    EvidenceStrength (..),
    EvidenceStrictness (..),
    ModelCallEvidence,
    ThinkingTranslation,
    evidenceRequest,
    parseEvidenceStrength,
  )
import Baikai.Provider.Claude.Agent
  ( ClaudeAgentConfig,
    claudeAgentCommand,
    defaultClaudeAgentConfig,
  )
import Baikai.Provider.OpenAI.Agent
  ( CodexAgentConfig,
    codexAgentCommand,
    defaultCodexAgentConfig,
  )
import Control.Applicative ((<|>))
import Control.Exception (IOException, bracketOnError, displayException, try)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)
import Options.Applicative (Parser, ParserInfo)
import Options.Applicative qualified as Options
import Settei.Env (EnvSnapshot)
import Settei.Key (keySegments, mkKey, parseKey, renderKey)
import Settei.Optparse (CliOverride, cliOverride, cliOverrideKey, cliOverrideValue)
import Settei.Origin (Origin, SourceKind (..), SourceLocation)
import Settei.Provenance (renderReportedValue)
import Settei.Render (renderErrorsText, renderResolutionJson, renderWarningsText)
import Settei.Report
  ( ResolutionOutcome (..),
    ResolutionReport,
    reportNodes,
  )
import Settei.Value (RawValue (..))
import System.Directory
  ( doesFileExist,
    getCurrentDirectory,
    removeFile,
    renameFile,
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( dropTrailingPathSeparator,
    normalise,
    takeDirectory,
    takeFileName,
    (</>),
  )
import System.IO (hClose, openBinaryTempFileWithDefaultPermissions, stdin)

-- | Which of the three commands was asked for.
data AgentCliCommand
  = -- | Run a named job, taking the prompt from the given source.
    AgentRun !Text !PromptSource
  | -- | Explain a named job without starting anything.
    AgentShow !Text
  | -- | Enumerate the configured jobs.
    AgentList
  deriving stock (Eq, Show, Generic)

-- | Where the prompt comes from. The three are mutually exclusive on
-- the command line, so supplying two is a usage error rather than a
-- silent precedence puzzle.
data PromptSource
  = PromptStdin
  | PromptFile !FilePath
  | PromptInline !Text
  deriving stock (Eq, Show, Generic)

-- | The parsed command line, before any file is opened.
--
-- Construction: the constructor is deliberately not exported. Start
-- from 'agentCliOptions' and override fields by record update.
data AgentCliOptions = AgentCliOptions
  { command :: !AgentCliCommand,
    -- | Parsed @--set@ overrides, __with keys as the operator wrote
    -- them__. A key that does not already begin with the @jobs@ segment
    -- is job-relative and is rewritten to @jobs.\<job\>.\<key\>@ before
    -- resolution; the job name is not known while parsing, so the
    -- rewrite cannot happen here.
    overrides :: ![CliOverride],
    -- | Explicit operator-scope file, overriding discovery.
    userConfig :: !(Maybe FilePath),
    -- | Explicit repository-scope file, overriding discovery.
    repoConfig :: !(Maybe FilePath),
    jsonOutput :: !Bool,
    -- | Where to write the run's evidence record, from
    -- @--evidence-file@. Only @run@ accepts it; the other two commands
    -- start nothing and so have nothing to record.
    evidenceFile :: !(Maybe FilePath),
    -- | The caller's identifier for the logical run this invocation
    -- belongs to, from @--run-id@.
    runId :: !(Maybe Text),
    -- | The evidence strength this run must reach, from
    -- @--require-evidence@. Setting it turns recording on and makes the
    -- run refuse rather than start when the configuration cannot
    -- produce it.
    requiredEvidence :: !(Maybe EvidenceStrength)
  }
  deriving stock (Generic)

-- | One capturable run of the command-line surface.
--
-- 'standardOutput' and 'standardError' are __Baikai's__ output. Under
-- the @inherit@ and @tee@ output modes the agent's own output goes
-- straight to the real process streams and bypasses this record
-- entirely, which is correct and is what the motivating consumer wants.
--
-- Construction: the constructor is deliberately not exported. Start
-- from 'agentCliRun' and override fields by record update.
data AgentCliRun = AgentCliRun
  { exitCode :: !Int,
    standardOutput :: !Text,
    standardError :: !Text
  }
  deriving stock (Eq, Show, Generic)

usageExitCode,
  unavailableExitCode,
  timeoutExitCode,
  refusedExitCode,
  configExitCode ::
    Int

-- | The command line could not be parsed, or the prompt was empty.
--
-- Baikai's own failures start at 64 and follow the @sysexits@
-- convention, because the coding agent's own exit code passes through
-- unchanged and the two must stay separable. Coding agents
-- conventionally exit 0 or 1, so in practice they do; the residual
-- ambiguity when a provider exits 64 or above is documented rather than
-- hidden, and @--json@ carries the unambiguous answer.
usageExitCode = 64

-- | The coding-agent executable could not be started.
unavailableExitCode = 69

-- | The run exceeded its timeout and its process group was terminated.
timeoutExitCode = 75

-- | Policy refused the run: the ceiling was exceeded, or the provider
-- cannot express the requested policy. Nothing was started.
refusedExitCode = 77

-- | Configuration was missing, unreadable, or invalid.
configExitCode = 78

-- --------------------------------------------------------------------
-- Parsing
-- --------------------------------------------------------------------

-- | Complete parser metadata, including the usage-error exit code.
--
-- Without 'Options.failureCode' a mistyped flag would exit 1, which is
-- indistinguishable from a coding agent that ran and exited 1.
agentCliParserInfo :: ParserInfo AgentCliOptions
agentCliParserInfo =
  Options.info
    (agentCliParser Options.<**> Options.helper)
    ( Options.fullDesc
        <> Options.progDesc "Run unattended coding-agent jobs from configuration"
        <> Options.header "baikai - unattended coding-agent runs"
        <> Options.failureCode usageExitCode
    )

-- | The command line for one command, with every other option at the
-- value the parser produces when the flag is absent.
agentCliOptions :: AgentCliCommand -> AgentCliOptions
agentCliOptions cliCommand =
  AgentCliOptions
    { command = cliCommand,
      overrides = [],
      userConfig = Nothing,
      repoConfig = Nothing,
      jsonOutput = False,
      evidenceFile = Nothing,
      runId = Nothing,
      requiredEvidence = Nothing
    }

-- | A run result carrying an exit code and no output on either stream.
agentCliRun :: Int -> AgentCliRun
agentCliRun code =
  AgentCliRun
    { exitCode = code,
      standardOutput = Text.empty,
      standardError = Text.empty
    }

-- | The top level takes one subcommand group, @agent@, leaving room for
-- future groups without minting a new executable.
agentCliParser :: Parser AgentCliOptions
agentCliParser =
  Options.hsubparser
    ( Options.command
        "agent"
        ( Options.info
            agentGroupParser
            (Options.progDesc "Inspect and run unattended coding-agent jobs")
        )
    )

agentGroupParser :: Parser AgentCliOptions
agentGroupParser =
  Options.hsubparser
    ( Options.command
        "run"
        ( Options.info
            runOptionsParser
            (Options.progDesc "Run a configured job, propagating the agent's exit code")
        )
        <> Options.command
          "show"
          ( Options.info
              showOptionsParser
              (Options.progDesc "Print a job's effective configuration and rendered command")
          )
        <> Options.command
          "list"
          ( Options.info
              listOptionsParser
              (Options.progDesc "List the configured jobs and the scope each came from")
          )
    )

runOptionsParser :: Parser AgentCliOptions
runOptionsParser =
  assemble
    <$> jobArgument
    <*> promptSourceParser
    <*> Options.many overrideOption
    <*> Options.optional userConfigOption
    <*> Options.optional repoConfigOption
    <*> jsonSwitch
    <*> Options.optional evidenceFileOption
    <*> Options.optional runIdOption
    <*> Options.optional requireEvidenceOption
  where
    assemble
      jobName
      promptSource
      overrides
      userConfig
      repoConfig
      jsonOutput
      evidenceFile
      runId
      requiredEvidence =
        AgentCliOptions
          { command = AgentRun jobName promptSource,
            overrides,
            userConfig,
            repoConfig,
            jsonOutput,
            evidenceFile,
            runId,
            requiredEvidence
          }

showOptionsParser :: Parser AgentCliOptions
showOptionsParser =
  assemble
    <$> jobArgument
    <*> Options.many overrideOption
    <*> Options.optional userConfigOption
    <*> Options.optional repoConfigOption
    <*> jsonSwitch
  where
    assemble jobName overrides userConfig repoConfig jsonOutput =
      AgentCliOptions
        { command = AgentShow jobName,
          overrides,
          userConfig,
          repoConfig,
          jsonOutput,
          evidenceFile = Nothing,
          runId = Nothing,
          requiredEvidence = Nothing
        }

listOptionsParser :: Parser AgentCliOptions
listOptionsParser =
  assemble
    <$> Options.optional userConfigOption
    <*> Options.optional repoConfigOption
    <*> jsonSwitch
  where
    assemble userConfig repoConfig jsonOutput =
      AgentCliOptions
        { command = AgentList,
          overrides = [],
          userConfig,
          repoConfig,
          jsonOutput,
          evidenceFile = Nothing,
          runId = Nothing,
          requiredEvidence = Nothing
        }

jobArgument :: Parser Text
jobArgument =
  Options.strArgument
    (Options.metavar "JOB" <> Options.help "Name of the configured job")

-- | The three prompt sources are alternatives, so supplying two is a
-- usage error. @run@ requires one: an unattended agent with no
-- instruction is not a meaningful run.
promptSourceParser :: Parser PromptSource
promptSourceParser =
  Options.flag'
    PromptStdin
    ( Options.long "prompt-stdin"
        <> Options.help "Read the prompt from standard input"
    )
    <|> ( PromptFile
            <$> Options.strOption
              ( Options.long "prompt-file"
                  <> Options.metavar "PATH"
                  <> Options.help "Read the prompt from PATH"
              )
        )
    <|> ( PromptInline
            <$> Options.strOption
              ( Options.long "prompt"
                  <> Options.metavar "TEXT"
                  <> Options.help "Use TEXT as the prompt"
              )
        )

overrideOption :: Parser CliOverride
overrideOption =
  Options.option
    overrideReader
    ( Options.long "set"
        <> Options.metavar "KEY=VALUE"
        <> Options.help
          "Override one setting of the selected job; KEY is relative to the job \
          \unless it already starts with jobs."
    )

-- | Parse @KEY=VALUE@ into a @settei@ override, keeping the key exactly
-- as written.
--
-- This duplicates the shape of @settei@'s own @overrideOptions@ rather
-- than calling it, because the key here is normally job-relative and the
-- job name is not available while parsing. The value still becomes a
-- 'CliOverride' through @settei@'s own constructor, so it stays inside
-- the same provenance machinery as every other layer and its spelling
-- never carries the value.
overrideReader :: Options.ReadM CliOverride
overrideReader = Options.eitherReader $ \input ->
  let rendered = Text.pack input
      (keyText, assignment) = Text.breakOn "=" rendered
   in if Text.null assignment
        then Left "expected KEY=VALUE"
        else case parseKey keyText of
          Left problem -> Left ("invalid configuration key: " <> show problem)
          Right key -> Right (cliOverride key (Text.drop 1 assignment))

userConfigOption :: Parser FilePath
userConfigOption =
  Options.strOption
    ( Options.long "user-config"
        <> Options.metavar "PATH"
        <> Options.help "Read operator-scope configuration from PATH"
    )

repoConfigOption :: Parser FilePath
repoConfigOption =
  Options.strOption
    ( Options.long "config"
        <> Options.metavar "PATH"
        <> Options.help "Read repository-scope configuration from PATH"
    )

jsonSwitch :: Parser Bool
jsonSwitch =
  Options.switch
    (Options.long "json" <> Options.help "Emit machine-readable JSON")

evidenceFileOption :: Parser FilePath
evidenceFileOption =
  Options.strOption
    ( Options.long "evidence-file"
        <> Options.metavar "PATH"
        <> Options.help "Write the run's evidence record to PATH as one JSON object"
    )

runIdOption :: Parser Text
runIdOption =
  Options.strOption
    ( Options.long "run-id"
        <> Options.metavar "TEXT"
        <> Options.help "Identifier for the logical run this invocation belongs to"
    )

-- | @--require-evidence@ takes a strength name and refuses the run when
-- the configuration cannot reach it.
--
-- The names are the ones an evidence record spells, so an operator reads
-- a record's @strength@ and passes that word back verbatim.
requireEvidenceOption :: Parser EvidenceStrength
requireEvidenceOption =
  Options.option
    (Options.eitherReader parse)
    ( Options.long "require-evidence"
        <> Options.metavar "STRENGTH"
        <> Options.help
          "Refuse to start unless the run can produce evidence of at least this \
          \strength: requested_only, correlated, model_observed, or fully_observed"
    )
  where
    -- The strength table lives beside its renderer, in
    -- 'Baikai.Evidence.parseEvidenceStrength', so this parser cannot
    -- fall behind the names an evidence record spells.
    parse other =
      maybe
        ( Left
            ( "unknown evidence strength: "
                <> other
                <> " (expected requested_only, correlated, model_observed, or fully_observed)"
            )
        )
        Right
        (parseEvidenceStrength (Text.pack other))

-- --------------------------------------------------------------------
-- Provider dispatch
-- --------------------------------------------------------------------

-- | Turn a resolved job into a rendered command, or refuse.
--
-- __This is the only place in the codebase that knows both
-- providers.__ It is the answer to the improvement request's first
-- acceptance criterion — that a script select Claude Code or Codex
-- entirely through configuration — and if provider knowledge spreads to
-- a second site, adding a third provider later becomes a hunt.
--
-- Both the job and the request are taken even though the request was
-- built from the job. The renderers consume the request; the job carries
-- the executable override, for which 'AgentRunRequest' has no field
-- because it is a configuration concern rather than a run description.
-- The redundancy looks like an accident and is not.
--
-- The translation half of the pair says what the request's reasoning
-- effort became on that provider's command line. It is threaded through
-- rather than discarded here, because the runner cannot derive it: it
-- deliberately imports no vendor renderer.
renderJobCommand ::
  AgentJob ->
  AgentRunRequest ->
  Either AgentRenderError (AgentCommand, ThinkingTranslation)
renderJobCommand job request = case request ^. #provider of
  AgentClaude -> claudeAgentCommand (claudeConfigFor job) request
  AgentCodex -> codexAgentCommand (codexConfigFor job) request

claudeConfigFor :: AgentJob -> ClaudeAgentConfig
claudeConfigFor job =
  maybe
    defaultClaudeAgentConfig
    (\exe -> defaultClaudeAgentConfig & #executable .~ exe)
    (job ^. #executable)

codexConfigFor :: AgentJob -> CodexAgentConfig
codexConfigFor job =
  maybe
    defaultCodexAgentConfig
    (\exe -> defaultCodexAgentConfig & #executable .~ exe)
    (job ^. #executable)

-- --------------------------------------------------------------------
-- Running
-- --------------------------------------------------------------------

-- | Run the command line against the real configuration file
-- locations, with any explicit path overriding the discovered one.
runAgentCli :: EnvSnapshot -> AgentCliOptions -> IO AgentCliRun
runAgentCli snapshot options = do
  paths <- effectiveConfigPaths options
  runAgentCliWithPaths paths snapshot options

-- | Run the command line against explicitly supplied configuration
-- paths.
--
-- Tests use this rather than 'runAgentCli': a developer with a real
-- @~\/.config\/baikai\/agents.kdl@ would otherwise get different results
-- from a clean machine, and the failure would be baffling.
runAgentCliWithPaths ::
  AgentConfigPaths -> EnvSnapshot -> AgentCliOptions -> IO AgentCliRun
runAgentCliWithPaths paths snapshot options = case options ^. #command of
  AgentList -> listCommand paths options
  AgentShow jobName -> showCommand paths snapshot options jobName
  AgentRun jobName promptSource ->
    runCommand paths snapshot options jobName promptSource

-- | Discovery, with explicit paths winning per scope. When both scopes
-- are explicit nothing is discovered at all, so a fully specified
-- invocation never reads @HOME@ or @XDG_CONFIG_HOME@.
-- The repository root is always the process's own directory. @--config@
-- chooses which file supplies repository-scope settings; it does not
-- move the repository, because the root is what confines a
-- repository-supplied working directory.
effectiveConfigPaths :: AgentCliOptions -> IO AgentConfigPaths
effectiveConfigPaths options = do
  root <- getCurrentDirectory
  case (options ^. #userConfig, options ^. #repoConfig) of
    (Just user, Just repo) ->
      pure
        emptyAgentConfigPaths
          { userConfig = Just user,
            repoConfig = Just repo,
            repositoryRoot = root
          }
    (user, repo) -> do
      discovered <- defaultAgentConfigPaths
      pure
        emptyAgentConfigPaths
          { userConfig = user <|> discovered ^. #userConfig,
            repoConfig = repo <|> discovered ^. #repoConfig,
            repositoryRoot = root
          }

successfulRun :: Text -> Text -> AgentCliRun
successfulRun out err =
  AgentCliRun {exitCode = 0, standardOutput = out, standardError = err}

failedRun :: Int -> Text -> AgentCliRun
failedRun code message =
  AgentCliRun {exitCode = code, standardOutput = "", standardError = message}

-- --------------------------------------------------------------------
-- agent list
-- --------------------------------------------------------------------

listCommand :: AgentConfigPaths -> AgentCliOptions -> IO AgentCliRun
listCommand paths options = do
  listed <- listAgentJobs paths
  pure $ case listed of
    Left problem -> failedRun configExitCode (renderAgentConfigError problem <> "\n")
    Right entries
      | options ^. #jsonOutput ->
          successfulRun (encodeEnvelope (Aeson.toJSON (map entryJson entries))) ""
      -- An empty list is a normal state, not an error, and the note
      -- saying so goes to standard error so that a script piping the
      -- list never has to filter prose out of its data.
      | null entries -> successfulRun "" "no jobs are configured\n"
      | otherwise ->
          successfulRun
            (Text.unlines (map (entryLine (nameWidth entries)) entries))
            ""
  where
    nameWidth entries = maximum (0 : map (Text.length . (^. #name)) entries)
    entryLine width entry =
      Text.justifyLeft (width + 2) ' ' (entry ^. #name)
        <> renderAgentConfigScope (entry ^. #scope)
        <> ( if entry ^. #definingScopes > 1
               then " (also defined in another scope)"
               else ""
           )
    entryJson entry =
      Aeson.object
        [ "name" Aeson..= (entry ^. #name),
          "scope" Aeson..= renderAgentConfigScope (entry ^. #scope),
          "definingScopes" Aeson..= (entry ^. #definingScopes)
        ]

-- --------------------------------------------------------------------
-- Shared resolution
-- --------------------------------------------------------------------

-- | Everything both @show@ and @run@ need before they diverge.
data StagedJob = StagedJob
  { job :: !AgentJob,
    report :: !ResolutionReport,
    warnings :: !Text,
    ceiling :: !AgentCeiling,
    ceilingSource :: !Text,
    -- | Violations that depend on which file supplied a value, which
    -- the pure ceiling check cannot see. They are computed once here and
    -- concatenated with it, so an operator sees one refusal.
    scopeViolations :: ![CeilingViolation]
  }
  deriving stock (Generic)

-- | A stage that ended before a job was ready.
data StageFailure = StageFailure
  { exitCode :: !Int,
    message :: !Text,
    -- | A failed resolution still carries a report, and for an explain
    -- command that provenance is exactly what the operator needs.
    report :: !(Maybe ResolutionReport),
    warnings :: !Text
  }
  deriving stock (Generic)

stageJob ::
  AgentConfigPaths ->
  EnvSnapshot ->
  AgentCliOptions ->
  Text ->
  IO (Either StageFailure StagedJob)
stageJob paths snapshot options jobName = do
  loaded <- resolveAgentJob paths snapshot (map (scopeOverride jobName) (options ^. #overrides)) jobName
  case loaded of
    Left problem -> pure (Left (configFailure (renderAgentConfigError problem)))
    Right resolved -> do
      -- Not every warning settei raises is about this run. The
      -- declaration describes one job, so every key of every *other*
      -- job warns, and so does the operator file's policy node; neither
      -- is a mistake and neither is the operator's to fix. A repository
      -- policy node is different: it does nothing, and whoever wrote it
      -- believed it would, so it earns one notice.
      let warningsText =
            renderWarningsText (relevantWarnings jobName (resolved ^. #warnings))
              <> fromMaybe "" (repositoryPolicyNotice (resolved ^. #warnings))
      case resolved ^. #answer of
        Left problems ->
          pure
            ( Left
                StageFailure
                  { exitCode = configExitCode,
                    message = renderErrorsText problems,
                    report = Just (resolved ^. #report),
                    warnings = warningsText
                  }
            )
        Right job -> do
          -- The ceiling is a separate load with a deliberately different
          -- source list, and this command must not introduce a second
          -- path to it. It calls loadAgentCeiling and adds no override
          -- of its own.
          loadedCeiling <- loadAgentCeiling paths
          let loadedOrFailed = case loadedCeiling of
                Left problem ->
                  Left
                    StageFailure
                      { exitCode = configExitCode,
                        message = renderAgentConfigError problem,
                        report = Nothing,
                        warnings = warningsText
                      }
                Right ceiling' -> Right ceiling'
          case loadedOrFailed of
            Left failure -> pure (Left failure)
            Right ceiling' -> do
              -- Provenance first, against the job as configured: the
              -- scope check composes the root itself and must see the
              -- spelling the document used.
              scopeViolations <-
                repositoryScopeViolations paths (resolved ^. #report) jobName job
              pure
                ( Right
                    StagedJob
                      { job = rootedJob paths job,
                        report = resolved ^. #report,
                        warnings = warningsText,
                        ceiling = ceiling',
                        ceilingSource = ceilingSourceLabel paths,
                        scopeViolations
                      }
                )
  where
    configFailure text =
      StageFailure
        { exitCode = configExitCode,
          message = text,
          report = Nothing,
          warnings = ""
        }

-- | Resolve the job's working directory against the repository root.
--
-- A relative @working-dir@ has to resolve against /something/, and the
-- process's own directory is the wrong answer for a value that may have
-- come from either file: two documents defining one job would make
-- @\".\"@ mean two places depending on which layer won. The repository
-- root is the same directory whichever file declared it, so
-- @working-dir \".\"@ means \"this checkout\" everywhere.
--
-- An absolute path passes through @\<\/\>@ unchanged, so a job naming
-- one is untouched. The result is normalised and stripped of a trailing
-- separator, so @\".\"@ yields the root itself rather than
-- @\<root\>\/.@ — this path is rendered into @codex exec --cd@, printed
-- by @agent show@, and recorded as an evidence endpoint, and all three
-- should read as the directory a person would name.
rootedJob :: AgentConfigPaths -> AgentJob -> AgentJob
rootedJob paths job =
  job
    & #workingDir
      .~ dropTrailingPathSeparator
        (normalise ((paths ^. #repositoryRoot) </> (job ^. #workingDir)))

ceilingSourceLabel :: AgentConfigPaths -> Text
ceilingSourceLabel paths = case paths ^. #userConfig of
  Nothing -> "built-in default (no operator configuration file)"
  Just path -> Text.pack path

-- | Rewrite a job-relative override key to its absolute form.
--
-- A key already beginning with @jobs@ is absolute and passes through
-- untouched, which keeps @--set jobs.demo.provider=codex@ meaning what
-- it says. Everything else names a setting of the selected job, so
-- @--set output=capture@ addresses @jobs.\<job\>.output@. The rewrite
-- cannot happen while parsing, because the job name is parsed by the
-- same applicative.
-- The last guard is unreachable by construction — 'cliOverride' always
-- builds a 'RawText', and 'RawValue' has no 'Show' instance precisely so
-- that a possibly-secret value cannot be rendered — so a shape this
-- function cannot rewrite is passed through unchanged rather than
-- reported with its value inlined.
scopeOverride :: Text -> CliOverride -> CliOverride
scopeOverride jobName original
  | firstSegment == "jobs" = original
  | RawText value <- cliOverrideValue original,
    Right scoped <- mkKey ("jobs" NonEmpty.:| (jobName : segments)) =
      cliOverride scoped value
  | otherwise = original
  where
    segments = NonEmpty.toList (keySegments (cliOverrideKey original))
    firstSegment = NonEmpty.head (keySegments (cliOverrideKey original))

-- --------------------------------------------------------------------
-- agent show
-- --------------------------------------------------------------------

showCommand ::
  AgentConfigPaths -> EnvSnapshot -> AgentCliOptions -> Text -> IO AgentCliRun
showCommand paths snapshot options jobName = do
  staged <- stageJob paths snapshot options jobName
  pure $ case staged of
    Left failure
      | options ^. #jsonOutput ->
          AgentCliRun
            { exitCode = failure ^. #exitCode,
              standardOutput =
                encodeEnvelope
                  ( showJson
                      jobName
                      "failed"
                      (failure ^. #exitCode)
                      (Just (failure ^. #message))
                      (failure ^. #report)
                      Nothing
                      Nothing
                  ),
              standardError = failure ^. #warnings
            }
      | otherwise ->
          AgentCliRun
            { exitCode = failure ^. #exitCode,
              -- A failed resolution's provenance is exactly what an
              -- explain command is for, so the report is printed when
              -- there is one.
              standardOutput = maybe "" renderEffectiveConfig (failure ^. #report),
              standardError = failure ^. #warnings <> failure ^. #message <> "\n"
            }
    Right stagedJob -> explain options jobName stagedJob

-- | Print the effective configuration, the ceiling, and the command
-- that would be spawned — or the refusal, after the configuration, so
-- the operator sees both what was asked for and why it was refused.
explain :: AgentCliOptions -> Text -> StagedJob -> AgentCliRun
explain options jobName staged =
  case rendered of
    Left refusal
      | options ^. #jsonOutput ->
          AgentCliRun
            { exitCode = refusedExitCode,
              standardOutput =
                encodeEnvelope
                  ( showJson
                      jobName
                      "refused"
                      refusedExitCode
                      (Just (renderAgentRenderError refusal))
                      (Just (staged ^. #report))
                      (Just (staged ^. #ceilingSource, staged ^. #ceiling))
                      Nothing
                  ),
              standardError = staged ^. #warnings
            }
      | otherwise ->
          AgentCliRun
            { exitCode = refusedExitCode,
              standardOutput = textSections,
              standardError =
                staged ^. #warnings <> "refused: " <> renderAgentRenderError refusal <> "\n"
            }
    Right command
      | options ^. #jsonOutput ->
          successfulRun
            ( encodeEnvelope
                ( showJson
                    jobName
                    "shown"
                    0
                    Nothing
                    (Just (staged ^. #report))
                    (Just (staged ^. #ceilingSource, staged ^. #ceiling))
                    (Just command)
                )
            )
            (staged ^. #warnings)
      | otherwise ->
          successfulRun
            (textSections <> "\n" <> renderCommandSection command)
            (staged ^. #warnings)
  where
    -- `show` takes no prompt, so a clearly artificial placeholder stands
    -- in for it and is labelled as such wherever it could be mistaken
    -- for a configured value.
    placeholder = "<prompt supplied at run time>"
    request = agentJobRequest (staged ^. #job) placeholder
    -- The argument vector is printed, so it must not carry the one
    -- setting that can hold a credential. The ceiling is checked against
    -- the real request; only the request the display is rendered from
    -- has its raw provider arguments replaced, so each one still shows
    -- in its true position without showing its value.
    displayRequest =
      request
        & #safety
          . #providerArgs
          .~ ["<redacted>" | _ <- staged ^. #job . #providerArgs]
    rendered = do
      ceilingGuard staged request
      fst <$> renderJobCommand (staged ^. #job) displayRequest
    textSections =
      "job \""
        <> jobName
        <> "\"\n\neffective configuration\n"
        <> renderEffectiveConfig (staged ^. #report)
        <> "\npolicy ceiling, from "
        <> staged ^. #ceilingSource
        <> "\n"
        <> renderCeiling (staged ^. #ceiling)

-- | Render every resolved value with the file, line, and column it came
-- from.
--
-- @settei@'s own @renderResolutionText@ names a value's source but drops
-- its location; only the JSON rendering carries path, line, and column.
-- Improvement-request acceptance criterion 5 requires the position, so
-- this walks the report itself rather than delegating.
renderEffectiveConfig :: ResolutionReport -> Text
renderEffectiveConfig report =
  Text.concat (map renderNode (reportNodes report))
  where
    renderNode node = case node ^. #outcome of
      NotSelected -> ""
      MissingValue ->
        "  " <> renderKey (node ^. #key) <> " = (unset)\n"
      Resolved value ->
        "  "
          <> renderKey (node ^. #key)
          <> " = "
          <> renderReportedValue value
          <> "\n"
          <> renderSource node
    renderSource node =
      case (node ^. #origin, node ^. #derivation) of
        (Just origin, _) -> "      from " <> renderOrigin origin <> "\n"
        (Nothing, Just derivation) ->
          "      from default rule "
            <> derivation ^. #rule
            <> " ("
            <> derivation ^. #explanation
            <> ")\n"
        (Nothing, Nothing) -> ""

-- | A value produced by a named default rule carries a 'DerivedSource'
-- origin whose name is the rule, which reads as a bare word without the
-- prefix — @no-provider-args@ rather than
-- @default rule no-provider-args@.
renderOrigin :: Origin -> Text
renderOrigin origin =
  prefix
    <> origin ^. #name
    <> maybe "" ((" at " <>) . renderLocation) (origin ^. #location)
  where
    prefix = case origin ^. #kind of
      DerivedSource -> "default rule "
      _ -> ""

renderLocation :: SourceLocation -> Text
renderLocation location =
  location
    ^. #path
    <> maybe "" (\line -> ":" <> Text.pack (show line)) (location ^. #line)
    <> maybe "" (\column -> ":" <> Text.pack (show column)) (location ^. #column)

-- | Every way this job exceeds the operator's policy, as one refusal.
--
-- Two lists are concatenated because they answer different questions.
-- 'ceilingViolations' compares the request against the ceiling and knows
-- nothing about files; 'repositoryScopeViolations', already computed
-- while staging, says which values the untrusted repository file was not
-- allowed to supply at all. Reporting them together means an operator
-- fixing a job description sees every problem in one run, which is the
-- same property 'Baikai.Agent.applyAgentCeiling' has on its own.
--
-- The request is never clamped to fit: a job that asked for more than it
-- may have is an error to report, not a request to quietly weaken.
ceilingGuard :: StagedJob -> AgentRunRequest -> Either AgentRenderError ()
ceilingGuard staged request =
  case (staged ^. #scopeViolations) <> ceilingViolations (staged ^. #ceiling) request of
    [] -> Right ()
    violations -> Left (CeilingRejected violations)

renderCeiling :: AgentCeiling -> Text
renderCeiling ceiling' =
  Text.unlines
    [ "  max-capability       " <> renderAgentCapability (ceiling' ^. #maxCapability),
      "  allow-provider-args  " <> renderBool (ceiling' ^. #allowProviderArgs),
      "  allowed-providers    " <> renderProviders (ceiling' ^. #allowedProviders),
      "  allowed-tools        " <> renderGrants (ceiling' ^. #allowedTools),
      "  max-timeout          " <> renderUnlimited showText (ceiling' ^. #maxTimeout),
      "  max-output-limit     " <> renderUnlimited showText (ceiling' ^. #maxOutputLimit)
    ]
  where
    renderBool True = "true"
    renderBool False = "false"
    renderProviders [] = "none"
    renderProviders providers =
      Text.intercalate ", " (map renderAgentProvider providers)
    -- An empty grant list is not "none at all": the capability still
    -- implies its own grants, and saying so stops an operator reading
    -- this line as "no tools".
    renderGrants [] = "(none beyond the capability)"
    renderGrants grants = Text.intercalate ", " grants
    renderUnlimited render = maybe "unlimited" render
    showText :: (Show a) => a -> Text
    showText = Text.pack . show

-- | The rendered command, one flag per line.
--
-- A flag and the value that follows it are shown together purely as a
-- display convenience; the argument vector itself is the flat list.
renderCommandSection :: AgentCommand -> Text
renderCommandSection command =
  "rendered command\n"
    <> "  "
    <> Text.pack (command ^. #executable)
    <> "\n"
    <> Text.concat ["    " <> Text.pack line <> "\n" | line <- groupArguments (command ^. #arguments)]
    <> "  prompt transport: "
    <> renderTransport (command ^. #promptTransport)
    <> "\n"

renderTransport :: AgentPromptTransport -> Text
renderTransport PromptOnStdin =
  "standard input (the prompt appears nowhere in the argument vector)"
renderTransport PromptAsArgument =
  "the final argument (the child gets no standard input)"

groupArguments :: [String] -> [String]
groupArguments [] = []
groupArguments [single] = [single]
groupArguments (flag : value : rest)
  | isFlag flag && not (isFlag value) = (flag <> " " <> value) : groupArguments rest
  | otherwise = flag : groupArguments (value : rest)
  where
    isFlag ('-' : _) = True
    isFlag _ = False

-- --------------------------------------------------------------------
-- agent run
-- --------------------------------------------------------------------

runCommand ::
  AgentConfigPaths ->
  EnvSnapshot ->
  AgentCliOptions ->
  Text ->
  PromptSource ->
  IO AgentCliRun
runCommand _paths _snapshot options _jobName _promptSource
  | evidenceWithoutADestination options =
      pure
        ( failedRun
            usageExitCode
            "--run-id and --require-evidence produce an evidence record, which \
            \needs a destination: add --evidence-file PATH or --json\n"
        )
runCommand paths snapshot options jobName promptSource = do
  staged <- stageJob paths snapshot options jobName
  case staged of
    Left failure ->
      pure
        ( failedRun
            (failure ^. #exitCode)
            (failure ^. #warnings <> failure ^. #message <> "\n")
        )
    Right stagedJob -> do
      promptRead <- readPromptSource promptSource
      case promptRead of
        Left problem -> pure (failedRun usageExitCode (problem <> "\n"))
        Right promptBody
          | Text.null promptBody ->
              pure
                ( failedRun
                    usageExitCode
                    ( "the prompt read from "
                        <> promptSourceLabel promptSource
                        <> " is empty; an unattended agent given no instruction \
                           \does something unpredictable and expensive\n"
                    )
                )
          | otherwise -> execute options stagedJob promptBody

execute :: AgentCliOptions -> StagedJob -> Text -> IO AgentCliRun
execute options staged promptBody =
  case prepared of
    Left refusal -> pure (refusedRun (renderAgentRenderError refusal))
    Right (request, command, translation) -> do
      ran <- runAgentCommand (evidenceRequestFor options) translation request command
      written <- writeEvidenceFile (options ^. #evidenceFile) (ran ^. #evidence)
      pure (interpret options staged request (ran ^. #outcome) (ran ^. #evidence) written)
  where
    request0 = agentJobRequest (staged ^. #job) promptBody
    prepared = do
      ceilingGuard staged request0
      (command, translation) <- renderJobCommand (staged ^. #job) request0
      pure (request0, command, translation)
    refusedRun message
      | options ^. #jsonOutput =
          AgentCliRun
            { exitCode = refusedExitCode,
              standardOutput =
                encodeEnvelope
                  ( Aeson.object
                      [ "outcome" Aeson..= ("refused" :: Text),
                        "exitCode" Aeson..= refusedExitCode,
                        "message" Aeson..= message
                      ]
                  ),
              standardError = staged ^. #warnings
            }
      | otherwise =
          failedRun refusedExitCode (staged ^. #warnings <> "refused: " <> message <> "\n")

interpret ::
  AgentCliOptions ->
  StagedJob ->
  AgentRunRequest ->
  Either AgentRunFailure AgentRunResult ->
  -- | The run's evidence record, when one was built. Under @--json@ it
  -- travels in the envelope, which is the destination a caller who
  -- named no file asked for.
  Maybe ModelCallEvidence ->
  -- | Whatever went wrong writing the evidence file, appended to
  -- standard error. A failed write never changes the exit code: the
  -- agent's own status is what a calling script branches on, and
  -- silently turning a successful run into a failure because a log could
  -- not be written would be the worse surprise.
  Text ->
  AgentCliRun
interpret options staged request result record evidenceNote = case result of
  -- A timed-out run is still a run: the tool started, printed, and may
  -- have changed the working tree. Its drained output is reported with
  -- exactly the stream discipline a finished run gets, so
  -- `response=$(baikai agent run job)` under `capture` receives the
  -- partial answer with $? set to the timeout code. Under `tee` the
  -- bytes were echoed while draining and are not repeated; under
  -- `inherit` there is nothing to report.
  Left failure@(RunTimedOut timedOut)
    | options ^. #jsonOutput ->
        AgentCliRun
          { exitCode = failureExitCode failure,
            standardOutput =
              encodeEnvelope
                ( Aeson.object
                    ( [ "outcome" Aeson..= ("failed" :: Text),
                        "exitCode" Aeson..= failureExitCode failure,
                        "message" Aeson..= renderAgentRunFailure failure
                      ]
                        <> streamFields "stdout" (timedOut ^. #stdout)
                        <> streamFields "stderr" (timedOut ^. #stderr)
                        <> evidenceField record
                    )
                ),
            standardError = staged ^. #warnings <> evidenceNote
          }
    | otherwise ->
        AgentCliRun
          { exitCode = failureExitCode failure,
            standardOutput = if capturing then decoded (timedOut ^. #stdout) else "",
            standardError =
              staged ^. #warnings
                <> evidenceNote
                <> (if capturing then decoded (timedOut ^. #stderr) else "")
                <> renderAgentRunFailure failure
                <> "\n"
          }
  Left failure
    | options ^. #jsonOutput ->
        AgentCliRun
          { exitCode = failureExitCode failure,
            standardOutput =
              encodeEnvelope
                ( Aeson.object
                    ( [ "outcome" Aeson..= ("failed" :: Text),
                        "exitCode" Aeson..= failureExitCode failure,
                        "message" Aeson..= renderAgentRunFailure failure
                      ]
                        <> evidenceField record
                    )
                ),
            standardError = staged ^. #warnings <> evidenceNote
          }
    | otherwise ->
        failedRun
          (failureExitCode failure)
          (staged ^. #warnings <> evidenceNote <> renderAgentRunFailure failure <> "\n")
  Right ran
    | options ^. #jsonOutput ->
        AgentCliRun
          { exitCode = resultExitCode ran,
            standardOutput = encodeEnvelope (resultJson record ran),
            standardError = staged ^. #warnings <> evidenceNote <> truncationNotes ran
          }
    | otherwise ->
        AgentCliRun
          { exitCode = resultExitCode ran,
            -- Only a captured stream reaches this record. Under `tee`
            -- the runner already echoed the bytes to the real streams
            -- while draining, so re-emitting them here would print
            -- everything twice.
            standardOutput = if capturing then decoded (ran ^. #stdout) else "",
            standardError =
              staged ^. #warnings
                <> evidenceNote
                <> (if capturing then decoded (ran ^. #stderr) else "")
                <> truncationNotes ran
          }
  where
    -- Only a captured stream is Baikai's to re-emit. `tee` already wrote
    -- the bytes to the real streams while draining, and `inherit`
    -- captured nothing at all.
    capturing = request ^. #output == CaptureOutput

-- | Whether the caller asked for a record and named nowhere to put it.
--
-- Building one costs a @--version@ probe of the tool and two digests, so
-- a record that is built and dropped is measurable work proving nothing.
-- There is no sensible default destination either: writing to a guessed
-- path would surprise, and printing it on standard output would corrupt
-- the agent's own answer, which a capturing script is reading.
evidenceWithoutADestination :: AgentCliOptions -> Bool
evidenceWithoutADestination options =
  (isJust (options ^. #runId) || isJust (options ^. #requiredEvidence))
    && isNothing (options ^. #evidenceFile)
    && not (options ^. #jsonOutput)

-- | The caller's evidence request, or 'Nothing' when they asked for
-- none.
--
-- Evidence is built exactly when the operator named a destination for it
-- or an outer run to correlate it with. Anyone who supplies neither gets
-- the behaviour they had before evidence existed, at the cost they had
-- before it existed: no digest, no call identifier, and no @--version@
-- probe of the tool.
--
-- With @--evidence-file@ but no @--run-id@ the job's own name stands in.
-- It is opaque text baikai never parses, and the alternative — an empty
-- string — would be a field a consumer has to special-case.
evidenceRequestFor :: AgentCliOptions -> Maybe EvidenceRequest
evidenceRequestFor options =
  case (options ^. #evidenceFile, options ^. #runId, options ^. #requiredEvidence) of
    (Nothing, Nothing, Nothing) -> Nothing
    (_, _, strictness) ->
      Just
        ( (evidenceRequest (fromMaybe (jobNameOf (options ^. #command)) (options ^. #runId)))
            { strictness = maybe EvidenceBestEffort EvidenceRequired strictness
            }
        )
  where
    jobNameOf = \case
      AgentRun name _ -> name
      AgentShow name -> name
      AgentList -> "agent"

-- | Write one evidence record to the operator's chosen path, returning
-- whatever went wrong.
--
-- The write is atomic — a uniquely named staging file beside the
-- destination, then a rename — so a reader polling the path never sees a
-- half-written record. It never appends: each run writes one complete
-- object, and an operator wanting a log of many runs points each at its
-- own path.
--
-- The staging name is __not__ the destination plus a suffix.
-- @openBinaryTempFileWithDefaultPermissions@ creates the file itself
-- under a fresh name, with @O_EXCL@, so a symbolic link planted at a
-- guessable path is never followed — an unattended run writing its
-- record into whatever a predictable name pointed at is a file overwrite
-- an attacker chooses. The default-permissions variant keeps the mode a
-- plain @writeFile@ would have given rather than the @0600@ the ordinary
-- temp-file function uses, so an operator's umask still decides who can
-- read the record.
--
-- Nothing is written when the operator named no path, and nothing is
-- written when the run produced no evidence, which is the case where the
-- tool never started. An empty file would claim a run happened.
writeEvidenceFile :: Maybe FilePath -> Maybe ModelCallEvidence -> IO Text
writeEvidenceFile Nothing _ = pure ""
writeEvidenceFile (Just _) Nothing = pure ""
writeEvidenceFile (Just path) (Just record) = do
  written <-
    try
      ( bracketOnError
          ( openBinaryTempFileWithDefaultPermissions
              (takeDirectory path)
              (takeFileName path <> ".partial")
          )
          -- Only on failure: a rename that succeeded has taken the name
          -- away, and removing the destination would be the opposite of
          -- what this function is for.
          (\(staging, handle) -> hClose handle >> removeFile staging)
          ( \(staging, handle) -> do
              BSL.hPut handle (Aeson.encode record)
              hClose handle
              renameFile staging path
          )
      ) ::
      IO (Either IOException ())
  pure $ case written of
    Right () -> ""
    Left problem ->
      "could not write the evidence record to "
        <> Text.pack path
        <> ": "
        <> Text.pack (displayException problem)
        <> "\n"

resultExitCode :: AgentRunResult -> Int
resultExitCode result = case result ^. #exitCode of
  ExitSuccess -> 0
  ExitFailure code -> code

failureExitCode :: AgentRunFailure -> Int
failureExitCode = \case
  RunTimedOut _ -> timeoutExitCode
  SpawnFailed _ _ -> unavailableExitCode
  WorkingDirMissing _ -> configExitCode
  MissingEnvironment _ -> configExitCode
  -- Policy said no and nothing was started, which is exactly what
  -- 'refusedExitCode' means for a ceiling violation or a provider that
  -- cannot express a safety policy. A script that already branches on
  -- 77 for those needs no new case for this one.
  EvidenceRefused _ -> refusedExitCode

-- | Announce truncation. A silently truncated response that a script
-- then parses is a bug waiting to happen.
truncationNotes :: AgentRunResult -> Text
truncationNotes result =
  note "standard output" (result ^. #stdout) <> note "standard error" (result ^. #stderr)
  where
    note label (OutputTruncated _) =
      "the agent's " <> label <> " was truncated at the configured output limit\n"
    note _ _ = ""

decoded :: AgentCapturedOutput -> Text
decoded captured = case captured of
  OutputNotCaptured -> ""
  OutputCaptured bytes -> Text.decodeUtf8Lenient bytes
  OutputTruncated bytes -> Text.decodeUtf8Lenient bytes

resultJson :: Maybe ModelCallEvidence -> AgentRunResult -> Aeson.Value
resultJson record result =
  Aeson.object
    ( [ "outcome" Aeson..= ("ran" :: Text),
        "exitCode" Aeson..= resultExitCode result,
        "provider" Aeson..= renderAgentProvider (result ^. #provider),
        "durationSeconds" Aeson..= (realToFrac (result ^. #duration) :: Double)
      ]
        <> streamFields "stdout" (result ^. #stdout)
        <> streamFields "stderr" (result ^. #stderr)
        <> evidenceField record
    )

-- | The run's evidence record as one JSON field, or no field at all.
--
-- Absent rather than @null@ when none was built, for the same reason a
-- stream that was never captured contributes nothing: a reader can tell
-- \"no record was asked for\" from \"a record exists and says nothing\".
-- 'ModelCallEvidence' has its own 'Aeson.ToJSON', which is the same
-- encoder @--evidence-file@ writes, so the two destinations cannot
-- drift.
evidenceField :: Maybe ModelCallEvidence -> [Pair]
evidenceField Nothing = []
evidenceField (Just record) = ["evidence" Aeson..= record]

-- | One captured stream as JSON fields: its text and whether it was cut
-- off at the configured output limit.
--
-- A stream that was never captured contributes nothing rather than an
-- empty string, so a reader can tell \"the agent printed nothing\" from
-- \"the bytes went to the terminal and were never Baikai's to report\".
--
-- Shared by a finished run and by a timed-out one, which carries the
-- same two streams.
streamFields :: Text -> AgentCapturedOutput -> [Pair]
streamFields _ OutputNotCaptured = []
streamFields label captured =
  [ Key.fromText label Aeson..= decoded captured,
    Key.fromText (label <> "Truncated")
      Aeson..= case captured of
        OutputTruncated _ -> True
        _ -> False
  ]

-- --------------------------------------------------------------------
-- Prompts
-- --------------------------------------------------------------------

-- | Read the prompt, decoding UTF-8 explicitly.
--
-- Explicit decoding rather than @getContents@ on purpose: the latter's
-- behavior depends on the handle's locale encoding, and the motivating
-- consumer's prompt contains interpolated paths and could contain any
-- character, so a locale-dependent read would corrupt it on a machine
-- without a UTF-8 locale.
readPromptSource :: PromptSource -> IO (Either Text Text)
readPromptSource = \case
  PromptStdin -> decodeFrom "standard input" <$> BS.hGetContents stdin
  PromptFile path -> do
    present <- doesFileExist path
    if not present
      then pure (Left ("the prompt file does not exist: " <> Text.pack path))
      else decodeFrom (Text.pack path) <$> BS.readFile path
  PromptInline value -> pure (Right value)
  where
    decodeFrom label bytes = case Text.decodeUtf8' bytes of
      Left problem ->
        Left
          ( "the prompt read from "
              <> label
              <> " is not valid UTF-8: "
              <> Text.pack (show problem)
          )
      Right value -> Right value

promptSourceLabel :: PromptSource -> Text
promptSourceLabel PromptStdin = "standard input"
promptSourceLabel (PromptFile path) = Text.pack path
promptSourceLabel (PromptInline _) = "--prompt"

-- --------------------------------------------------------------------
-- JSON
-- --------------------------------------------------------------------

-- | One JSON value as a line of output.
--
-- Every @--json@ path goes through this, so the encoder — and therefore
-- the escaping — is @aeson@'s in every case. The package already
-- depends on it to write evidence records.
encodeEnvelope :: Aeson.Value -> Text
encodeEnvelope value = Text.decodeUtf8Lenient (BSL.toStrict (Aeson.encode value)) <> "\n"

-- | The one shape @agent show --json@ emits, whatever happened.
--
-- A reader should not have to know which of three failure modes it is
-- looking at before it can find the exit code: every field is always
-- present, and the ones that do not apply are @null@. That is why a
-- document that would not even parse still produces an object here,
-- where it used to produce a bare resolution report or nothing at all.
showJson ::
  -- | The job that was asked about.
  Text ->
  -- | @shown@, @refused@, or @failed@.
  Text ->
  -- | The exit code the command is about to return.
  Int ->
  -- | The refusal or the configuration error, when there was one.
  Maybe Text ->
  -- | The resolution report, when resolution got far enough to produce
  -- one. A failed resolution still carries provenance, and for an
  -- explain command that is exactly what the operator needs.
  Maybe ResolutionReport ->
  -- | The ceiling and the file it came from, when one was loaded.
  Maybe (Text, AgentCeiling) ->
  -- | The rendered command, when one was rendered.
  Maybe AgentCommand ->
  Aeson.Value
showJson jobName outcomeWord code message report ceiling' command =
  Aeson.object
    [ "job" Aeson..= jobName,
      "outcome" Aeson..= outcomeWord,
      "exitCode" Aeson..= code,
      "message" Aeson..= message,
      "configuration" Aeson..= fmap reportJson report,
      "ceiling" Aeson..= fmap (uncurry ceilingJson) ceiling',
      "command" Aeson..= fmap commandJson command
    ]

-- | @settei@'s own JSON rendering of a resolution report, as a value
-- rather than as text, so it nests inside the envelope instead of
-- appearing as an escaped string.
--
-- The fallback keeps the text: a report that will not decode is still
-- worth showing, and refusing to emit an envelope over it would lose
-- the exit code too.
reportJson :: ResolutionReport -> Aeson.Value
reportJson report =
  fromMaybe
    (Aeson.String rendered)
    (Aeson.decodeStrict (Text.encodeUtf8 rendered))
  where
    rendered = renderResolutionJson report

ceilingJson :: Text -> AgentCeiling -> Aeson.Value
ceilingJson sourceLabel ceiling' =
  Aeson.object
    [ "source" Aeson..= sourceLabel,
      "maxCapability" Aeson..= renderAgentCapability (ceiling' ^. #maxCapability),
      "allowProviderArgs" Aeson..= (ceiling' ^. #allowProviderArgs),
      "allowedProviders"
        Aeson..= map renderAgentProvider (ceiling' ^. #allowedProviders),
      "allowedTools" Aeson..= (ceiling' ^. #allowedTools),
      -- Null rather than a word, because "unlimited" is the absence of a
      -- bound and a reader branching on null needs no vocabulary.
      "maxTimeout"
        Aeson..= fmap (Text.pack . show) (ceiling' ^. #maxTimeout),
      "maxOutputLimit" Aeson..= (ceiling' ^. #maxOutputLimit)
    ]

commandJson :: AgentCommand -> Aeson.Value
commandJson command =
  Aeson.object
    [ "executable" Aeson..= Text.pack (command ^. #executable),
      "arguments" Aeson..= map Text.pack (command ^. #arguments),
      "promptTransport"
        Aeson..= ( case command ^. #promptTransport of
                     PromptOnStdin -> "stdin" :: Text
                     PromptAsArgument -> "argument"
                 )
    ]
