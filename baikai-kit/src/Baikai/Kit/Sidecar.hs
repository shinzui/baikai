module Baikai.Kit.Sidecar
  ( SidecarMeta (..),
    computeKitHash,
    sidecarPath,
    readSidecar,
    writeSidecar,
  )
where

import Baikai.AgentAssets (AgentAssetProvider, agentTargetPath, skillTargetPath)
import Baikai.Interactive (InteractiveScope (InteractiveProjectScope))
import Baikai.Kit.Manifest (KitItem (..), itemKind, itemName, itemVersion)
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
import System.FilePath (takeDirectory, (</>))
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
      content <- BS.readFile (dir </> Text.unpack rel)
      let pathBytes = Text.Encoding.encodeUtf8 rel
          lenBytes = LBS.toStrict (runPut (putWord64be (fromIntegral (BS.length content))))
      pure $ BS.concat [pathBytes, BS.singleton 0x00, lenBytes, content, BS.singleton 0x00]

sidecarPath :: AgentAssetProvider -> KitItem -> FilePath -> Text -> FilePath
sidecarPath provider (KitSkillItem entry) targetBase sidecarName =
  targetBase
    </> skillTargetPath provider InteractiveProjectScope (Text.unpack (entry ^. #name))
    </> Text.unpack sidecarName
sidecarPath provider (KitAgentItem entry) targetBase sidecarName =
  targetBase
    </> dropExtensionForSidecar (agentTargetPath provider InteractiveProjectScope (Text.unpack (entry ^. #name)))
      <> Text.unpack sidecarName
  where
    dropExtensionForSidecar path =
      case reverse path of
        'd' : 'm' : '.' : rest -> reverse rest
        'l' : 'm' : 'o' : 't' : '.' : rest -> reverse rest
        _ -> path

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
  now <- getCurrentTime
  let stamp = Text.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      meta =
        SidecarMeta
          { name = itemName item,
            kind = itemKind item,
            version = itemVersion item,
            hash = hashStr,
            installedAt = stamp
          }
      out = sidecarPath provider item targetBase sidecarName
  createDirectoryIfMissing True (takeDirectory out)
  LBS.writeFile out (encode meta)
