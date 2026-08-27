{-# LANGUAGE LambdaCase #-}

-- | Building a 'ModelCallEvidence' from what every transport already
-- knows.
--
-- "Baikai.Evidence" is the vocabulary and is deliberately free of any
-- dependency on 'Model' or 'Options'. This module is the bridge: it
-- reads the caller's request out of 'Options', the endpoint out of
-- 'Model', and produces the record a provider adapter attaches to its
-- terminal stream event.
--
-- Four adapters call 'minimalEvidence' and a fifth path (dispatch that
-- found no registered provider) calls it too. Putting the construction
-- here rather than in each adapter keeps them from drifting, and — more
-- importantly — puts the caller's opt-out gate somewhere an adapter
-- cannot forget it.
module Baikai.Evidence.Build
  ( minimalEvidence,
    minimalEvidenceAt,
    prepareEvidence,
    prepareEvidenceAt,
    endpointIdentity,
    endpointIdentityAt,
    sanitizeEndpoint,
    dispatchEnvelope,
    requestedTranslation,
    transportForModel,
    baikaiPackageVersion,

    -- * Trace-sink failure policy
    onSinkFailure,
    sinkFailureIsFatal,
    sinkFailureError,

    -- * Strict mode
    strictnessOf,
    missingEvidenceError,

    -- * The pre-dispatch strictness gate
    EvidenceRefusal (..),
    renderEvidenceRefusal,
    checkEvidenceRequirements,
    refusalError,
  )
where

import Baikai.Api (Api (..), renderApi)
import Baikai.Error (BaikaiError, invalidRequest, providerError)
import Baikai.Evidence
  ( CallStatus,
    EndpointIdentity (..),
    EvidenceStrength,
    EvidenceStrictness (..),
    ModelCallEvidence (..),
    ThinkingAdjustment (..),
    ThinkingTranslation (..),
    TransportKind (..),
    baseEvidence,
    commitmentDigest,
    configurationDigest,
    declaredStrength,
    newCallId,
    renderEvidenceStrength,
    untranslatedThinking,
    weakensThinking,
  )
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
import Baikai.ThinkingLevel (renderThinkingLevel)
import Baikai.Url qualified as Url
import Control.Exception (SomeException, displayException)
import Data.Aeson qualified as Aeson
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Version (showVersion)
import Paths_baikai qualified as Paths
import System.IO (hPutStrLn, stderr)

-- | The version of the @baikai@ package that produced an evidence
-- record, read from the cabal-generated @Paths_baikai@ module.
--
-- Read once, centrally, rather than hardcoded per adapter. Five
-- packages construct evidence, and a literal in each of them becomes a
-- lie the first time one is missed during a release.
baikaiPackageVersion :: Text
baikaiPackageVersion = Text.pack (showVersion Paths.version)

-- | Build the evidence every transport can produce without observing
-- anything: identity from the caller's
-- 'Baikai.Evidence.EvidenceRequest', endpoint from the 'Model', the
-- requested model id, the supplied translation, the timings, the
-- status, and the two request digests. Every observed field is
-- 'Baikai.Evidence.Unobserved' and the strength is
-- 'Baikai.Evidence.EvidenceRequestedOnly'.
--
-- Returns 'Nothing' when the caller set no @evidence@ field in
-- 'Options'. That is the opt-out path and it must stay genuinely free:
-- no digest is computed, no call identifier is generated, and the
-- @envelope@ argument is never forced. The gate lives here rather than
-- at each adapter's call site so that an adapter cannot forget it and a
-- transport added later inherits it.
--
-- A transport that learns more overwrites the observed fields and
-- raises the strength; it must never overwrite a requested field with
-- an observed one or the reverse.
minimalEvidence ::
  Model ->
  Options ->
  TransportKind ->
  ThinkingTranslation ->
  -- | The request envelope, used for the two digests. API providers
  -- pass the JSON body they are about to send; subprocess providers
  -- pass their argument vector rendered as a JSON array.
  --
  -- __Deliberately lazy, and deliberately without the bang every other
  -- field in this package carries.__ On the opt-out path this thunk is
  -- discarded unforced, so an adapter may pass an expression that costs
  -- something to evaluate without charging callers who opted out. The
  -- missing strictness annotation is load-bearing; a test in
  -- @baikai/test/TraceSpec.hs@ passes an envelope that throws when
  -- forced and asserts an opted-out call still succeeds, so adding a
  -- bang here fails the build rather than silently costing every caller
  -- two SHA-256 passes over every prompt.
  Aeson.Value ->
  -- | Started at.
  UTCTime ->
  -- | Ended at.
  UTCTime ->
  CallStatus ->
  -- | The normalized error, which must be 'Just' exactly when the
  -- status is not 'CallSucceeded'. 'ModelCallEvidence' keeps the status
  -- and the error as separate fields because that is the shape the JSON
  -- schema needs, and their correlation is stated in the record's own
  -- documentation rather than enforced by the type.
  Maybe BaikaiError ->
  IO (Maybe ModelCallEvidence)
minimalEvidence m opts =
  minimalEvidenceAt (m ^. #baseUrl) m opts

-- | 'minimalEvidence' against the base URL the adapter actually
-- resolved, rather than the possibly-empty one on the 'Model'.
--
-- Both API adapters substitute a vendor default for an empty
-- @baseUrl@ inside their own @prepareCall@, so the call goes to a
-- definite host while the model still says @""@ — and
-- 'sanitizeEndpoint' then recorded @null@ for a call whose destination
-- was perfectly well known. The core cannot know a vendor default, so
-- where no adapter ran @null@ remains the truthful answer and the
-- unsuffixed functions keep passing @m ^. #baseUrl@.
minimalEvidenceAt ::
  -- | The resolved base URL.
  Text ->
  Model ->
  Options ->
  TransportKind ->
  ThinkingTranslation ->
  -- | The request envelope. Lazy, for the reason 'minimalEvidence'
  -- documents at length.
  Aeson.Value ->
  UTCTime ->
  UTCTime ->
  CallStatus ->
  Maybe BaikaiError ->
  IO (Maybe ModelCallEvidence)
minimalEvidenceAt baseUrl m opts transport translation envelope started ended st err = do
  mk <- prepareEvidenceAt baseUrl m opts transport translation envelope started
  pure (fmap (\finish -> finish ended st err) mk)

-- | 'minimalEvidence' for a transport that learns its terminal
-- timestamp and status later than it learns everything else.
--
-- A streaming adapter has the request envelope in hand before the first
-- byte comes back and the outcome only at the last, and the parts of
-- its translator that see the terminal event are usually pure. This
-- does the 'IO' half once — the opt-out check and the call identifier —
-- and hands back a function the adapter applies at the terminal.
--
-- 'Nothing' is the opt-out path and carries the same guarantees
-- 'minimalEvidence' documents: no identifier is generated and the
-- envelope is never forced. Do not reach for this when the outcome is
-- already known; 'minimalEvidence' says the same thing with less
-- ceremony.
prepareEvidence ::
  Model ->
  Options ->
  TransportKind ->
  ThinkingTranslation ->
  -- | The request envelope. Lazy, for the reason 'minimalEvidence'
  -- documents at length.
  Aeson.Value ->
  -- | Started at.
  UTCTime ->
  IO (Maybe (UTCTime -> CallStatus -> Maybe BaikaiError -> ModelCallEvidence))
prepareEvidence m opts =
  prepareEvidenceAt (m ^. #baseUrl) m opts

-- | 'prepareEvidence' against the base URL the adapter actually
-- resolved. See 'minimalEvidenceAt'.
prepareEvidenceAt ::
  -- | The resolved base URL.
  Text ->
  Model ->
  Options ->
  TransportKind ->
  ThinkingTranslation ->
  -- | The request envelope. Lazy, for the reason 'minimalEvidence'
  -- documents at length.
  Aeson.Value ->
  -- | Started at.
  UTCTime ->
  IO (Maybe (UTCTime -> CallStatus -> Maybe BaikaiError -> ModelCallEvidence))
prepareEvidenceAt baseUrl m opts transport translation envelope started =
  case opts ^. #evidence of
    Nothing -> pure Nothing
    Just req -> do
      cid <- newCallId
      let ep = endpointIdentityAt baseUrl m transport
          commitment = commitmentDigest envelope
          configuration = configurationDigest envelope
      pure $
        Just $ \ended st err ->
          ( baseEvidence
              req
              cid
              ep
              (m ^. #modelId)
              translation
              started
              ended
              st
              commitment
              configuration
          )
            { errorInfo = err
            }

-- | The strictness a call was dispatched under. A call with no
-- evidence request is best-effort.
strictnessOf :: Options -> EvidenceStrictness
strictnessOf opts =
  maybe EvidenceBestEffort (^. #strictness) (opts ^. #evidence)

-- | The error a strict call fails with when its provider produced a
-- successful terminal and attached no evidence record to it.
--
-- Built with 'providerError' for the reason 'sinkFailureError' is:
-- nothing about the request was invalid and the provider did its job,
-- and 'Baikai.Error.ErrorCategory' is closed. The message prefix is the
-- contract until the surface freeze decides on a category.
missingEvidenceError :: BaikaiError
missingEvidenceError =
  providerError
    "this call required evidence, but the provider attached no evidence record to its \
    \terminal event; the response is reported failed rather than left unaccounted for"

-- | The translation to record where no provider adapter ran: an
-- unregistered provider, and a @complete@ handler that threw before
-- returning.
--
-- It carries the caller's level and says @not_translated@, so the
-- record states the request without claiming a wire shape that was
-- never built. Where an adapter /did/ run — the consumer-abort path in
-- "Baikai.Trace", and each adapter's own @immediateError@ — call that
-- adapter's @describeThinking@ instead; re-deriving a description in
-- the core is what
-- @docs\/adr\/0003-the-adapter-owns-the-translation-description.md@
-- forbids.
requestedTranslation :: Options -> ThinkingTranslation
requestedTranslation opts = untranslatedThinking (opts ^. #thinking)

-- | Where a call went, without recording a credential.
--
-- 'implementationVersion' is left 'Nothing' here. An API provider knows
-- its vendor package version and a subprocess provider can probe its
-- executable, but neither fact is available to the core, and inventing
-- one would be worse than admitting the gap.
endpointIdentity :: Model -> TransportKind -> EndpointIdentity
endpointIdentity m = endpointIdentityAt (m ^. #baseUrl) m

-- | 'endpointIdentity' against the base URL the adapter actually
-- resolved. See 'minimalEvidenceAt'.
endpointIdentityAt :: Text -> Model -> TransportKind -> EndpointIdentity
endpointIdentityAt baseUrl m transport =
  EndpointIdentity
    { provider = m ^. #provider,
      api = renderApi (m ^. #api),
      transport = transport,
      endpoint = sanitizeEndpoint baseUrl,
      baikaiVersion = baikaiPackageVersion,
      implementationVersion = Nothing
    }

-- | Reduce a base URL to scheme, host, port, and path.
--
-- This is "Baikai.Url" applied to the recording problem: 'Url.parseUrl'
-- never holds the userinfo, the query string or the fragment in the
-- first place, and 'Url.renderEndpoint' can only put back what it has.
-- The query string is therefore dropped __wholesale__ rather than
-- filtered field by field, which is the right behaviour rather than a
-- convenient one: some gateways carry an API key in a query parameter,
-- and an allow-list of safe parameter names would be wrong the first
-- time a host invented one. Userinfo
-- (@https:\/\/user:secret\@host\/@) goes for the same reason; a
-- fragment cannot carry a credential to a server but is never part of
-- what was requested either.
--
-- The scheme and host come back lower-cased, because that is what
-- "Baikai.Url" says a host is; the path is kept verbatim.
--
-- An empty base URL yields 'Nothing' rather than an empty string, so a
-- reader can tell "baikai recorded no endpoint" from "the endpoint was
-- the empty string".
sanitizeEndpoint :: Text -> Maybe Text
sanitizeEndpoint = fmap Url.renderEndpoint . Url.parseUrl

-- | The request envelope for the paths where __no provider adapter ran
-- to completion__, and therefore no wire request body exists for this
-- process to digest.
--
-- There are three such paths: dispatch that found no registered handler
-- (@Baikai.Stream.streamRequestWith@ and
-- @Baikai.Provider.Registry.completeRequestWith@), a synchronous
-- handler that threw before returning a response
-- (@Baikai.Stream.liftCompleteToStream@), and a consumer that abandoned
-- the event stream before the terminal event
-- (@Baikai.Trace@'s finalizer).
--
-- What this commits to is baikai's own dispatch parameters, not a
-- provider request body. That distinction matters and the failure mode
-- is deliberately the safe one: a verifier who independently holds the
-- prompt recomputes a different value and concludes the record does not
-- describe their request, which is a false negative. The unsafe
-- direction — a digest that appears to bind a run to an artifact it
-- never saw — cannot arise. On the no-handler paths there is no
-- reduction at all, because no wire body ever existed.
--
-- Both keys are in the configuration allow-list
-- 'Baikai.Evidence.configurationProjection' recognises, so the
-- configuration digest over this envelope is meaningful rather than
-- degenerate.
dispatchEnvelope :: Model -> Options -> Aeson.Value
dispatchEnvelope m opts =
  Aeson.object
    [ "model" Aeson..= (m ^. #modelId),
      "max_tokens" Aeson..= fromMaybe (m ^. #maxOutputTokens) (opts ^. #maxTokens)
    ]

-- | The transport a model's 'Api' tag implies.
--
-- Only for the adapter-less paths above, where no implementation is
-- available to state its own transport. A real adapter passes the kind
-- it knows it used rather than calling this.
transportForModel :: Model -> TransportKind
transportForModel m = case m ^. #api of
  AnthropicMessagesCli -> TransportSubprocess
  OpenAICompletionsCli -> TransportSubprocess
  _ -> TransportHttpApi

-- ============================================================
-- The pre-dispatch strictness gate
-- ============================================================

-- | Why a strict call was refused before anything was sent.
data EvidenceRefusal
  = -- | The transport's declared maximum is below what the caller
    -- required. Carries the required strength, then the declared one.
    StrengthUnreachable !EvidenceStrength !EvidenceStrength
  | -- | The request would reach the wire expressing less than the caller
    -- asked for. Carries every adjustment that would apply.
    ThinkingWouldDowngrade ![ThinkingAdjustment]
  deriving stock (Eq, Show, Generic)

-- | An explanation an operator can act on. Every refusal names both the
-- thing that was required and the thing that is actually available,
-- because a refusal that says only "no" is a dead end.
renderEvidenceRefusal :: EvidenceRefusal -> Text
renderEvidenceRefusal = \case
  StrengthUnreachable needed declared ->
    "this transport can reach at most "
      <> renderEvidenceStrength declared
      <> " evidence, and the call required "
      <> renderEvidenceStrength needed
  ThinkingWouldDowngrade adjustments ->
    "the reasoning-effort request would not reach the provider as asked: "
      <> Text.intercalate "; " (map describeAdjustment adjustments)

-- | One adjustment, in words. Six of these are places baikai weakens a
-- thinking request, and the whole point of strict mode is that a caller
-- can refuse each of them by name rather than discovering it in a trace
-- afterwards. The two sampling entries are rendered here as well, so a
-- record printed for a human reads completely, even though
-- 'Baikai.Evidence.weakensThinking' keeps them out of the refusal
-- list.
describeAdjustment :: ThinkingAdjustment -> Text
describeAdjustment = \case
  EffortClamped lvl wire ->
    renderThinkingLevel lvl <> " would be sent as " <> wire
  EffortCollapsedToToggle lvl ->
    renderThinkingLevel lvl
      <> " would become a bare on/off toggle, so this host cannot tell it from any other level"
  EffortOmitted lvl ->
    renderThinkingLevel lvl
      <> " would send no effort field at all, so the request is indistinguishable on the wire \
         \from the provider's own default"
  ThinkingDroppedUnsupportedModel lvl ->
    renderThinkingLevel lvl
      <> " would be dropped entirely, because this model does not advertise reasoning support"
  ThinkingDroppedUnsupportedHost lvl ->
    renderThinkingLevel lvl
      <> " would be dropped entirely, because this host exposes no reasoning controls"
  ThinkingDroppedBudgetExceeded lvl budget maxOut ->
    renderThinkingLevel lvl
      <> " would be dropped entirely, because its "
      <> Text.pack (show budget)
      <> "-token budget does not fit inside the resolved output ceiling of "
      <> Text.pack (show maxOut)
  SamplingDroppedUnsupportedModel fields ->
    Text.intercalate ", " fields
      <> " would be dropped, because this model generation rejects sampling parameters"
  SamplingDroppedUnsupportedApi fields ->
    Text.intercalate ", " fields
      <> " would be dropped, because this API has no such field on any generation"

-- | The pre-dispatch gate: every reason this call must not proceed, or
-- an empty list when it may.
--
-- Every reason rather than the first, matching what
-- 'Baikai.Agent.applyAgentCeiling' already does for policy violations
-- and for the same reason: an operator fixing a configuration should see
-- all of it in one run rather than one thing per attempt.
--
-- __The translation argument is deliberately lazy and deliberately
-- carries no bang.__ Under 'EvidenceBestEffort' — which is every caller
-- who has not opted into strictness — this returns @[]@ without touching
-- it, so a provider's translation function is never run for them. That
-- matters because computing a translation means a host-compatibility
-- lookup and a model-capability check on every dispatch, for a feature
-- only strict callers use. A test in @baikai/test/StrictEvidenceSpec.hs@
-- passes a translation that throws when forced and asserts a best-effort
-- call still succeeds, so adding a bang here fails the build rather than
-- silently costing every caller.
--
-- The downgrade rule needs one judgement stated, because it is not
-- obvious. A caller who requested no level at all is never downgraded —
-- there is nothing to weaken, and 'Baikai.Evidence.noThinkingRequested'
-- carries no adjustments, so this falls out. But every adjustment that
-- weakens the thinking request refuses, including
-- 'Baikai.Evidence.EffortOmitted', which is the subtlest: that request
-- is not weaker in effect, it is merely indistinguishable on the wire
-- from the provider's default. A caller who demanded strict evidence and
-- receives a request they cannot later prove asked for @high@ has not
-- got what they demanded.
--
-- The adjustment list is filtered through
-- 'Baikai.Evidence.weakensThinking' rather than tested for emptiness,
-- because it also carries the sampling drops. The documented contract is
-- refusing a call that would /weaken the requested thinking level/; a
-- caller who set @seed@ on a Claude model, where the API has no such
-- field on any generation, must not have every strict call refused over
-- it. The drop is still in the record, where they can see it.
checkEvidenceRequirements ::
  EvidenceStrictness ->
  -- | The provider's own ceiling
  -- ('Baikai.Provider.Registry.strengthCeiling'), not a value looked up
  -- by 'Baikai.Api.Api': only the provider knows what its evidence can
  -- reach, and a tag-keyed table capped every caller-supplied transport
  -- at 'EvidenceRequestedOnly'.
  EvidenceStrength ->
  ThinkingTranslation ->
  [EvidenceRefusal]
checkEvidenceRequirements EvidenceBestEffort _ _ = []
checkEvidenceRequirements (EvidenceRequired needed) declared translation =
  [StrengthUnreachable needed declared | declared < needed]
    <> [ThinkingWouldDowngrade downgrades | not (null downgrades)]
  where
    downgrades = filter weakensThinking (adjustments translation)

-- | Turn a non-empty refusal list into the error the call fails with.
--
-- 'invalidRequest' rather than a provider error, because nothing reached
-- a provider: the call is refused on the caller's own terms, and a
-- retry-classifying consumer must not treat it as transient.
refusalError :: [EvidenceRefusal] -> BaikaiError
refusalError refusals =
  invalidRequest
    ( "strict evidence refused this call before dispatch: "
        <> Text.intercalate "; " (map renderEvidenceRefusal refusals)
    )

-- | Report a trace-sink failure on stderr.
--
-- Always, under either strictness. A strict caller /additionally/ has
-- their call failed — see 'sinkFailureIsFatal' — but they should still
-- see the operator-facing line, because the two audiences are different:
-- the message is for whoever is watching the process, and the failed
-- call is for the program.
onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
onSinkFailure _ e =
  hPutStrLn
    stderr
    ( "baikai: trace sink failed; trace events for this call were dropped: "
        <> displayException e
    )

-- | Whether a trace-sink failure must fail the call.
--
-- Under 'EvidenceBestEffort' it must not: reporting once on stderr and
-- letting the call succeed is baikai's long-standing behaviour and is
-- what every caller who has not opted into evidence gets.
--
-- Under 'EvidenceRequired' it must. A strict caller asked for a record
-- of this call and the record did not survive; the call succeeding
-- anyway would hand them an answer they cannot account for, and they
-- would have no way to notice. __Evidence that can vanish without the
-- caller noticing is not evidence__, which is the whole reason the mode
-- exists. This is the one place in baikai where a call that reached the
-- provider and came back is nevertheless reported as failed, and it is
-- deliberate.
sinkFailureIsFatal :: EvidenceStrictness -> Bool
sinkFailureIsFatal = \case
  EvidenceBestEffort -> False
  EvidenceRequired _ -> True

-- | The error a strict call fails with when its trace sink failed.
--
-- 'invalidRequest' would be wrong — nothing about the request was
-- invalid — and no provider category fits either, because the provider
-- did its job. It is baikai's own machinery that failed the caller, so
-- it is a plain provider-side error naming the sink and carrying the
-- sink's own message.
sinkFailureError :: SomeException -> BaikaiError
sinkFailureError e =
  providerError
    ( "the trace sink failed and this call required evidence, so its record was \
      \not written: "
        <> Text.pack (displayException e)
    )
