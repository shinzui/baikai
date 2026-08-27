-- | The 'Tool' type and tool-choice control.
--
-- A 'Tool' is a name, a human-readable description, and a JSON
-- Schema describing the parameters. The schema is carried as a
-- 'Data.Aeson.Value' rather than a typed schema GADT so callers can
-- hand-write or generate the schema however they like; the
-- provider-side encoders forward it to the upstream API verbatim.
--
-- 'ToolChoice' tells the model how aggressively to use the tools.
-- The default in 'Baikai.Options.Options' is 'Nothing' which lets
-- the provider apply its own default (typically @auto@ for
-- Anthropic and OpenAI).
--
-- The conversation-level helper for the common case — execute the
-- model's tool calls and append the results to the next request —
-- lives in 'Baikai.Context.appendToolResult' and
-- 'Baikai.Context.appendToolResultText' to avoid an import cycle
-- between this module (which 'Baikai.Context' imports for the @tools@
-- field type) and 'Baikai.Context' itself.
module Baikai.Tool
  ( Tool (name, description, parameters),
    mkTool,
    ToolChoice (..),
    emptyTool,
    _Tool,
  )
where

import Data.Aeson
  ( FromJSON (..),
    Options (..),
    SumEncoding (..),
    ToJSON (..),
    Value (..),
    camelTo2,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
  )
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)

-- | A caller-declared tool. @parameters@ holds a JSON Schema; the
-- provider-side encoders pass it through unchanged.
--
-- Construction: the constructor is deliberately not exported. Use
-- 'mkTool', which takes the three fields every provider needs, and
-- override anything else by record update. 'emptyTool' remains for
-- fixtures, but a tool declared from it and sent unchanged reaches the
-- wire with @input_schema: null@.
data Tool = Tool
  { name :: !Text,
    description :: !Text,
    parameters :: !Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A tool from its name, its description and its JSON Schema — the
-- three things every provider requires.
--
-- > mkTool "get_weather" "Look up the weather" schema
mkTool :: Text -> Text -> Value -> Tool
mkTool toolName toolDescription toolParameters =
  Tool
    { name = toolName,
      description = toolDescription,
      parameters = toolParameters
    }

-- | How the model should pick between the registered tools.
--
-- * 'ToolChoiceAuto' — model decides (the default at most providers).
-- * 'ToolChoiceNone' — disable tool calling for this request.
-- * 'ToolChoiceRequired' — must call some tool.
-- * 'ToolChoiceSpecific' — must call this exact tool by name.
data ToolChoice
  = ToolChoiceAuto
  | ToolChoiceNone
  | ToolChoiceRequired
  | ToolChoiceSpecific !Text
  deriving stock (Eq, Show, Generic)

toolChoiceOptions :: Options
toolChoiceOptions =
  defaultOptions
    { sumEncoding = TaggedObject {tagFieldName = "type", contentsFieldName = "name"},
      constructorTagModifier = camelTo2 '_' . drop (Text.length "ToolChoice")
    }

instance FromJSON ToolChoice where
  parseJSON = genericParseJSON toolChoiceOptions

instance ToJSON ToolChoice where
  toJSON = genericToJSON toolChoiceOptions

-- | An empty tool — useful as a base for record updates.
emptyTool :: Tool
emptyTool =
  Tool
    { name = Text.empty,
      description = Text.empty,
      parameters = Null
    }

{-# DEPRECATED _Tool "Use emptyTool instead." #-}
_Tool :: Tool
_Tool = emptyTool
