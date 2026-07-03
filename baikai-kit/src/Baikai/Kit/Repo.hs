module Baikai.Kit.Repo
  ( ensureKitRepo,
    PullResult (..),
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

data PullResult
  = PullSucceeded
  | PullFailed !Text
  deriving stock (Eq, Show)

ensureKitRepo :: KitConfig -> IO FilePath
ensureKitRepo config = do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist (cacheDir </> ".git")
  if exists
    then do
      result <- pullKitRepo config cacheDir
      case result of
        PullSucceeded -> pure ()
        PullFailed err ->
          hPutStrLn stderr $ "Warning: git pull failed, using cached data. " <> Text.unpack err
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

pullKitRepo :: KitConfig -> FilePath -> IO PullResult
pullKitRepo _config cacheDir = do
  result <-
    try @IOException $
      readProcessWithExitCode "git" ["-C", cacheDir, "pull", "--ff-only", "--quiet"] ""
  case result of
    Right (ExitSuccess, _, _) -> pure PullSucceeded
    Right (ExitFailure _, _, errOut) ->
      pure (PullFailed (Text.pack errOut))
    Left e ->
      pure (PullFailed (Text.pack (show e)))
