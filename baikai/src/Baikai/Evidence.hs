{-# LANGUAGE LambdaCase #-}

-- | Verifiable evidence about one completed model call.
--
-- A trace event answers "what did this call cost?". This module
-- answers a different and harder question: "what actually crossed the
-- boundary between this process and the provider, and how much of that
-- can be corroborated?".
--
-- Three things are kept strictly apart and are never collapsed into
-- one another:
--
-- * what the caller __requested__ — the model id and the
--   'Baikai.ThinkingLevel.ThinkingLevel' they asked for;
--
-- * what Baikai __translated__ that into for one specific provider —
--   the effort word, token budget, and wire field actually sent, plus
--   every clamp, collapse, or drop applied on the way, recorded in
--   'ThinkingTranslation';
--
-- * what the provider was __observed__ to report back — recorded in
--   'Observed', where a field the provider stayed silent about is
--   'Unobserved' and is never backfilled from the request.
--
-- Nothing in this module reaches a provider or performs a call. It is
-- the vocabulary the provider adapters populate.
module Baikai.Evidence
  ( -- * Observation
    Observed (..),
    observedValue,

    -- * Reasoning-effort translation
    ThinkingTranslation (..),
    ThinkingMode (..),
    ThinkingAdjustment (..),
    noThinkingRequested,

    -- * Endpoint and transport
    EndpointIdentity (..),
    TransportKind (..),

    -- * Outcome and strength
    CallStatus (..),
    EvidenceStrength (..),

    -- * The caller's request
    EvidenceRequest (..),
    EvidenceStrictness (..),
    evidenceRequest,
  )
where

import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Data.Aeson
  ( FromJSON (parseJSON),
    Options (fieldLabelModifier),
    ToJSON (toJSON),
    Value (Object, String),
    camelTo2,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    object,
    withText,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (typeMismatch)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- ============================================================
-- Observation
-- ============================================================

-- | A value the provider either did or did not report back.
--
-- This is deliberately not 'Maybe'. A 'Maybe' invites
-- @fromMaybe requested observed@, which is precisely the error this
-- type exists to prevent: a field the provider never reported must
-- never be filled in from what was requested. There is intentionally
-- no function here that supplies a default, no 'Monoid' instance, and
-- no @fromObserved@.
data Observed a
  = -- | The provider reported this value.
    Observed !a
  | -- | The provider did not report this value, or the transport
    -- cannot carry it. This is a positive statement about the
    -- provider's silence, not a missing field.
    Unobserved
  deriving stock (Eq, Show, Generic, Functor)

-- | @Observed x@ encodes as @{"observed": x}@ and 'Unobserved' as the
-- bare JSON string @"unobserved"@. Downstream consumers pattern-match
-- on that literal, so the shape is part of the schema and must not be
-- replaced with a generically derived encoding.
instance (ToJSON a) => ToJSON (Observed a) where
  toJSON = \case
    Observed a -> object ["observed" .= a]
    Unobserved -> String "unobserved"

instance (FromJSON a) => FromJSON (Observed a) where
  parseJSON = \case
    String "unobserved" -> pure Unobserved
    Object o -> Observed <$> o .: "observed"
    v -> typeMismatch "Observed" v

-- | Branch on whether the provider reported a value.
--
-- Use this to /report/ what was observed, never to /supply a default/
-- for it: @fromMaybe requestedModel (observedValue observedModel)@
-- defeats the entire purpose of this type and produces a record that
-- claims the provider corroborated something it never mentioned.
observedValue :: Observed a -> Maybe a
observedValue = \case
  Observed a -> Just a
  Unobserved -> Nothing

-- ============================================================
-- Reasoning-effort translation
-- ============================================================

-- | Which shape a provider's thinking configuration took on the wire.
--
-- Encodes as a lowercase string: @budget@, @adaptive@, @flag@,
-- @toggle@, @unsupported@, @absent@.
data ThinkingMode
  = -- | The provider took an explicit token budget.
    ThinkingModeBudget
  | -- | The provider chose its own depth, steered by an effort word.
    ThinkingModeAdaptive
  | -- | The preference travelled as a command-line flag.
    ThinkingModeFlag
  | -- | The provider accepted a bare on/off toggle with no depth.
    ThinkingModeToggle
  | -- | The caller requested a level and this transport cannot express
    -- any part of it.
    ThinkingModeUnsupported
  | -- | The caller requested no level at all.
    ThinkingModeAbsent
  deriving stock (Eq, Show, Generic)

renderThinkingMode :: ThinkingMode -> Text
renderThinkingMode = \case
  ThinkingModeBudget -> "budget"
  ThinkingModeAdaptive -> "adaptive"
  ThinkingModeFlag -> "flag"
  ThinkingModeToggle -> "toggle"
  ThinkingModeUnsupported -> "unsupported"
  ThinkingModeAbsent -> "absent"

parseThinkingMode :: Text -> Maybe ThinkingMode
parseThinkingMode = \case
  "budget" -> Just ThinkingModeBudget
  "adaptive" -> Just ThinkingModeAdaptive
  "flag" -> Just ThinkingModeFlag
  "toggle" -> Just ThinkingModeToggle
  "unsupported" -> Just ThinkingModeUnsupported
  "absent" -> Just ThinkingModeAbsent
  _ -> Nothing

instance ToJSON ThinkingMode where
  toJSON = String . renderThinkingMode

instance FromJSON ThinkingMode where
  parseJSON =
    withText "ThinkingMode" $ \t ->
      maybe (fail ("unknown thinking mode: " <> show t)) pure (parseThinkingMode t)

-- | One thing that happened to the caller's reasoning-effort request
-- between the canonical 'ThinkingLevel' and the wire.
--
-- This is the type that makes an otherwise silent downgrade visible.
-- Every constructor corresponds to a real site in this repository
-- where a request is weakened, dropped, or made indistinguishable from
-- the provider's own default.
--
-- Levels are carried as 'ThinkingLevel' rather than text so that
-- strict evidence mode can compare them; they render through
-- 'Baikai.ThinkingLevel.renderThinkingLevel' in JSON.
data ThinkingAdjustment
  = -- | The requested level was replaced by a weaker one the transport
    -- accepts. Carries the requested level and the wire text sent.
    EffortClamped !ThinkingLevel !Text
  | -- | The transport expresses no depth, so the level only turned
    -- thinking on. Carries the requested level.
    EffortCollapsedToToggle !ThinkingLevel
  | -- | The transport sends no effort field for this level, so the
    -- request is indistinguishable on the wire from the provider's own
    -- default. Carries the requested level.
    EffortOmitted !ThinkingLevel
  | -- | The chosen model does not advertise reasoning support, so the
    -- thinking configuration was dropped entirely.
    ThinkingDroppedUnsupportedModel !ThinkingLevel
  | -- | The host exposes no reasoning controls at all, so the
    -- configuration was dropped.
    ThinkingDroppedUnsupportedHost !ThinkingLevel
  | -- | A computed thinking budget was discarded because it did not
    -- fit inside the resolved output-token ceiling. Carries the
    -- requested level, the budget that was computed, and the ceiling.
    ThinkingDroppedBudgetExceeded !ThinkingLevel !Natural !Natural
  deriving stock (Eq, Show, Generic)

-- | Adjustments encode as a tagged object whose @kind@ names the
-- constructor in snake_case and whose @requested@ field carries the
-- canonical level name.
instance ToJSON ThinkingAdjustment where
  toJSON = \case
    EffortClamped lvl wire ->
      tagged "effort_clamped" lvl ["wire" .= wire]
    EffortCollapsedToToggle lvl ->
      tagged "effort_collapsed_to_toggle" lvl []
    EffortOmitted lvl ->
      tagged "effort_omitted" lvl []
    ThinkingDroppedUnsupportedModel lvl ->
      tagged "thinking_dropped_unsupported_model" lvl []
    ThinkingDroppedUnsupportedHost lvl ->
      tagged "thinking_dropped_unsupported_host" lvl []
    ThinkingDroppedBudgetExceeded lvl budget maxOut ->
      tagged
        "thinking_dropped_budget_exceeded"
        lvl
        ["budget_tokens" .= budget, "max_tokens" .= maxOut]
    where
      tagged kind lvl extra =
        object
          ( ["kind" .= (kind :: Text), "requested" .= renderThinkingLevel lvl]
              <> extra
          )

instance FromJSON ThinkingAdjustment where
  parseJSON = \case
    Object o -> do
      kind <- o .: "kind"
      lvl <- o .: "requested" >>= parseThinkingLevelText
      case kind :: Text of
        "effort_clamped" -> EffortClamped lvl <$> o .: "wire"
        "effort_collapsed_to_toggle" -> pure (EffortCollapsedToToggle lvl)
        "effort_omitted" -> pure (EffortOmitted lvl)
        "thinking_dropped_unsupported_model" ->
          pure (ThinkingDroppedUnsupportedModel lvl)
        "thinking_dropped_unsupported_host" ->
          pure (ThinkingDroppedUnsupportedHost lvl)
        "thinking_dropped_budget_exceeded" ->
          ThinkingDroppedBudgetExceeded lvl <$> o .: "budget_tokens" <*> o .: "max_tokens"
        other -> fail ("unknown thinking adjustment: " <> show other)
    v -> typeMismatch "ThinkingAdjustment" v

-- | Parse a canonical level name as produced by
-- 'Baikai.ThinkingLevel.renderThinkingLevel'. The evidence schema
-- spells levels with those names rather than with the constructor
-- names that 'ThinkingLevel'\'s own derived instance uses, because a
-- reader of an evidence record should see the same vocabulary the
-- provider documentation uses.
parseThinkingLevelText :: (MonadFail m) => Text -> m ThinkingLevel
parseThinkingLevelText = \case
  "minimal" -> pure ThinkingMinimal
  "low" -> pure ThinkingLow
  "medium" -> pure ThinkingMedium
  "high" -> pure ThinkingHigh
  "xhigh" -> pure ThinkingXHigh
  "max" -> pure ThinkingMax
  other -> fail ("unknown thinking level: " <> show other)

-- | What a canonical 'ThinkingLevel' actually became on the wire for
-- one specific provider.
--
-- The provider adapter that built the request owns this value. No
-- downstream layer — trace sink, exporter, or reporting tool — may
-- re-derive it: doing so would mean reimplementing every provider's
-- translation and compatibility lookup, and would silently diverge the
-- first time a translation changed.
data ThinkingTranslation = ThinkingTranslation
  { -- | The level the caller asked for, if any.
    requested :: !(Maybe ThinkingLevel),
    mode :: !ThinkingMode,
    -- | The exact effort text placed on the wire, when the transport
    -- uses one.
    effortText :: !(Maybe Text),
    -- | The exact token budget placed on the wire, when the transport
    -- uses one.
    budgetTokens :: !(Maybe Natural),
    -- | The provider-specific field name the configuration travelled
    -- in, for example @"thinking"@, @"reasoning_effort"@, or
    -- @"--effort"@. 'Nothing' when nothing was sent.
    wireField :: !(Maybe Text),
    -- | Everything that happened to the request between the canonical
    -- level and the wire, in the order it was applied. Empty means the
    -- request was expressed exactly.
    adjustments :: ![ThinkingAdjustment]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ThinkingTranslation where
  toJSON t =
    object
      [ "requested" .= fmap renderThinkingLevel (requested t),
        "mode" .= mode t,
        "effort_text" .= effortText t,
        "budget_tokens" .= budgetTokens t,
        "wire_field" .= wireField t,
        "adjustments" .= adjustments t
      ]

instance FromJSON ThinkingTranslation where
  parseJSON = \case
    Object o -> do
      rawLevel <- o .:? "requested"
      lvl <- traverse parseThinkingLevelText rawLevel
      ThinkingTranslation lvl
        <$> o .: "mode"
        <*> o .:? "effort_text"
        <*> o .:? "budget_tokens"
        <*> o .:? "wire_field"
        <*> o .: "adjustments"
    v -> typeMismatch "ThinkingTranslation" v

-- | The translation for a call where the caller set no level at all.
-- Distinct from a call that asked for a level the transport could not
-- express, which is 'ThinkingModeUnsupported' with a non-empty
-- 'adjustments' list.
noThinkingRequested :: ThinkingTranslation
noThinkingRequested =
  ThinkingTranslation
    { requested = Nothing,
      mode = ThinkingModeAbsent,
      effortText = Nothing,
      budgetTokens = Nothing,
      wireField = Nothing,
      adjustments = []
    }

-- ============================================================
-- Endpoint and transport
-- ============================================================

-- | How the call physically reached the provider. The three kinds
-- differ fundamentally in how much they can corroborate: an HTTP call
-- can carry provider response headers, a subprocess can only report
-- what the executable chose to print, and an unattended agent run
-- reports only what its own result envelope contains.
--
-- Encodes as @http_api@, @subprocess@, or @agent_run@.
data TransportKind
  = TransportHttpApi
  | TransportSubprocess
  | TransportAgentRun
  deriving stock (Eq, Show, Generic)

renderTransportKind :: TransportKind -> Text
renderTransportKind = \case
  TransportHttpApi -> "http_api"
  TransportSubprocess -> "subprocess"
  TransportAgentRun -> "agent_run"

instance ToJSON TransportKind where
  toJSON = String . renderTransportKind

instance FromJSON TransportKind where
  parseJSON = withText "TransportKind" $ \case
    "http_api" -> pure TransportHttpApi
    "subprocess" -> pure TransportSubprocess
    "agent_run" -> pure TransportAgentRun
    other -> fail ("unknown transport kind: " <> show other)

-- | Where the call went, recorded without recording a credential.
data EndpointIdentity = EndpointIdentity
  { -- | The provider name as Baikai knows it, e.g. @"anthropic"@.
    provider :: !Text,
    -- | The wire protocol tag, rendered from 'Baikai.Api.Api'.
    api :: !Text,
    transport :: !TransportKind,
    -- | Scheme, host, port, and path with every query parameter and
    -- userinfo component removed. A query string can carry an API key
    -- on some gateways, so it is dropped wholesale rather than
    -- filtered field by field.
    endpoint :: !(Maybe Text),
    -- | The version of the @baikai@ package that produced this record.
    baikaiVersion :: !Text,
    -- | The provider implementation's own version, when it has one:
    -- the vendor package version for an API provider, or the
    -- executable's reported version for a subprocess.
    implementationVersion :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

evidenceJsonOptions :: Options
evidenceJsonOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance ToJSON EndpointIdentity where
  toJSON = genericToJSON evidenceJsonOptions

instance FromJSON EndpointIdentity where
  parseJSON = genericParseJSON evidenceJsonOptions

-- ============================================================
-- Outcome and strength
-- ============================================================

-- | The terminal outcome of a call. Encodes as @succeeded@, @failed@,
-- or @aborted@.
data CallStatus
  = CallSucceeded
  | CallFailed
  | -- | The consumer stopped reading before the provider finished.
    CallAborted
  deriving stock (Eq, Show, Generic)

renderCallStatus :: CallStatus -> Text
renderCallStatus = \case
  CallSucceeded -> "succeeded"
  CallFailed -> "failed"
  CallAborted -> "aborted"

instance ToJSON CallStatus where
  toJSON = String . renderCallStatus

instance FromJSON CallStatus where
  parseJSON = withText "CallStatus" $ \case
    "succeeded" -> pure CallSucceeded
    "failed" -> pure CallFailed
    "aborted" -> pure CallAborted
    other -> fail ("unknown call status: " <> show other)

-- | How much a given evidence record actually proves.
--
-- The constructors ascend, and the derived 'Ord' instance is what
-- strict evidence mode compares against a caller's stated requirement.
-- __Do not reorder them.__
--
-- Encodes as @requested_only@, @correlated@, @model_observed@, or
-- @fully_observed@.
data EvidenceStrength
  = -- | Baikai recorded what it requested and what it translated. The
    -- provider reported nothing back that corroborates it. A
    -- successful process exit does not raise a record to a higher
    -- strength.
    EvidenceRequestedOnly
  | -- | The provider returned a correlation identifier, so this call
    -- can be located in the provider's own records, but it did not
    -- report the model or the effort it used.
    EvidenceCorrelated
  | -- | The provider reported the model it ran, in addition to a
    -- correlation identifier.
    EvidenceModelObserved
  | -- | The provider reported both the model and its effective
    -- thinking configuration.
    EvidenceFullyObserved
  deriving stock (Eq, Ord, Show, Generic)

renderEvidenceStrength :: EvidenceStrength -> Text
renderEvidenceStrength = \case
  EvidenceRequestedOnly -> "requested_only"
  EvidenceCorrelated -> "correlated"
  EvidenceModelObserved -> "model_observed"
  EvidenceFullyObserved -> "fully_observed"

instance ToJSON EvidenceStrength where
  toJSON = String . renderEvidenceStrength

instance FromJSON EvidenceStrength where
  parseJSON = withText "EvidenceStrength" $ \case
    "requested_only" -> pure EvidenceRequestedOnly
    "correlated" -> pure EvidenceCorrelated
    "model_observed" -> pure EvidenceModelObserved
    "fully_observed" -> pure EvidenceFullyObserved
    other -> fail ("unknown evidence strength: " <> show other)

-- ============================================================
-- The caller's request
-- ============================================================

-- | Whether a caller merely wants evidence or requires it.
data EvidenceStrictness
  = -- | Record whatever this transport can supply. Never fails a call
    -- for evidence reasons. This is the behaviour every existing
    -- caller gets.
    EvidenceBestEffort
  | -- | Refuse, before dispatch, to run this call on a transport that
    -- cannot reach the required strength or that would weaken the
    -- requested thinking level.
    EvidenceRequired !EvidenceStrength
  deriving stock (Eq, Show, Generic)

-- | Encoded by hand rather than derived, because a generically derived
-- sum encoding for a constructor carrying a payload would put the
-- strength somewhere a reader has to guess at:
-- @{"mode":"best_effort"}@ and
-- @{"mode":"required","strength":"model_observed"}@.
instance ToJSON EvidenceStrictness where
  toJSON = \case
    EvidenceBestEffort -> object ["mode" .= ("best_effort" :: Text)]
    EvidenceRequired s ->
      object ["mode" .= ("required" :: Text), "strength" .= s]

instance FromJSON EvidenceStrictness where
  parseJSON = \case
    Object o -> do
      m <- o .: "mode"
      case m :: Text of
        "best_effort" -> pure EvidenceBestEffort
        "required" -> EvidenceRequired <$> o .: "strength"
        other -> fail ("unknown evidence strictness: " <> show other)
    v -> typeMismatch "EvidenceStrictness" v

-- | A caller's per-call request for evidence, set through
-- @Baikai.Options.evidence@. A call whose evidence field is 'Nothing'
-- behaves exactly as it did before this vocabulary existed: no digest
-- is computed, no call identifier is generated for evidence purposes,
-- and no evidence is emitted.
data EvidenceRequest = EvidenceRequest
  { -- | The caller's identifier for the logical unit of work this call
    -- belongs to. Baikai treats it as opaque text and never parses it.
    runId :: !Text,
    strictness :: !EvidenceStrictness,
    -- | Which attempt this is, when the caller is retrying. One-based.
    -- Baikai has no retry or fallback loop of its own, so this is
    -- provenance the caller supplies, not something Baikai observes.
    attempt :: !Natural,
    -- | The call id of the attempt this one supersedes, when the
    -- caller is retrying or falling back.
    supersedes :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EvidenceRequest where
  toJSON = genericToJSON evidenceJsonOptions

instance FromJSON EvidenceRequest where
  parseJSON = genericParseJSON evidenceJsonOptions

-- | Request best-effort evidence for a call belonging to the given
-- run: attempt one, superseding nothing.
evidenceRequest :: Text -> EvidenceRequest
evidenceRequest rid =
  EvidenceRequest
    { runId = rid,
      strictness = EvidenceBestEffort,
      attempt = 1,
      supersedes = Nothing
    }
