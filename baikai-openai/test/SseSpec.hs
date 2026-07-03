module SseSpec (tests) where

import Baikai.Error (ErrorCategory (..), category, httpStatus, retryAfterSeconds)
import Baikai.Provider.OpenAI.Sse (sseFromResponse)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.OpenAI.Sse"
    [ testCase "non-2xx response preserves Retry-After and status" $ do
        eventsRef <- newIORef []
        resp <- mkResponse 429 [("Retry-After", "9")] ["{\"error\":{\"message\":\"rate limited\",\"type\":\"tokens\"}}"]
        sseFromResponse resp (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> do
            category e @?= RateLimited
            retryAfterSeconds e @?= Just 9
            httpStatus e @?= Just 429
          other -> assertFailure ("expected one classified error, got: " <> show other),
      testCase "[DONE] terminates without emitting a JSON event" $ do
        eventsRef <- newIORef []
        resp <- mkResponse 200 [] ["data: {\"choices\":[]}\n\n", "data: [DONE]\n\n", "data: {\"ignored\":true}\n\n"]
        sseFromResponse resp (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Right (Aeson.Object _)] -> pure ()
          other -> assertFailure ("expected one JSON event before [DONE], got: " <> show other)
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
