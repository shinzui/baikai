module SseSpec (tests) where

import Baikai.Error (ErrorCategory (..), category, httpStatus, retryAfterSeconds)
import Baikai.Provider.Claude.Sse (sseFromResponse)
import Claude.V1.Messages qualified as Messages
import Control.Lens ((^.))
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude.Sse"
    [ testCase "non-2xx response preserves Retry-After and status" $ do
        eventsRef <- newIORef []
        resp <- mkResponse 429 [("Retry-After", "7")] ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
        sseFromResponse resp (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> do
            category e @?= RateLimited
            retryAfterSeconds e @?= Just 7
            httpStatus e @?= Just 429
          other -> assertFailure ("expected one classified error, got: " <> show other),
      testCase "200 response decodes split SSE data frames in order" $ do
        eventsRef <- newIORef []
        resp <-
          mkResponse
            200
            []
            [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",",
              "\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,",
              "\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\r\n\r\n",
              "data: {\"type\":\"message_stop\"}\n\n"
            ]
        sseFromResponse resp (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Right Messages.Message_Start {Messages.message = msg}, Right Messages.Message_Stop] ->
            msg ^. #id @?= "msg_1"
          other -> assertFailure ("expected message_start then message_stop, got: " <> show other)
    ]

mkResponse :: Int -> [(ByteString, ByteString)] -> [ByteString] -> IO (HTTP.Response HTTP.BodyReader)
mkResponse status headers chunks = do
  ref <- newIORef chunks
  let bodyReader = do
        remaining <- readIORef ref
        case remaining of
          [] -> pure ""
          (x : xs) -> writeIORef ref xs >> pure x
  pure
    HTTP.Response
      { HTTP.responseStatus = mkStatus status "",
        HTTP.responseVersion = http11,
        HTTP.responseHeaders = [(CI.mk k, v) | (k, v) <- headers],
        HTTP.responseBody = bodyReader,
        HTTP.responseCookieJar = HTTP.createCookieJar [],
        HTTP.responseClose' = HTTP.ResponseClose (pure ()),
        HTTP.responseOriginalRequest = HTTP.defaultRequest,
        HTTP.responseEarlyHints = []
      }
