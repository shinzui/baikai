-- | Internal helpers shared by the CLI providers in @baikai-claude@
-- and @baikai-openai@.
--
-- Not re-exported from "Baikai"; vendor packages import this module
-- directly. This is an internal interface and is not covered by PVP
-- stability guarantees: names, types, and semantics may change in
-- minor releases. Application code should use the public provider
-- modules instead.
module Baikai.Provider.Cli.Internal
  ( renderPrompt,
    wrapSystemPrompt,
    maybeApply,
    decodeUtf8Lenient,
    extractAgentMessage,
    parseCodexJsonlStream,
    argvEnvelope,
  )
where

import Baikai.Content
  ( AssistantContent (..),
    TextContent (..),
    ToolResultContent (..),
    UserContent (..),
  )
import Baikai.Context (Context)
import Baikai.Message
  ( AssistantPayload (..),
    Message (..),
    ToolResultPayload (..),
    UserPayload (..),
  )
import Control.Lens ((^.))
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseMaybe, (.:?))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Unfold qualified as Unfold

-- | Flatten a 'Context'\'s messages into a single prompt string
-- suitable for a one-shot CLI invocation.
--
-- A context whose only message is a 'UserMessage' with a single
-- 'UserText' block is returned verbatim. Anything else is joined
-- with @[role]:@ markers so the CLI still sees a coherent
-- transcript. Image content and tool calls are dropped (CLI
-- providers do not participate in tool use; image bytes cannot be
-- passed verbatim through a CLI). The masterplan documents CLI
-- providers as text-only and tool-incapable.
renderPrompt :: Context -> Text
renderPrompt ctx =
  let msgs = Vector.toList (ctx ^. #messages)
   in case msgs of
        [UserMessage UserPayload {content = uc}]
          | [UserText (TextContent t)] <- Vector.toList uc ->
              t
        _ -> Text.intercalate "\n" (fmap tag msgs)
  where
    tag :: Message -> Text
    tag (UserMessage UserPayload {content = uc}) =
      "[user]: " <> flattenUser uc
    tag (AssistantMessage AssistantPayload {content = ac}) =
      "[assistant]: " <> flattenAssistant ac
    tag (ToolResultMessage ToolResultPayload {toolName = n, content = trc}) =
      "[tool:" <> n <> "]: " <> flattenToolResult trc

    flattenUser :: Vector UserContent -> Text
    flattenUser = Text.concat . Vector.toList . Vector.mapMaybe pickU
      where
        pickU (UserText (TextContent t)) = Just t
        pickU _ = Nothing

    flattenAssistant :: Vector AssistantContent -> Text
    flattenAssistant = Text.concat . Vector.toList . Vector.mapMaybe pickA
      where
        pickA (AssistantText (TextContent t)) = Just t
        pickA _ = Nothing

    flattenToolResult :: Vector ToolResultContent -> Text
    flattenToolResult = Text.concat . Vector.toList . Vector.mapMaybe pickT
      where
        pickT (ToolResultText (TextContent t)) = Just t
        pickT _ = Nothing

-- | Wrap a rendered prompt with a system-instruction preamble for
-- CLIs that expose no native system-prompt flag. 'Nothing' and
-- blank system prompts return the body unchanged. The textual
-- format is shared by the codex batch provider and the codex
-- interactive launcher.
wrapSystemPrompt :: Maybe Text -> Text -> Text
wrapSystemPrompt msp body = case Text.strip <$> msp of
  Nothing -> body
  Just "" -> body
  Just sp ->
    Text.concat
      [ "System instructions:\n",
        sp,
        "\n\nUser request:\n",
        body
      ]

-- | @maybeApply ma f x@ applies @f a x@ when @ma = Just a@,
-- otherwise returns @x@. Useful for threading optional configuration
-- into a cradle pipeline.
maybeApply :: Maybe a -> (a -> b -> b) -> b -> b
maybeApply Nothing _ b = b
maybeApply (Just a) f b = f a b

-- | Decode UTF-8 bytes leniently, replacing invalid sequences with
-- U+FFFD. Used for surfacing CLI stderr in a
-- 'Baikai.Error.ProcessFailure' error.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = Text.decodeUtf8With Text.lenientDecode

-- | Best-effort extractor for the assistant text inside a single
-- Codex @--json@ event. See the original implementation's
-- documentation for the schema variants accepted.
extractAgentMessage :: Value -> Maybe Text
extractAgentMessage = parseMaybe parser
  where
    parser = Aeson.withObject "codex-event" $ \o -> do
      mItem <- o .:? "item"
      case (mItem :: Maybe Value) of
        Just (Aeson.Object io) -> do
          ty <- io .:? "type"
          case (ty :: Maybe Text) of
            Just "agent_message" -> pickText io
            _ -> tryMsg o
        _ -> tryMsg o

    tryMsg o = do
      mInner <- o .:? "msg"
      case (mInner :: Maybe Value) of
        Just (Aeson.Object io) -> do
          ty <- io .:? "type"
          case (ty :: Maybe Text) of
            Just "agent_message" -> pickText io
            _ -> fail "not an agent_message"
        _ -> tryFlat o

    tryFlat o = do
      ty <- o .:? "type"
      case (ty :: Maybe Text) of
        Just "agent_message" -> pickText o
        _ -> fail "not an agent_message"

    pickText o = case KeyMap.lookup "message" o of
      Just (Aeson.String t) -> pure t
      _ -> case KeyMap.lookup "text" o of
        Just (Aeson.String t) -> pure t
        _ -> fail "no payload"

-- | Consume a stream of stdout bytes from @codex exec --json@,
-- split on newlines, decode each line as JSON, filter to
-- @agent_message@ events, and return the concatenation of their
-- payloads.
parseCodexJsonlStream :: Stream IO ByteString -> IO Text
parseCodexJsonlStream chunks = do
  let bytes :: Stream IO Word8
      bytes = Stream.unfoldEach Unfold.fromList (fmap BS.unpack chunks)
      lineFold = Fold.takeEndBy_ (== newlineByte) (Fold.foldl' BS.snoc BS.empty)
  msgs <-
    Stream.foldMany lineFold bytes
      & Stream.mapMaybe Aeson.decodeStrict
      & Stream.mapMaybe extractAgentMessage
      & Stream.fold Fold.toList
  pure (Text.concat msgs)

newlineByte :: Word8
newlineByte = 0x0a

-- | The request envelope a subprocess provider hands to
-- 'Baikai.Evidence.Build.minimalEvidence': the rendered argument
-- vector, executable first, as a JSON array of strings.
--
-- This is the subprocess analogue of an API provider's request body,
-- and it is genuinely what crossed the boundary — there is no other
-- description of a process launch.
--
-- Both CLI providers place the prompt inside this vector, so
-- 'Baikai.Evidence.commitmentDigest' over it legitimately commits to
-- the prompt. 'Baikai.Evidence.configurationDigest' does not: its
-- projection admits named fields from an object and a JSON array has
-- none, so an argv envelope projects to @null@ and the configuration
-- digest reveals nothing about the command line at all. That is the
-- allow-list failing in the safe direction, which is what it is for.
argvEnvelope :: FilePath -> [String] -> Value
argvEnvelope exe args =
  Aeson.toJSON (map Text.pack (exe : args))
