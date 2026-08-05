-- | Launch real interactive Claude Code sessions from Baikai's
-- provider-neutral interactive request type.
--
-- This module is intentionally separate from
-- "Baikai.Provider.Claude.Cli": that module drives @claude -p@ as a
-- batch completion provider, while this module starts the interactive
-- terminal UI and returns only after the CLI exits.
--
-- A safety policy Claude Code cannot express is refused before launch
-- rather than dropped: both the pure command builder and the launcher
-- return 'Either' 'AgentRenderError', and a 'Left' means no process was
-- started.
module Baikai.Provider.Claude.Interactive
  ( ClaudeInteractiveConfig,
    executable,
    extraArgs,
    defaultClaudeInteractiveConfig,
    claudeInteractiveCommand,
    launchClaudeInteractive,
  )
where

import Baikai.Agent (AgentProvider (..), AgentRenderError (..))
import Baikai.Interactive
  ( InteractiveLaunchRequest,
    InteractiveLaunchResult,
    InteractiveProvider (..),
    InteractiveSafety (..),
    interactiveLaunchResult,
    renderCodexApprovalPolicy,
    renderCodexSandboxMode,
  )
import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Cradle (addArgs, cmd, run, setWorkingDir)
import Data.Generics.Labels ()
import Data.Text qualified as Text

-- | Configuration for the interactive @claude@ process.
data ClaudeInteractiveConfig = ClaudeInteractiveConfig
  { executable :: !FilePath,
    extraArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeInteractiveConfig :: ClaudeInteractiveConfig
defaultClaudeInteractiveConfig =
  ClaudeInteractiveConfig
    { executable = "claude",
      extraArgs = mempty
    }

-- | Render the executable and arguments for an interactive Claude
-- Code launch. The final positional argument is the initial user
-- prompt. The prompt is preceded by @--@ because Claude's
-- @--allowedTools@ and @--add-dir@ flags are variadic.
--
-- Returns 'Left' when the request's safety policy is one Claude Code
-- cannot express, so a caller who asked to be constrained never
-- receives a command that is not.
claudeInteractiveCommand ::
  ClaudeInteractiveConfig ->
  InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
claudeInteractiveCommand cfg req = do
  safety <- safetyArgs req
  pure
    ( cfg ^. #executable,
      modelArgs req
        <> effortArgs req
        <> systemPromptArgs req
        <> extraDirArgs req
        <> safety
        <> fmap Text.unpack (cfg ^. #extraArgs)
        <> fmap Text.unpack (req ^. #extraArgs)
        <> ["--", Text.unpack (req ^. #userPrompt)]
    )

-- | Launch Claude Code with inherited stdin, stdout, and stderr so
-- the local CLI owns the interactive terminal experience.
--
-- A 'Left' result means no process was started: the requested safety
-- policy was refused before launch. A 'Right' carrying a non-zero
-- 'System.Exit.ExitCode' means the session ran and exited non-zero.
launchClaudeInteractive ::
  ClaudeInteractiveConfig ->
  InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
launchClaudeInteractive cfg req = case claudeInteractiveCommand cfg req of
  Left err -> pure (Left err)
  Right (exe, args) -> do
    code <-
      run $
        cmd exe
          & addArgs args
          & maybe id setWorkingDir (req ^. #workingDir)
    pure (Right (interactiveLaunchResult InteractiveClaude code))

modelArgs :: InteractiveLaunchRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #modelId of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

-- | Claude's @--effort@ accepts @low|medium|high|xhigh|max@, but
-- not @minimal@, so the lowest Baikai level maps up to @low@.
effortArgs :: InteractiveLaunchRequest -> [String]
effortArgs req = case req ^. #effort of
  Nothing -> []
  Just lvl -> ["--effort", Text.unpack (claudeEffortValue lvl)]

claudeEffortValue :: ThinkingLevel -> Text
claudeEffortValue ThinkingMinimal = "low"
claudeEffortValue lvl = renderThinkingLevel lvl

systemPromptArgs :: InteractiveLaunchRequest -> [String]
systemPromptArgs req = case Text.strip <$> req ^. #systemPrompt of
  Nothing -> []
  Just "" -> []
  Just prompt -> ["--system-prompt", Text.unpack prompt]

extraDirArgs :: InteractiveLaunchRequest -> [String]
extraDirArgs req =
  concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)

-- | 'DefaultSafety' means the caller declined to specify a policy, so
-- rendering nothing honors it rather than downgrading it. An empty
-- allow-list restricts nothing, so it too renders nothing. Only a
-- Codex sandbox policy is a restriction Claude Code cannot express,
-- and that is refused.
safetyArgs :: InteractiveLaunchRequest -> Either AgentRenderError [String]
safetyArgs req = case req ^. #safety of
  DefaultSafety -> Right []
  ClaudeAllowedTools [] -> Right []
  ClaudeAllowedTools tools ->
    Right ["--allowedTools", Text.unpack (Text.intercalate "," tools)]
  CodexSandbox sandbox approval ->
    Left
      ( SafetyNotExpressible
          AgentClaude
          ( "Claude Code cannot express a Codex sandbox policy ("
              <> renderCodexSandboxMode sandbox
              <> ", "
              <> renderCodexApprovalPolicy approval
              <> "); use ClaudeAllowedTools, or DefaultSafety to accept Claude's own default"
          )
      )
