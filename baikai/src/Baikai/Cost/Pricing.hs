-- | Per-model pricing tables and pure cost computation.
--
-- Prices are quoted in USD per million tokens and stored as exact 'Rational'
-- values. The seeded values are a snapshot taken on 2026-05-13 from
-- <https://www.anthropic.com/pricing> and <https://openai.com/api/pricing>;
-- providers change prices, so verify against the current page before relying
-- on these values. Each API provider record carries its own 'pricing' field,
-- so callers can override the table without touching the library.
module Baikai.Cost.Pricing
  ( PricingRate (..)
  , claudePricing
  , openaiPricing
  , defaultPricing
  , lookupRate
  , compute
  , attachCost
  ) where

import Baikai.Cost (Cost (..), CostBreakdown (..))
import Baikai.Model (Model (..))
import Baikai.Response (Response (..))
import Baikai.Usage (Usage (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

data PricingRate = PricingRate
  { inputPerMillion :: !Rational
  , outputPerMillion :: !Rational
  , cachedInputPerMillion :: !(Maybe Rational)
  }
  deriving stock (Eq, Show, Generic)

-- | Anthropic Claude prices in USD per million tokens. Snapshot 2026-05-13.
-- Source: <https://www.anthropic.com/pricing>.
claudePricing :: Map Text PricingRate
claudePricing =
  Map.fromList
    [
      ( "claude-opus-4-7"
      , PricingRate
          { inputPerMillion = 15
          , outputPerMillion = 75
          , cachedInputPerMillion = Just (3 / 2)
          }
      )
    ,
      ( "claude-sonnet-4-6"
      , PricingRate
          { inputPerMillion = 3
          , outputPerMillion = 15
          , cachedInputPerMillion = Just (3 / 10)
          }
      )
    ,
      ( "claude-sonnet-4-5-20250929"
      , PricingRate
          { inputPerMillion = 3
          , outputPerMillion = 15
          , cachedInputPerMillion = Just (3 / 10)
          }
      )
    ,
      ( "claude-haiku-4-5-20251001"
      , PricingRate
          { inputPerMillion = 1
          , outputPerMillion = 5
          , cachedInputPerMillion = Just (1 / 10)
          }
      )
    ]

-- | OpenAI Chat prices in USD per million tokens. Snapshot 2026-05-13.
-- Source: <https://openai.com/api/pricing>.
openaiPricing :: Map Text PricingRate
openaiPricing =
  Map.fromList
    [
      ( "gpt-5"
      , PricingRate
          { inputPerMillion = 5
          , outputPerMillion = 20
          , cachedInputPerMillion = Just (5 / 10)
          }
      )
    ,
      ( "gpt-4o"
      , PricingRate
          { inputPerMillion = 5
          , outputPerMillion = 20
          , cachedInputPerMillion = Just (25 / 10)
          }
      )
    ,
      ( "gpt-4o-mini"
      , PricingRate
          { inputPerMillion = 15 / 100
          , outputPerMillion = 6 / 10
          , cachedInputPerMillion = Just (75 / 1000)
          }
      )
    ,
      ( "o3"
      , PricingRate
          { inputPerMillion = 60
          , outputPerMillion = 240
          , cachedInputPerMillion = Just 30
          }
      )
    ]

-- | Union of 'claudePricing' and 'openaiPricing'. Used as the default for the
-- 'pricing' field on each API provider record.
defaultPricing :: Map Text PricingRate
defaultPricing = claudePricing <> openaiPricing

lookupRate :: Map Text PricingRate -> Model -> Maybe PricingRate
lookupRate pricing (Model m) = Map.lookup m pricing

-- | Compute a 'Cost' from a model and its token 'Usage' against a pricing
-- table. Returns 'Nothing' when the model is not in the table; that is the
-- truthful signal that the library does not know the price.
compute :: Map Text PricingRate -> Model -> Usage -> Maybe Cost
compute pricing model usage =
  case lookupRate pricing model of
    Nothing -> Nothing
    Just rate ->
      let inUsd =
            toRational (inputTokens usage)
              * inputPerMillion rate
              / 1_000_000
          outUsd =
            toRational (outputTokens usage)
              * outputPerMillion rate
              / 1_000_000
          cachedUsd =
            case (cachedInputTokens usage, cachedInputPerMillion rate) of
              (Just n, Just r) -> toRational n * r / 1_000_000
              _ -> 0
          total = inUsd + outUsd + cachedUsd
       in Just
            Cost
              { usd = total
              , breakdown =
                  CostBreakdown
                    { inputUsd = inUsd
                    , outputUsd = outUsd
                    , cachedInputUsd = cachedUsd
                    }
              }

-- | Fill a 'Response's 'cost' field from the pricing table when 'usage' is
-- present and the model is known. Leaves the response untouched otherwise.
attachCost :: Map Text PricingRate -> Response -> Response
attachCost pricing resp = case usage resp of
  Nothing -> resp
  Just u -> resp {cost = compute pricing (model resp) u}
