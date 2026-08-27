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
import Baikai.Kit.Config (KitConfig, KitScope (..), providerAgentsBase, providerLabel, sidecarFileName)
import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Install (loadManifestMaybe, lookupItem)
import Baikai.Kit.Manifest (KitItem, KitItemKind (..), itemKind, itemSources, itemVersion, kindLabel)
import Baikai.Kit.Repo (ensureKitRepo)
import Baikai.Kit.Sidecar (SidecarMeta, computeKitHash, readSidecar, sidecarPath)
import Baikai.Prelude
import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (groupBy, isPrefixOf, isSuffixOf, nub, sort, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, (</>))

data KitState
  = KitUpToDate
  | KitOutdated
  | KitDirty
  | KitDirtyOutdated
  | KitDelisted
  | KitUpstreamRefused
  | KitUnknown
  deriving stock (Eq, Ord, Show)

data StatusRow = StatusRow
  { name :: !Text,
    kind :: !Text,
    scope :: !Text,
    providers :: !Text,
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
  KitDirtyOutdated -> "dirty+outdated"
  KitDelisted -> "delisted"
  KitUpstreamRefused -> "refused"
  KitUnknown -> "unknown"

classify :: Maybe SidecarMeta -> Maybe KitItem -> Maybe Text -> KitState
classify Nothing _ _ = KitUnknown
classify (Just _) Nothing _ = KitDelisted
classify (Just sm) (Just it) mUpstreamHash =
  let outdated = case itemVersion it of
        Just latest -> sm ^. #version /= Just latest
        Nothing -> False
      dirty = case mUpstreamHash of
        Just up -> up /= sm ^. #hash
        Nothing -> False
   in case (outdated, dirty) of
        (True, True) -> KitDirtyOutdated
        (True, False) -> KitOutdated
        (False, True) -> KitDirty
        (False, False) -> KitUpToDate

kitStatus :: KitConfig -> IO ()
kitStatus config = do
  cacheDir <- resolveCacheOrEmpty config
  rows <- collectStatus config cacheDir [(UserScope, "user"), (ProjectScope, "project")]
  renderStatusTable rows

collectStatus :: KitConfig -> FilePath -> [(KitScope, Text)] -> IO [StatusRow]
collectStatus config cacheDir scopes = do
  mManifest <- loadManifestMaybe cacheDir
  fmap concat . forM scopes $ \(scope, scopeText) -> do
    items <- scanInstalled config scope
    forM items $ \(provider, baseDir, itemName', scannedKind) -> do
      let mItem = lookupItem itemName' =<< mManifest
      mSidecar <- readSidecar (sidecarPath provider scannedKind itemName' baseDir (sidecarFileName config))
      upstream <- upstreamHash cacheDir mItem
      let state' = case upstream of
            Left _ -> KitUpstreamRefused
            Right mUpstreamHash -> classify mSidecar mItem mUpstreamHash
      pure
        StatusRow
          { name = itemName',
            kind = maybe (kindLabel scannedKind) itemKind mItem,
            scope = scopeText,
            providers = providerLabel provider,
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

-- | The hash of an item's sources as they are in the cached checkout.
--
--   @Right Nothing@ means there is nothing to compare against: no cache,
--   no manifest entry, or an upstream source that is simply gone. A
--   'Left' means the upstream listing is one this installer refuses to
--   read — a symbolic link, an escaping path, an unsafe manifest string —
--   which 'collectStatus' shows as 'KitUpstreamRefused'.
upstreamHash :: FilePath -> Maybe KitItem -> IO (Either KitError (Maybe Text))
upstreamHash "" _ = pure (Right Nothing)
upstreamHash _ Nothing = pure (Right Nothing)
upstreamHash cacheDir (Just item) =
  case itemSources item of
    Left err -> pure (Left err)
    Right sources -> do
      result <- computeKitHash cacheDir (sources ^. #base) (sources ^. #files)
      pure $ case result of
        Left (KitSourceMissing _) -> Right Nothing
        Left err -> Left err
        Right h -> Right (Just h)

scanInstalled :: KitConfig -> KitScope -> IO [(AgentAssetProvider, FilePath, Text, KitItemKind)]
scanInstalled config scope = fmap concat $
  forM (config ^. #providers) $ \provider -> do
    baseDir <- providerAgentsBase config provider scope
    skillItems <- scanSkills provider (takeDirectory (baseDir </> skillTargetPath provider InteractiveProjectScope "__scan__"))
    agentItems <- scanAgents provider (takeDirectory (baseDir </> agentTargetPath provider InteractiveProjectScope "__scan__"))
    pure [(provider', baseDir, itemName', kind) | (provider', itemName', kind) <- skillItems ++ agentItems]

scanSkills :: AgentAssetProvider -> FilePath -> IO [(AgentAssetProvider, Text, KitItemKind)]
scanSkills provider dir = do
  exists <- doesDirectoryExist dir
  if exists
    then do
      entries <- listDirectory dir
      pure [(provider, Text.pack e, SkillKind) | e <- entries, visible e]
    else pure []

scanAgents :: AgentAssetProvider -> FilePath -> IO [(AgentAssetProvider, Text, KitItemKind)]
scanAgents provider dir = do
  exists <- doesDirectoryExist dir
  if exists
    then do
      entries <- listDirectory dir
      let files = filter (\f -> agentExtension provider `isSuffixOf` f && visible f) entries
      pure [(provider, Text.pack (dropAgentExtension provider f), AgentKind) | f <- files]
    else pure []

renderStatusTable :: [StatusRow] -> IO ()
renderStatusTable [] = Text.IO.putStrLn "No kit items installed."
renderStatusTable rows = do
  let displayRows = aggregateStatusRows rows
      nameW = colWidth displayRows "NAME" (^. #name)
      kindW = colWidth displayRows "TYPE" (^. #kind)
      scopeW = colWidth displayRows "SCOPE" (^. #scope)
      providersW = colWidth displayRows "PROVIDERS" (^. #providers)
      instW = colWidth displayRows "INSTALLED" (renderMVer . view #installedVersion)
      latW = colWidth displayRows "LATEST" (renderMVer . view #latestVersion)
      hdr =
        Text.justifyLeft (nameW + 2) ' ' "NAME"
          <> Text.justifyLeft (kindW + 2) ' ' "TYPE"
          <> Text.justifyLeft (scopeW + 2) ' ' "SCOPE"
          <> Text.justifyLeft (providersW + 2) ' ' "PROVIDERS"
          <> Text.justifyLeft (instW + 2) ' ' "INSTALLED"
          <> Text.justifyLeft (latW + 2) ' ' "LATEST"
          <> "STATE"
  Text.IO.putStrLn hdr
  mapM_ (printRow nameW kindW scopeW providersW instW latW) displayRows
  where
    colWidth displayRows colTitle f =
      maximum (Text.length colTitle : map (Text.length . f) displayRows)

    renderMVer = fromMaybe "-"

    printRow nameW kindW scopeW providersW instW latW row =
      Text.IO.putStrLn $
        Text.justifyLeft (nameW + 2) ' ' (row ^. #name)
          <> Text.justifyLeft (kindW + 2) ' ' (row ^. #kind)
          <> Text.justifyLeft (scopeW + 2) ' ' (row ^. #scope)
          <> Text.justifyLeft (providersW + 2) ' ' (row ^. #providers)
          <> Text.justifyLeft (instW + 2) ' ' (renderMVer (row ^. #installedVersion))
          <> Text.justifyLeft (latW + 2) ' ' (renderMVer (row ^. #latestVersion))
          <> renderState (row ^. #state)

aggregateStatusRows :: [StatusRow] -> [StatusRow]
aggregateStatusRows rows =
  map summarize grouped
  where
    grouped = groupBy sameKey $ sortOn rowKey rows
    rowKey row =
      ( row ^. #name,
        row ^. #kind,
        row ^. #scope,
        row ^. #installedVersion,
        row ^. #latestVersion,
        row ^. #state
      )
    sameKey a b = rowKey a == rowKey b
    summarize groupRows@(firstRow : _) =
      firstRow & #providers .~ Text.intercalate "," (sort (nub (map (^. #providers) groupRows)))
    summarize [] = error "aggregateStatusRows: empty group"

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
