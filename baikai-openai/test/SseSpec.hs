module SseSpec (tests) where

import Baikai
import Baikai.Http qualified as Http
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Baikai.Provider.OpenAI.Api
  ( Assembler,
    RawChunk (..),
    SseDriver,
    emptyAssembler,
    openaiChatStreamWith,
    parseFrame,
    translate,
  )
import Baikai.Provider.OpenAI.Sse
  ( ResponseMetadata,
    buildRequest,
    openaiSseStreamValueWithHeaders,
    sseFromResponse,
  )
import Contract (assertErrorContract)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as SBS
import Data.ByteString.Char8 qualified as S8
import Data.ByteString.Lazy qualified as LBS
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
    "Baikai.Provider.OpenAI.Sse"
    [ testCase "non-2xx response preserves Retry-After and status" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <- mkResponse 429 [("Retry-After", "9")] ["{\"error\":{\"message\":\"rate limited\",\"type\":\"tokens\"}}"]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Left e] -> do
            category e @?= RateLimited
            retryAfterSeconds e @?= Just 9
            httpStatus e @?= Just 429
          other -> assertFailure ("expected one classified error, got: " <> show other),
      testCase "[DONE] terminates without emitting a JSON event" $ do
        eventsRef <- newIORef []
        metaRef <- newIORef []
        resp <- mkResponse 200 [] ["data: {\"choices\":[]}\n\n", "data: [DONE]\n\n", "data: {\"ignored\":true}\n\n"]
        sseFromResponse resp (\md -> modifyIORef' metaRef (<> [md])) (\ev -> modifyIORef' eventsRef (<> [ev]))
        events <- readIORef eventsRef
        case events of
          [Right (Aeson.Object _)] -> pure ()
          other -> assertFailure ("expected one JSON event before [DONE], got: " <> show other),
      testCase "an HTTP 401 stream is EventStart then one EventError" $ do
        -- The whole provider stream, not just the transport: what a
        -- consumer sees when the call fails before the first chunk.
        events <- replayStream 401 [] ["{\"error\":{\"message\":\"bad key\",\"type\":\"invalid_request_error\"}}"]
        assertErrorContract events
        case reverse events of
          (EventError TerminalPayload {errorInfo = Just be} : _) -> category be @?= AuthError
          other -> assertFailure ("expected a terminal EventError carrying errorInfo, got: " <> show (take 1 other)),
      observationTests,
      blockClosingTests,
      requestShapeTests,
      redirectTests
    ]

-- | How blocks close when something goes wrong, and what the transport
-- does with a frame it was not written for.
blockClosingTests :: TestTree
blockClosingTests =
  testGroup
    "block closing under failure"
    [ testCase "[DONE] with trailing whitespace terminates without a decode error" $ do
        -- Hosts send @data: [DONE] @ and @data: [DONE]\r@; an exact
        -- comparison turned the end of a healthy stream into a decode
        -- error terminal.
        events <-
          transportEvents
            200
            (init successBody <> ["data: [DONE] \n\n"])
        assertAllRight events
        length events @?= 3,
      testCase "an empty data heartbeat is ignored" $ do
        events <- transportEvents 200 ["data:\n\n", "data: {\"choices\":[]}\n\n", "data: [DONE]\n\n"]
        assertAllRight events
        length events @?= 1,
      testCase "a tool call cut off by finish_reason length closes with its raw argument text" $ do
        let chunks =
              [ toolChunk (Just "call_1") (Just "search") (Just "{\"query\":\"hel"),
                "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n"
              ]
        events <- replayStream 200 [] chunks
        let calls = [tc | ToolCallEnd ToolCallEndPayload {toolCall = tc} <- events]
        case calls of
          [tc] -> do
            tc ^. #arguments @?= Aeson.String "{\"query\":\"hel"
            assertBool "the call is marked cut off" (isCutOffToolCall tc)
          other -> assertFailure ("expected exactly one ToolCallEnd, got: " <> show (length other))
        case reverse events of
          (EventDone TerminalPayload {reason = r} : _) -> r @?= Length
          other -> assertFailure ("expected a terminal EventDone, got: " <> show (take 1 other)),
      -- An upstream failure the host only learned about after
      -- committing to a 200. Before 'parseFrame' this frame parsed as an
      -- empty chunk, was dropped, and the call ended as
      -- OtherError "openai stream ended without finish_reason".
      testCase "an in-band error frame on a 2xx stream reaches the assembler as a classified Left" $ do
        events <-
          replayStream
            200
            []
            [ "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n",
              openRouterErrorFrame,
              "data: [DONE]\n\n"
            ]
        assertErrorContract events
        case reverse events of
          (EventError TerminalPayload {errorInfo = Just be} : _) -> do
            category be @?= TransientError
            httpStatus be @?= Just 502
            be ^. #message @?= "Provider returned error"
          other -> assertFailure ("expected a classified terminal EventError, got: " <> show (take 1 other)),
      testCase "a mid-stream transport error closes open blocks before the terminal" $ do
        -- Injected through 'translate' rather than the transport,
        -- because what is under test is the assembler's Left path: a
        -- classified error arriving with a text block open.
        let (openEvents, ass) =
              translate
                (Right emptyChunk {contentDelta = Just "partial"})
                (emptyAssembler streamTestModel testTime)
                testTime
            (failEvents, _) = translate (Left (providerUnavailable "connection reset mid-stream")) ass testTime
        assertBool
          ("expected a text block to be open, got: " <> show openEvents)
          (not (null [() | TextStart {} <- openEvents]))
        case failEvents of
          [TextEnd BlockEndPayload {contentIndex = 0, content = body}, EventError TerminalPayload {message = msg}] -> do
            body @?= "partial"
            [t | AssistantText (TextContent t) <- Vector.toList (messageBlocks msg)] @?= ["partial"]
          other -> assertFailure ("expected TextEnd then EventError, got: " <> show other)
    ]

toolChunk :: Maybe Text.Text -> Maybe Text.Text -> Maybe Text.Text -> ByteString
toolChunk tid tname targs =
  "data: "
    <> LBS.toStrict
      ( Aeson.encode
          ( Aeson.object
              [ "choices"
                  Aeson..= [ Aeson.object
                               [ "index" Aeson..= (0 :: Int),
                                 "delta"
                                   Aeson..= Aeson.object
                                     [ "tool_calls"
                                         Aeson..= [ Aeson.object
                                                      [ "index" Aeson..= (0 :: Int),
                                                        "id" Aeson..= tid,
                                                        "type" Aeson..= ("function" :: Text.Text),
                                                        "function"
                                                          Aeson..= Aeson.object
                                                            ["name" Aeson..= tname, "arguments" Aeson..= targs]
                                                      ]
                                                  ]
                                     ]
                               ]
                           ]
              ]
          )
      )
    <> "\n\n"

-- | The raw chunk values the transport produced, with no assembler
-- involved.
transportEvents :: Int -> [ByteString] -> IO [Either BaikaiError Aeson.Value]
transportEvents status chunks = do
  eventsRef <- newIORef []
  resp <- mkResponse status [] chunks
  sseFromResponse resp (const (pure ())) (\ev -> modifyIORef' eventsRef (<> [ev]))
  readIORef eventsRef

assertAllRight :: [Either BaikaiError Aeson.Value] -> Assertion
assertAllRight events =
  case [e | Left e <- events] of
    [] -> pure ()
    errs -> assertFailure ("expected no transport errors, got: " <> show errs)

emptyChunk :: RawChunk
emptyChunk =
  RawChunk
    { contentDelta = Nothing,
      reasoningDelta = Nothing,
      finishReason = Nothing,
      toolDeltas = [],
      usage = Nothing,
      model = Nothing,
      responseId = Nothing
    }

messageBlocks :: Message -> Vector AssistantContent
messageBlocks = \case
  AssistantMessage AssistantPayload {content = c} -> c
  _ -> Vector.empty

-- | Drain a recorded response as the provider stream a consumer sees.
replayStream :: Int -> [(ByteString, ByteString)] -> [ByteString] -> IO [AssistantMessageEvent]
replayStream status headers chunks = do
  bodyRef <- newIORef Aeson.Null
  Stream.toList
    (openaiChatStreamWith (replayDriver bodyRef status headers chunks) streamTestModel emptyContext streamTestOptions)

-- | A transport driver that serves a recorded response instead of
-- opening a socket. The same shape as @EvidenceSpec.replayDriver@; the
-- two suites keep their own so neither can silently change the other's
-- fixtures.
replayDriver ::
  IORef Aeson.Value -> Int -> [(ByteString, ByteString)] -> [ByteString] -> SseDriver
replayDriver bodyRef status headers chunks _env _headers body onMetadata onEvent = do
  writeIORef bodyRef body
  resp <- mkResponse status headers chunks
  sseFromResponse resp onMetadata onEvent

streamTestModel :: Model
streamTestModel =
  openai_gpt_4o_mini
    & #api .~ OpenAIChatCompletions
    & #baseUrl .~ "https://api.openai.com"

streamTestOptions :: Options
streamTestOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")

-- | What the transport and the assembler between them can say about
-- what the host reported, as opposed to what was configured.
--
-- The fixture's @model@ deliberately differs from the model the
-- assembler was built with. If they matched, a bug that read the
-- caller's configuration instead of the host's chunk would pass these
-- assertions, which is exactly the substitution the 'Observed' type
-- exists to prevent.
observationTests :: TestTree
observationTests =
  testGroup
    "response observation"
    [ testCase "a 200 response yields one metadata value carrying x-request-id" $ do
        (metas, _) <- replay 200 [("x-request-id", "req_abc123"), ("authorization", "Bearer sk-leak")] successBody
        case metas of
          [md] -> do
            md ^. #httpStatus @?= 200
            -- Allow-list, not denylist: the credential-shaped header the
            -- fixture also carries must not be recorded.
            md ^. #headers @?= [("x-request-id", "req_abc123")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other),
      testCase "the observed model comes from the chunks, not the configured model" $ do
        (_, ass) <- replay 200 [("x-request-id", "req_abc123")] successBody
        ass ^. #observedModel @?= Observed "gpt-4o-mini-20990101-server-side"
        -- Asserted as a difference rather than against a literal catalog
        -- id, which is generated and moves.
        assertBool
          "the fixture's model must differ from the configured one"
          (ass ^. #observedModel /= Observed (openai_gpt_4o_mini ^. #modelId))
        ass ^. #responseId @?= Just "chatcmpl-observed"
        ass ^. #usageReported @?= True,
      testCase "the first reported model wins over a later one" $ do
        (_, ass) <- replay 200 [] disagreeingBody
        ass ^. #observedModel @?= Observed "first-reported-model"
        ass ^. #responseId @?= Just "chatcmpl-first",
      testCase "a failed response still yields metadata, and observes no model" $ do
        (metas, ass) <-
          replay
            429
            [("x-request-id", "req_failed")]
            ["{\"error\":{\"message\":\"rate limited\",\"type\":\"tokens\"}}"]
        case metas of
          [md] -> do
            md ^. #httpStatus @?= 429
            md ^. #headers @?= [("x-request-id", "req_failed")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other)
        ass ^. #observedModel @?= Unobserved
        ass ^. #responseId @?= Nothing
        ass ^. #usageReported @?= False,
      testCase "a gateway header is captured when the host's own is absent" $ do
        (metas, _) <- replay 200 [("cf-ray", "ray-9"), ("x-amzn-requestid", "gw-1")] successBody
        case metas of
          -- Recorded in the order the response listed them; the
          -- adapter's preference order lives in capturedHeaderNames.
          [md] -> md ^. #headers @?= [("cf-ray", "ray-9"), ("x-amzn-requestid", "gw-1")]
          other -> assertFailure ("expected exactly one metadata value, got: " <> show other)
    ]

-- | A complete successful stream whose reported model is not any model
-- in the catalog, so it cannot be confused with a configured one.
successBody :: [ByteString]
successBody =
  [ "data: {\"id\":\"chatcmpl-observed\",\"object\":\"chat.completion.chunk\",",
    "\"model\":\"gpt-4o-mini-20990101-server-side\",",
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"pong\"}}]}\n\n",
    "data: {\"id\":\"chatcmpl-observed\",\"model\":\"gpt-4o-mini-20990101-server-side\",",
    "\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
    "data: {\"id\":\"chatcmpl-observed\",\"model\":\"gpt-4o-mini-20990101-server-side\",",
    "\"choices\":[],\"usage\":{\"prompt_tokens\":11,\"completion_tokens\":5}}\n\n",
    "data: [DONE]\n\n"
  ]

-- | Two chunks reporting different identities. Compatible hosts repeat
-- both fields on every chunk and they are expected to agree; this pins
-- which one is kept if one ever does not, so the answer is a recorded
-- decision rather than whichever chunk happened to arrive last.
disagreeingBody :: [ByteString]
disagreeingBody =
  [ "data: {\"id\":\"chatcmpl-first\",\"model\":\"first-reported-model\",",
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\"}}]}\n\n",
    "data: {\"id\":\"chatcmpl-second\",\"model\":\"second-reported-model\",",
    "\"choices\":[{\"index\":0,\"delta\":{\"content\":\"b\"},\"finish_reason\":\"stop\"}]}\n\n",
    "data: [DONE]\n\n"
  ]

-- | Drive a recorded response through the real transport and fold the
-- chunks it produces through the real parser and translator.
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
          (\acc ev -> snd (translate (parsed ev) acc testTime))
          (emptyAssembler openai_gpt_4o_mini testTime)
          events
  pure (metas, ass)

-- | OpenRouter's mid-stream failure frame: the upstream status as a
-- number in @code@, and a @choices@ array beside the error, so detection
-- cannot key on the absence of @choices@.
openRouterErrorFrame :: ByteString
openRouterErrorFrame =
  "data: {\"error\":{\"message\":\"Provider returned error\",\"code\":502},\
  \\"choices\":[{\"index\":0,\"finish_reason\":\"error\",\"delta\":{}}]}\n\n"

-- | Frames reach the assembler through 'parseFrame', exactly as the
-- worker sends them — so an in-band error frame is sorted out here, not
-- parsed as an empty chunk.
parsed :: Either BaikaiError Aeson.Value -> Either BaikaiError RawChunk
parsed = \case
  Left e -> Left e
  Right v -> case parseFrame v of
    Left err -> Left (providerError (Text.pack err))
    Right frame -> frame

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
-- root, baikai appends `/v1/chat/completions` itself, and a trailing
-- `/v1` is removed rather than doubled — which is why
-- `https://api.deepseek.com/v1`, the spelling every OpenAI SDK teaches,
-- does not request `/v1/v1/...`.
requestShapeTests :: TestTree
requestShapeTests =
  testGroup
    "the request this transport sends"
    [ testCase "one version segment, whatever spelling the base URL used"
        $ forM_
          [ ("https://api.deepseek.com/v1", "/v1/chat/completions"),
            ("https://api.deepseek.com", "/v1/chat/completions"),
            ("https://openrouter.ai/api", "/api/v1/chat/completions"),
            ("https://openrouter.ai/api/v1/", "/api/v1/chat/completions"),
            ( "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
              "/compatible-mode/v1/chat/completions"
            )
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
            openaiSseStreamValueWithHeaders
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
