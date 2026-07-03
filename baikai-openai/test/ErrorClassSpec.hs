module ErrorClassSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Provider.OpenAI.Internal.ErrorClass
  ( classifyErrorText,
    classifyException,
    responseToError,
  )
import Control.Exception (toException)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Sequence qualified as Seq
import Data.Text qualified as Text
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Servant.Client (ResponseF (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.OpenAI.Internal.ErrorClass"
    [ httpStatusTests,
      sdkTextTests,
      streamedErrorTests,
      fallbackTests
    ]

mkResp :: Int -> [(ByteString, ByteString)] -> LBS.ByteString -> ResponseF LBS.ByteString
mkResp status hdrs body =
  Response
    { responseStatusCode = mkStatus status "",
      responseHeaders = Seq.fromList [(CI.mk n, v) | (n, v) <- hdrs],
      responseHttpVersion = http11,
      responseBody = body
    }

httpStatusTests :: TestTree
httpStatusTests =
  testGroup
    "responseToError (HTTP status)"
    [ testCase "429 + Retry-After -> RateLimited with hint" $ do
        let e = responseToError (mkResp 429 [("Retry-After", "12")] "slow down")
        category e @?= RateLimited
        httpStatus e @?= Just 429
        retryAfterSeconds e @?= Just 12,
      testCase "401 -> AuthError" $
        category (responseToError (mkResp 401 [] "bad key")) @?= AuthError,
      testCase "400 with overflow body -> ContextOverflow" $
        category (responseToError (mkResp 400 [] "maximum context length is 8192 tokens"))
          @?= ContextOverflow,
      testCase "400 ordinary -> InvalidRequest" $
        category (responseToError (mkResp 400 [] "unknown parameter")) @?= InvalidRequest,
      testCase "500 -> TransientError" $
        category (responseToError (mkResp 500 [] "")) @?= TransientError
    ]

streamedErrorTests :: TestTree
streamedErrorTests =
  testGroup
    "classifyErrorText (mid-stream error text)"
    [ testCase "rate limit text -> RateLimited" $
        fmap category (classifyErrorText "Rate limit reached for requests") @?= Just RateLimited,
      testCase "context length text -> ContextOverflow" $
        fmap category (classifyErrorText "This model's maximum context length is 4096 tokens")
          @?= Just ContextOverflow,
      testCase "invalid api key text -> AuthError" $
        fmap category (classifyErrorText "Incorrect API key provided") @?= Just AuthError,
      testCase "unknown text -> OtherError" $
        fmap category (classifyErrorText "something odd happened") @?= Just OtherError,
      testCase "blank text -> Nothing" $
        classifyErrorText "   " @?= Nothing
    ]

fallbackTests :: TestTree
fallbackTests =
  testGroup
    "classifyException fallback"
    [ testCase "http-client connection failures are transient" $ do
        let e =
              classifyException $
                toException $
                  HTTP.HttpExceptionRequest
                    HTTP.defaultRequest
                    (HTTP.ConnectionFailure (toException (userError "reset")))
        category e @?= TransientError
        assertBool "connection failure is retryable" (isRetryable e),
      testCase "http-client response timeouts are transient" $ do
        let e =
              classifyException $
                toException $
                  HTTP.HttpExceptionRequest
                    HTTP.defaultRequest
                    HTTP.ResponseTimeout
        category e @?= TransientError
        assertBool "response timeout is retryable" (isRetryable e),
      testCase "non-ClientError exception -> OtherError, text preserved" $ do
        let e = classifyException (toException (userError "weird failure"))
        category e @?= OtherError
        assertBool "message keeps the original text" $
          "weird failure" `Text.isInfixOf` message e
    ]

sdkTextTests :: TestTree
sdkTextTests =
  testGroup
    "classifyErrorText (SDK HTTP text)"
    [ testCase "429 SDK text -> RateLimited with status" $ do
        let parsed =
              classifyErrorText
                "HTTP error 429 Too Many Requests: {\"error\":{\"message\":\"Rate limit reached...\",\"type\":\"tokens\"}}"
        fmap category parsed @?= Just RateLimited
        fmap httpStatus parsed @?= Just (Just 429),
      testCase "401 SDK text -> AuthError" $
        fmap category (classifyErrorText "HTTP error 401 Unauthorized: {\"error\":{\"message\":\"bad key\"}}")
          @?= Just AuthError
    ]
