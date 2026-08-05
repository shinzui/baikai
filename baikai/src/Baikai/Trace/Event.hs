{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | The 'TraceEvent' sum and its JSON encoding.
--
-- A trace event is one of four discriminated cases: 'CallStarted' fires
-- when a provider call begins, 'CallFinished' when it returns a response,
-- 'CallFailed' when it throws, and 'CallEvidence' carries the full
-- 'ModelCallEvidence' record for callers who asked for one. The
-- 'sumEncoding' tag field is @kind@, so a JSON-Lines stream of these can
-- be filtered with @jq 'select(.kind == "call_finished")'@.
module Baikai.Trace.Event
  ( TraceEvent (..),
    traceEventOptions,
  )
where

import Baikai.Evidence (ModelCallEvidence)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    defaultOptions,
    genericToEncoding,
    genericToJSON,
    withObject,
    (.:),
    (.:?),
  )
import Data.Aeson.Types (Parser)
import Data.Char (toLower)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | One observable event from a provider call.
--
-- Every event carries an 'eventId' that correlates the @started@ event
-- with its matching @finished@, @failed@, or @evidence@ event within a
-- single process run. Token counts are 'Maybe' because subscription-based
-- providers (the CLIs) do not report them; 'omitNothingFields' keeps the
-- absent fields out of the rendered JSON.
--
-- 'usd' is deliberately /not/ 'Maybe'-shaped as an "unknown" marker: it
-- was until this release, and a computed cost of zero was suppressed, so
-- a genuinely free call and a call whose cost baikai could not compute
-- looked identical in a trace. The field is still 'Maybe' because a
-- non-assistant terminal has no usage at all, but a zero cost now
-- renders as @0@.
data TraceEvent
  = CallStarted
      { eventId :: !Text,
        timestamp :: !UTCTime,
        provider :: !Text,
        model :: !Text,
        maxTokens :: !Natural,
        promptSummary :: !Text
      }
  | CallFinished
      { eventId :: !Text,
        timestamp :: !UTCTime,
        provider :: !Text,
        model :: !Text,
        latencyMs :: !Int,
        inputTokens :: !(Maybe Natural),
        outputTokens :: !(Maybe Natural),
        -- | Cache-read, cache-write, reasoning, and total token counts.
        -- 'Baikai.Cost.Log.CallLogEntry' has always kept the first and
        -- the third; a trace that dropped them was strictly less
        -- faithful than the cost log built from the same 'Usage' value.
        cachedInputTokens :: !(Maybe Natural),
        cacheWriteTokens :: !(Maybe Natural),
        reasoningTokens :: !(Maybe Natural),
        totalTokens :: !(Maybe Natural),
        usd :: !(Maybe Scientific)
      }
  | CallFailed
      { eventId :: !Text,
        timestamp :: !UTCTime,
        provider :: !Text,
        model :: !Text,
        latencyMs :: !Int,
        errorMessage :: !Text
      }
  | -- | The complete evidence record for one terminal provider call.
    --
    -- Emitted exactly once per call, immediately after the matching
    -- 'CallFinished' or 'CallFailed', and only when the caller set
    -- 'Baikai.Options.evidence' and the provider built a record. A
    -- consumer that wants only evidence can filter on this kind alone,
    -- and a consumer written before this constructor existed is
    -- unaffected as long as its pattern match is not exhaustive over
    -- the sum.
    CallEvidence
      { eventId :: !Text,
        timestamp :: !UTCTime,
        provider :: !Text,
        model :: !Text,
        evidence :: !ModelCallEvidence
      }
  deriving stock (Eq, Show, Generic)

-- | Aeson options used by the 'ToJSON' instance, and the shape the
-- hand-written 'FromJSON' instance parses.
--
-- * Sum encoding: @{"kind":"<tag>","data":{...}}@.
-- * Constructor tags: snake-case (@call_started@, @call_finished@,
--   @call_failed@, @call_evidence@).
-- * Field labels: kept as-is (camelCase).
-- * Nothing fields are dropped from the encoded JSON.
traceEventOptions :: Options
traceEventOptions =
  defaultOptions
    { sumEncoding = TaggedObject {tagFieldName = "kind", contentsFieldName = "data"},
      constructorTagModifier = dropWhile (== '_') . camelToSnake,
      omitNothingFields = True
    }
  where
    camelToSnake :: String -> String
    camelToSnake [] = []
    camelToSnake (c : cs)
      | c `elem` ['A' .. 'Z'] = '_' : toLower c : camelToSnake cs
      | otherwise = c : camelToSnake cs

instance ToJSON TraceEvent where
  toJSON = genericToJSON traceEventOptions
  toEncoding = genericToEncoding traceEventOptions

-- | Written out rather than derived, and it decodes only the three
-- non-evidence cases.
--
-- 'ModelCallEvidence' deliberately has no 'FromJSON' instance: it embeds
-- a 'Baikai.Cost.Cost' whose exact 'Rational' amounts encode through an
-- approximating 'Data.Scientific.Scientific', so a decoder would return
-- a different value than was encoded. Rather than manufacture that
-- fidelity, a @call_evidence@ line fails to parse with a message saying
-- to read it as a plain 'Data.Aeson.Value'. That is the honest
-- behaviour, and it is what a consumer wants anyway — the JSON, not a
-- Haskell mirror of it, is the contract other systems pin against.
instance FromJSON TraceEvent where
  parseJSON = withObject "TraceEvent" $ \o -> do
    kind <- o .: "kind"
    d <- o .: "data" :: Parser Object
    case kind :: Text of
      "call_started" ->
        CallStarted
          <$> d .: "eventId"
          <*> d .: "timestamp"
          <*> d .: "provider"
          <*> d .: "model"
          <*> d .: "maxTokens"
          <*> d .: "promptSummary"
      "call_finished" ->
        CallFinished
          <$> d .: "eventId"
          <*> d .: "timestamp"
          <*> d .: "provider"
          <*> d .: "model"
          <*> d .: "latencyMs"
          <*> d .:? "inputTokens"
          <*> d .:? "outputTokens"
          <*> d .:? "cachedInputTokens"
          <*> d .:? "cacheWriteTokens"
          <*> d .:? "reasoningTokens"
          <*> d .:? "totalTokens"
          <*> d .:? "usd"
      "call_failed" ->
        CallFailed
          <$> d .: "eventId"
          <*> d .: "timestamp"
          <*> d .: "provider"
          <*> d .: "model"
          <*> d .: "latencyMs"
          <*> d .: "errorMessage"
      "call_evidence" ->
        fail
          "TraceEvent: a call_evidence line carries a ModelCallEvidence, \
          \which has no faithful decoder; read it as a Data.Aeson.Value"
      other -> fail ("TraceEvent: unknown kind " <> show other)
