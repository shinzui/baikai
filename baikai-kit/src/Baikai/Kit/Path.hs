module Baikai.Kit.Path
  ( safeItemName,
    safeRelativePath,
    safeUnder,
  )
where

import Baikai.Prelude
import Data.Text qualified as Text
import System.FilePath (isAbsolute, normalise, splitDirectories, (</>))

safeRelativePath :: Text -> Either Text FilePath
safeRelativePath input
  | Text.null input = Left "path is empty"
  | Text.any (== '\0') input = Left "path contains a NUL byte"
  | Text.any (== '\\') input = Left "path contains a backslash"
  | isAbsolute raw = Left "path is absolute"
  | ".." `elem` components = Left "path contains a parent-directory component"
  | otherwise = Right normalised
  where
    raw = Text.unpack input
    normalised = normalise raw
    components = splitDirectories normalised

safeItemName :: Text -> Either Text FilePath
safeItemName input
  | Text.any (== '/') input = Left "name must be a single path segment"
  | otherwise = do
      name <- safeRelativePath input
      validateName name
  where
    validateName name
      | name == "." = Left "name cannot be '.'"
      | name == ".." = Left "name cannot be '..'"
      | "." `Text.isPrefixOf` Text.pack name = Left "name cannot start with '.'"
      | length (splitDirectories name) /= 1 = Left "name must be a single path segment"
      | otherwise = Right name

safeUnder :: FilePath -> Text -> Either Text FilePath
safeUnder base rel = (base </>) <$> safeRelativePath rel
