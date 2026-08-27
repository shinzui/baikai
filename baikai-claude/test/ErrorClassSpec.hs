module ErrorClassSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Provider.Claude.Internal.ErrorClass
  ( classifyErrorValue,
    classifyException,
  )
import Control.Exception (toException)
import Data.Aeson (Value, object, (.=))
import Data.Text qualified as Text
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude.Internal.ErrorClass"
    [ streamedErrorTests,
      fallbackTests
    ]

streamedErrorTests :: TestTree
streamedErrorTests =
  testGroup
    "classifyErrorValue (mid-stream error event)"
    [ testCase "rate_limit_error -> RateLimited" $
        fmap category (classifyErrorValue (anthropicError "rate_limit_error" "slow"))
          @?= Just RateLimited,
      testCase "overloaded_error -> TransientError" $
        fmap category (classifyErrorValue (anthropicError "overloaded_error" "busy"))
          @?= Just TransientError,
      testCase "authentication_error -> AuthError" $
        fmap category (classifyErrorValue (anthropicError "authentication_error" "nope"))
          @?= Just AuthError,
      testCase "invalid_request_error with overflow text -> ContextOverflow" $
        fmap category (classifyErrorValue (anthropicError "invalid_request_error" "prompt is too long"))
          @?= Just ContextOverflow,
      testCase "invalid_request_error otherwise -> InvalidRequest" $
        fmap category (classifyErrorValue (anthropicError "invalid_request_error" "bad"))
          @?= Just InvalidRequest,
      testCase "value without a type -> Nothing" $
        classifyErrorValue (object ["message" .= ("hi" :: Text.Text)]) @?= Nothing
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

-- | The inner error object Anthropic streams as the @error@ field.
anthropicError :: Text.Text -> Text.Text -> Value
anthropicError ty msg = object ["type" .= ty, "message" .= msg]
