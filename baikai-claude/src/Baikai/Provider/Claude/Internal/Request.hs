{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal request mapping for the Anthropic Messages provider.
--
-- This module is exposed for provider tests and debugging but is not covered by PVP
-- compatibility guarantees. Import the public provider module for stable application code.
module Baikai.Provider.Claude.Internal.Request
  ( mapRequest,
    planRequest,
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
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel, thinkingTokenBudget)
import Baikai.Tool qualified as Tool
import Claude.V1.Messages qualified as Messages
import Claude.V1.Tool qualified as ClaudeTool
import Control.Lens ((%~), (&), (.~), (^.))
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Base64 qualified as Base64
import Data.Char (isAlphaNum, isAscii)
import Data.Generics.Labels ()
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

-- | The wire wants an absent field for "no stop sequences", and
-- 'Baikai.Options.stopSequences' says that with an empty list — the one
-- representation, where @Nothing@ and @Just []@ used to be two.
nonEmptyStops :: [Text] -> Maybe (Vector.Vector Text)
nonEmptyStops [] = Nothing
nonEmptyStops xs = Just (Vector.fromList xs)

-- | Map a baikai request onto the SDK's 'Messages.CreateMessage', and
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
  Model -> Context -> Options -> Either Text (Messages.CreateMessage, ThinkingTranslation)
mapRequest m ctx opts = do
  msgs <- catMaybes <$> traverse mapMessage (Vector.toList (ctx ^. #messages))
  let compat = anthropicMessagesCompatFor m
      cap = m ^. #maxOutputTokens
      baseTokens = resolveBaseTokens m opts
      clamp n = if cap == 0 then n else min n cap
      (plan, sampling, translation) = planRequest m opts
      maxTokensField_ = case budget plan of
        Just b -> clamp (baseTokens + b)
        Nothing -> clamp baseTokens
      cacheControlField = computeCacheControl compat (opts ^. #cacheRetention)
      toolsVec = ctx ^. #tools
      toolsField =
        if Vector.null toolsVec
          then Nothing
          else Just (Vector.map (mkAnthropicTool compat) toolsVec)
      toolChoiceField = case opts ^. #toolChoice of
        Just Tool.ToolChoiceNone -> Nothing
        Just tc -> Just (mkAnthropicToolChoice tc)
        Nothing -> Nothing
      outputConfigField = mergeEffort (effort plan) (fmap mkAnthropicOutputConfig (opts ^. #responseFormat))
  pure
    ( Messages._CreateMessage
        { Messages.model = m ^. #modelId,
          Messages.messages = Vector.fromList msgs,
          Messages.max_tokens = maxTokensField_,
          Messages.system = fmap Messages.SystemPromptText (ctx ^. #systemPrompt),
          Messages.temperature = sampling ^. #temperature,
          Messages.top_p = sampling ^. #topP,
          Messages.stop_sequences = nonEmptyStops (opts ^. #stopSequences),
          Messages.tools = toolsField,
          Messages.tool_choice = toolChoiceField,
          Messages.cache_control = cacheControlField,
          Messages.thinking = field plan,
          Messages.output_config = outputConfigField
        },
      translation
    )

-- | The sampling parameters that will reach the wire, after the compat
-- record's gate. 'Nothing' means the field is omitted — the SDK encodes
-- 'Messages.CreateMessage' with @omitNothingFields = True@, so a
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
  (plan, sampling, translation & #adjustments %~ (<> samplingAdjustments))
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

    gated = not (supportsSamplingParameters compat)
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
mergeEffort Nothing cfg = cfg
mergeEffort (Just e) Nothing = Just (Messages.effortConfig e)
mergeEffort (Just e) (Just cfg) = Just cfg {Messages.effort = Just e}

-- | Map a baikai 'ResponseFormat' onto the upstream Anthropic
-- 'Messages.OutputConfig'. 'JsonSchema' forwards the schema
-- verbatim via 'Messages.jsonSchemaConfig'. Anthropic's structured
-- outputs are always schema-enforcing, so the baikai 'strict' flag
-- has no wire analog and is dropped. 'JsonObject' (plain-JSON mode)
-- has no native Anthropic equivalent — 'output_config' requires a
-- schema — so it downgrades to a permissive @{"type":"object"}@
-- schema, which still forces the model to emit a JSON object.
mkAnthropicOutputConfig :: ResponseFormat -> Messages.OutputConfig
mkAnthropicOutputConfig = \case
  JsonSchema f -> Messages.jsonSchemaConfig f.schema
  JsonObject ->
    Messages.jsonSchemaConfig
      (Aeson.object ["type" .= ("object" :: Text)])

-- | Translate the call-time 'Baikai.CacheRetention' preference into
-- the Anthropic SDK's @cache_control@ shape.
--
-- 'CacheRetentionNone' (and 'Nothing') turn the field off entirely.
-- 'CacheRetentionShort' uses the ephemeral marker with no TTL (the
-- provider default). 'CacheRetentionLong' asks for the @"1h"@ TTL
-- when the host advertises 'supportsLongCacheRetention'; otherwise it
-- transparently downgrades to short retention.
computeCacheControl ::
  AnthropicMessagesCompat ->
  Maybe CacheRetention ->
  Maybe Messages.CacheControl
computeCacheControl _ Nothing = Nothing
computeCacheControl _ (Just CacheRetentionNone) = Nothing
computeCacheControl _ (Just CacheRetentionShort) =
  Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}
computeCacheControl compat (Just CacheRetentionLong)
  | supportsLongCacheRetention compat =
      Just
        Messages.CacheControl
          { Messages.type_ = "ephemeral",
            Messages.ttl = Just (Messages.CacheTTLDuration "1h")
          }
  | otherwise =
      Just Messages.CacheControl {Messages.type_ = "ephemeral", Messages.ttl = Nothing}

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
-- Returning only the first is what this provider used to do, and it is
-- why a caller could never tell an honoured request from a dropped one.
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
            adjustments = [ThinkingDroppedUnsupportedModel lvl]
          }
      )
  | thinkingStyle compat == AnthropicThinkingAdaptive =
      let e = adaptiveEffort lvl
       in ( ThinkingPlan
              { field = Just Messages.ThinkingAdaptive,
                effort = e,
                budget = Nothing
              },
            ThinkingTranslation
              { requested = Just lvl,
                mode = ThinkingModeAdaptive,
                effortText = e,
                budgetTokens = Nothing,
                wireField = Just "thinking",
                adjustments = adaptiveAdjustments lvl e
              }
          )
  | otherwise =
      let b = thinkingTokenBudget lvl
       in ( ThinkingPlan
              { field = Just Messages.ThinkingEnabled {Messages.budget_tokens = b},
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
                adjustments = []
              }
          )

adaptiveEffort :: ThinkingLevel -> Maybe Text
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing
  ThinkingXHigh -> Just "xhigh"
  ThinkingMax -> Just "max"

-- | What Anthropic's adaptive vocabulary did to the requested level.
--
-- Derived from what 'adaptiveEffort' actually produced rather than from
-- a second table beside it, so the two cannot drift. 'Nothing' means no
-- effort field is sent at all, which leaves the request
-- wire-indistinguishable from a caller who expressed no preference and
-- took Anthropic's own default depth. An effort word that differs from
-- the level's canonical name is a clamp onto the nearest word the
-- adaptive vocabulary has — Anthropic's has no @minimal@.
adaptiveAdjustments :: ThinkingLevel -> Maybe Text -> [ThinkingAdjustment]
adaptiveAdjustments lvl = \case
  Nothing -> [EffortOmitted lvl]
  Just wire
    | wire == renderThinkingLevel lvl -> []
    | otherwise -> [EffortClamped lvl wire]

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
mkAnthropicTool :: AnthropicMessagesCompat -> Tool.Tool -> ClaudeTool.ToolDefinition
mkAnthropicTool _compat t =
  ClaudeTool.inlineTool
    ( ClaudeTool.functionTool
        (Tool.name t)
        (Just (Tool.description t))
        (Tool.parameters t)
    )

-- | Map a baikai 'Tool.ToolChoice' into the upstream Anthropic
-- 'ClaudeTool.ToolChoice'. 'Tool.ToolChoiceNone' is handled by the
-- raw request shaper because the SDK lacks a @none@ constructor.
-- 'Tool.ToolChoiceRequired' maps to Anthropic's
-- @any@ which is the closest equivalent ("must call some tool").
mkAnthropicToolChoice :: Tool.ToolChoice -> ClaudeTool.ToolChoice
mkAnthropicToolChoice = \case
  Tool.ToolChoiceAuto -> ClaudeTool.ToolChoice_Auto
  Tool.ToolChoiceRequired -> ClaudeTool.ToolChoice_Any
  Tool.ToolChoiceSpecific n -> ClaudeTool.ToolChoice_Tool {ClaudeTool.name = n}
  -- Unreachable in typed requests: ToolChoiceNone is injected by the shaper.
  Tool.ToolChoiceNone -> ClaudeTool.ToolChoice_Auto

-- | Anthropic enforces @[a-zA-Z0-9_-]@ on tool-call ids and caps their
-- length at 64 characters. Callers may have used any naming convention,
-- so the provider boundary normalizes here whenever an id is
-- round-tripped back to Anthropic — both on assistant turn replay
-- ('Messages.Content_Tool_Use') and on tool-result messages
-- ('Messages.Content_Tool_Result').
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
    let blocks = Vector.mapMaybe userContentToBlock uc
     in if Vector.null blocks
          then
            Left
              "Anthropic Messages rejects a user turn with no content blocks; \
              \this one had none, or only empty text"
          else
            Right
              ( Just
                  Messages.Message
                    { Messages.role = Messages.User,
                      Messages.content = blocks,
                      Messages.cache_control = Nothing
                    }
              )
  Msg.AssistantMessage Msg.AssistantPayload {Msg.content = ac} ->
    let blocks = Vector.mapMaybe assistantContentToBlock ac
     in case duplicateToolUseId blocks of
          Just dup ->
            Left ("duplicate tool_use id after normalisation: " <> dup)
          Nothing
            | Vector.null blocks -> Right Nothing
            | otherwise ->
                Right
                  ( Just
                      Messages.Message
                        { Messages.role = Messages.Assistant,
                          Messages.content = blocks,
                          Messages.cache_control = Nothing
                        }
                  )
  Msg.ToolResultMessage
    Msg.ToolResultPayload
      { Msg.toolCallId = tid,
        Msg.content = trc,
        Msg.isError = err
      } ->
      case concatToolResultText trc of
        Left unsupported -> Left unsupported
        Right body ->
          Right
            ( Just
                Messages.Message
                  { Messages.role = Messages.User,
                    Messages.content =
                      Vector.singleton
                        Messages.Content_Tool_Result
                          { Messages.tool_use_id = normalizeToolCallId tid,
                            Messages.content = nonEmpty body,
                            Messages.is_error = Just err
                          },
                    Messages.cache_control = Nothing
                  }
            )

-- | The first @tool_use@ id that appears twice in one assistant turn,
-- if any. Ids are already normalised at this point, so this catches the
-- residual hash collision as well as a caller that reused an id.
duplicateToolUseId :: Vector Messages.Content -> Maybe Text
duplicateToolUseId = go [] . Vector.toList
  where
    go _ [] = Nothing
    go seen (Messages.Content_Tool_Use {Messages.id = i} : rest)
      | i `elem` seen = Just i
      | otherwise = go (i : seen) rest
    go seen (_ : rest) = go seen rest

-- | An empty text block is dropped: Anthropic rejects
-- @{"type":"text","text":""}@ outright, and an empty block carries
-- nothing the model or the caller said.
userContentToBlock :: Content.UserContent -> Maybe Messages.Content
userContentToBlock = \case
  Content.UserText (Content.TextContent t)
    | Text.null t -> Nothing
    | otherwise ->
        Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.UserImage img ->
    Just
      Messages.Content_Image
        { Messages.source =
            Messages.ImageSource
              { Messages.type_ = "base64",
                Messages.media_type = Content.mimeType img,
                Messages.data_ = Text.decodeUtf8 (Base64.encode (Content.imageData img))
              },
          Messages.cache_control = Nothing
        }

-- | As 'userContentToBlock' for empty text. Unsigned thinking is also
-- dropped, because Anthropic rejects a thinking block whose signature
-- is missing; a turn left with no blocks at all is then dropped
-- entirely by 'mapMessage'.
assistantContentToBlock :: Content.AssistantContent -> Maybe Messages.Content
assistantContentToBlock = \case
  Content.AssistantText (Content.TextContent t)
    | Text.null t -> Nothing
    | otherwise ->
        Just Messages.Content_Text {Messages.text = t, Messages.cache_control = Nothing}
  Content.AssistantThinking th ->
    if Content.redacted th
      then Just Messages.Content_Redacted_Thinking {Messages.data_ = Content.thinking th}
      else case Content.signature th of
        Just sig ->
          Just
            Messages.Content_Thinking
              { Messages.thinking = Content.thinking th,
                Messages.signature = sig
              }
        Nothing -> Nothing
  Content.AssistantToolCall tc ->
    Just
      Messages.Content_Tool_Use
        { Messages.id = normalizeToolCallId (Content.id_ tc),
          Messages.name = Content.name tc,
          Messages.input = Content.arguments tc,
          Messages.caller = Nothing
        }

concatToolResultText :: Vector Content.ToolResultContent -> Either Text Text
concatToolResultText =
  fmap (Text.concat . Vector.toList) . traverse oneBlock
  where
    oneBlock = \case
      Content.ToolResultText (Content.TextContent t) -> Right t
      Content.ToolResultImage _ ->
        Left "Anthropic Messages cannot encode ToolResultImage blocks in tool-result messages"

nonEmpty :: Text -> Maybe Text
nonEmpty t
  | Text.null t = Nothing
  | otherwise = Just t
