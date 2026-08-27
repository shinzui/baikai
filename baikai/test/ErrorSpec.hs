module ErrorSpec (tests) where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    classifyHttpStatus,
    classifyHttpStatusWithBody,
    decodeError,
    httpError,
    invalidRequest,
    isRetryable,
    parseHttpDate,
    parseRetryAfterSeconds,
    processError,
    rateLimited,
    retryAfterSecondsAt,
  )
import Data.Time (UTCTime)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Error"
    [ classifyTests,
      bodyClassifyTests,
      httpHelperTests,
      retryTests,
      constructorTests
    ]

httpHelperTests :: TestTree
httpHelperTests =
  testGroup
    "httpError / parseRetryAfterSeconds"
    [ testCase "429 + retry-after -> RateLimited with hint" $ do
        let e = httpError 429 (Just 12) "slow down"
        category e @?= RateLimited
        httpStatus e @?= Just 429
        retryAfterSeconds e @?= Just 12,
      -- Re-homed from the provider suites' servant fixtures: the
      -- assertion is about 'httpError', which is where it belongs.
      testCase "429 without Retry-After -> RateLimited, no hint" $ do
        let e = httpError 429 Nothing "slow down"
        category e @?= RateLimited
        retryAfterSeconds e @?= Nothing,
      testCase "400 + overflow body -> ContextOverflow" $
        category (httpError 400 Nothing "maximum context length exceeded")
          @?= ContextOverflow,
      testCase "integer Retry-After parses as seconds" $
        parseRetryAfterSeconds "12" @?= Just 12,
      -- The integer-only contract is now deliberate rather than a
      -- limitation: converting a date needs a reference instant, which
      -- 'retryAfterSecondsAt' takes and this function cannot.
      testCase "parseRetryAfterSeconds is integer-only" $
        parseRetryAfterSeconds "Wed, 21 Oct 2026 07:28:00 GMT" @?= Nothing,
      testCase "HTTP-date Retry-After yields seconds from the reference instant" $
        retryAfterSecondsAt referenceInstant "Wed, 21 Oct 2026 07:28:00 GMT" @?= Just 30,
      -- The server is saying "now", not "some time last week".
      testCase "HTTP-date Retry-After in the past yields zero" $
        retryAfterSecondsAt referenceInstant "Wed, 21 Oct 2026 07:00:00 GMT" @?= Just 0,
      testCase "integer Retry-After ignores the reference instant" $
        retryAfterSecondsAt referenceInstant "12" @?= Just 12,
      testCase "malformed Retry-After yields Nothing" $
        retryAfterSecondsAt referenceInstant "soonish" @?= Nothing,
      testCase "parseHttpDate accepts IMF-fixdate, RFC 850 and asctime" $ do
        let expected = Just (read "1994-11-06 08:49:37 UTC" :: UTCTime)
        parseHttpDate "Sun, 06 Nov 1994 08:49:37 GMT" @?= expected
        parseHttpDate "Sunday, 06-Nov-94 08:49:37 GMT" @?= expected
        parseHttpDate "Sun Nov  6 08:49:37 1994" @?= expected,
      testCase "parseHttpDate rejects text that is not a date" $
        parseHttpDate "tomorrow" @?= Nothing
    ]

-- | Thirty seconds before the @Retry-After@ date the cases above use, so
-- the expected answer is a number a reader can check by eye.
referenceInstant :: UTCTime
referenceInstant = read "2026-10-21 07:27:30 UTC"

bodyClassifyTests :: TestTree
bodyClassifyTests =
  testGroup
    "classifyHttpStatusWithBody"
    [ testCase "400 + overflow body -> ContextOverflow" $
        classifyHttpStatusWithBody 400 Nothing "This model's maximum context length is 8192 tokens"
          @?= ContextOverflow,
      testCase "400 + prompt-too-long body -> ContextOverflow" $
        classifyHttpStatusWithBody 400 Nothing "prompt is too long: 9000 tokens > 8000"
          @?= ContextOverflow,
      testCase "400 + ordinary body -> InvalidRequest" $
        classifyHttpStatusWithBody 400 Nothing "missing required field 'model'"
          @?= InvalidRequest,
      testCase "429 + overflow-looking body still RateLimited (status wins)" $
        classifyHttpStatusWithBody 429 Nothing "context length whatever"
          @?= RateLimited,
      testCase "500 defers to status -> TransientError" $
        classifyHttpStatusWithBody 500 Nothing "context length" @?= TransientError,
      -- 413 is the size-limit status, so the body's wording changes
      -- nothing: the caller's remedy is to shrink the input either way.
      testCase "413 + ordinary body -> ContextOverflow" $
        classifyHttpStatusWithBody 413 Nothing "payload too large" @?= ContextOverflow,
      testCase "413 + request_too_large body -> ContextOverflow" $
        classifyHttpStatusWithBody 413 Nothing "request_too_large" @?= ContextOverflow
    ]

classifyTests :: TestTree
classifyTests =
  testGroup
    "classifyHttpStatus"
    [ testCase "401 -> AuthError" $ classifyHttpStatus 401 Nothing @?= AuthError,
      testCase "403 -> AuthError" $ classifyHttpStatus 403 Nothing @?= AuthError,
      testCase "429 -> RateLimited" $ classifyHttpStatus 429 Nothing @?= RateLimited,
      testCase "408 -> TransientError" $ classifyHttpStatus 408 Nothing @?= TransientError,
      testCase "400 -> InvalidRequest" $ classifyHttpStatus 400 Nothing @?= InvalidRequest,
      testCase "404 -> InvalidRequest" $ classifyHttpStatus 404 Nothing @?= InvalidRequest,
      testCase "422 -> InvalidRequest" $ classifyHttpStatus 422 Nothing @?= InvalidRequest,
      testCase "500 -> TransientError" $ classifyHttpStatus 500 Nothing @?= TransientError,
      testCase "502 -> TransientError" $ classifyHttpStatus 502 Nothing @?= TransientError,
      testCase "503 -> TransientError" $ classifyHttpStatus 503 Nothing @?= TransientError,
      testCase "413 -> ContextOverflow" $ classifyHttpStatus 413 Nothing @?= ContextOverflow,
      testCase "418 -> OtherError" $ classifyHttpStatus 418 Nothing @?= OtherError
    ]

retryTests :: TestTree
retryTests =
  testGroup
    "isRetryable / retryAfterSeconds"
    [ testCase "rate limited is retryable" $
        isRetryable (rateLimited (Just 30) "slow down") @?= True,
      testCase "rate limited carries retry-after" $
        retryAfterSeconds (rateLimited (Just 30) "slow down") @?= Just 30,
      testCase "rate limited sets httpStatus 429" $
        httpStatus (rateLimited Nothing "slow down") @?= Just 429,
      testCase "invalid request is not retryable" $
        isRetryable (invalidRequest "bad shape") @?= False,
      testCase "decode failure is not retryable" $
        isRetryable (decodeError "garbled") @?= False
    ]

constructorTests :: TestTree
constructorTests =
  testGroup
    "smart constructors"
    [ testCase "processError carries exit code" $
        exitCode (processError 2 "boom") @?= Just 2,
      testCase "processError category is ProcessFailure" $
        category (processError 2 "boom") @?= ProcessFailure,
      testCase "invalidRequest category" $
        category (invalidRequest "x") @?= InvalidRequest,
      testCase "decodeError category" $
        category (decodeError "x") @?= DecodeFailure
    ]
