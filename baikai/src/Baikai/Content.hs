{-# LANGUAGE LambdaCase #-}

-- | Typed content blocks for user, assistant, and tool-result messages.
--
-- A message no longer carries a single opaque blob of text. Instead it
-- holds a vector of typed blocks. For user input the blocks can be text
-- or an inline base64-encoded image. For assistant output a block can be
-- text, a thinking trace (for reasoning-capable models), or a tool
-- invocation. For tool-result messages (a caller-supplied reply to a
-- model-issued tool call) blocks can be text or image.
--
-- Image content is restricted to
-- inline base64 with an explicit @mimeType@: the caller is responsible
-- for the (small, reversible) work of base64-encoding bytes once, and
-- every provider can consume the same shape without a URL-fetch path
-- that varies in failure modes.
module Baikai.Content
  ( -- * Block primitives
    TextContent (..),
    ThinkingContent (..),
    ToolCall (..),
    ImageContent (..),

    -- * Per-role block sums
    UserContent (..),
    AssistantContent (..),
    ToolResultContent (..),

    -- * Tool-call arguments
    toolArgumentsFromText,
    isCutOffToolCall,

    -- * Smart defaults
    emptyTextContent,
    emptyThinkingContent,
    emptyToolCall,
    emptyImageContent,
  )
where

import Data.Aeson
  ( FromJSON (parseJSON),
    Options (..),
    SumEncoding (..),
    ToJSON (toJSON),
    Value (Null),
    camelTo2,
    defaultOptions,
    genericParseJSON,
    genericToJSON,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import GHC.Generics (Generic)

-- | A plain-text block. The wire form is @{"text": "..."}@.
newtype TextContent = TextContent
  { text :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A reasoning trace block produced by thinking-capable models. The
-- @signature@ field is an opaque continuation token returned by the
-- provider; it must be threaded back into the next request unchanged for
-- the model to resume from the same state. @redacted@ is 'True' when the
-- provider hid the underlying content (Anthropic flags this when its
-- safety system removes a thinking block from the wire response). When
-- @redacted@ is 'True', @thinking@ holds the provider's opaque encrypted
-- payload verbatim; callers must not display or edit it.
data ThinkingContent = ThinkingContent
  { thinking :: !Text,
    signature :: !(Maybe Text),
    redacted :: !Bool
  }
  deriving stock (Eq, Show, Generic)

-- | A model-issued tool invocation. @id_@ has a trailing underscore in
-- Haskell to dodge a clash with @Prelude.id@; the JSON encoding strips
-- it back to @id@.
--
-- @arguments@ is the decoded JSON value the model sent — normally an
-- object. A bare 'Data.Aeson.String' is the __cut-off marker__: the
-- model's argument stream was truncated (by the output cap, or by a
-- transport failure mid-call) and the raw text is kept verbatim rather
-- than replaced by something well-formed that the model never asked
-- for. 'isCutOffToolCall' is the predicate; 'toolArgumentsFromText' is
-- the one rule that produces it. A cut-off call must not be dispatched:
-- 'Baikai.Provider.Registry.runToolLoop' stops on one and
-- 'Baikai.Context.appendToolResult' reports it as a tool-result error.
data ToolCall = ToolCall
  { id_ :: !Text,
    name :: !Text,
    arguments :: !Value
  }
  deriving stock (Eq, Show, Generic)

-- | Turn a tool call's accumulated argument text into its @arguments@
-- value.
--
-- Empty text is an empty object: Anthropic opens a @tool_use@ block with
-- no input and streams no delta, and an empty object is exactly what the
-- model asked for. Non-empty text that does not decode is kept verbatim
-- as a 'Data.Aeson.String' — the call was cut off, and no byte of what
-- the model did send is dropped.
--
-- Both provider assemblers and core's stream-recovery path use this one
-- rule, so 'isCutOffToolCall' means the same thing at every layer.
-- Before it, the assemblers replaced malformed arguments with @{}@ and a
-- tool loop happily executed the call with no arguments at all.
toolArgumentsFromText :: Text -> Value
toolArgumentsFromText raw
  | Text.null (Text.strip raw) = Aeson.Object mempty
  | otherwise = case Aeson.eitherDecodeStrict (Text.encodeUtf8 raw) of
      Right v -> v
      Left _ -> Aeson.String raw

-- | 'True' when the call's argument stream was cut off: @arguments@ is
-- the raw text rather than a decoded value. See 'ToolCall'.
isCutOffToolCall :: ToolCall -> Bool
isCutOffToolCall ToolCall {arguments = Aeson.String _} = True
isCutOffToolCall _ = False

-- | An inline image block. Bytes are stored decoded; the JSON encoding
-- emits base64 under @data@ and the @mimeType@ camel-snakes to
-- @mime_type@.
data ImageContent = ImageContent
  { imageData :: !ByteString,
    mimeType :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | What a caller can put into a 'Baikai.Message.UserMessage'.
data UserContent
  = UserText !TextContent
  | UserImage !ImageContent
  deriving stock (Eq, Show, Generic)

-- | What a provider can put into a 'Baikai.Message.AssistantMessage'.
data AssistantContent
  = AssistantText !TextContent
  | AssistantThinking !ThinkingContent
  | AssistantToolCall !ToolCall
  deriving stock (Eq, Show, Generic)

-- | What a caller can put into a 'Baikai.Message.ToolResultMessage'.
data ToolResultContent
  = ToolResultText !TextContent
  | ToolResultImage !ImageContent
  deriving stock (Eq, Show, Generic)

emptyTextContent :: TextContent
emptyTextContent = TextContent {text = Text.empty}

emptyThinkingContent :: ThinkingContent
emptyThinkingContent =
  ThinkingContent
    { thinking = Text.empty,
      signature = Nothing,
      redacted = False
    }

emptyToolCall :: ToolCall
emptyToolCall =
  ToolCall
    { id_ = Text.empty,
      name = Text.empty,
      arguments = Null
    }

emptyImageContent :: ImageContent
emptyImageContent =
  ImageContent
    { imageData = BS.empty,
      mimeType = Text.empty
    }

-- Aeson plumbing ---------------------------------------------------------

snakeOptions :: Options
snakeOptions = defaultOptions {fieldLabelModifier = camelTo2 '_'}

instance FromJSON ThinkingContent where
  parseJSON = genericParseJSON snakeOptions

instance ToJSON ThinkingContent where
  toJSON = genericToJSON snakeOptions

-- Strip the trailing underscore on @id_@ so the wire form is @id@; the
-- other fields keep their natural names.
toolCallOptions :: Options
toolCallOptions =
  defaultOptions
    { fieldLabelModifier = \case
        "id_" -> "id"
        s -> camelTo2 '_' s
    }

instance FromJSON ToolCall where
  parseJSON = genericParseJSON toolCallOptions

instance ToJSON ToolCall where
  toJSON = genericToJSON toolCallOptions

-- ImageContent is encoded manually so the bytes round-trip through
-- base64 on the wire under @data@ while staying decoded in Haskell.
instance ToJSON ImageContent where
  toJSON c =
    object
      [ "data" .= Text.decodeUtf8 (Base64.encode (imageData c)),
        "mime_type" .= mimeType c
      ]

instance FromJSON ImageContent where
  parseJSON = withObject "ImageContent" $ \o -> do
    encoded <- o .: "data"
    mt <- o .: "mime_type"
    case Base64.decode (Text.encodeUtf8 encoded) of
      Left err -> fail ("ImageContent.data is not base64: " <> err)
      Right raw -> pure ImageContent {imageData = raw, mimeType = mt}

contentSumOptions :: Options
contentSumOptions =
  defaultOptions
    { sumEncoding = TaggedObject {tagFieldName = "type", contentsFieldName = "data"},
      constructorTagModifier = camelTo2 '_'
    }

instance FromJSON UserContent where
  parseJSON = genericParseJSON contentSumOptions

instance ToJSON UserContent where
  toJSON = genericToJSON contentSumOptions

instance FromJSON AssistantContent where
  parseJSON = genericParseJSON contentSumOptions

instance ToJSON AssistantContent where
  toJSON = genericToJSON contentSumOptions

instance FromJSON ToolResultContent where
  parseJSON = genericParseJSON contentSumOptions

instance ToJSON ToolResultContent where
  toJSON = genericToJSON contentSumOptions
