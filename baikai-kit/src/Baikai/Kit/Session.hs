module Baikai.Kit.Session
  ( agentDirsForSession,
    codexSessionArgs,
  )
where

import Baikai.Interactive (InteractiveProvider (InteractiveCodex))
import Baikai.Kit.CodexConfig (enableSkillsArgs)
import Baikai.Kit.Config (KitConfig, KitScope (..), projectAgentsDir, providerAgentsBase, sidecarFileName, userAgentsDir)
import Baikai.Kit.Sidecar (readSidecar)
import Baikai.Prelude
import Control.Monad (filterM, forM)
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.FilePath ((</>))

agentDirsForSession :: KitConfig -> IO [FilePath]
agentDirsForSession config = do
  userDir <- userAgentsDir config
  projectDir <- projectAgentsDir config
  filterM doesDirectoryExist [userDir, projectDir]

-- | Add these to a tool's Codex launch request's extraArgs. Other providers
-- use agentDirsForSession instead. Only this tool's sidecars contribute.
codexSessionArgs :: KitConfig -> IO [Text]
codexSessionArgs config
  | InteractiveCodex `notElem` (config ^. #providers) = pure []
  | otherwise = do
      paths <- fmap concat . forM [UserScope, ProjectScope] $ \scope -> do
        base <- providerAgentsBase config InteractiveCodex scope
        let root = base </> ".agents/skills"
        exists <- doesDirectoryExist root
        names <- if exists then sort <$> listDirectory root else pure []
        fmap concat . forM names $ \name -> do
          meta <- readSidecar (root </> name </> Text.unpack (sidecarFileName config))
          let tracked = map Text.unpack (fromMaybe [] (meta >>= (^. #codexDisabledSkills)))
              hidden = [root </> name </> "SKILL.md" | (meta >>= (^. #visibility)) == Just "tool-only"]
          pure (hidden ++ tracked)
      canonical <- traverse canonicalizePath paths
      pure (enableSkillsArgs (nub canonical))
