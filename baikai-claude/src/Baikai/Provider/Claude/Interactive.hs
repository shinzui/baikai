-- | Launch real interactive Claude Code sessions from Baikai's
-- provider-neutral interactive request type.
--
-- This module is intentionally separate from
-- "Baikai.Provider.Claude.Cli": that module drives @claude -p@ as a
-- batch completion provider, while this module starts the interactive
-- terminal UI and returns only after the CLI exits.
module Baikai.Provider.Claude.Interactive
  ( ClaudeInteractiveConfig,
    executable,
    extraArgs,
    defaultClaudeInteractiveConfig,
    claudeInteractiveCommand,
    launchClaudeInteractive,
  )
where

import Baikai.Interactive
  ( InteractiveLaunchRequest,
    InteractiveLaunchResult,
    InteractiveProvider (..),
    InteractiveSafety (..),
    interactiveLaunchResult,
  )
import Baikai.Prelude
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
claudeInteractiveCommand ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])
claudeInteractiveCommand cfg req =
  ( cfg ^. #executable,
    modelArgs req
      <> systemPromptArgs req
      <> extraDirArgs req
      <> safetyArgs req
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> fmap Text.unpack (req ^. #extraArgs)
      <> ["--", Text.unpack (req ^. #userPrompt)]
  )

-- | Launch Claude Code with inherited stdin, stdout, and stderr so
-- the local CLI owns the interactive terminal experience.
launchClaudeInteractive ::
  ClaudeInteractiveConfig -> InteractiveLaunchRequest -> IO InteractiveLaunchResult
launchClaudeInteractive cfg req = do
  let (exe, args) = claudeInteractiveCommand cfg req
  code <-
    run $
      cmd exe
        & addArgs args
        & maybe id setWorkingDir (req ^. #workingDir)
  pure (interactiveLaunchResult InteractiveClaude code)

modelArgs :: InteractiveLaunchRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #modelId of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

systemPromptArgs :: InteractiveLaunchRequest -> [String]
systemPromptArgs req = case Text.strip <$> req ^. #systemPrompt of
  Nothing -> []
  Just "" -> []
  Just prompt -> ["--system-prompt", Text.unpack prompt]

extraDirArgs :: InteractiveLaunchRequest -> [String]
extraDirArgs req =
  concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)

safetyArgs :: InteractiveLaunchRequest -> [String]
safetyArgs req = case req ^. #safety of
  ClaudeAllowedTools [] -> []
  ClaudeAllowedTools tools ->
    ["--allowedTools", Text.unpack (Text.intercalate "," tools)]
  DefaultSafety -> []
  CodexSandbox _ _ -> []
