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
  ( -- * Schema identity
    evidenceSchemaVersion,

    -- * The evidence record
    ModelCallEvidence (..),
    baseEvidence,

    -- * Observation
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
    renderEvidenceStrength,
    declaredStrength,

    -- * The caller's request
    EvidenceRequest (..),
    EvidenceStrictness (..),
    evidenceRequest,

    -- * Canonical encoding and digests
    canonicalEncode,
    commitmentDigest,
    configurationDigest,
    configurationProjection,

    -- * Identifiers
    newCallId,
  )
where

import Baikai.Api (Api (..))
import Baikai.Error (BaikaiError)
import Baikai.ThinkingLevel (ThinkingLevel (..), renderThinkingLevel)
import Baikai.Usage (Usage)
import Control.Exception (SomeException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( FromJSON (parseJSON),
    Options (fieldLabelModifier, omitNothingFields),
    ToJSON (toJSON),
    Value (Array, Bool, Null, Number, Object, String),
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
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (typeMismatch)
import Data.Bits (Bits, shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Builder (Builder)
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (ord)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (intersperse)
import Data.Scientific (FPFormat (Fixed), Scientific)
import Data.Scientific qualified as Scientific
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (UTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.IO.Unsafe (unsafePerformIO)

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

-- | Field names render in snake_case, matching 'Baikai.Usage.Usage'
-- and 'Baikai.Error.BaikaiError', which are embedded verbatim in an
-- evidence record.
--
-- @omitNothingFields@ is 'False' and stated explicitly rather than
-- left to the default, because it is load-bearing here: an evidence
-- record must render an absent field as @null@ rather than dropping
-- it, so that a reader can tell "Baikai recorded nothing here" apart
-- from "this record predates the field". This is the opposite of the
-- choice @Baikai.Trace.Event@ makes for trace events, where dropping
-- absent fields keeps log lines small. The difference is deliberate;
-- do not harmonise them.
evidenceJsonOptions :: Options
evidenceJsonOptions =
  defaultOptions
    { fieldLabelModifier = camelTo2 '_',
      omitNothingFields = False
    }

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

-- | The canonical name a strength encodes as, also used in the refusal
-- messages strict mode produces.
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

-- | The highest strength a transport can reach when everything goes
-- well.
--
-- This is a static property of the transport, not a claim about any
-- particular call: a transport that declares 'EvidenceModelObserved'
-- still produces 'EvidenceRequestedOnly' for a call that failed before
-- the provider said anything. Strict evidence mode compares a caller's
-- requirement against this /before/ dispatch, which is the only point at
-- which refusing is still cheap.
--
-- __Declaring more than a transport can deliver is the one way to make
-- strict mode lie__, so every value below is justified by a test that
-- actually drives that transport to it. If you raise a declaration, add
-- the test first.
--
-- The values, and what proved them:
--
-- * 'AnthropicMessages' and 'OpenAIChatCompletions' reach
--   'EvidenceModelObserved'. Both echo the model they ran and both carry
--   a correlation header. Neither echoes the thinking configuration it
--   applied, so 'EvidenceFullyObserved' is unreachable on either — a
--   reasoning-token count corroborates output volume and says nothing
--   about which effort setting was in force. No transport in this
--   repository currently declares 'EvidenceFullyObserved'.
--
-- * 'AnthropicMessagesCli' reaches 'EvidenceModelObserved'. The @claude@
--   CLI names the model that consumed tokens in its result event's
--   @modelUsage@ map, alongside a session identifier.
--
-- * 'OpenAICompletionsCli' reaches only 'EvidenceCorrelated'.
--   @codex exec --json@ names a thread identifier but no model anywhere
--   in its event stream, and the model baikai passed on the command line
--   is the request rather than an observation.
--
-- * 'Custom' declares 'EvidenceRequestedOnly'. Baikai knows nothing
--   about a caller-supplied transport and must not assume on its behalf.
declaredStrength :: Api -> EvidenceStrength
declaredStrength = \case
  AnthropicMessages -> EvidenceModelObserved
  OpenAIChatCompletions -> EvidenceModelObserved
  AnthropicMessagesCli -> EvidenceModelObserved
  OpenAICompletionsCli -> EvidenceCorrelated
  Custom _ -> EvidenceRequestedOnly

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

-- ============================================================
-- The evidence record
-- ============================================================

-- | The schema identifier for 'ModelCallEvidence'. Consumers pin
-- against this string.
--
-- Bump the minor component when a field is added in a way that leaves
-- existing readers working; bump the major component when a field is
-- removed, changes meaning, or when 'canonicalEncode' changes, since
-- that invalidates every previously recorded digest.
evidenceSchemaVersion :: Text
evidenceSchemaVersion = "baikai.model-call-evidence/1.0"

-- | Everything Baikai can say about one completed provider call.
--
-- The field order is the story the record tells: who ran it, where it
-- went, what was asked, what came back, how it went, and what it costs
-- to believe.
data ModelCallEvidence = ModelCallEvidence
  { -- Identity -------------------------------------------------------

    -- | Always 'evidenceSchemaVersion' for records this build produces.
    schemaVersion :: !Text,
    -- | The caller's identifier for the logical unit of work.
    runId :: !Text,
    -- | This call's globally unique identifier, from 'newCallId'.
    callId :: !Text,
    -- | Which attempt this is, one-based, as supplied by the caller.
    attempt :: !Natural,
    -- | The 'callId' of the attempt this one supersedes, as supplied
    -- by the caller. Baikai has no retry loop and never fills this in
    -- itself.
    supersedes :: !(Maybe Text),
    -- Where it went --------------------------------------------------
    endpoint :: !EndpointIdentity,
    -- What was requested ---------------------------------------------

    -- | The model identifier the caller configured. This is what was
    -- /asked for/; see 'observedModel' for what the provider said it
    -- ran.
    requestedModel :: !Text,
    -- | What the caller's reasoning-effort preference became on the
    -- wire, including every downgrade applied on the way.
    thinking :: !ThinkingTranslation,
    -- What came back -------------------------------------------------

    -- | The model identifier the provider reported running.
    -- 'Unobserved' when the provider did not echo one or the transport
    -- cannot carry it. Never backfilled from 'requestedModel'.
    observedModel :: !(Observed Text),
    -- | The provider's own description of the thinking configuration
    -- it applied, when it reports one.
    --
    -- Reasoning-token counts do /not/ belong here. They live in
    -- 'usage', and they are corroborating evidence about output
    -- volume, not a statement of which effort setting was applied.
    observedThinking :: !(Observed Text),
    -- | The provider's identifier for this response.
    responseId :: !(Observed Text),
    -- | The provider's request-correlation identifier, typically from
    -- a response header, used to locate this call in the provider's
    -- own records.
    providerRequestId :: !(Observed Text),
    -- | The identifier Baikai put on the outgoing request, when it
    -- sent one. Unlike the two fields above this is something Baikai
    -- knows by construction rather than observes, so it is 'Maybe' and
    -- not 'Observed'.
    clientRequestId :: !(Maybe Text),
    -- How it went ----------------------------------------------------
    startedAt :: !UTCTime,
    endedAt :: !UTCTime,
    latencyMs :: !Int,
    status :: !CallStatus,
    -- | 'Nothing' exactly when 'status' is 'CallSucceeded'.
    errorInfo :: !(Maybe BaikaiError),
    -- | The token accounting the provider reported.
    --
    -- This is 'Observed' rather than a bare 'Baikai.Usage.Usage'
    -- because the existing code substitutes
    -- 'Baikai.Usage.zeroUsage' when a provider reports nothing. In a
    -- cost log that substitution is harmless; in evidence it is a
    -- false statement that the call consumed no tokens.
    usage :: !(Observed Usage),
    -- What it proves -------------------------------------------------

    -- | This record's honest self-assessment. Derived from which
    -- observed fields the transport actually filled in.
    strength :: !EvidenceStrength,
    -- | 'commitmentDigest' of the request envelope.
    requestCommitment :: !Text,
    -- | 'configurationDigest' of the request envelope.
    requestConfiguration :: !Text,
    -- | 'commitmentDigest' of the response envelope. 'Unobserved' when
    -- the call failed before any response body arrived: recording an
    -- empty-string digest there would be a fabrication.
    responseCommitment :: !(Observed Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Evidence is emitted as JSON and consumed out of process. There is
-- deliberately no 'FromJSON' instance: 'Baikai.Usage.Usage' embeds a
-- 'Baikai.Cost.Cost', whose exact 'Rational' amounts are encoded
-- through an approximating 'Data.Scientific.Scientific', so a decoder
-- could not round-trip a record faithfully and would be claiming a
-- fidelity it does not have. Read an emitted record as a plain
-- 'Data.Aeson.Value' and match on 'evidenceSchemaVersion'.
instance ToJSON ModelCallEvidence where
  toJSON = genericToJSON evidenceJsonOptions

-- | The evidence any transport can always produce: identity, endpoint,
-- requested model, thinking translation, timing, status, and the two
-- request digests.
--
-- Every observed field starts 'Unobserved', 'errorInfo' starts
-- 'Nothing', and 'strength' starts at 'EvidenceRequestedOnly'. A
-- transport that learns more overwrites those fields and raises the
-- strength. Construct through this rather than with the record
-- constructor, so that a field added in a later release cannot be left
-- uninitialised at a call site.
baseEvidence ::
  EvidenceRequest ->
  -- | Call id, from 'newCallId'.
  Text ->
  EndpointIdentity ->
  -- | Requested model id.
  Text ->
  ThinkingTranslation ->
  -- | Started at.
  UTCTime ->
  -- | Ended at.
  UTCTime ->
  CallStatus ->
  -- | Request commitment digest.
  Text ->
  -- | Request configuration digest.
  Text ->
  ModelCallEvidence
baseEvidence
  EvidenceRequest {runId = rid, attempt = att, supersedes = prev}
  cid
  ep
  reqModel
  translation
  started
  ended
  st
  commitment
  configuration =
    ModelCallEvidence
      { schemaVersion = evidenceSchemaVersion,
        runId = rid,
        callId = cid,
        attempt = att,
        supersedes = prev,
        endpoint = ep,
        requestedModel = reqModel,
        thinking = translation,
        observedModel = Unobserved,
        observedThinking = Unobserved,
        responseId = Unobserved,
        providerRequestId = Unobserved,
        clientRequestId = Nothing,
        startedAt = started,
        endedAt = ended,
        latencyMs = millisBetween started ended,
        status = st,
        errorInfo = Nothing,
        usage = Unobserved,
        strength = EvidenceRequestedOnly,
        requestCommitment = commitment,
        requestConfiguration = configuration,
        responseCommitment = Unobserved
      }

-- | Whole milliseconds between two instants, rounded. Matches the
-- latency arithmetic @Baikai.Trace@ already uses for @CallFinished@ so
-- the two records agree on the same call.
millisBetween :: UTCTime -> UTCTime -> Int
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))

-- ============================================================
-- Canonical encoding
-- ============================================================

-- | Encode a JSON value to bytes such that two equal values always
-- produce byte-identical output.
--
-- The rules, which a later maintainer must preserve:
--
-- * Object keys are emitted in ascending order by their UTF-8 byte
--   sequence, recursively. Aeson's @Object@ is a @KeyMap@ whose
--   iteration order is unspecified and in practice depends on
--   insertion history, so the order is imposed here rather than
--   inherited.
--
-- * Array order is preserved, because array order is semantically
--   meaningful.
--
-- * There is no insignificant whitespace: no space after a colon or a
--   comma, and no trailing newline.
--
-- * Strings are UTF-8 with the minimal escaping JSON requires:
--   @\\"@, @\\\\@, the five short control escapes, and @\\u@ followed
--   by four /lowercase/ hexadecimal digits for any other character
--   below @U+0020@. Nothing else is escaped. The escaper is written
--   out here rather than borrowed from aeson so that an aeson upgrade
--   cannot silently change a digest.
--
-- * Numbers are normalised before rendering, so @1@, @1.0@, @1.00@,
--   and @1e0@ all produce the bytes @1@. An integral value renders as
--   a plain integer with no decimal point and no exponent; anything
--   else renders fixed-point with no exponent.
--
-- Changing any of these rules invalidates every digest recorded by an
-- earlier build. Treat such a change as a major bump of
-- 'evidenceSchemaVersion', not as a bug fix.
canonicalEncode :: Value -> ByteString
canonicalEncode =
  LazyByteString.toStrict . Builder.toLazyByteString . buildCanonical

buildCanonical :: Value -> Builder
buildCanonical = \case
  Null -> Builder.byteString "null"
  Bool True -> Builder.byteString "true"
  Bool False -> Builder.byteString "false"
  Number n -> buildNumber n
  String t -> buildString t
  Array xs ->
    Builder.char7 '['
      <> mconcat (intersperse (Builder.char7 ',') (map buildCanonical (Vector.toList xs)))
      <> Builder.char7 ']'
  Object o ->
    Builder.char7 '{'
      <> mconcat (intersperse (Builder.char7 ',') (map member (KeyMap.toAscList o)))
      <> Builder.char7 '}'
  where
    member (k, v) = buildString (Key.toText k) <> Builder.char7 ':' <> buildCanonical v

-- | Render a number with exactly one spelling per mathematical value.
-- 'Scientific.normalize' strips trailing zeros from the coefficient
-- first, without which @1.1@ and @1.100@ — which aeson parses into
-- different 'Scientific' values — would encode to different bytes.
buildNumber :: Scientific -> Builder
buildNumber raw
  | Scientific.isInteger n = Builder.integerDec (truncate n)
  | otherwise = Builder.string7 (Scientific.formatScientific Fixed Nothing n)
  where
    n = Scientific.normalize raw

buildString :: Text -> Builder
buildString t =
  Builder.char7 '"' <> Text.foldr (\c acc -> escapeChar c <> acc) mempty t <> Builder.char7 '"'

escapeChar :: Char -> Builder
escapeChar = \case
  '"' -> Builder.byteString "\\\""
  '\\' -> Builder.byteString "\\\\"
  '\n' -> Builder.byteString "\\n"
  '\r' -> Builder.byteString "\\r"
  '\t' -> Builder.byteString "\\t"
  '\b' -> Builder.byteString "\\b"
  '\f' -> Builder.byteString "\\f"
  c
    | c < '\x20' -> Builder.byteString "\\u" <> hex4 (ord c)
    | otherwise -> Builder.charUtf8 c

hex4 :: Int -> Builder
hex4 n = mconcat [Builder.char7 (hexDigit (n `shiftR` s)) | s <- [12, 8, 4, 0]]

-- | The low nibble of a value as a lowercase hexadecimal character.
hexDigit :: (Integral a, Bits a) => a -> Char
hexDigit v = "0123456789abcdef" !! fromIntegral (v .&. 0xF)

-- | SHA-256 of the canonical encoding, rendered as 64 lowercase
-- hexadecimal characters and prefixed with the algorithm so the string
-- is self-describing: @"sha256:1b4f0e98…"@.
--
-- @Base16.encode@ emits lowercase ASCII, so decoding it as Latin-1 is
-- total and gives the same characters.
digestOf :: Value -> Text
digestOf v =
  "sha256:"
    <> TextEncoding.decodeLatin1 (Base16.encode (SHA256.hash (canonicalEncode v)))

-- ============================================================
-- The two digests
-- ============================================================

-- | A commitment to the exact request body Baikai sent, prompt content
-- included.
--
-- The digest reveals nothing on its own: publishing it does not
-- disclose the prompt. Anyone who independently holds the request can
-- recompute this value and confirm that a given evidence record
-- describes that request — which is what makes it possible to bind a
-- recorded call to a reviewed artifact.
--
-- Nothing is redacted here, because credentials travel in HTTP headers
-- and command-line environments, never in a request body, and headers
-- are not part of this function's input.
commitmentDigest :: Value -> Text
commitmentDigest = digestOf

-- | A digest over the request's configuration only, with all content
-- removed by 'configurationProjection'.
--
-- Two calls that ask the same model the same way about different
-- subjects produce the same value here. That is the point: this digest
-- is safe to compare across runs that legitimately differ in content.
-- It proves /how/ a call was configured and deliberately proves
-- nothing about /what/ was asked, so it must never be presented as
-- binding a run to any particular input. Use 'commitmentDigest' for
-- that.
configurationDigest :: Value -> Text
configurationDigest = digestOf . configurationProjection

-- | Reduce a request envelope to the configuration it expresses,
-- discarding everything that carries content.
--
-- This is an explicit __allow-list__, never a denylist, and the
-- distinction is not stylistic. A denylist over request bodies from
-- the Anthropic Messages API and seven different OpenAI-compatible
-- hosts will miss a field the first time any one of them adds one, and
-- the failure mode is prompt content leaking into a digest that
-- callers were told is content-free. An allow-list fails the other
-- way: a genuinely new configuration field is silently omitted from
-- the digest until someone adds it here, which loses fidelity rather
-- than leaking.
--
-- Keys outside the list are dropped entirely. Three keys are kept but
-- replaced with structural summaries: @messages@ becomes one object
-- per message carrying its role, its block count, and the total
-- character length of every string inside it; @system@ becomes just
-- that character count; @tools@ becomes each tool's name and nothing
-- else, so descriptions and JSON schemas do not survive.
--
-- A top-level value that is not an object has no named fields for the
-- allow-list to admit, so it projects to 'Null' rather than passing
-- through.
configurationProjection :: Value -> Value
configurationProjection = \case
  Object o -> Object (KeyMap.fromList (concatMap keep (KeyMap.toAscList o)))
  _ -> Null
  where
    keep (k, v) = case Key.toText k of
      "messages" -> [(k, summariseMessages v)]
      "system" -> [(k, charSummary v)]
      "tools" -> [(k, summariseTools v)]
      name
        | name `Set.member` configurationKeys -> [(k, v)]
        | otherwise -> []

-- | The request fields that describe how a call is configured rather
-- than what it says. Covers the Anthropic Messages API and the
-- OpenAI-compatible Chat Completions shapes this repository builds.
configurationKeys :: Set Text
configurationKeys =
  Set.fromList
    [ "cache_control",
      "enable_thinking",
      "frequency_penalty",
      "max_completion_tokens",
      "max_tokens",
      "model",
      "output_config",
      "presence_penalty",
      "reasoning",
      "reasoning_effort",
      "response_format",
      "seed",
      "stop_sequences",
      "stream",
      "temperature",
      "thinking",
      "tool_choice",
      "top_p"
    ]

summariseMessages :: Value -> Value
summariseMessages = \case
  Array xs -> Array (fmap summariseMessage xs)
  _ -> Null

summariseMessage :: Value -> Value
summariseMessage = \case
  Object m ->
    object
      [ "role" .= roleOf (KeyMap.lookup "role" m),
        "blocks" .= blockCount (KeyMap.lookup "content" m),
        "chars" .= maybe 0 totalStringChars (KeyMap.lookup "content" m)
      ]
  _ -> Null
  where
    roleOf = \case
      Just (String r) -> String r
      _ -> Null
    blockCount :: Maybe Value -> Int
    blockCount = \case
      Just (Array a) -> Vector.length a
      Just Null -> 0
      Nothing -> 0
      Just _ -> 1

-- | Total characters across every JSON string anywhere inside a value.
-- Recursive on purpose: a content block's text can sit at any depth,
-- and a count is a structural fact that reveals nothing about what was
-- written.
totalStringChars :: Value -> Int
totalStringChars = \case
  String t -> Text.length t
  Array xs -> sum (fmap totalStringChars xs)
  Object o -> sum (fmap totalStringChars (KeyMap.elems o))
  _ -> 0

charSummary :: Value -> Value
charSummary v = object ["chars" .= totalStringChars v]

-- | A tool reduces to its name. The name is configuration — which
-- capabilities the call offered — while the description and input
-- schema are author-written content. Both wire shapes are handled: the
-- Anthropic form with @name@ at the top level, and the OpenAI form
-- that nests it under @function@.
summariseTools :: Value -> Value
summariseTools = \case
  Array xs -> Array (fmap summariseTool xs)
  _ -> Null

summariseTool :: Value -> Value
summariseTool = \case
  Object t -> object ["name" .= nameOf t]
  _ -> Null
  where
    nameOf t = case KeyMap.lookup "name" t of
      Just n@(String _) -> n
      _ -> case KeyMap.lookup "function" t of
        Just (Object f) -> case KeyMap.lookup "name" f of
          Just n@(String _) -> n
          _ -> Null
        _ -> Null

-- ============================================================
-- Identifiers
-- ============================================================

-- | A globally unique call identifier: 32 lowercase hexadecimal
-- characters carrying 128 bits, laid out as 48 bits of Unix time in
-- milliseconds, then 48 bits of a per-process random seed drawn once
-- at first use, then a 32-bit process-local counter.
--
-- The time prefix comes first so that identifiers sort
-- chronologically. The seed is what distinguishes two processes; the
-- counter is what distinguishes two calls within one. The counter
-- wrapping after 2^32 calls is harmless, because the millisecond
-- prefix will have moved on long before.
--
-- This replaces the previous generator, which combined the process
-- start /second/ with a process-local counter and therefore produced
-- identical identifier sequences in two processes started within the
-- same second. For ordinary tracing that was a minor collision hazard;
-- for evidence that another system correlates into a run, it was a
-- correctness defect.
--
-- Generating an identifier costs one atomic counter increment and one
-- clock read, and performs no syscall for randomness. That matters
-- because this function sits on the trace path for every call whether
-- or not the caller asked for evidence, and a per-call read from the
-- system random source would charge people who never asked for one.
--
-- These identifiers are __not secrets__. They are not capabilities,
-- they are not unguessable, and they must not be used as one. Their
-- only job is to correlate records.
newCallId :: IO Text
newCallId = do
  n <- atomicModifyIORef' callIdCounter (\k -> (k + 1, k))
  now <- getPOSIXTime
  let millis = floor (now * 1000) :: Word64
      seed = callIdSeed .&. 0xFFFFFFFFFFFF
      high = ((millis .&. 0xFFFFFFFFFFFF) `shiftL` 16) .|. (seed `shiftR` 32)
      low = ((seed .&. 0xFFFFFFFF) `shiftL` 32) .|. (n .&. 0xFFFFFFFF)
  pure (hex16 high <> hex16 low)

hex16 :: Word64 -> Text
hex16 w = Text.pack [hexDigit (w `shiftR` s) | s <- [60, 56 .. 0]]

callIdCounter :: IORef Word64
callIdCounter = unsafePerformIO (newIORef 0)
{-# NOINLINE callIdCounter #-}

-- | Sixty-four bits drawn once from @\/dev\/urandom@, of which
-- 'newCallId' uses the low forty-eight.
--
-- Read with 'hGet' rather than @ByteString.readFile@: @readFile@ asks
-- for the file's size, gets zero for a character device, and then
-- reads until end of file — which @\/dev\/urandom@ never reaches.
--
-- If the read fails for any reason, the seed falls back to the current
-- time in nanoseconds. That is weaker — two processes starting within
-- the same nanosecond would share a seed — but it is still far
-- stronger than the per-second base this generator replaced, and it
-- keeps a failure to open a device file from taking down a library
-- that only wanted to name a call.
callIdSeed :: Word64
callIdSeed = unsafePerformIO $ do
  drawn <-
    try (withBinaryFile "/dev/urandom" ReadMode (\h -> ByteString.hGet h 8)) ::
      IO (Either SomeException ByteString)
  case drawn of
    Right bytes
      | ByteString.length bytes == 8 ->
          pure (ByteString.foldl' (\acc b -> (acc `shiftL` 8) .|. fromIntegral b) 0 bytes)
    _ -> do
      now <- getPOSIXTime
      pure (floor (now * 1000000000))
{-# NOINLINE callIdSeed #-}
