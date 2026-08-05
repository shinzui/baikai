-- | Render the argument vector for an __unattended__ Claude Code run
-- from Baikai's provider-neutral unattended request type.
--
-- This module is intentionally separate from the other two Claude
-- surfaces. "Baikai.Provider.Claude.Cli" drives @claude -p@ as a batch
-- completion provider and returns a parsed response.
-- "Baikai.Provider.Claude.Interactive" starts the interactive terminal
-- UI and returns when the human quits. This module describes a run with
-- no terminal and no human, whose deliverable is the changed working
-- tree.
--
-- Every function here is pure: nothing is spawned, and the prompt is
-- carried as data rather than as an argument. A policy Claude Code
-- cannot express is refused with an 'AgentRenderError' before a process
-- would ever be created; it is never approximated with a near-miss
-- flag.
module Baikai.Provider.Claude.Agent
  ( ClaudeAgentConfig (executable, extraArgs, persistSession),
    defaultClaudeAgentConfig,
    claudeAgentCommand,
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
import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Data.Generics.Labels ()
import Data.Text qualified as Text

-- | Configuration for the unattended @claude@ process.
data ClaudeAgentConfig = ClaudeAgentConfig
  { -- | The program to run, either a bare name resolved on @PATH@ or
    -- an explicit path.
    executable :: !FilePath,
    -- | Raw provider defaults an application always wants. Rendered
    -- after every structured flag and before the request's own raw
    -- arguments.
    extraArgs :: ![Text],
    -- | Whether the run may leave a resumable session on disk.
    -- Defaults to 'False', which emits @--no-session-persistence@:
    -- automation runs are one-shot, and a session file nobody will
    -- clean up is just litter. The flag only works together with @-p@,
    -- which this renderer always emits.
    persistSession :: !Bool
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeAgentConfig :: ClaudeAgentConfig
defaultClaudeAgentConfig =
  ClaudeAgentConfig
    { executable = "claude",
      extraArgs = mempty,
      persistSession = False
    }

-- | Render the executable, argument vector, and prompt transport for an
-- unattended Claude Code run, or refuse the request.
--
-- The prompt appears nowhere in the argument vector: the transport is
-- 'PromptOnStdin', so a prompt beginning with a dash cannot be mistaken
-- for a flag and cannot be swallowed by a preceding variadic flag such
-- as @--allowedTools@ or @--add-dir@.
--
-- No working-directory flag is rendered, because Claude Code has none.
-- The runner sets the child's working directory from the request's
-- @workingDir@ field.
claudeAgentCommand ::
  ClaudeAgentConfig -> AgentRunRequest -> Either AgentRenderError AgentCommand
claudeAgentCommand cfg req
  | req ^. #provider /= AgentClaude =
      Left (ProviderMismatch AgentClaude (req ^. #provider))
  | otherwise = do
      permission <- permissionModeArgs (req ^. #safety . #capability)
      pure
        AgentCommand
          { executable = cfg ^. #executable,
            arguments =
              ["-p"]
                <> sessionArgs cfg
                <> modelArgs req
                <> effortArgs req
                <> permission
                <> allowedToolArgs req
                <> extraDirArgs req
                <> fmap Text.unpack (cfg ^. #extraArgs)
                <> fmap Text.unpack (req ^. #safety . #providerArgs),
            promptTransport = PromptOnStdin,
            promptText = req ^. #prompt
          }

-- | Map a capability profile onto Claude Code's @--permission-mode@.
--
-- The result is an 'Either' even though all three capabilities map
-- today. The type is the promise that an unmappable capability would be
-- refused rather than approximated: a later contributor adding a fourth
-- capability gets an incomplete-pattern warning pointing at this
-- decision instead of a silently missing flag.
permissionModeArgs :: AgentCapability -> Either AgentRenderError [String]
permissionModeArgs = \case
  -- Claude Code has no mode meaning exactly "may read, must not
  -- write". Of its six modes, `manual` and `dontAsk` can block waiting
  -- for a human and are unusable unattended, `acceptEdits` and
  -- `bypassPermissions` permit writes, and `auto` delegates the
  -- decision to a classifier whose behavior is not a stable contract.
  -- `plan` is the only mode that reliably does not modify the tree, at
  -- the documented cost of also framing the task as producing a plan.
  AgentReadOnly -> Right ["--permission-mode", "plan"]
  AgentEditWorkspace -> Right ["--permission-mode", "acceptEdits"]
  AgentFullAccess -> Right ["--permission-mode", "bypassPermissions"]

sessionArgs :: ClaudeAgentConfig -> [String]
sessionArgs cfg
  | cfg ^. #persistSession = []
  | otherwise = ["--no-session-persistence"]

-- | A blank model value must not produce @--model ""@, which Claude
-- rejects.
modelArgs :: AgentRunRequest -> [String]
modelArgs req = case Text.strip <$> req ^. #modelId of
  Nothing -> []
  Just "" -> []
  Just mid -> ["--model", Text.unpack mid]

-- | Claude's @--effort@ accepts @low|medium|high|xhigh|max@, but not
-- @minimal@, so the lowest Baikai level maps up to @low@. This matches
-- "Baikai.Provider.Claude.Interactive" exactly so the two surfaces
-- cannot drift.
effortArgs :: AgentRunRequest -> [String]
effortArgs req = case req ^. #effort of
  Nothing -> []
  Just lvl -> ["--effort", Text.unpack (claudeEffortValue lvl)]

claudeEffortValue :: ThinkingLevel -> Text
claudeEffortValue ThinkingMinimal = "low"
claudeEffortValue lvl = renderThinkingLevel lvl

-- | Join tool names with commas into one argument rather than passing
-- several values, because @--allowedTools@ is variadic and separate
-- values could absorb a following flag.
allowedToolArgs :: AgentRunRequest -> [String]
allowedToolArgs req = case req ^. #safety . #allowedTools of
  [] -> []
  tools -> ["--allowedTools", Text.unpack (Text.intercalate "," tools)]

-- | On Claude Code @--add-dir@ grants tool /access/ to a directory. The
-- identically named @codex exec@ flag grants /write/ access, so the
-- shared @extraDirs@ field means "directories this run may reach" and
-- the precise authority is provider-dependent.
extraDirArgs :: AgentRunRequest -> [String]
extraDirArgs req =
  concatMap (\dir -> ["--add-dir", dir]) (req ^. #extraDirs)
