module StreamSpec (tests) where

import Baikai
import Baikai.Prelude
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay, throwTo)
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Time (UTCTime)
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

streamApi :: Api
streamApi = Custom "baikai-stream-spec"

streamModel :: Model
streamModel =
  emptyModel
    & #modelId
    .~ "stream-spec-model"
    & #api
    .~ streamApi
    & #provider
    .~ "stream-spec"

streamContext :: Context
streamContext = emptyContext

streamOptions :: Options
streamOptions = emptyOptions

epoch :: UTCTime
epoch = read "2000-01-01 00:00:00 UTC"

assistantPayload :: Vector AssistantContent -> StopReason -> Maybe Text -> UTCTime -> AssistantPayload
assistantPayload blocks sr err ts =
  AssistantPayload
    { content = blocks,
      usage = zeroUsage,
      stopReason = sr,
      errorMessage = err,
      timestamp = Just ts
    }

assistantMessage :: [AssistantContent] -> Message
assistantMessage blocks =
  AssistantMessage (assistantPayload (Vector.fromList blocks) Stop Nothing epoch)

responseWith :: Maybe Text -> [AssistantContent] -> Response
responseWith rid blocks =
  emptyResponse
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
  EventDone (doneTerminal Nothing rid Stop (assistantMessage blocks))

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
        resp ^. #message ^. #errorMessage @?= Just "stream ended without terminal event"
        -- The recovered call is the same shape the two provider
        -- assemblers now produce for a cut-off call, and it says so.
        [tc | AssistantToolCall tc <- Vector.toList (resp ^. #message ^. #content)]
          @?= [ToolCall {id_ = "", name = "", arguments = Aeson.String "{\"a\":1"}]
        assertBool
          "a flushed dangling tool call is marked cut off"
          (all isCutOffToolCall [tc | AssistantToolCall tc <- Vector.toList (resp ^. #message ^. #content)]),
      cutOffToolCallIsNeverDispatchedTest,
      testCase "latencyMs is clamped at zero" $ do
        let oldResponse =
              responseWith Nothing [AssistantText (TextContent "old")]
                & #message
                %~ (#timestamp .~ Just epoch)
            handler _ _ _ = pure oldResponse
        resp <- streamingComplete (liftCompleteToStream handler) streamModel streamContext streamOptions
        assertBool "latencyMs should be non-negative" (resp ^. #latencyMs >= 0),
      testCase "async exceptions pass through liftCompleteToStream" $ do
        done <- newEmptyMVar
        let blocked _ _ _ = threadDelay (10 * 1000 * 1000) *> pure (responseWith Nothing [])
        tid <-
          forkIO $ do
            outcome <- Exception.try (Stream.toList (liftCompleteToStream blocked streamModel streamContext streamOptions))
            putMVar done (outcome :: Either Exception.SomeException [AssistantMessageEvent])
        threadDelay 100000
        throwTo tid Exception.ThreadKilled
        outcome <- takeMVar done
        case outcome of
          Left e ->
            (Exception.fromException e :: Maybe Exception.AsyncException)
              @?= Just Exception.ThreadKilled
          Right events -> assertFailure ("expected ThreadKilled, got events: " <> show events),
      testCase "error-only streams begin with EventStart" $ do
        reg <- newProviderRegistry
        noProviderEvents <- Stream.toList (streamRequestWith reg streamModel streamContext streamOptions)
        case noProviderEvents of
          [ EventStart StartPayload {},
            EventError TerminalPayload {errorInfo = Just be}
            ] ->
              be ^. #category @?= ProviderUnavailable
          other -> assertFailure ("expected EventStart then provider-unavailable EventError, got: " <> show other)

        let throwing _ _ _ = Exception.throwIO (rateLimited (Just 5) "slow down")
        liftedEvents <- Stream.toList (liftCompleteToStream throwing streamModel streamContext streamOptions)
        case liftedEvents of
          [EventStart StartPayload {}, EventError {}] -> pure ()
          other -> assertFailure ("expected EventStart then EventError, got: " <> show other)
        resp <- runEvents liftedEvents
        case resp ^. #errorInfo of
          Just be -> do
            be ^. #category @?= RateLimited
            be ^. #retryAfterSeconds @?= Just 5
          Nothing -> assertFailure "expected lifted BaikaiError to survive reassembly"
    ]

-- | A tool call the model never finished asking for is not executed.
--
-- Both halves: 'runToolLoopWith' stops with the response intact rather
-- than dispatching, and 'appendToolResult' -- the documented direct
-- round-trip, which a caller drives by hand -- appends an error result
-- without calling the dispatcher either.
cutOffToolCallIsNeverDispatchedTest :: TestTree
cutOffToolCallIsNeverDispatchedTest =
  testCase "a cut-off tool call is never dispatched" $ do
    let cutOffCall = ToolCall {id_ = "call_1", name = "search", arguments = Aeson.String "{\"a\":1"}
        -- 'Length' is what a real cut-off carries; the guard does not
        -- rely on it, because a compatible host can report
        -- @finish_reason: tool_calls@ for truncated arguments.
        cutOffResponse =
          emptyResponse
            & #message
            .~ assistantPayload (Vector.singleton (AssistantToolCall cutOffCall)) Length Nothing epoch
            & #model
            .~ cutOffModel
            & #api
            .~ cutOffApi
            & #provider
            .~ "stream-spec"
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      ApiProvider
        { apiTag = cutOffApi,
          stream = liftCompleteToStream (\_ _ _ -> pure cutOffResponse),
          complete = \_ _ _ -> pure cutOffResponse,
          describeThinking = \_ _ -> noThinkingRequested
        }
    dispatched <- newIORef ([] :: [ToolCall])
    let dispatcher tc = modifyIORef' dispatched (<> [tc]) >> pure (toolResultText "never")

    (_, looped) <- runToolLoopWith reg 4 dispatcher cutOffModel streamContext streamOptions
    looped ^. #message ^. #content @?= Vector.singleton (AssistantToolCall cutOffCall)
    looped ^. #message ^. #stopReason @?= Length
    readIORef dispatched >>= \calls -> calls @?= []

    ctx' <- appendToolResult streamContext cutOffResponse dispatcher
    readIORef dispatched >>= \calls -> calls @?= []
    case Vector.toList (ctx' ^. #messages) of
      [_assistant, ToolResultMessage p] -> do
        p ^. #isError @?= True
        p ^. #toolCallId @?= "call_1"
      other -> assertFailure ("expected the assistant message then one tool result, got: " <> show (length other))

-- | Its own tag, so this case cannot collide with the module's other
-- registrations when the suite runs in one process.
cutOffApi :: Api
cutOffApi = Custom "baikai-stream-spec-cutoff"

cutOffModel :: Model
cutOffModel =
  emptyModel
    & #modelId
    .~ "stream-spec-cutoff-model"
    & #api
    .~ cutOffApi
    & #provider
    .~ "stream-spec"
