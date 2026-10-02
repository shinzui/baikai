-- | Reading the manifest and installing what it lists.
--
--   Every function here returns @'Either' 'KitError' a@ and prints
--   nothing: rendering and exiting belong to 'Baikai.Kit.Command.runKit'.
--   Internally the module raises 'KitError' and catches it at each
--   exported boundary, which keeps the plumbing readable without changing
--   what a caller observes.
module Baikai.Kit.Install
  ( InstallOptions (..),
    defaultInstallOptions,
    VisibilityCheck (..),
    checkVisibility,
    checkVisibilityWithEntries,
    relativeLinkTarget,
    loadManifest,
    loadManifestMaybe,
    lookupItem,
    installItem,
    installFrom,
    uninstallItem,
    renderUninstallReport,
    RemovalOutcome (..),
    OverwritePolicy (..),
    UpdateReport (..),
    updateKit,
    reinstallPresent,
    LocalEdits (..),
    checkLocalEdits,
    listAvailable,
    renderAvailable,
    PlannedWrite (..),
    WriteContent (..),
    executePlan,
    executePlanWith,
    stripYamlFrontmatter,
  )
where

import Baikai.AgentAssets
  ( AgentAssetProvider,
    CodexCustomAgent (..),
    agentTargetPath,
    codexCustomAgentToml,
    skillTargetPath,
  )
import Baikai.Interactive (InteractiveProvider (..), InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.CodexConfig (addDisabledSkill, checkDisabledSkill, checkRemoveDisabledSkill, codexConfigPath, readSkillEntries, removeDisabledSkill)
import Baikai.Kit.Config (KitConfig, KitScope (..), kitCacheDir, providerAgentsBase, providerLabel, scopeLabel, sidecarFileName)
import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Link (SharedLink, applyLink, claudeLinks, foreignOwner, linkIsOurs, pathExists, preflightLink, relativeLinkTarget, removeLink)
import Baikai.Kit.Manifest
  ( AgentEntry,
    ItemSources,
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    SkillEntry,
    itemName,
    itemSources,
    itemVisibility,
    kitItemKind,
    supportedManifestVersions,
  )
import Baikai.Kit.Path (safeItemName, safeSourcePath)
import Baikai.Kit.Repo (KitRepo, PullResult (..), RepoRefresh (..), ensureKitRepo, pullKitRepo)
import Baikai.Kit.Sidecar (SidecarMeta, hashEntries, newSidecarMeta, readSidecar, sidecarPath)
import Baikai.Kit.Visibility (KitVisibility (..), parseVisibility, visibilityLabel)
import Baikai.Prelude
import Control.Exception (IOException, onException, throwIO, try)
import Control.Monad (filterM, forM, forM_, unless, when)
import Data.Aeson (eitherDecodeFileStrict', encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (find, nub)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeDirectoryRecursive,
    removeFile,
    renameFile,
  )
import System.Directory qualified
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, openTempFile)

data InstallOptions = InstallOptions
  { visibility :: !(Maybe KitVisibility),
    acceptSharedCodex :: !Bool
  }
  deriving stock (Eq, Generic, Show)

defaultInstallOptions :: InstallOptions
defaultInstallOptions = InstallOptions Nothing False

-- | One file this install will put in place. Exposed as a test seam
--   together with 'executePlanWith'; not part of the stable surface.
data PlannedWrite = PlannedWrite
  { destination :: !FilePath,
    content :: !WriteContent
  }
  deriving stock (Generic, Show)

data WriteContent
  = CopyFrom !FilePath
  | WriteBytes !LBS.ByteString
  deriving stock (Show)

data RemovalOutcome = RemovalOutcome
  { provider :: !InteractiveProvider,
    skillRemoved :: !Bool,
    agentRemoved :: !Bool,
    sidecarRemoved :: !Bool,
    linksRemoved :: ![FilePath],
    configEntriesRemoved :: ![FilePath]
  }
  deriving stock (Eq, Generic, Show)

-- | What @kit update@ should do with an item whose installed files were
--   edited after they were installed.
data OverwritePolicy
  = KeepLocalEdits
  | OverwriteLocalEdits
  deriving stock (Eq, Show)

-- | What @kit update@ did, for the caller to render. @refresh@ is
--   'Nothing' when no refresh was attempted, which is what
--   'reinstallPresent' reports.
data UpdateReport = UpdateReport
  { refresh :: !(Maybe RepoRefresh),
    updated :: ![(Text, KitScope)],
    skipped :: ![(Text, KitScope)]
  }
  deriving stock (Eq, Generic, Show)

-- | Read and validate the manifest at @<dir>/kit.json@.
loadManifest :: FilePath -> IO (Either KitError KitManifest)
loadManifest = kitTry . loadManifestIO

-- | The same, tolerating an absent cache or an absent manifest. A
--   manifest that is present but unreadable is still a 'Left'.
loadManifestMaybe :: FilePath -> IO (Either KitError (Maybe KitManifest))
loadManifestMaybe "" = pure (Right Nothing)
loadManifestMaybe cacheDir = kitTry $ do
  exists <- doesFileExist (cacheDir </> "kit.json")
  if exists then Just <$> loadManifestIO cacheDir else pure Nothing

lookupItem :: Text -> KitManifest -> Maybe KitItem
lookupItem n manifest =
  case find (\entry -> entry ^. #name == n) (manifest ^. #skills) of
    Just skill -> Just (KitSkillItem skill)
    Nothing -> KitAgentItem <$> find (\entry -> entry ^. #name == n) (manifest ^. #agents)

-- | Refresh the cache, read the manifest and install one item. The
--   'KitRepo'\'s refresh state is dropped by this convenience; a command
--   that wants to warn about a stale cache composes 'ensureKitRepo',
--   'loadManifest' and 'installFrom' itself.
installItem :: KitConfig -> Text -> KitScope -> InstallOptions -> IO (Either KitError KitItem)
installItem config itemN scope options = kitTry $ do
  repo <- requireRepo config
  manifest <- loadManifestIO (repo ^. #dir)
  installFromIO config (repo ^. #dir) manifest itemN scope options

-- | The network-free half of 'installItem': install one item from a
--   manifest already read out of @repoDir@.
installFrom :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> InstallOptions -> IO (Either KitError KitItem)
installFrom config repoDir manifest itemN scope options =
  kitTry (installFromIO config repoDir manifest itemN scope options)

-- | Remove an item's assets, its resource directory and its sidecar from
--   every provider at one scope.
uninstallItem :: KitConfig -> Text -> KitScope -> IO (Either KitError [RemovalOutcome])
uninstallItem config n scope = kitTry $ do
  safeName <- orThrow (KitUnsafeName n) (safeItemName n)
  forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    old <- traverse (\kind -> readSidecar (sidecarPath provider kind n providerBase (sidecarFileName config))) [SkillKind, AgentKind]
    links <-
      if provider == InteractiveClaude
        then do
          skillLinks <- claudeLinks config scope SkillKind n False
          agentLinks <- claudeLinks config scope AgentKind n True
          fmap concat . forM (skillLinks ++ agentLinks) $ \link -> do
            removed <- removeLink link
            pure [link ^. #location | removed]
        else pure []
    -- Sidecars are read before deleting assets so owned entries remain known.
    removedEntries <- fmap concat . forM old $ \meta ->
      fmap concat . forM (fromMaybe [] (meta >>= (^. #codexDisabledSkills))) $ \raw -> do
        path <- codexConfigPath
        removed <- removeDisabledSkill path (Text.unpack raw) >>= either throwIO pure
        pure [Text.unpack raw | removed]
    let ownsSkill = provider /= InteractiveCodex || any (maybe False ((== "skill") . view #kind)) old
        ownsAgent = provider /= InteractiveCodex || any (maybe False ((== "agent") . view #kind)) old
    skillRemoved <- if ownsSkill then removeIfDirectory (skillTarget config provider providerBase safeName) else pure False
    agentFileRemoved <- if ownsAgent then removeIfFile (agentTarget config provider providerBase safeName) else pure False
    -- A multi-file agent owns a directory beside its agent file; it is
    -- part of the agent, not a kind of its own.
    agentDirRemoved <- if ownsAgent then removeIfDirectory (agentResourceDir config provider providerBase safeName) else pure False
    sidecarRemoved <- removeIfFile (agentSidecarTarget config provider providerBase safeName)
    pure
      RemovalOutcome
        { provider,
          skillRemoved,
          agentRemoved = agentFileRemoved || agentDirRemoved,
          sidecarRemoved,
          linksRemoved = links,
          configEntriesRemoved = removedEntries
        }

renderUninstallReport :: Text -> KitScope -> [RemovalOutcome] -> Text
renderUninstallReport n scope outcomes
  | any assetRemoved outcomes =
      "Uninstalled "
        <> Text.intercalate "+" removedKinds
        <> " '"
        <> n
        <> "' from "
        <> scopeLabel scope
        <> " scope ("
        <> Text.intercalate "," removedProviders
        <> ")."
        <> visibilityRemovalNote
  | any (^. #sidecarRemoved) outcomes =
      "Removed stale kit metadata for '" <> n <> "' from " <> scopeLabel scope <> " scope." <> visibilityRemovalNote
  | any visibilityRemoved outcomes =
      "Removed stale visibility for '" <> n <> "' from " <> scopeLabel scope <> " scope." <> visibilityRemovalNote
  | otherwise =
      "'" <> n <> "' is not installed in " <> scopeLabel scope <> " scope."
  where
    visibilityRemovalNote =
      let links = sum (map (length . view #linksRemoved) outcomes)
          entries = sum (map (length . view #configEntriesRemoved) outcomes)
       in Text.concat
            [ " Removed " <> Text.pack (show count) <> " " <> label <> "."
            | (count, label) <- [(links, "shared link(s)"), (entries, "Codex config entry/entries")],
              count > 0
            ]
    assetRemoved outcome = outcome ^. #skillRemoved || outcome ^. #agentRemoved
    visibilityRemoved outcome = not (null (outcome ^. #linksRemoved) && null (outcome ^. #configEntriesRemoved))
    removedKinds =
      nub $
        ["skill" | any (^. #skillRemoved) outcomes]
          ++ ["agent" | any (^. #agentRemoved) outcomes]
    removedProviders = map (providerLabel . view #provider) (filter assetRemoved outcomes)

-- | Refresh the cache and reinstall the items that are already installed.
--   A failed refresh is an error here, unlike the other verbs: fetching
--   is what update is for.
updateKit :: KitConfig -> Maybe Text -> OverwritePolicy -> IO (Either KitError UpdateReport)
updateKit config mName policy = kitTry $ do
  cacheDir <- kitCacheDir config
  isCheckout <- doesDirectoryExist (cacheDir </> ".git")
  refreshed <-
    if isCheckout
      then do
        result <- pullKitRepo config cacheDir
        case result of
          PullSucceeded -> pure RepoPulled
          PullFailed err -> throwIO (KitPullFailed err)
      else do
        repo <- requireRepo config
        case repo ^. #refresh of
          RepoStale err -> throwIO (KitCloneFailed (config ^. #repoUrl) err)
          fresh -> pure fresh
  manifest <- loadManifestIO cacheDir
  report <- reinstallPresentIO config cacheDir manifest mName policy
  pure (report & #refresh .~ Just refreshed)

-- | The network-free second half of 'updateKit': reinstall what is
--   already installed from a manifest already read out of @repoDir@.
--
--   Under 'KeepLocalEdits' an item whose installed files no longer hash
--   to what its sidecar recorded is skipped rather than overwritten. A
--   sidecar written before those fields existed carries no hash, so such
--   an item is reinstalled without the check.
reinstallPresent ::
  KitConfig ->
  FilePath ->
  KitManifest ->
  Maybe Text ->
  OverwritePolicy ->
  IO (Either KitError UpdateReport)
reinstallPresent config repoDir manifest mName policy =
  kitTry (reinstallPresentIO config repoDir manifest mName policy)

-- | Refresh the cache and read the manifest of what the kit offers.
listAvailable :: KitConfig -> IO (Either KitError KitManifest)
listAvailable config = kitTry $ do
  repo <- requireRepo config
  loadManifestIO (repo ^. #dir)

-- | The listing @kit list@ prints, without a trailing newline.
renderAvailable :: KitManifest -> Text
renderAvailable manifest
  | null skills && null agents = "No items available in the kit."
  | otherwise = Text.intercalate "\n" (skillBlock ++ gap ++ agentBlock)
  where
    skills = manifest ^. #skills
    agents = manifest ^. #agents
    gap = ["" | not (null skills), not (null agents)]
    skillBlock
      | null skills = []
      | otherwise = "Skills:" : map (entryLine (columnWidth (map (view #name) skills)) . skillNameDesc) skills
    agentBlock
      | null agents = []
      | otherwise = "Agents:" : map (entryLine (columnWidth (map (view #name) agents)) . agentNameDesc) agents
    columnWidth names = maximum (map Text.length names)
    entryLine width (n, desc) = "  " <> Text.justifyLeft (width + 2) ' ' n <> desc

-- | Put a plan in place, or leave the filesystem as it was.
--
--   Phase one writes every payload to a uniquely named temporary file in
--   its destination's directory. Phase two, per entry, moves an existing
--   destination aside to a unique backup and renames the temporary into
--   place, journalling both; a failure restores every completed entry in
--   reverse, removes the remaining temporaries and reports which paths
--   were restored and which could not be. Same-directory renames are
--   atomic on POSIX, so a reader sees either the old file or the new one.
executePlan :: [PlannedWrite] -> IO (Either KitError ())
executePlan = executePlanWith renameFile

-- | 'executePlan' with an injectable rename step. A test seam; not part
--   of the stable surface.
executePlanWith :: (FilePath -> FilePath -> IO ()) -> [PlannedWrite] -> IO (Either KitError ())
executePlanWith renameInto writes = do
  clash <- firstDirectoryDestination writes
  case clash of
    Just dest -> pure (Left (writeFailed ("destination is a directory: " <> Text.pack dest)))
    Nothing -> do
      staged <- stage [] writes
      case staged of
        Left err -> pure (Left err)
        Right temps -> commit [] temps
  where
    writeFailed reason = KitWriteFailed reason [] []

    firstDirectoryDestination [] = pure Nothing
    firstDirectoryDestination (planned : rest) = do
      let dest = planned ^. #destination
      isDir <- doesDirectoryExist dest
      if isDir then pure (Just dest) else firstDirectoryDestination rest

    -- Phase one. Nothing observable has changed while this runs, so a
    -- failure removes the temporaries and reports no changes.
    stage staged [] = pure (Right (reverse staged))
    stage staged (planned : rest) = do
      result <- try @IOException (stageOne planned)
      case result of
        Left e -> do
          removeTemps staged
          pure (Left (writeFailed (Text.pack (show e))))
        Right pair -> stage (pair : staged) rest

    stageOne planned = do
      let dest = planned ^. #destination
          dir = takeDirectory dest
      bytes <- payload (planned ^. #content)
      createDirectoryIfMissing True dir
      -- 'openTempFile' splits the template at its last extension, so the
      -- file is named <dest><random>.baikai-kit-tmp: unique, and still
      -- carrying the suffix a residue check looks for.
      (temp, handle) <- openTempFile dir (takeFileName dest <> ".baikai-kit-tmp")
      (LBS.hPut handle bytes >> hClose handle)
        `onException` (hClose handle >> ignoring (removeFile temp))
      pure (temp, dest)

    payload (CopyFrom src) = LBS.readFile src
    payload (WriteBytes bytes) = pure bytes

    -- Phase two. Every entry that changed anything is journalled with the
    -- backup it displaced and whether its rename completed.
    commit journal [] = do
      forM_ journal $ \(_, mBackup, _) -> forM_ mBackup (ignoring . removeFile)
      pure (Right ())
    commit journal (entry@(temp, dest) : rest) = do
      backed <- try @IOException (backupExisting dest)
      case backed of
        Left e -> unwind journal (entry : rest) e
        Right mBackup -> do
          renamed <- try @IOException (renameInto temp dest)
          case renamed of
            Left e -> unwind ((dest, mBackup, False) : journal) (entry : rest) e
            Right () -> commit ((dest, mBackup, True) : journal) rest

    backupExisting dest = do
      exists <- doesFileExist dest
      if not exists
        then pure Nothing
        else do
          (backup, handle) <- openTempFile (takeDirectory dest) (takeFileName dest <> ".baikai-kit-bak")
          hClose handle
          renameFile dest backup
          pure (Just backup)

    unwind journal remaining e = do
      outcomes <- forM (filter changedSomething journal) $ \(dest, mBackup, renamed) -> do
        restored <- try @IOException (restoreEntry dest mBackup renamed)
        pure (dest, either (const False) (const True) (restored :: Either IOException ()))
      removeTemps remaining
      pure . Left $
        KitWriteFailed
          (Text.pack (show e))
          [dest | (dest, True) <- outcomes]
          [dest | (dest, False) <- outcomes]

    changedSomething (_, mBackup, renamed) = renamed || has _Just mBackup

    restoreEntry dest (Just backup) _ = renameFile backup dest
    restoreEntry dest Nothing True = removeFile dest
    restoreEntry _ Nothing False = pure ()

    removeTemps entries = forM_ entries $ \(temp, _) -> ignoring (removeFile temp)

    ignoring action = do
      _ <- try @IOException action
      pure ()

-- Internal ------------------------------------------------------------

loadManifestIO :: FilePath -> IO KitManifest
loadManifestIO repoDir = do
  let manifestPath = repoDir </> "kit.json"
  exists <- doesFileExist manifestPath
  unless exists (throwIO (KitManifestMissing manifestPath))
  result <- eitherDecodeFileStrict' manifestPath
  case result of
    Left err -> throwIO (KitManifestInvalid manifestPath (Text.pack err))
    Right manifest -> do
      let declared = manifest ^. #version
      unless (declared `elem` supportedManifestVersions) $
        throwIO (KitManifestVersionUnsupported manifestPath declared)
      pure manifest

installFromIO :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> InstallOptions -> IO KitItem
installFromIO config repoDir manifest itemN scope options =
  case lookupItem itemN manifest of
    Nothing -> throwIO (KitItemNotFound itemN)
    Just item -> do
      choices <- prepareVisibility config item scope (Just options)
      doInstall config repoDir item scope choices
      pure item

requireRepo :: KitConfig -> IO KitRepo
requireRepo config = ensureKitRepo config >>= either throwIO pure

reinstallPresentIO ::
  KitConfig ->
  FilePath ->
  KitManifest ->
  Maybe Text ->
  OverwritePolicy ->
  IO UpdateReport
reinstallPresentIO config repoDir manifest mName policy = do
  results <-
    fmap concat . forM candidates $ \n ->
      fmap concat . forM [UserScope, ProjectScope] $ \scope -> do
        installed <- isInstalled config n scope
        case (installed, lookupItem n manifest) of
          (True, Just item) -> do
            modified <- case policy of
              OverwriteLocalEdits -> pure False
              KeepLocalEdits -> locallyModified config item scope
            choices <- prepareVisibility config item scope Nothing
            if modified
              then do
                repairSkippedVisibility choices
                pure [Left (n, scope)]
              else do
                doInstall config repoDir item scope choices
                pure [Right (n, scope)]
          _ -> pure []
  pure
    UpdateReport
      { refresh = Nothing,
        updated = [entry | Right entry <- results],
        skipped = [entry | Left entry <- results]
      }
  where
    candidates = case mName of
      Just n -> [n]
      Nothing ->
        map (view #name) (manifest ^. #skills)
          ++ map (view #name) (manifest ^. #agents)

-- | Whether one provider's installed copy of an item still matches what
--   was installed.
data LocalEdits
  = -- | Every recorded file reads back with the recorded hash.
    Unedited
  | -- | A recorded file differs, or cannot be read.
    Edited
  | -- | There is nothing to compare against: no sidecar, or a sidecar
    --   written before @installedFiles@ and @installedHash@ existed.
    EditsUnknown
  deriving stock (Eq, Show)

-- | Do one provider's installed files for an item still hash to what its
--   sidecar recorded? This is the one local-edit check: @kit update@ skips
--   an 'Edited' item under 'KeepLocalEdits', and @kit status@ reports it
--   as modified. Reads only local files.
checkLocalEdits ::
  KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError LocalEdits)
checkLocalEdits config provider scope kind n = kitTry (localEditsIO config provider scope kind n)

localEditsIO :: KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO LocalEdits
localEditsIO config provider scope kind n = do
  safeName <- orThrow (KitUnsafeName n) (safeItemName n)
  providerBase <- providerAgentsBase config provider scope
  let root = installedRoot config provider providerBase kind safeName
  mSidecar <- readSidecar (sidecarPath provider kind (Text.pack safeName) providerBase (sidecarFileName config))
  case mSidecar of
    Nothing -> pure EditsUnknown
    Just sidecar ->
      case (sidecar ^. #installedFiles, sidecar ^. #installedHash) of
        (Just recorded, Just expected) -> do
          entries <- forM recorded $ \rel -> do
            bytes <- try @IOException (BS.readFile (root </> Text.unpack rel))
            pure (either (const Nothing) (Just . (Text.unpack rel,)) (bytes :: Either IOException BS.ByteString))
          pure $ case sequence entries of
            Nothing -> Edited
            Just pairs
              | hashEntries pairs /= expected -> Edited
              | otherwise -> Unedited
        _ -> pure EditsUnknown

-- | Was any provider's copy of this item edited locally? A missing or
--   legacy sidecar is not an edit.
locallyModified :: KitConfig -> KitItem -> KitScope -> IO Bool
locallyModified config item scope = do
  checks <- forM (config ^. #providers) $ \provider ->
    localEditsIO config provider scope (kitItemKind item) (itemName item)
  pure (Edited `elem` checks)

-- | The one visibility check shared by status and update. An absent
-- requested value marks an installation that predates visibility tracking.
data VisibilityCheck = VisibilityCheck
  { requested :: !(Maybe KitVisibility),
    effective :: !KitVisibility,
    broken :: ![FilePath]
  }
  deriving stock (Eq, Generic, Show)

checkVisibility :: KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError VisibilityCheck)
checkVisibility config provider scope kind n = do
  entries <-
    if provider == InteractiveCodex && kind == SkillKind
      then codexConfigPath >>= readSkillEntries
      else pure (Right [])
  checkVisibilityWithEntries entries config provider scope kind n

-- | A status run supplies one parsed Codex snapshot for every row.
checkVisibilityWithEntries :: Either KitError [(FilePath, Bool)] -> KitConfig -> AgentAssetProvider -> KitScope -> KitItemKind -> Text -> IO (Either KitError VisibilityCheck)
checkVisibilityWithEntries entries config provider scope kind n = kitTry $ do
  _ <- orThrow (KitUnsafeName n) (safeItemName n)
  base <- providerAgentsBase config provider scope
  meta <- readSidecar (sidecarPath provider kind n base (sidecarFileName config))
  let requested = meta >>= (^. #visibility) >>= either (const Nothing) Just . parseVisibility
  case provider of
    InteractiveClaude -> do
      links <- claudeLinks config scope kind n True
      states <- forM links $ \link -> do
        ours <- linkIsOurs link
        exists <- System.Directory.doesPathExist (link ^. #location)
        pure (link ^. #location, ours && exists)
      let shared = case states of
            (_, True) : _ -> True
            _ -> False
          recorded = fromMaybe [] (meta >>= (^. #sharedLinks))
          hasResources = maybe False ((> 1) . length) (meta >>= (^. #installedFiles))
          wanted =
            [ p
            | (ordinal, (p, _)) <- zip [0 :: Int ..] states,
              requested == Just SharedVisibility,
              ordinal == 0 || hasResources
            ]
          broken =
            [ p
            | raw <- recorded,
              let p = Text.unpack raw,
              if p `elem` wanted then lookup p states /= Just True else lookup p states == Just True
            ]
      pure VisibilityCheck {requested, effective = if shared then SharedVisibility else ToolOnlyVisibility, broken}
    InteractiveCodex
      | kind == AgentKind ->
          pure VisibilityCheck {requested, effective = SharedVisibility, broken = []}
    InteractiveCodex -> do
      path <- System.Directory.canonicalizePath (skillTarget config provider base (Text.unpack n) </> "SKILL.md")
      canonical <- case entries of
        Left _ -> pure []
        Right values -> forM values $ \(p, enabled) -> do
          absolute <- System.Directory.canonicalizePath p
          pure (absolute, enabled)
      let disabled p = (p, False) `elem` canonical && (p, True) `notElem` canonical
          tracked = map Text.unpack (fromMaybe [] (meta >>= (^. #codexDisabledSkills)))
      trackedPaths <- traverse System.Directory.canonicalizePath tracked
      let broken = nub [p | p <- trackedPaths ++ [path | has _Just requested], if requested == Just SharedVisibility then disabled p else not (disabled p)]
      pure VisibilityCheck {requested, effective = if disabled path then ToolOnlyVisibility else SharedVisibility, broken}

-- Visibility intent is prepared for every provider before writing any asset.
data ProviderVisibility = ProviderVisibility
  { provider :: !AgentAssetProvider,
    baseDir :: !FilePath,
    sidecarFile :: !FilePath,
    previous :: !(Maybe SidecarMeta),
    requested :: !(Maybe KitVisibility),
    source :: !(Maybe Text),
    links :: ![SharedLink],
    oldLinks :: ![SharedLink],
    configFile :: !FilePath,
    disablePaths :: ![FilePath],
    trackedDisabled :: ![Text],
    oldDisabled :: ![Text]
  }
  deriving stock (Generic)

prepareVisibility :: KitConfig -> KitItem -> KitScope -> Maybe InstallOptions -> IO [ProviderVisibility]
prepareVisibility config item scope options = do
  case options of
    Just opts
      | InteractiveCodex `elem` (config ^. #providers),
        kitItemKind item == AgentKind,
        fromMaybe (itemVisibility item) (opts ^. #visibility) == ToolOnlyVisibility -> do
          accepted <-
            if opts ^. #acceptSharedCodex
              then pure True
              else maybe (pure False) ($ item) (config ^. #confirmSharedCodex)
          unless accepted (throwIO (KitCodexCannotIsolate (itemName item)))
    _ -> pure ()
  providers <- case options of
    Just _ -> pure (config ^. #providers)
    Nothing -> filterM (installedProvider config item scope) (config ^. #providers)
  forM providers $ \provider -> do
    baseDir <- providerAgentsBase config provider scope
    let n = itemName item
        kind = kitItemKind item
        sidecarFile = sidecarPath provider kind n baseDir (sidecarFileName config)
        assetPath = case kind of
          SkillKind -> skillTarget config provider baseDir (Text.unpack n)
          AgentKind -> agentTarget config provider baseDir (Text.unpack n)
    previous <- readSidecar sidecarFile
    current <- checkVisibility config provider scope kind n >>= either throwIO pure
    when (provider == InteractiveCodex) $ do
      let protected = assetPath : [agentResourceDir config provider baseDir (Text.unpack n) | kind == AgentKind]
      forM_ protected $ \path -> do
        exists <- pathExists path
        when (exists && not (has _Just previous)) $ do
          owner <- foreignOwner path
          throwIO (KitSharedNameTaken path owner)
    let (requested, source) = case options of
          Just opts ->
            ( Just (fromMaybe (itemVisibility item) (opts ^. #visibility)),
              Just (if has _Just (opts ^. #visibility) then "install-flag" else "manifest")
            )
          Nothing -> case current ^. #requested of
            Nothing -> (Nothing, Nothing)
            Just old ->
              if (previous >>= (^. #visibilitySource)) == Just "install-flag"
                then (Just old, Just "install-flag")
                else (Just (itemVisibility item), Just "manifest")
    sources <- either throwIO pure (itemSources item)
    possible <-
      if provider == InteractiveClaude
        then claudeLinks config scope kind n (kind == AgentKind && length (sources ^. #files) > 1)
        else pure []
    allLinks <- if provider == InteractiveClaude then claudeLinks config scope kind n True else pure []
    let links = [link | link <- possible, requested == Just SharedVisibility]
        recorded = fromMaybe [] (previous >>= (^. #sharedLinks))
    owned <- forM allLinks linkIsOurs
    let oldLinks = [link | (link, ours) <- zip allLinks owned, ours || Text.pack (link ^. #location) `elem` recorded]
    forM_ links preflightLink
    configFile <- codexConfigPath
    let oldDisabled = fromMaybe [] (previous >>= (^. #codexDisabledSkills))
    when (provider == InteractiveCodex && kind == SkillKind && requested == Just SharedVisibility) $ do
      path <- System.Directory.canonicalizePath (assetPath </> "SKILL.md")
      entries <- readSkillEntries configFile >>= either throwIO pure
      disabled <- forM [p | (p, False) <- entries] System.Directory.canonicalizePath
      ownedPaths <- traverse (System.Directory.canonicalizePath . Text.unpack) oldDisabled
      when (path `elem` disabled && path `notElem` ownedPaths) $
        throwIO (KitCodexConfigUnusable configFile "a user-owned disabled entry hides this skill; remove that entry by hand before installing --shared")
    disablePaths <-
      if provider == InteractiveCodex && kind == SkillKind && requested == Just ToolOnlyVisibility
        then do
          unless ("SKILL.md" `elem` (sources ^. #files)) $
            throwIO (KitCodexConfigUnusable configFile "tool-only visibility on Codex needs a SKILL.md; use --shared")
          path <- System.Directory.canonicalizePath (assetPath </> "SKILL.md")
          pure [path]
        else pure []
    needed <- forM disablePaths $ \path -> do
      added <- checkDisabledSkill configFile path >>= either throwIO pure
      pure [Text.pack path | added || Text.pack path `elem` oldDisabled]
    let trackedDisabled = concat needed
    forM_ oldDisabled $ \path -> when (has _Just requested && Text.unpack path `notElem` disablePaths) $ do
      _ <- checkRemoveDisabledSkill configFile (Text.unpack path) >>= either throwIO pure
      pure ()
    pure
      ProviderVisibility
        { provider,
          baseDir,
          sidecarFile,
          previous,
          requested,
          source,
          links,
          oldLinks,
          configFile,
          disablePaths,
          trackedDisabled,
          oldDisabled
        }

-- Update reconciles copies already installed, including a surviving sidecar
-- with missing assets. It does not introduce a new unaccepted provider copy.
installedProvider :: KitConfig -> KitItem -> KitScope -> AgentAssetProvider -> IO Bool
installedProvider config item scope provider = do
  base <- providerAgentsBase config provider scope
  let kind = kitItemKind item
      name = itemName item
      asset = case kind of
        SkillKind -> skillTarget config provider base (Text.unpack name)
        AgentKind -> agentTarget config provider base (Text.unpack name)
  exists <- pathExists asset
  metadata <- doesFileExist (sidecarPath provider kind name base (sidecarFileName config))
  pure (exists || metadata)

applyVisibility :: ProviderVisibility -> IO ()
applyVisibility choice = when (has _Just (choice ^. #requested)) $ do
  result <- try @IOException . try @KitError $ do
    forM_ (choice ^. #links) applyLink
    forM_ (choice ^. #disablePaths) $ \path -> do
      addDisabledSkill (choice ^. #configFile) path >>= either throwIO (const (pure ()))
    forM_ (choice ^. #oldDisabled) $ \path ->
      unless (Text.unpack path `elem` (choice ^. #disablePaths)) $
        removeDisabledSkill (choice ^. #configFile) (Text.unpack path) >>= either throwIO (const (pure ()))
    forM_ (choice ^. #oldLinks) $ \link ->
      unless (any ((== link ^. #location) . view #location) (choice ^. #links)) $ do
        _ <- removeLink link
        pure ()
  case result of
    Left e -> throwIO (KitVisibilityNotApplied (Text.pack (show e)) (map (view #location) (choice ^. #links ++ choice ^. #oldLinks)))
    Right (Left err) ->
      throwIO
        ( KitVisibilityNotApplied
            (Text.pack (show err))
            (map (view #location) (choice ^. #links ++ choice ^. #oldLinks) ++ [choice ^. #configFile])
        )
    Right (Right ()) -> do
      meta <- readSidecar (choice ^. #sidecarFile)
      forM_ meta $ \current -> do
        let final =
              current
                & #sharedLinks
                .~ Just (map (Text.pack . view #location) (choice ^. #links))
                & #codexDisabledSkills
                .~ Just (choice ^. #trackedDisabled)
        when (current /= final) $
          executePlan [PlannedWrite (choice ^. #sidecarFile) (WriteBytes (encode final))]
            >>= either (\err -> throwIO (KitVisibilityNotApplied (Text.pack (show err)) [choice ^. #sidecarFile])) pure

repairSkippedVisibility :: [ProviderVisibility] -> IO ()
repairSkippedVisibility choices = do
  let writes =
        [ PlannedWrite
            (choice ^. #sidecarFile)
            ( WriteBytes
                ( encode
                    ( old
                        & #visibility
                        .~ (visibilityLabel <$> (choice ^. #requested))
                        & #visibilitySource
                        .~ (choice ^. #source)
                        & #sharedLinks
                        .~ Just (nub (map (Text.pack . view #location) (choice ^. #links ++ choice ^. #oldLinks)))
                        & #codexDisabledSkills
                        .~ Just (nub (choice ^. #trackedDisabled ++ choice ^. #oldDisabled))
                    )
                )
            )
        | choice <- choices,
          Just old <- [choice ^. #previous],
          has _Just (choice ^. #requested)
        ]
  executePlan writes >>= either throwIO pure
  forM_ choices applyVisibility

doInstall :: KitConfig -> FilePath -> KitItem -> KitScope -> [ProviderVisibility] -> IO ()
doInstall config repoDir item scope choices = do
  writes <- planInstall config repoDir item scope choices
  executePlan writes >>= either throwIO pure
  forM_ choices applyVisibility

-- | One installed asset: its name relative to the provider's installed
--   root, where it goes, and the bytes to put there.
data PlannedAsset = PlannedAsset
  { relativeName :: !FilePath,
    target :: !FilePath,
    bytes :: !LBS.ByteString
  }
  deriving stock (Generic)

planInstall :: KitConfig -> FilePath -> KitItem -> KitScope -> [ProviderVisibility] -> IO [PlannedWrite]
planInstall config repoDir item _scope choices = do
  safeName <- orThrow (KitUnsafeName (itemName item)) (safeItemName (itemName item))
  sources <- either throwIO pure (itemSources item)
  resolved <- resolveSources repoDir sources
  contents <- forM resolved $ \(rel, path) -> do
    read' <- try @IOException (BS.readFile path)
    case read' of
      Left e -> throwIO (KitSourceUnreadable path (Text.pack (show e)))
      Right raw -> pure (rel, path, raw)
  let upstreamHash = hashEntries [(rel, raw) | (rel, _, raw) <- contents]
  fmap concat $
    forM choices $ \choice -> do
      let provider = choice ^. #provider
          targetBase = choice ^. #baseDir
      assets <- providerAssets config provider targetBase safeName item contents
      let installedNames = [Text.pack (asset ^. #relativeName) | asset <- assets]
          installedDigest =
            hashEntries [(asset ^. #relativeName, LBS.toStrict (asset ^. #bytes)) | asset <- assets]
      meta <-
        newSidecarMeta
          item
          upstreamHash
          installedNames
          installedDigest
          (visibilityLabel <$> (choice ^. #requested))
          (choice ^. #source)
          (nub (map (Text.pack . view #location) (choice ^. #links ++ choice ^. #oldLinks)))
          (nub (choice ^. #trackedDisabled ++ choice ^. #oldDisabled))
      let assetWrites =
            [ PlannedWrite {destination = asset ^. #target, content = WriteBytes (asset ^. #bytes)}
            | asset <- assets
            ]
          sidecarWrite =
            PlannedWrite
              { destination =
                  sidecarPath provider (kitItemKind item) (Text.pack safeName) targetBase (sidecarFileName config),
                content = WriteBytes (encode meta)
              }
      pure (assetWrites ++ [sidecarWrite])

-- | Turn an item's sources into what one provider gets. A skill's files
--   keep their names below the skill directory. An agent's first file
--   becomes the provider's agent file — copied for Claude, rendered to
--   TOML for Codex — and every remaining file goes into a resource
--   directory named after the agent beside it, because both providers'
--   agent directories are flat and a stray Markdown file there would be
--   discovered as a bogus agent.
providerAssets ::
  KitConfig ->
  InteractiveProvider ->
  FilePath ->
  FilePath ->
  KitItem ->
  [(FilePath, FilePath, BS.ByteString)] ->
  IO [PlannedAsset]
providerAssets config provider targetBase safeName (KitSkillItem _) contents =
  pure
    [ PlannedAsset
        { relativeName = rel,
          target = skillTarget config provider targetBase safeName </> rel,
          bytes = LBS.fromStrict raw
        }
    | (rel, _, raw) <- contents
    ]
providerAssets config provider targetBase safeName (KitAgentItem entry) contents =
  case contents of
    [] -> throwIO (KitItemHasNoFiles (entry ^. #name))
    (_, primaryPath, primaryRaw) : extras -> do
      let agentFile = agentTarget config provider targetBase safeName
          resourceDir = agentResourceDir config provider targetBase safeName
      body <- decodeSource primaryPath primaryRaw
      let primaryBytes = case provider of
            InteractiveClaude -> LBS.fromStrict primaryRaw
            InteractiveCodex -> LBS.fromStrict (Text.Encoding.encodeUtf8 (agentAsCodexToml entry body))
      pure $
        PlannedAsset
          { relativeName = takeFileName agentFile,
            target = agentFile,
            bytes = primaryBytes
          }
          : [ PlannedAsset
                { relativeName = safeName </> rel,
                  target = resourceDir </> rel,
                  bytes = LBS.fromStrict raw
                }
            | (rel, _, raw) <- extras
            ]

-- | Agent bodies are UTF-8, not whatever the locale says. (ADR 0007.)
decodeSource :: FilePath -> BS.ByteString -> IO Text
decodeSource path raw =
  case Text.Encoding.decodeUtf8' raw of
    Left err -> throwIO (KitSourceUnreadable path (Text.pack (show err)))
    Right text -> pure text

-- | Resolve every listed file through 'safeSourcePath', pairing the name
-- relative to the item's base with the absolute path to read.
resolveSources :: FilePath -> ItemSources -> IO [(FilePath, FilePath)]
resolveSources repoDir sources =
  forM (sources ^. #files) $ \rel -> do
    resolved <- safeSourcePath repoDir ((sources ^. #base) </> rel)
    (rel,) <$> either throwIO pure resolved

isInstalled :: KitConfig -> Text -> KitScope -> IO Bool
isInstalled config n scope = do
  safeName <- orThrow (KitUnsafeName n) (safeItemName n)
  results <- forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    skillExists <- doesDirectoryExist (skillTarget config provider providerBase safeName)
    agentExists <- doesFileExist (agentTarget config provider providerBase safeName)
    skillMetadata <- doesFileExist (sidecarPath provider SkillKind n providerBase (sidecarFileName config))
    agentMetadata <- doesFileExist (agentSidecarTarget config provider providerBase safeName)
    pure (skillExists || agentExists || skillMetadata || agentMetadata)
  pure (or results)

-- | Run an action that may raise a 'KitError' and hand the caller a
--   value. Only 'KitError' is caught; anything else propagates.
kitTry :: IO a -> IO (Either KitError a)
kitTry = try

orThrow :: (Text -> KitError) -> Either Text a -> IO a
orThrow toError = either (throwIO . toError) pure

removeIfDirectory :: FilePath -> IO Bool
removeIfDirectory dir = do
  exists <- doesDirectoryExist dir
  when exists (removeDirectoryRecursive dir)
  pure exists

removeIfFile :: FilePath -> IO Bool
removeIfFile file = do
  exists <- doesFileExist file
  when exists (removeFile file)
  pure exists

skillTarget :: KitConfig -> InteractiveProvider -> FilePath -> FilePath -> FilePath
skillTarget _config provider targetBase n =
  targetBase </> skillTargetPath provider InteractiveProjectScope n

agentTarget :: KitConfig -> InteractiveProvider -> FilePath -> FilePath -> FilePath
agentTarget _config provider targetBase n =
  targetBase </> agentTargetPath provider InteractiveProjectScope n

-- | Where a multi-file agent's extra files live: beside its agent file,
--   in a directory named after the agent.
agentResourceDir :: KitConfig -> InteractiveProvider -> FilePath -> FilePath -> FilePath
agentResourceDir config provider targetBase n =
  takeDirectory (agentTarget config provider targetBase n) </> n

-- | The directory the names in a sidecar's @installedFiles@ are relative
--   to, per provider and kind.
installedRoot :: KitConfig -> InteractiveProvider -> FilePath -> KitItemKind -> FilePath -> FilePath
installedRoot config provider targetBase SkillKind n = skillTarget config provider targetBase n
installedRoot config provider targetBase AgentKind n =
  takeDirectory (agentTarget config provider targetBase n)

agentSidecarTarget :: KitConfig -> InteractiveProvider -> FilePath -> FilePath -> FilePath
agentSidecarTarget config provider targetBase n =
  sidecarPath provider AgentKind (Text.pack n) targetBase (sidecarFileName config)

skillNameDesc :: SkillEntry -> (Text, Text)
skillNameDesc entry = (entry ^. #name, entry ^. #description)

agentNameDesc :: AgentEntry -> (Text, Text)
agentNameDesc entry = (entry ^. #name, entry ^. #description)

agentAsCodexToml :: AgentEntry -> Text -> Text
agentAsCodexToml entry body =
  codexCustomAgentToml
    CodexCustomAgent
      { name = entry ^. #name,
        description = entry ^. #description,
        developerInstructions = stripYamlFrontmatter body
      }

-- | Drop a leading YAML frontmatter block and normalise line endings to
--   LF. Every branch normalises, including input with no frontmatter and
--   input whose frontmatter is never closed.
stripYamlFrontmatter :: Text -> Text
stripYamlFrontmatter input =
  case textLines of
    firstLine : rest
      | isDelimiter firstLine,
        (_, _ : body) <- break isDelimiter rest ->
          Text.intercalate "\n" body
    _ -> Text.intercalate "\n" textLines
  where
    textLines = map (Text.dropWhileEnd (== '\r')) (Text.splitOn "\n" input)
    isDelimiter = (== "---") . Text.stripEnd
