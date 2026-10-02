-- | Preserve the user's TOML text; parse both sides of every surgical edit.
module Baikai.Kit.CodexConfig
  ( codexConfigPath,
    readSkillEntries,
    addDisabledSkill,
    removeDisabledSkill,
    checkDisabledSkill,
    checkRemoveDisabledSkill,
    enableSkillsArgs,
  )
where

import Baikai.Kit.Error (KitError (..))
import Baikai.Prelude
import Control.Exception (IOException, onException, try)
import Control.Monad (forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Numeric (showHex)
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
    getPermissions,
    pathIsSymbolicLink,
    readable,
    removeFile,
    renameFile,
    setPermissions,
    writable,
  )
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, openTempFile)
import Toml qualified

codexConfigPath :: IO FilePath
codexConfigPath = do
  home <- getHomeDirectory
  root <- fromMaybe (home </> ".codex") <$> lookupEnv "CODEX_HOME"
  pure (root </> "config.toml")

readSkillEntries :: FilePath -> IO (Either KitError [(FilePath, Bool)])
readSkillEntries config = configTry config "" $ do
  text <- readConfig config
  pure $ do
    table <- parseConfig text
    traverse entry (configValues table)
  where
    entry (Toml.Table t) = do
      p <- case value "path" t of
        Just (Toml.Text p) -> pure (Text.unpack p)
        _ -> Left "skills.config entry has no string path"
      enabled <- case value "enabled" t of
        Nothing -> Right True
        Just (Toml.Bool b) -> Right b
        _ -> Left "skills.config entry has no boolean enabled"
      Right (p, enabled)
    entry _ = Left "skills.config must contain tables"

-- | Validate without writing: True means we would add and own this entry.
checkDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)
checkDisabledSkill config skill = fmap (fmap (has _Just)) (prepareEdit True config skill)

checkRemoveDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)
checkRemoveDisabledSkill config skill = fmap (fmap (has _Just)) (prepareEdit False config skill)

addDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)
addDisabledSkill = editSkill True

removeDisabledSkill :: FilePath -> FilePath -> IO (Either KitError Bool)
removeDisabledSkill = editSkill False

editSkill :: Bool -> FilePath -> FilePath -> IO (Either KitError Bool)
editSkill adding config skill = do
  prepared <- prepareEdit adding config skill
  case prepared of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right False)
    Right (Just text) -> configTry config skill $ do
      atomicWrite config text
      pure (Right True)

prepareEdit :: Bool -> FilePath -> FilePath -> IO (Either KitError (Maybe Text))
prepareEdit adding config skill = configTry config skill $ do
  linked <- either (const False) id <$> try @IOException (pathIsSymbolicLink config)
  if linked
    then pure (Left "config.toml is a symbolic link (possibly generated); refusing to replace it")
    else do
      exists <- doesFileExist config
      permissions <- if exists then Just <$> getPermissions config else pure Nothing
      case permissions of
        Just perms | not (readable perms && writable perms) -> ioError (userError "config.toml is not readable and writable")
        _ -> pure ()
      checkParentWritable (takeDirectory config)
      text <- readConfig config
      case parseConfig text of
        Left err -> pure (Left err)
        Right old -> do
          absolute <- canonicalizePath skill
          matches <- traverse (matchesPath absolute) (configValues old)
          let matchedEntries = [v | (v, True) <- zip (configValues old) matches]
          pure $ do
            selected <- case matchedEntries of
              [] -> Right Nothing
              [v@(Toml.Table t)] -> case value "enabled" t of
                Just (Toml.Bool False) -> Right (Just v)
                _
                  | adding -> Left "the user already enabled this skill; refusing to override that entry"
                  | otherwise -> Right Nothing
              _ -> Left "multiple skills.config entries name this path"
            case (adding, selected) of
              (True, Just _) -> Right Nothing
              (False, Nothing) -> Right Nothing
              _ -> do
                let newText = if adding then appendBlock text absolute else removeBlock text absolute
                    expected =
                      if adding
                        then configValues old ++ [disabledValue absolute]
                        else filter (\v -> Just v /= selected) (configValues old)
                new <- parseConfig newText
                unless (configValues new == expected && withoutConfig old == withoutConfig new) $
                  Left "the edit would change other TOML values; use array-of-table [[skills.config]] entries"
                Right (Just newText)
  where
    matchesPath absolute (Toml.Table t) = case value "path" t of
      Just (Toml.Text p) -> (== absolute) <$> canonicalizePath (Text.unpack p)
      _ -> pure False
    matchesPath _ _ = pure False

checkParentWritable :: FilePath -> IO ()
checkParentWritable path = do
  exists <- doesDirectoryExist path
  if exists
    then do
      permissions <- getPermissions path
      unless (writable permissions) (ioError (userError "Codex config directory is not writable"))
    else do
      let parent = takeDirectory path
      when (parent == path || parent == "/") (ioError (userError "Codex config has no writable parent"))
      checkParentWritable parent

readConfig :: FilePath -> IO Text
readConfig config = do
  exists <- doesFileExist config
  if not exists
    then pure ""
    else do
      bytes <- BS.readFile config
      either (ioError . userError . show) pure (Encoding.decodeUtf8' bytes)

parseConfig :: Text -> Either Text Toml.Table
parseConfig text = do
  t <- either (Left . Text.pack) (Right . Toml.forgetTableAnns) (Toml.parse text)
  case value "skills" t of
    Nothing -> Right t
    Just (Toml.Table skills) -> case value "config" skills of
      Nothing -> Right t
      Just (Toml.List _) -> Right t
      _ -> Left "skills.config is not an array"
    _ -> Left "skills is not a table"

value :: Text -> Toml.Table -> Maybe Toml.Value
value key (Toml.MkTable t) = snd <$> Map.lookup key t

configValues :: Toml.Table -> [Toml.Value]
configValues t = case value "skills" t of
  Just (Toml.Table skills) -> case value "config" skills of
    Just (Toml.List values) -> values
    _ -> []
  _ -> []

withoutConfig :: Toml.Table -> Toml.Table
withoutConfig (Toml.MkTable t) = Toml.MkTable $ Map.update clean "skills" t
  where
    clean (_, Toml.Table (Toml.MkTable skills)) =
      let rest = Map.delete "config" skills
       in if Map.null rest then Nothing else Just ((), Toml.Table (Toml.MkTable rest))
    clean other = Just other

disabledValue :: FilePath -> Toml.Value
disabledValue skill =
  Toml.Table
    ( Toml.MkTable
        ( Map.fromList
            [("path", ((), Toml.Text (Text.pack skill))), ("enabled", ((), Toml.Bool False))]
        )
    )

disabledBlock :: FilePath -> Text
disabledBlock skill = "[[skills.config]]\npath = " <> tomlString (Text.pack skill) <> "\nenabled = false\n"

-- Mark the separator so uninstall restores even a seed with no final newline.
appendBlock :: Text -> FilePath -> Text
appendBlock text skill = text <> "\n# baikai-kit begin\n" <> disabledBlock skill <> "# baikai-kit end\n"

removeBlock :: Text -> FilePath -> Text
removeBlock text skill =
  let marked = go "" (Text.splitOn "\n# baikai-kit begin\n" text)
   in if marked /= text then marked else removeUnmarked text skill
  where
    go prefix [] = prefix
    go prefix [lastPart] = prefix <> lastPart
    go prefix (part : block : remaining) =
      let (body, suffix) = Text.breakOn "# baikai-kit end\n" block
          matches = case parseConfig body of
            Right table -> configValues table == [disabledValue skill]
            Left _ -> False
       in if matches && not (Text.null suffix)
            then
              prefix
                <> part
                <> Text.drop (Text.length "# baikai-kit end\n") suffix
                <> Text.concat ["\n# baikai-kit begin\n" <> r | r <- remaining]
            else go (prefix <> part <> "\n# baikai-kit begin\n") (block : remaining)

-- A user may remove our delimiter comments. Locate the table block; the
-- caller still verifies that removing it changes exactly one parsed entry.
removeUnmarked :: Text -> FilePath -> Text
removeUnmarked text skill = go [] (Text.splitOn "\n" text)
  where
    go before [] = Text.intercalate "\n" before
    go before (line : rest)
      | Text.strip (Text.takeWhile (/= '#') line) == "[[skills.config]]" =
          let (body, after) = break (Text.isPrefixOf "[" . Text.stripStart) rest
              block = Text.intercalate "\n" (line : body)
              matches = case parseConfig block of
                Right table -> case configValues table of
                  [Toml.Table entry] ->
                    value "path" entry == Just (Toml.Text (Text.pack skill))
                      && value "enabled" entry == Just (Toml.Bool False)
                  _ -> False
                Left _ -> False
           in if matches
                then Text.intercalate "\n" (before ++ after)
                else go (before ++ [line]) rest
      | otherwise = go (before ++ [line]) rest

atomicWrite :: FilePath -> Text -> IO ()
atomicWrite path text = do
  let dir = takeDirectory path
  createDirectoryIfMissing True dir
  exists <- doesFileExist path
  permissions <- if exists then Just <$> getPermissions path else pure Nothing
  (temp, handle) <- openTempFile dir (takeFileName path <> ".baikai-kit-tmp")
  ( do
      BS.hPut handle (Encoding.encodeUtf8 text)
      hClose handle
      forM_ permissions (setPermissions temp)
      renameFile temp path
    )
    `onException` (hClose handle >> removeFile temp)

configTry :: FilePath -> FilePath -> IO (Either Text a) -> IO (Either KitError a)
configTry config skill action = do
  result <- try @IOException action
  pure $ case result of
    Left e -> Left (failure (Text.pack (show e)))
    Right (Left reason) -> Left (failure reason)
    Right (Right v) -> Right v
  where
    failure reason =
      KitCodexConfigUnusable
        config
        ( reason
            <> "\nAdd this block by hand:\n"
            <> disabledBlock skill
            <> "Use --shared to install without the entry. --accept-shared-codex applies to agents that cannot be isolated."
        )

enableSkillsArgs :: [FilePath] -> [Text]
enableSkillsArgs [] = []
enableSkillsArgs skills =
  [ "-c",
    "skills.config=["
      <> Text.intercalate
        ","
        ["{path=" <> tomlString (Text.pack p) <> ",enabled=true}" | p <- nub skills]
      <> "]"
  ]

tomlString :: Text -> Text
tomlString input = "\"" <> Text.concatMap escape input <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c
      | ord c < 32 || ord c == 127 =
          let digits = showHex (ord c) ""
           in "\\u" <> Text.pack (replicate (4 - length digits) '0' ++ digits)
    escape c = Text.singleton c
