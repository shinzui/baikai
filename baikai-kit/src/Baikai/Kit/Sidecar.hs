module Baikai.Kit.Sidecar
  ( SidecarMeta (..),
    computeKitHash,
    hashEntries,
    newSidecarMeta,
    sidecarPath,
    readSidecar,
  )
where

import Baikai.AgentAssets (AgentAssetProvider, agentTargetPath, skillTargetPath)
import Baikai.Interactive (InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Error (KitError (..))
import Baikai.Kit.Manifest (KitItem, KitItemKind (..), itemKind, itemName, itemVersion)
import Baikai.Kit.Path (safeSourcePath)
import Baikai.Prelude
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson (eitherDecodeFileStrict')
import Data.Binary.Put (putWord64be, runPut)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (sortOn)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (doesFileExist)
import System.FilePath (dropExtension, (</>))
import System.IO (hPutStrLn, stderr)

-- | The metadata written beside each installed asset.
--
--   @installedFiles@ and @installedHash@ describe what this tool wrote
--   for one provider — the file names relative to that provider's target
--   directory, and the hash of exactly those bytes — so @kit update@ can
--   tell a file the user edited from one it installed. Both are 'Nothing'
--   in sidecars written before those fields existed, and such an item is
--   updated without the check.
data SidecarMeta = SidecarMeta
  { name :: !Text,
    kind :: !Text,
    version :: !(Maybe Text),
    hash :: !Text,
    installedAt :: !Text,
    installedFiles :: !(Maybe [Text]),
    installedHash :: !(Maybe Text)
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Content hash of the listed files, which lie at @base '</>' file@
--   below the kit checkout @root@.
--
--   The hashed bytes are, per file sorted by name: the file name relative
--   to @base@, NUL, the big-endian length, the content, NUL — unchanged
--   from earlier releases, so existing sidecars keep matching. Every file
--   is resolved through 'safeSourcePath' first, so a symbolic link
--   anywhere below @root@ refuses the hash instead of being read through.
computeKitHash :: FilePath -> FilePath -> [FilePath] -> IO (Either KitError Text)
computeKitHash root base relFiles = do
  results <- traverse readOne relFiles
  pure (hashEntries <$> sequence results)
  where
    readOne :: FilePath -> IO (Either KitError (FilePath, BS.ByteString))
    readOne rel = do
      resolved <- safeSourcePath root (base </> rel)
      case resolved of
        Left err -> pure (Left err)
        Right path -> do
          content <- try @IOException (BS.readFile path)
          pure $ case content of
            Left e -> Left (KitSourceUnreadable path (Text.pack (show e)))
            Right bytes -> Right (rel, bytes)

-- | The pure core: hash already-read (relative name, bytes) pairs.
hashEntries :: [(FilePath, BS.ByteString)] -> Text
hashEntries entries = "sha256:" <> Text.pack (show digest)
  where
    digest = Hash.hash (BS.concat (map chunk (sortOn fst entries))) :: Digest SHA256
    chunk (rel, content) =
      BS.concat
        [ Text.Encoding.encodeUtf8 (Text.pack rel),
          BS.singleton 0x00,
          LBS.toStrict (runPut (putWord64be (fromIntegral (BS.length content)))),
          content,
          BS.singleton 0x00
        ]

sidecarPath :: AgentAssetProvider -> KitItemKind -> Text -> FilePath -> Text -> FilePath
sidecarPath provider SkillKind itemName' targetBase sidecarName =
  targetBase
    </> skillTargetPath provider InteractiveProjectScope (Text.unpack itemName')
    </> Text.unpack sidecarName
sidecarPath provider AgentKind itemName' targetBase sidecarName =
  targetBase
    </> dropExtension (agentTargetPath provider InteractiveProjectScope (Text.unpack itemName'))
      <> Text.unpack sidecarName

readSidecar :: FilePath -> IO (Maybe SidecarMeta)
readSidecar p = do
  exists <- doesFileExist p
  if not exists
    then pure Nothing
    else do
      result <- eitherDecodeFileStrict' p
      case result of
        Right meta -> pure (Just meta)
        Left err -> do
          hPutStrLn stderr $ "Warning: failed to parse sidecar " <> p <> ": " <> err
          pure Nothing

-- | Build the sidecar for one provider: the upstream content hash, the
--   names this install writes for that provider, and the hash of the
--   bytes it writes.
newSidecarMeta :: KitItem -> Text -> [Text] -> Text -> IO SidecarMeta
newSidecarMeta item hashStr writtenFiles writtenHash = do
  now <- getCurrentTime
  let stamp = Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  pure
    SidecarMeta
      { name = itemName item,
        kind = itemKind item,
        version = itemVersion item,
        hash = hashStr,
        installedAt = stamp,
        installedFiles = Just writtenFiles,
        installedHash = Just writtenHash
      }
