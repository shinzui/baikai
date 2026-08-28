{-# LANGUAGE LambdaCase #-}

module ReasoningSpec (tests) where

import Baikai
import Baikai.Models.Generated
import Baikai.Provider.OpenAI.Internal.Request (mapRequest)
import Baikai.Provider.OpenAI.Internal.Stream
  ( RawChunk (..),
    closeOpenStream,
    emptyAssembler,
    emptyTagScanState,
    parseChunk,
    parseFrame,
    scanThinkTags,
    translate,
  )
import Baikai.Provider.OpenAI.Sse (sseFromResponse)
import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Data.Vector qualified as Vector
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import OpenAI.V1.Chat.Completions qualified as Chat
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ReasoningSpec"
    [ parseReasoningTests,
      assemblyTests,
      tagScannerTests,
      taggedTextCompatTest,
      replayDropsThinkingTest
    ]

parseReasoningTests :: TestTree
parseReasoningTests =
  testGroup
    "parseChunk reasoning fields"
    [ testCase "DeepSeek reasoning_content delta" $
        case parseChunk (chunkValue "reasoning_content" "because") of
          Right RawChunk {reasoningDelta = Just r} -> r @?= "because"
          other -> assertFailure ("unexpected parse result: " <> show other),
      testCase "OpenRouter reasoning delta" $
        case parseChunk (chunkValue "reasoning" "because") of
          Right RawChunk {reasoningDelta = Just r} -> r @?= "because"
          other -> assertFailure ("unexpected parse result: " <> show other)
    ]

assemblyTests :: TestTree
assemblyTests =
  testGroup
    "reasoning assembly"
    [ testCase "reasoning deltas close before visible content" $ do
        let chunks =
              [ emptyChunk {reasoningDelta = Just "because "},
                emptyChunk {reasoningDelta = Just "therefore"},
                emptyChunk {contentDelta = Just "answer "},
                emptyChunk {contentDelta = Just "done"},
                emptyChunk {finishReason = Just "stop"}
              ]
            events = runChunks deepseek_deepseek_reasoner chunks
        eventShape events
          @?= [ "ThinkingStart:0",
                "ThinkingDelta:0:because ",
                "ThinkingDelta:0:therefore",
                "ThinkingEnd:0:because therefore",
                "TextStart:1",
                "TextDelta:1:answer ",
                "TextDelta:1:done",
                "TextEnd:1:answer done",
                "EventDone"
              ]
        terminalContent events
          @?= Vector.fromList
            [ AssistantThinking
                ThinkingContent
                  { thinking = "because therefore",
                    signature = Nothing,
                    redacted = False
                  },
              AssistantText (TextContent "answer done")
            ],
      testCase "reasoning after visible text closes the text block first" $ do
        -- The other half of the same rule: opening a thinking block
        -- closes an open text block, so at most one of the two is open
        -- at a time and every _End precedes the next _Start. Before
        -- this, reasoning opened at index 1 while text stayed open at
        -- 0, and the later text delta landed back on 0 -- two blocks
        -- open at once and an index revisited after a later one.
        let chunks =
              [ emptyChunk {contentDelta = Just "a"},
                emptyChunk {reasoningDelta = Just "r"},
                emptyChunk {contentDelta = Just "b"},
                emptyChunk {finishReason = Just "stop"}
              ]
            events = runChunks deepseek_deepseek_reasoner chunks
        eventShape events
          @?= [ "TextStart:0",
                "TextDelta:0:a",
                "TextEnd:0:a",
                "ThinkingStart:1",
                "ThinkingDelta:1:r",
                "ThinkingEnd:1:r",
                "TextStart:2",
                "TextDelta:2:b",
                "TextEnd:2:b",
                "EventDone"
              ],
      -- Driven through the transport rather than handed straight to
      -- 'parseChunk', because a `data:` frame is the only way this
      -- object can reach the assembler: a whole-message shape on a
      -- streaming endpoint is what a compatible host sends when it
      -- ignores `stream: true`, and it still arrives framed.
      testCase "a data frame carrying a whole message object yields reasoning then text" $ do
        chunks <- transportChunks [dataFrame wholeMessageObject, "data: [DONE]\n\n"]
        terminalContent (runChunks deepseek_deepseek_reasoner chunks)
          @?= Vector.fromList
            [ AssistantThinking
                ThinkingContent
                  { thinking = "because",
                    signature = Nothing,
                    redacted = False
                  },
              AssistantText (TextContent "answer")
            ],
      -- The honest statement of the transport's limitation: an SSE
      -- transport decodes frames, so a bare JSON body with no @data:@
      -- prefix reaches nothing at all. Pretending 'parseMessageObject'
      -- is reachable for such a body would be pretending.
      testCase "a bare JSON body with no data prefix is not decoded" $ do
        chunks <- transportChunks [LBS.toStrict (Aeson.encode wholeMessageObject)]
        length chunks @?= 0
    ]

-- | The shape a compatible host sends when it answers a streaming
-- request with a whole message instead of deltas.
wholeMessageObject :: Aeson.Value
wholeMessageObject =
  Aeson.object
    [ "choices"
        Aeson..= [ Aeson.object
                     [ "message"
                         Aeson..= Aeson.object
                           [ "reasoning_content" Aeson..= ("because" :: Text.Text),
                             "content" Aeson..= ("answer" :: Text.Text)
                           ],
                       "finish_reason" Aeson..= ("stop" :: Text.Text)
                     ]
                 ]
    ]

dataFrame :: Aeson.Value -> ByteString
dataFrame v = "data: " <> LBS.toStrict (Aeson.encode v) <> "\n\n"

-- | Push a recorded 200 body through the real 'sseFromResponse' and the
-- real 'parseFrame', which is the pair the worker runs.
transportChunks :: [ByteString] -> IO [RawChunk]
transportChunks body = do
  eventsRef <- newIORef []
  resp <- mkResponse 200 body
  sseFromResponse resp (const (pure ())) (\ev -> modifyIORef' eventsRef (<> [ev]))
  events <- readIORef eventsRef
  traverse decodeOne [v | Right v <- events]
  where
    decodeOne v = case parseFrame v of
      Right (Right chunk) -> pure chunk
      Right (Left be) -> assertFailure ("expected a chunk, got a classified error: " <> show be)
      Left err -> assertFailure ("parse failed: " <> err)

-- | The same fixture shape both 'SseSpec' and 'EvidenceSpec' keep, so
-- neither suite can silently change another's response.
mkResponse :: Int -> [ByteString] -> IO (HTTP.Response HTTP.BodyReader)
mkResponse status chunks = do
  ref <- newIORef chunks
  let bodyReader = do
        remaining <- readIORef ref
        case remaining of
          [] -> pure ""
          (x : xs) -> writeIORef ref xs >> pure x
  pure
    HTTP.Response
      { HTTP.responseStatus = mkStatus status "",
        HTTP.responseVersion = http11,
        HTTP.responseHeaders = [],
        HTTP.responseBody = bodyReader,
        HTTP.responseCookieJar = HTTP.createCookieJar [],
        HTTP.responseClose' = HTTP.ResponseClose (pure ()),
        HTTP.responseOriginalRequest = HTTP.defaultRequest,
        HTTP.responseEarlyHints = []
      }

tagScannerTests :: TestTree
tagScannerTests =
  testGroup
    "scanThinkTags"
    [ testCase "split tags across deltas" $ do
        let (st1, p1) = scanThinkTags emptyTagScanState "<th"
            (st2, p2) = scanThinkTags st1 "ink>reasoning</thi"
            (_st3, p3) = scanThinkTags st2 "nk>answer"
        p1 <> p2 <> p3 @?= [Left "reasoning", Right "answer"],
      testCase "literal less-than text passes through" $ do
        let (_st, parts) = scanThinkTags emptyTagScanState "2 < 3"
        parts @?= [Right "2 < 3"]
    ]

taggedTextCompatTest :: TestTree
taggedTextCompatTest =
  testCase "requiresThinkingAsText gates tag extraction" $ do
    let tagged = "<think>reasoning</think>answer"
        deepseekEvents =
          runChunks
            deepseek_deepseek_reasoner
            [ emptyChunk {contentDelta = Just tagged},
              emptyChunk {finishReason = Just "stop"}
            ]
        openaiEvents =
          runChunks
            openai_gpt_4o_mini
            [ emptyChunk {contentDelta = Just tagged},
              emptyChunk {finishReason = Just "stop"}
            ]
    terminalContent deepseekEvents
      @?= Vector.fromList
        [ AssistantThinking
            ThinkingContent
              { thinking = "reasoning",
                signature = Nothing,
                redacted = False
              },
          AssistantText (TextContent "answer")
        ]
    terminalContent openaiEvents
      @?= Vector.singleton (AssistantText (TextContent tagged))

replayDropsThinkingTest :: TestTree
replayDropsThinkingTest =
  testCase "OpenAI-compatible replay drops AssistantThinking blocks" $ do
    let msg =
          AssistantMessage
            AssistantPayload
              { content =
                  Vector.fromList
                    [ AssistantThinking
                        ThinkingContent
                          { thinking = "internal",
                            signature = Nothing,
                            redacted = False
                          },
                      AssistantText (TextContent "visible")
                    ],
                usage = zeroUsage,
                stopReason = Stop,
                errorMessage = Nothing,
                timestamp = Just testTime
              }
        ctx = emptyContext & #messages .~ Vector.singleton msg
    case mapRequest deepseek_deepseek_reasoner ctx emptyOptions of
      Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
      Right req -> case Vector.toList (requestMessages req) of
        [Chat.Assistant {Chat.assistant_content = Just parts}] ->
          case Vector.toList parts of
            [Chat.Text {Chat.text = body}] -> body @?= "visible"
            other -> assertFailure ("unexpected assistant content parts: " <> show other)
        other -> assertFailure ("unexpected mapped messages: " <> show other)

chunkValue :: Text.Text -> Text.Text -> Aeson.Value
chunkValue key value =
  Aeson.object
    [ "choices"
        Aeson..= [ Aeson.object
                     [ "delta"
                         Aeson..= case key of
                           "reasoning_content" ->
                             Aeson.object ["reasoning_content" Aeson..= value]
                           "reasoning" ->
                             Aeson.object ["reasoning" Aeson..= value]
                           _ ->
                             Aeson.object []
                     ]
                 ]
    ]

emptyChunk :: RawChunk
emptyChunk =
  RawChunk
    { contentDelta = Nothing,
      reasoningDelta = Nothing,
      finishReason = Nothing,
      toolDeltas = [],
      usage = Nothing,
      model = Nothing,
      responseId = Nothing
    }

runChunks :: Model -> [RawChunk] -> [AssistantMessageEvent]
runChunks model chunks =
  let (events, ass) =
        foldl
          ( \(acc, st) chunk ->
              let (newEvents, st') = translate (Right chunk) st testTime
               in (acc <> newEvents, st')
          )
          ([], emptyAssembler model testTime)
          chunks
      (terminalEvents, _) = closeOpenStream testTime Nothing ass
   in events <> terminalEvents

eventShape :: [AssistantMessageEvent] -> [Text.Text]
eventShape =
  fmap $ \case
    ThinkingStart IndexPayload {contentIndex = i} -> "ThinkingStart:" <> tshow i
    ThinkingDelta DeltaPayload {contentIndex = i, delta = d} -> "ThinkingDelta:" <> tshow i <> ":" <> d
    ThinkingEnd ThinkingEndPayload {contentIndex = i, content = ThinkingContent {thinking = body}} ->
      "ThinkingEnd:" <> tshow i <> ":" <> body
    TextStart IndexPayload {contentIndex = i} -> "TextStart:" <> tshow i
    TextDelta DeltaPayload {contentIndex = i, delta = d} -> "TextDelta:" <> tshow i <> ":" <> d
    TextEnd BlockEndPayload {contentIndex = i, content = body} -> "TextEnd:" <> tshow i <> ":" <> body
    EventDone {} -> "EventDone"
    EventError {} -> "EventError"
    _ -> "other"

terminalContent :: [AssistantMessageEvent] -> Vector.Vector AssistantContent
terminalContent events =
  case last events of
    EventDone TerminalPayload {message = AssistantMessage AssistantPayload {content = blocks}} -> blocks
    EventError TerminalPayload {message = AssistantMessage AssistantPayload {content = blocks}} -> blocks
    _ -> Vector.empty

requestMessages :: Chat.CreateChatCompletion -> Vector.Vector (Chat.Message (Vector.Vector Chat.Content))
requestMessages Chat.CreateChatCompletion {Chat.messages = msgs} = msgs

tshow :: (Show a) => a -> Text.Text
tshow = Text.pack . show

testTime :: UTCTime
testTime = read "2026-07-03 12:00:00 UTC"
