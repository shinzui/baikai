-- | End-to-end check that a structured error set on an 'EventError'
-- terminal is threaded through reassembly onto the 'Response' a caller
-- gets back from 'completeRequest'. This is the user-visible payoff of
-- the in-band error-classification work: branch on category/retry
-- without parsing error text.
module ErrorInfoSpec (tests) where

import Baikai
import Baikai.Prelude
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

errApi :: Api
errApi = Custom "baikai-errinfo"

errModel :: Model
errModel =
  emptyModel
    & #modelId
    .~ "err-model"
    & #api
    .~ errApi
    & #provider
    .~ "test"

-- | A stream that emits a single 'EventError' carrying a structured
-- 'RateLimited' error with a retry-after hint.
errStream :: Model -> Context -> Options -> Stream.Stream IO AssistantMessageEvent
errStream _ _ _ =
  let payload =
        (emptyResponse ^. #message)
          & #stopReason
          .~ ErrorReason
          & #errorMessage
          .~ Just "rate limited, slow down"
      term =
        errorTerminal
          Nothing
          ErrorReason
          (AssistantMessage payload)
          (rateLimited (Just 5) "rate limited, slow down")
      start = EventStart StartPayload {partial = AssistantMessage payload, responseId = Nothing}
   in Stream.fromList [start, EventError term]

errResponse :: Model -> Context -> Options -> IO Response
errResponse m _ _ =
  pure (errorResponse m (read "2026-06-05 00:00:00 UTC") 0 (rateLimited (Just 5) "rate limited, slow down"))

registerErr :: IO ()
registerErr =
  registerApiProvider
    ApiProvider
      { apiTag = errApi,
        stream = errStream,
        complete = streamingComplete errStream
      }

tests :: TestTree
tests =
  testGroup
    "Response.errorInfo threading"
    [ testCase "completeRequest surfaces structured errorInfo" $ do
        registerErr
        resp <- completeRequest errModel emptyContext emptyOptions
        case responseError resp of
          Just be -> do
            be ^. #category @?= RateLimited
            be ^. #retryAfterSeconds @?= Just 5
          Nothing -> assertFailure "expected Response.errorInfo to be populated",
      testCase "completeRequestWith reports missing provider in-band" $ do
        reg <- newProviderRegistry
        resp <- completeRequestWith reg errModel emptyContext emptyOptions
        case responseError resp of
          Just be -> be ^. #category @?= ProviderUnavailable
          Nothing -> assertFailure "expected ProviderUnavailable response",
      testCase "liftCompleteToStream preserves error-shaped responses as EventError" $ do
        let stream = liftCompleteToStream errResponse
        events <- Stream.toList (stream errModel emptyContext emptyOptions)
        assertBool "expected exactly one terminal" (length (filter isTerminal events) == 1)
        case last events of
          EventError TerminalPayload {errorInfo = Just be} -> do
            be ^. #category @?= RateLimited
            be ^. #retryAfterSeconds @?= Just 5
          other -> assertFailure ("expected terminal EventError, got: " <> show other),
      testCase "reassembly normalizes ErrorReason terminals without errorInfo" $ do
        let payload =
              (emptyResponse ^. #message)
                & #stopReason
                .~ ErrorReason
                & #errorMessage
                .~ Just "legacy unclassified failure"
            terminal =
              doneTerminal
                Nothing
                ErrorReason
                (AssistantMessage payload)
            events =
              [ EventStart StartPayload {partial = AssistantMessage payload, responseId = Nothing},
                EventDone terminal
              ]
        resp <- Stream.fold (reassembleResponse errModel) (Stream.fromList events)
        case responseError resp of
          Just be -> do
            be ^. #category @?= OtherError
            be ^. #message @?= "legacy unclassified failure"
          Nothing -> assertFailure "expected synthesized errorInfo"
    ]
