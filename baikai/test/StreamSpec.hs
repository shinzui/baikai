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
      duplicateStartTest,
      eventsAfterTerminalTest,
      failedTerminalAppendsDanglingTest,
      emptySuccessfulTerminalFallsBackTest,
      wallClockLatencyTest,
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

-- | A duplicated start does not rewrite the assembly.
--
-- First skeleton wins, so the latency window is measured from the first
-- event the provider actually sent; @responseId@ merges, so a later
-- 'Nothing' cannot erase an id an earlier event supplied.
duplicateStartTest :: TestTree
duplicateStartTest =
  testCase "a duplicate EventStart keeps the first skeleton and merges responseId" $ do
    let firstSkeleton = AssistantMessage (assistantPayload Vector.empty Stop Nothing later)
        staleSkeleton = AssistantMessage (assistantPayload Vector.empty Stop Nothing epoch)
    resp <-
      runEvents
        [ EventStart StartPayload {partial = firstSkeleton, responseId = Just "msg_1"},
          EventStart StartPayload {partial = staleSkeleton, responseId = Nothing},
          EventDone
            ( doneTerminal
                Nothing
                Nothing
                Stop
                (AssistantMessage (assistantPayload (Vector.singleton (AssistantText (TextContent "hi"))) Stop Nothing muchLater))
            )
        ]
    resp ^. #responseId @?= Just "msg_1"
    -- Measured from the first skeleton's timestamp, not the stale one:
    -- the stale skeleton is at the epoch, which would give a latency of
    -- decades.
    resp ^. #latencyMs @?= 2000

-- | The first terminal wins. A producer that keeps talking afterwards
-- cannot rewrite the answer a consumer has already been handed.
eventsAfterTerminalTest :: TestTree
eventsAfterTerminalTest =
  testCase "events after the terminal are ignored" $ do
    resp <-
      runEvents
        [ startEvent Nothing,
          doneEvent Nothing [AssistantText (TextContent "final")],
          TextStart IndexPayload {contentIndex = 5},
          TextDelta DeltaPayload {contentIndex = 5, delta = "late"},
          EventError
            ( errorTerminal
                Nothing
                Nothing
                ErrorReason
                (AssistantMessage (assistantPayload Vector.empty ErrorReason (Just "too late") epoch))
                (providerError "too late")
            )
        ]
    resp ^. #message ^. #content @?= Vector.singleton (AssistantText (TextContent "final"))
    resp ^. #message ^. #stopReason @?= Stop
    resp ^. #errorInfo @?= Nothing

-- | A failed terminal's own content comes first and the blocks that were
-- still open are appended after it. Safe because an open index is always
-- greater than every closed one.
failedTerminalAppendsDanglingTest :: TestTree
failedTerminalAppendsDanglingTest =
  testCase "a failed terminal appends dangling blocks after its content" $ do
    resp <-
      runEvents
        [ startEvent Nothing,
          TextStart IndexPayload {contentIndex = 0},
          TextDelta DeltaPayload {contentIndex = 0, delta = "closed"},
          TextEnd BlockEndPayload {contentIndex = 0, content = "closed"},
          ThinkingStart IndexPayload {contentIndex = 1},
          ThinkingDelta DeltaPayload {contentIndex = 1, delta = "half a thought"},
          EventError
            ( errorTerminal
                Nothing
                Nothing
                ErrorReason
                (AssistantMessage (assistantPayload (Vector.singleton (AssistantText (TextContent "closed"))) ErrorReason (Just "boom") epoch))
                (providerError "boom")
            )
        ]
    resp ^. #message ^. #content
      @?= Vector.fromList
        [ AssistantText (TextContent "closed"),
          AssistantThinking ThinkingContent {thinking = "half a thought", signature = Nothing, redacted = False}
        ]

-- | A terminal that carries no content is not authoritative about
-- content: the blocks the stream assembled are.
emptySuccessfulTerminalFallsBackTest :: TestTree
emptySuccessfulTerminalFallsBackTest =
  testCase "a successful terminal with empty content falls back to the assembled blocks" $ do
    resp <-
      runEvents
        [ startEvent Nothing,
          TextStart IndexPayload {contentIndex = 0},
          TextDelta DeltaPayload {contentIndex = 0, delta = "assembled"},
          TextEnd BlockEndPayload {contentIndex = 0, content = "assembled"},
          doneEvent Nothing []
        ]
    resp ^. #message ^. #content @?= Vector.singleton (AssistantText (TextContent "assembled"))

-- | With no provider timestamps, latency is the window this fold saw
-- rather than a zero that reads as "instant".
wallClockLatencyTest :: TestTree
wallClockLatencyTest =
  testCase "latencyMs falls back to the wall clock when timestamps are absent" $ do
    let untimed sr err blocks =
          AssistantMessage
            AssistantPayload
              { content = Vector.fromList blocks,
                usage = zeroUsage,
                stopReason = sr,
                errorMessage = err,
                timestamp = Nothing
              }
        events =
          [ EventStart StartPayload {partial = untimed Stop Nothing [], responseId = Nothing},
            EventDone (doneTerminal Nothing Nothing Stop (untimed Stop Nothing [AssistantText (TextContent "slow")]))
          ]
    resp <-
      Stream.fold
        (reassembleResponse streamModel)
        (Stream.mapM (\e -> threadDelay 20000 >> pure e) (Stream.fromList events))
    assertBool
      ("expected a wall-clock latency of at least 20ms, got: " <> show (resp ^. #latencyMs))
      (resp ^. #latencyMs >= 20)

later :: UTCTime
later = read "2000-01-01 00:00:01 UTC"

muchLater :: UTCTime
muchLater = read "2000-01-01 00:00:03 UTC"
