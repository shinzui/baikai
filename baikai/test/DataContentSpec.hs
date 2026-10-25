module DataContentSpec (tests) where

import Baikai
import Baikai.Cost.Log qualified as Log
import Baikai.Evidence.Build qualified
import Baikai.Prelude
import Baikai.Trace (runRequestWithRegistry, withTraceWith)
import Baikai.Trace.Event qualified as T
import Baikai.Trace.Sink qualified as Sink
import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Ratio ((%))
import Data.Text qualified as Text
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as S
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

sample :: DataContent
sample =
  DataContent
    (A.object ["urgent" A..= True, "category" A..= ("technical" :: Text.Text), "severity" A..= (2 :: Int)])
    (Just (Map.fromList [("urgent", Map.fromList [("true", 0.8), ("false", 0.2)]), ("category", Map.fromList [("billing", 0.2), ("technical", 0.7)]), ("severity", Map.fromList [("0", 0), ("1", 0.1), ("2", 1)])]))
    (Just (Map.fromList [("category", 0.7), ("severity", 0.9)]))
    (Just "provider_classification")

payload :: AssistantPayload
payload = (emptyResponse ^. #message) & #content .~ V.fromList [AssistantText (TextContent "before"), AssistantData sample, AssistantText (TextContent "after")]

modelFixture :: Model
modelFixture = emptyModel & #api .~ Custom "data-fixture" & #provider .~ "data-fixture"

responseFixture :: Response
responseFixture = emptyResponse & #message . #usage . #cost .~ (zeroCost & #usd .~ (3 % 10) & #breakdown . #inputUsd .~ (3 % 10)) & #model .~ modelFixture & #api .~ Custom "data-fixture" & #message .~ (payload & #usage . #cost .~ (zeroCost & #usd .~ (3 % 10) & #breakdown . #inputUsd .~ (3 % 10)))

-- Deliberately leave the error terminal empty to exercise closed-block recovery.
events :: Bool -> [AssistantMessageEvent]
events failed =
  [ EventStart (StartPayload (assistant "") Nothing),
    TextStart (IndexPayload 0),
    TextEnd (BlockEndPayload 0 "before"),
    DataStart (IndexPayload 1),
    DataEnd (DataEndPayload 1 sample),
    TextStart (IndexPayload 2),
    TextEnd (BlockEndPayload 2 "after")
  ]
    <> [ if failed
           then EventError (errorTerminal Nothing Nothing ErrorReason (assistant "") (providerError "failed"))
           else EventDone (doneTerminal Nothing Nothing Stop (AssistantMessage payload))
       ]

tests :: TestTree
tests =
  testGroup
    "structured content"
    [ testCase "data, scalar inputs and typed refusals round-trip" $ do
        A.eitherDecode (A.encode (AssistantData sample)) @?= Right (AssistantData sample)
        forM_ [A.Null, A.Bool True, A.String "日本語", A.toJSON ([1, 2] :: [Int]), value sample] $ \v -> do
          A.eitherDecode (A.encode (UserData v)) @?= Right (UserData v)
          let ctx = contextOf [userData v]
          Log.summarizeContext ctx @?= Text.take 200 (canonicalDataText v)
        forM_ [unsupportedFeature "messages[0].content[1]" "cannot replay", unsupportedModel "unknown" "not supported"] $ \e -> do
          A.eitherDecode (A.encode e) @?= Right e
          isRetryable e @?= False,
      testCase "invalid individual probabilities/confidences fail without normalizing totals" $ do
        forM_ ["probabilities", "confidence"] $ \key ->
          forM_ [A.toJSON (-0.1 :: Double), A.toJSON (1.1 :: Double), A.String "bad", A.Null, A.Number 1e10000] $ \bad -> do
            let v = A.object ["value" A..= A.Null, key A..= if key == "probabilities" then A.object ["field" A..= A.object ["x" A..= bad]] else A.object ["field" A..= bad]]
            assertBool "invalid numeric evidence rejected" (isLeft (parseEither A.parseJSON v :: Either String DataContent))
        A.eitherDecode (A.encode sample) @?= Right sample,
      testCase "atomic events serialize and retain mixed blocks on success and failure" $ do
        forM_ [False, True] $ \failed -> do
          let es = events failed
          A.eitherDecode (A.encode es) @?= Right es
          r <- S.fold (reassembleResponse modelFixture) (S.fromList es)
          (r ^. #message) ^. #content @?= payload ^. #content
          r2 <- S.fold (reassembleResponse modelFixture) (S.fromList (es <> [EventDone (doneTerminal Nothing Nothing Stop (assistant "overwrite"))]))
          r2 ^. #message @?= r ^. #message
        r <- S.fold (reassembleResponse modelFixture) (S.fromList [DataStart (IndexPayload 0)])
        flattenAssistantData ((r ^. #message) ^. #content) @?= V.empty,
      testCase "gapped data indices are not duplicated and partial failure terminals recover all data" $ do
        let first = sample
            second = sample & #method .~ Just "second"
            finalOne = (emptyResponse ^. #message) & #content .~ V.singleton (AssistantData first)
            terminal = EventError (errorTerminal Nothing Nothing ErrorReason (AssistantMessage finalOne) (providerError "partial terminal"))
            es = [DataStart (IndexPayload 2), DataEnd (DataEndPayload 2 first)]
        r <- S.fold (reassembleResponse modelFixture) (S.fromList (es <> [terminal]))
        flattenAssistantData (r ^. #message . #content) @?= V.singleton first
        let both = es <> [DataStart (IndexPayload 5), DataEnd (DataEndPayload 5 second), terminal]
        r2 <- S.fold (reassembleResponse modelFixture) (S.fromList both)
        flattenAssistantData (r2 ^. #message . #content) @?= V.fromList [first, second]
        reg <- newProviderRegistry
        let stream _ _ _ = S.fromList both
        registerApiProviderWith reg (apiProviderWith (Custom "data-fixture") stream (streamingComplete stream))
        withSystemTempDirectory "baikai-gapped-data" $ \dir -> do
          sink <- Sink.fileSink (dir </> "trace.jsonl")
          _ <- withTraceWith reg sink modelFixture emptyContext emptyOptions
          bytes <- BL.readFile (dir </> "trace.jsonl")
          ts <- either assertFailure pure (traverse A.eitherDecode (filter (not . BL.null) (BL.split 10 bytes)) :: Either String [T.TraceEvent])
          [ds | T.CallFailed {T.structuredData = ds} <- ts] @?= [Just (V.fromList [first, second])],
      testCase "named response bytes, optional evidence and response commitments" $ do
        ev <- Baikai.Evidence.Build.minimalEvidence modelFixture (emptyOptions & #evidence .~ Just (evidenceRequest "data-test")) TransportHttpApi noThinkingRequested (A.object []) (read "2026-10-25 00:00:00 UTC") (read "2026-10-25 00:00:01 UTC") CallSucceeded Nothing
        forM_ [responseFixture, responseFixture & #evidence .~ fmap (\e -> e & #usage .~ Observed (responseFixture ^. #message . #usage)) ev, responseFixture & #errorInfo .~ Just (unsupportedFeature "x" "refused") & #message . #stopReason .~ ErrorReason] $ \r -> do
          let encoded = responseToJSON r
          case parseEither responseFromJSON encoded of
            Left e -> assertFailure e
            Right decoded -> do
              canonicalEncode (responseToJSON decoded) @?= canonicalEncode encoded
              flattenAssistantData ((decoded ^. #message) ^. #content) @?= V.singleton sample
          let cached = case encoded of A.Object o -> A.Object (KM.delete "evidence" o); v -> v
          fmap (flattenAssistantData . (^. #content) . (^. #message)) (parseEither responseFromJSON cached) @?= Right (V.singleton sample)
        let changed = sample {method = Just "another"}
        assertBool "probability is committed" (commitmentDigest (A.toJSON sample) /= commitmentDigest (A.toJSON (sample & #probabilities .~ Just Map.empty)))
        assertBool "method is committed" (commitmentDigest (A.toJSON sample) /= commitmentDigest (A.toJSON changed)),
      testCase "file trace and both call-log entry points preserve data without evidence opt-in" $
        withSystemTempDirectory "baikai-data" $ \dir ->
          forM_ [False, True] $ \failed -> do
            reg <- newProviderRegistry
            let stream _ _ _ = S.fromList (events failed)
            registerApiProviderWith reg (apiProviderWith (Custom "data-fixture") stream (streamingComplete stream))
            let tracePath = dir </> (if failed then "failed-trace.jsonl" else "trace.jsonl")
                logPath = dir </> (if failed then "failed-log.jsonl" else "log.jsonl")
            sink <- Sink.fileSink tracePath
            Log.withCallLog (Log.callLogConfig logPath) $ \h -> do
              _ <- runRequestWithRegistry reg sink h modelFixture emptyContext emptyOptions
              _ <- Log.runRequestWithLogWith reg h modelFixture emptyContext emptyOptions
              pure ()
            traceBytes <- BL.readFile tracePath
            let decodedTrace = traverse A.eitherDecode (filter (not . BL.null) (BL.split 10 traceBytes)) :: Either String [T.TraceEvent]
            case decodedTrace of
              Right ts -> case [ds | T.CallFinished {T.structuredData = ds} <- ts] <> [ds | T.CallFailed {T.structuredData = ds} <- ts] of
                [ds] -> ds @?= Just (V.singleton sample)
                _ -> assertFailure "expected one terminal"
              Left e -> assertFailure e
            logBytes <- BL.readFile logPath
            case traverse A.eitherDecode (filter (not . BL.null) (BL.split 10 logBytes)) :: Either String [Log.CallLogEntry] of
              Right entries -> map (\e -> e ^. #structuredData) entries @?= replicate 2 (Just (V.singleton sample))
              Left e -> assertFailure e
    ]
