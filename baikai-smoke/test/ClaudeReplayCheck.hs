-- | Compare the signed blocks in a tool response to its actual follow-up body.
module ClaudeReplayCheck (signedBlocks, matchesSignedReplay) where

import Baikai.Content (AssistantContent (..))
import Baikai.Response (Response, flattenAssistantBlocks)
import Control.Lens ((^.))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector

signedBlocks :: Response -> [(Int, Value)]
signedBlocks response =
  [ (index, object ["type" .= String "thinking", "thinking" .= (block ^. #thinking), "signature" .= signature])
  | (index, AssistantThinking block) <- zip [0 ..] (Vector.toList (flattenAssistantBlocks response)),
    not (block ^. #redacted),
    Just signature <- [block ^. #signature],
    not (Text.null signature)
  ]

-- The adapter appends one user message per tool result immediately after the
-- assistant turn. Match their IDs before comparing the assistant content.
matchesSignedReplay :: [Text] -> [(Int, Value)] -> Value -> Bool
matchesSignedReplay toolIds expected requestBody =
  case field "messages" requestBody of
    Just (Array messages) ->
      let (prefix, results) = Vector.splitAt (Vector.length messages - length toolIds) messages
       in case Vector.unsnoc prefix of
            Just (_, assistant) ->
              not (null toolIds)
                && traverse toolResultId (Vector.toList results) == Just toolIds
                && field "role" assistant == Just (String "assistant")
                && case field "content" assistant of
                  Just (Array content) ->
                    [(index, block) | (index, block) <- zip [0 ..] (Vector.toList content), isSigned block] == expected
                  _ -> False
            Nothing -> False
    _ -> False
  where
    field key (Object fields) = KeyMap.lookup key fields
    field _ _ = Nothing
    isSigned block = case (field "type" block, field "signature" block) of
      (Just (String "thinking"), Just (String signature)) -> not (Text.null signature)
      _ -> False
    toolResultId message
      | Just (String "user") <- field "role" message,
        Just (Array content) <- field "content" message,
        [block] <- Vector.toList content,
        Just (String "tool_result") <- field "type" block,
        Just (String ident) <- field "tool_use_id" block =
          Just ident
      | otherwise = Nothing
