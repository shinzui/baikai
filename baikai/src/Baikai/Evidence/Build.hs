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
    prepareEvidence,
    endpointIdentity,
    sanitizeEndpoint,
    dispatchEnvelope,
    transportForModel,
    baikaiPackageVersion,
    onSinkFailure,
  )
where

import Baikai.Api (Api (..), renderApi)
import Baikai.Error (BaikaiError)
import Baikai.Evidence
  ( CallStatus,
    EndpointIdentity (..),
    EvidenceStrictness (..),
    ModelCallEvidence (..),
    ThinkingTranslation,
    TransportKind (..),
    baseEvidence,
    commitmentDigest,
    configurationDigest,
    newCallId,
  )
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Prelude
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
minimalEvidence m opts transport translation envelope started ended st err = do
  mk <- prepareEvidence m opts transport translation envelope started
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
prepareEvidence m opts transport translation envelope started =
  case opts ^. #evidence of
    Nothing -> pure Nothing
    Just req -> do
      cid <- newCallId
      let ep = endpointIdentity m transport
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

-- | Where a call went, without recording a credential.
--
-- 'implementationVersion' is left 'Nothing' here. An API provider knows
-- its vendor package version and a subprocess provider can probe its
-- executable, but neither fact is available to the core, and inventing
-- one would be worse than admitting the gap.
endpointIdentity :: Model -> TransportKind -> EndpointIdentity
endpointIdentity m transport =
  EndpointIdentity
    { provider = m ^. #provider,
      api = renderApi (m ^. #api),
      transport = transport,
      endpoint = sanitizeEndpoint (m ^. #baseUrl),
      baikaiVersion = baikaiPackageVersion,
      implementationVersion = Nothing
    }

-- | Reduce a base URL to scheme, host, port, and path.
--
-- The query string is dropped __wholesale__ rather than filtered field
-- by field, because some gateways carry an API key in a query
-- parameter and an allow-list of safe parameter names would be wrong
-- the first time a host invented one. Any @userinfo@ component
-- (@https:\/\/user:secret\@host\/@) is dropped for the same reason. A
-- fragment cannot carry a credential to a server but is dropped too,
-- since it is never part of what was requested.
--
-- An empty base URL yields 'Nothing' rather than an empty string, so a
-- reader can tell "baikai recorded no endpoint" from "the endpoint was
-- the empty string".
sanitizeEndpoint :: Text -> Maybe Text
sanitizeEndpoint raw
  | Text.null trimmed = Nothing
  | Text.null cleaned = Nothing
  | otherwise = Just cleaned
  where
    trimmed = Text.strip raw
    withoutFragment = Text.takeWhile (/= '#') trimmed
    withoutQuery = Text.takeWhile (/= '?') withoutFragment
    cleaned = dropUserInfo withoutQuery

-- | Drop a @user:password\@@ prefix from the authority component,
-- keeping the scheme. Splits on the last @\@@ before the first @\/@ of
-- the path so that an @\@@ later in the path is not mistaken for
-- userinfo.
dropUserInfo :: Text -> Text
dropUserInfo url =
  let (scheme, rest) = case Text.breakOn "://" url of
        (s, r) | not (Text.null r) -> (s <> "://", Text.drop 3 r)
        _ -> ("", url)
      (authority, path) = Text.break (== '/') rest
   in case Text.breakOnEnd "@" authority of
        (before, after) | not (Text.null before) -> scheme <> after <> path
        _ -> scheme <> authority <> path

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

-- | What to do when the trace sink itself fails.
--
-- Under 'EvidenceBestEffort' this reports once on stderr and continues,
-- which is baikai's long-standing behaviour and what every caller who
-- has not opted into evidence gets. Strict callers need the opposite —
-- evidence that can vanish without the caller noticing is not evidence
-- — and get it from
-- @docs\/plans\/57-enforce-strict-evidence-mode-and-release-the-evidence-surface.md@,
-- which replaces the body of this one function rather than
-- restructuring the trace finalizer around it.
onSinkFailure :: EvidenceStrictness -> SomeException -> IO ()
onSinkFailure = \case
  EvidenceBestEffort -> report
  EvidenceRequired _ -> report
  where
    report e =
      hPutStrLn
        stderr
        ( "baikai: trace sink failed; trace events for this call were dropped: "
            <> displayException e
        )
