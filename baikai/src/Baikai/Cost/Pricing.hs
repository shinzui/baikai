-- | Cost computation from a 'Baikai.Model.Model' and a 'Usage'.
--
-- The previous map-based lookup (@Map Text PricingRate@) is gone.
-- Pricing rates live on 'Baikai.Model.Model.cost' directly, so the
-- computation collapses to a record-field access. Models without
-- published pricing carry a zero 'Baikai.Model.ModelCost' (the
-- default in '_Model'), producing a zero 'Cost'.
module Baikai.Cost.Pricing
  ( computeCost,
    attachCost,
  )
where

import Baikai.Cost (Cost (..), CostBreakdown (..))
import Baikai.Message (AssistantPayload (..), Message (..))
import Baikai.Model (Model, ModelCost (..))
import Baikai.Prelude
import Baikai.Response (Response (..))
import Baikai.Usage (Usage (..))

-- | Compute a 'Cost' from a model's per-million-token rates and a
-- 'Usage'. Returns a zero 'Cost' when the model carries zero rates,
-- which is the truthful signal for providers without published
-- pricing (CLI providers, custom hosts).
computeCost :: Model -> Usage -> Cost
computeCost m u =
  let rates = m ^. #cost
      inRate = inputCost rates
      outRate = outputCost rates
      crRate = cacheReadCost rates
      cwRate = cacheWriteCost rates
      inUsd = toRational (u ^. #inputTokens) * inRate / 1_000_000
      outUsd = toRational (u ^. #outputTokens) * outRate / 1_000_000
      cachedUsd = toRational (u ^. #cacheReadTokens) * crRate / 1_000_000
      cacheWriteUsd = toRational (u ^. #cacheWriteTokens) * cwRate / 1_000_000
      total = inUsd + outUsd + cachedUsd + cacheWriteUsd
   in Cost
        { usd = total,
          breakdown =
            CostBreakdown
              { inputUsd = inUsd,
                outputUsd = outUsd,
                cachedInputUsd = cachedUsd,
                cachedWriteUsd = cacheWriteUsd
              }
        }

-- | Replace the assistant message's embedded 'Cost' with one
-- computed from the supplied model. Leaves the response untouched
-- when 'message' is not an 'AssistantMessage' (providers never
-- produce a different constructor in practice).
attachCost :: Model -> Response -> Response
attachCost m r = case r ^. #message of
  AssistantMessage
    AssistantPayload
      { usage = u,
        content = c,
        stopReason = sr,
        errorMessage = em,
        timestamp = ts
      } ->
      let computed = computeCost m u
          u' = u & #cost .~ computed
          msg' =
            AssistantMessage
              AssistantPayload
                { content = c,
                  usage = u',
                  stopReason = sr,
                  errorMessage = em,
                  timestamp = ts
                }
       in r & #message .~ msg'
  _ -> r
