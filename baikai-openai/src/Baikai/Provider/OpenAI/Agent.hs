-- | Render the argument vector for an __unattended__ Codex run from
-- Baikai's provider-neutral unattended request type.
--
-- This module is intentionally separate from the other two Codex
-- surfaces. "Baikai.Provider.OpenAI.Cli" drives @codex exec --json@ as
-- a batch completion provider and returns a parsed response.
-- "Baikai.Provider.OpenAI.Interactive" starts the interactive terminal
-- UI and returns when the human quits. This module describes a run with
-- no terminal and no human, whose deliverable is the changed working
-- tree.
--
-- Every function here is pure: nothing is spawned, and the prompt is
-- carried as data rather than as an argument. A policy @codex exec@
-- cannot express is refused with an 'AgentRenderError' before a process
-- would ever be created — notably a tool allow-list, for which Codex
-- has no flag at all.
module Baikai.Provider.OpenAI.Agent
  ( CodexAgentConfig (executable, extraArgs, skipGitRepoCheck, ephemeral),
    defaultCodexAgentConfig,
    codexAgentCommand,
    codexAgentThinking,
  )
where

import Baikai.Agent
  ( AgentCapability (..),
    AgentCommand (..),
    AgentPromptTransport (..),
    AgentProvider (..),
    AgentRenderError (..),
    AgentRunRequest,
  )
import Baikai.Evidence
  ( ThinkingAdjustment (..),
    ThinkingMode (..),
    ThinkingTranslation (..),
    noThinkingRequested,
  )
import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel, renderThinkingLevel)
import Data.Generics.Labels ()
import Data.Text qualified as Text

-- | Configuration for the unattended @codex@ process.
data CodexAgentConfig = CodexAgentConfig
  { -- | The program to run, either a bare name resolved on @PATH@ or
    -- an explicit path.
    executable :: !FilePath,
    -- | Raw provider defaults an application always wants. Rendered
    -- after every structured flag and before the request's own raw
    -- arguments.
    extraArgs :: ![Text],
    -- | Whether to emit @--skip-git-repo-check@. Defaults to 'True' so
    -- an unattended run works outside a Git repository.
    skipGitRepoCheck :: !Bool,
    -- | Whether to emit @--ephemeral@. Defaults to 'True' so the run
    -- leaves no session files behind.
    ephemeral :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultCodexAgentConfig :: CodexAgentConfig
defaultCodexAgentConfig =
  CodexAgentConfig
    { executable = "codex",
      extraArgs = mempty,
      skipGitRepoCheck = True,
      ephemeral = True
    }

-- | Render the executable, argument vector, and prompt transport for an
-- unattended Codex run, or refuse the request.
--
-- The prompt appears nowhere in the argument vector: the transport is
-- 'PromptOnStdin'. That is not merely convenient here — @codex exec@
-- documents that if standard input is piped /and/ a positional prompt
-- is supplied, standard input is appended as a @\<stdin\>@ block, so
-- emitting both would silently corrupt the instruction.
--
-- Long flag spellings are used throughout, @--sandbox@ and @--cd@
-- rather than @-s@ and @-C@, because the rendered vector is printed to
-- operators and a long flag is self-describing.
-- The second half of the pair describes what the request's reasoning
-- effort became on that command line. The runner cannot derive it — it
-- never imports a vendor renderer — so it travels alongside the command.
codexAgentCommand ::
  CodexAgentConfig ->
  AgentRunRequest ->
  Either AgentRenderError (AgentCommand, ThinkingTranslation)
codexAgentCommand cfg req
  | req ^. #provider /= AgentCodex =
      Left (ProviderMismatch AgentCodex (req ^. #provider))
  | otherwise = do
      toolRestrictionGuard req
      sandbox <- sandboxArgs (req ^. #safety . #capability)
      pure
        ( AgentCommand
            { executable = cfg ^. #executable,
              arguments =
                ["exec"]
                  <> modelArgs req
                  <> effortArgs req
                  <> sandbox
                  <> ["--cd", req ^. #workingDir]
                  <> extraDirArgs req
                  <> ["--skip-git-repo-check" | cfg ^. #skipGitRepoCheck]
                  <> ["--ephemeral" | cfg ^. #ephemeral]
                  <> fmap Text.unpack (cfg ^. #extraArgs)
                  <> fmap Text.unpack (req ^. #safety . #providerArgs),
              promptTransport = PromptOnStdin,
              promptText = req ^. #prompt
            },
          codexAgentThinking req
        )

-- | What the request's reasoning effort became on the @codex exec@
-- command line.
--
-- The adjustment list is derived by comparing what 'effortArgs' actually
-- sends — through the same 'codexEffortValue' — with the canonical level
-- name, rather than being hardcoded empty. It is empty at every level,
-- because codex is the one tool baikai drives that accepts all six
-- verbatim; writing @[]@ by hand would keep claiming that after someone
-- changed the mapping.
--
-- A request with no effort at all yields 'noThinkingRequested', which is
-- a different fact from a request whose level the tool weakened.
codexAgentThinking :: AgentRunRequest -> ThinkingTranslation
codexAgentThinking req = case req ^. #effort of
  Nothing -> noThinkingRequested
  Just lvl ->
    let wire = codexEffortValue lvl
     in ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeFlag,
            effortText = Just wire,
            budgetTokens = Nothing,
            wireField = Just "model_reasoning_effort",
            adjustments = [EffortClamped lvl wire | wire /= renderThinkingLevel lvl]
          }

-- | Map a capability profile onto @codex exec@'s @--sandbox@. Kept an
-- 'Either' for the same reason as the Claude renderer's permission-mode
-- mapping: an unmappable capability must be refused, never
-- approximated.
sandboxArgs :: AgentCapability -> Either AgentRenderError [String]
sandboxArgs = \case
  AgentReadOnly -> Right ["--sandbox", "read-only"]
  AgentEditWorkspace -> Right ["--sandbox", "workspace-write"]
  AgentFullAccess -> Right ["--sandbox", "danger-full-access"]

-- | @codex exec@ has no tool allow-list flag, so a request that names
-- tool grants is refused rather than run without them. A caller who
-- granted a tool set and gets a run that ignores the list has been given
-- something other than what they asked for, which is the silent
-- substitution this surface exists to prevent. The message names the
-- alternative so the error is actionable.
--
-- The operator's ceiling runs first, so a job that both grants a tool
-- the operator forbids /and/ selects Codex hears about the policy
-- problem — the one the operator can fix — rather than this one.
toolRestrictionGuard :: AgentRunRequest -> Either AgentRenderError ()
toolRestrictionGuard req = case req ^. #safety . #allowedTools of
  [] -> Right ()
  _ ->
    Left
      ( UnsupportedToolRestriction
          AgentCodex
          "codex exec has no tool allow-list flag; restrict Codex with a narrower \
          \sandbox mode, or pass an explicit provider argument if your operator \
          \policy permits raw arguments"
      )

-- | A blank model value must not produce @--model ""@.
modelArgs :: AgentRunRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #modelId of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

-- | Codex receives reasoning effort through a config override and
-- accepts all six canonical Baikai levels, so there is no clamp here —
-- unlike Claude, whose @--effort@ has no @minimal@ value. The
-- provider-only @none@ and @ultra@ values remain available through raw
-- provider arguments.
effortArgs :: AgentRunRequest -> [String]
effortArgs req = case req ^. #effort of
  Nothing -> []
  Just lvl ->
    ["-c", "model_reasoning_effort=" <> Text.unpack (codexEffortValue lvl)]

-- | The word codex's @model_reasoning_effort@ override receives. Codex
-- accepts all six baikai levels verbatim, which makes this the identity.
codexEffortValue :: ThinkingLevel -> Text
codexEffortValue = renderThinkingLevel

-- | On @codex exec@ @--add-dir@ grants /write/ access alongside the
-- primary workspace. The identically named Claude Code flag grants tool
-- /access/, so the shared @extraDirs@ field means "directories this run
-- may reach" and the precise authority is provider-dependent.
extraDirArgs :: AgentRunRequest -> [String]
extraDirArgs req =
  concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)
