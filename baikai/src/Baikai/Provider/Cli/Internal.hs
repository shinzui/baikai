-- | Internal helpers shared by the CLI providers in @baikai-claude@ and
-- @baikai-openai@.
--
-- Not re-exported from "Baikai"; vendor packages import this module directly.
-- Anything exported here is considered part of the core library's interface
-- to the CLI provider packages and should not be relied on by application
-- code.
module Baikai.Provider.Cli.Internal
  ( renderPrompt
  , maybeApply
  , decodeUtf8Lenient
  , extractAgentMessage
  , parseCodexJsonlStream
  ) where

import qualified Baikai.Message as Msg
import qualified Baikai.Request as Req
import Control.Lens ((^.))
import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseMaybe, (.:?))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import qualified Data.Vector as Vector
import Data.Word (Word8)
import qualified Streamly.Data.Fold as Fold
import Streamly.Data.Stream (Stream)
import qualified Streamly.Data.Stream as Stream
import qualified Streamly.Data.Unfold as Unfold

-- | Flatten 'Req.Request.messages' into a single prompt string suitable for a
-- one-shot CLI invocation.
--
-- A request with exactly one 'Msg.User' message is returned verbatim. Anything
-- else is joined with @[role]:@ markers so the CLI still sees a coherent
-- transcript. EP-3 documents this as a deliberate simplification: first-class
-- multi-turn support belongs in a later ExecPlan.
renderPrompt :: Req.Request -> Text
renderPrompt req =
  let msgs = Vector.toList (req ^. #messages)
      tag m = case m ^. #role of
        Msg.User -> "[user]: " <> m ^. #content
        Msg.Assistant -> "[assistant]: " <> m ^. #content
        Msg.System -> "[system]: " <> m ^. #content
   in case msgs of
        [m] | m ^. #role == Msg.User -> m ^. #content
        _ -> Text.intercalate "\n" (fmap tag msgs)

-- | @maybeApply ma f x@ applies @f a x@ when @ma = Just a@, otherwise returns
-- @x@. Useful for threading optional configuration into a cradle pipeline.
maybeApply :: Maybe a -> (a -> b -> b) -> b -> b
maybeApply Nothing _ b = b
maybeApply (Just a) f b = f a b

-- | Decode UTF-8 bytes leniently, replacing invalid sequences with U+FFFD.
-- Used for surfacing CLI stderr in 'Baikai.Error.ProcessError'.
decodeUtf8Lenient :: ByteString -> Text
decodeUtf8Lenient = Text.decodeUtf8With Text.lenientDecode

-- | Best-effort extractor for the assistant text inside a single Codex
-- @--json@ event.
--
-- The Codex JSONL schema has varied across releases, so the parser tries
-- multiple shapes:
--
-- 1. @{"type":"item.completed","item":{"type":"agent_message","text":"..."}}@
--    (current default, codex-cli 0.13x+).
-- 2. @{"msg":{"type":"agent_message","message":"..."}}@ (older releases).
-- 3. @{"msg":{"type":"agent_message","text":"..."}}@ (older releases).
-- 4. @{"type":"agent_message","message":"..."}@ (very early releases).
-- 5. @{"type":"agent_message","text":"..."}@ (very early releases).
--
-- Any event whose discriminator is not @agent_message@ is dropped. If the
-- payload field is missing the event is also dropped rather than producing
-- an empty string.
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

-- | Consume a stream of stdout bytes from @codex exec --json@, split on
-- newlines, decode each line as JSON, filter to @agent_message@ events, and
-- return the concatenation of their payloads.
--
-- Streaming: memory usage stays flat in response length. Lines that fail to
-- decode as JSON, or whose schema does not match 'extractAgentMessage', are
-- silently skipped.
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
