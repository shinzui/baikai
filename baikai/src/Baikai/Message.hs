-- | The conversation message ADT.
--
-- A 'Message' is one of three constructors:
--
-- * 'UserMessage' — caller input, carrying a 'UserPayload' (its
--   'content' is a vector of text and inline image blocks, plus a
--   creation timestamp).
-- * 'AssistantMessage' — model output, carrying an 'AssistantPayload'
--   (its 'content' holds 'AssistantText', 'AssistantThinking', and
--   'AssistantToolCall' blocks, alongside the call's 'Usage' (which now
--   embeds 'Cost' in-place), the 'StopReason' the model reported, an
--   optional 'errorMessage', and a timestamp).
-- * 'ToolResultMessage' — caller-supplied output for a model-issued
--   tool call, carrying a 'ToolResultPayload' (the tool-call id it
--   answers, the tool's name, the result 'content' (text or image), an
--   'isError' flag, and a timestamp).
--
-- The 'system' constructor from prior versions is removed: system
-- prompts live on 'Baikai.Request.Request.systemPrompt'. The 'Role'
-- enum is also removed — pattern-match on the constructor instead.
--
-- Each constructor wraps a dedicated single-constructor payload record
-- ('UserPayload', 'AssistantPayload', 'ToolResultPayload') rather than
-- carrying record fields directly on the sum. This keeps every field
-- selector total: a partial selector defined across a multi-constructor
-- sum (e.g. an @assistantContent@ that throws on a 'UserMessage') is a
-- latent runtime hazard that @-Wpartial-fields@ flags. Splitting the
-- payloads out makes each field live in a single-constructor record
-- where selection cannot fail, and lets every payload reuse the clean
-- shared field name 'content' (via @DuplicateRecordFields@) instead of
-- the @userContent@/@assistantContent@/@toolResultContent@ workaround a
-- single data declaration would have forced.
module Baikai.Message
  ( Message (..),
    UserPayload (..),
    AssistantPayload (..),
    ToolResultPayload (..),
    ToolResult (..),
    user,
    userAt,
    userNow,
    userImage,
    userImageAt,
    userImageNow,
    assistant,
    assistantAt,
    assistantNow,
    toolResultMessage,
    toolResultMessageAt,
    toolResultMessageNow,
    toolResultFromCall,
    toolResultFromCallAt,
    toolResultFromCallNow,
    toolResult,
    toolResultAt,
    toolResultNow,
    toolResultText,
    toolResultErrorText,
    toolResultImage,
    toolResultBlocks,
  )
where

import Baikai.Content
  ( AssistantContent (..),
    ImageContent,
    TextContent (TextContent),
    ToolCall (..),
    ToolResultContent (..),
    UserContent (..),
  )
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (Usage, _Usage)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as V
import GHC.Generics (Generic)

data Message
  = UserMessage UserPayload
  | AssistantMessage AssistantPayload
  | ToolResultMessage ToolResultPayload
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Caller input: a vector of text and inline image blocks plus a
-- creation timestamp.
data UserPayload = UserPayload
  { content :: !(Vector UserContent),
    timestamp :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Model output: the assistant content blocks ('AssistantText',
-- 'AssistantThinking', 'AssistantToolCall'), the call's 'Usage' (which
-- embeds 'Cost' in-place), the reported 'StopReason', an optional
-- 'errorMessage' (failure text or a non-fatal provider diagnostic;
-- use 'stopReason'/'Response.errorInfo' to detect failures), and a
-- creation timestamp.
data AssistantPayload = AssistantPayload
  { content :: !(Vector AssistantContent),
    usage :: !Usage,
    stopReason :: !StopReason,
    errorMessage :: !(Maybe Text),
    timestamp :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Caller-supplied output for a model-issued tool call: the tool-call
-- id it answers, the tool's name, the result 'content' (text or
-- image), an 'isError' flag, and a creation timestamp.
data ToolResultPayload = ToolResultPayload
  { toolCallId :: !Text,
    toolName :: !Text,
    content :: !(Vector ToolResultContent),
    isError :: !Bool,
    timestamp :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | A caller-produced result for one model-issued tool call.
--
-- The result can contain one or more text or image blocks, and
-- @isError@ tells the model whether the tool execution failed in a
-- recoverable way. Use the smart constructors below for the common
-- cases.
data ToolResult = ToolResult
  { content :: !(Vector ToolResultContent),
    isError :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

defaultTimestamp :: UTCTime
defaultTimestamp = read "2000-01-01 00:00:00 UTC"

-- | Build a one-text-block user message with a deterministic fixture
-- timestamp. Prefer 'userAt' when the timestamp matters, or 'userNow'
-- when the timestamp should be sampled in 'IO'.
user :: Text -> Message
user = userAt defaultTimestamp

-- | Build a one-text-block user message at an explicit timestamp.
userAt :: UTCTime -> Text -> Message
userAt ts t =
  UserMessage
    UserPayload
      { content = V.singleton (UserText (TextContent t)),
        timestamp = ts
      }

-- | Build a one-text-block user message using the current time.
userNow :: Text -> IO Message
userNow t = do
  now <- getCurrentTime
  pure (userAt now t)

-- | Build a user message carrying one inline image alongside optional
-- preceding text, using a deterministic fixture timestamp.
userImage :: ImageContent -> Maybe Text -> Message
userImage = userImageAt defaultTimestamp

-- | Build a user image message at an explicit timestamp. Bytes are
-- stored decoded; the JSON encoding base64-encodes them on the wire.
userImageAt :: UTCTime -> ImageContent -> Maybe Text -> Message
userImageAt ts img mPrefix =
  let prefix = case mPrefix of
        Nothing -> V.empty
        Just t -> V.singleton (UserText (TextContent t))
   in UserMessage
        UserPayload
          { content = prefix <> V.singleton (UserImage img),
            timestamp = ts
          }

-- | Build a user image message using the current time.
userImageNow :: ImageContent -> Maybe Text -> IO Message
userImageNow img mPrefix = do
  now <- getCurrentTime
  pure (userImageAt now img mPrefix)

-- | Build a one-text-block assistant message with zero usage and a
-- @stop@ stop reason, using a deterministic fixture timestamp.
assistant :: Text -> Message
assistant = assistantAt defaultTimestamp

-- | Build a one-text-block assistant message at an explicit timestamp.
assistantAt :: UTCTime -> Text -> Message
assistantAt ts t =
  AssistantMessage
    AssistantPayload
      { content = V.singleton (AssistantText (TextContent t)),
        usage = _Usage,
        stopReason = Stop,
        errorMessage = Nothing,
        timestamp = ts
      }

-- | Build a one-text-block assistant message using the current time.
assistantNow :: Text -> IO Message
assistantNow t = do
  now <- getCurrentTime
  pure (assistantAt now t)

-- | Build a tool-result message answering a prior 'AssistantToolCall'
-- using rich content blocks and a deterministic fixture timestamp.
toolResultMessage :: Text -> Text -> ToolResult -> Message
toolResultMessage callId name =
  toolResultMessageAt defaultTimestamp callId name

-- | Build a tool-result message at an explicit timestamp.
toolResultMessageAt :: UTCTime -> Text -> Text -> ToolResult -> Message
toolResultMessageAt ts callId name ToolResult {content = blocks, isError = err} =
  ToolResultMessage
    ToolResultPayload
      { toolCallId = callId,
        toolName = name,
        content = blocks,
        isError = err,
        timestamp = ts
      }

-- | Build a tool-result message using the current time.
toolResultMessageNow :: Text -> Text -> ToolResult -> IO Message
toolResultMessageNow callId name result = do
  now <- getCurrentTime
  pure (toolResultMessageAt now callId name result)

-- | Build a rich tool-result message from the original tool call.
toolResultFromCall :: ToolCall -> ToolResult -> Message
toolResultFromCall ToolCall {id_ = callId, name = toolName} =
  toolResultMessage callId toolName

-- | Build a rich tool-result message from the original tool call at
-- an explicit timestamp.
toolResultFromCallAt :: UTCTime -> ToolCall -> ToolResult -> Message
toolResultFromCallAt ts ToolCall {id_ = callId, name = toolName} =
  toolResultMessageAt ts callId toolName

-- | Build a rich tool-result message from the original tool call using
-- the current time.
toolResultFromCallNow :: ToolCall -> ToolResult -> IO Message
toolResultFromCallNow ToolCall {id_ = callId, name = toolName} =
  toolResultMessageNow callId toolName

-- | Build a one-text-block tool-result message. This is the
-- text-only compatibility shorthand; prefer 'toolResultMessage'
-- when the result has multiple blocks or image content.
toolResult :: Text -> Text -> Text -> Bool -> Message
toolResult callId name body err =
  toolResultAt defaultTimestamp callId name body err

-- | Build a one-text-block tool-result message at an explicit timestamp.
toolResultAt :: UTCTime -> Text -> Text -> Text -> Bool -> Message
toolResultAt ts callId name body err =
  toolResultMessageAt
    ts
    callId
    name
    ( ToolResult
        { content = V.singleton (ToolResultText (TextContent body)),
          isError = err
        }
    )

-- | Build a one-text-block tool-result message using the current time.
toolResultNow :: Text -> Text -> Text -> Bool -> IO Message
toolResultNow callId name body err = do
  now <- getCurrentTime
  pure (toolResultAt now callId name body err)

-- | Successful one-text-block tool result.
toolResultText :: Text -> ToolResult
toolResultText body =
  ToolResult
    { content = V.singleton (ToolResultText (TextContent body)),
      isError = False
    }

-- | Error one-text-block tool result.
toolResultErrorText :: Text -> ToolResult
toolResultErrorText body =
  ToolResult
    { content = V.singleton (ToolResultText (TextContent body)),
      isError = True
    }

-- | Successful one-image-block tool result.
toolResultImage :: ImageContent -> ToolResult
toolResultImage img =
  ToolResult
    { content = V.singleton (ToolResultImage img),
      isError = False
    }

-- | Tool result with explicit content blocks and error flag.
toolResultBlocks :: Vector ToolResultContent -> Bool -> ToolResult
toolResultBlocks blocks err =
  ToolResult
    { content = blocks,
      isError = err
    }
