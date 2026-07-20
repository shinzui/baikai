-- | Launch real interactive Codex sessions from Baikai's
-- provider-neutral interactive request type.
--
-- This module is intentionally separate from
-- "Baikai.Provider.OpenAI.Cli": that module drives @codex exec@ as a
-- batch completion provider, while this module starts the interactive
-- terminal UI and returns only after the CLI exits.
module Baikai.Provider.OpenAI.Interactive
  ( CodexInteractiveConfig,
    executable,
    extraArgs,
    defaultCodexInteractiveConfig,
    codexInteractiveCommand,
    codexInteractivePrompt,
    launchCodexInteractive,
  )
where

import Baikai.Interactive
  ( CodexApprovalPolicy,
    CodexSandboxMode,
    InteractiveLaunchRequest,
    InteractiveLaunchResult,
    InteractiveProvider (..),
    InteractiveSafety (..),
    interactiveLaunchResult,
    renderCodexApprovalPolicy,
    renderCodexSandboxMode,
  )
import Baikai.Prelude
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.ThinkingLevel (renderThinkingLevel)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import System.Process qualified as P

-- | Configuration for the interactive @codex@ process.
data CodexInteractiveConfig = CodexInteractiveConfig
  { executable :: !FilePath,
    extraArgs :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

defaultCodexInteractiveConfig :: CodexInteractiveConfig
defaultCodexInteractiveConfig =
  CodexInteractiveConfig
    { executable = "codex",
      extraArgs = mempty
    }

-- | Render the executable and arguments for an interactive Codex
-- launch. The final positional argument is the initial prompt.
codexInteractiveCommand ::
  CodexInteractiveConfig -> InteractiveLaunchRequest -> (FilePath, [String])
codexInteractiveCommand cfg req =
  ( cfg ^. #executable,
    modelArgs req
      <> effortArgs req
      <> workingDirArgs req
      <> extraDirArgs req
      <> safetyArgs req
      <> fmap Text.unpack (cfg ^. #extraArgs)
      <> fmap Text.unpack (req ^. #extraArgs)
      <> ["--", Text.unpack (codexInteractivePrompt req)]
  )

-- | Codex does not currently expose a top-level interactive
-- system-prompt flag. Preserve Baikai's request shape by placing the
-- system prompt before the user prompt in the initial prompt text.
codexInteractivePrompt :: InteractiveLaunchRequest -> Text
codexInteractivePrompt req =
  Internal.wrapSystemPrompt (req ^. #systemPrompt) (req ^. #userPrompt)

-- | Launch Codex with inherited stdin, stdout, and stderr so the
-- local CLI owns the interactive terminal experience.
launchCodexInteractive ::
  CodexInteractiveConfig -> InteractiveLaunchRequest -> IO InteractiveLaunchResult
launchCodexInteractive cfg req = do
  let (exe, args) = codexInteractiveCommand cfg req
      spec =
        (P.proc exe args)
          { P.std_in = P.Inherit,
            P.std_out = P.Inherit,
            P.std_err = P.Inherit,
            P.cwd = req ^. #workingDir
          }
  code <- P.withCreateProcess spec (\_ _ _ ph -> P.waitForProcess ph)
  pure (interactiveLaunchResult InteractiveCodex code)

modelArgs :: InteractiveLaunchRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #modelId of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

-- | Codex receives reasoning effort through a config override. The
-- provider-only @none@ and @ultra@ values remain available through
-- raw extra arguments.
effortArgs :: InteractiveLaunchRequest -> [String]
effortArgs req = case req ^. #effort of
  Nothing -> []
  Just lvl ->
    ["-c", "model_reasoning_effort=" <> Text.unpack (renderThinkingLevel lvl)]

workingDirArgs :: InteractiveLaunchRequest -> [String]
workingDirArgs req = case req ^. #workingDir of
  Nothing -> []
  Just dir -> ["--cd", dir]

extraDirArgs :: InteractiveLaunchRequest -> [String]
extraDirArgs req =
  concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)

safetyArgs :: InteractiveLaunchRequest -> [String]
safetyArgs req = case req ^. #safety of
  CodexSandbox sandbox approval -> codexSafetyArgs sandbox approval
  DefaultSafety -> []
  ClaudeAllowedTools _ -> []

codexSafetyArgs :: CodexSandboxMode -> CodexApprovalPolicy -> [String]
codexSafetyArgs sandbox approval =
  [ "--sandbox",
    Text.unpack (renderCodexSandboxMode sandbox),
    "--ask-for-approval",
    Text.unpack (renderCodexApprovalPolicy approval)
  ]
