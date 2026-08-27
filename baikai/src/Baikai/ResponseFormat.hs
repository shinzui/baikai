{-# LANGUAGE OverloadedRecordDot #-}

-- | Provider-agnostic structured-output preference.
--
-- Each provider maps the value to its own native mechanism:
-- OpenAI's @response_format@ and Anthropic's @output_config@.
-- 'Nothing' on 'Baikai.Options.responseFormat' means no
-- structured-output constraint (today's behaviour).
module Baikai.ResponseFormat
  ( ResponseFormat (..),
    JsonSchemaFormat (name, schema, strict),
    jsonSchemaFormat,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | A named JSON Schema to enforce.
--
-- The 'schema' is a raw JSON Schema document (an aeson 'Value'), passed
-- through verbatim; baikai never inspects or validates it. 'strict'
-- requests the provider's strict schema-enforcement mode where available
-- (OpenAI honours it; Anthropic structured outputs are always
-- schema-enforcing and ignore it).
--
-- Construction: the constructor is deliberately not exported. Start from
-- 'jsonSchemaFormat' and override 'strict' by record update.
data JsonSchemaFormat = JsonSchemaFormat
  { name :: !Text,
    schema :: !Value,
    strict :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | A schema request from its name and its schema document, with
-- @strict = False@.
jsonSchemaFormat :: Text -> Value -> JsonSchemaFormat
jsonSchemaFormat schemaName schemaDoc =
  JsonSchemaFormat {name = schemaName, schema = schemaDoc, strict = False}

-- | How to constrain the model's output.
--
-- The schema fields live on 'JsonSchemaFormat' rather than directly on
-- the 'JsonSchema' constructor: as fields of a sum they were partial
-- selectors, and @name f@ on a 'JsonObject' was a crash rather than a
-- type error.
data ResponseFormat
  = -- | Enforce a named JSON Schema.
    JsonSchema !JsonSchemaFormat
  | -- | Plain-JSON mode: the model must emit syntactically valid JSON
    --   but is not constrained to a specific shape. Maps to OpenAI's
    --   @{"type":"json_object"}@; on Anthropic (whose structured
    --   outputs require a schema) it maps to a permissive
    --   @{"type":"object"}@ schema.
    JsonObject
  deriving stock (Eq, Show, Generic)

-- | Hand-written to keep the flat encoding the derived instances
-- produced before 'JsonSchemaFormat' existed:
-- @{"tag":"JsonSchema","name":…,"schema":…,"strict":…}@ and
-- @{"tag":"JsonObject"}@. 'Baikai.Options.Options' derives 'ToJSON'
-- through this, and at least one consumer keys a cache on the result.
instance ToJSON ResponseFormat where
  toJSON (JsonSchema f) =
    object
      [ "tag" .= ("JsonSchema" :: Text),
        "name" .= f.name,
        "schema" .= f.schema,
        "strict" .= f.strict
      ]
  toJSON JsonObject = object ["tag" .= ("JsonObject" :: Text)]

instance FromJSON ResponseFormat where
  parseJSON = withObject "ResponseFormat" $ \o -> do
    tag <- o .: "tag"
    case tag :: Text of
      "JsonObject" -> pure JsonObject
      "JsonSchema" -> do
        schemaName <- o .: "name"
        schemaDoc <- o .: "schema"
        isStrict <- o .:? "strict"
        pure
          ( JsonSchema
              (jsonSchemaFormat schemaName schemaDoc) {strict = fromMaybe False isStrict}
          )
      other -> fail ("unknown ResponseFormat tag: " <> show other)
