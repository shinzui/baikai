-- | Provider-neutral types for launching local interactive agent
-- CLIs such as Claude Code and Codex.
--
-- This module deliberately does not implement process spawning.
-- The core package owns the shared vocabulary, while vendor
-- packages own the command-line flags for their local CLI.
module Baikai.Interactive
  ( InteractiveProvider (..),
    InteractiveScope (..),
    InteractiveLaunchRequest (..),
    InteractiveSafety (..),
    CodexSandboxMode (..),
    CodexApprovalPolicy (..),
    InteractiveLaunchResult (..),
    _InteractiveLaunchRequest,
    _InteractiveLaunchResult,
    renderInteractiveProvider,
    renderInteractiveScope,
    renderCodexSandboxMode,
    renderCodexApprovalPolicy,
  )
where

import Baikai.Prelude
import System.Exit (ExitCode)

-- | Local interactive provider families that Baikai knows how to
-- describe without depending on a vendor package.
data InteractiveProvider
  = InteractiveClaude
  | InteractiveCodex
  deriving stock (Eq, Ord, Show, Generic)

-- | Scope for provider-native assets and configuration. User scope
-- means the provider's home-directory location. Project scope means
-- a location under the working project.
data InteractiveScope
  = InteractiveUserScope
  | InteractiveProjectScope
  deriving stock (Eq, Ord, Show, Generic)

-- | Inputs common to local interactive agent launches.
data InteractiveLaunchRequest = InteractiveLaunchRequest
  { systemPrompt :: !(Maybe Text),
    userPrompt :: !Text,
    model :: !(Maybe Text),
    workingDir :: !(Maybe FilePath),
    extraDirs :: ![FilePath],
    safety :: !InteractiveSafety,
    extraArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

-- | Safety configuration expressed in the shared core vocabulary.
-- Vendor launchers translate the selected branch into their CLI's
-- concrete flags.
data InteractiveSafety
  = DefaultSafety
  | ClaudeAllowedTools [Text]
  | CodexSandbox CodexSandboxMode CodexApprovalPolicy
  deriving stock (Eq, Ord, Show, Generic)

data CodexSandboxMode
  = CodexReadOnly
  | CodexWorkspaceWrite
  | CodexDangerFullAccess
  deriving stock (Eq, Ord, Show, Generic)

data CodexApprovalPolicy
  = CodexApprovalUntrusted
  | CodexApprovalOnFailure
  | CodexApprovalOnRequest
  | CodexApprovalNever
  deriving stock (Eq, Ord, Show, Generic)

-- | Process-level outcome after the interactive CLI exits.
data InteractiveLaunchResult = InteractiveLaunchResult
  { provider :: !InteractiveProvider,
    exitCode :: !ExitCode
  }
  deriving stock (Eq, Show, Generic)

_InteractiveLaunchRequest :: Text -> InteractiveLaunchRequest
_InteractiveLaunchRequest prompt =
  InteractiveLaunchRequest
    { systemPrompt = Nothing,
      userPrompt = prompt,
      model = Nothing,
      workingDir = Nothing,
      extraDirs = [],
      safety = DefaultSafety,
      extraArgs = []
    }

_InteractiveLaunchResult :: InteractiveProvider -> ExitCode -> InteractiveLaunchResult
_InteractiveLaunchResult p code =
  InteractiveLaunchResult
    { provider = p,
      exitCode = code
    }

renderInteractiveProvider :: InteractiveProvider -> Text
renderInteractiveProvider InteractiveClaude = "claude"
renderInteractiveProvider InteractiveCodex = "codex"

renderInteractiveScope :: InteractiveScope -> Text
renderInteractiveScope InteractiveUserScope = "user"
renderInteractiveScope InteractiveProjectScope = "project"

renderCodexSandboxMode :: CodexSandboxMode -> Text
renderCodexSandboxMode CodexReadOnly = "read-only"
renderCodexSandboxMode CodexWorkspaceWrite = "workspace-write"
renderCodexSandboxMode CodexDangerFullAccess = "danger-full-access"

renderCodexApprovalPolicy :: CodexApprovalPolicy -> Text
renderCodexApprovalPolicy CodexApprovalUntrusted = "untrusted"
renderCodexApprovalPolicy CodexApprovalOnFailure = "on-failure"
renderCodexApprovalPolicy CodexApprovalOnRequest = "on-request"
renderCodexApprovalPolicy CodexApprovalNever = "never"
