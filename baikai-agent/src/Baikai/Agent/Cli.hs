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
    AgentCliOptions (..),
    agentCliParser,
    agentCliParserInfo,

    -- * Running it
    AgentCliRun (..),
    runAgentCli,
    runAgentCliWithPaths,

    -- * Provider dispatch
    renderJobCommand,

    -- * Exit codes
    usageExitCode,
    unavailableExitCode,
    internalExitCode,
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
    AgentRenderError,
    AgentRunFailure (..),
    AgentRunRequest,
    AgentRunResult,
    renderAgentCapability,
    renderAgentProvider,
    renderAgentRenderError,
    renderAgentRunFailure,
  )
import Baikai.Agent.Config
  ( AgentConfigPaths (..),
    AgentJob,
    agentJobRequest,
    applyCeilingToJob,
    defaultAgentConfigPaths,
    listAgentJobs,
    loadAgentCeiling,
    renderAgentConfigError,
    renderAgentConfigScope,
    resolveAgentJob,
  )
import Baikai.Agent.Run (runAgentCommand)
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
import Control.Lens ((&), (.~), (^.))
import Data.ByteString qualified as BS
import Data.Char (isControl, ord)
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
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
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.IO (stdin)

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
    jsonOutput :: !Bool
  }
  deriving stock (Generic)

-- | One capturable run of the command-line surface.
--
-- 'standardOutput' and 'standardError' are __Baikai's__ output. Under
-- the @inherit@ and @tee@ output modes the agent's own output goes
-- straight to the real process streams and bypasses this record
-- entirely, which is correct and is what the motivating consumer wants.
data AgentCliRun = AgentCliRun
  { exitCode :: !Int,
    standardOutput :: !Text,
    standardError :: !Text
  }
  deriving stock (Eq, Show, Generic)

usageExitCode,
  unavailableExitCode,
  internalExitCode,
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

-- | The agent produced output the caller could not interpret.
internalExitCode = 70

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
  where
    assemble jobName promptSource overrides userConfig repoConfig jsonOutput =
      AgentCliOptions
        { command = AgentRun jobName promptSource,
          overrides,
          userConfig,
          repoConfig,
          jsonOutput
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
          jsonOutput
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
          jsonOutput
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
renderJobCommand :: AgentJob -> AgentRunRequest -> Either AgentRenderError AgentCommand
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
effectiveConfigPaths :: AgentCliOptions -> IO AgentConfigPaths
effectiveConfigPaths options =
  case (options ^. #userConfig, options ^. #repoConfig) of
    (Just user, Just repo) ->
      pure AgentConfigPaths {userConfig = Just user, repoConfig = Just repo}
    (user, repo) -> do
      discovered <- defaultAgentConfigPaths
      pure
        AgentConfigPaths
          { userConfig = user <|> discovered ^. #userConfig,
            repoConfig = repo <|> discovered ^. #repoConfig
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
      | options ^. #jsonOutput -> successfulRun (jsonArray (map entryJson entries) <> "\n") ""
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
      jsonObject
        [ ("name", jsonString (entry ^. #name)),
          ("scope", jsonString (renderAgentConfigScope (entry ^. #scope))),
          ("definingScopes", Text.pack (show (entry ^. #definingScopes)))
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
    ceilingSource :: !Text
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
      let warningsText = renderWarningsText (resolved ^. #warnings)
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
          pure $ case loadedCeiling of
            Left problem ->
              Left
                StageFailure
                  { exitCode = configExitCode,
                    message = renderAgentConfigError problem,
                    report = Nothing,
                    warnings = warningsText
                  }
            Right ceiling' ->
              Right
                StagedJob
                  { job,
                    report = resolved ^. #report,
                    warnings = warningsText,
                    ceiling = ceiling',
                    ceilingSource = ceilingSourceLabel paths
                  }
  where
    configFailure text =
      StageFailure
        { exitCode = configExitCode,
          message = text,
          report = Nothing,
          warnings = ""
        }

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
    Left failure ->
      AgentCliRun
        { exitCode = failure ^. #exitCode,
          -- A failed resolution's provenance is exactly what an explain
          -- command is for, so the report is printed when there is one.
          standardOutput = maybe "" (renderReport options) (failure ^. #report),
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
              standardOutput = jsonShow (Just (renderAgentRenderError refusal)) Nothing <> "\n",
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
          successfulRun (jsonShow Nothing (Just command) <> "\n") (staged ^. #warnings)
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
    rendered = do
      permitted <- applyCeilingToJob (staged ^. #ceiling) request
      renderJobCommand (staged ^. #job) permitted
    textSections =
      "job \""
        <> jobName
        <> "\"\n\neffective configuration\n"
        <> renderEffectiveConfig (staged ^. #report)
        <> "\npolicy ceiling, from "
        <> staged ^. #ceilingSource
        <> "\n"
        <> renderCeiling (staged ^. #ceiling)
    jsonShow refusal command =
      jsonObject
        ( [ ("job", jsonString jobName),
            ("configuration", renderResolutionJson (staged ^. #report)),
            ("ceiling", ceilingJson (staged ^. #ceilingSource) (staged ^. #ceiling))
          ]
            <> maybe [] (\message -> [("refused", jsonString message)]) refusal
            <> maybe [] (\value -> [("command", commandJson value)]) command
        )

renderReport :: AgentCliOptions -> ResolutionReport -> Text
renderReport options report
  | options ^. #jsonOutput = renderResolutionJson report <> "\n"
  | otherwise = renderEffectiveConfig report

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

renderCeiling :: AgentCeiling -> Text
renderCeiling ceiling' =
  Text.unlines
    [ "  max-capability       " <> renderAgentCapability (ceiling' ^. #maxCapability),
      "  allow-provider-args  " <> renderBool (ceiling' ^. #allowProviderArgs),
      "  allowed-providers    " <> renderProviders (ceiling' ^. #allowedProviders)
    ]
  where
    renderBool True = "true"
    renderBool False = "false"
    renderProviders [] = "none"
    renderProviders providers =
      Text.intercalate ", " (map renderAgentProvider providers)

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
    Right (request, command) -> do
      outcome <- runAgentCommand request command
      pure (interpret options staged request outcome)
  where
    request0 = agentJobRequest (staged ^. #job) promptBody
    prepared = do
      permitted <- applyCeilingToJob (staged ^. #ceiling) request0
      command <- renderJobCommand (staged ^. #job) permitted
      pure (permitted, command)
    refusedRun message
      | options ^. #jsonOutput =
          AgentCliRun
            { exitCode = refusedExitCode,
              standardOutput =
                jsonObject
                  [ ("outcome", jsonString "refused"),
                    ("exitCode", Text.pack (show refusedExitCode)),
                    ("message", jsonString message)
                  ]
                  <> "\n",
              standardError = staged ^. #warnings
            }
      | otherwise =
          failedRun refusedExitCode (staged ^. #warnings <> "refused: " <> message <> "\n")

interpret ::
  AgentCliOptions ->
  StagedJob ->
  AgentRunRequest ->
  Either AgentRunFailure AgentRunResult ->
  AgentCliRun
interpret options staged request = \case
  Left failure
    | options ^. #jsonOutput ->
        AgentCliRun
          { exitCode = failureExitCode failure,
            standardOutput =
              jsonObject
                [ ("outcome", jsonString "failed"),
                  ("exitCode", Text.pack (show (failureExitCode failure))),
                  ("message", jsonString (renderAgentRunFailure failure))
                ]
                <> "\n",
            standardError = staged ^. #warnings
          }
    | otherwise ->
        failedRun
          (failureExitCode failure)
          (staged ^. #warnings <> renderAgentRunFailure failure <> "\n")
  Right result
    | options ^. #jsonOutput ->
        AgentCliRun
          { exitCode = resultExitCode result,
            standardOutput = resultJson result <> "\n",
            standardError = staged ^. #warnings <> truncationNotes result
          }
    | otherwise ->
        AgentCliRun
          { exitCode = resultExitCode result,
            -- Only a captured stream reaches this record. Under `tee`
            -- the runner already echoed the bytes to the real streams
            -- while draining, so re-emitting them here would print
            -- everything twice.
            standardOutput = if capturing then decoded (result ^. #stdout) else "",
            standardError =
              staged ^. #warnings
                <> (if capturing then decoded (result ^. #stderr) else "")
                <> truncationNotes result
          }
  where
    -- Only a captured stream is Baikai's to re-emit. `tee` already wrote
    -- the bytes to the real streams while draining, and `inherit`
    -- captured nothing at all.
    capturing = request ^. #output == CaptureOutput

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
  OutputMalformed _ -> internalExitCode

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

resultJson :: AgentRunResult -> Text
resultJson result =
  jsonObject
    ( [ ("outcome", jsonString "ran"),
        ("exitCode", Text.pack (show (resultExitCode result))),
        ("provider", jsonString (renderAgentProvider (result ^. #provider))),
        ("durationSeconds", Text.pack (show (realToFrac (result ^. #duration) :: Double)))
      ]
        <> streamFields "stdout" (result ^. #stdout)
        <> streamFields "stderr" (result ^. #stderr)
    )
  where
    streamFields _ OutputNotCaptured = []
    streamFields label captured =
      [ (label, jsonString (decoded captured)),
        ( label <> "Truncated",
          case captured of
            OutputTruncated _ -> "true"
            _ -> "false"
        )
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
-- A very small JSON writer
-- --------------------------------------------------------------------

-- | Hand-rolled rather than pulled from @aeson@: the package needs
-- exactly three shapes, and the alternative is a dependency the library
-- otherwise has no use for.
jsonObject :: [(Text, Text)] -> Text
jsonObject fields =
  "{" <> Text.intercalate "," [jsonString name <> ":" <> value | (name, value) <- fields] <> "}"

jsonArray :: [Text] -> Text
jsonArray values = "[" <> Text.intercalate "," values <> "]"

jsonString :: Text -> Text
jsonString value = "\"" <> Text.concatMap escape value <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape character
      | isControl character =
          "\\u" <> Text.justifyRight 4 '0' (Text.pack (showHex (ord character) ""))
      | otherwise = Text.singleton character

ceilingJson :: Text -> AgentCeiling -> Text
ceilingJson sourceLabel ceiling' =
  jsonObject
    [ ("source", jsonString sourceLabel),
      ("maxCapability", jsonString (renderAgentCapability (ceiling' ^. #maxCapability))),
      ( "allowProviderArgs",
        if ceiling' ^. #allowProviderArgs then "true" else "false"
      ),
      ( "allowedProviders",
        jsonArray (map (jsonString . renderAgentProvider) (ceiling' ^. #allowedProviders))
      )
    ]

commandJson :: AgentCommand -> Text
commandJson command =
  jsonObject
    [ ("executable", jsonString (Text.pack (command ^. #executable))),
      ("arguments", jsonArray (map (jsonString . Text.pack) (command ^. #arguments))),
      ( "promptTransport",
        jsonString
          ( case command ^. #promptTransport of
              PromptOnStdin -> "stdin"
              PromptAsArgument -> "argument"
          )
      )
    ]
