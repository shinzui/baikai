module Baikai.Kit.Install
  ( loadManifest,
    loadManifestMaybe,
    lookupItem,
    installItem,
    uninstallItem,
    updateKit,
    listAvailable,
  )
where

import Baikai.AgentAssets
  ( CodexCustomAgent (..),
    agentTargetPath,
    codexCustomAgentToml,
    skillTargetPath,
  )
import Baikai.Interactive (InteractiveProvider (..), InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Config (KitConfig, KitScope (..), kitCacheDir, providerAgentsBase, scopeLabel, sidecarFileName)
import Baikai.Kit.Manifest
  ( AgentEntry,
    KitItem (..),
    KitManifest (..),
    SkillEntry,
    agentSources,
    itemKind,
  )
import Baikai.Kit.Manifest qualified as Manifest
import Baikai.Kit.Repo (ensureKitRepo, pullKitRepo)
import Baikai.Kit.Sidecar (computeKitHash, sidecarPath, writeSidecar)
import Baikai.Prelude
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (eitherDecodeFileStrict')
import Data.List (find)
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import System.Directory
  ( copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    removeDirectoryRecursive,
    removeFile,
  )
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

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
      doInstall config repoDir item scope
      Text.IO.putStrLn $
        "Installed " <> itemKind item <> " '" <> itemN <> "' to " <> scopeLabel scope <> " scope."

uninstallItem :: KitConfig -> Text -> KitScope -> IO ()
uninstallItem config n scope = do
  removals <- fmap catMaybes $
    forM (config ^. #providers) $ \provider -> do
      providerBase <- providerAgentsBase config provider scope
      skillRemoved <- removeIfDirectory (skillTarget config provider providerBase n)
      agentRemoved <- removeIfFile (agentTarget config provider providerBase n)
      sidecarRemoved <- removeIfFile (agentSidecarTarget config provider providerBase n)
      pure $
        if skillRemoved
          then Just "skill"
          else
            if agentRemoved || sidecarRemoved
              then Just "agent"
              else Nothing
  case removals of
    (kind : _) ->
      Text.IO.putStrLn $
        "Uninstalled " <> kind <> " '" <> n <> "' from " <> scopeLabel scope <> " scope."
    [] ->
      Text.IO.putStrLn $ "'" <> n <> "' is not installed in " <> scopeLabel scope <> " scope."

updateKit :: KitConfig -> Maybe Text -> IO ()
updateKit config mName = do
  cacheDir <- kitCacheDir config
  exists <- doesDirectoryExist cacheDir
  if exists
    then do
      pullKitRepo config cacheDir
      Text.IO.putStrLn "Kit repository updated."
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
doInstall config repoDir item@(KitSkillItem entry) scope = do
  let sourceDir = repoDir </> Text.unpack (entry ^. #path)
  hashStr <- computeKitHash sourceDir (entry ^. #files)
  forM_ (config ^. #providers) $ \provider -> do
    targetBase <- providerAgentsBase config provider scope
    let targetDir = skillTarget config provider targetBase (entry ^. #name)
    createDirectoryIfMissing True targetDir
    mapM_ (copySkillFile repoDir entry targetDir) (entry ^. #files)
    writeSidecar provider item targetBase (sidecarFileName config) hashStr
doInstall config repoDir item@(KitAgentItem entry) scope = do
  let sources = agentSources entry
      sourceBase = agentSourceBase repoDir entry
      relFiles = map (Text.pack . snd) sources
  hashStr <- computeKitHash sourceBase relFiles
  primarySource <- case sources of
    (source, _) : _ -> pure source
    [] -> do
      hPutStrLn stderr $ "Error: agent '" <> Text.unpack (entry ^. #name) <> "' has no source files."
      exitFailure
  forM_ (config ^. #providers) $ \provider -> do
    targetBase <- providerAgentsBase config provider scope
    let dstFile = agentTarget config provider targetBase (entry ^. #name)
    createDirectoryIfMissing True (takeDirectory dstFile)
    case provider of
      InteractiveClaude -> copyFile (repoDir </> primarySource) dstFile
      InteractiveCodex -> do
        body <- Text.IO.readFile (repoDir </> primarySource)
        Text.IO.writeFile dstFile (agentAsCodexToml entry body)
    writeSidecar provider item targetBase (sidecarFileName config) hashStr

copySkillFile :: FilePath -> SkillEntry -> FilePath -> Text -> IO ()
copySkillFile repoDir entry targetDir fileName = do
  let src = repoDir </> Text.unpack (entry ^. #path) </> Text.unpack fileName
      dst = targetDir </> Text.unpack fileName
  createDirectoryIfMissing True (takeDirectory dst)
  copyFile src dst

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
  results <- forM (config ^. #providers) $ \provider -> do
    providerBase <- providerAgentsBase config provider scope
    skillExists <- doesDirectoryExist (skillTarget config provider providerBase n)
    agentExists <- doesFileExist (agentTarget config provider providerBase n)
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

skillTarget :: KitConfig -> InteractiveProvider -> FilePath -> Text -> FilePath
skillTarget _config provider targetBase n =
  targetBase </> skillTargetPath provider InteractiveProjectScope (Text.unpack n)

agentTarget :: KitConfig -> InteractiveProvider -> FilePath -> Text -> FilePath
agentTarget _config provider targetBase n =
  targetBase </> agentTargetPath provider InteractiveProjectScope (Text.unpack n)

agentSidecarTarget :: KitConfig -> InteractiveProvider -> FilePath -> Text -> FilePath
agentSidecarTarget config provider targetBase n =
  sidecarPath provider (KitAgentItem (dummyAgent n)) targetBase (sidecarFileName config)

dummyAgent :: Text -> AgentEntry
dummyAgent n =
  Manifest.AgentEntry
    { name = n,
      description = "",
      version = Nothing,
      path = n,
      files = Nothing
    }

skillNameDesc :: SkillEntry -> (Text, Text)
skillNameDesc entry = (entry ^. #name, entry ^. #description)

agentNameDesc :: AgentEntry -> (Text, Text)
agentNameDesc entry = (entry ^. #name, entry ^. #description)

agentSourceBase :: FilePath -> AgentEntry -> FilePath
agentSourceBase repoDir entry =
  case entry ^. #files of
    Just _ -> repoDir </> Text.unpack (entry ^. #path)
    Nothing -> repoDir </> takeDirectory (Text.unpack (entry ^. #path))

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
  case Text.stripPrefix "---\n" input of
    Nothing -> input
    Just rest ->
      case Text.breakOn "\n---\n" rest of
        (_, "") -> input
        (_, after) -> Text.drop 5 after
