module SseSpec (tests) where

import Baikai.Error (ErrorCategory (..), category, httpStatus, retryAfterSeconds)
import Baikai.Evidence (Observed (..))
import Baikai.Models.Generated (anthropic_claude_haiku_4_5)
import Baikai.Provider.Claude.Api (Assembler, emptyAssembler, translate)
import Baikai.Provider.Claude.Sse (ResponseMetadata, sseFromResponse)
import Claude.V1.Messages qualified as Messages
import Control.Lens ((^.))
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Time.Clock (UTCTime)
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude.Sse"
    [ testCase "non-2xx response preserves Retry-After and status" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <- mkResponse 429 [("Retry-After", "7")] ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> do
            category e @?= RateLimited
            retryAfterSeconds e @?= Just 7
            httpStatus e @?= Just 429
          other -> assertFailure ("expected one classified error, got: " <> show other),
      testCase "200 response decodes split SSE data frames in order" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <-
          mkResponse
            200
            []
            [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",",
              "\"content\":[],\"model\":\"claude-test\",\"stop_reason\":null,\"stop_sequence\":null,",
              "\"usage\":{\"input_tokens\":3,\"output_tokens\":0}}}\r\n\r\n",
              "data: {\"type\":\"message_stop\"}\n\n"
            ]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Right Messages.Message_Start {Messages.message = msg}, Right Messages.Message_Stop] ->
            msg ^. #id @?= "msg_1"
          other -> assertFailure ("expected message_start then message_stop, got: " <> show other),
      observationTests
    ]

-- | What the transport and the assembler between them can say about
-- what Anthropic reported, as opposed to what was configured.
--
-- The fixture's @model@ deliberately differs from the model the
-- assembler was built with. If they matched, a bug that read the
-- caller's configuration instead of the provider's event would pass
-- these assertions, which is exactly the substitution the 'Observed'
-- type exists to prevent.
observationTests :: TestTree
observationTests =
  testGroup
    "response observation"
    [ testCase "a 200 response yields one metadata value carrying request-id" $ do
        (metas, _) <- replay 200 [("request-id", "req_abc123"), ("x-api-key", "sk-leak")] successBody
        case metas of
          [md] -> do
            md ^. #httpStatus @?= 200
            -- Allow-list, not denylist: the credential-shaped header the
            -- fixture also carries must not be recorded.
            md ^. #headers @?= [("request-id", "req_abc123")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other),
      testCase "the observed model comes from message_start, not the configured model" $ do
        (_, ass) <- replay 200 [("request-id", "req_abc123")] successBody
        ass ^. #observedModel @?= Observed "claude-haiku-4-5-20990101-server-side"
        -- Asserted as a difference rather than against a literal
        -- catalog id, which is generated and moves.
        assertBool
          "the fixture's model must differ from the configured one"
          (ass ^. #observedModel /= Observed (anthropic_claude_haiku_4_5 ^. #modelId))
        ass ^. #responseId @?= Just "msg_observed"
        ass ^. #usageReported @?= True,
      testCase "a failed response still yields metadata, and observes no model" $ do
        (metas, ass) <-
          replay
            429
            [("request-id", "req_failed")]
            ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
        case metas of
          [md] -> do
            md ^. #httpStatus @?= 429
            md ^. #headers @?= [("request-id", "req_failed")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other)
        ass ^. #observedModel @?= Unobserved
        ass ^. #usageReported @?= False,
      testCase "a gateway header is captured when Anthropic's own is absent" $ do
        (metas, _) <- replay 200 [("cf-ray", "ray-9"), ("x-request-id", "gw-1")] successBody
        case metas of
          -- Recorded in the order the response listed them; the
          -- adapter's preference order lives in capturedHeaderNames.
          [md] -> md ^. #headers @?= [("cf-ray", "ray-9"), ("x-request-id", "gw-1")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other)
    ]

-- | A complete successful stream whose reported model is not any model
-- in the catalog, so it cannot be confused with a configured one.
successBody :: [ByteString]
successBody =
  [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_observed\",\"type\":\"message\",",
    "\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5-20990101-server-side\",",
    "\"stop_reason\":null,\"stop_sequence\":null,",
    "\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},",
    "\"usage\":{\"output_tokens\":5}}\n\n",
    "data: {\"type\":\"message_stop\"}\n\n"
  ]

-- | Drive a recorded response through the real transport and fold the
-- events it produces through the real translator.
replay ::
  Int -> [(ByteString, ByteString)] -> [ByteString] -> IO ([ResponseMetadata], Assembler)
replay status headers chunks = do
  metaRef <- newIORef []
  eventsRef <- newIORef []
  resp <- mkResponse status headers chunks
  sseFromResponse
    resp
    (\md -> modifyIORef' metaRef (<> [md]))
    (\ev -> modifyIORef' eventsRef (<> [ev]))
  metas <- readIORef metaRef
  events <- readIORef eventsRef
  let ass =
        foldl'
          (\acc ev -> snd (translate ev acc testTime))
          (emptyAssembler anthropic_claude_haiku_4_5 testTime)
          events
  pure (metas, ass)

testTime :: UTCTime
testTime = read "2026-07-03 12:00:00 UTC"

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
