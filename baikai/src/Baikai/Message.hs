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
    userImage,
    assistant,
    toolResultMessage,
    toolResultFromCall,
    toolResult,
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
import System.IO.Unsafe (unsafePerformIO)

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
-- 'errorMessage', and a creation timestamp.
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

-- | Build a one-text-block user message.
--
-- 'getCurrentTime' is run through 'unsafePerformIO' for ergonomics:
-- tests and one-shot scripts can write @user "hello"@ without threading
-- 'IO'. Production callers that need a controlled timestamp should
-- build the record directly. The 'NOINLINE' pragma ensures every call
-- site samples the clock once rather than sharing a single time across
-- the program.
user :: Text -> Message
user t =
  UserMessage
    UserPayload
      { content = V.singleton (UserText (TextContent t)),
        timestamp = unsafePerformIO getCurrentTime
      }
{-# NOINLINE user #-}

-- | Build a user message carrying one inline image alongside optional
-- preceding text. Bytes are stored decoded; the JSON encoding
-- base64-encodes them on the wire.
userImage :: ImageContent -> Maybe Text -> Message
userImage img mPrefix =
  let prefix = case mPrefix of
        Nothing -> V.empty
        Just t -> V.singleton (UserText (TextContent t))
   in UserMessage
        UserPayload
          { content = prefix <> V.singleton (UserImage img),
            timestamp = unsafePerformIO getCurrentTime
          }
{-# NOINLINE userImage #-}

-- | Build a one-text-block assistant message with zero usage and a
-- @stop@ stop reason. Useful for fixtures and replaying prior turns
-- into a follow-up request.
assistant :: Text -> Message
assistant t =
  AssistantMessage
    AssistantPayload
      { content = V.singleton (AssistantText (TextContent t)),
        usage = _Usage,
        stopReason = Stop,
        errorMessage = Nothing,
        timestamp = unsafePerformIO getCurrentTime
      }
{-# NOINLINE assistant #-}

-- | Build a tool-result message answering a prior 'AssistantToolCall'
-- using rich content blocks.
toolResultMessage :: Text -> Text -> ToolResult -> Message
toolResultMessage callId name ToolResult {content = blocks, isError = err} =
  ToolResultMessage
    ToolResultPayload
      { toolCallId = callId,
        toolName = name,
        content = blocks,
        isError = err,
        timestamp = unsafePerformIO getCurrentTime
      }
{-# NOINLINE toolResultMessage #-}

-- | Build a rich tool-result message from the original tool call.
toolResultFromCall :: ToolCall -> ToolResult -> Message
toolResultFromCall ToolCall {id_ = callId, name = toolName} =
  toolResultMessage callId toolName

-- | Build a one-text-block tool-result message. This is the
-- text-only compatibility shorthand; prefer 'toolResultMessage'
-- when the result has multiple blocks or image content.
toolResult :: Text -> Text -> Text -> Bool -> Message
toolResult callId name body err =
  toolResultMessage
    callId
    name
    ToolResult
      { content = V.singleton (ToolResultText (TextContent body)),
        isError = err
      }

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
