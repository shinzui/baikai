{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure core for @baikai-gen-models@: parse catalog JSON, flatten enabled
-- entries, reject generated identifier collisions, and render the generated
-- Haskell module. The executable wrapper owns only argument parsing, file IO,
-- and default path resolution.
module GenModelsCore
  ( CatalogFile (..),
    CatalogCompat (..),
    ModelEntry (..),
    CostEntry (..),
    GeneratedEntry (..),
    flattenEntries,
    checkIdentifierCollisions,
    checkAnthropicCompat,
    parseAnthropicThinkingStyle,
    sanitizeIdentifier,
    renderModule,
  )
where

import Baikai.Api (Api (..), parseApi)
import Baikai.Compat
  ( AnthropicMessagesCompat
      ( sendSessionAffinityHeaders,
        supportsCacheControlOnTools,
        supportsLongCacheRetention,
        supportsSamplingParameters,
        thinkingStyle
      ),
    AnthropicThinkingStyle (..),
    CacheControlFormat (..),
    MaxTokensField (..),
    OpenAICompletionsCompat
      ( cacheControlFormat,
        maxTokensField,
        requiresThinkingAsText,
        supportsLongCacheRetention,
        supportsStrictMode,
        supportsUsageInStreaming,
        thinkingFormat
      ),
    ThinkingFormat (..),
    defaultAnthropicMessagesCompat,
    defaultOpenAICompletionsCompat,
  )
import Baikai.Model (InputModality (..))
import Data.Aeson (FromJSON (..), (.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, typeMismatch)
import Data.Map.Strict qualified as Map
import Data.Ratio (denominator, numerator)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)

-- * Catalog data types -----------------------------------------------

-- | One catalog file, in source form.
data CatalogFile = CatalogFile
  { provider :: !Text,
    baseUrl :: !Text,
    api :: !Api,
    compat :: !CatalogCompat,
    models :: ![ModelEntry]
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
  sst <- o .:? "supportsStrictMode" .!= supportsStrictMode d
  rtat <- o .:? "requiresThinkingAsText" .!= requiresThinkingAsText d
  tf <- optionalField o "thinkingFormat" parseThinkingFormat (thinkingFormat d)
  ccf <- optionalMaybeField o "cacheControlFormat" parseCacheControlFormat (cacheControlFormat d)
  sus <- o .:? "supportsUsageInStreaming" .!= d.supportsUsageInStreaming
  slcr <- o .:? "supportsLongCacheRetention" .!= d.supportsLongCacheRetention
  pure
    d
      { maxTokensField = mtf,
        supportsStrictMode = sst,
        requiresThinkingAsText = rtat,
        thinkingFormat = tf,
        cacheControlFormat = ccf,
        supportsUsageInStreaming = sus,
        supportsLongCacheRetention = slcr
      }

parseAnthropicCompat :: Aeson.Object -> Parser AnthropicMessagesCompat
parseAnthropicCompat o = do
  let d = defaultAnthropicMessagesCompat
  slcr <- o .:? "supportsLongCacheRetention" .!= d.supportsLongCacheRetention
  scot <- o .:? "supportsCacheControlOnTools" .!= d.supportsCacheControlOnTools
  ssah <- o .:? "sendSessionAffinityHeaders" .!= d.sendSessionAffinityHeaders
  ts <- optionalField o "thinkingStyle" parseAnthropicThinkingStyle d.thinkingStyle
  ssp <- o .:? "supportsSamplingParameters" .!= d.supportsSamplingParameters
  pure
    d
      { supportsLongCacheRetention = slcr,
        supportsCacheControlOnTools = scot,
        sendSessionAffinityHeaders = ssah,
        thinkingStyle = ts,
        supportsSamplingParameters = ssp
      }

-- | The catalog dialect spells the extended-thinking wire shape as a
-- word, as every other catalog enum does, rather than through the
-- derived instance on 'AnthropicThinkingStyle' (which is part of
-- 'Baikai.Model.Model'\'s pinned JSON round trip and names the Haskell
-- constructor).
parseAnthropicThinkingStyle :: Text -> Parser AnthropicThinkingStyle
parseAnthropicThinkingStyle = \case
  "budget" -> pure AnthropicThinkingBudget
  "adaptive" -> pure AnthropicThinkingAdaptive
  t -> fail $ "unknown thinkingStyle: " <> Text.unpack t

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
optionalMaybeField ::
  Aeson.Object ->
  Aeson.Key ->
  (Text -> Parser a) ->
  Maybe a ->
  Parser (Maybe a)
optionalMaybeField o key parser def = do
  mv <- o .:? key
  case mv of
    Nothing -> pure def
    Just Aeson.Null -> pure Nothing
    Just (Aeson.String t) -> Just <$> parser t
    Just v -> typeMismatch "string or null" v

-- | One model row in a catalog file.
data ModelEntry = ModelEntry
  { entryId :: !Text,
    entryName :: !Text,
    entryReasoning :: !Bool,
    entryInput :: ![InputModality],
    entryCost :: !CostEntry,
    entryContextWindow :: !Natural,
    entryMaxOutputTokens :: !Natural,
    entryEnabled :: !Bool,
    entryCompatOverride :: !(Maybe CatalogCompat)
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
-- (@1.5@ -> @3 % 2@) rather than an arbitrary IEEE-754 approximation.
data CostEntry = CostEntry
  { costInput :: !Scientific,
    costOutput :: !Scientific,
    costCacheRead :: !Scientific,
    costCacheWrite :: !Scientific
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
  { ident :: !Text,
    modelId :: !Text,
    name :: !Text,
    api :: !Api,
    provider :: !Text,
    baseUrl :: !Text,
    reasoning :: !Bool,
    input :: ![InputModality],
    cost :: !CostEntry,
    contextWindow :: !Natural,
    maxOutputTokens :: !Natural,
    compat :: !CatalogCompat
  }

flattenEntries :: CatalogFile -> [(Text, GeneratedEntry)]
flattenEntries c =
  [ (g.ident, g)
  | m <- models c,
    entryEnabled m,
    let g =
          GeneratedEntry
            { ident =
                sanitizeIdentifier (c.provider <> "_" <> entryId m),
              modelId = entryId m,
              name = entryName m,
              api = c.api,
              provider = c.provider,
              baseUrl = c.baseUrl,
              reasoning = entryReasoning m,
              input = entryInput m,
              cost = entryCost m,
              contextWindow = entryContextWindow m,
              maxOutputTokens = entryMaxOutputTokens m,
              compat =
                case entryCompatOverride m of
                  Just c' -> c'
                  Nothing -> c.compat
            }
  ]

-- | Reject catalogs whose sanitized generated Haskell binding names collide.
-- Without this check, two distinct upstream model ids such as @foo-bar@ and
-- @foo_bar@ would silently render duplicate top-level declarations.
checkIdentifierCollisions :: [(Text, GeneratedEntry)] -> Either Text ()
checkIdentifierCollisions entries =
  case Map.toList collisions of
    [] -> Right ()
    dupes ->
      Left $
        "duplicate generated model identifiers: "
          <> Text.intercalate "; " (map renderCollision dupes)
  where
    grouped =
      Map.fromListWith
        (++)
        [(i, [entry]) | (i, entry) <- entries]
    collisions = Map.filter ((> 1) . length) grouped
    renderCollision (i, es) =
      i
        <> " from "
        <> Text.intercalate ", " (map origin (reverse es))
    origin e = e.provider <> "/" <> e.modelId

-- | Every @anthropic-messages@ entry must state its thinking style and
-- sampling support explicitly. An entry left at the file-level
-- @"compat": "auto"@ directive would fall through to host
-- auto-detection, which knows the host but cannot know the model
-- generation — the drift that sent @claude-sonnet-5@ a @budget_tokens@
-- request the generation rejects. The generator refuses rather than
-- guessing, so a hand edit to @baikai/data/models/anthropic.json@ that
-- drops a block fails the build instead of shipping.
checkAnthropicCompat :: [(Text, GeneratedEntry)] -> Either Text ()
checkAnthropicCompat entries =
  case [e | (_, e) <- entries, e.api == AnthropicMessages, not (stated e.compat)] of
    [] -> Right ()
    missing -> Left (Text.intercalate "; " (map complain missing))
  where
    stated = \case
      CatalogCompatAnthropic _ -> True
      _ -> False
    complain e =
      "anthropic-messages entry "
        <> e.provider
        <> "/"
        <> e.modelId
        <> " has no compat block; add {\"kind\":\"anthropic-messages\""
        <> ",\"thinkingStyle\":\"budget\"|\"adaptive\""
        <> ",\"supportsSamplingParameters\":true|false}"

-- | Replace any non-identifier character with @_@. Haskell allows
-- letters, digits, underscore, and apostrophe; everything else
-- (slash, dash, dot, colon, ...) becomes an underscore.
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
  Text.unlines $
    dropTrailingEmpty
      ( header
          ++ concatMap (renderEntry . snd) entries
          ++ renderAllModels (map (ident . snd) entries)
      )
  where
    dropTrailingEmpty = \case
      [] -> []
      xs
        | last xs == "" -> init xs
        | otherwise -> xs

    header =
      [ "-- AUTO-GENERATED by baikai-gen-models. Do not edit by hand.",
        "-- Regenerate with: cabal run baikai-gen-models",
        "{-# LANGUAGE OverloadedStrings #-}",
        "{-# OPTIONS_GHC -Wno-missing-export-lists #-}",
        "{-# OPTIONS_GHC -Wno-unused-imports #-}",
        "",
        "module Baikai.Models.Generated where",
        "",
        "import Baikai.Api (Api (..))",
        "import Baikai.Compat",
        "  ( AnthropicMessagesCompat",
        "      ( sendSessionAffinityHeaders,",
        "        supportsCacheControlOnTools,",
        "        supportsLongCacheRetention,",
        "        supportsSamplingParameters,",
        "        thinkingStyle",
        "      ),",
        "    AnthropicThinkingStyle (..),",
        "    CacheControlFormat (..),",
        "    MaxTokensField (..),",
        "    OpenAICompletionsCompat",
        "      ( cacheControlFormat,",
        "        maxTokensField,",
        "        requiresThinkingAsText,",
        "        supportsLongCacheRetention,",
        "        supportsStrictMode,",
        "        supportsUsageInStreaming,",
        "        thinkingFormat",
        "      ),",
        "    ThinkingFormat (..),",
        "    defaultAnthropicMessagesCompat,",
        "    defaultOpenAICompletionsCompat,",
        "  )",
        "import Baikai.Model",
        "  ( Compat (..),",
        "    InputModality (..),",
        "    Model,",
        "    ModelCost (..),",
        "    api,",
        "    baseUrl,",
        "    compat,",
        "    contextWindow,",
        "    cost,",
        "    emptyModel,",
        "    headers,",
        "    input,",
        "    maxOutputTokens,",
        "    modelId,",
        "    name,",
        "    provider,",
        "    reasoning,",
        "  )",
        "import Data.Map.Strict qualified as Map",
        "import Data.Ratio ((%))",
        ""
      ]

-- | Render the @allModels@ binding: every generated model in one list, in the
-- same (identifier-sorted) order as the declarations above. Consumers can fold
-- or filter this instead of hand-listing bindings, so a catalog change flows
-- through automatically.
renderAllModels :: [Text] -> [Text]
renderAllModels idents =
  "-- | Every model in the generated catalog, in declaration order."
    : "allModels :: [Model]"
    : "allModels ="
    : case idents of
      [] -> ["  []"]
      _ ->
        [ "  " <> prefix <> ident <> suffix
        | (position, ident) <- zip [0 :: Int ..] idents,
          let prefix = if position == 0 then "[ " else "  ",
          let suffix = if position == length idents - 1 then "" else ","
        ]
          ++ ["  ]"]

renderEntry :: GeneratedEntry -> [Text]
renderEntry g =
  [ g.ident <> " :: Model",
    g.ident <> " =",
    "  emptyModel",
    "    { modelId = " <> renderText g.modelId <> ",",
    "      name = " <> renderText g.name <> ",",
    "      api = " <> renderApiCtor g.api <> ",",
    "      provider = " <> renderText g.provider <> ",",
    "      baseUrl = " <> renderText g.baseUrl <> ",",
    "      reasoning = " <> renderBool g.reasoning <> ",",
    "      input = " <> renderInputList g.input <> ",",
    "      cost =",
    renderCost g.cost <> ",",
    "      contextWindow = " <> Text.pack (show g.contextWindow) <> ",",
    "      maxOutputTokens = " <> Text.pack (show g.maxOutputTokens) <> ",",
    "      headers = Map.empty,"
  ]
    ++ renderCompat g.compat
    ++ [ "    }",
         ""
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
    [ "        ModelCost",
      "          { inputCost = " <> renderRational (toRational (costInput c)) <> ",",
      "            outputCost = " <> renderRational (toRational (costOutput c)) <> ",",
      "            cacheReadCost = " <> renderRational (toRational (costCacheRead c)) <> ",",
      "            cacheWriteCost = " <> renderRational (toRational (costCacheWrite c)),
      "          }"
    ]

renderRational :: Rational -> Text
renderRational r =
  Text.pack (show (numerator r)) <> " % " <> Text.pack (show (denominator r))

-- | The @compat@ field of one rendered entry, as source lines.
--
-- The layout is the one @ormolu@ produces, because the repository
-- formatter runs over the generated module and @CatalogSpec@ demands
-- the generator's output be byte-identical to the committed file: a
-- layout the formatter would rewrite makes those two checks
-- contradict each other.
renderCompat :: CatalogCompat -> [Text]
renderCompat = \case
  CatalogCompatAuto -> ["      compat = CompatNone"]
  CatalogCompatOpenAI c ->
    [ "      compat =",
      "        CompatOpenAICompletions",
      "          defaultOpenAICompletionsCompat",
      "            { maxTokensField = " <> renderMaxTokensField c.maxTokensField <> ",",
      "              supportsStrictMode = " <> renderBool c.supportsStrictMode <> ",",
      "              requiresThinkingAsText = " <> renderBool c.requiresThinkingAsText <> ",",
      "              thinkingFormat = " <> renderThinkingFormat c.thinkingFormat <> ",",
      "              cacheControlFormat = " <> renderMaybeCacheControl c.cacheControlFormat <> ",",
      "              supportsUsageInStreaming = " <> renderBool c.supportsUsageInStreaming <> ",",
      "              supportsLongCacheRetention = " <> renderBool c.supportsLongCacheRetention,
      "            }"
    ]
  CatalogCompatAnthropic c ->
    [ "      compat =",
      "        CompatAnthropicMessages",
      "          defaultAnthropicMessagesCompat",
      "            { supportsLongCacheRetention = " <> renderBool c.supportsLongCacheRetention <> ",",
      "              supportsCacheControlOnTools = " <> renderBool c.supportsCacheControlOnTools <> ",",
      "              sendSessionAffinityHeaders = " <> renderBool c.sendSessionAffinityHeaders <> ",",
      "              thinkingStyle = " <> renderAnthropicThinkingStyle c.thinkingStyle <> ",",
      "              supportsSamplingParameters = " <> renderBool c.supportsSamplingParameters,
      "            }"
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

renderAnthropicThinkingStyle :: AnthropicThinkingStyle -> Text
renderAnthropicThinkingStyle = \case
  AnthropicThinkingBudget -> "AnthropicThinkingBudget"
  AnthropicThinkingAdaptive -> "AnthropicThinkingAdaptive"

renderMaybeCacheControl :: Maybe CacheControlFormat -> Text
renderMaybeCacheControl = \case
  Nothing -> "Nothing"
  Just CacheControlFormatAnthropic -> "Just CacheControlFormatAnthropic"
