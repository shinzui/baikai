module ErrorClassSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Provider.OpenAI.Internal.ErrorClass
  ( classifyErrorText,
    classifyException,
  )
import Control.Exception (toException)
import Data.Text qualified as Text
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.OpenAI.Internal.ErrorClass"
    [ sdkTextTests,
      streamedErrorTests,
      fallbackTests
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
      -- The delegation itself, through the provider's entry point: a
      -- reset raised from the body read reaches the worker as a raw
      -- IOException, which no HttpException branch would have matched.
      testCase "a body-read reset is transient through classifyException" $ do
        let e =
              classifyException . toException $
                IOE.IOError
                  { IOE.ioe_handle = Nothing,
                    IOE.ioe_type = IOE.ResourceVanished,
                    IOE.ioe_location = "Network.Socket.recvBuf",
                    IOE.ioe_description = "Connection reset by peer",
                    IOE.ioe_errno = Just (case eCONNRESET of Errno n -> n),
                    IOE.ioe_filename = Nothing
                  }
        category e @?= TransientError
        assertBool "a mid-stream reset is retryable" (isRetryable e),
      testCase "non-transport exception -> OtherError, text preserved" $ do
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
