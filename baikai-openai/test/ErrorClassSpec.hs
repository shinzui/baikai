module ErrorClassSpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Provider.OpenAI.Internal.ErrorClass
  ( classifyErrorFrame,
    classifyException,
  )
import Control.Exception (toException)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
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
    [ errorFrameTests,
      streamedErrorTests,
      fallbackTests
    ]

-- | The phrase table, pinned through the entry point the runtime uses.
--
-- These four phrases used to be fed to a bare-'Text' classifier that no
-- production path called. They still classify the same way, but now as
-- the @message@ of a frame the transport can actually deliver.
streamedErrorTests :: TestTree
streamedErrorTests =
  testGroup
    "classifyErrorFrame (message phrase fallback)"
    [ testCase "rate limit text -> RateLimited" $
        fmap category (classifyErrorFrame (frameWithMessage "Rate limit reached for requests"))
          @?= Just RateLimited,
      testCase "context length text -> ContextOverflow" $
        fmap
          category
          (classifyErrorFrame (frameWithMessage "This model's maximum context length is 4096 tokens"))
          @?= Just ContextOverflow,
      testCase "invalid api key text -> AuthError" $
        fmap category (classifyErrorFrame (frameWithMessage "Incorrect API key provided"))
          @?= Just AuthError,
      testCase "unknown text -> OtherError" $
        fmap category (classifyErrorFrame (frameWithMessage "something odd happened"))
          @?= Just OtherError,
      -- A blank message is still a frame: the error key is what makes it
      -- one, and dropping it would put the call back on the "stream
      -- ended without finish_reason" path this milestone exists to fix.
      testCase "a frame whose message is blank still classifies" $ do
        let parsed = classifyErrorFrame (frameWithMessage "   ")
        fmap category parsed @?= Just OtherError
        fmap message parsed @?= Just "provider sent an error frame without a message"
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

-- | The frames a compatible host actually sends on a 2xx stream.
errorFrameTests :: TestTree
errorFrameTests =
  testGroup
    "classifyErrorFrame (in-band error frames)"
    [ -- OpenRouter forwards the upstream HTTP status as a *number* in
      -- `code`, and sends a `choices` array beside the error, so
      -- detection cannot key on the absence of `choices`.
      testCase "an OpenRouter upstream 502 frame is TransientError with httpStatus 502" $ do
        let parsed =
              classifyErrorFrame . decode $
                "{\"error\":{\"message\":\"Provider returned error\",\"code\":502,\
                \\"metadata\":{\"provider_name\":\"x\"}},\
                \\"choices\":[{\"index\":0,\"finish_reason\":\"error\",\"delta\":{}}]}"
        fmap category parsed @?= Just TransientError
        fmap httpStatus parsed @?= Just (Just 502)
        fmap message parsed @?= Just "Provider returned error"
        fmap isRetryable parsed @?= Just True,
      testCase "an OpenAI insufficient_quota frame is AuthError and not retryable" $ do
        let parsed =
              classifyErrorFrame . decode $
                "{\"error\":{\"message\":\"You exceeded your current quota\",\
                \\"type\":\"insufficient_quota\",\"code\":\"insufficient_quota\"}}"
        fmap category parsed @?= Just AuthError
        fmap isRetryable parsed @?= Just False,
      testCase "a rate_limit_exceeded code is RateLimited" $
        fmap
          category
          ( classifyErrorFrame . decode $
              "{\"error\":{\"message\":\"slow down\",\"code\":\"rate_limit_exceeded\"}}"
          )
          @?= Just RateLimited,
      testCase "a context_length_exceeded code is ContextOverflow" $
        fmap
          category
          ( classifyErrorFrame . decode $
              "{\"error\":{\"message\":\"too big\",\"code\":\"context_length_exceeded\"}}"
          )
          @?= Just ContextOverflow,
      testCase "an upstream 429 status wins over the message text" $ do
        let parsed =
              classifyErrorFrame . decode $
                "{\"error\":{\"message\":\"something odd\",\"status\":429}}"
        fmap category parsed @?= Just RateLimited
        fmap httpStatus parsed @?= Just (Just 429),
      testCase "a string-valued error is a frame" $ do
        let parsed = classifyErrorFrame (decode "{\"error\":\"Rate limit reached\"}")
        fmap category parsed @?= Just RateLimited
        fmap message parsed @?= Just "Rate limit reached",
      testCase "a chunk without an error key is not a frame" $
        classifyErrorFrame (decode "{\"choices\":[]}") @?= Nothing,
      testCase "a non-object payload is not a frame" $
        classifyErrorFrame (decode "[1,2,3]") @?= Nothing
    ]

-- | The minimal frame: an error object carrying only a message.
frameWithMessage :: Text.Text -> Value
frameWithMessage msg = Aeson.object ["error" Aeson..= Aeson.object ["message" Aeson..= msg]]

-- | Fixtures are written as the JSON the host sends, so what is under
-- test is the shape on the wire rather than a hand-built 'Value'.
decode :: LBS.ByteString -> Value
decode raw = case Aeson.eitherDecode raw of
  Right v -> v
  Left err -> error ("fixture is not valid JSON: " <> err)
