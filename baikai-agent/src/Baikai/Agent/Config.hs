-- | Resolve an unattended coding-agent job from layered KDL
-- configuration.
--
-- A repository owns @.baikai\/agents.kdl@, which names jobs; an operator
-- owns @~\/.config\/baikai\/agents.kdl@, which supplies defaults __and__
-- the safety ceiling. A caller asks for a job by name and receives a
-- fully resolved description together with a report saying, for every
-- value, which file and which line it came from.
--
-- Two loads with deliberately different rules live here, and the
-- asymmetry between them is the security property of this module.
-- 'resolveAgentJob' layers five sources, later ones winning.
-- 'loadAgentCeiling' reads the operator's own file and __nothing else__,
-- so no repository file, environment variable, or command-line override
-- can raise the ceiling. They are two functions rather than one function
-- with a flag precisely so the difference is visible in the code.
--
-- A repository configuration file is untrusted input: an automation
-- daemon that encounters a checkout is reading a file somebody else
-- wrote, and that file could ask for unrestricted filesystem access.
-- 'applyCeilingToJob' is where that ask is refused.
module Baikai.Agent.Config
  ( -- * The configured shape of one job
    AgentJob (..),
    agentJobConfig,
    agentJobRequest,

    -- * Where configuration lives
    AgentConfigPaths (..),
    AgentConfigScope (..),
    renderAgentConfigScope,
    defaultAgentConfigPaths,

    -- * Layered resolution
    resolveAgentJob,

    -- * The operator policy ceiling
    agentCeilingConfig,
    loadAgentCeiling,
    applyCeilingToJob,

    -- * Enumeration
    AgentJobEntry (..),
    listAgentJobs,

    -- * Failures
    AgentConfigError (..),
    renderAgentConfigError,

    -- * Exposed for testing
    parseDuration,
    agentEnvBindings,
    defaultOutputLimit,
    scalarOrListDecoder,
    validateJobName,
  )
where

import Baikai.Agent
  ( AgentCapability,
    AgentCeiling,
    AgentOutputMode (..),
    AgentProvider,
    AgentRenderError (..),
    AgentRunRequest,
    AgentSafety,
    agentRunRequest,
    agentSafety,
    applyAgentCeiling,
    defaultAgentCeiling,
    parseAgentCapability,
    parseAgentOutputMode,
    parseAgentProvider,
    renderAgentCapability,
    renderAgentOutputMode,
    renderAgentProvider,
  )
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Read qualified as TextRead
import Data.Time.Clock (NominalDiffTime)
import GHC.Generics (Generic)
import Settei.Config (Config, optional, required, withDefault)
import Settei.Default (Default, RuleName (..), constantDefault)
import Settei.Env
  ( Bindings,
    EnvName (..),
    EnvSnapshot,
    binding,
    bindings,
    environmentSource,
    renderEnvErrorsText,
  )
import Settei.Kdl
  ( kdlSourceOptions,
    readKdlSource,
    renderKdlErrorsText,
    withKdlSourcePath,
  )
import Settei.Key (Key, keySegments, parseKey)
import Settei.Optparse (CliOverride, cliSources)
import Settei.Resolve (ResolveResult, defaultResolveOptions, resolve)
import Settei.Setting
  ( Setting,
    publicSetting,
    publicSettingWithRenderer,
    publicShowSetting,
    secretSetting,
  )
import Settei.Source (Source, sourceLeaves)
import Settei.Value
  ( Decoder,
    RawValue (..),
    boolDecoder,
    boundedIntegralDecoder,
    decodeFailure,
    decoder,
    enumDecoder,
    parsedDecoder,
    runDecoder,
    textDecoder,
  )
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | The configured shape of one named job.
--
-- The safety fields are flattened here rather than nested as an
-- 'AgentSafety', even though the KDL document nests them under a
-- @safety@ node. A @settei@ setting is addressed by a dotted key, not by
-- a nested record, so a flat record maps one-to-one onto the
-- declaration; 'agentJobRequest' reassembles the nested value.
--
-- There is deliberately no @name@ field. The name is how the job was
-- looked up, not a property of it, and storing it would invite a
-- mismatch between the two.
data AgentJob = AgentJob
  { -- | Which coding-agent tool to run. Required.
    provider :: !AgentProvider,
    -- | Where the tool lives, for an operator whose installation is not
    -- on @PATH@ under its canonical name. 'AgentRunRequest' has no field
    -- for this, so it stays a configuration concern.
    executable :: !(Maybe FilePath),
    -- | Model override, or 'Nothing' to leave the tool's default.
    modelId :: !(Maybe Text),
    -- | Reasoning-effort override, or 'Nothing' to leave the tool's
    -- default.
    effort :: !(Maybe ThinkingLevel),
    -- | The directory the run is rooted in. Required.
    workingDir :: !FilePath,
    -- | Directories the run may reach beyond 'workingDir'.
    extraDirs :: ![FilePath],
    -- | How much filesystem authority the job asks for. Required: a job
    -- that forgot to state its authority must not silently receive
    -- some.
    capability :: !AgentCapability,
    -- | Optional narrowing of the provider's tool set.
    allowedTools :: ![Text],
    -- | Raw provider arguments passed through verbatim. Classified
    -- __secret__, because it is the one field an operator could write a
    -- credential into.
    providerArgs :: ![Text],
    -- | Wall-clock limit for the whole run, or 'Nothing' for no limit.
    timeout :: !(Maybe NominalDiffTime),
    -- | What to do with the child's output streams.
    output :: !AgentOutputMode,
    -- | Maximum captured bytes per stream. 'Nothing' means unbounded.
    outputLimit :: !(Maybe Int),
    -- | Names of environment variables the job declares it requires.
    -- Names only, never values, so the list cannot carry a secret.
    envRequires :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | Which configuration file a value or a job name came from.
--
-- This is Baikai's own vocabulary rather than @settei@'s 'SourceKind',
-- which cannot serve: @settei-kdl@ tags every document it reads
-- @FileSource \"KDL v2\"@ — naming the /format/, not the file — so the
-- user and repository documents are indistinguishable by kind.
data AgentConfigScope
  = UserScope
  | RepositoryScope
  deriving stock (Eq, Ord, Show, Generic)

renderAgentConfigScope :: AgentConfigScope -> Text
renderAgentConfigScope UserScope = "user configuration"
renderAgentConfigScope RepositoryScope = "repository configuration"

-- | One configured job name and the scope that supplied the winning
-- definition of it.
data AgentJobEntry = AgentJobEntry
  { -- | The job name, as it appears after the @jobs@ segment.
    name :: !Text,
    -- | The highest-precedence scope defining the name.
    scope :: !AgentConfigScope,
    -- | How many scopes define this name. A bare name with no
    -- indication that two files define it hides a real source of
    -- confusion, so the count is reported rather than dropped.
    definingScopes :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | The two configuration files, each absent when it does not exist.
--
-- An explicit record with a pure resolution path underneath is what lets
-- a test point at a temporary directory. Nothing below this record reads
-- the real @HOME@ or @XDG_CONFIG_HOME@.
data AgentConfigPaths = AgentConfigPaths
  { userConfig :: !(Maybe FilePath),
    repoConfig :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

-- | A failure loading configuration, as distinct from a resolution
-- failure, which @settei@ reports through 'ResolveResult'.
data AgentConfigError
  = -- | The file that could not be read or parsed, and the rendered
    -- @settei-kdl@ diagnosis. The diagnosis never contains the file's
    -- contents: @settei-kdl@ errors carry a category, a name, a path, a
    -- span, and a concise message, and appending the document \"for
    -- context\" would defeat that redaction.
    ConfigFileUnreadable !FilePath !Text
  | -- | The job name, and why it cannot address a configuration key.
    InvalidJobName !Text !Text
  deriving stock (Eq, Show, Generic)

renderAgentConfigError :: AgentConfigError -> Text
renderAgentConfigError (ConfigFileUnreadable path message) =
  "could not read the configuration file " <> Text.pack path <> ": " <> message
renderAgentConfigError (InvalidJobName jobName why) =
  "invalid job name " <> jobName <> ": " <> why

-- | Bytes per stream captured when no layer states a limit.
--
-- Concrete rather than unbounded on purpose: an operator who never
-- mentions a limit should not be one runaway agent away from exhausting
-- memory. Four mebibytes is far more than a normal run prints, and any
-- layer may raise it, lower it, or write @output-limit \"unlimited\"@ to
-- remove it.
defaultOutputLimit :: Int
defaultOutputLimit = 4194304

-- | Accept a scalar, an array, or an absent value as a list.
--
-- @settei@'s own @listDecoder@ accepts only an array, which cannot serve
-- here: a KDL node's raw shape depends on how many arguments it has, so
-- @extra-dirs@ with no arguments is a null, with one argument is a
-- scalar, and only with two or more is it an array. A command-line
-- override is always a scalar, because @cliOverride@ builds a
-- @RawText@. Requiring an array would make the one-directory spelling
-- and every list-valued @--set@ undecodable.
scalarOrListDecoder :: Decoder a -> Decoder [a]
scalarOrListDecoder elementDecoder =
  decoder $ \key raw -> case raw of
    RawNull -> Right []
    RawArray values -> traverse (runDecoder elementDecoder key) values
    scalar -> fmap pure (runDecoder elementDecoder key scalar)

-- | Parse a duration written with a unit suffix, or a bare number of
-- seconds.
--
-- @\"90s\"@ is ninety seconds, @\"45m\"@ is forty-five minutes,
-- @\"2h\"@ is two hours, and @\"45\"@ is forty-five seconds. Zero and
-- negative values are rejected: a timeout of zero would mean \"kill
-- every run immediately\", which no operator intends and which would be
-- baffling to diagnose. Omitting the setting is how a run goes
-- untimed.
parseDuration :: Text -> Maybe NominalDiffTime
parseDuration raw =
  case TextRead.decimal (Text.strip raw) of
    Right (magnitude :: Integer, rest)
      | magnitude > 0 ->
          fmap
            (\multiplier -> fromInteger (magnitude * multiplier))
            (unitMultiplier (Text.strip rest))
    _ -> Nothing
  where
    unitMultiplier "" = Just 1
    unitMultiplier "s" = Just 1
    unitMultiplier "m" = Just 60
    unitMultiplier "h" = Just 3600
    unitMultiplier _ = Nothing

renderDuration :: NominalDiffTime -> Text
renderDuration value = Text.pack (show value)

-- | The configuration key addressing one leaf of one named job.
--
-- Calling 'error' on an unparseable key is safe only because the leaf
-- names are compile-time constants and the job name has already passed
-- 'validateJobName'; a failure here is a programming error, not bad
-- input. This mirrors the @validKey@ helper in @settei@'s own reference
-- application.
jobKey :: Text -> Text -> Key
jobKey jobName leaf = validKey ("jobs." <> jobName <> "." <> leaf)

validKey :: Text -> Key
validKey value = either (error . show) id (parseKey value)

-- | Reject a job name that cannot address a configuration key.
--
-- A name containing a dot would silently nest one level deeper than the
-- operator wrote, and an empty name would address the @jobs@ node
-- itself. Both are refused here so 'jobKey' is only ever reached with a
-- good name.
validateJobName :: Text -> Either AgentConfigError ()
validateJobName jobName
  | Text.null jobName = Left (InvalidJobName jobName "the name is empty")
  | Text.any (== '.') jobName =
      Left (InvalidJobName jobName "a job name may not contain a dot")
  | otherwise = case parseKey ("jobs." <> jobName <> ".provider") of
      Left problem -> Left (InvalidJobName jobName (Text.pack (show problem)))
      Right _ -> Right ()

providerDecoder :: Decoder AgentProvider
providerDecoder =
  parsedDecoder
    "one of: claude, codex"
    (maybe (Left "unknown provider") Right . parseAgentProvider)

capabilityDecoder :: Decoder AgentCapability
capabilityDecoder =
  parsedDecoder
    "one of: read-only, edit-workspace, full-access"
    (maybe (Left "unknown capability") Right . parseAgentCapability)

outputModeDecoder :: Decoder AgentOutputMode
outputModeDecoder =
  parsedDecoder
    "one of: inherit, capture, tee"
    (maybe (Left "unknown output mode") Right . parseAgentOutputMode)

-- | The six canonical reasoning-effort names. The list lives in
-- @baikai\/src\/Baikai\/ThinkingLevel.hs@, which has a renderer but no
-- parser, so a future level must be added in both places.
effortDecoder :: Decoder ThinkingLevel
effortDecoder =
  enumDecoder
    [ ("minimal", ThinkingMinimal),
      ("low", ThinkingLow),
      ("medium", ThinkingMedium),
      ("high", ThinkingHigh),
      ("xhigh", ThinkingXHigh),
      ("max", ThinkingMax)
    ]

pathDecoder :: Decoder FilePath
pathDecoder = fmap Text.unpack textDecoder

-- | A duration written with a unit, or a bare positive number of
-- seconds. The unquoted form @timeout 2700@ is accepted too, because a
-- KDL number is a @RawNumber@ rather than a @RawText@.
durationDecoder :: Decoder NominalDiffTime
durationDecoder =
  decoder $ \key raw ->
    let reject = Left (decodeFailure key durationExpectation)
     in case raw of
          RawText value -> maybe reject Right (parseDuration value)
          _ -> case runDecoder boundedIntegralDecoder key raw of
            Right (seconds :: Int) | seconds > 0 -> Right (fromIntegral seconds)
            _ -> reject
  where
    durationExpectation =
      "a positive duration such as 90s, 45m, or 2h, or a bare number of seconds"

-- | A positive byte count, or the word @unlimited@ for no bound.
outputLimitDecoder :: Decoder (Maybe Int)
outputLimitDecoder =
  decoder $ \key raw -> case raw of
    RawText "unlimited" -> Right Nothing
    _ -> case runDecoder boundedIntegralDecoder key raw of
      Right (bytes :: Int) | bytes > 0 -> Right (Just bytes)
      _ -> Left (decodeFailure key "a positive number of bytes, or the word unlimited")

providerSetting :: Text -> Setting AgentProvider
providerSetting jobName =
  publicSettingWithRenderer
    (jobKey jobName "provider")
    "Coding-agent tool to run"
    providerDecoder
    renderAgentProvider

executableSetting :: Text -> Setting FilePath
executableSetting jobName =
  publicShowSetting
    (jobKey jobName "executable")
    "Path to the coding-agent executable, overriding PATH lookup"
    pathDecoder

modelSetting :: Text -> Setting Text
modelSetting jobName =
  publicSetting (jobKey jobName "model") "Model override" textDecoder

effortSetting :: Text -> Setting ThinkingLevel
effortSetting jobName =
  publicSettingWithRenderer
    (jobKey jobName "effort")
    "Reasoning-effort override"
    effortDecoder
    renderThinkingLevel

workingDirSetting :: Text -> Setting FilePath
workingDirSetting jobName =
  publicShowSetting
    (jobKey jobName "working-dir")
    "Directory the run is rooted in"
    pathDecoder

extraDirsSetting :: Text -> Setting [FilePath]
extraDirsSetting jobName =
  publicShowSetting
    (jobKey jobName "extra-dirs")
    "Directories the run may reach beyond its working directory"
    (scalarOrListDecoder pathDecoder)

capabilitySetting :: Text -> Setting AgentCapability
capabilitySetting jobName =
  publicSettingWithRenderer
    (jobKey jobName "safety.capability")
    "Filesystem authority the job requests"
    capabilityDecoder
    renderAgentCapability

allowedToolsSetting :: Text -> Setting [Text]
allowedToolsSetting jobName =
  publicShowSetting
    (jobKey jobName "safety.allowed-tools")
    "Narrowing of the provider's tool set"
    (scalarOrListDecoder textDecoder)

-- | Raw provider arguments, classified __secret__.
--
-- This is the only setting in the schema that can carry a credential —
-- nothing stops an operator from writing @--api-key sk-…@ here — and
-- @settei@ converts a secret-classified value to an opaque redacted form
-- before it can be retained in a resolution report or in a structural
-- error. Every other setting is structurally incapable of holding a
-- secret: environment variables are referenced by name and never by
-- value, and both coding agents keep their credentials in their own
-- stores.
providerArgsSetting :: Text -> Setting [Text]
providerArgsSetting jobName =
  secretSetting
    (jobKey jobName "safety.provider-args")
    "Raw provider arguments passed through verbatim"
    (scalarOrListDecoder textDecoder)

timeoutSetting :: Text -> Setting NominalDiffTime
timeoutSetting jobName =
  publicSettingWithRenderer
    (jobKey jobName "timeout")
    "Wall-clock limit for the whole run"
    durationDecoder
    renderDuration

outputSetting :: Text -> Setting AgentOutputMode
outputSetting jobName =
  publicSettingWithRenderer
    (jobKey jobName "output")
    "What to do with the child's output streams"
    outputModeDecoder
    renderAgentOutputMode

outputLimitSetting :: Text -> Setting (Maybe Int)
outputLimitSetting jobName =
  publicShowSetting
    (jobKey jobName "output-limit")
    "Maximum captured bytes per stream"
    outputLimitDecoder

envRequiresSetting :: Text -> Setting [Text]
envRequiresSetting jobName =
  publicShowSetting
    (jobKey jobName "env-requires")
    "Environment variable names the job requires; names only, never values"
    (scalarOrListDecoder textDecoder)

emptyListDefault :: Text -> Default [a]
emptyListDefault ruleName =
  constantDefault (RuleName ruleName) "nothing configured" []

-- | The declaration for one named job.
--
-- The keys are built from the job name because @settei@'s 'Config'
-- describes a statically known set of keys while a document holds an
-- unknown number of jobs. A 'Config' is an ordinary value, so one is
-- built per name; decoding the whole document into an opaque map would
-- work too but would lose per-value provenance, and provenance is the
-- point.
--
-- Defaults are named rules rather than a synthetic built-in source
-- because a source would have to be rebuilt for every job name — every
-- key contains it — while a rule is name-independent, keeps this
-- declaration complete on its own, and is reported with its own name and
-- rationale.
agentJobConfig :: Text -> Config AgentJob
agentJobConfig jobName =
  AgentJob
    <$> required (providerSetting jobName)
    <*> optional (executableSetting jobName)
    <*> optional (modelSetting jobName)
    <*> optional (effortSetting jobName)
    <*> required (workingDirSetting jobName)
    <*> withDefault (extraDirsSetting jobName) (emptyListDefault "no-extra-dirs")
    <*> required (capabilitySetting jobName)
    <*> withDefault (allowedToolsSetting jobName) (emptyListDefault "no-tool-restriction")
    <*> withDefault (providerArgsSetting jobName) (emptyListDefault "no-provider-args")
    <*> optional (timeoutSetting jobName)
    <*> withDefault
      (outputSetting jobName)
      (constantDefault (RuleName "inherit-output") "no output discipline configured" InheritOutput)
    <*> withDefault
      (outputLimitSetting jobName)
      ( constantDefault
          (RuleName "default-output-limit")
          "no output limit configured"
          (Just defaultOutputLimit)
      )
    <*> withDefault (envRequiresSetting jobName) (emptyListDefault "no-required-environment")

-- | Convert a resolved job into a run request, with the prompt supplied
-- at call time because a job describes where the text comes from rather
-- than carrying it.
--
-- The ceiling is deliberately __not__ applied here. Burying the check
-- inside a conversion would make it bypassable by calling the conversion
-- directly; 'applyCeilingToJob' is a separate, explicitly named step.
agentJobRequest :: AgentJob -> Text -> AgentRunRequest
agentJobRequest job promptBody =
  agentRunRequest (job ^. #provider) (job ^. #workingDir) promptBody
    & #modelId .~ (job ^. #modelId)
    & #effort .~ (job ^. #effort)
    & #extraDirs .~ (job ^. #extraDirs)
    & #safety .~ requestedSafety
    & #timeout .~ (job ^. #timeout)
    & #output .~ (job ^. #output)
    & #outputLimit .~ (job ^. #outputLimit)
    & #envPassthrough .~ (job ^. #envRequires)
  where
    requestedSafety :: AgentSafety
    requestedSafety =
      agentSafety (job ^. #capability)
        & #allowedTools .~ (job ^. #allowedTools)
        & #providerArgs .~ (job ^. #providerArgs)

-- | Environment variables that may influence a job, bound explicitly.
--
-- The set is small and deliberately chosen: the provider, the model, the
-- executable, and the timeout. The capability, the tool list, and the
-- raw provider arguments are __not__ bound. An environment variable is
-- easy to set accidentally and is inherited by every child process, so
-- letting one widen a job's authority would create exactly the ambient
-- influence the ceiling exists to prevent.
--
-- The binding list is a function of the job name rather than a module
-- constant, because every key contains the name. Forcing it for any name
-- validates the whole list, which the test suite does so an invalid edit
-- fails in tests rather than at start-up.
agentEnvBindings :: Text -> Bindings
agentEnvBindings jobName =
  either
    (error . Text.unpack . renderEnvErrorsText)
    id
    ( bindings
        [ binding (EnvName "BAIKAI_AGENT_PROVIDER") (jobKey jobName "provider"),
          binding (EnvName "BAIKAI_AGENT_MODEL") (jobKey jobName "model"),
          binding (EnvName "BAIKAI_AGENT_EXECUTABLE") (jobKey jobName "executable"),
          binding (EnvName "BAIKAI_AGENT_TIMEOUT") (jobKey jobName "timeout")
        ]
    )

-- | Locate the two configuration files, treating a missing file as a
-- normal state rather than an error.
--
-- The user path is @$XDG_CONFIG_HOME\/baikai\/agents.kdl@ when that
-- variable is set and non-empty, otherwise
-- @$HOME\/.config\/baikai\/agents.kdl@. The repository path is
-- @.\/.baikai\/agents.kdl@ relative to the current working directory and
-- __nothing else__: an upward search would make the effective
-- configuration depend on where the process happened to start, and a job
-- could silently pick up a file from a parent directory outside the
-- repository it believes it is working in. For an untrusted file that
-- grants filesystem authority that is an unacceptable surprise. A caller
-- wanting a different file passes an explicit path.
defaultAgentConfigPaths :: IO AgentConfigPaths
defaultAgentConfigPaths = do
  xdgHome <- lookupEnv "XDG_CONFIG_HOME"
  homeDir <- lookupEnv "HOME"
  let configBase = case xdgHome of
        Just dir | not (null dir) -> Just dir
        _ -> fmap (</> ".config") (nonEmptyPath =<< homeDir)
      userPath = fmap (\base -> base </> "baikai" </> "agents.kdl") configBase
  userConfig <- maybe (pure Nothing) whenPresent userPath
  repoConfig <- whenPresent (".baikai" </> "agents.kdl")
  pure AgentConfigPaths {userConfig, repoConfig}
  where
    nonEmptyPath dir = if null dir then Nothing else Just dir
    whenPresent path = do
      present <- doesFileExist path
      pure (if present then Just path else Nothing)

-- | Read one scope's document, if it is configured at all.
loadScope :: AgentConfigScope -> Maybe FilePath -> IO (Either AgentConfigError [Source])
loadScope _ Nothing = pure (Right [])
loadScope scope (Just path) = do
  outcome <-
    readKdlSource
      (withKdlSourcePath path (kdlSourceOptions (renderAgentConfigScope scope)))
      path
  pure $ case outcome of
    Left problems -> Left (ConfigFileUnreadable path (renderKdlErrorsText problems))
    Right loaded -> Right [loaded]

-- | Both documents in ascending precedence order, each tagged with the
-- scope that produced it.
loadScopeSources :: AgentConfigPaths -> IO (Either AgentConfigError [(AgentConfigScope, Source)])
loadScopeSources paths = do
  userLoaded <- loadScope UserScope (paths ^. #userConfig)
  repoLoaded <- loadScope RepositoryScope (paths ^. #repoConfig)
  pure $ do
    userSources <- userLoaded
    repoSources <- repoLoaded
    Right (map ((,) UserScope) userSources <> map ((,) RepositoryScope) repoSources)

-- | Resolve one named job across all five layers.
--
-- The environment snapshot is a parameter rather than the real
-- environment so the layer is testable without mutating the process, and
-- the command-line overrides arrive already parsed so this module needs
-- no @optparse-applicative@ wiring.
resolveAgentJob ::
  AgentConfigPaths ->
  EnvSnapshot ->
  [CliOverride] ->
  Text ->
  IO (Either AgentConfigError (ResolveResult AgentJob))
resolveAgentJob paths snapshot overrides jobName = do
  loaded <- loadScopeSources paths
  pure $ do
    validateJobName jobName
    scoped <- loaded
    Right
      ( resolve
          defaultResolveOptions
          -- Lowest precedence first: built-in defaults (named rules
          -- inside `agentJobConfig`), the user file, the repository
          -- file, the environment, then explicit command-line
          -- overrides. This list is the only place the order is
          -- expressed, so reordering it is a silent behavior change.
          ( map snd scoped
              <> [environmentSource (agentEnvBindings jobName) snapshot]
              <> cliSources "arguments" overrides
          )
          (agentJobConfig jobName)
      )

-- | The declaration for the operator's policy ceiling.
--
-- Each setting defaults to the corresponding field of
-- 'defaultAgentCeiling', so an operator file that sets only one of the
-- three still yields a complete ceiling. 'AgentCeiling' hides its
-- constructor, so the value is built by updating the default through
-- its generic field lenses rather than by a record literal.
agentCeilingConfig :: Config AgentCeiling
agentCeilingConfig =
  buildCeiling
    <$> withDefault
      maxCapabilitySetting
      ( constantDefault
          (RuleName "default-max-capability")
          "no operator policy configured"
          (defaultAgentCeiling ^. #maxCapability)
      )
    <*> withDefault
      allowProviderArgsSetting
      ( constantDefault
          (RuleName "default-allow-provider-args")
          "no operator policy configured"
          (defaultAgentCeiling ^. #allowProviderArgs)
      )
    <*> withDefault
      allowedProvidersSetting
      ( constantDefault
          (RuleName "default-allowed-providers")
          "no operator policy configured"
          (defaultAgentCeiling ^. #allowedProviders)
      )
  where
    buildCeiling cap rawArgs providers =
      defaultAgentCeiling
        & #maxCapability .~ cap
        & #allowProviderArgs .~ rawArgs
        & #allowedProviders .~ providers
    maxCapabilitySetting =
      publicSettingWithRenderer
        (validKey "policy.max-capability")
        "Highest capability any job may request"
        capabilityDecoder
        renderAgentCapability
    allowProviderArgsSetting =
      publicShowSetting
        (validKey "policy.allow-provider-args")
        "Whether jobs may pass raw provider arguments at all"
        boolDecoder
    allowedProvidersSetting =
      publicShowSetting
        (validKey "policy.allowed-providers")
        "Providers jobs may select"
        (scalarOrListDecoder providerDecoder)

-- | Load the operator's policy ceiling.
--
-- __The source list below is the entire mechanism.__ It resolves against
-- the user file and nothing else. It must never include the repository
-- file, the environment source, or command-line overrides: a ceiling any
-- lower layer could raise is not a ceiling. If the repository file could
-- set @policy.max-capability@ an untrusted checkout would grant itself
-- whatever it liked, and if a command-line override could, then
-- @--set policy.max-capability=full-access@ would defeat the mechanism
-- outright — which is exactly the flag a compromised automation script
-- would add. Someone \"fixing an inconsistency\" by adding the
-- repository source here would silently remove the security property
-- while every test that does not specifically check it kept passing.
--
-- With no user file the ceiling is 'defaultAgentCeiling': read-only and
-- edit-workspace are permitted, full access is refused, and raw provider
-- arguments are refused.
loadAgentCeiling :: AgentConfigPaths -> IO (Either AgentConfigError AgentCeiling)
loadAgentCeiling paths = do
  userLoaded <- loadScope UserScope (paths ^. #userConfig)
  pure $ do
    userSources <- userLoaded
    let resolved = resolve defaultResolveOptions userSources agentCeilingConfig
    case resolved ^. #answer of
      Left problems ->
        Left
          ( ConfigFileUnreadable
              (maybe "<no user configuration>" id (paths ^. #userConfig))
              (renderCeilingProblems problems)
          )
      Right ceiling' -> Right ceiling'
  where
    renderCeilingProblems problems =
      Text.intercalate "; " (map (Text.pack . show) (NonEmpty.toList problems))

-- | Refuse a request that exceeds the operator's ceiling.
--
-- The comparison itself is 'applyAgentCeiling', which is pure and
-- already tested in the core package. This wrapper only converts the
-- violation list into the 'AgentRenderError' the command-line tool
-- reports through, so there is one error type on the path from
-- configuration to rendered command. The request is never clamped to
-- fit.
applyCeilingToJob :: AgentCeiling -> AgentRunRequest -> Either AgentRenderError AgentRunRequest
applyCeilingToJob ceiling' request =
  case applyAgentCeiling ceiling' request of
    Left violations -> Left (CeilingRejected violations)
    Right permitted -> Right permitted

-- | Every configured job name, sorted, each attributed to the
-- highest-precedence scope defining it.
--
-- Sorting matters because a script may diff the output. The names come
-- from parsed keys, so they are already valid key segments and cannot
-- contain a dot; 'validateJobName' guards the other direction, where a
-- caller supplies a name.
listAgentJobs :: AgentConfigPaths -> IO (Either AgentConfigError [AgentJobEntry])
listAgentJobs paths = do
  loaded <- loadScopeSources paths
  pure (fmap entriesFrom loaded)
  where
    entriesFrom scoped =
      [ AgentJobEntry {name, scope, definingScopes}
      | (name, (scope, definingScopes)) <- Map.toAscList (foldl' absorb Map.empty scoped)
      ]
    absorb seen (scope, loadedSource) =
      foldl'
        (\acc jobName -> Map.insertWith laterScopeWins jobName (scope, 1) acc)
        seen
        (jobNamesIn loadedSource)
    -- Map.insertWith applies its function as @f new old@, so the later
    -- source's scope replaces the earlier one and the count accumulates.
    laterScopeWins (newScope, _) (_, count) = (newScope, count + 1)

-- | The distinct job names one document defines.
--
-- Distinct per source, not per leaf: one job contributes many leaf keys,
-- and counting them would inflate the defining-scope count.
jobNamesIn :: Source -> [Text]
jobNamesIn loadedSource =
  Set.toList
    ( Set.fromList
        [ jobName
        | (key, _) <- sourceLeaves loadedSource,
          "jobs" : jobName : _ <- [NonEmpty.toList (keySegments key)]
        ]
    )
