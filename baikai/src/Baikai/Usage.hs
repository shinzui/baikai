module Baikai.Usage (Usage (..), _Usage) where

import Data.Aeson
  ( FromJSON (parseJSON)
  , Options (fieldLabelModifier)
  , ToJSON (toJSON)
  , camelTo2
  , defaultOptions
  , genericParseJSON
  , genericToJSON
  )
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

data Usage = Usage
  { inputTokens :: !Natural
  , outputTokens :: !Natural
  , cachedInputTokens :: !(Maybe Natural)
  , reasoningTokens :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

usageOptions :: Options
usageOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance FromJSON Usage where parseJSON = genericParseJSON usageOptions
instance ToJSON Usage where toJSON = genericToJSON usageOptions

_Usage :: Usage
_Usage =
  Usage
    { inputTokens = 0
    , outputTokens = 0
    , cachedInputTokens = Nothing
    , reasoningTokens = Nothing
    }
