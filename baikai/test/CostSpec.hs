module CostSpec (tests) where

import Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry
  , runRequestWithLog
  , withCallLog
  )
import Baikai.Cost.Pricing (attachCost, compute, defaultPricing)
import Baikai.Message (user)
import Baikai.Model (Model (..))
import Baikai.Prelude
import Baikai.Provider (Provider (..))
import Baikai.Request (Request, _Request)
import Baikai.Response (Response, _Response)
import Baikai.Usage (Usage, _Usage)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty)
import Data.Maybe (fromJust, isJust)
import qualified Data.Vector as V
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
        fmap (^. #usd) (compute defaultPricing knownModel sampleUsage)
          @?= Just (7 / 2000)
    , testCase "Nothing for unknown models" $
        compute defaultPricing unknownModel sampleUsage @?= Nothing
    , testCase "cachedInputTokens contribute when both present" $ do
        let u :: Usage
            u =
              _Usage
                & #cachedInputTokens .~ Just 1000
        -- claude-haiku cached rate: $0.10/M → 1000 * (1/10_000_000) = 1/10_000
        fmap (^. #usd) (compute defaultPricing knownModel u)
          @?= Just (1 / 10000)
    ]

attachCostTests :: TestTree
attachCostTests =
  testGroup
    "attachCost"
    [ testCase "fills the cost field on known models" $
        fmap (^. #usd) (attachCost defaultPricing (mkResp knownModel) ^. #cost)
          @?= Just (7 / 2000)
    , testCase "leaves cost Nothing on unknown models" $
        (attachCost defaultPricing (mkResp unknownModel) ^. #cost) @?= Nothing
    , testCase "leaves the response untouched when usage is Nothing" $
        ( attachCost
            defaultPricing
            (_Response & #model .~ knownModel)
            ^. #cost
        )
          @?= Nothing
    ]
  where
    mkResp m =
      _Response
        & #content .~ "hi"
        & #model .~ m
        & #usage .~ Just sampleUsage
        & #provider .~ "claude-api"
        & #latencyMs .~ 100

-- A trivial in-memory provider for the call-log test.
data CannedProvider = CannedProvider {cannedResp :: !Response}

instance Provider CannedProvider where
  providerName _ = "canned"
  runRequest CannedProvider {cannedResp} _ = pure cannedResp

cannedHaiku :: Response
cannedHaiku =
  _Response
    & #content .~ "ok"
    & #model .~ knownModel
    & #usage .~ Just sampleUsage
    & #cost .~ compute defaultPricing knownModel sampleUsage
    & #provider .~ "canned"
    & #latencyMs .~ 7

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
          resp ^. #content @?= "ok"
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
