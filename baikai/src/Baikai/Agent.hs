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

    -- * The rendered command
    AgentPromptTransport (..),
    AgentCommand (..),

    -- * The run result
    AgentRunResult,
    agentRunResult,
  )
where

import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel)
import Data.ByteString (ByteString)
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
-- 'Ord' instance derived from that order is what
-- 'Baikai.Agent.applyAgentCeiling' compares against an operator's
-- permitted maximum — do not reorder them.
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
