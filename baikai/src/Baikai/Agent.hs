-- | Provider-neutral types for unattended coding-agent runs with
-- local agent CLIs such as Claude Code and Codex.
--
-- An unattended run starts the coding agent with no terminal and no
-- human present, lets it drive its own internal tool loop, allows it
-- to change files inside directories the caller explicitly authorized,
-- and collects a process result. It is neither a completion (the
-- interesting output is the changed working tree, not the text) nor an
-- interactive launch (nobody is watching).
--
-- This module deliberately does not implement process spawning, and it
-- renders no command-line flags. The core package owns the shared
-- vocabulary and the pure policy algebra, while vendor packages own the
-- translation into their CLI's arguments and a separate package owns
-- the process runner.
--
-- This module is not re-exported from "Baikai". Its field accessors
-- deliberately share names with "Baikai.Interactive", so import it
-- directly, qualified if you need both surfaces at once.
module Baikai.Agent
  ( -- * Provider identity
    AgentProvider (..),
    renderAgentProvider,
    parseAgentProvider,

    -- * Capability profile
    AgentCapability (..),
    renderAgentCapability,
    parseAgentCapability,

    -- * Requested safety policy
    AgentSafety (capability, allowedTools, providerArgs),
    agentSafety,

    -- * Output discipline
    AgentOutputMode (..),
    renderAgentOutputMode,
    parseAgentOutputMode,
    AgentCapturedOutput (..),
    capturedBytes,

    -- * The unattended run request
    AgentRunRequest
      ( provider,
        prompt,
        modelId,
        effort,
        workingDir,
        extraDirs,
        safety,
        timeout,
        output,
        outputLimit,
        envPassthrough
      ),
    agentRunRequest,

    -- * The operator policy ceiling
    AgentCeiling (maxCapability, allowProviderArgs, allowedProviders),
    defaultAgentCeiling,
    CeilingViolation (..),
    renderCeilingViolation,
    applyAgentCeiling,

    -- * The rendered command
    AgentPromptTransport (..),
    AgentCommand (..),

    -- * The run result
    AgentRunResult,
    agentRunResult,
    AgentRunOutcome (..),
    agentRunOutcome,

    -- * Failures
    AgentRenderError (..),
    renderAgentRenderError,
    AgentRunFailure (..),
    AgentTimedOut (..),
    renderAgentRunFailure,
  )
where

import Baikai.Evidence (ModelCallEvidence)
import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import System.Exit (ExitCode)

-- | Local coding-agent tools Baikai can describe without depending on
-- a vendor package. The names match 'Baikai.Interactive.InteractiveProvider'
-- so both surfaces spell the same tool identically.
data AgentProvider
  = AgentClaude
  | AgentCodex
  deriving stock (Eq, Ord, Show, Generic)

renderAgentProvider :: AgentProvider -> Text
renderAgentProvider AgentClaude = "claude"
renderAgentProvider AgentCodex = "codex"

-- | Parse a canonical provider name. Matching is exact and
-- case-sensitive: @\"Claude\"@ is not a provider.
parseAgentProvider :: Text -> Maybe AgentProvider
parseAgentProvider "claude" = Just AgentClaude
parseAgentProvider "codex" = Just AgentCodex
parseAgentProvider _ = Nothing

-- | How much authority an unattended run gets, expressed
-- provider-neutrally. Constructors ascend in authority, and the
-- 'Ord' instance derived from that order is what 'applyAgentCeiling'
-- compares against an operator's permitted maximum — do not reorder
-- them.
--
-- * 'AgentReadOnly': the run may read but must not modify anything.
-- * 'AgentEditWorkspace': the run may modify files inside its working
--   directory and its explicit extra directories, and nowhere else.
-- * 'AgentFullAccess': no sandbox at all. This is why an operator
--   ceiling refuses it by default.
data AgentCapability
  = AgentReadOnly
  | AgentEditWorkspace
  | AgentFullAccess
  deriving stock (Eq, Ord, Show, Generic)

renderAgentCapability :: AgentCapability -> Text
renderAgentCapability AgentReadOnly = "read-only"
renderAgentCapability AgentEditWorkspace = "edit-workspace"
renderAgentCapability AgentFullAccess = "full-access"

-- | Parse a canonical capability name. Matching is exact and
-- case-sensitive.
parseAgentCapability :: Text -> Maybe AgentCapability
parseAgentCapability "read-only" = Just AgentReadOnly
parseAgentCapability "edit-workspace" = Just AgentEditWorkspace
parseAgentCapability "full-access" = Just AgentFullAccess
parseAgentCapability _ = Nothing

-- | The safety policy a job asks for, as opposed to what an operator
-- permits.
data AgentSafety = AgentSafety
  { -- | How much filesystem authority the run requests.
    capability :: !AgentCapability,
    -- | Optional narrowing of the provider's tool set. An empty list
    -- means \"do not restrict tools beyond what the capability
    -- implies\"; a non-empty list is rendered where the provider
    -- supports a tool allow-list.
    allowedTools :: ![Text],
    -- | Raw provider arguments Baikai does not model, passed through
    -- verbatim. This is a privileged channel: arbitrary vendor flags
    -- can widen authority in ways no capability profile can see, so an
    -- operator ceiling gates the channel as a whole. Nothing here
    -- inspects these strings for dangerous flags, and nothing should:
    -- flag spellings change, and a denylist that misses one provides
    -- false confidence rather than a security boundary.
    providerArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | A safety request for the given capability, with no tool narrowing
-- and no raw provider arguments.
agentSafety :: AgentCapability -> AgentSafety
agentSafety cap =
  AgentSafety
    { capability = cap,
      allowedTools = [],
      providerArgs = []
    }

-- | What Baikai does with the child process's output streams.
--
-- * 'InheritOutput': the child writes straight to the parent's own
--   streams and Baikai captures nothing.
-- * 'CaptureOutput': Baikai collects the bytes and the parent sees
--   nothing.
-- * 'TeeOutput': both.
data AgentOutputMode
  = InheritOutput
  | CaptureOutput
  | TeeOutput
  deriving stock (Eq, Ord, Show, Generic)

renderAgentOutputMode :: AgentOutputMode -> Text
renderAgentOutputMode InheritOutput = "inherit"
renderAgentOutputMode CaptureOutput = "capture"
renderAgentOutputMode TeeOutput = "tee"

-- | Parse a canonical output-mode name. Matching is exact and
-- case-sensitive.
parseAgentOutputMode :: Text -> Maybe AgentOutputMode
parseAgentOutputMode "inherit" = Just InheritOutput
parseAgentOutputMode "capture" = Just CaptureOutput
parseAgentOutputMode "tee" = Just TeeOutput
parseAgentOutputMode _ = Nothing

-- | One captured stream of a finished run. The three states are
-- distinct on purpose: under 'InheritOutput' the bytes went to the
-- parent's terminal and none exist to report, which an empty
-- 'ByteString' could not distinguish from a command that legitimately
-- printed nothing.
data AgentCapturedOutput
  = -- | The stream was not captured.
    OutputNotCaptured
  | -- | The stream was captured in full.
    OutputCaptured !ByteString
  | -- | The stream was captured up to the byte limit; more existed.
    OutputTruncated !ByteString
  deriving stock (Eq, Show, Generic)

-- | The captured bytes, if any were captured at all.
capturedBytes :: AgentCapturedOutput -> Maybe ByteString
capturedBytes OutputNotCaptured = Nothing
capturedBytes (OutputCaptured bytes) = Just bytes
capturedBytes (OutputTruncated bytes) = Just bytes

-- | Everything an unattended coding-agent run needs, expressed
-- provider-neutrally. This is the single source of truth for every
-- process-level setting: the working directory, the timeout, the output
-- discipline, the output limit, and the declared environment
-- variables.
data AgentRunRequest = AgentRunRequest
  { -- | Which coding-agent tool to run.
    provider :: !AgentProvider,
    -- | The instruction handed to the coding agent.
    prompt :: !Text,
    -- | Model override, or 'Nothing' to leave the tool's default.
    modelId :: !(Maybe Text),
    -- | Reasoning-effort override, or 'Nothing' to leave the tool's
    -- default.
    effort :: !(Maybe ThinkingLevel),
    -- | The directory the run is rooted in. Required, not optional:
    -- the safety contract is that a run gets no filesystem authority
    -- beyond this directory and 'extraDirs', and that sentence has no
    -- meaning if the root can be absent.
    workingDir :: !FilePath,
    -- | Directories this run may reach beyond 'workingDir'. The
    -- precise authority is provider-dependent: Claude Code's
    -- @--add-dir@ grants tool access, while @codex exec@'s @--add-dir@
    -- grants write access alongside the primary workspace.
    extraDirs :: ![FilePath],
    -- | The safety policy this job asks for.
    safety :: !AgentSafety,
    -- | Wall-clock limit for the whole run, or 'Nothing' for no limit.
    timeout :: !(Maybe NominalDiffTime),
    -- | What to do with the child's output streams.
    output :: !AgentOutputMode,
    -- | Maximum captured bytes per stream, not in total. 'Nothing'
    -- means unbounded.
    outputLimit :: !(Maybe Int),
    -- | Names of environment variables this job declares it requires.
    -- These are names only, never name\/value pairs, so the list
    -- cannot contain a secret by construction. It is not an allow-list
    -- and does not restrict the child's environment: the child
    -- inherits the parent's environment in full, because both coding
    -- agents need @HOME@, @PATH@, and their own credential files to
    -- function. What the list buys is a precondition check — a runner
    -- fails before spawning when a declared variable is unset or
    -- empty, so a misconfigured job produces one clear error instead
    -- of a coding agent that starts and then flails.
    envPassthrough :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | An unattended run of the given provider, rooted in the given
-- working directory, with the given prompt. Everything else defaults
-- to the least-authority, least-surprising value: no model or effort
-- override, no extra directories, read-only capability, no timeout,
-- inherited output, no output limit, and no declared environment
-- variables.
--
-- The capability default is 'AgentReadOnly': a caller who wants to
-- change files must say so. That is independent of an operator
-- ceiling, which says what a caller is /allowed/ to ask for.
agentRunRequest :: AgentProvider -> FilePath -> Text -> AgentRunRequest
agentRunRequest p dir userPrompt =
  AgentRunRequest
    { provider = p,
      prompt = userPrompt,
      modelId = Nothing,
      effort = Nothing,
      workingDir = dir,
      extraDirs = [],
      safety = agentSafety AgentReadOnly,
      timeout = Nothing,
      output = InheritOutput,
      outputLimit = Nothing,
      envPassthrough = []
    }

-- | The limit an operator places on what any job may request.
--
-- A job description can come from a repository the operator did not
-- write, which makes it untrusted input: it could ask for unlimited
-- filesystem access. A ceiling is a separate, operator-owned value
-- that bounds what any job may ask for, and 'applyAgentCeiling' is the
-- pure check.
data AgentCeiling = AgentCeiling
  { -- | The highest capability any job may request.
    maxCapability :: !AgentCapability,
    -- | Whether jobs may pass raw provider arguments at all. The whole
    -- channel is privileged, so it is permitted or refused as a unit
    -- rather than filtered.
    allowProviderArgs :: !Bool,
    -- | The providers jobs may select. An empty list permits __no__
    -- provider; it does not mean \"all providers\".
    allowedProviders :: ![AgentProvider]
  }
  deriving stock (Eq, Show, Generic)

-- | The ceiling in force when an operator has supplied no policy of
-- their own: a job may ask for read-only or edit-workspace authority,
-- may not ask for full access, and may not pass raw provider
-- arguments; both providers are permitted.
--
-- An edit-capable default is the only one under which a job that
-- changes files works on a fresh machine with no out-of-band setup,
-- while the two things that can widen authority without bound —
-- sandbox-bypassing modes and arbitrary vendor flags — stay opt-in at
-- operator scope.
defaultAgentCeiling :: AgentCeiling
defaultAgentCeiling =
  AgentCeiling
    { maxCapability = AgentEditWorkspace,
      allowProviderArgs = False,
      allowedProviders = [AgentClaude, AgentCodex]
    }

-- | One way a request exceeded a ceiling.
data CeilingViolation
  = -- | The requested capability, then the permitted maximum. The
    -- order matters: reversing the pair produces a message that blames
    -- the wrong side.
    CapabilityExceeded !AgentCapability !AgentCapability
  | -- | The raw provider arguments that were requested while the
    -- channel is closed, in the order given.
    --
    -- __Do not render these values.__ This is the one field of a job
    -- description an operator could write a credential into, which is
    -- why the configuration layer classifies it secret; a refusal
    -- message that quoted them would defeat that classification, so
    -- 'renderCeilingViolation' reports how many were requested and not
    -- what they were. The list is retained rather than reduced to a
    -- count because a programmatic caller may legitimately need to
    -- inspect it.
    ProviderArgsForbidden ![Text]
  | -- | The requested provider, then the permitted providers.
    ProviderForbidden !AgentProvider ![AgentProvider]
  deriving stock (Eq, Show, Generic)

-- | One line of plain English naming what was asked for and what is
-- permitted.
renderCeilingViolation :: CeilingViolation -> Text
renderCeilingViolation (CapabilityExceeded requested permitted) =
  "requested capability "
    <> renderAgentCapability requested
    <> " exceeds the permitted maximum "
    <> renderAgentCapability permitted
renderCeilingViolation (ProviderArgsForbidden args) =
  "raw provider arguments are not permitted; "
    <> Text.pack (show (length args))
    <> " requested, and their values are secret and are not shown"
renderCeilingViolation (ProviderForbidden requested permitted) =
  "provider "
    <> renderAgentProvider requested
    <> " is not permitted; permitted providers: "
    <> renderPermittedProviders permitted
  where
    renderPermittedProviders [] = "none"
    renderPermittedProviders ps = Text.intercalate ", " (map renderAgentProvider ps)

-- | Check a request against a ceiling. Returns the request
-- __unchanged__ when it is within the ceiling, and every violation
-- when it is not.
--
-- Two properties are deliberate. The request is never modified to fit
-- the ceiling: a job that asked for more authority than it may have is
-- an error to report, not a request to quietly weaken, because silent
-- clamping is how a job that believes it may edit ends up doing
-- nothing and reporting success. And every violation is collected
-- rather than only the first, so an operator fixing a job description
-- sees all of them in one run.
--
-- This function does not inspect the contents of the requested
-- 'providerArgs'. See that field's documentation for why a denylist of
-- dangerous flags would be false confidence rather than a boundary.
applyAgentCeiling :: AgentCeiling -> AgentRunRequest -> Either [CeilingViolation] AgentRunRequest
applyAgentCeiling limit request
  | null violations = Right request
  | otherwise = Left violations
  where
    requestedProvider = request ^. #provider
    permittedProviders = limit ^. #allowedProviders
    requestedCapability = request ^. #safety . #capability
    permittedCapability = limit ^. #maxCapability
    requestedArgs = request ^. #safety . #providerArgs
    violations =
      concat
        [ [ ProviderForbidden requestedProvider permittedProviders
          | requestedProvider `notElem` permittedProviders
          ],
          [ CapabilityExceeded requestedCapability permittedCapability
          | requestedCapability > permittedCapability
          ],
          [ ProviderArgsForbidden requestedArgs
          | not (null requestedArgs),
            not (limit ^. #allowProviderArgs)
          ]
        ]

-- | How the prompt reaches the child process.
data AgentPromptTransport
  = -- | The prompt is written to the child's standard input and
    -- appears nowhere in the argument vector.
    PromptOnStdin
  | -- | The prompt is already the final element of the argument
    -- vector, protected by the provider's @--@ separator, and the
    -- child gets no standard input at all.
    PromptAsArgument
  deriving stock (Eq, Ord, Show, Generic)

-- | A rendered provider command: the boundary value between a vendor
-- renderer, which produces it, and a process runner, which consumes
-- it. It lives in the core package so that neither side depends on the
-- other.
--
-- Honor 'promptTransport' exactly. @codex exec@ documents that a piped
-- standard input /and/ a positional prompt are both used, with
-- standard input appended as a @\<stdin\>@ block, so emitting both is
-- a silent corruption of the instruction. Making the transport an
-- explicit choice turns that hazard into a type-level distinction
-- rather than a convention.
--
-- This type deliberately carries no working directory. Claude Code has
-- no working-directory flag at all, so for one of the two providers the
-- working directory can only ever be a process-level setting; a runner
-- therefore reads it from 'AgentRunRequest' and takes both values.
-- Duplicating it here was rejected because two copies of a working
-- directory can disagree, and that disagreement would be a sandbox
-- escape rather than a cosmetic bug.
data AgentCommand = AgentCommand
  { -- | The program to run, either a bare name resolved on @PATH@ or
    -- an explicit path.
    executable :: !FilePath,
    -- | The rendered argument vector, excluding the program name.
    arguments :: ![String],
    -- | Where the prompt travels.
    promptTransport :: !AgentPromptTransport,
    -- | The prompt itself, for a runner that must write it to standard
    -- input.
    promptText :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | The process-level outcome of a finished unattended run. Read it
-- with @generic-lens@ labels, for example @result ^. #exitCode@.
--
-- A non-zero exit code is a normal result and lives here rather than
-- in a failure type: a coding agent that fails its task and exits 1
-- has still run.
data AgentRunResult = AgentRunResult
  { -- | Which coding-agent tool ran.
    provider :: !AgentProvider,
    -- | The child's exit status.
    exitCode :: !ExitCode,
    -- | The child's standard output, per the request's output mode.
    stdout :: !AgentCapturedOutput,
    -- | The child's standard error, per the request's output mode.
    stderr :: !AgentCapturedOutput,
    -- | How long the run took.
    duration :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | A result with both streams marked 'OutputNotCaptured'.
agentRunResult :: AgentProvider -> ExitCode -> NominalDiffTime -> AgentRunResult
agentRunResult p code elapsed =
  AgentRunResult
    { provider = p,
      exitCode = code,
      stdout = OutputNotCaptured,
      stderr = OutputNotCaptured,
      duration = elapsed
    }

-- | Everything one finished unattended run produced: what happened, and
-- the evidence the runner built for it.
--
-- The two are siblings rather than the evidence living inside
-- 'AgentRunResult', because the run that most needs a record is one that
-- did not produce a result. A run killed by its own timeout started, ran,
-- consumed tokens, and possibly changed the working tree, and it reports
-- @Left ('RunTimedOut' …)@ — so evidence hanging off the @Right@ would be
-- unreachable in exactly the case an operator most wants it.
--
-- 'evidence' is 'Nothing' in two situations that must not be confused.
-- The caller asked for none, which is the default and costs nothing. Or
-- nothing ever started — a missing working directory, an unset declared
-- environment variable, an executable that could not be spawned — and
-- there is no run to describe.
data AgentRunOutcome = AgentRunOutcome
  { outcome :: !(Either AgentRunFailure AgentRunResult),
    evidence :: !(Maybe ModelCallEvidence)
  }
  deriving stock (Eq, Show, Generic)

-- | An outcome carrying no evidence, for the paths where none was asked
-- for or none exists.
agentRunOutcome :: Either AgentRunFailure AgentRunResult -> AgentRunOutcome
agentRunOutcome result = AgentRunOutcome {outcome = result, evidence = Nothing}

-- | A refusal raised before any process is created: the requested
-- policy cannot be expressed honestly for the chosen provider, so the
-- run must not start.
--
-- Every constructor that reports an inexpressible policy carries a
-- human-readable explanation, because a refusal that does not say
-- /why/ is a dead end rather than an error an operator can act on.
data AgentRenderError
  = -- | The provider, the capability it cannot express, and why.
    UnsupportedCapability !AgentProvider !AgentCapability !Text
  | -- | The provider cannot honor a tool allow-list, and why.
    UnsupportedToolRestriction !AgentProvider !Text
  | -- | The general case: this provider cannot honor the requested
    -- safety policy, and why. It carries no capability, so it also
    -- serves surfaces whose safety vocabulary has no capability
    -- profile — notably the interactive launchers, which share this
    -- refusal type rather than growing a parallel one.
    SafetyNotExpressible !AgentProvider !Text
  | -- | The provider the renderer implements, then the provider the
    -- request named. Each vendor renderer is a separate function in a
    -- separate package, so nothing in the type system stops a caller
    -- from handing a Codex request to the Claude renderer; without
    -- this constructor the renderer's only options would be to
    -- silently render the wrong provider's flags or to throw. The
    -- order matters: reversing the pair names the wrong culprit.
    ProviderMismatch !AgentProvider !AgentProvider
  | -- | The request exceeded the operator's policy ceiling.
    CeilingRejected ![CeilingViolation]
  deriving stock (Eq, Show, Generic)

renderAgentRenderError :: AgentRenderError -> Text
renderAgentRenderError (UnsupportedCapability p cap why) =
  renderAgentProvider p
    <> " cannot express the requested capability "
    <> renderAgentCapability cap
    <> ": "
    <> why
renderAgentRenderError (UnsupportedToolRestriction p why) =
  renderAgentProvider p
    <> " cannot express the requested tool restriction: "
    <> why
renderAgentRenderError (SafetyNotExpressible p why) =
  renderAgentProvider p
    <> " cannot honor the requested safety policy: "
    <> why
renderAgentRenderError (ProviderMismatch renderer requested) =
  "the "
    <> renderAgentProvider renderer
    <> " renderer cannot render a request for provider "
    <> renderAgentProvider requested
renderAgentRenderError (CeilingRejected violations) =
  "the request exceeds the permitted policy ceiling: "
    <> Text.intercalate "; " (map renderCeilingViolation violations)

-- | What a run that hit its deadline left behind.
--
-- The limit is the one that was configured, not the slightly larger
-- elapsed time, because the caller asked for a limit and wants to be
-- told which one was hit.
--
-- The two streams are whatever was drained before the process group was
-- killed. A timed-out run is precisely the run an operator most wants to
-- read: the tool started, may have consumed tokens, and may already have
-- changed the working tree, and the bytes it printed on the way are the
-- only account of that. Under 'InheritOutput' those bytes went to the
-- parent's terminal and both fields are 'OutputNotCaptured'.
data AgentTimedOut = AgentTimedOut
  { -- | The configured limit the run exceeded.
    limit :: !NominalDiffTime,
    -- | Standard output drained before the group was killed.
    stdout :: !AgentCapturedOutput,
    -- | Standard error drained before the group was killed.
    stderr :: !AgentCapturedOutput
  }
  deriving stock (Eq, Show, Generic)

-- | A failure raised while spawning the child process or waiting for
-- it.
--
-- There is deliberately no constructor for \"the process exited
-- non-zero\". That is a normal outcome and lives in 'AgentRunResult':
-- a coding agent that fails its task and exits 1 has still run.
data AgentRunFailure
  = -- | The executable that could not be started, and the operating
    -- system's message. The pair is what distinguishes \"the tool is
    -- not installed\" from \"the tool is installed but the working
    -- directory does not exist\".
    SpawnFailed !FilePath !Text
  | -- | The run exceeded its limit. Its whole process group was
    -- interrupted, then terminated, then killed; what each stream
    -- drained before the kill is carried along.
    RunTimedOut !AgentTimedOut
  | -- | Every variable named in the request's 'envPassthrough' that is
    -- unset or empty, checked as a group so an operator sees all of
    -- them at once.
    MissingEnvironment ![Text]
  | -- | The working directory does not exist or is not a directory.
    WorkingDirMissing !FilePath
  | -- | The run produced output the caller could not interpret.
    OutputMalformed !Text
  | -- | The caller required evidence this configuration cannot produce,
    -- so nothing was started. Carries one rendered explanation per
    -- reason, from
    -- 'Baikai.Evidence.Build.renderEvidenceRefusal'.
    --
    -- Structural rather than predictive: it fires when the requirement
    -- is /impossible/ here, never when it merely might not be met. A run
    -- that could have reported what the caller needed and did not says
    -- so in its own record's @strength@; refusing it after the fact
    -- would destroy a report of work that actually happened.
    EvidenceRefused ![Text]
  deriving stock (Eq, Show, Generic)

renderAgentRunFailure :: AgentRunFailure -> Text
renderAgentRunFailure (SpawnFailed path message) =
  "could not start " <> Text.pack path <> ": " <> message
renderAgentRunFailure (RunTimedOut timedOut) =
  "the run exceeded its timeout of " <> Text.pack (show (timedOut ^. #limit))
renderAgentRunFailure (MissingEnvironment names) =
  "required environment variables are unset or empty: "
    <> Text.intercalate ", " names
renderAgentRunFailure (WorkingDirMissing path) =
  "the working directory does not exist or is not a directory: "
    <> Text.pack path
renderAgentRunFailure (OutputMalformed why) =
  "the run produced malformed output: " <> why
renderAgentRunFailure (EvidenceRefused reasons) =
  "refused before starting, because this run cannot produce the evidence it \
  \required: "
    <> Text.intercalate "; " reasons
