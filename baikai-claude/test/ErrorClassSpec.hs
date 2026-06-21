module ErrorClassSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..))
import Baikai.Provider.Claude.ErrorClass
  ( classifyErrorValue,
    classifyException,
    responseToError,
  )
import Control.Exception (toException)
import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.CaseInsensitive qualified as CI
import Data.Sequence qualified as Seq
import Data.Text qualified as Text
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Servant.Client (ResponseF (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude.ErrorClass"
    [ httpStatusTests,
      streamedErrorTests,
      fallbackTests
    ]

-- | Build a synthetic servant 'ResponseF' for the HTTP-status mapper.
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
        let e = responseToError (mkResp 429 [("Retry-After", "30")] "slow down")
        category e @?= RateLimited
        httpStatus e @?= Just 429
        retryAfterSeconds e @?= Just 30,
      testCase "429 without Retry-After -> RateLimited, no hint" $ do
        let e = responseToError (mkResp 429 [] "slow down")
        category e @?= RateLimited
        retryAfterSeconds e @?= Nothing,
      testCase "401 -> AuthError" $
        category (responseToError (mkResp 401 [] "bad key")) @?= AuthError,
      testCase "400 with overflow body -> ContextOverflow" $
        category (responseToError (mkResp 400 [] "prompt is too long: 9000 tokens"))
          @?= ContextOverflow,
      testCase "400 with ordinary body -> InvalidRequest" $
        category (responseToError (mkResp 400 [] "missing field model"))
          @?= InvalidRequest,
      testCase "503 -> TransientError" $
        category (responseToError (mkResp 503 [] "")) @?= TransientError,
      testCase "non-integer Retry-After is ignored" $
        retryAfterSeconds (responseToError (mkResp 429 [("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT")] ""))
          @?= Nothing
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
    [ testCase "non-ClientError exception -> OtherError, text preserved" $ do
        let e = classifyException (toException (userError "weird failure"))
        category e @?= OtherError
        assertBool "message keeps the original text" $
          "weird failure" `Text.isInfixOf` message e
    ]

-- | The inner error object Anthropic streams as the @error@ field.
anthropicError :: Text.Text -> Text.Text -> Value
anthropicError ty msg = object ["type" .= ty, "message" .= msg]
