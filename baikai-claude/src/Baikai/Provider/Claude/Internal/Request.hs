{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal request mapping for the Anthropic Messages provider.
--
-- This module is exposed for provider tests and debugging but is not covered by PVP
-- compatibility guarantees. Import the public provider module for stable application code.
module Baikai.Provider.Claude.Internal.Request
  ( mapRequest,
    planRequest,
    planSpeed,
    planThinking,
    describeThinkingFor,
    ThinkingPlan (..),
    SamplingPlan (..),
    uncappedMaxTokensFloor,
    computeThinking,
    normalizeToolCallId,
  )
where

import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Compat (AnthropicMessagesCompat (..), AnthropicThinkingStyle (..))
import Baikai.Content qualified as Content
import Baikai.Context (Context (..))
import Baikai.Context qualified as Context
import Baikai.Error qualified as Error
import Baikai.Evidence
  ( ThinkingAdjustment (..),
    ThinkingMode (..),
    ThinkingTranslation (..),
    noThinkingRequested,
  )
import Baikai.Message qualified as Msg
import Baikai.Model (Model, anthropicMessagesCompatFor)
import Baikai.Options (Options (..))
import Baikai.ResponseFormat (JsonSchemaFormat (..), ResponseFormat (..))
import Baikai.Speed (Speed (..))
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel, thinkingTokenBudget)
import Baikai.Tool qualified as Tool
import Claude.Messages qualified as Messages
import Control.Lens ((%~), (&), (.~), (^.))
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAlphaNum, isAscii)
import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- ============================================================
-- Request mapping: Context and Options onto the SDK's request record.
-- ============================================================

-- | Map a baikai request onto the SDK's 'Messages.MessageRequest', and
-- describe what the caller's reasoning-effort preference became on the
-- way.
--
-- The 'ThinkingTranslation' is returned rather than reconstructed
-- downstream because this is the only place that knows all of it: the
-- host compatibility lookup, the model's reasoning capability, the
-- adaptive effort vocabulary, and the max-tokens interaction below all
-- feed into it. A trace sink asked to re-derive it would have to
-- reimplement every one of them.
mapRequest ::
  Model -> Context -> Options -> Either Text (Messages.MessageRequest, ThinkingTranslation)
mapRequest m ctx opts = do
  either (Left . Error.message) pure (Context.refuseAssistantDataHistory ctx)
  case opts ^. #toolChoice of
    Just Tool.ToolChoiceRequired | not (anthropicMessagesCompatFor m).supportsForcedToolChoice -> unsupportedForcedChoice
    Just (Tool.ToolChoiceSpecific _) | not (anthropicMessagesCompatFor m).supportsForcedToolChoice -> unsupportedForcedChoice
    _ -> pure ()
  mapM_
    ( \msg -> case msg of
        Msg.AssistantMessage payload ->
          mapM_
            ( \block -> case block of
                Content.AssistantThinking th
                  | Just _ <- Content.replayState th ->
                      Left "This endpoint cannot replay provider-scoped reasoning state; use its originating API and model"
                _ -> pure ()
            )
            (payload ^. #content)
        _ -> pure ()
    )
    (ctx ^. #messages)
  msgs <- catMaybes <$> traverse mapMessage (Vector.toList (ctx ^. #messages))
  outputConfig <- traverse mkAnthropicOutputConfig (opts ^. #responseFormat)
  let compat = anthropicMessagesCompatFor m
      cap = m ^. #maxOutputTokens
      baseTokens = resolveBaseTokens m opts
      clamp n = if cap == 0 then n else min n cap
      (plan, sampling, translation) = planRequest m opts
      maxTokensField_ = case budget plan of
        Just b -> clamp (baseTokens + b)
        Nothing -> clamp baseTokens
      cacheControlField = computeCacheControl compat (opts ^. #cacheRetention)
      features =
        Messages.MessageFeatures
          (mergeEffort (effort plan) outputConfig)
          (field plan)
          cacheControlField
          (map mkAnthropicTool (Vector.toList (ctx ^. #tools)))
          (mkAnthropicToolChoice <$> (opts ^. #toolChoice))
          (fst (planSpeed compat (opts ^. #speed)))
      conversation =
        Messages.withConversationHistory msgs $
          Messages.EmptyConversation (m ^. #modelId) (Messages.SystemText <$> (ctx ^. #systemPrompt)) features
      controls =
        Messages.defaultRequestControls
          { Messages.temperature = sampling ^. #temperature,
            Messages.topP = sampling ^. #topP
          }
  let limit = fromMaybe Messages.cacheOnly (Messages.maxTokens maxTokensField_)
  pure
    ( Messages.withRequestControls controls (Messages.MessageRequest conversation limit (opts ^. #stopSequences)),
      translation
    )

unsupportedForcedChoice :: Either Text ()
unsupportedForcedChoice = Left "This model does not support forced tool choice; use ToolChoiceAuto or ToolChoiceNone"

-- | The sampling parameters that will reach the wire, after the compat
-- record's gate. 'Nothing' means the field is omitted — the SDK encodes
-- 'Messages.MessageRequest' with @omitNothingFields = True@, so a
-- 'Nothing' is genuinely absent from the request body rather than a
-- JSON @null@ the provider would reject.
data SamplingPlan = SamplingPlan
  { temperature :: !(Maybe Double),
    topP :: !(Maybe Double)
  }
  deriving stock (Eq, Show, Generic)

-- | The @max_tokens@ sent for a model whose cap is unknown (@0@) when
-- the caller set no 'Baikai.Options.maxTokens'.
--
-- Anthropic requires @max_tokens@ on every request and rejects @0@, so
-- the OpenAI adapter's rule — omit the field entirely — is not
-- available here. 1024 is the SDK's own @_CreateMessage@ default and is
-- accepted by every generation and every known compatible host.
--
-- This is a default, not a downgrade of anything the caller asked for,
-- so no adjustment is recorded: it is visible in the request body, which
-- the evidence record already digests. An explicit
-- @maxTokens = Just 0@ is forwarded as written.
uncappedMaxTokensFloor :: Natural
uncappedMaxTokensFloor = 1024

-- | The output-token base this request resolves to before any thinking
-- budget is added: the caller's 'Baikai.Options.maxTokens' if they set
-- one, the model's cap if it knows one, and 'uncappedMaxTokensFloor'
-- when neither is available.
resolveBaseTokens :: Model -> Options -> Natural
resolveBaseTokens m opts = case opts ^. #maxTokens of
  Just n -> n
  Nothing
    | cap == 0 -> uncappedMaxTokensFloor
    | otherwise -> cap
  where
    cap = m ^. #maxOutputTokens

-- | Everything 'mapRequest' decides about thinking, sampling and the
-- output ceiling, and the one description of all of it.
--
-- Factored out of 'mapRequest' so the pre-dispatch strictness gate can
-- ask what /would/ happen without building a request. Both callers go
-- through this one function on purpose: a gate that reimplemented the
-- ceiling arithmetic would miss the least discoverable of baikai's
-- downgrades the first time either side changed, and it would miss it
-- silently. The same argument puts sampling here rather than in
-- 'mapRequest': the adapter that builds the request owns the
-- description of what it translated
-- (@docs\/adr\/0003-the-adapter-owns-the-translation-description.md@),
-- and a dropped @temperature@ is a translation, not an absence
-- (@docs\/adr\/0002-requested-translated-observed-are-never-collapsed.md@).
--
-- The thinking interaction it captures: the output-token ceiling this
-- request resolves to still has the thinking budget inside it, the
-- budget has to fit, and when it does not the entire thinking plan is
-- dropped. A caller who lowered @maxTokens@ on a reasoning model
-- silently loses thinking, which is why both colliding numbers are
-- recorded in the adjustment.
--
-- The sampling gate: 'Baikai.Compat.supportsSamplingParameters' says
-- whether the model generation accepts @temperature@ and @top_p@ at
-- all. Adaptive-era generations reject them with a 400, so they are
-- dropped and the drop is recorded. Three more sampling controls —
-- @seed@, @frequencyPenalty@ and @presencePenalty@ — have no field in
-- the Anthropic Messages API on any generation, so they are recorded
-- separately: one is a fact about the model, the other about the API.
planRequest :: Model -> Options -> (ThinkingPlan, SamplingPlan, ThinkingTranslation)
planRequest m opts =
  (plan, sampling, translation & #adjustments %~ (<> (samplingAdjustments <> snd (planSpeed compat (opts ^. #speed)))))
  where
    compat = anthropicMessagesCompatFor m
    cap = m ^. #maxOutputTokens
    baseTokens = resolveBaseTokens m opts
    clamp n = if cap == 0 then n else min n cap
    (plan0, translation0) = computeThinking compat m (opts ^. #thinking)
    resolvedCeiling = clamp (baseTokens + fromMaybe 0 (budget plan0))
    (plan, translation) = case (budget plan0, translation0 ^. #requested) of
      (Just b, Just lvl)
        | resolvedCeiling <= b ->
            ( emptyThinkingPlan,
              dropThinking (ThinkingDroppedBudgetExceeded lvl b resolvedCeiling) translation0
            )
      _ -> (plan0, translation0)

    gated = not (compat ^. #supportsSamplingParameters)
    sampling
      | gated = SamplingPlan {temperature = Nothing, topP = Nothing}
      | otherwise =
          SamplingPlan {temperature = opts ^. #temperature, topP = opts ^. #topP}

    -- In wire order, and only the ones the caller actually set.
    modelDropped =
      [name | (name, isSet) <- [("temperature", set_ (opts ^. #temperature)), ("top_p", set_ (opts ^. #topP))], isSet]
    apiDropped =
      [ name
      | (name, isSet) <-
          [ ("seed", set_ (opts ^. #seed)),
            ("frequency_penalty", set_ (opts ^. #frequencyPenalty)),
            ("presence_penalty", set_ (opts ^. #presencePenalty))
          ],
        isSet
      ]
    set_ :: Maybe a -> Bool
    set_ = maybe False (const True)

    samplingAdjustments =
      [SamplingDroppedUnsupportedModel modelDropped | gated, not (null modelDropped)]
        <> [SamplingDroppedUnsupportedApi apiDropped | not (null apiDropped)]

-- | The thinking half of 'planRequest', for callers that need only it.
planThinking :: Model -> Options -> (ThinkingPlan, ThinkingTranslation)
planThinking m opts = let (plan, _, translation) = planRequest m opts in (plan, translation)

-- | What this provider would do with the caller's reasoning-effort
-- request, without building or sending anything. The
-- 'Baikai.Provider.Registry.describeThinking' implementation for the
-- Anthropic Messages provider.
--
-- A projection of 'planRequest' rather than its own derivation, so the
-- gate, the builder and the evidence record all read one answer — the
-- sampling drops included.
describeThinkingFor :: Model -> Options -> ThinkingTranslation
describeThinkingFor m opts = snd (planThinking m opts)

mergeEffort :: Maybe Text -> Maybe Messages.OutputConfig -> Maybe Messages.OutputConfig
mergeEffort Nothing config = config
mergeEffort (Just value) config =
  Just (Messages.OutputConfig (Just (Messages.VersionedEffort value)) (config >>= Messages.schema))

mkAnthropicOutputConfig :: ResponseFormat -> Either Text Messages.OutputConfig
mkAnthropicOutputConfig = \case
  JsonSchema spec -> case spec.schema of
    Aeson.Object schema -> Right (Messages.OutputConfig Nothing (Just schema))
    _ -> Left "Anthropic Messages requires the output schema to be a JSON object"
  JsonObject -> Right (Messages.OutputConfig Nothing (Just (KeyMap.singleton "type" (Aeson.String "object"))))

computeCacheControl ::
  AnthropicMessagesCompat ->
  Maybe CacheRetention ->
  Maybe Messages.CacheControl
computeCacheControl _ Nothing = Nothing
computeCacheControl _ (Just CacheRetentionNone) = Nothing
computeCacheControl _ (Just CacheRetentionShort) = Just (Messages.Ephemeral Nothing)
computeCacheControl compat (Just CacheRetentionLong)
  | compat ^. #supportsLongCacheRetention = Just (Messages.Ephemeral (Just Messages.OneHour))
  | otherwise = Just (Messages.Ephemeral Nothing)

-- | Translate the call-time 'Baikai.ThinkingLevel' preference into
-- the Anthropic SDK's 'Messages.Thinking' shape.
--
-- We only enable the thinking field when the chosen model advertises
-- 'reasoning' support — sending a thinking config to a non-reasoning
-- model is a 400 error from Anthropic, not a silent no-op. Callers
-- that asked for thinking on a non-reasoning model get the request
-- shaped without it (the request still succeeds and returns a normal
-- response).
data ThinkingPlan = ThinkingPlan
  { field :: !(Maybe Messages.Thinking),
    effort :: !(Maybe Text),
    budget :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

emptyThinkingPlan :: ThinkingPlan
emptyThinkingPlan =
  ThinkingPlan
    { field = Nothing,
      effort = Nothing,
      budget = Nothing
    }

-- | Build the SDK's thinking configuration and, beside it, the
-- provider-neutral description of what the caller's level became.
--
-- The two travel together because they are two views of one decision.
-- Adaptive requests explicitly ask for summarized display, using the catalog
-- thinking style. Budget requests retain their existing provider default.
-- Display changes visibility only; it does not establish reasoning depth.
-- Returning only the first is what this provider used to do, and it is
-- why a caller could never tell an honoured request from a dropped one.
--
-- 'ThinkingNone' sends @thinking: {"type": "disabled"}@ when the
-- generation accepts it ('supportsThinkingDisabled'), on either style:
-- some adaptive generations otherwise think by default, and on a
-- budget one the explicit value is documented as identical to omitting
-- the field. It carries no effort and no display, because Anthropic
-- rejects @display@ beside @disabled@. A generation that rejects
-- @disabled@ falls through to the adaptive branch below, where 'adaptiveEffort'
-- clamps @none@ to @low@ and the clamp is recorded.
computeThinking ::
  AnthropicMessagesCompat ->
  Model ->
  Maybe ThinkingLevel ->
  (ThinkingPlan, ThinkingTranslation)
computeThinking _ _ Nothing = (emptyThinkingPlan, noThinkingRequested)
computeThinking compat m (Just lvl)
  | not (m ^. #reasoning) =
      ( emptyThinkingPlan,
        ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeUnsupported,
            effortText = Nothing,
            budgetTokens = Nothing,
            wireField = Nothing,
            displayText = Nothing,
            adjustments = [ThinkingDroppedUnsupportedModel lvl]
          }
      )
  | lvl == ThinkingNone && compat ^. #supportsThinkingDisabled =
      -- Opus 5 and Haiku 5.5 accept @disabled@ only at effort @high@ or
      -- below. That is safe here: this branch sends no effort, so
      -- @output_config@ effort is omitted.
      ( ThinkingPlan
          { field = Just Messages.ThinkingDisabled,
            effort = Nothing,
            budget = Nothing
          },
        ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeToggle,
            effortText = Nothing,
            budgetTokens = Nothing,
            wireField = Just "thinking",
            displayText = Nothing,
            adjustments = []
          }
      )
  | lvl == ThinkingNone && thinkingStyle compat /= AnthropicThinkingAdaptive =
      -- Legacy or hand-rolled compat records can reach this: a budget-style
      -- host that rejects @disabled@. Omitting the field is the provider
      -- default, which a budget-era generation documents as no thinking,
      -- but nothing on the wire says so.
      ( emptyThinkingPlan,
        ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeUnsupported,
            effortText = Nothing,
            budgetTokens = Nothing,
            wireField = Nothing,
            displayText = Nothing,
            adjustments = [EffortOmitted lvl]
          }
      )
  | thinkingStyle compat == AnthropicThinkingAdaptive =
      let e = adaptiveEffort lvl
       in ( ThinkingPlan
              { field = Just (Messages.Adaptive (Just Messages.Summarized)),
                effort = Just e,
                budget = Nothing
              },
            ThinkingTranslation
              { requested = Just lvl,
                mode = ThinkingModeAdaptive,
                effortText = Just e,
                budgetTokens = Nothing,
                wireField = Just "thinking",
                displayText = Just "summarized",
                adjustments = adaptiveAdjustments lvl e
              }
          )
  | otherwise =
      let b = thinkingTokenBudget lvl
       in ( ThinkingPlan
              { field = Just (Messages.ManualBudget b Nothing),
                effort = Nothing,
                budget = Just b
              },
            ThinkingTranslation
              { requested = Just lvl,
                mode = ThinkingModeBudget,
                effortText = Nothing,
                budgetTokens = Just b,
                -- A budget expresses the requested level exactly, so
                -- there is nothing to adjust.
                wireField = Just "thinking",
                displayText = Nothing,
                adjustments = []
              }
          )

-- | The effort word sent for each level on the adaptive style.
--
-- Every level sends a word, @high@ included. Anthropic's defaults differ
-- by model (Claude Opus 5.5 and Claude Haiku 5.5 default to @medium@,
-- other adaptive models to @high@; see
-- <https://platform.claude.com/docs/en/build-with-claude/effort>), so an
-- omitted field does not mean @high@. Sending a model's default
-- explicitly is documented as identical to omitting it.
--
-- 'ThinkingNone' reaches this when disable support is absent from the
-- compatibility record. The positive @low@ fallback is recorded, so it
-- cannot pass a strict caller's explicit off requirement.
adaptiveEffort :: ThinkingLevel -> Text
adaptiveEffort = \case
  ThinkingNone -> "low"
  ThinkingMinimal -> "low"
  ThinkingLow -> "low"
  ThinkingMedium -> "medium"
  ThinkingHigh -> "high"
  ThinkingXHigh -> "xhigh"
  ThinkingMax -> "max"

-- | What Anthropic's adaptive vocabulary did to the requested level.
--
-- Derived from what 'adaptiveEffort' actually produced rather than from
-- a second table beside it, so the two cannot drift. An effort word that
-- differs from the level's canonical name is a clamp onto the nearest
-- word the adaptive vocabulary has — Anthropic's has no @minimal@.
adaptiveAdjustments :: ThinkingLevel -> Text -> [ThinkingAdjustment]
adaptiveAdjustments lvl wire
  | wire == renderThinkingLevel lvl = []
  | otherwise = [EffortClamped lvl wire]

-- | Record that, after all, nothing about thinking reached the wire.
--
-- Every field describing a wire value is cleared, because after the drop
-- there is none. The adjustment is appended rather than replacing the
-- list so a reader sees the order things were applied in.
dropThinking :: ThinkingAdjustment -> ThinkingTranslation -> ThinkingTranslation
dropThinking adj t =
  t
    & #mode .~ ThinkingModeUnsupported
    & #effortText .~ Nothing
    & #budgetTokens .~ Nothing
    & #wireField .~ Nothing
    & #displayText .~ Nothing
    & #adjustments %~ (<> [adj])

-- | Map a baikai 'Tool.Tool' into the upstream Anthropic
-- 'ClaudeTool.ToolDefinition'. The SDK helper is used to populate
-- the ordinary typed fields; the raw request shaper later restores
-- the caller's verbatim @input_schema@ because
-- 'ClaudeTool.functionTool' keeps only a subset of JSON Schema.
--
-- The compat record is accepted at this layer for call-site
-- consistency; per-tool @cache_control@ markers are applied by
-- 'Baikai.Provider.Claude.Shape.injectToolCacheControl'.
mkAnthropicTool :: Tool.Tool -> Messages.Tool
mkAnthropicTool tool =
  case Tool.parameters tool of
    Aeson.Object schema -> Messages.CustomTool (Messages.ClientTool (Tool.name tool) (Just (Tool.description tool)) schema Nothing Nothing)
    schema ->
      Messages.VersionedTool (KeyMap.fromList ["name" .= Tool.name tool, "description" .= Tool.description tool, "input_schema" .= schema])

mkAnthropicToolChoice :: Tool.ToolChoice -> Messages.ToolChoice
mkAnthropicToolChoice = \case
  Tool.ToolChoiceAuto -> Messages.AutoTool False
  Tool.ToolChoiceRequired -> Messages.AnyTool False
  Tool.ToolChoiceSpecific name -> Messages.NamedTool name False
  Tool.ToolChoiceNone -> Messages.NoTool

-- | Anthropic enforces @[a-zA-Z0-9_-]@ on tool-call ids and caps their
-- length at 64 characters. Callers may have used any naming convention,
-- so the provider boundary normalizes here whenever an id is
-- round-tripped back to Anthropic — both on assistant turn replay
-- ('Messages.InputToolUse') and on tool-result messages
-- ('Messages.InputToolResult').
--
-- An id that already satisfies the rule passes through byte for byte.
-- That covers every id either provider actually mints — Anthropic's
-- @toolu_…@ and OpenAI's @call_…@ — and it must, because the
-- tool-result side normalizes with this same function and the two have
-- to agree.
--
-- Any other id is sanitised, truncated to 51 characters and suffixed
-- with @_@ plus twelve lowercase hex characters of the SHA-256 of the
-- /original/. Mapping every disallowed character to @_@ and truncating
-- is not injective: @a.b@ and @a_b@ both became @a_b@, and two ids
-- differing only after character 64 both became the same 64 characters
-- — two distinct calls in one turn collapsing onto one id, which
-- silently misroutes a tool result. Forty-eight bits of hash make a
-- collision among one conversation's calls negligible, and 'mapMessage'
-- turns a remaining collision into a clear error rather than a
-- misrouted result. Refusing non-conforming ids outright was rejected:
-- it would break replay of any conversation begun on a provider with a
-- different id alphabet.
normalizeToolCallId :: Text -> Text
normalizeToolCallId original
  | isValid original = original
  | otherwise = Text.take 51 (Text.map sanitise original) <> "_" <> suffix
  where
    isValid t = not (Text.null t) && Text.length t <= 64 && Text.all allowed t
    allowed c = (isAscii c && isAlphaNum c) || c == '_' || c == '-'
    sanitise c = if allowed c then c else '_'
    suffix =
      Text.take
        12
        (Text.decodeLatin1 (Base16.encode (SHA256.hash (Text.encodeUtf8 original))))

-- | Map one baikai message onto an SDK message, or say why it cannot
-- be sent, or say that it should not be sent at all.
--
-- Three outcomes rather than two, because Anthropic rejects both an
-- empty text block and an empty @content@ array, and baikai can produce
-- either from its own bookkeeping:
--
-- * @Right (Just msg)@ — the ordinary case.
--
-- * @Right Nothing@ — an /assistant/ turn left with no blocks after
--   empty text was dropped. That turn is baikai's own artifact: a text
--   block that opened and closed with no deltas, or a turn whose only
--   content was unsigned thinking, which replay already omits because
--   Anthropic rejects a thinking block without its signature. Dropping
--   it loses nothing the model said, and Anthropic merges the adjacent
--   user turns itself. A placeholder would fabricate content the model
--   never produced.
--
-- * @Left reason@ — a /user/ turn left with no blocks. That is a caller
--   error, not baikai's, so it is refused locally with a better message
--   than the provider's 400 and with the same
--   'Baikai.Error.InvalidRequest' category, which 'prepareCall' already
--   assigns. It is also refused when two @tool_use@ blocks in one
--   assistant turn normalise onto the same id, which would misroute the
--   tool result answering one of them.
mapMessage :: Msg.Message -> Either Text (Maybe Messages.Message)
mapMessage = \case
  Msg.UserMessage Msg.UserPayload {Msg.content = uc} ->
    case NonEmpty.nonEmpty (Vector.toList (Vector.mapMaybe userContentToBlock uc)) of
      Nothing -> Left "Anthropic Messages rejects a user turn with no content blocks; this one had none, or only empty text"
      Just blocks -> Right (Just (Messages.Message Messages.User blocks))
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
    let blocks = Vector.toList (Vector.mapMaybe assistantContentToBlock ac)
     in case duplicateToolUseId blocks of
          Just dup -> Left ("duplicate tool_use id after normalisation: " <> dup)
          Nothing -> Right (Messages.Message Messages.Assistant <$> NonEmpty.nonEmpty blocks)
  Msg.ToolResultMessage Msg.ToolResultPayload {Msg.toolCallId = tid, Msg.content = trc, Msg.isError = err} -> do
    body <- concatToolResultText trc
    let payload = if Text.null body then Messages.EmptyToolResult else Messages.ToolResultText body
        block = Messages.InputToolResult (Messages.ToolResult (normalizeToolCallId tid) payload (Just err) Nothing)
    Right (Just (Messages.Message Messages.User (block :| [])))

-- | IDs have already been normalised, so this also catches collisions.
duplicateToolUseId :: [Messages.InputBlock] -> Maybe Text
duplicateToolUseId = go []
  where
    go _ [] = Nothing
    go seen (Messages.InputToolUse i _ _ _ : rest)
      | i `elem` seen = Just i
      | otherwise = go (i : seen) rest
    go seen (_ : rest) = go seen rest

userContentToBlock :: Content.UserContent -> Maybe Messages.InputBlock
userContentToBlock = \case
  Content.UserText (Content.TextContent t)
    | Text.null t -> Nothing
    | otherwise -> Just (Messages.InputText t)
  Content.UserData v -> userContentToBlock (Content.UserText (Content.TextContent (Content.canonicalDataText v)))
  Content.UserImage img ->
    Just (Messages.InputImage (Messages.Base64Image (Content.mimeType img) (Text.decodeUtf8 (Base64.encode (Content.imageData img)))))

assistantContentToBlock :: Content.AssistantContent -> Maybe Messages.InputBlock
assistantContentToBlock = \case
  Content.AssistantText (Content.TextContent t)
    | Text.null t -> Nothing
    | otherwise -> Just (Messages.InputText t)
  Content.AssistantThinking th
    | Content.redacted th ->
        Just (reasoning "redacted_thinking" ["data" .= Content.thinking th])
    | otherwise ->
        (\sig -> reasoning "thinking" ["thinking" .= Content.thinking th, "signature" .= sig]) <$> Content.signature th
  Content.AssistantData _ -> Nothing
  Content.AssistantToolCall tc ->
    Just (Messages.InputToolUse (normalizeToolCallId (Content.id_ tc)) (Content.name tc) (Content.arguments tc) Nothing)
  where
    reasoning tag fields = Messages.VersionedBlock (KeyMap.fromList (("type" .= (tag :: Text)) : fields))

concatToolResultText :: Vector Content.ToolResultContent -> Either Text Text
concatToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "Anthropic Messages cannot encode ToolResultImage blocks in tool-result messages"

-- | One capability gate shared by wire mapping, headers and the describer.
planSpeed :: AnthropicMessagesCompat -> Maybe Speed -> (Maybe Messages.Speed, [ThinkingAdjustment])
planSpeed compat = \case
  Nothing -> (Nothing, [])
  Just SpeedStandard -> (Just Messages.Standard, [])
  Just SpeedFast
    | compat ^. #supportsFastMode -> (Just Messages.Fast, [])
    | otherwise -> (Nothing, [FastModeDroppedUnsupportedModel])
