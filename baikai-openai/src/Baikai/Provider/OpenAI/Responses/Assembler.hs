{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | Internal Responses item assembly; no stability guarantee. The wire
-- schema is wider than the released SDK's streaming sum (see
-- mori://MercuryTechnologies/openai/packages/openai), so inspect JSON at
-- this boundary and preserve reasoning snapshots without re-encoding.
module Baikai.Provider.OpenAI.Responses.Assembler
  ( Assembler,
    emptyAssembler,
    advance,
    closePartial,
    assembledContent,
    observedResponse,
    terminalReason,
  )
where

import Baikai.Api (Api (OpenAIResponses))
import Baikai.Content qualified as C
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event qualified as E
import Control.Monad (foldM, unless)
import Data.Aeson (Value (..))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.IntMap.Strict qualified as IM
import Data.IntSet qualified as IS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

-- No Show: items can contain opaque encrypted continuation.
data Item = Item
  { kind :: !Text,
    identity :: !Text,
    callId :: !Text,
    functionName :: !Text,
    parts :: !(IM.IntMap Text),
    endedParts :: !IS.IntSet,
    complete :: !Bool,
    snapshot :: !(Maybe Value)
  }

data Assembler = Assembler
  { scopeModel :: !Text,
    items :: !(IM.IntMap Item),
    cursor :: !Int,
    opened :: !Bool,
    emitted :: !Text,
    assembledContent :: !(V.Vector C.AssistantContent),
    -- | Actual provider response object, including raw usage availability.
    observedResponse :: !(Maybe Value),
    terminalReason :: !(Maybe StopReason)
  }

emptyAssembler :: Text -> Assembler
emptyAssembler m = Assembler m IM.empty 0 False "" V.empty Nothing Nothing

-- | Consume one JSON event. Errors contain only schema diagnostics, never
-- raw response bodies. The caller closes partial blocks and emits the
-- terminal error on Left. Lifecycle terminal events are emitted by the
-- owning stream after attaching usage and evidence.
advance :: Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
advance frame a
  | Just _ <- a.terminalReason = Right (a, [])
  | otherwise = do
      typ <- str "type" frame
      case typ of
        "response.created" -> observe frame a
        "response.in_progress" -> observe frame a
        "response.queued" -> observe frame a
        "response.output_item.added" -> do
          n <- index "output_index" frame
          raw <- field "item" frame
          item <- fromSnapshot False raw
          unless (IM.notMember n a.items && n >= a.cursor) (Left "Responses repeated output item")
          unless (all ((/= item.identity) . (.identity)) (IM.elems a.items)) (Left "Responses duplicate item ID")
          pump a {items = IM.insert n item a.items}
        "response.output_item.done" -> do
          n <- index "output_index" frame
          raw <- field "item" frame
          updated <- mergeSnapshot n True raw a
          pump updated
        "response.output_text.delta" -> delta "message" "content_index" frame a
        "response.refusal.delta" -> delta "message" "content_index" frame a
        "response.reasoning_summary_text.delta" -> delta "reasoning" "summary_index" frame a
        "response.function_call_arguments.delta" -> delta "function_call" "" frame a
        "response.output_text.done" -> donePart "message" "content_index" "text" frame a
        "response.refusal.done" -> donePart "message" "content_index" "refusal" frame a
        "response.reasoning_summary_text.done" -> donePart "reasoning" "summary_index" "text" frame a
        "response.function_call_arguments.done" -> donePart "function_call" "" "arguments" frame a
        "response.content_part.added" -> partEvent False "message" "content_index" frame a
        "response.content_part.done" -> partEvent True "message" "content_index" frame a
        "response.reasoning_summary_part.added" -> partEvent False "reasoning" "summary_index" frame a
        "response.reasoning_summary_part.done" -> partEvent True "reasoning" "summary_index" frame a
        "response.completed" -> terminal Stop frame a
        "response.incomplete" -> do
          response <- field "response" frame
          details <- field "incomplete_details" response
          reason <- str "reason" details
          unless (reason == "max_output_tokens") (Left "Responses terminated incomplete for a reason other than max_output_tokens")
          terminal Length frame a
        "response.failed" -> Left "Responses response.failed"
        "error" -> Left "Responses error event"
        -- Annotations and reasoning details do not change the public text
        -- or continuation. New output kinds are rejected at item creation.
        _ -> Right (a, [])

observe :: Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
observe f a = do
  r <- field "response" f
  pure (a {observedResponse = Just r}, [])

terminal :: StopReason -> Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
terminal reason f a = do
  r <- field "response" f
  output <- array "output" r
  updated <- foldM (\s (n, raw) -> mergeSnapshot n True raw s) a (zip [0 ..] (V.toList output))
  unless (IM.size updated.items == V.length output) (Left "Responses terminal output omitted an existing item")
  (drained, events) <- pump updated {observedResponse = Just r}
  unless (drained.cursor == IM.size drained.items) (Left "Responses terminal output has a gap")
  let hasTool = any (\case C.AssistantToolCall _ -> True; _ -> False) drained.assembledContent
      stop = if reason == Stop && hasTool then ToolUse else reason
  pure (drained {terminalReason = Just stop}, events)

fromSnapshot :: Bool -> Value -> Either Text Item
fromSnapshot final raw = do
  k <- str "type" raw
  ident <- nonempty "id" raw
  (call, name, ps) <- case k of
    "message" -> do
      cs <- array "content" raw
      texts <- traverse partText (V.toList cs)
      pure ("", "", IM.fromList (zip [0 ..] texts))
    "reasoning" -> do
      cs <- array "summary" raw
      texts <- traverse partText (V.toList cs)
      pure ("", "", IM.fromList (zip [0 ..] texts))
    "function_call" -> do
      call <- nonempty "call_id" raw
      name <- nonempty "name" raw
      args <- str "arguments" raw
      pure (call, name, IM.singleton 0 args)
    _ -> Left "Responses unsupported output item type"
  pure (Item k ident call name ps (if final then IS.fromList (IM.keys ps) else IS.empty) final (if final then Just raw else Nothing))

mergeSnapshot :: Int -> Bool -> Value -> Assembler -> Either Text Assembler
mergeSnapshot n final raw a = do
  new <- fromSnapshot final raw
  case IM.lookup n a.items of
    Nothing -> do
      unless (n >= a.cursor && all ((/= new.identity) . (.identity)) (IM.elems a.items)) (Left "Responses duplicate item ID")
      pure a {items = IM.insert n new a.items}
    Just old -> do
      unless (old.kind == new.kind && old.identity == new.identity && old.callId == new.callId && old.functionName == new.functionName) (Left "Responses item identity changed")
      unless (not old.complete || old.snapshot == Just raw) (Left "Responses completed item changed")
      mapM_ (\(p, t) -> unless (maybe False (T.isPrefixOf t) (IM.lookup p new.parts)) (Left "Responses final snapshot contradicts streamed content")) (IM.toList old.parts)
      pure a {items = IM.insert n new a.items}

partText :: Value -> Either Text Text
partText p = do
  k <- str "type" p
  case k of
    "output_text" -> str "text" p
    "summary_text" -> str "text" p
    "refusal" -> str "refusal" p
    _ -> Left "Responses unsupported output content part"

itemAt :: Text -> Value -> Assembler -> Either Text (Int, Item)
itemAt expected f a = do
  n <- index "output_index" f
  ident <- str "item_id" f
  item <- maybe (Left "Responses delta before output item") Right (IM.lookup n a.items)
  unless (item.kind == expected && item.identity == ident) (Left "Responses delta item identity mismatch")
  pure (n, item)

partIndex :: Key -> Value -> Either Text Int
partIndex "" _ = Right 0
partIndex key f = index key f

delta :: Text -> Key -> Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
delta k key f a = do
  (n, item) <- itemAt k f a
  p <- partIndex key f
  txt <- str "delta" f
  unless (not item.complete && not (IS.member p item.endedParts)) (Left "Responses delta after content done")
  let ps = IM.insert p (IM.findWithDefault "" p item.parts <> txt) item.parts
  pump a {items = IM.insert n item {parts = ps} a.items}

donePart :: Text -> Key -> Key -> Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
donePart k key txtKey f a = do
  txt <- str txtKey f
  setPart True k key txt f a

partEvent :: Bool -> Text -> Key -> Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
partEvent final k key f a = do
  p <- field "part" f
  txt <- partText p
  setPart final k key txt f a

setPart :: Bool -> Text -> Key -> Text -> Value -> Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
setPart final k key txt f a = do
  (n, item) <- itemAt k f a
  p <- partIndex key f
  let old = IM.findWithDefault "" p item.parts
  unless (old `T.isPrefixOf` txt && (not (item.complete || IS.member p item.endedParts) || old == txt)) (Left "Responses part snapshot contradicts streamed content")
  let updated = item {parts = IM.insert p txt item.parts, endedParts = if final then IS.insert p item.endedParts else item.endedParts}
  pump a {items = IM.insert n updated a.items}

-- Only the contiguous prefix is visible: a later parallel item or content
-- part cannot overtake the one still streaming. One Baikai block per item.
visible :: Item -> Text
visible item = go 0
  where
    go n = case IM.lookup n item.parts of
      Nothing -> ""
      Just txt -> txt <> if item.complete || IS.member n item.endedParts then go (n + 1) else ""

pump :: Assembler -> Either Text (Assembler, [E.AssistantMessageEvent])
pump a = case IM.lookup a.cursor a.items of
  Nothing -> Right (a, [])
  Just item -> do
    let txt = visible item
        n = V.length a.assembledContent
    unless (a.emitted `T.isPrefixOf` txt) (Left "Responses snapshot changed emitted content")
    let suffix = T.drop (T.length a.emitted) txt
        start = if a.opened then [] else [startEvent item.kind n]
        deltas = if T.null suffix then [] else [deltaEvent item.kind n suffix]
        openedState = a {opened = True, emitted = txt}
    if item.complete
      then do
        let content = itemContent a.scopeModel True item
            closed = openedState {cursor = a.cursor + 1, opened = False, emitted = "", assembledContent = V.snoc a.assembledContent content}
        (next, events) <- pump closed
        pure (next, start <> deltas <> [endEvent n content] <> events)
      else pure (openedState, start <> deltas)

-- | Close an interrupted stream, retaining every observed item. An item
-- without output_item.done keeps String arguments even when that prefix
-- happens to be parseable JSON; callers must never execute that prefix.
closePartial :: Assembler -> (Assembler, [E.AssistantMessageEvent])
closePartial a = foldl close (a, []) [(n, i) | (n, i) <- IM.toAscList a.items, n >= a.cursor]
  where
    close (s, events) (outputIndex, item) =
      let n = V.length s.assembledContent
          txt = T.concat (IM.elems item.parts)
          suffix = if s.emitted `T.isPrefixOf` txt then T.drop (T.length s.emitted) txt else ""
          content = itemContent s.scopeModel item.complete item
          starts = if s.opened then [] else [startEvent item.kind n]
          deltas = if T.null suffix then [] else [deltaEvent item.kind n suffix]
       in (s {cursor = outputIndex + 1, opened = False, emitted = "", assembledContent = V.snoc s.assembledContent content}, events <> starts <> deltas <> [endEvent n content])

itemContent :: Text -> Bool -> Item -> C.AssistantContent
itemContent m final item =
  let txt = T.concat (IM.elems item.parts)
   in case item.kind of
        "reasoning" -> C.AssistantThinking (C.ThinkingContent txt Nothing False (fmap (C.ThinkingReplay OpenAIResponses m . V.singleton) item.snapshot))
        "function_call" -> C.AssistantToolCall (C.ToolCall item.callId item.functionName (if final && completedStatus item.snapshot then C.toolArgumentsFromText txt else String txt))
        _ -> C.AssistantText (C.TextContent txt)

completedStatus :: Maybe Value -> Bool
completedStatus (Just (Object o)) = case KM.lookup "status" o of
  Nothing -> True -- output_item.done itself supplies completion.
  Just (String "completed") -> True
  _ -> False
completedStatus _ = False

startEvent :: Text -> Int -> E.AssistantMessageEvent
startEvent "reasoning" n = E.ThinkingStart (E.IndexPayload n)
startEvent "function_call" n = E.ToolCallStart (E.IndexPayload n)
startEvent _ n = E.TextStart (E.IndexPayload n)

deltaEvent :: Text -> Int -> Text -> E.AssistantMessageEvent
deltaEvent "reasoning" n txt = E.ThinkingDelta (E.DeltaPayload n txt)
deltaEvent "function_call" n txt = E.ToolCallDelta (E.DeltaPayload n txt)
deltaEvent _ n txt = E.TextDelta (E.DeltaPayload n txt)

endEvent :: Int -> C.AssistantContent -> E.AssistantMessageEvent
endEvent n (C.AssistantThinking c) = E.ThinkingEnd (E.ThinkingEndPayload n c)
endEvent n (C.AssistantToolCall c) = E.ToolCallEnd (E.ToolCallEndPayload n c)
endEvent n (C.AssistantText c) = E.TextEnd (E.BlockEndPayload n c.text)

field :: Key -> Value -> Either Text Value
field k (Object o) = maybe (Left "Responses missing required event field") Right (KM.lookup k o)
field _ _ = Left "Responses event field must be an object"

str :: Key -> Value -> Either Text Text
str k v = field k v >>= \case String t -> Right t; _ -> Left "Responses event field must be text"

nonempty :: Key -> Value -> Either Text Text
nonempty k v = do
  t <- str k v
  unless (not (T.null t)) (Left "Responses item identity must be nonempty")
  pure t

array :: Key -> Value -> Either Text (V.Vector Value)
array k v = field k v >>= \case Array xs -> Right xs; _ -> Left "Responses event field must be an array"

index :: Key -> Value -> Either Text Int
index k v =
  field k v >>= \case
    Number n | n >= 0, n <= fromIntegral (maxBound :: Int), fromInteger (floor n) == n -> Right (floor n)
    _ -> Left "Responses event index must be a nonnegative integer"
