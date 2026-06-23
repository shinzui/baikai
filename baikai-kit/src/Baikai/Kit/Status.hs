module Baikai.Kit.Status
  ( KitState (..),
    StatusRow (..),
    classify,
    collectStatus,
    kitStatus,
    renderState,
  )
where

import Baikai.AgentAssets (AgentAssetProvider, agentTargetPath, skillTargetPath)
import Baikai.Interactive (InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Config (KitConfig, KitScope (..), resolveAgentsBase, sidecarFileName)
import Baikai.Kit.Install (loadManifestMaybe, lookupItem)
import Baikai.Kit.Manifest (AgentEntry, KitItem (..), agentSources, itemVersion)
import Baikai.Kit.Repo (ensureKitRepo)
import Baikai.Kit.Sidecar (SidecarMeta, computeKitHash, readSidecar, sidecarPath)
import Baikai.Prelude
import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, (</>))

data KitState
  = KitUpToDate
  | KitOutdated
  | KitDirty
  | KitUnknown
  deriving stock (Eq, Show)

data StatusRow = StatusRow
  { name :: !Text,
    kind :: !Text,
    scope :: !Text,
    installedVersion :: !(Maybe Text),
    latestVersion :: !(Maybe Text),
    state :: !KitState
  }
  deriving stock (Eq, Generic, Show)

renderState :: KitState -> Text
renderState = \case
  KitUpToDate -> "up-to-date"
  KitOutdated -> "outdated"
  KitDirty -> "dirty"
  KitUnknown -> "unknown"

classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
classify Nothing _ _ = KitUnknown
classify (Just _) Nothing _ = KitUnknown
classify (Just sm) (Just it) mUpstreamHash =
  let mInstalled = sm ^. #version
      mLatest = itemVersion it
   in case mLatest of
        Just latest
          | mInstalled /= Just latest -> KitOutdated
        _ ->
          case mUpstreamHash of
            Just up | up /= sm ^. #hash -> KitDirty
            _ -> KitUpToDate

kitStatus :: KitConfig -> IO ()
kitStatus config = do
  cacheDir <- resolveCacheOrEmpty config
  userDir <- resolveAgentsBase config UserScope
  projectDir <- resolveAgentsBase config ProjectScope
  rows <- collectStatus config cacheDir [(userDir, "user"), (projectDir, "project")]
  renderStatusTable rows

collectStatus :: KitConfig -> FilePath -> [(FilePath, Text)] -> IO [StatusRow]
collectStatus config cacheDir scopes = do
  mManifest <- loadManifestMaybe cacheDir
  fmap concat . forM scopes $ \(baseDir, scopeText) -> do
    items <- scanInstalled config baseDir
    forM items $ \(provider, itemName', _itemKind) -> do
      let mItem = lookupItem itemName' =<< mManifest
      mSidecar <- case mItem of
        Just item -> readSidecar (sidecarPath provider item baseDir (sidecarFileName config))
        Nothing -> pure Nothing
      mUpstreamHash <- upstreamHash cacheDir mItem
      let state' = classify mSidecar mItem mUpstreamHash
      pure
        StatusRow
          { name = itemName',
            kind = maybe _itemKind itemKindOf mItem,
            scope = scopeText,
            installedVersion = mSidecar >>= (^. #version),
            latestVersion = mItem >>= itemVersion,
            state = state'
          }

resolveCacheOrEmpty :: KitConfig -> IO FilePath
resolveCacheOrEmpty config = do
  result <- try @IOException (ensureKitRepo config)
  case result of
    Right dir -> do
      manifestExists <- doesFileExist (dir </> "kit.json")
      pure (if manifestExists then dir else "")
    Left _ -> pure ""

upstreamHash :: FilePath -> Maybe KitItem -> IO (Maybe Text)
upstreamHash "" _ = pure Nothing
upstreamHash _ Nothing = pure Nothing
upstreamHash cacheDir (Just (KitSkillItem entry)) =
  tryHash (cacheDir </> Text.unpack (entry ^. #path)) (entry ^. #files)
upstreamHash cacheDir (Just (KitAgentItem entry)) =
  tryHash (agentSourceBase cacheDir entry) (map (Text.pack . snd) (agentSources entry))

tryHash :: FilePath -> [Text] -> IO (Maybe Text)
tryHash base files = do
  result <- try @IOException (computeKitHash base files)
  case result of
    Right h -> pure (Just h)
    Left _ -> pure Nothing

scanInstalled :: KitConfig -> FilePath -> IO [(AgentAssetProvider, Text, Text)]
scanInstalled config baseDir = fmap concat $
  forM (config ^. #providers) $ \provider -> do
    skillItems <- scanSkills provider (takeDirectory (baseDir </> skillTargetPath provider InteractiveProjectScope "__scan__"))
    agentItems <- scanAgents provider (takeDirectory (baseDir </> agentTargetPath provider InteractiveProjectScope "__scan__"))
    pure (skillItems ++ agentItems)

scanSkills :: AgentAssetProvider -> FilePath -> IO [(AgentAssetProvider, Text, Text)]
scanSkills provider dir = do
  exists <- doesDirectoryExist dir
  if exists
    then do
      entries <- listDirectory dir
      pure [(provider, Text.pack e, "skill") | e <- entries, visible e]
    else pure []

scanAgents :: AgentAssetProvider -> FilePath -> IO [(AgentAssetProvider, Text, Text)]
scanAgents provider dir = do
  exists <- doesDirectoryExist dir
  if exists
    then do
      entries <- listDirectory dir
      let files = filter (\f -> agentExtension provider `isSuffixOf` f && visible f) entries
      pure [(provider, Text.pack (dropAgentExtension provider f), "agent") | f <- files]
    else pure []

renderStatusTable :: [StatusRow] -> IO ()
renderStatusTable [] = Text.IO.putStrLn "No kit items installed."
renderStatusTable rows = do
  let nameW = colWidth "NAME" (^. #name)
      kindW = colWidth "TYPE" (^. #kind)
      scopeW = colWidth "SCOPE" (^. #scope)
      instW = colWidth "INSTALLED" (renderMVer . view #installedVersion)
      latW = colWidth "LATEST" (renderMVer . view #latestVersion)
      hdr =
        Text.justifyLeft (nameW + 2) ' ' "NAME"
          <> Text.justifyLeft (kindW + 2) ' ' "TYPE"
          <> Text.justifyLeft (scopeW + 2) ' ' "SCOPE"
          <> Text.justifyLeft (instW + 2) ' ' "INSTALLED"
          <> Text.justifyLeft (latW + 2) ' ' "LATEST"
          <> "STATE"
  Text.IO.putStrLn hdr
  mapM_ (printRow nameW kindW scopeW instW latW) rows
  where
    colWidth colTitle f =
      maximum (Text.length colTitle : map (Text.length . f) rows)

    renderMVer = fromMaybe "-"

    printRow nameW kindW scopeW instW latW row =
      Text.IO.putStrLn $
        Text.justifyLeft (nameW + 2) ' ' (row ^. #name)
          <> Text.justifyLeft (kindW + 2) ' ' (row ^. #kind)
          <> Text.justifyLeft (scopeW + 2) ' ' (row ^. #scope)
          <> Text.justifyLeft (instW + 2) ' ' (renderMVer (row ^. #installedVersion))
          <> Text.justifyLeft (latW + 2) ' ' (renderMVer (row ^. #latestVersion))
          <> renderState (row ^. #state)

itemKindOf :: KitItem -> Text
itemKindOf KitSkillItem {} = "skill"
itemKindOf KitAgentItem {} = "agent"

agentSourceBase :: FilePath -> AgentEntry -> FilePath
agentSourceBase repoDir entry =
  case entry ^. #files of
    Just _ -> repoDir </> Text.unpack (entry ^. #path)
    Nothing -> repoDir </> takeDirectory (Text.unpack (entry ^. #path))

agentExtension :: AgentAssetProvider -> String
agentExtension provider =
  case agentTargetPath provider InteractiveProjectScope "__scan__" of
    path
      | ".toml" `isSuffixOf` path -> ".toml"
      | ".md" `isSuffixOf` path -> ".md"
      | otherwise -> ""

dropAgentExtension :: AgentAssetProvider -> FilePath -> FilePath
dropAgentExtension provider file =
  let ext = agentExtension provider
   in take (length file - length ext) file

visible :: FilePath -> Bool
visible = not . ("." `isPrefixOf`)
