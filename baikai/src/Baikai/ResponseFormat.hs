{-# OPTIONS_GHC -Wno-partial-fields #-}

-- | Provider-agnostic structured-output preference.
--
-- Each provider maps the value to its own native mechanism:
-- OpenAI's @response_format@ and Anthropic's @output_config@.
-- 'Nothing' on 'Baikai.Options.responseFormat' means no
-- structured-output constraint (today's behaviour).
module Baikai.ResponseFormat
  ( ResponseFormat (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | How to constrain the model's output.
data ResponseFormat
  = -- | Enforce a named JSON Schema. The 'schema' is a raw JSON
    --   Schema document (an aeson 'Value'), passed through verbatim;
    --   baikai never inspects or validates it. 'strict' requests the
    --   provider's strict schema-enforcement mode where available
    --   (OpenAI honours it; Anthropic structured outputs are always
    --   schema-enforcing and ignore it).
    JsonSchema
      { name :: !Text,
        schema :: !Value,
        strict :: !Bool
      }
  | -- | Plain-JSON mode: the model must emit syntactically valid JSON
    --   but is not constrained to a specific shape. Maps to OpenAI's
    --   @{"type":"json_object"}@; on Anthropic (whose structured
    --   outputs require a schema) it maps to a permissive
    --   @{"type":"object"}@ schema.
    JsonObject
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
