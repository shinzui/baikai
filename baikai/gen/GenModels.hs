{-# LANGUAGE OverloadedStrings #-}

-- | Generator executable that reads JSON catalog files from
-- @baikai\/data\/models\/@ and emits a single
-- @baikai\/src\/Baikai\/Models\/Generated.hs@ module containing one
-- fully populated 'Baikai.Model.Model' value per (provider, model id)
-- pair.
--
-- Run as @cabal run baikai-gen-models@ from anywhere inside the repo
-- tree. The default input and output paths are resolved relative to
-- the directory containing @baikai.cabal@, located by walking up from
-- the current working directory (and one step into a @baikai@ subdir
-- if needed), so the natural invocation from the repo root works
-- without any flags. Options:
--
-- * @--models-dir PATH@ — directory containing catalog @.json@ files.
--   Default: @\<baikai-pkg-dir\>\/data\/models@.
-- * @--out PATH@ — output Haskell source path.
--   Default: @\<baikai-pkg-dir\>\/src\/Baikai\/Models\/Generated.hs@.
--
-- Explicit paths are interpreted relative to the caller's CWD (or
-- absolute), not the package directory.
--
-- The generator is intentionally deterministic: entries are sorted by
-- their generated Haskell identifier, the output formatting is fixed,
-- and re-running with unchanged inputs produces byte-identical output
-- (enforced by @CatalogSpec@ in @baikai\/test\/@).
module Main (main) where

import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.List (sort, sortOn)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import GenModelsCore
  ( checkAnthropicCompat,
    checkIdentifierCollisions,
    flattenEntries,
    renderModule,
  )
import System.Directory (doesFileExist, getCurrentDirectory, listDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory, takeExtension, (</>))

main :: IO ()
main = do
  args <- getArgs
  (mModelsDir, mOutputPath) <- parseArgs args
  (modelsDir, outputPath) <- resolveDefaults mModelsDir mOutputPath
  jsonFiles <- listCatalogFiles modelsDir
  catalogs <- forM jsonFiles $ \f -> do
    raw <- BSL.readFile (modelsDir </> f)
    case Aeson.eitherDecode raw of
      Left err -> die $ f <> ": " <> err
      Right c -> pure c
  let allEntries = concatMap flattenEntries catalogs
  case checkIdentifierCollisions allEntries of
    Left err -> die (Text.unpack err)
    Right () -> pure ()
  case checkAnthropicCompat allEntries of
    Left err -> die (Text.unpack err)
    Right () -> pure ()
  let sorted = sortOn fst allEntries
      rendered = renderModule sorted
  TIO.writeFile outputPath rendered
  putStrLn $
    "Wrote "
      <> outputPath
      <> " ("
      <> show (length sorted)
      <> " enabled models)"

-- | Parse command-line arguments. Recognises @--models-dir@ and
-- @--out@; everything else is a hard error. 'Nothing' for either
-- field means \"use the package-dir-anchored default\".
parseArgs :: [String] -> IO (Maybe FilePath, Maybe FilePath)
parseArgs = go Nothing Nothing
  where
    go d o [] = pure (d, o)
    go _ o ("--models-dir" : v : rest) = go (Just v) o rest
    go d _ ("--out" : v : rest) = go d (Just v) rest
    go _ _ (a : _) = die $ "baikai-gen-models: unknown argument " <> show a

-- | Resolve any unset path defaults against the @baikai@ package
-- directory so the generator works from anywhere inside the repo.
-- Explicit overrides are returned unchanged (CWD-relative or
-- absolute). If both paths are explicit no lookup happens.
resolveDefaults :: Maybe FilePath -> Maybe FilePath -> IO (FilePath, FilePath)
resolveDefaults (Just m) (Just o) = pure (m, o)
resolveDefaults mModelsDir mOutputPath = do
  mPkg <- locatePackageDir
  case mPkg of
    Nothing ->
      die
        "baikai-gen-models: could not locate baikai.cabal in any \
        \ancestor directory; pass --models-dir and --out explicitly"
    Just pkg ->
      pure
        ( maybe (pkg </> "data/models") id mModelsDir,
          maybe (pkg </> "src/Baikai/Models/Generated.hs") id mOutputPath
        )

-- | Locate the directory containing @baikai.cabal@ by walking up from
-- the current working directory. Also checks for a @baikai@ subdir at
-- each level so the executable works when invoked from the repo root
-- (where @baikai.cabal@ lives at @baikai\/baikai.cabal@).
locatePackageDir :: IO (Maybe FilePath)
locatePackageDir = getCurrentDirectory >>= walk
  where
    walk dir = do
      here <- doesFileExist (dir </> "baikai.cabal")
      if here
        then pure (Just dir)
        else do
          sub <- doesFileExist (dir </> "baikai" </> "baikai.cabal")
          if sub
            then pure (Just (dir </> "baikai"))
            else
              let parent = takeDirectory dir
               in if parent == dir then pure Nothing else walk parent

-- | List the @.json@ files in @dir@, sorted alphabetically so the
-- output is deterministic across filesystems.
listCatalogFiles :: FilePath -> IO [FilePath]
listCatalogFiles dir = do
  entries <- listDirectory dir
  pure $ sort [f | f <- entries, takeExtension f == ".json"]
