module Baikai.Kit.Session
  ( agentDirsForSession,
  )
where

import Baikai.Kit.Config (KitConfig, projectAgentsDir, userAgentsDir)
import Control.Monad (filterM)
import System.Directory (doesDirectoryExist)

agentDirsForSession :: KitConfig -> IO [FilePath]
agentDirsForSession config = do
  userDir <- userAgentsDir config
  projectDir <- projectAgentsDir config
  filterM doesDirectoryExist [userDir, projectDir]
