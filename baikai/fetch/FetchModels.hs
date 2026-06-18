{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Executable @baikai-fetch-models@: refresh baikai's catalog JSON
-- from upstream sources (primarily @https:\/\/models.dev\/api.json@).
--
-- Milestone 1 surface (offline only): read a models.dev-shaped JSON
-- document from @--from-file PATH@, normalize the requested provider(s)
-- into baikai catalog JSON, and print to stdout. The live network
-- fetch and in-place file writing are added in later milestones.
--
-- All normalization, curation, and rendering logic lives in the pure
-- 'FetchModelsCore' module so it can be unit-tested without IO.
module FetchModels (main) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import FetchModelsCore
import System.Environment (getArgs)
import System.Exit (die)

-- | Which provider(s) to emit.
data ProviderSel = SelOpenAI | SelAnthropic | SelAll
  deriving stock (Eq, Show)

-- | Parsed command-line options.
data Options = Options
  { optFromFile :: !(Maybe FilePath),
    optProvider :: !ProviderSel
  }

defaultOptions :: Options
defaultOptions =
  Options
    { optFromFile = Nothing,
      optProvider = SelAll
    }

main :: IO ()
main = do
  args <- getArgs
  opts <- parseArgs args
  raw <- case optFromFile opts of
    Just path -> BSL.readFile path
    Nothing ->
      die
        "baikai-fetch-models: --from-file PATH is required \
        \(live network fetch is added in a later milestone)"
  upstream <- case parseUpstream raw of
    Left err -> die $ "baikai-fetch-models: failed to parse upstream JSON: " <> err
    Right u -> pure u
  let specs = selectedSpecs (optProvider opts)
  mapM_ (BS.putStr . renderCatalog . catalogFor upstream) specs

-- | Build a provider's catalog from the parsed upstream document,
-- defaulting to an empty model map if the provider is absent.
catalogFor :: Map Text (Map Text UpstreamModel) -> ProviderSpec -> Catalog
catalogFor upstream spec =
  normalizeProvider spec (Map.findWithDefault Map.empty (psProvider spec) upstream)

-- | The provider specs selected by @--provider@.
selectedSpecs :: ProviderSel -> [ProviderSpec]
selectedSpecs = \case
  SelOpenAI -> [openaiSpec]
  SelAnthropic -> [anthropicSpec]
  SelAll -> [anthropicSpec, openaiSpec]

-- | Parse @--from-file@ and @--provider@; anything else is a hard
-- error, mirroring @baikai-gen-models@'s strict arg handling.
parseArgs :: [String] -> IO Options
parseArgs = go defaultOptions
  where
    go o [] = pure o
    go o ("--from-file" : v : rest) = go o {optFromFile = Just v} rest
    go o ("--provider" : v : rest) = do
      sel <- parseProvider v
      go o {optProvider = sel} rest
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
