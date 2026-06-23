module Baikai.Kit.Config
  ( KitConfig (..),
    KitScope (..),
    kitCacheDir,
    userAgentsDir,
    projectAgentsDir,
    resolveAgentsBase,
    sidecarFileName,
    scopeLabel,
  )
where

import Baikai.AgentAssets (AgentAssetProvider)
import Baikai.Prelude
import Data.Text qualified as Text
import System.Directory (getCurrentDirectory, getHomeDirectory)
import System.FilePath ((</>))

data KitConfig = KitConfig
  { toolName :: !Text,
    repoUrl :: !Text,
    providers :: ![AgentAssetProvider]
  }
  deriving stock (Generic, Show)

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

projectAgentsDir :: KitConfig -> IO FilePath
projectAgentsDir config = do
  cwd <- getCurrentDirectory
  pure (cwd </> "." <> Text.unpack (config ^. #toolName) </> "agents")

resolveAgentsBase :: KitConfig -> KitScope -> IO FilePath
resolveAgentsBase config UserScope = userAgentsDir config
resolveAgentsBase config ProjectScope = projectAgentsDir config

sidecarFileName :: KitConfig -> Text
sidecarFileName config = "." <> (config ^. #toolName) <> "-kit.json"

scopeLabel :: KitScope -> Text
scopeLabel UserScope = "user"
scopeLabel ProjectScope = "project"
