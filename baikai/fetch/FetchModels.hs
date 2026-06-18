{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Executable @baikai-fetch-models@: refresh baikai's catalog JSON
-- from upstream sources (primarily @https:\/\/models.dev\/api.json@).
--
-- Pipeline role: this tool does @network -> catalog JSON@. The
-- existing @baikai-gen-models@ does @catalog JSON -> Generated.hs@.
-- The two stay separate so the network never runs at build time and
-- the catalog JSON stays a human-reviewable @git diff@ artifact.
--
-- Typical use, from the repo root:
--
-- > cabal run baikai-fetch-models           -- fetch live, rewrite data/models/{anthropic,openai}.json
-- > cabal run baikai-gen-models             -- regenerate Generated.hs
-- > git --no-pager diff baikai/data/models  -- review before committing
--
-- Flags:
--
-- * @--from-url URL@   — upstream document (default
--   @https:\/\/models.dev\/api.json@).
-- * @--from-file PATH@ — read a local document instead of the network
--   (used by tests and for offline work).
-- * @--out-dir DIR@    — directory to write @\<provider\>.json@ into
--   (default @\<baikai-pkg-dir\>\/data\/models@).
-- * @--provider {openai|anthropic|all}@ — which catalogs to emit
--   (default @all@).
-- * @--stdout@         — print to stdout instead of writing files.
--
-- All normalization, curation, and rendering logic lives in the pure
-- 'FetchModelsCore' module so it can be unit-tested without IO; this
-- module is only the impure shell (arg parsing, network fetch, file
-- writing).
module FetchModels (main, fetchUpstream) where

import Control.Exception (catch)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import FetchModelsCore
import Network.HTTP.Client (HttpException, httpLbs, parseUrlThrow, responseBody)
import Network.HTTP.Client.TLS (newTlsManager)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))

-- | Which provider(s) to emit.
data ProviderSel = SelOpenAI | SelAnthropic | SelAll
  deriving stock (Eq, Show)

-- | Parsed command-line options.
data Options = Options
  { optFromUrl :: !String,
    optFromFile :: !(Maybe FilePath),
    optOutDir :: !(Maybe FilePath),
    optProvider :: !ProviderSel,
    optStdout :: !Bool
  }

defaultOptions :: Options
defaultOptions =
  Options
    { optFromUrl = "https://models.dev/api.json",
      optFromFile = Nothing,
      optOutDir = Nothing,
      optProvider = SelAll,
      optStdout = False
    }

main :: IO ()
main = do
  args <- getArgs
  opts <- parseArgs args
  raw <- loadUpstreamBytes opts
  upstream <- case parseUpstream raw of
    Left err -> die $ "baikai-fetch-models: failed to parse upstream JSON: " <> err
    Right u -> pure u
  let catalogs = map (catalogFor upstream) (selectedSpecs (optProvider opts))
  if optStdout opts
    then mapM_ (BS.putStr . renderCatalog) catalogs
    else do
      outDir <- resolveOutDir (optOutDir opts)
      mapM_ (writeCatalog outDir) catalogs

-- | Obtain the raw upstream bytes: a local file when @--from-file@ is
-- set, otherwise a live GET. A network/HTTP failure ('HttpException',
-- which 'parseUrlThrow' raises for non-2xx responses) is turned into a
-- clean non-zero exit with nothing written.
loadUpstreamBytes :: Options -> IO BSL.ByteString
loadUpstreamBytes opts = case optFromFile opts of
  Just path -> BSL.readFile path
  Nothing ->
    fetchUpstream (optFromUrl opts)
      `catch` \e ->
        die $
          "baikai-fetch-models: failed to fetch "
            <> optFromUrl opts
            <> ": "
            <> show (e :: HttpException)

-- | GET a URL over TLS and return the body. 'parseUrlThrow' makes any
-- non-2xx status raise an 'HttpException' (handled by the caller), so
-- a 404 or server error never reaches the parser or the filesystem.
fetchUpstream :: String -> IO BSL.ByteString
fetchUpstream url = do
  manager <- newTlsManager
  req <- parseUrlThrow url
  responseBody <$> httpLbs req manager

-- | Build a provider's catalog from the parsed upstream document,
-- defaulting to an empty model map if the provider is absent.
catalogFor :: Map Text (Map Text UpstreamModel) -> ProviderSpec -> Catalog
catalogFor upstream spec =
  normalizeProvider spec (Map.findWithDefault Map.empty (psProvider spec) upstream)

-- | Write one catalog to @\<dir\>\/\<provider\>.json@ in a single
-- 'BS.writeFile' (so a crash mid-run cannot leave a truncated file)
-- and report what was written.
writeCatalog :: FilePath -> Catalog -> IO ()
writeCatalog dir cat = do
  let path = dir </> (Text.unpack (cProvider cat) <> ".json")
  BS.writeFile path (renderCatalog cat)
  putStrLn $
    "Wrote " <> path <> " (" <> show (length (cModels cat)) <> " models)"

-- | The provider specs selected by @--provider@.
selectedSpecs :: ProviderSel -> [ProviderSpec]
selectedSpecs = \case
  SelOpenAI -> [openaiSpec]
  SelAnthropic -> [anthropicSpec]
  SelAll -> [anthropicSpec, openaiSpec]

-- | Resolve the output directory, anchoring the default against the
-- @baikai@ package directory the same way @baikai-gen-models@ does.
resolveOutDir :: Maybe FilePath -> IO FilePath
resolveOutDir (Just d) = pure d
resolveOutDir Nothing = do
  mPkg <- locatePackageDir
  case mPkg of
    Nothing ->
      die
        "baikai-fetch-models: could not locate baikai.cabal in any \
        \ancestor directory; pass --out-dir explicitly"
    Just pkg -> pure (pkg </> "data/models")

-- | Locate the directory containing @baikai.cabal@ by walking up from
-- the current working directory, also checking a @baikai@ subdir at
-- each level so invocation from the repo root works. Mirrors
-- @baikai-gen-models@.
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

-- | Parse the flags; anything else is a hard error, mirroring
-- @baikai-gen-models@'s strict arg handling.
parseArgs :: [String] -> IO Options
parseArgs = go defaultOptions
  where
    go o [] = pure o
    go o ("--from-url" : v : rest) = go o {optFromUrl = v} rest
    go o ("--from-file" : v : rest) = go o {optFromFile = Just v} rest
    go o ("--out-dir" : v : rest) = go o {optOutDir = Just v} rest
    go o ("--provider" : v : rest) = do
      sel <- parseProvider v
      go o {optProvider = sel} rest
    go o ("--stdout" : rest) = go o {optStdout = True} rest
    go _ (a : _) = die $ "baikai-fetch-models: unknown argument " <> show a

parseProvider :: String -> IO ProviderSel
parseProvider = \case
  "openai" -> pure SelOpenAI
  "anthropic" -> pure SelAnthropic
  "all" -> pure SelAll
  other ->
    die $
      "baikai-fetch-models: unknown --provider "
        <> show other
        <> " (expected openai, anthropic, or all)"
