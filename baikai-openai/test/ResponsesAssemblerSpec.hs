{-# LANGUAGE OverloadedRecordDot #-}

module ResponsesAssemblerSpec (tests) where

import Baikai.Content qualified as C
import Baikai.Provider.OpenAI.Responses.Assembler qualified as A
import Baikai.StopReason (StopReason (..))
import Baikai.Stream.Event qualified as E
import Control.Monad (foldM)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Text (Text)
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses assembler"
    [ testCase "streams text immediately and reconciles snapshots without duplication" $ do
        (s, events) <- run [added 0 (message ""), textDelta 0 0 "hello"]
        events @?= [E.TextStart (E.IndexPayload 0), E.TextDelta (E.DeltaPayload 0 "hello")]
        (done, rest) <- step (completed [message "hello world"]) s
        rest @?= [E.TextDelta (E.DeltaPayload 0 " world"), E.TextEnd (E.BlockEndPayload 0 "hello world")]
        A.assembledContent done @?= V.singleton (C.AssistantText (C.TextContent "hello world"))
        A.terminalReason done @?= Just Stop
        (_, again) <- step (completed [message "hello world"]) done
        again @?= [],
      testCase "parallel function calls retain call IDs and serialize blocks" $ do
        (s, events) <-
          run
            [ added 0 (call "item_a" "call_a" "" "in_progress"),
              added 1 (call "item_b" "call_b" "" "in_progress"),
              argDelta 1 "item_b" "{\"b\":2}",
              argDelta 0 "item_a" "{\"a\":1}",
              itemDone 1 (call "item_b" "call_b" "{\"b\":2}" "completed"),
              itemDone 0 (call "item_a" "call_a" "{\"a\":1}" "completed"),
              completed [call "item_a" "call_a" "{\"a\":1}" "completed", call "item_b" "call_b" "{\"b\":2}" "completed"]
            ]
        A.terminalReason s @?= Just ToolUse
        A.assembledContent s
          @?= V.fromList
            [C.AssistantToolCall (C.ToolCall "call_a" "lookup" (object ["a" .= (1 :: Int)])), C.AssistantToolCall (C.ToolCall "call_b" "lookup" (object ["b" .= (2 :: Int)]))]
        [n | E.ToolCallStart (E.IndexPayload n) <- events] @?= [0, 1]
        [n | E.ToolCallEnd (E.ToolCallEndPayload n _) <- events] @?= [0, 1]
        assertBool "second block waits for first end" (case drop 2 events of E.ToolCallEnd _ : E.ToolCallStart _ : _ -> True; _ -> False),
      testCase "empty summary retains the entire encrypted reasoning item" $ do
        (s, _) <- run [added 0 reasoningAdded, itemDone 0 reasoning, completed [reasoning]]
        case V.toList (A.assembledContent s) of
          [C.AssistantThinking t] -> do
            t.thinking @?= ""
            fmap (.replayItems) t.replayState @?= Just (V.singleton reasoning)
            fmap (.replayModel) t.replayState @?= Just "configured-model"
          _ -> assertFailure "missing thinking block",
      testCase "later content parts wait for earlier parts and final snapshots fill gaps" $ do
        (s, _) <- run [added 0 (message ""), textDelta 0 1 "second", textDelta 0 0 "first"]
        let final = object ["type" .= ("message" :: Text), "id" .= ("msg" :: Text), "content" .= [part "first", part "second"]]
        (done, events) <- step (completed [final]) s
        events @?= [E.TextDelta (E.DeltaPayload 0 "second"), E.TextEnd (E.BlockEndPayload 0 "firstsecond")]
        A.assembledContent done @?= V.singleton (C.AssistantText (C.TextContent "firstsecond")),
      testCase "interrupted parseable function prefix stays cut off" $ do
        (s, _) <- run [added 0 (call "item_a" "call_a" "" "in_progress"), argDelta 0 "item_a" "{}"]
        let (closed, _) = A.closePartial s
        A.assembledContent closed @?= V.singleton (C.AssistantToolCall (C.ToolCall "call_a" "lookup" (String "{}"))),
      testCase "incomplete response does not turn a truncated call into executable JSON" $ do
        let item = call "item_a" "call_a" "{}" "incomplete"
        (s, _) <- run [frame "response.incomplete" ["response" .= object ["output" .= [item], "incomplete_details" .= object ["reason" .= ("max_output_tokens" :: Text)]]]]
        A.terminalReason s @?= Just Length
        A.assembledContent s @?= V.singleton (C.AssistantToolCall (C.ToolCall "call_a" "lookup" (String "{}"))),
      testCase "contradictory snapshots and wrong item identities fail" $ do
        (s, _) <- run [added 0 (message ""), textDelta 0 0 "prefix"]
        rejects (completed [message "replacement"]) s
        rejects (argDelta 0 "wrong" "secret") s
        rejects (added 1 (message "")) s,
      testCase "part done snapshots and item done snapshots never repeat text" $ do
        let textDone = frame "response.output_text.done" ["output_index" .= (0 :: Int), "item_id" .= ("msg" :: Text), "content_index" .= (0 :: Int), "text" .= ("hello" :: Text)]
        (s, events) <- run [added 0 (message ""), textDelta 0 0 "hel", textDone, textDone, itemDone 0 (message "hello"), completed [message "hello"]]
        [t | E.TextDelta (E.DeltaPayload _ t) <- events] @?= ["hel", "lo"]
        A.terminalReason s @?= Just Stop,
      testCase "reasoning summaries stream while encrypted state stays out of deltas" $ do
        let summary = object ["type" .= ("summary_text" :: Text), "text" .= ("consider" :: Text)]
            raw = object ["type" .= ("reasoning" :: Text), "id" .= ("rs" :: Text), "summary" .= [summary], "encrypted_content" .= ("opaque" :: Text)]
            d = frame "response.reasoning_summary_text.delta" ["output_index" .= (0 :: Int), "item_id" .= ("rs" :: Text), "summary_index" .= (0 :: Int), "delta" .= ("consider" :: Text)]
        (s, events) <- run [added 0 reasoningAdded, d, completed [raw]]
        [t | E.ThinkingDelta (E.DeltaPayload _ t) <- events] @?= ["consider"]
        case V.toList (A.assembledContent s) of
          [C.AssistantThinking t] -> fmap (.replayItems) t.replayState @?= Just (V.singleton raw)
          _ -> assertFailure "missing summary",
      testCase "partial text closes with its observed prefix" $ do
        (s, _) <- run [added 0 (message ""), textDelta 0 0 "partial"]
        let (closed, events) = A.closePartial s
        events @?= [E.TextEnd (E.BlockEndPayload 0 "partial")]
        A.assembledContent closed @?= V.singleton (C.AssistantText (C.TextContent "partial"))
        let (_, repeated) = A.closePartial closed
        repeated @?= [],
      testCase "terminal retains exact observed usage including absent cache-write field" $ do
        let raw = object ["id" .= ("r" :: Text), "model" .= ("observed" :: Text), "output" .= [message "ok"], "usage" .= object ["input_tokens" .= (20 :: Int), "input_tokens_details" .= object ["cached_tokens" .= (10 :: Int)]]]
        (s, _) <- run [frame "response.completed" ["response" .= raw]]
        A.observedResponse s @?= Just raw,
      testCase "duplicate call IDs cannot masquerade as separate tool calls" $ do
        (s, _) <- run [added 0 (call "item_a" "same_call" "" "in_progress")]
        rejects (added 1 (call "item_b" "same_call" "" "in_progress")) s
        rejects (completed [call "item_a" "same_call" "{}" "completed", call "item_b" "same_call" "{}" "completed"]) s,
      testCase "successful reasoning must carry replayable continuation" $ do
        rejects (completed [reasoningAdded]) (A.emptyAssembler "m"),
      testCase "failure and malformed frames remain failures" $ do
        mapM_
          (\f -> rejects f (A.emptyAssembler "m"))
          [frame "response.failed" [], frame "error" [], object [], added (-1) (message ""), completed [object ["type" .= ("web_search_call" :: Text), "id" .= ("w" :: Text)]]]
    ]

run :: [Value] -> IO (A.Assembler, [E.AssistantMessageEvent])
run = foldM (\(s, es) f -> do (next, events) <- step f s; pure (next, es <> events)) (A.emptyAssembler "configured-model", [])

step :: Value -> A.Assembler -> IO (A.Assembler, [E.AssistantMessageEvent])
step f s = either (\e -> assertFailure (show e) >> fail "assembly failed") pure (A.advance f s)

rejects :: Value -> A.Assembler -> IO ()
rejects f s = case A.advance f s of Left _ -> pure (); Right _ -> assertFailure "expected schema rejection"

frame :: Text -> [(Key, Value)] -> Value
frame t fields = object (("type" .= t) : fields)

added :: Int -> Value -> Value
added n item = frame "response.output_item.added" ["output_index" .= n, "item" .= item]

itemDone :: Int -> Value -> Value
itemDone n item = frame "response.output_item.done" ["output_index" .= n, "item" .= item]

completed :: [Value] -> Value
completed items = frame "response.completed" ["response" .= object ["id" .= ("resp" :: Text), "model" .= ("observed-model" :: Text), "output" .= items]]

part :: Text -> Value
part t = object ["type" .= ("output_text" :: Text), "text" .= t]

message :: Text -> Value
message t = object ["type" .= ("message" :: Text), "id" .= ("msg" :: Text), "content" .= [part t]]

textDelta :: Int -> Int -> Text -> Value
textDelta n p t = frame "response.output_text.delta" ["output_index" .= n, "item_id" .= ("msg" :: Text), "content_index" .= p, "delta" .= t]

call :: Text -> Text -> Text -> Text -> Value
call ident callId args status = object ["type" .= ("function_call" :: Text), "id" .= ident, "call_id" .= callId, "name" .= ("lookup" :: Text), "arguments" .= args, "status" .= status]

argDelta :: Int -> Text -> Text -> Value
argDelta n ident t = frame "response.function_call_arguments.delta" ["output_index" .= n, "item_id" .= ident, "delta" .= t]

reasoningAdded :: Value
reasoningAdded = object ["type" .= ("reasoning" :: Text), "id" .= ("rs" :: Text), "summary" .= ([] :: [Value])]

reasoning :: Value
reasoning = object ["type" .= ("reasoning" :: Text), "id" .= ("rs" :: Text), "summary" .= ([] :: [Value]), "encrypted_content" .= ("opaque" :: Text), "future_field" .= object ["keep" .= True]]
