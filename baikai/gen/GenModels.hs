{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Generator executable that reads JSON catalog files from
-- @baikai\/data\/models\/@ and emits a single
-- @baikai\/src\/Baikai\/Models\/Generated.hs@ module containing one
-- fully populated 'Baikai.Model.Model' value per (provider, model id)
-- pair.
--
-- Run as @cabal run baikai-gen-models@. Options:
--
-- * @--models-dir PATH@ — directory containing catalog @.json@ files.
--   Default: @data\/models@ (relative to the @baikai\/@ package).
-- * @--out PATH@ — output Haskell source path.
--   Default: @src\/Baikai\/Models\/Generated.hs@ (relative to the
--   @baikai\/@ package).
--
-- The generator is intentionally deterministic: entries are sorted by
-- their generated Haskell identifier, the output formatting is fixed,
-- and re-running with unchanged inputs produces byte-identical output
-- (enforced by @CatalogSpec@ in @baikai\/test\/@).
module Main (main) where

import Baikai.Api (Api (..), parseApi)
import Baikai.Compat
  ( AnthropicMessagesCompat (..)
  , CacheControlFormat (..)
  , MaxTokensField (..)
  , OpenAICompletionsCompat (..)
  , ThinkingFormat (..)
  , defaultAnthropicMessagesCompat
  , defaultOpenAICompletionsCompat
  )
import Baikai.Model (InputModality (..))
import Control.Monad (forM)
import Data.Aeson (FromJSON (..), (.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, typeMismatch)
import Data.ByteString.Lazy qualified as BSL
import Data.List (sort, sortOn)
import Data.Ratio (denominator, numerator)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TIO
import Numeric.Natural (Natural)
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeExtension, (</>))

main :: IO ()
main = do
  args <- getArgs
  (modelsDir, outputPath) <- parseArgs args
  jsonFiles <- listCatalogFiles modelsDir
  catalogs <- forM jsonFiles $ \f -> do
    raw <- BSL.readFile (modelsDir </> f)
    case Aeson.eitherDecode raw of
      Left err -> die $ f <> ": " <> err
      Right c -> pure c
  let allEntries = concatMap flattenEntries catalogs
      sorted = sortOn fst allEntries
      rendered = renderModule sorted
  TIO.writeFile outputPath rendered
  putStrLn $
    "Wrote "
      <> outputPath
      <> " ("
      <> show (length sorted)
      <> " enabled models)"

-- | Parse command-line arguments. Recognises @--models-dir@ and
-- @--out@; everything else is a hard error.
parseArgs :: [String] -> IO (FilePath, FilePath)
parseArgs = go defaultModelsDir defaultOutPath
  where
    defaultModelsDir = "data/models"
    defaultOutPath = "src/Baikai/Models/Generated.hs"
    go d o [] = pure (d, o)
    go _ o ("--models-dir" : v : rest) = go v o rest
    go d _ ("--out" : v : rest) = go d v rest
    go _ _ (a : _) = die $ "baikai-gen-models: unknown argument " <> show a

-- | List the @.json@ files in @dir@, sorted alphabetically so the
-- output is deterministic across filesystems.
listCatalogFiles :: FilePath -> IO [FilePath]
listCatalogFiles dir = do
  entries <- listDirectory dir
  pure $ sort [f | f <- entries, takeExtension f == ".json"]

-- * Catalog data types -----------------------------------------------

-- | One catalog file, in source form.
data CatalogFile = CatalogFile
  { provider :: !Text
  , baseUrl :: !Text
  , api :: !Api
  , compat :: !CatalogCompat
  , models :: ![ModelEntry]
  }

instance FromJSON CatalogFile where
  parseJSON = Aeson.withObject "CatalogFile" $ \o ->
    CatalogFile
      <$> o .: "provider"
      <*> o .: "baseUrl"
      <*> (parseApi <$> o .: "api")
      <*> o .: "compat"
      <*> o .: "models"

-- | A compat directive in the catalog. @"auto"@ defers to EP-5's
-- @baseUrl@-driven auto-detection (rendered as 'CompatNone'). The two
-- structured constructors carry a full override record.
data CatalogCompat
  = CatalogCompatAuto
  | CatalogCompatOpenAI !OpenAICompletionsCompat
  | CatalogCompatAnthropic !AnthropicMessagesCompat
  deriving stock (Show)

instance FromJSON CatalogCompat where
  parseJSON = \case
    Aeson.String "auto" -> pure CatalogCompatAuto
    Aeson.Object o -> do
      kind <- o .: "kind" :: Parser Text
      case kind of
        "openai-completions" ->
          CatalogCompatOpenAI <$> parseOpenAICompat o
        "anthropic-messages" ->
          CatalogCompatAnthropic <$> parseAnthropicCompat o
        _ ->
          fail $ "CatalogCompat: unknown kind " <> show kind
    v -> typeMismatch "CatalogCompat (expected \"auto\" or {\"kind\": ...})" v

parseOpenAICompat :: Aeson.Object -> Parser OpenAICompletionsCompat
parseOpenAICompat o = do
  let d = defaultOpenAICompletionsCompat
  mtf <- optionalField o "maxTokensField" parseMaxTokensField (maxTokensField d)
  sdr <- o .:? "supportsDeveloperRole" .!= supportsDeveloperRole d
  sst <- o .:? "supportsStrictMode" .!= supportsStrictMode d
  rtat <- o .:? "requiresThinkingAsText" .!= requiresThinkingAsText d
  tf <- optionalField o "thinkingFormat" parseThinkingFormat (thinkingFormat d)
  ccf <- optionalMaybeField o "cacheControlFormat" parseCacheControlFormat (cacheControlFormat d)
  sus <- o .:? "supportsUsageInStreaming" .!= d.supportsUsageInStreaming
  slcr <- o .:? "supportsLongCacheRetention" .!= d.supportsLongCacheRetention
  pure
    OpenAICompletionsCompat
      { maxTokensField = mtf
      , supportsDeveloperRole = sdr
      , supportsStrictMode = sst
      , requiresThinkingAsText = rtat
      , thinkingFormat = tf
      , cacheControlFormat = ccf
      , supportsUsageInStreaming = sus
      , supportsLongCacheRetention = slcr
      }

parseAnthropicCompat :: Aeson.Object -> Parser AnthropicMessagesCompat
parseAnthropicCompat o = do
  let d = defaultAnthropicMessagesCompat
  slcr <- o .:? "supportsLongCacheRetention" .!= d.supportsLongCacheRetention
  scot <- o .:? "supportsCacheControlOnTools" .!= d.supportsCacheControlOnTools
  seti <- o .:? "supportsEagerToolInputStreaming" .!= d.supportsEagerToolInputStreaming
  ssah <- o .:? "sendSessionAffinityHeaders" .!= d.sendSessionAffinityHeaders
  pure
    AnthropicMessagesCompat
      { supportsLongCacheRetention = slcr
      , supportsCacheControlOnTools = scot
      , supportsEagerToolInputStreaming = seti
      , sendSessionAffinityHeaders = ssah
      }

parseMaxTokensField :: Text -> Parser MaxTokensField
parseMaxTokensField = \case
  "max_tokens" -> pure MaxTokensField
  "max_completion_tokens" -> pure MaxCompletionTokensField
  t -> fail $ "unknown maxTokensField: " <> Text.unpack t

parseThinkingFormat :: Text -> Parser ThinkingFormat
parseThinkingFormat = \case
  "openai" -> pure ThinkingFormatOpenAI
  "openrouter" -> pure ThinkingFormatOpenRouter
  "deepseek" -> pure ThinkingFormatDeepseek
  "together" -> pure ThinkingFormatTogether
  "zai" -> pure ThinkingFormatZai
  "qwen" -> pure ThinkingFormatQwen
  "none" -> pure ThinkingFormatNone
  t -> fail $ "unknown thinkingFormat: " <> Text.unpack t

parseCacheControlFormat :: Text -> Parser CacheControlFormat
parseCacheControlFormat = \case
  "anthropic" -> pure CacheControlFormatAnthropic
  t -> fail $ "unknown cacheControlFormat: " <> Text.unpack t

-- | Look up an optional field; missing returns @def@.
optionalField :: Aeson.Object -> Aeson.Key -> (Text -> Parser a) -> a -> Parser a
optionalField o key parser def = do
  mv <- o .:? key
  case mv of
    Nothing -> pure def
    Just v -> parser v

-- | Look up an optional @Maybe@-typed field. JSON @null@ or absence
-- yields @def@; otherwise the value is parsed through @parser@ and
-- wrapped in 'Just'.
optionalMaybeField
  :: Aeson.Object
  -> Aeson.Key
  -> (Text -> Parser a)
  -> Maybe a
  -> Parser (Maybe a)
optionalMaybeField o key parser def = do
  mv <- o .:? key
  case mv of
    Nothing -> pure def
    Just Aeson.Null -> pure Nothing
    Just (Aeson.String t) -> Just <$> parser t
    Just v -> typeMismatch "string or null" v

-- | One model row in a catalog file.
data ModelEntry = ModelEntry
  { entryId :: !Text
  , entryName :: !Text
  , entryReasoning :: !Bool
  , entryInput :: ![InputModality]
  , entryCost :: !CostEntry
  , entryContextWindow :: !Natural
  , entryMaxOutputTokens :: !Natural
  , entryEnabled :: !Bool
  , entryCompatOverride :: !(Maybe CatalogCompat)
  }

instance FromJSON ModelEntry where
  parseJSON = Aeson.withObject "ModelEntry" $ \o ->
    ModelEntry
      <$> o .: "id"
      <*> o .: "name"
      <*> o .:? "reasoning" .!= False
      <*> (o .: "input" >>= traverse parseInputModality)
      <*> o .: "cost"
      <*> o .: "contextWindow"
      <*> o .: "maxOutputTokens"
      <*> o .:? "enabled" .!= True
      <*> o .:? "compat"

parseInputModality :: Text -> Parser InputModality
parseInputModality = \case
  "text" -> pure InputText
  "image" -> pure InputImage
  t -> fail $ "unknown input modality: " <> Text.unpack t

-- | Per-million-token cost rates. Parsed as 'Scientific' so the
-- round-trip into 'Rational' produces a small, canonical fraction
-- (@1.5@ → @3 % 2@) rather than an arbitrary IEEE-754 approximation.
data CostEntry = CostEntry
  { costInput :: !Scientific
  , costOutput :: !Scientific
  , costCacheRead :: !Scientific
  , costCacheWrite :: !Scientific
  }

instance FromJSON CostEntry where
  parseJSON = Aeson.withObject "CostEntry" $ \o ->
    CostEntry
      <$> o .: "input"
      <*> o .: "output"
      <*> o .:? "cacheRead" .!= 0
      <*> o .:? "cacheWrite" .!= 0

-- * Flattening ---------------------------------------------------------

-- | One generated Haskell identifier plus the 'Model'-shaped record
-- it should be rendered as. Keeping these together lets the renderer
-- stay a pure transformation over a flat list.
data GeneratedEntry = GeneratedEntry
  { genIdent :: !Text
  , genModelId :: !Text
  , genName :: !Text
  , genApi :: !Api
  , genProvider :: !Text
  , genBaseUrl :: !Text
  , genReasoning :: !Bool
  , genInput :: ![InputModality]
  , genCost :: !CostEntry
  , genContextWindow :: !Natural
  , genMaxOutputTokens :: !Natural
  , genCompat :: !CatalogCompat
  }

flattenEntries :: CatalogFile -> [(Text, GeneratedEntry)]
flattenEntries c =
  [ (genIdent g, g)
  | m <- models c
  , entryEnabled m
  , let g =
          GeneratedEntry
            { genIdent =
                sanitizeIdentifier (provider c <> "_" <> entryId m)
            , genModelId = entryId m
            , genName = entryName m
            , genApi = api c
            , genProvider = provider c
            , genBaseUrl = baseUrl c
            , genReasoning = entryReasoning m
            , genInput = entryInput m
            , genCost = entryCost m
            , genContextWindow = entryContextWindow m
            , genMaxOutputTokens = entryMaxOutputTokens m
            , genCompat =
                case entryCompatOverride m of
                  Just c' -> c'
                  Nothing -> compat c
            }
  ]

-- | Replace any non-identifier character with @_@. Haskell allows
-- letters, digits, underscore, and apostrophe; everything else
-- (slash, dash, dot, colon, …) becomes an underscore.
sanitizeIdentifier :: Text -> Text
sanitizeIdentifier = Text.map replace
  where
    replace c
      | (c >= 'a' && c <= 'z')
          || (c >= 'A' && c <= 'Z')
          || (c >= '0' && c <= '9')
          || c == '_'
          || c == '\'' =
          c
      | otherwise = '_'

-- * Source rendering --------------------------------------------------

renderModule :: [(Text, GeneratedEntry)] -> Text
renderModule entries =
  Text.unlines
    ( header
        ++ concatMap (renderEntry . snd) entries
    )
  where
    header =
      [ "-- AUTO-GENERATED by baikai-gen-models. Do not edit by hand."
      , "-- Regenerate with: cabal run baikai-gen-models"
      , "{-# LANGUAGE OverloadedStrings #-}"
      , "{-# OPTIONS_GHC -Wno-missing-export-lists #-}"
      , "{-# OPTIONS_GHC -Wno-unused-imports #-}"
      , ""
      , "module Baikai.Models.Generated where"
      , ""
      , "import Baikai.Api (Api (..))"
      , "import Baikai.Compat"
      , "  ( AnthropicMessagesCompat (..)"
      , "  , CacheControlFormat (..)"
      , "  , MaxTokensField (..)"
      , "  , OpenAICompletionsCompat (..)"
      , "  , ThinkingFormat (..)"
      , "  )"
      , "import Baikai.Model"
      , "  ( Compat (..)"
      , "  , InputModality (..)"
      , "  , Model (..)"
      , "  , ModelCost (..)"
      , "  )"
      , "import Data.Map.Strict qualified as Map"
      , "import Data.Ratio ((%))"
      , ""
      ]

renderEntry :: GeneratedEntry -> [Text]
renderEntry g =
  [ genIdent g <> " :: Model"
  , genIdent g <> " ="
  , "  Model"
  , "    { modelId = " <> renderText (genModelId g)
  , "    , name = " <> renderText (genName g)
  , "    , api = " <> renderApiCtor (genApi g)
  , "    , provider = " <> renderText (genProvider g)
  , "    , baseUrl = " <> renderText (genBaseUrl g)
  , "    , reasoning = " <> renderBool (genReasoning g)
  , "    , input = " <> renderInputList (genInput g)
  , "    , cost = " <> renderCost (genCost g)
  , "    , contextWindow = " <> Text.pack (show (genContextWindow g))
  , "    , maxOutputTokens = " <> Text.pack (show (genMaxOutputTokens g))
  , "    , headers = Map.empty"
  , "    , compat = " <> renderCompat (genCompat g)
  , "    }"
  , ""
  ]

renderText :: Text -> Text
renderText t =
  "\""
    <> Text.replace "\"" "\\\"" (Text.replace "\\" "\\\\" t)
    <> "\""

renderBool :: Bool -> Text
renderBool True = "True"
renderBool False = "False"

renderInputList :: [InputModality] -> Text
renderInputList ms =
  "[" <> Text.intercalate ", " (map renderInput ms) <> "]"
  where
    renderInput InputText = "InputText"
    renderInput InputImage = "InputImage"

renderApiCtor :: Api -> Text
renderApiCtor = \case
  OpenAIChatCompletions -> "OpenAIChatCompletions"
  AnthropicMessages -> "AnthropicMessages"
  OpenAICompletionsCli -> "OpenAICompletionsCli"
  AnthropicMessagesCli -> "AnthropicMessagesCli"
  Custom t -> "Custom " <> renderText t

renderCost :: CostEntry -> Text
renderCost c =
  Text.intercalate
    "\n"
    [ "ModelCost"
    , "        { inputCost = " <> renderRational (toRational (costInput c))
    , "        , outputCost = " <> renderRational (toRational (costOutput c))
    , "        , cacheReadCost = " <> renderRational (toRational (costCacheRead c))
    , "        , cacheWriteCost = " <> renderRational (toRational (costCacheWrite c))
    , "        }"
    ]

renderRational :: Rational -> Text
renderRational r =
  Text.pack (show (numerator r)) <> " % " <> Text.pack (show (denominator r))

renderCompat :: CatalogCompat -> Text
renderCompat = \case
  CatalogCompatAuto -> "CompatNone"
  CatalogCompatOpenAI c ->
    Text.intercalate
      "\n"
      [ "CompatOpenAICompletions"
      , "        OpenAICompletionsCompat"
      , "          { maxTokensField = " <> renderMaxTokensField c.maxTokensField
      , "          , supportsDeveloperRole = " <> renderBool c.supportsDeveloperRole
      , "          , supportsStrictMode = " <> renderBool c.supportsStrictMode
      , "          , requiresThinkingAsText = " <> renderBool c.requiresThinkingAsText
      , "          , thinkingFormat = " <> renderThinkingFormat c.thinkingFormat
      , "          , cacheControlFormat = " <> renderMaybeCacheControl c.cacheControlFormat
      , "          , supportsUsageInStreaming = " <> renderBool c.supportsUsageInStreaming
      , "          , supportsLongCacheRetention = " <> renderBool c.supportsLongCacheRetention
      , "          }"
      ]
  CatalogCompatAnthropic c ->
    Text.intercalate
      "\n"
      [ "CompatAnthropicMessages"
      , "        AnthropicMessagesCompat"
      , "          { supportsLongCacheRetention = " <> renderBool c.supportsLongCacheRetention
      , "          , supportsCacheControlOnTools = " <> renderBool c.supportsCacheControlOnTools
      , "          , supportsEagerToolInputStreaming = " <> renderBool c.supportsEagerToolInputStreaming
      , "          , sendSessionAffinityHeaders = " <> renderBool c.sendSessionAffinityHeaders
      , "          }"
      ]

renderMaxTokensField :: MaxTokensField -> Text
renderMaxTokensField = \case
  MaxCompletionTokensField -> "MaxCompletionTokensField"
  MaxTokensField -> "MaxTokensField"

renderThinkingFormat :: ThinkingFormat -> Text
renderThinkingFormat = \case
  ThinkingFormatOpenAI -> "ThinkingFormatOpenAI"
  ThinkingFormatOpenRouter -> "ThinkingFormatOpenRouter"
  ThinkingFormatDeepseek -> "ThinkingFormatDeepseek"
  ThinkingFormatTogether -> "ThinkingFormatTogether"
  ThinkingFormatZai -> "ThinkingFormatZai"
  ThinkingFormatQwen -> "ThinkingFormatQwen"
  ThinkingFormatNone -> "ThinkingFormatNone"

renderMaybeCacheControl :: Maybe CacheControlFormat -> Text
renderMaybeCacheControl = \case
  Nothing -> "Nothing"
  Just CacheControlFormatAnthropic -> "Just CacheControlFormatAnthropic"
