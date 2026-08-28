-- | CAP-8, docs/capabilities/categorised-error-model.md.
module Shape.Cap8 (shape) where

import Baikai hiding (model)
import Shape.Fixtures (backOff, ctx, giveUp, model, opts, retry, use)

shape :: IO ()
shape = do
  -- BEGIN CAP-8
  resp <- completeRequest model ctx opts
  case responseError resp of
    Just err | isRetryable err -> backOff (retryAfterSeconds err) >> retry
    Just _ -> giveUp
    Nothing -> use resp

-- END CAP-8
