module Baikai.Kit.Config
  ( KitConfig (..),
    KitScope (..),
    kitConfig,
    findProjectRoot,
    projectRootByMarkers,
    kitCacheDir,
    userAgentsDir,
    projectAgentsDir,
    resolveAgentsBase,
    providerAgentsBase,
    providerLabel,
    sidecarFileName,
    scopeLabel,
  )
where

import Baikai.AgentAssets (AgentAssetProvider)
import Baikai.Interactive (InteractiveProvider (..))
import Baikai.Prelude
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import System.Directory (doesPathExist, getCurrentDirectory, getHomeDirectory, makeAbsolute)
import System.FilePath (takeDirectory, (</>))

-- | How a tool configures the kit engine. Build one with 'kitConfig' and
--   override optional fields with record update syntax; a record literal
--   must set every field.
data KitConfig = KitConfig
  { toolName :: !Text,
    repoUrl :: !Text,
    providers :: ![AgentAssetProvider],
    -- | The directory project scope lives under. It is run once per
    --   project-scope path lookup, so install, status, update, uninstall,
    --   and 'Baikai.Kit.Session.agentDirsForSession' all agree on it. The
    --   default ('kitConfig') is the current directory; 'projectRootByMarkers'
    --   walks up to the nearest marker such as @.git@. An exception thrown
    --   by this action propagates to the caller.
    projectRoot :: !(IO FilePath)
  }
  deriving stock (Generic)

instance Show KitConfig where
  showsPrec d config =
    showParen (d > 10) $
      showString "KitConfig {toolName = "
        . shows (config ^. #toolName)
        . showString ", repoUrl = "
        . shows (config ^. #repoUrl)
        . showString ", providers = "
        . shows (config ^. #providers)
        . showString ", projectRoot = <IO FilePath>}"

-- | A configuration with every optional behaviour at its default:
--   project scope is the current directory.
kitConfig :: Text -> Text -> [AgentAssetProvider] -> KitConfig
kitConfig toolName repoUrl providers =
  KitConfig {toolName, repoUrl, providers, projectRoot = getCurrentDirectory}

-- | The nearest directory, starting at @start@ and walking towards the
--   filesystem root, that contains any of @markers@ (a file or a
--   directory, e.g. @.git@ or @.mytool@). 'Nothing' if none does.
findProjectRoot :: [FilePath] -> FilePath -> IO (Maybe FilePath)
findProjectRoot markers start = makeAbsolute start >>= go
  where
    go dir = do
      found <- or <$> traverse (doesPathExist . (dir </>)) markers
      if found
        then pure (Just dir)
        else
          let parent = takeDirectory dir
           in if parent == dir then pure Nothing else go parent

-- | A ready-made 'projectRoot': the nearest ancestor of the current
--   directory holding one of @markers@, or the current directory itself
--   when there is none.
projectRootByMarkers :: [FilePath] -> IO FilePath
projectRootByMarkers markers = do
  cwd <- getCurrentDirectory
  fromMaybe cwd <$> findProjectRoot markers cwd

data KitScope
  = UserScope
  | ProjectScope
  deriving stock (Eq, Ord, Show)

kitCacheDir :: KitConfig -> IO FilePath
kitCacheDir config = do
  home <- getHomeDirectory
  pure (home </> ".cache" </> Text.unpack (config ^. #toolName) </> "kit")

userAgentsDir :: KitConfig -> IO FilePath
userAgentsDir config = do
  home <- getHomeDirectory
  pure (home </> ".config" </> Text.unpack (config ^. #toolName) </> "agents")

-- | Every project-scope path derives from 'projectRoot' through this
--   function, 'resolveAgentsBase', or 'providerAgentsBase'.
projectAgentsDir :: KitConfig -> IO FilePath
projectAgentsDir config = do
  root <- config ^. #projectRoot
  pure (root </> "." <> Text.unpack (config ^. #toolName) </> "agents")

resolveAgentsBase :: KitConfig -> KitScope -> IO FilePath
resolveAgentsBase config UserScope = userAgentsDir config
resolveAgentsBase config ProjectScope = projectAgentsDir config

providerAgentsBase :: KitConfig -> AgentAssetProvider -> KitScope -> IO FilePath
providerAgentsBase config InteractiveClaude scope = resolveAgentsBase config scope
providerAgentsBase _config InteractiveCodex UserScope = getHomeDirectory
providerAgentsBase config InteractiveCodex ProjectScope = config ^. #projectRoot

providerLabel :: AgentAssetProvider -> Text
providerLabel InteractiveClaude = "claude"
providerLabel InteractiveCodex = "codex"

sidecarFileName :: KitConfig -> Text
sidecarFileName config = "." <> (config ^. #toolName) <> "-kit.json"

scopeLabel :: KitScope -> Text
scopeLabel UserScope = "user"
scopeLabel ProjectScope = "project"
