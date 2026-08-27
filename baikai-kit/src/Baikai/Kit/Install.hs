-- | Reading the manifest and installing what it lists.
--
--   Every function here returns @'Either' 'KitError' a@ and prints
--   nothing: rendering and exiting belong to 'Baikai.Kit.Command.runKit'.
--   Internally the module raises 'KitError' and catches it at each
--   exported boundary, which keeps the plumbing readable without changing
--   what a caller observes.
module Baikai.Kit.Install
  ( loadManifest,
    loadManifestMaybe,
    lookupItem,
    installItem,
    installFrom,
    uninstallItem,
    renderUninstallReport,
    RemovalOutcome (..),
    UpdateReport (..),
    updateKit,
    listAvailable,
    renderAvailable,
    stripYamlFrontmatter,
  )
where

import Baikai.AgentAssets
  ( CodexCustomAgent (..),
    agentTargetPath,
    codexCustomAgentToml,
    skillTargetPath,
  )
import Baikai.Interactive (InteractiveProvider (..), InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Config (KitConfig, KitScope (..), kitCacheDir, providerAgentsBase, providerLabel, scopeLabel, sidecarFileName)
import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Manifest
  ( AgentEntry,
    ItemSources,
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    SkillEntry,
    itemName,
    itemSources,
    kitItemKind,
    supportedManifestVersions,
  )
import Baikai.Kit.Path (safeItemName, safeSourcePath)
import Baikai.Kit.Repo (KitRepo, PullResult (..), RepoRefresh (..), ensureKitRepo, pullKitRepo)
import Baikai.Kit.Sidecar (computeKitHash, newSidecarMeta, sidecarPath)
import Baikai.Prelude
import Control.Exception (IOException, catch, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (eitherDecodeFileStrict', encode)
import Data.ByteString.Lazy qualified as LBS
import Data.List (find, nub)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeDirectoryRecursive,
    removeFile,
    renameFile,
  )
import System.FilePath (takeDirectory, (</>))

data PlannedWrite = PlannedWrite
  { destination :: !FilePath,
    content :: !WriteContent
  }

data WriteContent
  = CopyFrom !FilePath
  | WriteBytes !LBS.ByteString

data RemovalOutcome = RemovalOutcome
  { provider :: !InteractiveProvider,
    skillRemoved :: !Bool,
    agentRemoved :: !Bool,
    sidecarRemoved :: !Bool
  }
  deriving stock (Eq, Generic, Show)

-- | What @kit update@ did, for the caller to render.
data UpdateReport = UpdateReport
  { refresh :: !RepoRefresh,
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
installItem :: KitConfig -> Text -> KitScope -> IO (Either KitError KitItem)
installItem config itemN scope = kitTry $ do
  repo <- requireRepo config
  manifest <- loadManifestIO (repo ^. #dir)
  installFromIO config (repo ^. #dir) manifest itemN scope

-- | The network-free half of 'installItem': install one item from a
--   manifest already read out of @repoDir@.
installFrom :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> IO (Either KitError KitItem)
installFrom config repoDir manifest itemN scope =
  kitTry (installFromIO config repoDir manifest itemN scope)

uninstallItem :: KitConfig -> Text -> KitScope -> IO (Either KitError [RemovalOutcome])
uninstallItem config n scope = kitTry $ do
  safeName <- orThrow (KitUnsafeName n) (safeItemName n)
  forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    skillRemoved <- removeIfDirectory (skillTarget config provider providerBase safeName)
    agentRemoved <- removeIfFile (agentTarget config provider providerBase safeName)
    sidecarRemoved <- removeIfFile (agentSidecarTarget config provider providerBase safeName)
    pure RemovalOutcome {provider, skillRemoved, agentRemoved, sidecarRemoved}

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
  | any (^. #sidecarRemoved) outcomes =
      "Removed stale kit metadata for '" <> n <> "' from " <> scopeLabel scope <> " scope."
  | otherwise =
      "'" <> n <> "' is not installed in " <> scopeLabel scope <> " scope."
  where
    assetRemoved outcome = outcome ^. #skillRemoved || outcome ^. #agentRemoved
    removedKinds =
      nub $
        ["skill" | any (^. #skillRemoved) outcomes]
          ++ ["agent" | any (^. #agentRemoved) outcomes]
    removedProviders = map (providerLabel . view #provider) (filter assetRemoved outcomes)

-- | Refresh the cache and reinstall the items that are already installed.
--   A failed refresh is an error here, unlike the other verbs: fetching
--   is what update is for.
updateKit :: KitConfig -> Maybe Text -> IO (Either KitError UpdateReport)
updateKit config mName = kitTry $ do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist cacheDir
  refresh <-
    if exists
      then do
        result <- pullKitRepo config cacheDir
        case result of
          PullSucceeded -> pure RepoPulled
          PullFailed err -> throwIO (KitPullFailed err)
      else view #refresh <$> requireRepo config
  manifest <- loadManifestIO cacheDir
  updated <- reinstallPresentIO config cacheDir manifest mName
  pure UpdateReport {refresh, updated, skipped = []}

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

installFromIO :: KitConfig -> FilePath -> KitManifest -> Text -> KitScope -> IO KitItem
installFromIO config repoDir manifest itemN scope =
  case lookupItem itemN manifest of
    Nothing -> throwIO (KitItemNotFound itemN)
    Just item -> do
      doInstall config repoDir item scope
      pure item

requireRepo :: KitConfig -> IO KitRepo
requireRepo config = ensureKitRepo config >>= either throwIO pure

reinstallPresentIO :: KitConfig -> FilePath -> KitManifest -> Maybe Text -> IO [(Text, KitScope)]
reinstallPresentIO config repoDir manifest mName =
  fmap concat . forM candidates $ \n ->
    fmap concat . forM [UserScope, ProjectScope] $ \scope -> do
      installed <- isInstalled config n scope
      case (installed, lookupItem n manifest) of
        (True, Just item) -> do
          doInstall config repoDir item scope
          pure [(n, scope)]
        _ -> pure []
  where
    candidates = case mName of
      Just n -> [n]
      Nothing ->
        map (view #name) (manifest ^. #skills)
          ++ map (view #name) (manifest ^. #agents)

doInstall :: KitConfig -> FilePath -> KitItem -> KitScope -> IO ()
doInstall config repoDir item scope = do
  writes <- planInstall config repoDir item scope
  outcome <- try @IOException (executePlan writes)
  case outcome of
    Left e -> throwIO (KitWriteFailed (Text.pack (show e)) [] [])
    Right () -> pure ()

planInstall :: KitConfig -> FilePath -> KitItem -> KitScope -> IO [PlannedWrite]
planInstall config repoDir item scope = do
  safeName <- orThrow (KitUnsafeName (itemName item)) (safeItemName (itemName item))
  sources <- either throwIO pure (itemSources item)
  resolved <- resolveSources repoDir sources
  hashStr <- either throwIO pure =<< computeKitHash repoDir (sources ^. #base) (sources ^. #files)
  meta <- newSidecarMeta item hashStr
  let sidecarWrite provider targetBase =
        PlannedWrite
          { destination = sidecarPath provider (kitItemKind item) (Text.pack safeName) targetBase (sidecarFileName config),
            content = WriteBytes (encode meta)
          }
  case item of
    KitSkillItem _ ->
      fmap concat $
        forM (config ^. #providers) $ \provider -> do
          targetBase <- providerAgentsBase config provider scope
          let targetDir = skillTarget config provider targetBase safeName
              fileWrites =
                [ PlannedWrite {destination = targetDir </> rel, content = CopyFrom source}
                | (rel, source) <- resolved
                ]
          pure (fileWrites ++ [sidecarWrite provider targetBase])
    KitAgentItem entry -> do
      primarySource <- case resolved of
        (_, source) : _ -> pure source
        [] -> throwIO (KitItemHasNoFiles (entry ^. #name))
      body <- Text.IO.readFile primarySource
      fmap concat $
        forM (config ^. #providers) $ \provider -> do
          targetBase <- providerAgentsBase config provider scope
          let dstFile = agentTarget config provider targetBase safeName
              agentWrite =
                case provider of
                  InteractiveClaude ->
                    PlannedWrite {destination = dstFile, content = CopyFrom primarySource}
                  InteractiveCodex ->
                    PlannedWrite
                      { destination = dstFile,
                        content = WriteBytes (LBS.fromStrict (Text.Encoding.encodeUtf8 (agentAsCodexToml entry body)))
                      }
          pure [agentWrite, sidecarWrite provider targetBase]

-- | Resolve every listed file through 'safeSourcePath', pairing the name
-- relative to the item's base with the absolute path to read.
resolveSources :: FilePath -> ItemSources -> IO [(FilePath, FilePath)]
resolveSources repoDir sources =
  forM (sources ^. #files) $ \rel -> do
    resolved <- safeSourcePath repoDir ((sources ^. #base) </> rel)
    (rel,) <$> either throwIO pure resolved

executePlan :: [PlannedWrite] -> IO ()
executePlan writes = do
  tempPaths <- phaseOne [] writes
  forM_ tempPaths $ \(temp, final) -> renameFile temp final
  where
    phaseOne temps [] = pure (reverse temps)
    phaseOne temps (PlannedWrite {destination, content} : rest) = do
      let temp = destination <> ".baikai-kit-tmp"
      result <-
        try @IOException $ do
          createDirectoryIfMissing True (takeDirectory destination)
          writeTemp content temp
          pure (temp, destination)
      case result of
        Left e -> cleanupTemps temps >> throwIO e
        Right tempPair ->
          phaseOne (tempPair : temps) rest
            `catch` \(e :: IOException) -> cleanupTemps (tempPair : temps) >> throwIO e

    writeTemp (CopyFrom src) temp = LBS.readFile src >>= LBS.writeFile temp
    writeTemp (WriteBytes bytes) temp = LBS.writeFile temp bytes

    cleanupTemps temps =
      forM_ temps $ \(temp, _) -> do
        _ <- try @IOException (removeFile temp)
        pure ()

isInstalled :: KitConfig -> Text -> KitScope -> IO Bool
isInstalled config n scope = do
  safeName <- orThrow (KitUnsafeName n) (safeItemName n)
  results <- forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    skillExists <- doesDirectoryExist (skillTarget config provider providerBase safeName)
    agentExists <- doesFileExist (agentTarget config provider providerBase safeName)
    pure (skillExists || agentExists)
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

stripYamlFrontmatter :: Text -> Text
stripYamlFrontmatter input =
  case map dropCr (Text.splitOn "\n" input) of
    "---" : rest
      | (_, _ : body) <- break (== "---") rest ->
          Text.intercalate "\n" body
    _ -> input
  where
    dropCr = Text.dropWhileEnd (== '\r')
