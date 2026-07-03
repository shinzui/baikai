module StreamSpec (tests) where

import Baikai
import Baikai.Prelude
import Data.Aeson qualified as Aeson
import Data.Time (UTCTime)
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

streamApi :: Api
streamApi = Custom "baikai-stream-spec"

streamModel :: Model
streamModel =
  _Model
    & #modelId
    .~ "stream-spec-model"
    & #api
    .~ streamApi
    & #provider
    .~ "stream-spec"

streamContext :: Context
streamContext = _Context

streamOptions :: Options
streamOptions = _Options

epoch :: UTCTime
epoch = read "2000-01-01 00:00:00 UTC"

assistantPayload :: Vector AssistantContent -> StopReason -> Maybe Text -> UTCTime -> AssistantPayload
assistantPayload blocks sr err ts =
  AssistantPayload
    { content = blocks,
      usage = _Usage,
      stopReason = sr,
      errorMessage = err,
      timestamp = ts
    }

assistantMessage :: [AssistantContent] -> Message
assistantMessage blocks =
  AssistantMessage (assistantPayload (Vector.fromList blocks) Stop Nothing epoch)

responseWith :: Maybe Text -> [AssistantContent] -> Response
responseWith rid blocks =
  _Response
    & #message
    .~ assistantPayload (Vector.fromList blocks) Stop Nothing epoch
    & #model
    .~ streamModel
    & #api
    .~ streamApi
    & #provider
    .~ "stream-spec"
    & #responseId
    .~ rid

runEvents :: [AssistantMessageEvent] -> IO Response
runEvents events =
  Stream.fold (reassembleResponse streamModel) (Stream.fromList events)

startEvent :: Maybe Text -> AssistantMessageEvent
startEvent rid =
  EventStart StartPayload {partial = assistantMessage [], responseId = rid}

doneEvent :: Maybe Text -> [AssistantContent] -> AssistantMessageEvent
doneEvent rid blocks =
  EventDone (doneTerminal rid Stop (assistantMessage blocks))

signedThinking :: ThinkingContent
signedThinking =
  ThinkingContent {thinking = "t", signature = Just "sig-abc", redacted = True}

tests :: TestTree
tests =
  testGroup
    "Baikai.Stream reassembly"
    [ testCase "thinking signature and redacted flag survive lift + reassembly" $ do
        let blocks =
              [ AssistantThinking signedThinking,
                AssistantText (TextContent "answer")
              ]
            handler _ _ _ = pure (responseWith (Just "lifted-id") blocks)
        resp <- streamingComplete (liftCompleteToStream handler) streamModel streamContext streamOptions
        resp ^. #message ^. #content @?= Vector.fromList blocks,
      testCase "ThinkingEnd carries the full ThinkingContent" $ do
        resp <-
          runEvents
            [ startEvent Nothing,
              ThinkingStart IndexPayload {contentIndex = 0},
              ThinkingDelta DeltaPayload {contentIndex = 0, delta = "t"},
              ThinkingEnd ThinkingEndPayload {contentIndex = 0, content = signedThinking},
              doneEvent Nothing []
            ]
        resp ^. #message ^. #content @?= Vector.singleton (AssistantThinking signedThinking),
      testCase "terminal message content is authoritative" $ do
        resp <-
          runEvents
            [ startEvent Nothing,
              TextStart IndexPayload {contentIndex = 0},
              TextDelta DeltaPayload {contentIndex = 0, delta = "partial"},
              TextEnd BlockEndPayload {contentIndex = 0, content = "partial"},
              doneEvent Nothing [AssistantText (TextContent "the real full text")]
            ]
        resp ^. #message ^. #content @?= Vector.singleton (AssistantText (TextContent "the real full text")),
      testCase "responseId flows from events to Response" $ do
        fromStart <- runEvents [startEvent (Just "msg_123"), doneEvent Nothing []]
        fromStart ^. #responseId @?= Just "msg_123"
        fromTerminal <- runEvents [startEvent (Just "msg_123"), doneEvent (Just "msg_456") []]
        fromTerminal ^. #responseId @?= Just "msg_456",
      testCase "dangling buffers keep contentIndex order; tool args flushed" $ do
        resp <-
          runEvents
            [ startEvent Nothing,
              TextStart IndexPayload {contentIndex = 0},
              TextDelta DeltaPayload {contentIndex = 0, delta = "first"},
              TextEnd BlockEndPayload {contentIndex = 0, content = "first"},
              ThinkingStart IndexPayload {contentIndex = 1},
              ThinkingDelta DeltaPayload {contentIndex = 1, delta = "partial-think"},
              TextStart IndexPayload {contentIndex = 2},
              TextDelta DeltaPayload {contentIndex = 2, delta = "last"},
              TextEnd BlockEndPayload {contentIndex = 2, content = "last"},
              ToolCallStart IndexPayload {contentIndex = 3},
              ToolCallDelta DeltaPayload {contentIndex = 3, delta = "{\"a\":1"}
            ]
        let expected =
              Vector.fromList
                [ AssistantText (TextContent "first"),
                  AssistantThinking ThinkingContent {thinking = "partial-think", signature = Nothing, redacted = False},
                  AssistantText (TextContent "last"),
                  AssistantToolCall ToolCall {id_ = "", name = "", arguments = Aeson.String "{\"a\":1"}
                ]
        resp ^. #message ^. #content @?= expected
        resp ^. #message ^. #stopReason @?= Stop
        resp ^. #message ^. #errorMessage @?= Just "stream ended without terminal event",
      testCase "latencyMs is clamped at zero" $ do
        let oldResponse =
              responseWith Nothing [AssistantText (TextContent "old")]
                & #message
                %~ (#timestamp .~ epoch)
            handler _ _ _ = pure oldResponse
        resp <- streamingComplete (liftCompleteToStream handler) streamModel streamContext streamOptions
        assertBool "latencyMs should be non-negative" (resp ^. #latencyMs >= 0)
    ]
