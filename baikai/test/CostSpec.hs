module CostSpec (tests) where

import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Cost (_Cost)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry
  , runRequestWithLog
  , withCallLog
  )
import Baikai.Cost.Pricing (attachCost, compute, defaultPricing)
import Baikai.Message (Message (..), user)
import Baikai.Model (Model (..))
import Baikai.Prelude
import Baikai.Provider (Provider (..))
import Baikai.Request (Request, _Request)
import Baikai.Response (Response (..), _Response, flattenAssistantBlocks)
import Baikai.StopReason (StopReason (..))
import Baikai.Usage (Usage, _Usage)
import Baikai.Usage qualified as Usage
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BSL
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty)
import Data.Maybe (fromJust, isJust)
import Data.Vector qualified as V
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Cost"
    [ computeTests
    , attachCostTests
    , callLogTests
    ]

-- 1000 input + 500 output tokens against claude-haiku-4-5-20251001
-- (input $1/M, output $5/M) is exactly 1000*(1/1_000_000) +
-- 500*(5/1_000_000) = 1/1000 + 1/400 = 7/2000 USD.
sampleUsage :: Usage
sampleUsage =
  _Usage
    & #inputTokens .~ 1000
    & #outputTokens .~ 500

knownModel :: Model
knownModel = Model "claude-haiku-4-5-20251001"

unknownModel :: Model
unknownModel = Model "totally-fake-model"

computeTests :: TestTree
computeTests =
  testGroup
    "compute"
    [ testCase "deterministic cost for claude-haiku-4-5-20251001" $
        Cost.usd (compute defaultPricing knownModel sampleUsage)
          @?= 7 / 2000
    , testCase "zero cost for unknown models" $
        compute defaultPricing unknownModel sampleUsage @?= _Cost
    , testCase "cacheReadTokens contribute when present" $ do
        let u :: Usage
            u =
              _Usage
                & #cacheReadTokens .~ 1000
        -- claude-haiku cached rate: $0.10/M → 1000 * (1/10_000_000) = 1/10_000
        Cost.usd (compute defaultPricing knownModel u) @?= 1 / 10000
    , testCase "cacheWriteTokens contribute against claude-haiku" $ do
        let u :: Usage
            u =
              _Usage
                & #cacheWriteTokens .~ 1000
        -- claude-haiku cache-write rate: $1.25/M → 1000 * (1.25/1_000_000) = 1/800
        Cost.usd (compute defaultPricing knownModel u) @?= 1 / 800
    ]

attachCostTests :: TestTree
attachCostTests =
  testGroup
    "attachCost"
    [ testCase "fills the cost field on known models" $
        attachedUsd knownModel @?= 7 / 2000
    , testCase "leaves cost zero on unknown models" $
        attachedUsd unknownModel @?= 0
    , testCase "leaves the response's empty content alone" $ do
        let resp = attachCost defaultPricing (mkResp knownModel)
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hi"))
    ]
  where
    attachedUsd m =
      let resp = attachCost defaultPricing (mkResp m)
          AssistantMessage {usage = u} = message resp
       in Cost.usd (Usage.cost u)
    mkResp m =
      _Response
        { message =
            AssistantMessage
              { assistantContent = V.singleton (AssistantText (TextContent "hi"))
              , usage = sampleUsage
              , stopReason = Stop
              , errorMessage = Nothing
              , timestamp = read "2026-05-14 00:00:00 UTC"
              }
        , model = m
        , api = "test"
        , provider = "claude-api"
        , responseId = Nothing
        , latencyMs = 100
        }

-- A trivial in-memory provider for the call-log test.
data CannedProvider = CannedProvider {cannedResp :: !Response}

instance Provider CannedProvider where
  providerName _ = "canned"
  runRequest CannedProvider {cannedResp} _ = pure cannedResp

cannedHaiku :: Response
cannedHaiku =
  let u = sampleUsage & #cost .~ compute defaultPricing knownModel sampleUsage
   in _Response
        { message =
            AssistantMessage
              { assistantContent = V.singleton (AssistantText (TextContent "ok"))
              , usage = u
              , stopReason = Stop
              , errorMessage = Nothing
              , timestamp = read "2026-05-14 00:00:00 UTC"
              }
        , model = knownModel
        , api = "test"
        , provider = "canned"
        , responseId = Nothing
        , latencyMs = 7
        }

reqHello :: Request
reqHello =
  _Request
    & #model .~ knownModel
    & #messages .~ V.fromList [user "Hello world"]

callLogTests :: TestTree
callLogTests =
  testGroup
    "CallLog"
    [ testCase "disabled handle skips disk I/O" $ do
        let cfg = CallLogConfig {path = "/dev/null", enabled = False}
            pr = CannedProvider {cannedResp = cannedHaiku}
        withCallLog cfg $ \h -> do
          resp <- runRequestWithLog h pr reqHello
          flattenAssistantBlocks resp
            @?= V.singleton (AssistantText (TextContent "ok"))
    , testCase "enabled handle writes one JSONL record per call" $ do
        tmp <- getTemporaryDirectory
        let path' = tmp </> "baikai-cost-test.jsonl"
        writeFile path' ""
        let cfg = CallLogConfig {path = path', enabled = True}
            pr = CannedProvider {cannedResp = cannedHaiku}
        withCallLog cfg $ \h -> do
          _ <- runRequestWithLog h pr reqHello
          pure ()
        raw <- BSL.readFile path'
        firstLine <- case nonEmpty (BSL.lines raw) of
          Nothing -> fail "expected one JSONL line, got an empty file"
          Just (l :| rest) -> do
            length rest @?= 0
            pure l
        let mEntry :: Maybe CallLogEntry
            mEntry = Aeson.decode firstLine
        isJust mEntry @?= True
        let entry = fromJust mEntry
        entry ^. #provider @?= "canned"
        entry ^. #model @?= "claude-haiku-4-5-20251001"
        entry ^. #inputTokens @?= Just 1000
        entry ^. #outputTokens @?= Just 500
        entry ^. #latencyMs @?= 7
        entry ^. #promptSummary @?= "Hello world"
        isJust (entry ^. #usd) @?= True
        removeFile path'
    ]
