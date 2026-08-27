module Baikai.Kit.Path
  ( safeItemName,
    safeRelativePath,
    safeSourcePath,
  )
where

import Baikai.Kit.Error (KitError (..))
import Baikai.Prelude
import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import System.Directory (canonicalizePath, doesFileExist, doesPathExist, pathIsSymbolicLink)
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

-- | Resolve an untrusted relative source path below a trusted kit
--   checkout.
--
--   Runs 'safeRelativePath' on the relative path, then walks every prefix
--   of it below @root@: a prefix that does not exist is
--   'KitSourceMissing', a prefix that is a symbolic link
--   ('pathIsSymbolicLink') is 'KitSourceSymlink'. Finally the canonical
--   form of the full path must lie component-wise below the canonical
--   form of @root@ ('canonicalizePath' on both, compared with
--   'splitDirectories'), else 'KitSourceEscapes', and the full path must
--   be a regular file ('doesFileExist'), else 'KitSourceMissing'. Any
--   'IOException' raised while inspecting a prefix is
--   'KitSourceUnreadable'. Returns @root '</>' rel@.
--
--   Check-then-read: the caller reads the returned path afterwards; a
--   writer to the checkout could swap a file for a link in between, which
--   is accepted because the checkout is owned by the invoking user and
--   written only by git before this runs.
safeSourcePath :: FilePath -> FilePath -> IO (Either KitError FilePath)
safeSourcePath root rel =
  case safeRelativePath (Text.pack rel) of
    Left reason -> pure (Left (KitUnsafePath (Text.pack rel) reason))
    Right validated -> do
      let full = root </> validated
          components = filter (/= ".") (splitDirectories validated)
      outcome <- try @IOException (inspect root full components)
      pure (either (Left . KitSourceUnreadable full . Text.pack . show) id outcome)
  where
    inspect base full components = do
      walked <- walkPrefixes base components
      case walked of
        Just err -> pure (Left err)
        Nothing -> do
          canonRoot <- canonicalizePath base
          canonFull <- canonicalizePath full
          if not (splitDirectories canonRoot `isPrefixOf` splitDirectories canonFull)
            then pure (Left (KitSourceEscapes canonFull canonRoot))
            else do
              isFile <- doesFileExist full
              pure (if isFile then Right full else Left (KitSourceMissing full))

    walkPrefixes _ [] = pure Nothing
    walkPrefixes base (component : rest) = do
      let here = base </> component
      -- 'doesPathExist' is False for a dangling link, which refuses the
      -- path without following it; 'pathIsSymbolicLink' throws when the
      -- path is absent, so the existence check comes first.
      exists <- doesPathExist here
      if not exists
        then pure (Just (KitSourceMissing here))
        else do
          isLink <- pathIsSymbolicLink here
          if isLink
            then pure (Just (KitSourceSymlink here))
            else walkPrefixes here rest
