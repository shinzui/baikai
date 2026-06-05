-- | Launch real interactive Codex sessions from Baikai's
-- provider-neutral interactive request type.
--
-- This module is intentionally separate from
-- "Baikai.Provider.OpenAI.Cli": that module drives @codex exec@ as a
-- batch completion provider, while this module starts the interactive
-- terminal UI and returns only after the CLI exits.
module Baikai.Provider.OpenAI.Interactive
  ( CodexInteractiveConfig (..),
    defaultCodexInteractiveConfig,
    codexInteractiveCommand,
    codexInteractivePrompt,
    launchCodexInteractive,
  )
where

import Baikai.Interactive
  ( CodexApprovalPolicy,
    CodexSandboxMode,
    InteractiveLaunchRequest (..),
    InteractiveLaunchResult,
    InteractiveProvider (..),
    InteractiveSafety (..),
    renderCodexApprovalPolicy,
    renderCodexSandboxMode,
    _InteractiveLaunchResult,
  )
import Baikai.Prelude
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Process qualified as P

-- | Configuration for the interactive @codex@ process.
data CodexInteractiveConfig = CodexInteractiveConfig
  { executable :: !FilePath,
    extraArgs :: !(Vector Text)
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
      <> workingDirArgs req
      <> extraDirArgs req
      <> safetyArgs req
      <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
      <> fmap Text.unpack (req ^. #extraArgs)
      <> [Text.unpack (codexInteractivePrompt req)]
  )

-- | Codex does not currently expose a top-level interactive
-- system-prompt flag. Preserve Baikai's request shape by placing the
-- system prompt before the user prompt in the initial prompt text.
codexInteractivePrompt :: InteractiveLaunchRequest -> Text
codexInteractivePrompt req = case Text.strip <$> req ^. #systemPrompt of
  Nothing -> req ^. #userPrompt
  Just "" -> req ^. #userPrompt
  Just prompt ->
    Text.concat
      [ "System instructions:\n",
        prompt,
        "\n\nUser request:\n",
        req ^. #userPrompt
      ]

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
  (_, _, _, ph) <- P.createProcess spec
  code <- P.waitForProcess ph
  pure (_InteractiveLaunchResult InteractiveCodex code)

modelArgs :: InteractiveLaunchRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #model of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

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
