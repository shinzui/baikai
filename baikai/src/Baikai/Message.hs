-- | The conversation message ADT.
--
-- A 'Message' is one of three constructors:
--
-- * 'UserMessage' — caller input. Carries 'userContent' (a vector of
--   text and inline image blocks) and a creation timestamp.
-- * 'AssistantMessage' — model output. Carries 'assistantContent'
--   ('AssistantText', 'AssistantThinking', 'AssistantToolCall'), the
--   call's 'Usage' (which now embeds 'Cost' in-place), the 'StopReason'
--   the model reported, an optional 'errorMessage', and a timestamp.
-- * 'ToolResultMessage' — caller-supplied output for a model-issued
--   tool call. Carries the tool-call id it answers, the tool's name,
--   'toolResultContent' (text or image), an 'isError' flag, and a
--   timestamp.
--
-- The 'system' constructor from prior versions is removed: system
-- prompts live on 'Baikai.Request.Request.systemPrompt'. The 'Role'
-- enum is also removed — pattern-match on the constructor instead.
--
-- Per-constructor content fields are named distinctly
-- ('userContent', 'assistantContent', 'toolResultContent') rather than
-- a shared 'content'. GHC's @DuplicateRecordFields@ does not permit a
-- single data declaration to give the same field name different types
-- across constructors, so giving each constructor a unique name is the
-- least-friction encoding. The masterplan's Integration Points section
-- documents the sketch with a shared 'content' field, which this
-- module's Decision Log diverges from.
module Baikai.Message
  ( Message (..)
  , user
  , userImage
  , assistant
  , toolResult
  ) where

import Baikai.Content
  ( AssistantContent (..)
  , ImageContent
  , TextContent (TextContent)
  , ToolResultContent (..)
  , UserContent (..)
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
  = UserMessage
      { userContent :: !(Vector UserContent)
      , timestamp :: !UTCTime
      }
  | AssistantMessage
      { assistantContent :: !(Vector AssistantContent)
      , usage :: !Usage
      , stopReason :: !StopReason
      , errorMessage :: !(Maybe Text)
      , timestamp :: !UTCTime
      }
  | ToolResultMessage
      { toolCallId :: !Text
      , toolName :: !Text
      , toolResultContent :: !(Vector ToolResultContent)
      , isError :: !Bool
      , timestamp :: !UTCTime
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
    { userContent = V.singleton (UserText (TextContent t))
    , timestamp = unsafePerformIO getCurrentTime
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
        { userContent = prefix <> V.singleton (UserImage img)
        , timestamp = unsafePerformIO getCurrentTime
        }
{-# NOINLINE userImage #-}

-- | Build a one-text-block assistant message with zero usage and a
-- @stop@ stop reason. Useful for fixtures and replaying prior turns
-- into a follow-up request.
assistant :: Text -> Message
assistant t =
  AssistantMessage
    { assistantContent = V.singleton (AssistantText (TextContent t))
    , usage = _Usage
    , stopReason = Stop
    , errorMessage = Nothing
    , timestamp = unsafePerformIO getCurrentTime
    }
{-# NOINLINE assistant #-}

-- | Build a tool-result message answering a prior 'AssistantToolCall'.
-- @body@ becomes a single 'ToolResultText' block; pass an empty string
-- when the tool produced only image bytes and build the record by hand.
toolResult :: Text -> Text -> Text -> Bool -> Message
toolResult callId name body err =
  ToolResultMessage
    { toolCallId = callId
    , toolName = name
    , toolResultContent = V.singleton (ToolResultText (TextContent body))
    , isError = err
    , timestamp = unsafePerformIO getCurrentTime
    }
{-# NOINLINE toolResult #-}
