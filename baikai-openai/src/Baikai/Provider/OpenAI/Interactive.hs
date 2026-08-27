-- | Launch real interactive Codex sessions from Baikai's
-- provider-neutral interactive request type.
--
-- This module is intentionally separate from
-- "Baikai.Provider.OpenAI.Cli": that module drives @codex exec@ as a
-- batch completion provider, while this module starts the interactive
-- terminal UI and returns only after the CLI exits.
--
-- A safety policy Codex cannot express is refused before launch rather
-- than dropped: both the pure command builder and the launcher return
-- 'Either' 'AgentRenderError', and a 'Left' means no process was
-- started. Two things are refused: a tool allow-list, which Codex has no
-- flag for at all, and an approval policy the installed @codex@
-- generation does not accept — 'CodexApprovalUntrusted' and
-- 'CodexApprovalOnFailure', which are older spellings current releases
-- reject.
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

import Baikai.Agent (AgentProvider (..), AgentRenderError (..))
import Baikai.Interactive
  ( CodexApprovalPolicy (..),
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
--
-- Returns 'Left' when the request's safety policy is one Codex cannot
-- express, so a caller who asked to be constrained never receives a
-- command that is not.
codexInteractiveCommand ::
  CodexInteractiveConfig ->
  InteractiveLaunchRequest ->
  Either AgentRenderError (FilePath, [String])
codexInteractiveCommand cfg req = do
  safety <- safetyArgs req
  pure
    ( cfg ^. #executable,
      modelArgs req
        <> effortArgs req
        <> workingDirArgs req
        <> extraDirArgs req
        <> safety
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
--
-- A 'Left' result means no process was started: the requested safety
-- policy was refused before launch. A 'Right' carrying a non-zero
-- 'System.Exit.ExitCode' means the session ran and exited non-zero.
launchCodexInteractive ::
  CodexInteractiveConfig ->
  InteractiveLaunchRequest ->
  IO (Either AgentRenderError InteractiveLaunchResult)
launchCodexInteractive cfg req = case codexInteractiveCommand cfg req of
  Left err -> pure (Left err)
  Right (exe, args) -> do
    let spec =
          (P.proc exe args)
            { P.std_in = P.Inherit,
              P.std_out = P.Inherit,
              P.std_err = P.Inherit,
              P.cwd = req ^. #workingDir
            }
    code <- P.withCreateProcess spec (\_ _ _ ph -> P.waitForProcess ph)
    pure (Right (interactiveLaunchResult InteractiveCodex code))

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

-- | 'DefaultSafety' means the caller declined to specify a policy, so
-- rendering nothing honors it rather than downgrading it.
safetyArgs :: InteractiveLaunchRequest -> Either AgentRenderError [String]
safetyArgs req = case req ^. #safety of
  DefaultSafety -> Right []
  CodexSandbox sandbox approval
    | approvalAccepted approval -> Right (codexSafetyArgs sandbox approval)
    | otherwise ->
        Left
          ( SafetyNotExpressible
              AgentCodex
              ( "the installed codex CLI accepts only on-request and never for \
                \--ask-for-approval (codex 0.149.1); it rejects "
                  <> renderCodexApprovalPolicy approval
                  <> ", so the session was not started; use CodexApprovalOnRequest or \
                     \CodexApprovalNever"
              )
          )
  -- An empty allow-list restricts nothing, so there is nothing Codex
  -- fails to honor. Only a non-empty list is a restriction Codex
  -- cannot express. The asymmetry with the next case is deliberate.
  ClaudeAllowedTools [] -> Right []
  ClaudeAllowedTools tools ->
    Left
      ( SafetyNotExpressible
          AgentCodex
          ( "Codex has no tool allow-list flag, so it cannot honor the requested tools ("
              <> Text.intercalate ", " tools
              <> "); use CodexSandbox to restrict Codex, or DefaultSafety to accept its own \
                 \default"
          )
      )

-- | Whether the installed @codex@ generation accepts this approval
-- policy.
--
-- @codex --help@ at @codex-cli 0.149.1@ (verified 2026-08-27) lists
-- exactly two possible values for @--ask-for-approval@, @on-request@ and
-- @never@. @untrusted@ and @on-failure@ are older spellings the CLI
-- rejects with a usage error, which would surface as a @Right@ carrying
-- a non-zero exit code — a session that ran and failed — rather than as
-- the refusal this module promises.
--
-- Refused rather than quietly mapped onto @on-request@: silently
-- substituting a different approval policy would change the very thing
-- the caller asked for, which is the failure this module exists to
-- prevent. Which values the installed tool accepts is the vendor
-- adapter's knowledge, which is why the check lives here and not in the
-- core vocabulary.
approvalAccepted :: CodexApprovalPolicy -> Bool
approvalAccepted = \case
  CodexApprovalOnRequest -> True
  CodexApprovalNever -> True
  CodexApprovalUntrusted -> False
  CodexApprovalOnFailure -> False

codexSafetyArgs :: CodexSandboxMode -> CodexApprovalPolicy -> [String]
codexSafetyArgs sandbox approval =
  [ "--sandbox",
    Text.unpack (renderCodexSandboxMode sandbox),
    "--ask-for-approval",
    Text.unpack (renderCodexApprovalPolicy approval)
  ]
