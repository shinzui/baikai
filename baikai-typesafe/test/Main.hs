module Main (main) where

import Baikai
import Baikai.Cost.Log qualified as Log
import Baikai.Evidence qualified as Ev
import Baikai.Models.Generated (typesafe_jev_latest)
import Baikai.Provider.TypeSafe.Api (typesafeProvider)
import Baikai.Provider.TypeSafe.Internal.Request qualified as R
import Baikai.Provider.TypeSafe.Internal.Response qualified as D
import Baikai.Trace qualified as Trace
import Baikai.Trace.Event qualified as Tr
import Baikai.Trace.Sink qualified as Sink
import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar
import Control.Exception (AsyncException (ThreadKilled), SomeException, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified
import Data.Vector qualified as V
import HttpFixture qualified as F
import Streamly.Data.Stream qualified as Stream
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit

fixture :: String -> IO A.Value
fixture n = BL.readFile ("test/fixtures/" <> n <> ".json") >>= either assertFailure pure . A.eitherDecode

validContext :: Context
validContext = contextOf [userData (A.object ["ticket" A..= ("Checkout is unavailable." :: Text)])]

options :: A.Value -> Options
options s = emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "fixture" s))

set :: [Text] -> A.Value -> A.Value -> A.Value
set [] v _ = v
set (k : ks) v (A.Object o) = A.Object (KM.insert (K.fromText k) (set ks v (maybe A.Null id (KM.lookup (K.fromText k) o))) o)
set _ _ old = old

delete :: [Text] -> A.Value -> A.Value
delete [k] (A.Object o) = A.Object (KM.delete (K.fromText k) o)
delete (k : ks) (A.Object o) = A.Object (maybe o (\v -> KM.insert (K.fromText k) (delete ks v) o) (KM.lookup (K.fromText k) o))
delete _ old = old

main :: IO ()
main = defaultMain (testGroup "TypeSafe" [pureTests, httpTests])

pureTests :: TestTree
pureTests =
  testGroup
    "wire contract"
    [ testCase "exact request, criteria variant and preserved response" $ do
        s <- fixture "schema"
        expected <- fixture "request"
        reply <- fixture "response"
        forM_ [False, True] $ \criteria -> do
          let schema = if criteria then set ["properties", "urgent"] (A.object ["description" A..= ("Is service blocked?" :: Text), "anyOf" A..= [A.object ["const" A..= True, "description" A..= ("Blocked" :: Text)], A.object ["const" A..= False, "description" A..= ("Degraded or fine" :: Text)]]]) s else s
          (js, request) <- either (assertFailure . show) pure (R.prepareRequest typesafe_jev_latest validContext (options schema))
          let wanted = if criteria then set ["questions", "urgent", "criteria"] (A.object ["true" A..= ("Blocked" :: Text), "false" A..= ("Degraded or fine" :: Text)]) expected else expected
          A.eitherDecode (R.requestBytes request) @?= Right wanted
          (dat, observed, u) <- either (assertFailure . show) pure (D.decodeResponse typesafe_jev_latest js (A.encode reply))
          observed @?= "jev-fixture-version"
          u ^. #inputTokens @?= 120
          dat ^. #value @?= A.object ["urgent" A..= True, "category" A..= ("technical" :: Text), "severity" A..= (1.5 :: Double)]
          dat ^. #confidence @?= Just (Map.fromList [("category", 0.65), ("severity", 0.55)]),
      testCase "numeric and boolean descriptions and scalar state are typed refusals" $ do
        s <- fixture "schema"
        forM_ [A.Number 0, A.Bool False] $ \v -> do
          case R.prepareRequest typesafe_jev_latest validContext (options (set ["properties", "severity", "description"] v s)) of
            Left e -> e ^. #requestProblem @?= Just (UnsupportedFeature "Options.responseFormat.schema.properties.severity.description")
            _ -> assertFailure "instruction refusal required"
        forM_ [A.Null, A.Bool True, A.Number 1] $ \v ->
          assertBool "scalar state refused" (isLeft (R.prepareRequest typesafe_jev_latest (contextOf [userData v]) (options s))),
      testCase "malformed answer and response matrix" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        (js, _) <- either (assertFailure . show) pure (R.prepareRequest typesafe_jev_latest validContext (options s))
        forM_ (malformed reply) $ \bad -> case D.decodeResponse typesafe_jev_latest js (A.encode bad) of
          Left e -> e ^. #category @?= DecodeFailure
          Right _ -> assertFailure "malformed response accepted"
        forM_ ["{}", "[]", "{", "null"] $ \bytes -> assertBool "bad envelope" (isLeft (D.decodeResponse typesafe_jev_latest js bytes))
        old <- BL.readFile "test/fixtures/dspy-2026-09-26-response.json"
        assertBool "dated DSPy shape rejected" (isLeft (D.decodeResponse typesafe_jev_latest js old))
    ]

registry :: IO ProviderRegistry
registry = do
  reg <- newProviderRegistry
  registerApiProviderWith reg typesafeProvider
  pure reg

call :: Bool -> ProviderRegistry -> Model -> Context -> Options -> IO Response
call False = completeRequestWith
call True = \reg m c o -> do
  es <- Stream.toList (streamRequestWith reg m c o)
  length [() | EventStart _ <- es] @?= 1
  length (filter isTerminal es) @?= 1
  let success = not (null [() | EventDone _ <- es])
  length [() | DataStart _ <- es] @?= if success then 1 else 0
  length [() | DataEnd _ <- es] @?= if success then 1 else 0
  Stream.fold (reassembleResponse m) (Stream.fromList es)

fixtureModel :: F.Fixture -> Model
fixtureModel server = typesafe_jev_latest & #baseUrl .~ F.base server

fixtureOptions :: A.Value -> Options
fixtureOptions s = options s & #apiKey .~ Just (ApiKeyLiteral "fixture-key")

httpTests :: TestTree
httpTests =
  testGroup
    "registered HTTP"
    [ testCase "exact POST through complete and stream, evidence, response codec, trace and both logs" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        wanted <- fixture "request"
        forM_ [False, True] $ \streaming -> F.withFixture 200 [("x-typesafe-request-id", "fixture-42")] (F.Reply (A.encode reply)) $ \server -> do
          reg <- registry
          let m = fixtureModel server
              o = fixtureOptions s & #evidence .~ Just (evidenceRequest "fixture")
          r <- call streaming reg m validContext o
          responseError r @?= Nothing
          let ds = flattenAssistantData (r ^. #message . #content)
          V.length ds @?= 1
          case r ^. #evidence of
            Just e -> do
              e ^. #requestedModel @?= "jev-latest"
              e ^. #observedModel @?= Observed "jev-fixture-version"
              e ^. #providerRequestId @?= Observed "fixture-42"
              e ^. #responseId @?= Unobserved
              e ^. #requestCommitment @?= commitmentDigest wanted
              assertBool "pricing is unavailable" (PricingUnavailable `elem` (estimateReasons ((r ^. #message . #usage . #cost) ^. #basis)))
            Nothing -> assertFailure "evidence missing"
          case parseEither responseFromJSON (responseToJSON r) of
            Left e -> assertFailure e
            Right decoded -> canonicalEncode (responseToJSON decoded) @?= canonicalEncode (responseToJSON r)
          captured <- F.captures server
          case captured of
            [F.Captured path headers bytes] -> do
              path @?= "/v1/systemone"
              lookup "Authorization" headers @?= Just "Bearer fixture-key"
              A.eitherDecode bytes @?= Right wanted
            _ -> assertFailure (show captured)
          withSystemTempDirectory "typesafe-evidence" $ \dir -> do
            sink <- Sink.fileSink (dir </> "trace.jsonl")
            Log.withCallLog (Log.callLogConfig (dir </> "calls.jsonl")) $ \h -> do
              _ <- Trace.runRequestWithRegistry reg sink h m validContext (fixtureOptions s)
              _ <- Log.runRequestWithLogWith reg h m validContext (fixtureOptions s)
              pure ()
            traceBytes <- BL.readFile (dir </> "trace.jsonl")
            let traceLines = filter (not . BL.null) (BL.split 10 traceBytes)
            ts <- either assertFailure pure (traverse A.eitherDecode traceLines :: Either String [Tr.TraceEvent])
            [d | Tr.CallFinished {Tr.structuredData = d} <- ts] @?= [Just ds]
            logBytes <- BL.readFile (dir </> "calls.jsonl")
            logs <- either assertFailure pure (traverse A.eitherDecode (filter (not . BL.null) (BL.split 10 logBytes)) :: Either String [Log.CallLogEntry])
            map (^. #structuredData) logs @?= replicate 2 (Just ds),
      testCase "HTTP noul criteria variant, accepted cardinalities, strict/opted-out evidence and custom-host auth" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        wanted <- fixture "request"
        let criteria = A.object ["description" A..= ("Is service blocked?" :: Text), "anyOf" A..= [A.object ["const" A..= True, "description" A..= ("Blocked" :: Text)], A.object ["const" A..= False, "description" A..= ("Degraded or fine" :: Text)]]]
            schema = set ["properties", "urgent"] criteria s
            expected = set ["questions", "urgent", "criteria"] (A.object ["true" A..= ("Blocked" :: Text), "false" A..= ("Degraded or fine" :: Text)]) wanted
        forM_ [False, True] $ \streaming -> F.withFixture 200 [("x-typesafe-request-id", "fixture-42")] (F.Reply (A.encode reply)) $ \server -> do
          reg <- registry
          r <- call streaming reg (fixtureModel server) validContext (fixtureOptions schema & #evidence .~ Just (evidenceRequest "strict" & #strictness .~ EvidenceRequired EvidenceModelObserved))
          responseError r @?= Nothing
          case r ^. #evidence of Just _ -> pure (); _ -> assertFailure "required evidence missing"
          captured <- F.captures server
          case captured of [F.Captured _ _ b] -> A.eitherDecode b @?= Right expected; _ -> assertFailure "one request expected"
          optedOut <- call streaming reg (fixtureModel server) validContext (fixtureOptions schema)
          optedOut ^. #evidence @?= Nothing
        F.withFixture 200 [] (F.Reply (A.encode reply)) $ \server -> do
          reg <- registry
          r <- call False reg (fixtureModel server) validContext (options s)
          fmap (^. #category) (responseError r) @?= Just AuthError
          F.captures server >>= (@?= [])
        defaultApiKeyEnvForBaseUrl "https://api.typesafe.ai/v1" @?= Just "TYPESAFE_API_KEY"
        forM_ [255, 2, 10] $ \n -> do
          let isChoice = n == 255
              labels = if isChoice then map (A.String . Data.Text.pack . show) [0 .. n - 1] else map A.toJSON [0 .. n - 1 :: Int]
              schemaN = A.object ["type" A..= ("object" :: Text), "properties" A..= A.object ["x" A..= A.object ["enum" A..= labels]]]
          assertBool "boundary compiles and maps" (not (isLeft (R.prepareRequest typesafe_jev_latest validContext (options schemaN))))
          let probabilities = A.object [(K.fromText (showText i), A.toJSON (1 / fromIntegral n :: Double)) | i <- [0 .. n - 1]]
              answer =
                if isChoice
                  then A.object ["type" A..= ("choice" :: Text), "choice" A..= ("0" :: Text), "probabilities" A..= probabilities, "confidence" A..= (0.5 :: Double)]
                  else A.object ["type" A..= ("score" :: Text), "score" A..= (0.5 :: Double), "probabilities" A..= probabilities, "confidence" A..= (0.5 :: Double), "legend" A..= A.object [(K.fromText (showText i), A.String (showText i)) | i <- [0 .. n - 1]]]
              response = A.object ["model" A..= ("fixture" :: Text), "usage" A..= A.object ["input_tokens" A..= (1 :: Int), "output_tokens" A..= (1 :: Int)], "answers" A..= A.object ["x" A..= answer]]
          forM_ [False, True] $ \streaming -> F.withFixture 200 [] (F.Reply (A.encode response)) $ \server -> do
            reg <- registry
            r <- call streaming reg (fixtureModel server) validContext (fixtureOptions schemaN)
            responseError r @?= Nothing,
      testCase "preflight refusal matrix dispatches zero requests in both public modes" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        F.withFixture 200 [] (F.Reply (A.encode reply)) $ \server -> do
          reg <- registry
          let m = fixtureModel server
              o = fixtureOptions s
              badSchemas = [A.object [], set ["properties"] (A.object []) s, set ["properties", "urgent"] (A.object ["type" A..= ("string" :: Text)]) s, set ["properties", "urgent", "description"] (A.Bool False) s, set ["properties", "urgent"] (A.object ["enum" A..= ([0 :: Int])]) s, set ["properties", "urgent"] (A.object ["enum" A..= ([0 :: Int .. 10])]) s, set ["properties", "urgent"] (A.object ["enum" A..= [show i | i <- [1 .. 256 :: Int]]]) s]
              badOptions =
                [o & #maxTokens .~ Just 1, o & #temperature .~ Just 0, o & #topP .~ Just 1, o & #stopSequences .~ ["x"], o & #seed .~ Just 1, o & #frequencyPenalty .~ Just 0, o & #presencePenalty .~ Just 0, o & #thinking .~ Just ThinkingLow, o & #cacheRetention .~ Just CacheRetentionLong, o & #speed .~ Just SpeedFast, o & #responseFormat .~ Nothing, o & #responseFormat .~ Just JsonObject, o & #timeoutMs .~ Just 0]
                  <> [o & #toolChoice .~ Just t | t <- [ToolChoiceAuto, ToolChoiceNone, ToolChoiceRequired, ToolChoiceSpecific "x"]]
                  <> [fixtureOptions bad | bad <- badSchemas]
              badContexts = [emptyContext, contextOf [user "a", user "b"], contextOf [assistant "wrong"], validContext & #systemPrompt .~ Just "", validContext & #tools .~ V.singleton emptyTool, contextOf [UserMessage (UserPayload V.empty Nothing)], contextOf [UserMessage (UserPayload (V.fromList [UserText (TextContent "x"), UserData A.Null]) Nothing)], contextOf [UserMessage (UserPayload (V.singleton (UserImage emptyImageContent)) Nothing)], contextOf [userData A.Null]]
          forM_ [False, True] $ \streaming -> forM_ ([(validContext, bad) | bad <- badOptions] <> [(bad, o) | bad <- badContexts]) $ \(c, op) -> do
            r <- call streaming reg m c op
            case responseError r of
              Just e -> do e ^. #category @?= InvalidRequest; assertBool "typed refusal" (case e ^. #requestProblem of Just (UnsupportedFeature _) -> True; _ -> False)
              Nothing -> assertFailure "expected local refusal"
            F.captures server >>= (@?= []),
      testCase "malformed HTTP successes never emit data and retain observations" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        forM_ [False, True] $ \streaming -> forM_ (malformed reply <> [A.Array V.empty]) $ \bad ->
          F.withFixture 200 [("x-typesafe-request-id", "fixture-42")] (F.Reply (A.encode bad)) $ \server -> do
            reg <- registry
            r <- call streaming reg (fixtureModel server) validContext (fixtureOptions s & #evidence .~ Just (evidenceRequest "malformed"))
            fmap (^. #category) (responseError r) @?= Just DecodeFailure
            flattenAssistantData (r ^. #message . #content) @?= V.empty
            fmap (length) (F.captures server) >>= (@?= 1)
            case r ^. #evidence of
              Just e -> e ^. #providerRequestId @?= Observed "fixture-42"
              Nothing -> assertFailure "failed call evidence absent",
      testCase "HTTP classification, exact unknown-model detection, Retry-After and no retries" $ do
        s <- fixture "schema"
        let errors = [(401, AuthError), (403, AuthError), (429, RateLimited), (400, InvalidRequest), (422, InvalidRequest), (500, TransientError), (529, TransientError)]
        forM_ [False, True] $ \streaming -> forM_ errors $ \(code, category) ->
          F.withFixture code [("Retry-After", "7")] (F.Reply "{\"error\":\"fixture\"}") $ \server -> do
            reg <- registry
            r <- call streaming reg (fixtureModel server) validContext (fixtureOptions s)
            fmap (^. #category) (responseError r) @?= Just category
            fmap (^. #retryAfterSeconds) (responseError r) @?= Just (Just 7)
            fmap length (F.captures server) >>= (@?= 1)
        forM_ [True, False] $ \known ->
          let body = A.object ["detail" A..= A.object ["error_type" A..= (if known then "api_usage_error" else "another" :: Text), "message" A..= ("Unknown model: missing" :: Text)]]
           in F.withFixture 400 [] (F.Reply (A.encode body)) $ \server -> do
                reg <- registry
                r <- call False reg (fixtureModel server) validContext (fixtureOptions s)
                fmap (^. #requestProblem) (responseError r) @?= Just (if known then Just (UnsupportedModel "jev-latest") else Nothing)
        F.withFixture 422 [] (F.Reply "{\"detail\":[{\"loc\":[\"body\",\"questions\",0],\"msg\":\"bad question\",\"type\":\"value_error\"}]}") $ \server -> do
          reg <- registry
          r <- call False reg (fixtureModel server) validContext (fixtureOptions s)
          assertBool "validation path surfaced" (maybe False (Data.Text.isInfixOf "body.questions.0: bad question" . (^. #message)) (responseError r)),
      testCase "truncated JSON, invalid usage/model, choice-not-argmax and redirect handling" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        forM_ [False, True] $ \streaming -> forM_ ["{", "null", "[]"] $ \bytes -> F.withFixture 200 [] (F.Reply bytes) $ \server -> do
          reg <- registry
          r <- call streaming reg (fixtureModel server) validContext (fixtureOptions s)
          fmap (^. #category) (responseError r) @?= Just DecodeFailure
          fmap length (F.captures server) >>= (@?= 1)
        F.withFixture 200 [] (F.Reply (A.encode (set ["answers", "category", "choice"] (A.String "billing") reply))) $ \server -> do
          reg <- registry
          r <- call False reg (fixtureModel server) validContext (fixtureOptions s)
          case V.toList (flattenAssistantData (r ^. #message . #content)) of
            [d] -> case d ^. #value of A.Object o -> KM.lookup "category" o @?= Just (A.String "billing"); _ -> assertFailure "object expected"
            _ -> assertFailure "one data block expected"
        F.withFixture 302 [("Location", "/must-not-follow")] (F.Reply "{}") $ \server -> do
          reg <- registry
          r <- call False reg (fixtureModel server) validContext (fixtureOptions s)
          assertBool "redirect fails in band" (case responseError r of Just _ -> True; _ -> False)
          fmap length (F.captures server) >>= (@?= 1),
      testCase "base normalization and case-insensitive header precedence" $ do
        s <- fixture "schema"
        reply <- fixture "response"
        forM_ ["", "/v1", "/gateway/v1/"] $ \suffix -> F.withFixture 200 [] (F.Reply (A.encode reply)) $ \server -> do
          reg <- registry
          let m = fixtureModel server & #baseUrl .~ (F.base server <> suffix) & #headers .~ Map.singleton "authorization" "Bearer model"
              o = fixtureOptions s & #headers .~ Map.singleton "AUTHORIZATION" "Bearer option"
          r <- call False reg m validContext o
          responseError r @?= Nothing
          captured <- F.captures server
          case captured of
            [F.Captured path headers _] -> do
              path @?= (if suffix == "/gateway/v1/" then "/gateway/v1/systemone" else "/v1/systemone")
              lookup "Authorization" headers @?= Just "Bearer option"
            _ -> assertFailure "one request expected",
      testCase "whole-call timeout and async cancellation close a stalled response" $ do
        s <- fixture "schema"
        forM_ [False, True] $ \streaming -> F.withFixture 200 [("x-typesafe-request-id", "stalled")] F.Stalled $ \server -> do
          reg <- registry
          r <- call streaming reg (fixtureModel server) validContext (fixtureOptions s & #timeoutMs .~ Just 100)
          fmap (^. #category) (responseError r) @?= Just TransientError
          timeout 2000000 (readMVar (F.closed server)) >>= (@?= Just ())
        F.withFixture 200 [] F.Stalled $ \server -> do
          reg <- registry
          done <- newEmptyMVar
          tid <- forkIO $ (try (call True reg (fixtureModel server) validContext (fixtureOptions s)) :: IO (Either SomeException Response)) >>= putMVar done
          timeout 2000000 (readMVar (F.requested server)) >>= (@?= Just ())
          threadDelay 50000
          throwTo tid ThreadKilled
          result <- timeout 2000000 (takeMVar done)
          assertBool "cancellation propagates" (case result of Just (Left _) -> True; _ -> False)
          timeout 2000000 (readMVar (F.closed server)) >>= (@?= Just ())
    ]

malformed :: A.Value -> [A.Value]
malformed reply = map ($ reply) (mutations <> numeric)
  where
    mutations = [set ["usage", "input_tokens"] (A.Number 1.5), set ["usage", "output_tokens"] (A.Bool True), set ["usage", "output_tokens"] (A.Number 1e400), set ["model"] (A.Number 1), set ["answers", "severity", "score"] (A.Number 1e400), set ["answers", "severity", "score"] (A.Number 3), delete ["answers", "urgent"], set ["answers", "extra"] (A.object ["type" A..= ("noul" :: Text), "noul" A..= (0.2 :: Double)]), set ["answers", "urgent", "type"] (A.String "unknown"), set ["answers", "urgent"] (A.object ["type" A..= ("box" :: Text), "box" A..= A.object ["top" A..= (0 :: Int), "bottom" A..= (1 :: Int), "left" A..= (0 :: Int), "right" A..= (1 :: Int)], "confidence" A..= A.Null]), delete ["answers", "category", "confidence"], delete ["answers", "severity", "score"], delete ["answers", "severity", "legend"], set ["answers", "severity", "legend", "0"] (A.String "wrong"), delete ["usage"], delete ["model"], set ["usage", "input_tokens"] (A.Number (-1)), set ["model"] (A.String ""), set ["answers", "category", "choice"] (A.String "other"), delete ["answers", "category", "probabilities", "billing"], set ["answers", "category", "probabilities", "extra"] (A.Number 0)]
    numeric = [set path v | path <- [["answers", "urgent", "noul"], ["answers", "category", "confidence"], ["answers", "severity", "probabilities", "0"]], v <- [A.Number (-0.1), A.Number 1.1, A.Number 1e400, A.Number (-1e-400), A.Bool True, A.String "bad"]]

showText :: Int -> Text
showText = Data.Text.pack . show
