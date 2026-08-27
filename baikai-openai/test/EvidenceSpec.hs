-- | End-to-end model-call evidence for the OpenAI-compatible Chat
-- Completions provider.
--
-- Every case here replays a recorded HTTP response through the real
-- adapter and reads the evidence back out of a trace sink. Nothing is
-- stubbed but the socket: the request is built by @mapRequest@ and
-- shaped by @streamRequestBody@, the response is decoded by
-- @sseFromResponse@, the headers are captured by the real allow-list,
-- and the record is assembled and emitted by the real trace path.
--
-- Assertions go through the encoded JSON rather than through Haskell
-- record accessors, because the JSON is the contract other systems pin
-- against, and it spells its fields in snake_case where a Haskell
-- mirror would silently paper over a rename.
module EvidenceSpec (tests) where

import Baikai
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Baikai.Provider.OpenAI.Api (SseDriver, openaiChatStreamWith)
import Baikai.Provider.OpenAI.Shape (describeThinkingShape)
import Baikai.Provider.OpenAI.Sse (sseFromResponse)
import Baikai.Trace (withTraceStreamWith)
import Baikai.Trace.Event (TraceEvent (..))
import Baikai.Trace.Sink (TraceSink (..))
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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
    "EvidenceSpec: OpenAI-compatible model-call evidence"
    [ successEvidenceTest,
      rateLimitEvidenceTest,
      toggleHostIndistinguishabilityTest,
      nonReasoningModelEvidenceTest,
      optOutTest
    ]

-- ============================================================
-- The cases
-- ============================================================

successEvidenceTest :: TestTree
successEvidenceTest =
  testCase "a replayed successful call records what the host reported" $ do
    ev <- oneEvidence =<< replayEvents 200 successHeaders successBody baseOptions
    field "status" ev @?= Just (String "succeeded")
    field "error_info" ev @?= Just Null
    field "run_id" ev @?= Just (String "run-54")

    -- The heart of it: requested and observed are different values, and
    -- the observed one came from the host's own chunks.
    field "requested_model" ev @?= Just (String (openai_gpt_4o_mini ^. #modelId))
    field "observed_model" ev @?= Just (observedJson "gpt-4o-mini-20990101-server-side")
    assertBool
      "observed_model must not be the configured model"
      (field "observed_model" ev /= Just (observedJson (openai_gpt_4o_mini ^. #modelId)))

    field "provider_request_id" ev @?= Just (observedJson "req_success_1")
    field "response_id" ev @?= Just (observedJson "chatcmpl-observed")
    -- Tied to the declaration mechanically: raising declaredStrength
    -- for this transport without the transport reaching it fails here.
    field "strength" ev @?= Just (Aeson.toJSON (declaredStrength OpenAIChatCompletions))

    -- No OpenAI-compatible host echoes the reasoning configuration it
    -- applied, so this transport cannot reach fully_observed and must
    -- not pretend a reasoning-token count is such an echo.
    field "observed_thinking" ev @?= Just (String "unobserved")

    assertDigest "request_commitment" ev
    assertDigest "request_configuration" ev
    case field "response_commitment" ev of
      Just (Object o) -> case KeyMap.lookup "observed" o of
        Just (String d) -> assertSha256 "response_commitment" d
        other -> assertFailure ("response_commitment not a digest: " <> show other)
      other -> assertFailure ("expected an observed response_commitment, got: " <> show other)

    -- Usage is Observed because the host reported it, and carries the
    -- fixture's counts rather than the assembler's initial zeroes.
    case field "usage" ev of
      Just (Object o) -> case KeyMap.lookup "observed" o of
        Just (Object u) -> do
          KeyMap.lookup "input_tokens" u @?= Just (Number 11)
          KeyMap.lookup "output_tokens" u @?= Just (Number 5)
        other -> assertFailure ("usage.observed not an object: " <> show other)
      other -> assertFailure ("expected an observed usage, got: " <> show other)

    -- The endpoint names this package's own version, read from the
    -- cabal-generated module, and carries no query string.
    case field "endpoint" ev of
      Just (Object o) -> do
        KeyMap.lookup "transport" o @?= Just (String "http_api")
        KeyMap.lookup "endpoint" o @?= Just (String "https://api.openai.com")
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
        =<< replayEvents
          429
          [("x-request-id", "req_rate_limited"), ("Retry-After", "7")]
          ["{\"error\":{\"message\":\"slow down\",\"type\":\"tokens\"}}"]
          baseOptions
    field "status" ev @?= Just (String "failed")
    case field "error_info" ev of
      Just (Object o) ->
        assertBool
          ("expected the rate-limit message, got: " <> show o)
          (KeyMap.member "message" o)
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

-- | Two calls a toggle host cannot tell apart, which baikai's record
-- can.
--
-- Z.ai and Qwen accept @enable_thinking: true@ and carry no depth, so a
-- caller asking for @max@ and a caller asking for @low@ put the same
-- bytes on the wire. Without the translation there is nothing anywhere
-- in baikai's output that distinguishes the two; with it, the request
-- each caller made is recorded beside the request that was actually
-- sent.
toggleHostIndistinguishabilityTest :: TestTree
toggleHostIndistinguishabilityTest =
  testCase "a toggle host receives identical bytes for max and for low" $ do
    (lowBody, lowEv) <- toggleCall ThinkingLow
    (maxBody, maxEv) <- toggleCall ThinkingMax

    Aeson.encode lowBody @?= Aeson.encode maxBody
    lookupIn "enable_thinking" lowBody @?= Just (Bool True)
    lookupIn "reasoning_effort" lowBody @?= Nothing

    thinkingOf lowEv "requested" @?= Just (String "low")
    thinkingOf maxEv "requested" @?= Just (String "max")
    thinkingOf lowEv "mode" @?= Just (String "toggle")
    thinkingOf lowEv "wire_field" @?= Just (String "enable_thinking")
    thinkingOf lowEv "effort_text" @?= Just Null

    collapsedLevels lowEv @?= ["low"]
    collapsedLevels maxEv @?= ["max"]
  where
    toggleCall lvl = do
      bodyRef <- newIORef Null
      events <-
        replayWith
          bodyRef
          toggleModel
          200
          successHeaders
          successBody
          (baseOptions & #thinking .~ Just lvl)
      ev <- oneEvidence events
      body <- readIORef bodyRef
      pure (body, ev)

    -- Every adjustment must be the collapse, and this returns the level
    -- each one names — so a run that recorded some other adjustment
    -- fails rather than quietly matching an empty list.
    collapsedLevels ev = case thinkingOf ev "adjustments" of
      Just (Array adjs) ->
        [ lvl
        | Object a <- Vector.toList adjs,
          KeyMap.lookup "kind" a == Just (String "effort_collapsed_to_toggle"),
          Just (String lvl) <- [KeyMap.lookup "requested" a]
        ]
      _ -> []

optOutTest :: TestTree
optOutTest =
  testCase "a call that asked for no evidence emits none" $ do
    events <- replayEvents 200 successHeaders successBody emptyCallOptions
    [e | e@CallEvidence {} <- events] @?= []
    -- The call itself still succeeded and still traced normally.
    length [e | e@CallStarted {} <- events] @?= 1
    length [e | e@CallFinished {} <- events] @?= 1

-- ============================================================
-- Replay harness
-- ============================================================

-- | Run one recorded response through the real adapter and the real
-- trace path, and return every trace event it produced.
replayEvents :: Int -> [(ByteString, ByteString)] -> [ByteString] -> Options -> IO [TraceEvent]
replayEvents status headers chunks opts = do
  sink <- newIORef Null
  replayWith sink testModel status headers chunks opts

-- | 'replayEvents' against an explicit model, recording the request body
-- the adapter handed to the transport.
replayWith ::
  IORef Value ->
  Model ->
  Int ->
  [(ByteString, ByteString)] ->
  [ByteString] ->
  Options ->
  IO [TraceEvent]
replayWith bodyRef model status headers chunks opts = do
  reg <- newProviderRegistry
  let driver = replayDriver bodyRef status headers chunks
      provider =
        ApiProvider
          { apiTag = OpenAIChatCompletions,
            stream = openaiChatStreamWith driver,
            complete = streamingComplete (openaiChatStreamWith driver),
            describeThinking = \m opts' ->
              describeThinkingShape (openaiCompletionsCompatFor m) (m ^. #reasoning) opts'
          }
  registerApiProviderWith reg provider
  (ref, sink) <- memorySink
  _ <-
    Stream.fold
      Fold.drain
      (withTraceStreamWith reg sink model emptyContext opts)
  reverse <$> readTVarIO ref

-- | A transport driver that serves a recorded response instead of
-- opening a socket, and records the request body it was given.
--
-- It goes through 'sseFromResponse', so the status classification,
-- header allow-list, and SSE frame decoding under test are the ones
-- production uses. Only 'HTTP.withResponse' is replaced.
replayDriver ::
  IORef Value -> Int -> [(ByteString, ByteString)] -> [ByteString] -> SseDriver
replayDriver bodyRef status headers chunks _env _headers body onMetadata onEvent = do
  writeIORef bodyRef body
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
  openai_gpt_4o_mini
    & #api .~ OpenAIChatCompletions
    & #baseUrl .~ "https://api.openai.com"

-- | The same model pinned to a host that accepts a bare thinking
-- toggle, which is the shape the indistinguishability case is about.
--
-- @reasoning@ is forced on: 'testModel' is @gpt-4o-mini@, which cannot
-- reason, and a level on such a model is now dropped before the host's
-- shape is consulted. The case is about the /host/ collapsing every
-- level onto one toggle, so it needs a model that reaches the host at
-- all. 'ShapeSpec.nonReasoningModelGateTest' covers the other half.
toggleModel :: Model
toggleModel =
  testModel
    & #reasoning .~ True
    & #compat
      .~ CompatOpenAICompletions
        defaultOpenAICompletionsCompat {thinkingFormat = ThinkingFormatZai}

-- | A literal key, so 'prepareCall' resolves one without reading the
-- environment. It never reaches the replayed response.
emptyCallOptions :: Options
emptyCallOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")

baseOptions :: Options
baseOptions = emptyCallOptions & #evidence .~ Just (evidenceRequest "run-54")

successHeaders :: [(ByteString, ByteString)]
successHeaders = [("x-request-id", "req_success_1")]

-- | A complete successful stream whose reported model is deliberately
-- not any model in the catalog, so it cannot be confused with a
-- configured one.
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

nonReasoningModelEvidenceTest :: TestTree
nonReasoningModelEvidenceTest =
  testCase "a level on a non-reasoning model is dropped and the record says so" $ do
    -- gpt-4o-mini cannot reason. Before this, a level on it put
    -- reasoning_effort on the wire and took a 400; now nothing is sent
    -- and the record names the drop, which is what
    -- docs/user/model-call-evidence.md has always promised baikai-wide.
    bodyRef <- newIORef Null
    events <-
      replayWith
        bodyRef
        testModel
        200
        successHeaders
        successBody
        (baseOptions & #thinking .~ Just ThinkingMax)
    ev <- oneEvidence events
    body <- readIORef bodyRef
    lookupIn "reasoning_effort" body @?= Nothing
    thinkingOf ev "mode" @?= Just (String "unsupported")
    thinkingOf ev "requested" @?= Just (String "max")
    thinkingOf ev "wire_field" @?= Just Null
    case thinkingOf ev "adjustments" of
      Just (Array adjustments) -> case Vector.toList adjustments of
        [Object a] -> do
          KeyMap.lookup "kind" a @?= Just (String "thinking_dropped_unsupported_model")
          KeyMap.lookup "requested" a @?= Just (String "max")
        other -> assertFailure ("expected exactly one adjustment, got: " <> show other)
      other -> assertFailure ("expected an adjustments array, got: " <> show other)

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
field k ev = lookupIn k (Aeson.toJSON ev)

lookupIn :: Text -> Value -> Maybe Value
lookupIn k = \case
  Object o -> KeyMap.lookup (Key.fromText k) o
  _ -> Nothing

thinkingOf :: ModelCallEvidence -> Text -> Maybe Value
thinkingOf ev k = field "thinking" ev >>= lookupIn k

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
