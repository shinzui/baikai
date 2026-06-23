module Baikai.Kit.Repo
  ( ensureKitRepo,
    pullKitRepo,
  )
where

import Baikai.Kit.Config (KitConfig, kitCacheDir)
import Baikai.Prelude
import Control.Exception (IOException, try)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

ensureKitRepo :: KitConfig -> IO FilePath
ensureKitRepo config = do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist (cacheDir </> ".git")
  if exists
    then do
      pullKitRepo config cacheDir
      pure cacheDir
    else do
      Text.IO.putStrLn $ "Fetching " <> (config ^. #toolName) <> "-kit..."
      createDirectoryIfMissing True cacheDir
      (exitCode, _, errOut) <-
        readProcessWithExitCode
          "git"
          ["clone", "--depth", "1", Text.unpack (config ^. #repoUrl), cacheDir]
          ""
      case exitCode of
        ExitSuccess -> pure cacheDir
        ExitFailure _ -> do
          manifestExists <- doesFileExist (cacheDir </> "kit.json")
          if manifestExists
            then do
              hPutStrLn stderr $ "Warning: git clone failed, using cached data. " <> errOut
              pure cacheDir
            else do
              hPutStrLn stderr $ "Error: Failed to fetch kit repository: " <> errOut
              exitFailure

pullKitRepo :: KitConfig -> FilePath -> IO ()
pullKitRepo _config cacheDir = do
  result <-
    try @IOException $
      readProcessWithExitCode "git" ["-C", cacheDir, "pull", "--ff-only", "--quiet"] ""
  case result of
    Right (ExitSuccess, _, _) -> pure ()
    Right (ExitFailure _, _, errOut) ->
      hPutStrLn stderr $ "Warning: git pull failed, using cached data. " <> errOut
    Left e ->
      hPutStrLn stderr $ "Warning: git pull failed: " <> show e
