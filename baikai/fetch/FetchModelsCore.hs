{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

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

    -- * Rendering
    renderCatalog,
  )
where

import Baikai.Model (InputModality (..))
import Data.Aeson (FromJSON (..), (.!=), (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, formatScientific)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)

-- * Upstream shape ----------------------------------------------------

-- | The subset of a models.dev model object that we consume. Every
-- optional field defaults the way pi-mono's scraper does: missing
-- numbers become 0 at normalization time, missing arrays become empty.
data UpstreamModel = UpstreamModel
  { uId :: !Text,
    uName :: !(Maybe Text),
    uToolCall :: !Bool,
    uReasoning :: !Bool,
    uCtx :: !(Maybe Integer),
    uMaxOut :: !(Maybe Integer),
    uCostIn :: !(Maybe Scientific),
    uCostOut :: !(Maybe Scientific),
    uCacheRead :: !(Maybe Scientific),
    uCacheWrite :: !(Maybe Scientific),
    uInputMods :: ![Text]
  }
  deriving stock (Eq, Show)

instance FromJSON UpstreamModel where
  parseJSON = Aeson.withObject "UpstreamModel" $ \o -> do
    uId <- o .: "id"
    uName <- o .:? "name"
    uToolCall <- o .:? "tool_call" .!= False
    uReasoning <- o .:? "reasoning" .!= False
    mLimit <- o .:? "limit"
    mCost <- o .:? "cost"
    mMods <- o .:? "modalities"
    pure
      UpstreamModel
        { uId = uId,
          uName = uName,
          uToolCall = uToolCall,
          uReasoning = uReasoning,
          uCtx = mLimit >>= limitContext,
          uMaxOut = mLimit >>= limitOutput,
          uCostIn = mCost >>= costIn,
          uCostOut = mCost >>= costOut,
          uCacheRead = mCost >>= costCacheRead,
          uCacheWrite = mCost >>= costCacheWrite,
          uInputMods = maybe [] modalitiesInput mMods
        }

-- | @limit@ sub-object.
data Limit = Limit
  { limitContext :: !(Maybe Integer),
    limitOutput :: !(Maybe Integer)
  }

instance FromJSON Limit where
  parseJSON = Aeson.withObject "limit" $ \o ->
    Limit <$> o .:? "context" <*> o .:? "output"

-- | @cost@ sub-object (US dollars per million tokens).
data Cost = Cost
  { costIn :: !(Maybe Scientific),
    costOut :: !(Maybe Scientific),
    costCacheRead :: !(Maybe Scientific),
    costCacheWrite :: !(Maybe Scientific)
  }

instance FromJSON Cost where
  parseJSON = Aeson.withObject "cost" $ \o ->
    Cost
      <$> o .:? "input"
      <*> o .:? "output"
      <*> o .:? "cache_read"
      <*> o .:? "cache_write"

-- | @modalities@ sub-object; we only read @input@.
newtype Modalities = Modalities {modalitiesInput :: [Text]}

instance FromJSON Modalities where
  parseJSON = Aeson.withObject "modalities" $ \o ->
    Modalities <$> o .:? "input" .!= []

-- | One provider object in the models.dev document. We only read the
-- @models@ map; every other provider field is ignored.
newtype UpstreamProvider = UpstreamProvider {upModels :: Map Text UpstreamModel}

instance FromJSON UpstreamProvider where
  parseJSON = Aeson.withObject "UpstreamProvider" $ \o ->
    UpstreamProvider <$> o .:? "models" .!= Map.empty

-- | Parse a full models.dev document into @provider -> (modelId ->
-- model)@. The top-level document is a JSON object keyed by provider
-- id; each provider object carries a @models@ map keyed by model id.
parseUpstream :: BSL.ByteString -> Either String (Map Text (Map Text UpstreamModel))
parseUpstream bs = Map.map upModels <$> Aeson.eitherDecode bs

-- * Output catalog shape ---------------------------------------------

-- | Per-million-token cost rates, in the catalog's field names.
data CatalogCost = CatalogCost
  { ccInput :: !Scientific,
    ccOutput :: !Scientific,
    ccCacheRead :: !Scientific,
    ccCacheWrite :: !Scientific
  }
  deriving stock (Eq, Show)

-- | One emitted catalog model. @enabled@ is always @true@ for emitted
-- models, so it is not stored here; the renderer writes it literally.
data CatalogModel = CatalogModel
  { cmId :: !Text,
    cmName :: !Text,
    cmReasoning :: !Bool,
    cmInput :: ![InputModality],
    cmCost :: !CatalogCost,
    cmContextWindow :: !Integer,
    cmMaxOutputTokens :: !Integer
  }
  deriving stock (Eq, Show)

-- | A whole catalog file: one provider and its curated models.
data Catalog = Catalog
  { cProvider :: !Text,
    cBaseUrl :: !Text,
    cApi :: !Text,
    cModels :: ![CatalogModel]
  }
  deriving stock (Eq, Show)

-- * Provider specs and normalization ---------------------------------

-- | What a provider needs to be normalized: its identity in the
-- catalog and the curation predicate selecting which upstream model
-- ids to keep.
data ProviderSpec = ProviderSpec
  { psProvider :: !Text,
    psBaseUrl :: !Text,
    psApi :: !Text,
    psInclude :: !(Text -> Bool)
  }

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
    { psProvider = "openai",
      psBaseUrl = "https://api.openai.com",
      psApi = "openai-chat-completions",
      psInclude = (`Set.member` openaiInclude)
    }

-- | Provider spec for Anthropic's first-party messages endpoint.
anthropicSpec :: ProviderSpec
anthropicSpec =
  ProviderSpec
    { psProvider = "anthropic",
      psBaseUrl = "https://api.anthropic.com",
      psApi = "anthropic-messages",
      psInclude = (`Set.member` anthropicInclude)
    }

-- | Normalize one provider's upstream models into a 'Catalog'. Keeps
-- only @tool_call == True@ models that pass the curation predicate,
-- maps each upstream model to a 'CatalogModel' (dropping @pdf@ and any
-- non-text/image modality; missing costs and limits default to 0 so a
-- human notices), and sorts by model id for deterministic output.
normalizeProvider :: ProviderSpec -> Map Text UpstreamModel -> Catalog
normalizeProvider spec upstream =
  Catalog
    { cProvider = psProvider spec,
      cBaseUrl = psBaseUrl spec,
      cApi = psApi spec,
      cModels = sortOn cmId (map toCatalogModel kept)
    }
  where
    kept =
      [ m
      | m <- Map.elems upstream,
        uToolCall m,
        psInclude spec (uId m)
      ]
    toCatalogModel m =
      CatalogModel
        { cmId = uId m,
          cmName = fromMaybe (uId m) (uName m),
          cmReasoning = uReasoning m,
          cmInput =
            if "image" `elem` uInputMods m
              then [InputText, InputImage]
              else [InputText],
          cmCost =
            CatalogCost
              { ccInput = fromMaybe 0 (uCostIn m),
                ccOutput = fromMaybe 0 (uCostOut m),
                ccCacheRead = fromMaybe 0 (uCacheRead m),
                ccCacheWrite = fromMaybe 0 (uCacheWrite m)
              },
          cmContextWindow = fromMaybe 0 (uCtx m),
          cmMaxOutputTokens = fromMaybe 0 (uMaxOut m)
        }

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
    ++ [ "  \"provider\": " <> jsonString (cProvider cat) <> ",",
         "  \"baseUrl\": " <> jsonString (cBaseUrl cat) <> ",",
         "  \"api\": " <> jsonString (cApi cat) <> ",",
         "  \"compat\": \"auto\","
       ]
    ++ modelsSection (cModels cat)
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
    "      \"id\": " <> jsonString (cmId m) <> ",",
    "      \"name\": " <> jsonString (cmName m) <> ",",
    "      \"reasoning\": " <> jsonBool (cmReasoning m) <> ",",
    "      \"input\": " <> renderInput (cmInput m) <> ",",
    "      \"cost\": {",
    "        \"input\": " <> renderNum (ccInput c) <> ",",
    "        \"output\": " <> renderNum (ccOutput c) <> ",",
    "        \"cacheRead\": " <> renderNum (ccCacheRead c) <> ",",
    "        \"cacheWrite\": " <> renderNum (ccCacheWrite c),
    "      },",
    "      \"contextWindow\": " <> Text.pack (show (cmContextWindow m)) <> ",",
    "      \"maxOutputTokens\": " <> Text.pack (show (cmMaxOutputTokens m)) <> ",",
    "      \"enabled\": true",
    "    }"
  ]
  where
    c = cmCost m

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
