{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | The 'TraceEvent' sum and its JSON encoding.
--
-- A trace event is one of three discriminated cases: 'CallStarted' fires
-- when a provider call begins, 'CallFinished' when it returns a response,
-- and 'CallFailed' when it throws. The 'sumEncoding' tag field is @kind@,
-- so a JSON-Lines stream of these can be filtered with
-- @jq 'select(.kind == "call_finished")'@.
module Baikai.Trace.Event
  ( TraceEvent (..),
    traceEventOptions,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    defaultOptions,
    genericParseJSON,
    genericToEncoding,
    genericToJSON,
  )
import Data.Char (toLower)
import Data.Scientific (Scientific)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | One observable event from a provider call.
--
-- Every event carries an 'eventId' that correlates the @started@ event
-- with its matching @finished@ or @failed@ event within a single process
-- run. Token counts and dollar cost are 'Maybe' because subscription-based
-- providers (the CLIs) do not report them; 'omitNothingFields' keeps the
-- absent fields out of the rendered JSON.
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
  deriving stock (Eq, Show, Generic)

-- | Aeson options shared by 'ToJSON' and 'FromJSON' instances.
--
-- * Sum encoding: @{"kind":"<tag>","data":{...}}@.
-- * Constructor tags: snake-case (@call_started@, @call_finished@,
--   @call_failed@).
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

instance FromJSON TraceEvent where
  parseJSON = genericParseJSON traceEventOptions
