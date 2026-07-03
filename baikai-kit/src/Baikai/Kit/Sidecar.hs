module Baikai.Kit.Sidecar
  ( SidecarMeta (..),
    computeKitHash,
    newSidecarMeta,
    sidecarPath,
    readSidecar,
    writeSidecar,
  )
where

import Baikai.AgentAssets (AgentAssetProvider, agentTargetPath, skillTargetPath)
import Baikai.Interactive (InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Manifest (KitItem, KitItemKind (..), itemKind, itemName, itemVersion, kitItemKind)
import Baikai.Kit.Path (safeRelativePath)
import Baikai.Prelude
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson (eitherDecodeFileStrict', encode)
import Data.Binary.Put (putWord64be, runPut)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (dropExtension, takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)

data SidecarMeta = SidecarMeta
  { name :: !Text,
    kind :: !Text,
    version :: !(Maybe Text),
    hash :: !Text,
    installedAt :: !Text
  }
  deriving stock (Eq, Generic, Show)
  deriving anyclass (FromJSON, ToJSON)

computeKitHash :: FilePath -> [Text] -> IO Text
computeKitHash baseDir relFiles = do
  chunks <- mapM (readOne baseDir) (sort relFiles)
  let digest = Hash.hash (BS.concat chunks) :: Digest SHA256
      hex = Text.pack (show digest)
  pure ("sha256:" <> hex)
  where
    readOne :: FilePath -> Text -> IO BS.ByteString
    readOne dir rel = do
      safeRel <- either (ioError . userError . Text.unpack) pure (safeRelativePath rel)
      content <- BS.readFile (dir </> safeRel)
      let pathBytes = Text.Encoding.encodeUtf8 (Text.pack safeRel)
          lenBytes = LBS.toStrict (runPut (putWord64be (fromIntegral (BS.length content))))
      pure $ BS.concat [pathBytes, BS.singleton 0x00, lenBytes, content, BS.singleton 0x00]

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

writeSidecar :: AgentAssetProvider -> KitItem -> FilePath -> Text -> Text -> IO ()
writeSidecar provider item targetBase sidecarName hashStr = do
  meta <- newSidecarMeta item hashStr
  let out = sidecarPath provider (kitItemKind item) (itemName item) targetBase sidecarName
  createDirectoryIfMissing True (takeDirectory out)
  LBS.writeFile out (encode meta)

newSidecarMeta :: KitItem -> Text -> IO SidecarMeta
newSidecarMeta item hashStr = do
  now <- getCurrentTime
  let stamp = Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
  pure
    SidecarMeta
      { name = itemName item,
        kind = itemKind item,
        version = itemVersion item,
        hash = hashStr,
        installedAt = stamp
      }
