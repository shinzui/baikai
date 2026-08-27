-- | End-to-end model-call evidence for the Anthropic Messages provider.
--
-- Every case here replays a recorded HTTP response through the real
-- adapter and reads the evidence back out of a trace sink. Nothing is
-- stubbed but the socket: the request is built by @mapRequest@, the
-- response is decoded by @sseFromResponse@, the headers are captured by
-- the real allow-list, and the record is assembled and emitted by the
-- real trace path.
--
-- Assertions go through the encoded JSON rather than through Haskell
-- record accessors, because the JSON is the contract other systems pin
-- against, and it spells its fields in snake_case where a Haskell
-- mirror would silently paper over a rename.
module EvidenceSpec (tests) where

import Baikai
import Baikai.Models.Generated (anthropic_claude_haiku_4_5)
import Baikai.Provider.Claude.Api (SseDriver, claudeMessagesStreamWith)
import Baikai.Provider.Claude.Internal.Request (describeThinkingFor)
import Baikai.Provider.Claude.Sse (sseFromResponse)
import Baikai.Trace (withTraceStreamWith)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Contract (assertErrorContract)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    -- Named so this plan's documented
    -- @--test-options='--pattern Evidence'@ actually selects it. A
    -- pattern that matches nothing reports "All 0 tests passed".
    "EvidenceSpec: Anthropic model-call evidence"
    [ successEvidenceTest,
      rateLimitEvidenceTest,
      thinkingEvidenceTest,
      samplingEvidenceTest,
      cacheUsageEvidenceTest,
      immediateErrorRecordsThinkingTest,
      defaultHostEndpointTest,
      optOutTest
    ]

-- ============================================================
-- The cases
-- ============================================================

successEvidenceTest :: TestTree
successEvidenceTest =
  testCase "a replayed successful call records what Anthropic reported" $ do
    ev <- oneEvidence =<< replay 200 successHeaders successBody baseOptions
    field "status" ev @?= Just (String "succeeded")
    field "error_info" ev @?= Just Null
    field "run_id" ev @?= Just (String "run-53")

    -- The heart of it: requested and observed are different values, and
    -- the observed one came from the provider's own message_start.
    field "requested_model" ev @?= Just (String (anthropic_claude_haiku_4_5 ^. #modelId))
    field "observed_model" ev @?= Just (observedJson "claude-haiku-4-5-20990101-server-side")
    assertBool
      "observed_model must not be the configured model"
      (field "observed_model" ev /= Just (observedJson (anthropic_claude_haiku_4_5 ^. #modelId)))

    field "provider_request_id" ev @?= Just (observedJson "req_success_1")
    field "response_id" ev @?= Just (observedJson "msg_observed")
    -- Tied to the declaration mechanically: raising declaredStrength
    -- for this transport without the transport reaching it fails here.
    field "strength" ev @?= Just (Aeson.toJSON (declaredStrength AnthropicMessages))

    -- Anthropic never echoes the thinking configuration it applied, so
    -- this transport cannot reach fully_observed and must not pretend
    -- a reasoning-token count is such an echo.
    field "observed_thinking" ev @?= Just (String "unobserved")

    assertDigest "request_commitment" ev
    assertDigest "request_configuration" ev
    case field "response_commitment" ev of
      Just (Object o) -> case KeyMap.lookup "observed" o of
        Just (String d) -> assertSha256 "response_commitment" d
        other -> assertFailure ("response_commitment not a digest: " <> show other)
      other -> assertFailure ("expected an observed response_commitment, got: " <> show other)

    -- Usage is Observed because Anthropic reported it, and carries the
    -- fixture's counts rather than the assembler's initial zeroes.
    case field "usage" ev of
      Just (Object o) -> case KeyMap.lookup "observed" o of
        Just (Object u) -> do
          KeyMap.lookup "input_tokens" u @?= Just (Number 11)
          KeyMap.lookup "output_tokens" u @?= Just (Number 5)
        other -> assertFailure ("usage.observed not an object: " <> show other)
      other -> assertFailure ("expected an observed usage, got: " <> show other)

    -- The endpoint names this package's own version, read from the
    -- cabal-generated module.
    case field "endpoint" ev of
      Just (Object o) -> do
        KeyMap.lookup "transport" o @?= Just (String "http_api")
        case KeyMap.lookup "implementation_version" o of
          Just (String v) ->
            assertBool "implementation_version must not be empty" (not (Text.null v))
          other -> assertFailure ("expected an implementation_version, got: " <> show other)
      other -> assertFailure ("expected an endpoint object, got: " <> show other)

rateLimitEvidenceTest :: TestTree
rateLimitEvidenceTest =
  testCase "a replayed 429 records the correlation id and observes nothing else" $ do
    ev <-
      oneEvidence
        =<< replay
          429
          [("request-id", "req_rate_limited"), ("Retry-After", "7")]
          ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
          baseOptions
    field "status" ev @?= Just (String "failed")
    case field "error_info" ev of
      Just (Object o) ->
        assertBool
          ("expected the rate-limit message, got: " <> show o)
          (KeyMap.lookup "message" o /= Nothing)
      other -> assertFailure ("expected a populated error_info, got: " <> show other)

    -- The header is present on errors too, and it is the single most
    -- useful thing to have when opening a provider support request.
    field "provider_request_id" ev @?= Just (observedJson "req_rate_limited")

    -- Absent metadata stays absent. None of these is backfilled.
    field "observed_model" ev @?= Just (String "unobserved")
    field "response_id" ev @?= Just (String "unobserved")
    field "response_commitment" ev @?= Just (String "unobserved")
    field "usage" ev @?= Just (String "unobserved")
    field "strength" ev @?= Just (String "correlated")

    -- The same replay as a stream: an HTTP failure that arrives before
    -- @message_start@ still begins with 'EventStart'.
    assertErrorContract
      =<< replayStreamEvents
        429
        [("request-id", "req_rate_limited"), ("Retry-After", "7")]
        ["{\"type\":\"error\",\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow\"}}"]
        baseOptions

thinkingEvidenceTest :: TestTree
thinkingEvidenceTest =
  testCase "the evidence carries the thinking translation the request actually used" $ do
    ev <-
      oneEvidence
        =<< replay
          200
          successHeaders
          successBody
          (baseOptions & #thinking .~ Just ThinkingMinimal)
    case field "thinking" ev of
      Just (Object t) -> do
        KeyMap.lookup "requested" t @?= Just (String "minimal")
        -- haiku-4-5 is a budget-style model, so the level is expressed
        -- exactly and nothing is adjusted.
        KeyMap.lookup "mode" t @?= Just (String "budget")
        KeyMap.lookup "budget_tokens" t @?= Just (Number 1024)
        KeyMap.lookup "effort_text" t @?= Just Null
        KeyMap.lookup "wire_field" t @?= Just (String "thinking")
        KeyMap.lookup "adjustments" t @?= Just (Array Vector.empty)
      other -> assertFailure ("expected a thinking translation, got: " <> show other)

-- | A call refused before the request was built still records the level
-- the caller asked for, described by the adapter's own describer.
--
-- 'Transport.resolveKey' refuses an unknown host rather than reading an
-- environment variable, so 'prepareCall' fails with an AuthError
-- whatever the developer's shell holds, the adapter takes
-- 'immediateError', and the replay driver is never reached.
immediateErrorRecordsThinkingTest :: TestTree
immediateErrorRecordsThinkingTest =
  testCase "a call refused before the request was built still records the requested level" $ do
    let model = testModel & #baseUrl .~ "https://unknown-host.example"
        opts =
          emptyOptions
            & #evidence .~ Just (evidenceRequest "run-53")
            & #thinking .~ Just ThinkingHigh
    ev <- oneEvidence =<< replayWith model 200 successHeaders successBody opts
    field "status" ev @?= Just (String "failed")
    case field "thinking" ev of
      Just (Object t) -> do
        KeyMap.lookup "requested" t @?= Just (String "high")
        let expectedMode = case Aeson.toJSON (describeThinkingFor model opts) of
              Object d -> KeyMap.lookup "mode" d
              _ -> Nothing
        KeyMap.lookup "mode" t @?= expectedMode
        assertBool
          "the mode must not collapse the request into absent"
          (KeyMap.lookup "mode" t /= Just (String "absent"))
      other -> assertFailure ("expected a thinking translation, got: " <> show other)

-- | A model carrying no base URL still records the host the call went
-- to.
--
-- The adapter substitutes Anthropic's host inside 'prepareCall', so the
-- call had a perfectly definite destination while the record said
-- @endpoint: null@. The replay driver ignores the URL, so this asserts
-- what was recorded rather than where the bytes went.
defaultHostEndpointTest :: TestTree
defaultHostEndpointTest =
  testCase "a call with no base URL records the default host it went to" $ do
    ev <-
      oneEvidence
        =<< replayWith (testModel & #baseUrl .~ "") 200 successHeaders successBody baseOptions
    case field "endpoint" ev of
      Just (Object e) -> KeyMap.lookup "endpoint" e @?= Just (String "https://api.anthropic.com")
      other -> assertFailure ("expected an endpoint identity, got: " <> show other)

optOutTest :: TestTree
optOutTest =
  testCase "a call that asked for no evidence emits none" $ do
    events <- replay 200 successHeaders successBody emptyCallOptions
    [e | e@CallEvidence {} <- events] @?= []
    -- The call itself still succeeded and still traced normally.
    length [e | e@CallStarted {} <- events] @?= 1
    length [e | e@CallFinished {} <- events] @?= 1

-- ============================================================
-- Replay harness
-- ============================================================

-- | Run one recorded response through the real adapter and the real
-- trace path, and return every trace event it produced.
replay :: Int -> [(ByteString, ByteString)] -> [ByteString] -> Options -> IO [TraceEvent]
replay = replayWith testModel

-- | 'replay' against a model of the caller's choosing, for the cases
-- whose point is a fact of the model's compat record.
replayWith ::
  Model -> Int -> [(ByteString, ByteString)] -> [ByteString] -> Options -> IO [TraceEvent]
replayWith model status headers chunks opts = do
  reg <- newProviderRegistry
  let driver = replayDriver status headers chunks
      provider =
        ApiProvider
          { apiTag = AnthropicMessages,
            stream = claudeMessagesStreamWith driver,
            complete = streamingComplete (claudeMessagesStreamWith driver),
            describeThinking = describeThinkingFor
          }
  registerApiProviderWith reg provider
  (ref, sink) <- memorySink
  _ <-
    Stream.fold
      Fold.drain
      (withTraceStreamWith reg sink model emptyContext opts)
  reverse <$> readTVarIO ref

-- | The same recorded response, drained as the provider stream itself
-- rather than through the trace path.
--
-- The evidence cases assert what the record says; this asserts that the
-- stream carrying it was protocol-conformant. One replay cannot do both,
-- because 'withTraceStreamWith' hands back trace events, not stream
-- events.
replayStreamEvents ::
  Int -> [(ByteString, ByteString)] -> [ByteString] -> Options -> IO [AssistantMessageEvent]
replayStreamEvents status headers chunks opts =
  Stream.toList
    (claudeMessagesStreamWith (replayDriver status headers chunks) testModel emptyContext opts)

-- | A transport driver that serves a recorded response instead of
-- opening a socket.
--
-- It goes through 'sseFromResponse', so the status classification,
-- header allow-list, and SSE frame decoding under test are the ones
-- production uses. Only 'HTTP.withResponse' is replaced.
replayDriver :: Int -> [(ByteString, ByteString)] -> [ByteString] -> SseDriver
replayDriver status headers chunks _call onMetadata onEvent = do
  resp <- mkResponse status headers chunks
  sseFromResponse resp onMetadata onEvent

mkResponse ::
  Int -> [(ByteString, ByteString)] -> [ByteString] -> IO (HTTP.Response HTTP.BodyReader)
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

memorySink :: IO (TVar [TraceEvent], TraceSink)
memorySink = do
  ref <- newTVarIO []
  let step () e = atomically (modifyTVar' ref (e :))
  pure (ref, TraceSink (Fold.foldlM' step (pure ())))

-- ============================================================
-- Fixtures
-- ============================================================

testModel :: Model
testModel =
  anthropic_claude_haiku_4_5
    & #api .~ AnthropicMessages
    & #baseUrl .~ "https://api.anthropic.com"

-- | A literal key, so 'prepareCall' resolves one without reading the
-- environment. It never reaches the replayed response.
emptyCallOptions :: Options
emptyCallOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")

baseOptions :: Options
baseOptions = emptyCallOptions & #evidence .~ Just (evidenceRequest "run-53")

successHeaders :: [(ByteString, ByteString)]
successHeaders = [("request-id", "req_success_1")]

-- | A complete successful stream whose reported model is deliberately
-- not any model in the catalog, so it cannot be confused with a
-- configured one.
successBody :: [ByteString]
successBody =
  [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_observed\",\"type\":\"message\",",
    "\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5-20990101-server-side\",",
    "\"stop_reason\":null,\"stop_sequence\":null,",
    "\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,",
    "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,",
    "\"delta\":{\"type\":\"text_delta\",\"text\":\"pong\"}}\n\n",
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},",
    "\"usage\":{\"output_tokens\":5}}\n\n",
    "data: {\"type\":\"message_stop\"}\n\n"
  ]

samplingEvidenceTest :: TestTree
samplingEvidenceTest =
  testCase "a dropped sampling parameter appears in the evidence record" $ do
    -- The generation rejects temperature with a 400, so baikai omits
    -- it. What must not happen is that it vanishes: the caller set a
    -- value, and the record says what became of it. The thinking mode
    -- is "absent" here — nothing about thinking was asked — which is
    -- exactly the case a reader would misread as "nothing happened".
    let model =
          testModel
            & #compat
              .~ CompatAnthropicMessages
                (defaultAnthropicMessagesCompat {supportsSamplingParameters = False})
    ev <-
      oneEvidence
        =<< replayWith
          model
          200
          successHeaders
          successBody
          (baseOptions & #temperature .~ Just 0.2)
    case field "thinking" ev of
      Just (Object t) -> do
        KeyMap.lookup "mode" t @?= Just (String "absent")
        KeyMap.lookup "requested" t @?= Just Null
        case KeyMap.lookup "adjustments" t of
          Just (Array adjustments) -> case Vector.toList adjustments of
            [Object a] -> do
              KeyMap.lookup "kind" a
                @?= Just (String "sampling_dropped_unsupported_model")
              KeyMap.lookup "fields" a
                @?= Just (Array (Vector.fromList [String "temperature"]))
            other -> assertFailure ("expected exactly one adjustment, got: " <> show other)
          other -> assertFailure ("expected an adjustments array, got: " <> show other)
      other -> assertFailure ("expected a thinking object, got: " <> show other)

cacheUsageEvidenceTest :: TestTree
cacheUsageEvidenceTest =
  testCase "cache-write and cache-read counts reach the observed usage" $ do
    -- The counts are what the whole cache-pricing story rests on, and
    -- nothing pinned them: cache_creation_input_tokens is what baikai
    -- prices at the catalog's single cacheWriteCost, and totalTokens
    -- must count both cache classes as billed input.
    ev <- oneEvidence =<< replay 200 successHeaders cachedBody baseOptions
    case field "usage" ev of
      Just (Object u) -> case KeyMap.lookup "observed" u of
        Just (Object o) -> do
          KeyMap.lookup "input_tokens" o @?= Just (Number 11)
          KeyMap.lookup "cache_write_tokens" o @?= Just (Number 40)
          KeyMap.lookup "cache_read_tokens" o @?= Just (Number 60)
          KeyMap.lookup "output_tokens" o @?= Just (Number 5)
          KeyMap.lookup "total_tokens" o @?= Just (Number (11 + 40 + 60 + 5))
        other -> assertFailure ("expected an observed usage object, got: " <> show other)
      other -> assertFailure ("expected a usage object, got: " <> show other)

-- | 'successBody' with cache counters on its @message_start@.
cachedBody :: [ByteString]
cachedBody =
  [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_observed\",\"type\":\"message\",",
    "\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5-20990101-server-side\",",
    "\"stop_reason\":null,\"stop_sequence\":null,",
    "\"usage\":{\"input_tokens\":11,\"output_tokens\":0,",
    "\"cache_creation_input_tokens\":40,\"cache_read_input_tokens\":60}}}\n\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,",
    "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,",
    "\"delta\":{\"type\":\"text_delta\",\"text\":\"pong\"}}\n\n",
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},",
    "\"usage\":{\"output_tokens\":5}}\n\n",
    "data: {\"type\":\"message_stop\"}\n\n"
  ]

-- ============================================================
-- Assertions on the encoded record
-- ============================================================

oneEvidence :: [TraceEvent] -> IO ModelCallEvidence
oneEvidence events = case [ev | CallEvidence {evidence = ev} <- events] of
  [ev] -> pure ev
  other ->
    assertFailure
      ("expected exactly one CallEvidence, got " <> show (length other) <> ": " <> show events)

field :: Text -> ModelCallEvidence -> Maybe Value
field k ev = case Aeson.toJSON ev of
  Object o -> KeyMap.lookup (Key.fromText k) o
  _ -> Nothing

-- | How 'Baikai.Evidence.Observed' encodes a present value.
observedJson :: Text -> Value
observedJson v = Object (KeyMap.singleton "observed" (String v))

assertDigest :: Text -> ModelCallEvidence -> IO ()
assertDigest k ev = case field k ev of
  Just (String d) -> assertSha256 k d
  other -> assertFailure (Text.unpack k <> " missing or not a string: " <> show other)

assertSha256 :: Text -> Text -> IO ()
assertSha256 k d =
  assertBool
    (Text.unpack k <> " must be a sha256 digest, got: " <> show d)
    ("sha256:" `Text.isPrefixOf` d && Text.length d == 71)
