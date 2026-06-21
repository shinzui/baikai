-- | Pure core of the @baikai-fetch-models@ tool: parse a
-- models.dev-shaped payload, normalize it into baikai's catalog JSON
-- shape, and render that JSON with formatting matched to the
-- hand-maintained files under @baikai\/data\/models\/@.
--
-- This module is deliberately free of @IO@ and of any network
-- dependency so it can be unit-tested directly (see
-- @baikai\/test\/FetchModelsSpec.hs@) and so the network fetch lives
-- only in the thin executable wrapper @baikai\/fetch\/FetchModels.hs@.
--
-- == Curation policy
--
-- baikai's catalog is an intentionally curated short list, not an
-- exhaustive mirror of models.dev. Only models whose ids appear in the
-- per-provider include set ('openaiInclude', 'anthropicInclude') are
-- emitted, and only if upstream marks them @tool_call: true@. For
-- @openai@ this excludes Responses-API-only ids (@*-pro@, @*-codex@,
-- @*-deep-research@) because @baikai/data/models/openai.json@ speaks
-- @openai-chat-completions@ and 'Baikai.Api' has no Responses tag.
--
-- == Override philosophy
--
-- models.dev is not fully trustworthy, so a small, explicit override
-- layer ('overrides') is applied after normalization. Each entry is a
-- per-@(provider, modelId)@ correction that overwrites only the fields
-- it sets, and each MUST carry a dated comment justifying why upstream
-- is wrong (mirroring pi-mono's @generate-models.ts@). Keep the table
-- minimal: prefer fixing upstream or curating ids out over piling on
-- overrides. Overrides that match no fetched model are warned about
-- ('staleOverrides') rather than silently kept.
--
-- Records follow the project convention: no field prefixes; field
-- access and updates go through generic-lens @#label@ optics rather
-- than bare selectors or record-update syntax.
module FetchModelsCore
  ( -- * Upstream shape (subset of models.dev fields we consume)
    UpstreamModel (..),
    parseUpstream,

    -- * Output catalog shape
    CatalogModel (..),
    CatalogCost (..),
    Catalog (..),

    -- * Provider specs and normalization
    ProviderSpec (..),
    openaiSpec,
    anthropicSpec,
    openaiInclude,
    anthropicInclude,
    normalizeProvider,

    -- * Override layer
    Override (..),
    emptyOverride,
    overrides,
    applyOverrides,
    staleOverrides,

    -- * Rendering
    renderCatalog,
  )
where

import Baikai.Model (InputModality (..))
import Baikai.Prelude
import Data.Aeson (eitherDecode, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, formatScientific)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)

-- * Upstream shape ----------------------------------------------------

-- | The subset of a models.dev model object that we consume. Every
-- optional field defaults the way pi-mono's scraper does: missing
-- numbers become 0 at normalization time, missing arrays become empty.
data UpstreamModel = UpstreamModel
  { modelId :: !Text,
    name :: !(Maybe Text),
    toolCall :: !Bool,
    reasoning :: !Bool,
    contextWindow :: !(Maybe Integer),
    maxOutputTokens :: !(Maybe Integer),
    inputCost :: !(Maybe Scientific),
    outputCost :: !(Maybe Scientific),
    cacheReadCost :: !(Maybe Scientific),
    cacheWriteCost :: !(Maybe Scientific),
    inputModalities :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON UpstreamModel where
  parseJSON = withObject "UpstreamModel" $ \o -> do
    mid <- o .: "id"
    nm <- o .:? "name"
    tc <- o .:? "tool_call" .!= False
    rs <- o .:? "reasoning" .!= False
    lim <- o .:? "limit" :: Parser (Maybe Limit)
    cst <- o .:? "cost" :: Parser (Maybe Cost)
    mods <- o .:? "modalities" :: Parser (Maybe Modalities)
    pure
      UpstreamModel
        { modelId = mid,
          name = nm,
          toolCall = tc,
          reasoning = rs,
          contextWindow = lim >>= (^. #context),
          maxOutputTokens = lim >>= (^. #output),
          inputCost = cst >>= (^. #input),
          outputCost = cst >>= (^. #output),
          cacheReadCost = cst >>= (^. #cacheRead),
          cacheWriteCost = cst >>= (^. #cacheWrite),
          inputModalities = maybe [] (^. #input) mods
        }

-- | @limit@ sub-object.
data Limit = Limit
  { context :: !(Maybe Integer),
    output :: !(Maybe Integer)
  }
  deriving stock (Show, Generic)

instance FromJSON Limit where
  parseJSON = withObject "limit" $ \o ->
    Limit <$> o .:? "context" <*> o .:? "output"

-- | @cost@ sub-object (US dollars per million tokens).
data Cost = Cost
  { input :: !(Maybe Scientific),
    output :: !(Maybe Scientific),
    cacheRead :: !(Maybe Scientific),
    cacheWrite :: !(Maybe Scientific)
  }
  deriving stock (Show, Generic)

instance FromJSON Cost where
  parseJSON = withObject "cost" $ \o ->
    Cost
      <$> o .:? "input"
      <*> o .:? "output"
      <*> o .:? "cache_read"
      <*> o .:? "cache_write"

-- | @modalities@ sub-object; we only read @input@.
newtype Modalities = Modalities {input :: [Text]}
  deriving stock (Show, Generic)

instance FromJSON Modalities where
  parseJSON = withObject "modalities" $ \o ->
    Modalities <$> o .:? "input" .!= []

-- | One provider object in the models.dev document. We only read the
-- @models@ map; every other provider field is ignored.
newtype UpstreamProvider = UpstreamProvider {models :: Map Text UpstreamModel}
  deriving stock (Generic)

instance FromJSON UpstreamProvider where
  parseJSON = withObject "UpstreamProvider" $ \o ->
    UpstreamProvider <$> o .:? "models" .!= Map.empty

-- | Parse a full models.dev document into @provider -> (modelId ->
-- model)@. The top-level document is a JSON object keyed by provider
-- id; each provider object carries a @models@ map keyed by model id.
parseUpstream :: BSL.ByteString -> Either String (Map Text (Map Text UpstreamModel))
parseUpstream bs =
  Map.map (^. #models) <$> (eitherDecode bs :: Either String (Map Text UpstreamProvider))

-- * Output catalog shape ---------------------------------------------

-- | Per-million-token cost rates, named to mirror
-- 'Baikai.Model.ModelCost'.
data CatalogCost = CatalogCost
  { inputCost :: !Scientific,
    outputCost :: !Scientific,
    cacheReadCost :: !Scientific,
    cacheWriteCost :: !Scientific
  }
  deriving stock (Eq, Show, Generic)

-- | One emitted catalog model. @enabled@ is always @true@ for emitted
-- models, so it is not stored here; the renderer writes it literally.
data CatalogModel = CatalogModel
  { modelId :: !Text,
    name :: !Text,
    reasoning :: !Bool,
    input :: ![InputModality],
    cost :: !CatalogCost,
    contextWindow :: !Integer,
    maxOutputTokens :: !Integer
  }
  deriving stock (Eq, Show, Generic)

-- | A whole catalog file: one provider and its curated models.
data Catalog = Catalog
  { provider :: !Text,
    baseUrl :: !Text,
    api :: !Text,
    models :: ![CatalogModel]
  }
  deriving stock (Eq, Show, Generic)

-- * Provider specs and normalization ---------------------------------

-- | What a provider needs to be normalized: its identity in the
-- catalog and the curation predicate selecting which upstream model
-- ids to keep.
data ProviderSpec = ProviderSpec
  { provider :: !Text,
    baseUrl :: !Text,
    api :: !Text,
    include :: !(Text -> Bool)
  }
  deriving stock (Generic)

-- | Curation include set for OpenAI: the chat-completions-compatible
-- current line. Responses-API-only ids (@*-pro@, @*-codex@,
-- @*-deep-research@) are deliberately absent.
openaiInclude :: Set Text
openaiInclude =
  Set.fromList
    [ "gpt-5.5",
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.4-nano",
      "gpt-5.2",
      "gpt-5.1",
      "gpt-5",
      "gpt-5-mini",
      "gpt-5-nano",
      "gpt-4.1",
      "gpt-4.1-mini",
      "gpt-4.1-nano",
      "gpt-4o",
      "gpt-4o-mini",
      "o3",
      "o3-mini",
      "o4-mini",
      "o1"
    ]

-- | Curation include set for Anthropic: the current generations.
anthropicInclude :: Set Text
anthropicInclude =
  Set.fromList
    [ "claude-opus-4-8",
      "claude-opus-4-7",
      "claude-opus-4-6",
      "claude-opus-4-5",
      "claude-sonnet-4-6",
      "claude-sonnet-4-5",
      "claude-haiku-4-5",
      "claude-fable-5"
    ]

-- | Provider spec for OpenAI's first-party chat-completions endpoint.
openaiSpec :: ProviderSpec
openaiSpec =
  ProviderSpec
    { provider = "openai",
      baseUrl = "https://api.openai.com",
      api = "openai-chat-completions",
      include = (`Set.member` openaiInclude)
    }

-- | Provider spec for Anthropic's first-party messages endpoint.
anthropicSpec :: ProviderSpec
anthropicSpec =
  ProviderSpec
    { provider = "anthropic",
      baseUrl = "https://api.anthropic.com",
      api = "anthropic-messages",
      include = (`Set.member` anthropicInclude)
    }

-- | Normalize one provider's upstream models into a 'Catalog'. Keeps
-- only @tool_call == True@ models that pass the curation predicate,
-- maps each upstream model to a 'CatalogModel' (dropping @pdf@ and any
-- non-text/image modality; missing costs and limits default to 0 so a
-- human notices), and sorts by model id for deterministic output.
normalizeProvider :: ProviderSpec -> Map Text UpstreamModel -> Catalog
normalizeProvider spec upstream =
  Catalog
    { provider = spec ^. #provider,
      baseUrl = spec ^. #baseUrl,
      api = spec ^. #api,
      models = sortOn (^. #modelId) (map toCatalogModel kept)
    }
  where
    kept =
      [ m
      | m <- Map.elems upstream,
        m ^. #toolCall,
        (spec ^. #include) (m ^. #modelId)
      ]
    toCatalogModel m =
      CatalogModel
        { modelId = m ^. #modelId,
          name = normalizeName (fromMaybe (m ^. #modelId) (m ^. #name)),
          reasoning = m ^. #reasoning,
          input =
            if "image" `elem` (m ^. #inputModalities)
              then [InputText, InputImage]
              else [InputText],
          cost =
            CatalogCost
              { inputCost = fromMaybe 0 (m ^. #inputCost),
                outputCost = fromMaybe 0 (m ^. #outputCost),
                cacheReadCost = fromMaybe 0 (m ^. #cacheReadCost),
                cacheWriteCost = fromMaybe 0 (m ^. #cacheWriteCost)
              },
          contextWindow = fromMaybe 0 (m ^. #contextWindow),
          maxOutputTokens = fromMaybe 0 (m ^. #maxOutputTokens)
        }

-- | Strip a trailing @" (latest)"@ display-name suffix that models.dev
-- attaches to the "latest" aliases (e.g. @"Claude Opus 4.5 (latest)"@).
-- This is a systematic upstream wart, so it is normalized for every
-- provider rather than via a per-model override.
normalizeName :: Text -> Text
normalizeName n = fromMaybe n (Text.stripSuffix " (latest)" n)

-- * Override layer ----------------------------------------------------

-- | A hand-maintained correction for one @(provider, modelId)@ pair.
-- Every field except the key is a @Maybe@: 'Nothing' leaves the
-- normalized value untouched, 'Just' overwrites it. Build entries from
-- 'emptyOverride' and set only the fields that need correcting.
data Override = Override
  { provider :: !Text,
    modelId :: !Text,
    name :: !(Maybe Text),
    reasoning :: !(Maybe Bool),
    inputCost :: !(Maybe Scientific),
    outputCost :: !(Maybe Scientific),
    cacheReadCost :: !(Maybe Scientific),
    cacheWriteCost :: !(Maybe Scientific),
    contextWindow :: !(Maybe Integer),
    maxOutputTokens :: !(Maybe Integer)
  }
  deriving stock (Eq, Show, Generic)

-- | An override that changes nothing, keyed by provider and model id.
emptyOverride :: Text -> Text -> Override
emptyOverride prov mid =
  Override
    { provider = prov,
      modelId = mid,
      name = Nothing,
      reasoning = Nothing,
      inputCost = Nothing,
      outputCost = Nothing,
      cacheReadCost = Nothing,
      cacheWriteCost = Nothing,
      contextWindow = Nothing,
      maxOutputTokens = Nothing
    }

-- | The hand-maintained correction table, applied after normalization.
-- Each entry MUST carry a dated comment explaining why upstream is
-- wrong, exactly as pi-mono's @generate-models.ts@ documents its
-- corrections. Order does not matter; entries are keyed by
-- @(provider, modelId)@.
overrides :: [Override]
overrides =
  [ -- 2026-06-21: models.dev has periodically reported Claude Opus
    -- cache_read at 3x the published rate (1.5 instead of 0.5 /Mtok) —
    -- the same wart pi-mono hard-corrects in generate-models.ts
    -- ("models.dev has 3x the correct pricing"). Pin cache_read to
    -- Anthropic's published 0.5 so an upstream regression cannot
    -- silently inflate cached-input cost.
    emptyOverride "anthropic" "claude-opus-4-5" & #cacheReadCost ?~ 0.5
  ]

-- | Apply all overrides matching this catalog's provider to its
-- models. A model with no matching override is returned unchanged.
applyOverrides :: [Override] -> Catalog -> Catalog
applyOverrides ovs cat = cat & #models %~ map applyMatching
  where
    prov = cat ^. #provider
    byKey =
      Map.fromList
        [((o ^. #provider, o ^. #modelId), o) | o <- ovs]
    applyMatching m =
      maybe m (`applyOne` m) (Map.lookup (prov, m ^. #modelId) byKey)

-- | Overwrite each 'CatalogModel' field for which the override carries
-- a 'Just'. 'Nothing' fields are left as normalized.
applyOne :: Override -> CatalogModel -> CatalogModel
applyOne o m =
  m
    & #name
    %~ overwrite (o ^. #name)
    & #reasoning
    %~ overwrite (o ^. #reasoning)
    & #cost
    . #inputCost
    %~ overwrite (o ^. #inputCost)
    & #cost
    . #outputCost
    %~ overwrite (o ^. #outputCost)
    & #cost
    . #cacheReadCost
    %~ overwrite (o ^. #cacheReadCost)
    & #cost
    . #cacheWriteCost
    %~ overwrite (o ^. #cacheWriteCost)
    & #contextWindow
    %~ overwrite (o ^. #contextWindow)
    & #maxOutputTokens
    %~ overwrite (o ^. #maxOutputTokens)
  where
    overwrite :: Maybe a -> a -> a
    overwrite = maybe id const

-- | Override keys @(provider, modelId)@ that match no model in any of
-- the given catalogs (restricted to providers actually present, so an
-- override for an unfetched provider is not falsely flagged). The tool
-- warns on these so stale overrides get noticed without failing.
staleOverrides :: [Override] -> [Catalog] -> [(Text, Text)]
staleOverrides ovs cats =
  [ (o ^. #provider, o ^. #modelId)
  | o <- ovs,
    (o ^. #provider) `Set.member` provs,
    (o ^. #provider, o ^. #modelId) `Set.notMember` present
  ]
  where
    provs = Set.fromList (map (^. #provider) cats)
    present =
      Set.fromList
        [ (cat ^. #provider, m ^. #modelId)
        | cat <- cats,
          m <- cat ^. #models
        ]

-- * Rendering ---------------------------------------------------------

-- | Render a 'Catalog' as catalog JSON, byte-for-byte in the style of
-- the hand-maintained files: 2-space indent, an inline @input@ array,
-- costs as decimal numbers with a trailing @.0@ on whole values, and a
-- trailing newline.
renderCatalog :: Catalog -> ByteString
renderCatalog cat = encodeUtf8 (Text.unlines (renderLines cat))

renderLines :: Catalog -> [Text]
renderLines cat =
  ["{"]
    ++ [ "  \"provider\": " <> jsonString (cat ^. #provider) <> ",",
         "  \"baseUrl\": " <> jsonString (cat ^. #baseUrl) <> ",",
         "  \"api\": " <> jsonString (cat ^. #api) <> ",",
         "  \"compat\": \"auto\","
       ]
    ++ modelsSection (cat ^. #models)
    ++ ["}"]

modelsSection :: [CatalogModel] -> [Text]
modelsSection [] = ["  \"models\": []"]
modelsSection ms =
  ["  \"models\": ["]
    ++ concat (addBlockCommas (map renderModel ms))
    ++ ["  ]"]

-- | Append a trailing comma to the last line of each block except the
-- final one, so emitted model objects are comma-separated.
addBlockCommas :: [[Text]] -> [[Text]]
addBlockCommas [] = []
addBlockCommas [b] = [b]
addBlockCommas (b : rest) = appendCommaToLast b : addBlockCommas rest
  where
    appendCommaToLast xs = case reverse xs of
      [] -> xs
      (lastLine : front) -> reverse ((lastLine <> ",") : front)

renderModel :: CatalogModel -> [Text]
renderModel m =
  [ "    {",
    "      \"id\": " <> jsonString (m ^. #modelId) <> ",",
    "      \"name\": " <> jsonString (m ^. #name) <> ",",
    "      \"reasoning\": " <> jsonBool (m ^. #reasoning) <> ",",
    "      \"input\": " <> renderInput (m ^. #input) <> ",",
    "      \"cost\": {",
    "        \"input\": " <> renderNum (c ^. #inputCost) <> ",",
    "        \"output\": " <> renderNum (c ^. #outputCost) <> ",",
    "        \"cacheRead\": " <> renderNum (c ^. #cacheReadCost) <> ",",
    "        \"cacheWrite\": " <> renderNum (c ^. #cacheWriteCost),
    "      },",
    "      \"contextWindow\": " <> Text.pack (show (m ^. #contextWindow)) <> ",",
    "      \"maxOutputTokens\": " <> Text.pack (show (m ^. #maxOutputTokens)) <> ",",
    "      \"enabled\": true",
    "    }"
  ]
  where
    c = m ^. #cost

renderInput :: [InputModality] -> Text
renderInput ms = "[" <> Text.intercalate ", " (map one ms) <> "]"
  where
    one InputText = "\"text\""
    one InputImage = "\"image\""

jsonBool :: Bool -> Text
jsonBool True = "true"
jsonBool False = "false"

-- | Render a cost as a fixed-point decimal. Whole values gain a
-- trailing @.0@ (e.g. @15@ → @15.0@) to match the existing files;
-- fractional values keep their natural decimal form (e.g. @0.075@).
renderNum :: Scientific -> Text
renderNum = Text.pack . formatScientific Fixed Nothing

-- | Render a 'Text' as a JSON string literal, escaping backslashes and
-- double quotes (sufficient for model ids and display names).
jsonString :: Text -> Text
jsonString t =
  "\"" <> Text.replace "\"" "\\\"" (Text.replace "\\" "\\\\" t) <> "\""
