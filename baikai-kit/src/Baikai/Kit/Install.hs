module Baikai.Kit.Install
  ( loadManifest,
    loadManifestMaybe,
    lookupItem,
    installItem,
    uninstallItem,
    uninstallOutcomes,
    renderUninstallReport,
    RemovalOutcome (..),
    updateKit,
    listAvailable,
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
import Baikai.Kit.Error (KitError (..), renderKitError)
import Baikai.Kit.Manifest
  ( AgentEntry,
    ItemSources,
    KitItem (..),
    KitItemKind (..),
    KitManifest (..),
    SkillEntry,
    itemKind,
    itemName,
    itemSources,
    kitItemKind,
  )
import Baikai.Kit.Path (safeItemName, safeSourcePath)
import Baikai.Kit.Repo (PullResult (..), ensureKitRepo, pullKitRepo)
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
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

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

loadManifest :: FilePath -> IO KitManifest
loadManifest repoDir = do
  let manifestPath = repoDir </> "kit.json"
  exists <- doesFileExist manifestPath
  unless exists $ do
    hPutStrLn stderr "Error: kit.json not found in kit repository."
    exitFailure
  result <- eitherDecodeFileStrict' manifestPath
  case result of
    Left err -> do
      hPutStrLn stderr $ "Error: Failed to parse kit.json: " <> err
      exitFailure
    Right manifest -> pure manifest

loadManifestMaybe :: FilePath -> IO (Maybe KitManifest)
loadManifestMaybe "" = pure Nothing
loadManifestMaybe cacheDir = do
  let manifestPath = cacheDir </> "kit.json"
  exists <- doesFileExist manifestPath
  if not exists
    then pure Nothing
    else do
      result <- eitherDecodeFileStrict' manifestPath
      case result of
        Left err -> do
          hPutStrLn stderr $ "Warning: failed to parse kit.json: " <> err
          pure Nothing
        Right manifest -> pure (Just manifest)

lookupItem :: Text -> KitManifest -> Maybe KitItem
lookupItem n manifest =
  case find (\entry -> entry ^. #name == n) (manifest ^. #skills) of
    Just skill -> Just (KitSkillItem skill)
    Nothing -> KitAgentItem <$> find (\entry -> entry ^. #name == n) (manifest ^. #agents)

installItem :: KitConfig -> Text -> KitScope -> IO ()
installItem config itemN scope = do
  repoDir <- ensureKitRepo config
  manifest <- loadManifest repoDir
  case lookupItem itemN manifest of
    Nothing -> do
      hPutStrLn stderr $ "Error: '" <> Text.unpack itemN <> "' not found in kit manifest."
      exitFailure
    Just item -> do
      result <- try @KitError (try @IOException (doInstall config repoDir item scope))
      case result of
        Right (Right ()) ->
          Text.IO.putStrLn $
            "Installed " <> itemKind item <> " '" <> itemN <> "' to " <> scopeLabel scope <> " scope."
        Right (Left e) -> do
          hPutStrLn stderr $ "Error: install failed, no changes were made: " <> show e
          exitFailure
        Left kitErr -> do
          Text.IO.hPutStrLn stderr ("Error: " <> renderKitError kitErr)
          exitFailure

uninstallItem :: KitConfig -> Text -> KitScope -> IO ()
uninstallItem config n scope = do
  outcomes <- uninstallOutcomes config n scope
  Text.IO.putStrLn (renderUninstallReport n scope outcomes)

uninstallOutcomes :: KitConfig -> Text -> KitScope -> IO [RemovalOutcome]
uninstallOutcomes config n scope = do
  safeName <- requireSafe "item name" (safeItemName n)
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

updateKit :: KitConfig -> Maybe Text -> IO ()
updateKit config mName = do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist cacheDir
  if exists
    then do
      result <- pullKitRepo config cacheDir
      case result of
        PullSucceeded -> Text.IO.putStrLn "Kit repository updated."
        PullFailed err -> do
          hPutStrLn stderr $ "Error: failed to update kit repository: " <> Text.unpack err
          hPutStrLn stderr "The cached copy is unchanged; installed items were not reinstalled."
          exitFailure
    else do
      _ <- ensureKitRepo config
      Text.IO.putStrLn "Kit repository cloned."
  manifest <- loadManifest =<< kitCacheDir config
  case mName of
    Just n -> do
      reinstallIfPresent config n UserScope manifest
      reinstallIfPresent config n ProjectScope manifest
    Nothing -> reinstallAllPresent config manifest

listAvailable :: KitConfig -> IO ()
listAvailable config = do
  repoDir <- ensureKitRepo config
  manifest <- loadManifest repoDir
  let sk = manifest ^. #skills
      ag = manifest ^. #agents
  if null sk && null ag
    then Text.IO.putStrLn "No items available in the kit."
    else do
      unless (null sk) $ do
        Text.IO.putStrLn "Skills:"
        let maxLen = maximum $ map (Text.length . view #name) sk
        mapM_ (printEntry maxLen . skillNameDesc) sk
      unless (null ag) $ do
        unless (null sk) (Text.IO.putStrLn "")
        Text.IO.putStrLn "Agents:"
        let maxLen = maximum $ map (Text.length . view #name) ag
        mapM_ (printEntry maxLen . agentNameDesc) ag
  where
    printEntry maxLen (n, desc) =
      Text.IO.putStrLn $ "  " <> Text.justifyLeft (maxLen + 2) ' ' n <> desc

doInstall :: KitConfig -> FilePath -> KitItem -> KitScope -> IO ()
doInstall config repoDir item scope =
  planInstall config repoDir item scope >>= executePlan

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

orThrow :: (Text -> KitError) -> Either Text a -> IO a
orThrow toError = either (throwIO . toError) pure

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

requireSafe :: Text -> Either Text a -> IO a
requireSafe what = \case
  Right a -> pure a
  Left reason -> do
    hPutStrLn stderr $ "Error: unsafe " <> Text.unpack what <> ": " <> Text.unpack reason
    exitFailure

reinstallIfPresent :: KitConfig -> Text -> KitScope -> KitManifest -> IO ()
reinstallIfPresent config n scope manifest = do
  installed <- isInstalled config n scope
  when installed $
    case lookupItem n manifest of
      Nothing -> pure ()
      Just item -> do
        repoDir <- kitCacheDir config
        doInstall config repoDir item scope
        Text.IO.putStrLn $ "Updated '" <> n <> "' (" <> scopeLabel scope <> ")"

reinstallAllPresent :: KitConfig -> KitManifest -> IO ()
reinstallAllPresent config manifest = do
  let allNames =
        map (view #name) (manifest ^. #skills)
          ++ map (view #name) (manifest ^. #agents)
  repoDir <- kitCacheDir config
  updated <- fmap sum $ forM allNames $ \n -> do
    userInstalled <- isInstalled config n UserScope
    projectInstalled <- isInstalled config n ProjectScope
    let count = (if userInstalled then 1 else 0) + (if projectInstalled then 1 else 0) :: Int
    when userInstalled $
      case lookupItem n manifest of
        Nothing -> pure ()
        Just item -> doInstall config repoDir item UserScope
    when projectInstalled $
      case lookupItem n manifest of
        Nothing -> pure ()
        Just item -> doInstall config repoDir item ProjectScope
    pure count
  Text.IO.putStrLn $ "Updated " <> Text.pack (show updated) <> " item(s)."

isInstalled :: KitConfig -> Text -> KitScope -> IO Bool
isInstalled config n scope = do
  safeName <- requireSafe "item name" (safeItemName n)
  results <- forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    skillExists <- doesDirectoryExist (skillTarget config provider providerBase safeName)
    agentExists <- doesFileExist (agentTarget config provider providerBase safeName)
    pure (skillExists || agentExists)
  pure (or results)

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
