module SseSpec (tests) where

import Baikai
import Baikai.Http qualified as Http
import Baikai.Models.Generated (anthropic_claude_haiku_4_5)
import Baikai.Provider.Claude.Internal.Stream (Assembler, SseDriver, claudeMessagesStreamWith, emptyAssembler, translate)
import Baikai.Provider.Claude.Sse
  ( ResponseMetadata,
    buildRequest,
    claudeSseStreamValueWithHeaders,
    sseFromResponse,
  )
import Claude.V1.Messages qualified as Messages
import Contract (assertErrorContract)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as SBS
import Data.ByteString.Char8 qualified as S8
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Servant.Client qualified as Client
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

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
      -- CDN-fronted hosts send a date rather than a count on a 429.
      -- The response's own Date is the reference instant, so the hint
      -- does not inherit this machine's clock skew.
      testCase "HTTP-date Retry-After is converted using the response Date header" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <-
          mkResponse
            429
            [ ("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT"),
              ("Date", "Wed, 21 Oct 2026 07:27:15 GMT")
            ]
            ["{\"error\":{\"message\":\"slow down\"}}"]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> do
            category e @?= RateLimited
            retryAfterSeconds e @?= Just 45
          other -> assertFailure ("expected one classified error, got: " <> show other),
      testCase "HTTP-date Retry-After without a Date header uses the current time" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <- mkResponse 429 [("Retry-After", "Wed, 21 Oct 2099 07:28:00 GMT")] [""]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> case retryAfterSeconds e of
            Just n -> assertBool ("a date in 2099 is far in the future, got " <> show n) (n > 0)
            Nothing -> assertFailure "expected a converted Retry-After hint"
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
      observationTests,
      requestShapeTests,
      redirectTests
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
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other),
      failureStreamTests,
      blockClosingTests
    ]

-- | How blocks close when something goes wrong, and what the transport
-- does with a frame it was not written for.
--
-- The point of the group is that a consumer reading raw events and a
-- consumer reassembling them see the same partial output, and that a
-- frame Anthropic adds later does not end a healthy stream.
blockClosingTests :: TestTree
blockClosingTests =
  testGroup
    "block closing under failure"
    [ testCase "a tool call cut off by max_tokens closes with its raw argument text" $ do
        events <- replayStream 200 [] cutOffToolBody
        let calls = [tc | ToolCallEnd ToolCallEndPayload {toolCall = tc} <- events]
        case calls of
          [tc] -> do
            tc ^. #arguments @?= Aeson.String "{\"query\":\"hel"
            assertBool "the call is marked cut off" (isCutOffToolCall tc)
          other -> assertFailure ("expected exactly one ToolCallEnd, got: " <> show (length other))
        case reverse events of
          (EventDone TerminalPayload {reason = r, message = msg} : _) -> do
            r @?= Length
            [tc | AssistantToolCall tc <- Vector.toList (messageBlocks msg)] @?= calls
          other -> assertFailure ("expected a terminal EventDone, got: " <> show (take 1 other)),
      testCase "a mid-stream transport error closes open blocks before the terminal" $ do
        -- The failure is injected through 'translate' rather than the
        -- transport, because what is under test is the assembler's
        -- Left path: a classified error arriving with a text block open.
        (openEvents, ass) <- replayTranslate openTextBody
        let (failEvents, _) = translate (Left (providerUnavailable "connection reset mid-stream")) ass testTime
        assertBool
          ("expected a text block to be open, got: " <> show openEvents)
          (not (null [() | TextStart {} <- openEvents]))
        case failEvents of
          [TextEnd BlockEndPayload {contentIndex = 0, content = body}, EventError TerminalPayload {message = msg}] -> do
            body @?= "partial"
            [t | AssistantText (TextContent t) <- Vector.toList (messageBlocks msg)] @?= ["partial"]
          other -> assertFailure ("expected TextEnd then EventError, got: " <> show other),
      testCase "an unknown event type is skipped without ending the stream" $ do
        events <-
          transportEvents
            200
            [ frameOf "{\"type\":\"message_stop\"}",
              frameOf "{\"type\":\"message_checkpoint\",\"checkpoint\":\"abc\"}",
              frameOf "{\"type\":\"ping\"}"
            ]
        assertAllRight events
        length events @?= 2,
      testCase "an unknown delta type is skipped without ending the stream" $ do
        events <-
          transportEvents
            200
            [ frameOf "{\"type\":\"message_stop\"}",
              frameOf "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citations_delta\",\"citation\":{}}}",
              frameOf "{\"type\":\"ping\"}"
            ]
        assertAllRight events
        length events @?= 2,
      testCase "an empty data heartbeat is ignored" $ do
        events <- transportEvents 200 ["data:\n\n", frameOf "{\"type\":\"message_stop\"}"]
        assertAllRight events
        length events @?= 1
    ]

-- | A stream that opens a tool call, streams half its arguments, and is
-- cut off by the output cap.
cutOffToolBody :: [ByteString]
cutOffToolBody =
  [ frameOf
      "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_cutoff\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-cutoff\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":4,\"output_tokens\":0}}}",
    frameOf
      "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"search\",\"input\":{}}}",
    frameOf
      "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"query\\\":\\\"hel\"}}",
    frameOf "{\"type\":\"content_block_stop\",\"index\":0}",
    frameOf "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":9}}",
    frameOf "{\"type\":\"message_stop\"}"
  ]

-- | A stream that opens a text block and streams one delta into it,
-- and stops there: the state a mid-stream failure finds.
openTextBody :: [ByteString]
openTextBody =
  [ frameOf
      "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_open\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-open\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":2,\"output_tokens\":0}}}",
    frameOf "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
    frameOf "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}"
  ]

frameOf :: ByteString -> ByteString
frameOf body = "data: " <> body <> "\n\n"

-- | The raw events the transport produced, with no assembler involved.
transportEvents ::
  Int -> [ByteString] -> IO [Either BaikaiError Messages.MessageStreamEvent]
transportEvents status chunks = do
  eventsRef <- newIORef []
  resp <- mkResponse status [] chunks
  sseFromResponse resp (const (pure ())) (\ev -> modifyIORef' eventsRef (<> [ev]))
  readIORef eventsRef

assertAllRight :: [Either BaikaiError Messages.MessageStreamEvent] -> Assertion
assertAllRight events =
  case [e | Left e <- events] of
    [] -> pure ()
    errs -> assertFailure ("expected no transport errors, got: " <> show errs)

-- | Replay through the real transport and fold the result through the
-- real translator, returning both the events emitted and the assembler
-- state they left behind.
replayTranslate :: [ByteString] -> IO ([AssistantMessageEvent], Assembler)
replayTranslate chunks = do
  raw <- transportEvents 200 chunks
  pure
    ( foldl'
        ( \(acc, a) ev ->
            let (evs, a') = translate ev a testTime in (acc <> evs, a')
        )
        ([], emptyAssembler anthropic_claude_haiku_4_5 testTime)
        raw
    )

messageBlocks :: Message -> Vector AssistantContent
messageBlocks = \case
  AssistantMessage AssistantPayload {content = c} -> c
  _ -> Vector.empty

-- | Every way a Claude stream can fail before Anthropic has said
-- anything about the response.
--
-- The point of the group is one invariant: the protocol's
-- "'EventStart' first, exactly one terminal" holds even when the
-- failure precedes @message_start@, which is the frame that used to
-- carry the start event. Each case drains the whole provider stream
-- through the real transport, so what is asserted is what a consumer
-- would actually see.
failureStreamTests :: TestTree
failureStreamTests =
  testGroup
    "failure streams are protocol-conformant"
    [ testCase "an HTTP 401 before message_start is EventStart then one EventError" $ do
        events <-
          replayStream
            401
            []
            ["{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"}}"]
        assertErrorContract events
        terminalError events >>= \be -> category be @?= AuthError,
      testCase "an HTTP 429 before message_start keeps EventStart first and Retry-After on the terminal" $ do
        events <-
          replayStream
            429
            [("Retry-After", "7")]
            ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
        assertErrorContract events
        be <- terminalError events
        category be @?= RateLimited
        retryAfterSeconds be @?= Just 7,
      testCase "an in-band error event before message_start is EventStart then one EventError" $ do
        events <-
          replayStream
            200
            []
            ["data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n"]
        assertErrorContract events
        terminalError events >>= \be -> category be @?= TransientError,
      testCase "EOF before message_start is EventStart then one EventError" $ do
        events <- replayStream 200 [] []
        assertErrorContract events
        be <- terminalError events
        be ^. #message @?= "claude stream ended without message_stop",
      testCase "message_start updates the skeleton and emits no second EventStart" $ do
        events <- replayStream 200 [] successBody
        length [() | EventStart {} <- events] @?= 1
        case events of
          -- The pre-seeded start carries no id: Anthropic has not sent
          -- one yet when it is emitted.
          (EventStart StartPayload {responseId = rid} : _) -> rid @?= Nothing
          other -> assertFailure ("expected EventStart first, got: " <> show (take 1 other))
        case reverse events of
          (EventDone TerminalPayload {responseId = rid} : _) -> rid @?= Just "msg_observed"
          other -> assertFailure ("expected a terminal EventDone, got: " <> show (take 1 other))
        resp <- Stream.fold (reassembleResponse testModel) (Stream.fromList events)
        resp ^. #responseId @?= Just "msg_observed"
    ]

-- | Drain a recorded response as the provider stream a consumer sees.
replayStream :: Int -> [(ByteString, ByteString)] -> [ByteString] -> IO [AssistantMessageEvent]
replayStream status headers chunks =
  Stream.toList
    (claudeMessagesStreamWith (replayDriver status headers chunks) testModel emptyContext testOptions)

-- | A transport driver that serves a recorded response instead of
-- opening a socket. The same eleven lines as
-- @EvidenceSpec.replayDriver@; the two suites keep their own so neither
-- can silently change the other's fixtures.
replayDriver :: Int -> [(ByteString, ByteString)] -> [ByteString] -> SseDriver
replayDriver status headers chunks _call onMetadata onEvent = do
  resp <- mkResponse status headers chunks
  sseFromResponse resp onMetadata onEvent

-- | The typed error on a stream's terminal. 'errorInfo' is a 'Maybe';
-- whether a failed stream carries a typed error at all is part of what
-- these cases assert.
terminalError :: [AssistantMessageEvent] -> IO BaikaiError
terminalError events = case reverse events of
  (EventError TerminalPayload {errorInfo = Just be} : _) -> pure be
  other -> assertFailure ("expected a terminal EventError carrying errorInfo, got: " <> show (take 1 other))

testModel :: Model
testModel =
  anthropic_claude_haiku_4_5
    & #api .~ AnthropicMessages
    & #baseUrl .~ "https://api.anthropic.com"

testOptions :: Options
testOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")

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

-- --------------------------------------------------------------------
-- What goes on the wire
-- --------------------------------------------------------------------

-- | The composed path and the redirect policy, asserted on the pure
-- request rather than by opening a connection.
--
-- The path cases are the base-URL convention: `Model.baseUrl` is the API
-- root, baikai appends `/v1/messages` itself, and a trailing
-- `/v1` is removed rather than doubled — which is why
-- `https://api.deepseek.com/v1`, the spelling every OpenAI SDK teaches,
-- does not request `/v1/v1/...`.
requestShapeTests :: TestTree
requestShapeTests =
  testGroup
    "the request this transport sends"
    [ testCase "one version segment, whatever spelling the base URL used"
        $ forM_
          [ ("https://api.anthropic.com/v1", "/v1/messages"),
            ("https://api.anthropic.com", "/v1/messages"),
            ("https://gateway.test/anthropic", "/anthropic/v1/messages"),
            ("https://gateway.test/anthropic/v1/", "/anthropic/v1/messages")
          ]
        $ \(url, expected) -> case Http.canonicalBaseUrl url of
          Left problem -> assertFailure (Text.unpack (url <> " was refused: " <> problem))
          Right base -> do
            let request = buildRequest base [] (Aeson.object [])
            (url, HTTP.path request) @?= (url, S8.pack expected),
      testCase "the request never follows a redirect" $
        case Http.canonicalBaseUrl "https://h.test" of
          Left problem -> assertFailure (Text.unpack problem)
          Right base -> do
            let request = buildRequest base [] (Aeson.object [])
            HTTP.redirectCount request @?= 0
            HTTP.method request @?= "POST"
    ]

-- --------------------------------------------------------------------
-- A 3xx is an error, not a hop
-- --------------------------------------------------------------------

-- | A 302 is delivered as the terminal error and no second connection is
-- ever opened.
--
-- @http-client@'s default is to follow up to ten redirects with every
-- header intact, so before `redirectCount = 0` this test recorded a
-- second connection — to whatever host the `Location` header named —
-- carrying the caller's bearer token.
--
-- The "server" is an in-process fake built from `managerRawConnection`,
-- which is what lets the case observe /which hosts a connection was
-- opened to/ directly, with no socket and no port.
redirectTests :: TestTree
redirectTests =
  testGroup
    "redirects"
    [ testCase "a 302 is the terminal error and no second host is contacted" $ do
        attemptsRef <- newIORef []
        manager <- fakeRedirectingManager attemptsRef
        case Http.canonicalBaseUrl "http://proxy.test" of
          Left problem -> assertFailure (Text.unpack problem)
          Right base -> do
            let env = Client.mkClientEnv manager base
            eventsRef <- newIORef []
            metaRef <- newIORef []
            claudeSseStreamValueWithHeaders
              env
              [("Authorization", "Bearer sk-test")]
              (Aeson.object [])
              (\md -> modifyIORef' metaRef (<> [md]))
              (\ev -> modifyIORef' eventsRef (<> [ev]))
            attempts <- readIORef attemptsRef
            attempts @?= [("proxy.test", 80)]
            events <- readIORef eventsRef
            case events of
              [Left e] -> httpStatus e @?= Just 302
              other -> assertFailure ("expected one 302 error, got: " <> show other)
    ]

-- | A manager whose every connection answers one 302 pointing at another
-- host, and records the host and port it was opened to.
fakeRedirectingManager :: IORef [(String, Int)] -> IO HTTP.Manager
fakeRedirectingManager attemptsRef =
  HTTP.newManager
    HTTP.defaultManagerSettings
      { HTTP.managerRawConnection = pure open
      }
  where
    open _ host portNumber = do
      modifyIORef' attemptsRef (<> [(host, portNumber)])
      remaining <- newIORef [redirectResponse]
      HTTP.makeConnection
        (atomicModifyIORef' remaining (\chunks -> case chunks of [] -> ([], SBS.empty); (c : cs) -> (cs, c)))
        (\_ -> pure ())
        (pure ())
    redirectResponse =
      S8.pack
        "HTTP/1.1 302 Found\r\nLocation: http://evil.test/steal\r\nContent-Length: 0\r\n\r\n"
