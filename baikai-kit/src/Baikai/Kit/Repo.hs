module Baikai.Kit.Repo
  ( KitRepo (..),
    RepoRefresh (..),
    ensureKitRepo,
    PullResult (..),
    pullKitRepo,
  )
where

import Baikai.Kit.Config (KitConfig, kitCacheDir)
import Baikai.Kit.Error (KitError (..))
import Baikai.Prelude
import Control.Exception (IOException, try)
import Data.Text qualified as Text
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

data PullResult
  = PullSucceeded
  | PullFailed !Text
  deriving stock (Eq, Show)

-- | What happened to the cache on the way to returning it.
data RepoRefresh
  = -- | The cache did not exist and was cloned.
    RepoCloned
  | -- | The cache existed and was pulled.
    RepoPulled
  | -- | The refresh failed and the cached copy is being used as it is;
    --   the 'Text' is git's output. A caller that needs fresh content
    --   (@kit update@) treats this as a failure; the others warn.
    RepoStale !Text
  deriving stock (Eq, Show)

data KitRepo = KitRepo
  { dir :: !FilePath,
    refresh :: !RepoRefresh
  }
  deriving stock (Eq, Generic, Show)

-- | Resolve the kit cache, refreshing it if it is already a checkout and
--   cloning it if it is not. Never prints and never exits: a first clone
--   that fails with no usable cache is 'KitCloneFailed', and a failed
--   refresh over a usable cache is 'RepoStale'.
ensureKitRepo :: KitConfig -> IO (Either KitError KitRepo)
ensureKitRepo config = do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist (cacheDir </> ".git")
  if exists
    then do
      result <- pullKitRepo config cacheDir
      pure . Right $ case result of
        PullSucceeded -> KitRepo {dir = cacheDir, refresh = RepoPulled}
        PullFailed err -> KitRepo {dir = cacheDir, refresh = RepoStale err}
    else do
      cloned <-
        try @IOException $ do
          createDirectoryIfMissing True cacheDir
          readProcessWithExitCode
            "git"
            ["clone", "--depth", "1", Text.unpack (config ^. #repoUrl), cacheDir]
            ""
      case cloned of
        -- A missing `git` binary arrives here as an IOException.
        Left e -> staleOrFailed cacheDir (Text.pack (show e))
        Right (ExitSuccess, _, _) -> pure (Right KitRepo {dir = cacheDir, refresh = RepoCloned})
        Right (ExitFailure _, _, errOut) -> staleOrFailed cacheDir (Text.pack errOut)
  where
    staleOrFailed cacheDir output = do
      manifestExists <- doesFileExist (cacheDir </> "kit.json")
      pure $
        if manifestExists
          then Right KitRepo {dir = cacheDir, refresh = RepoStale output}
          else Left (KitCloneFailed (config ^. #repoUrl) output)

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
