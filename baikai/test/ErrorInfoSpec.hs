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
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

errApi :: Api
errApi = Custom "baikai-errinfo"

errModel :: Model
errModel =
  _Model
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
        (_Response ^. #message)
          & #stopReason
          .~ ErrorReason
          & #errorMessage
          .~ Just "rate limited, slow down"
      term =
        errorTerminal
          Nothing
          ErrorReason
          (AssistantMessage payload)
          (Just (rateLimited (Just 5) "rate limited, slow down"))
   in Stream.fromList [EventError term]

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
        resp <- completeRequest errModel _Context _Options
        case resp ^. #errorInfo of
          Just be -> do
            be ^. #category @?= RateLimited
            be ^. #retryAfterSeconds @?= Just 5
          Nothing -> assertFailure "expected Response.errorInfo to be populated"
    ]
