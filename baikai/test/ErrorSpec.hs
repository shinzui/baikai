module ErrorSpec (tests) where

import Baikai.Error
  ( BaikaiError (..),
    ErrorCategory (..),
    classifyHttpStatus,
    classifyHttpStatusWithBody,
    decodeError,
    invalidRequest,
    isRetryable,
    processError,
    rateLimited,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Error"
    [ classifyTests,
      bodyClassifyTests,
      retryTests,
      constructorTests
    ]

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
        classifyHttpStatusWithBody 500 Nothing "context length" @?= TransientError
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
