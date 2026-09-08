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
-- @openai-chat-completions@ by default. Per-model API overrides allow
-- explicitly curated Responses models without changing the older routes.
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
    CatalogModelCompat (..),
    AnthropicGenerationFacts (..),
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

import Baikai.Compat (AnthropicThinkingStyle (..), OpenAICompletionsCompat (..), OpenAIResponsesCompat (..), defaultOpenAIResponsesCompat)
import Baikai.Model (InputModality (..))
import Baikai.Model qualified as Model
import Baikai.Prelude
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Data.Aeson (Value (String), eitherDecode, encode, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, formatScientific, fromRationalRepetendUnlimited)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

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

-- | The two request-shaping facts every curated Anthropic model must
-- state before it can enter the catalog. Which extended-thinking wire
-- shape a generation accepts, and whether it accepts the sampling
-- parameters @temperature@, @top_p@ and @top_k@, are facts about the
-- generation that no amount of inspecting the model id or the base URL
-- can recover; they are curated here and travel through the catalog
-- JSON into the generated 'Baikai.Compat.AnthropicMessagesCompat'.
data AnthropicGenerationFacts = AnthropicGenerationFacts
  { thinkingStyle :: !AnthropicThinkingStyle,
    supportsSamplingParameters :: !Bool,
    supportsForcedToolChoice :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | Per-model endpoint facts preserved through catalog refreshes.
data CatalogModelCompat
  = CatalogAnthropicCompat !AnthropicGenerationFacts
  | CatalogOpenAICompat !OpenAICompletionsCompat
  | CatalogResponsesCompat !OpenAIResponsesCompat
  deriving stock (Eq, Show, Generic)

-- | One emitted catalog model. @enabled@ is always @true@ for emitted
-- models, so it is not stored here; the renderer writes it literally.
data CatalogModel = CatalogModel
  { modelId :: !Text,
    name :: !Text,
    reasoning :: !Bool,
    input :: ![InputModality],
    cost :: !CatalogCost,
    pricingPolicy :: !(Maybe Model.PricingPolicy),
    contextWindow :: !Integer,
    maxOutputTokens :: !Integer,
    apiOverride :: !(Maybe Text),
    compat :: !(Maybe CatalogModelCompat)
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
    include :: !(Text -> Bool),
    -- | The per-model @compat@ block to render, if this provider needs
    -- one. 'const Nothing' for a provider whose file-level
    -- @"compat": "auto"@ directive says everything.
    apiFor :: !(Text -> Maybe Text),
    compatFor :: !(Text -> Maybe CatalogModelCompat)
  }
  deriving stock (Generic)

-- | Curation include set for OpenAI: the chat-completions-compatible
-- current line. Responses-API-only ids (@*-pro@, @*-codex@,
-- @*-deep-research@) are deliberately absent.
openaiInclude :: Map Text (Maybe CatalogModelCompat)
openaiInclude =
  Map.insert "gpt-6-astra" (Just (CatalogResponsesCompat astraResponsesFacts)) $
    Map.fromList
      [ (model, Nothing)
      | model <-
          [ "gpt-5.6",
            "gpt-5.6-luna",
            "gpt-5.6-sol",
            "gpt-5.6-terra",
            "gpt-5.5",
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
      ]
  where
    -- 2026-09-07: native tools require Responses; only modern 30m cache TTL.
    -- https://developers.openai.com/api/docs/guides/latest-model
    astraResponsesFacts =
      defaultOpenAIResponsesCompat
        { supportsPromptCacheOptions = True,
          supportsLongCacheRetention = False,
          supportsSamplingParameters = False,
          supportedReasoningEfforts = Just [ThinkingLow, ThinkingMedium, ThinkingHigh, ThinkingXHigh, ThinkingMax]
        }

-- | Curation include set for Anthropic: the current generations, each
-- keyed to the request-shaping facts of its generation.
--
-- This is the one place a human vets an Anthropic id, so it is also the
-- one place the facts are stated: no id can be curated in without them,
-- and a wholesale refresh cannot lose them. Each entry MUST carry a
-- dated comment naming its source, exactly as 'overrides' does. The
-- generator refuses an @anthropic-messages@ entry that reaches it
-- without a @compat@ block, so a hand edit cannot quietly drop one
-- back to host auto-detection.
anthropicInclude :: Map Text AnthropicGenerationFacts
anthropicInclude =
  Map.fromList
    [ -- 2026-08-27: adaptive-only, sampling parameters rejected with a
      -- 400 — Anthropic API reference cached 2026-06-24, as consulted
      -- by REV-2 C.1 (docs/reviews/correctness-and-api-review-follow-up.md).
      -- docs/plans/60-... named this id as the one the include set did not
      -- yet carry, and stated the facts it would have to arrive with.
      ("claude-opus-5", adaptiveNoSampling),
      -- 2026-08-27: adaptive-only, sampling parameters rejected with a
      -- 400 — same source.
      ("claude-opus-4-8", adaptiveNoSampling),
      -- 2026-08-27: adaptive-only, sampling parameters rejected — same source.
      ("claude-opus-4-7", adaptiveNoSampling),
      -- 2026-08-27: accepts both thinking shapes, but the budget shape is
      -- deprecated for this generation, so baikai sends the adaptive one;
      -- sampling parameters still accepted — same source.
      ("claude-opus-4-6", adaptiveWithSampling),
      -- 2026-08-27: budget shape, sampling parameters accepted — same source.
      ("claude-opus-4-5", budgetWithSampling),
      -- 2026-08-27: adaptive-only, sampling parameters rejected with a 400.
      -- This is the finding: the retired prefix table did not know this id
      -- and sent it budget_tokens — same source.
      ("claude-sonnet-5", adaptiveNoSampling),
      -- 2026-08-27: as claude-opus-4-6 — budget deprecated but functional,
      -- sampling accepted; baikai prefers the non-deprecated shape — same
      -- source. Plan 40 left this membership to a live check that never
      -- happened; docs/plans/60-... M4 is where it meets a real key.
      ("claude-sonnet-4-6", adaptiveWithSampling),
      -- 2026-08-27: budget shape, sampling parameters accepted — same source.
      ("claude-sonnet-4-5", budgetWithSampling),
      -- 2026-08-27: budget shape, sampling parameters accepted — same source.
      ("claude-haiku-4-5", budgetWithSampling),
      -- 2026-08-27: adaptive-only, sampling parameters rejected — same source.
      ("claude-fable-5", adaptiveNoSampling),
      -- 2026-09-07: always-on adaptive thinking; omit sampling parameters.
      -- https://platform.claude.com/docs/en/models/fable-5-1/whats-new-fable-5-1
      ("claude-fable-5-1", adaptiveNoSampling & #supportsForcedToolChoice .~ False)
    ]
  where
    -- 2026-09-07: all curated predecessors accept forced choice (subject to
    -- their separate manual-thinking constraint); only Fable 5.1 rejects it.
    -- https://platform.claude.com/docs/en/api/errors
    -- https://platform.claude.com/docs/en/models/fable-5-1/migration-guide
    adaptiveNoSampling = AnthropicGenerationFacts AnthropicThinkingAdaptive False True
    adaptiveWithSampling = AnthropicGenerationFacts AnthropicThinkingAdaptive True True
    budgetWithSampling = AnthropicGenerationFacts AnthropicThinkingBudget True True

-- | OpenAI curation with a Chat default and explicit Responses overrides.
openaiSpec :: ProviderSpec
openaiSpec =
  ProviderSpec
    { provider = "openai",
      baseUrl = "https://api.openai.com",
      api = "openai-chat-completions",
      include = (`Map.member` openaiInclude),
      apiFor = \mid -> case Map.lookup mid openaiInclude >>= id of
        Just (CatalogResponsesCompat _) -> Just "openai-responses"
        _ -> Nothing,
      compatFor = \mid -> Map.lookup mid openaiInclude >>= id
    }

-- | Provider spec for Anthropic's first-party messages endpoint.
anthropicSpec :: ProviderSpec
anthropicSpec =
  ProviderSpec
    { provider = "anthropic",
      baseUrl = "https://api.anthropic.com",
      api = "anthropic-messages",
      include = (`Map.member` anthropicInclude),
      apiFor = const Nothing,
      compatFor = fmap CatalogAnthropicCompat . (`Map.lookup` anthropicInclude)
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
          pricingPolicy = Map.lookup (spec ^. #provider, m ^. #modelId) pricingPolicies,
          contextWindow = fromMaybe 0 (m ^. #contextWindow),
          maxOutputTokens = fromMaybe 0 (m ^. #maxOutputTokens),
          apiOverride = (spec ^. #apiFor) (m ^. #modelId),
          compat = (spec ^. #compatFor) (m ^. #modelId)
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
    "      \"maxOutputTokens\": " <> Text.pack (show (m ^. #maxOutputTokens)) <> ","
  ]
    ++ maybe [] (\a -> ["      \"api\": " <> jsonString a <> ","]) (m ^. #apiOverride)
    ++ maybe [] (\p -> ["      \"pricingPolicy\": " <> renderPricingPolicy p <> ","]) (m ^. #pricingPolicy)
    ++ renderModelCompat (m ^. #compat)
    ++ [ "      \"enabled\": true",
         "    }"
       ]
  where
    c = m ^. #cost

-- | Provider documentation verified 2026-09-07. These rules supplement base
-- models.dev rates, which do not describe the full request billing policy.
-- https://developers.openai.com/api/docs/models/gpt-6-astra
-- https://platform.claude.com/docs/en/models/fable-5-1/overview
pricingPolicies :: Map (Text, Text) Model.PricingPolicy
pricingPolicies =
  Map.fromList
    [ (("openai", "gpt-6-astra"), Model.PricingPolicy [Model.InputPriceTier 272000 (Model.ModelCost 20 75 2 25)] Nothing),
      (("anthropic", "claude-fable-5-1"), Model.PricingPolicy [] (Just 20))
    ]

renderPricingPolicy :: Model.PricingPolicy -> Text
renderPricingPolicy p = "{\"inputTiers\": [" <> Text.intercalate ", " (map tier (Model.inputTiers p)) <> "]" <> maybe "" (\r -> ", \"longCacheWriteCost\": " <> num r) (Model.longCacheWriteCost p) <> "}"
  where
    num = renderNum . fst . fromRationalRepetendUnlimited
    tier t = "{\"inputAbove\": " <> Text.pack (show (Model.inputAbove t)) <> ", \"rates\": " <> rates (Model.rates t) <> "}"
    rates c = "{\"input\": " <> num (Model.inputCost c) <> ", \"output\": " <> num (Model.outputCost c) <> ", \"cacheRead\": " <> num (Model.cacheReadCost c) <> ", \"cacheWrite\": " <> num (Model.cacheWriteCost c) <> "}"

-- | Render the per-model @compat@ block, if the provider spec supplied
-- one. The block sits between @maxOutputTokens@ and @enabled@ so a
-- @git diff@ over the catalog shows a generation's wire facts next to
-- its limits.
renderModelCompat :: Maybe CatalogModelCompat -> [Text]
renderModelCompat Nothing = []
renderModelCompat (Just (CatalogAnthropicCompat facts)) =
  [ "      \"compat\": {",
    "        \"kind\": \"anthropic-messages\",",
    "        \"thinkingStyle\": "
      <> jsonString (renderThinkingStyle (facts ^. #thinkingStyle))
      <> ",",
    "        \"supportsSamplingParameters\": "
      <> jsonBool (facts ^. #supportsSamplingParameters)
      <> ",",
    "        \"supportsForcedToolChoice\": " <> jsonBool (facts ^. #supportsForcedToolChoice),
    "      },"
  ]
renderModelCompat (Just (CatalogOpenAICompat facts)) =
  [ "      \"compat\": {",
    "        \"kind\": \"openai-completions\",",
    "        \"supportsToolCalls\": " <> jsonBool (facts ^. #supportsToolCalls) <> ",",
    "        \"supportsSamplingParameters\": " <> jsonBool (facts ^. #supportsSamplingParameters) <> ",",
    "        \"supportedReasoningEfforts\": " <> maybe "null" (\xs -> "[" <> Text.intercalate ", " (map (jsonString . renderThinkingLevel) xs) <> "]") (facts ^. #supportedReasoningEfforts),
    "      },"
  ]
renderModelCompat (Just (CatalogResponsesCompat facts)) =
  [ "      \"compat\": {",
    "        \"kind\": \"openai-responses\",",
    "        \"supportsSamplingParameters\": " <> jsonBool (facts ^. #supportsSamplingParameters) <> ",",
    "        \"supportsLongCacheRetention\": " <> jsonBool (facts ^. #supportsLongCacheRetention) <> ",",
    "        \"supportsPromptCacheOptions\": " <> jsonBool (facts ^. #supportsPromptCacheOptions) <> ",",
    "        \"supportedReasoningEfforts\": " <> maybe "null" (\xs -> "[" <> Text.intercalate ", " (map (jsonString . renderThinkingLevel) xs) <> "]") (facts ^. #supportedReasoningEfforts),
    "      },"
  ]

-- | The catalog dialect spells the thinking style as a word, as every
-- other catalog enum does. The derived JSON instance on
-- 'Baikai.Compat.AnthropicThinkingStyle' is part of 'Baikai.Model.Model'\'s
-- pinned round trip and is deliberately not reused here.
renderThinkingStyle :: AnthropicThinkingStyle -> Text
renderThinkingStyle AnthropicThinkingBudget = "budget"
renderThinkingStyle AnthropicThinkingAdaptive = "adaptive"

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

-- | Render a 'Text' as a JSON string literal. Delegate escaping to aeson so
-- control characters, quotes, and backslashes follow the JSON encoder exactly.
jsonString :: Text -> Text
jsonString = decodeUtf8 . LBS.toStrict . encode . String
