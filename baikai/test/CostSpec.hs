module CostSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), _Context)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogConfig (..)
  , CallLogEntry
  , runRequestWithLog
  , withCallLog
  )
import Baikai.Cost.Pricing (attachCost, computeCost)
import Baikai.Message (Message (..), user)
import Baikai.Model (Model (..), ModelCost (..), _Model)
import Baikai.Options (Options, _Options)
import Baikai.Prelude
import Baikai.Provider
  ( ApiProvider (..)
  , registerApiProvider
  )
import Baikai.Response (Response (..), _Response, flattenAssistantBlocks)
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
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

-- Sample: 1000 input + 500 output tokens against a claude-haiku
-- pricing record (input $1/M, output $5/M) is exactly
-- 1000*(1/1_000_000) + 500*(5/1_000_000) = 7/2000 USD.
sampleUsage :: Usage
sampleUsage =
  _Usage
    & #inputTokens .~ 1000
    & #outputTokens .~ 500

-- Build a known-pricing model that matches the prior
-- claude-haiku-4-5-20251001 rates: input $1/M, output $5/M,
-- cache-read $0.10/M, cache-write $1.25/M.
knownModel :: Model
knownModel =
  _Model
    { modelId = "claude-haiku-4-5-20251001"
    , api = Custom "test"
    , provider = "anthropic"
    , cost =
        ModelCost
          { inputCost = 1
          , outputCost = 5
          , cacheReadCost = 1 / 10
          , cacheWriteCost = 5 / 4
          }
    }

unknownModel :: Model
unknownModel = _Model {modelId = "totally-fake-model", api = Custom "test"}

computeTests :: TestTree
computeTests =
  testGroup
    "computeCost"
    [ testCase "deterministic cost for the known model" $
        Cost.usd (computeCost knownModel sampleUsage)
          @?= 7 / 2000
    , testCase "zero cost for unknown models" $
        Cost.usd (computeCost unknownModel sampleUsage)
          @?= 0
    , testCase "cacheReadTokens contribute when present" $ do
        let u :: Usage
            u =
              _Usage
                & #cacheReadTokens .~ 1000
        Cost.usd (computeCost knownModel u) @?= 1 / 10000
    , testCase "cacheWriteTokens contribute against the known model" $ do
        let u :: Usage
            u =
              _Usage
                & #cacheWriteTokens .~ 1000
        Cost.usd (computeCost knownModel u) @?= 1 / 800
    ]

attachCostTests :: TestTree
attachCostTests =
  testGroup
    "attachCost"
    [ testCase "fills the cost field on known models" $
        attachedUsd knownModel @?= 7 / 2000
    , testCase "leaves cost zero on unknown models" $
        attachedUsd unknownModel @?= 0
    , testCase "leaves the response's content alone" $ do
        let resp = attachCost knownModel (mkResp knownModel)
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hi"))
    ]
  where
    attachedUsd m =
      let resp = attachCost m (mkResp m)
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
        , api = Custom "test"
        , provider = "claude-api"
        , responseId = Nothing
        , latencyMs = 100
        }

-- Register a handler under a private API tag that returns a canned
-- response. Used by the call-log tests below.
cannedApi :: Api
cannedApi = Custom "baikai-cost-canned"

cannedHaiku :: Response
cannedHaiku =
  let u = sampleUsage & #cost .~ computeCost knownModel sampleUsage
   in _Response
        { message =
            AssistantMessage
              { assistantContent = V.singleton (AssistantText (TextContent "ok"))
              , usage = u
              , stopReason = Stop
              , errorMessage = Nothing
              , timestamp = read "2026-05-14 00:00:00 UTC"
              }
        , model = knownModel {api = cannedApi}
        , api = cannedApi
        , provider = "canned"
        , responseId = Nothing
        , latencyMs = 7
        }

registerCanned :: Response -> IO ()
registerCanned resp =
  let handler _m _ctx _opts = pure resp
   in registerApiProvider
        ApiProvider
          { apiTag = cannedApi
          , stream = liftCompleteToStream handler
          , complete = handler
          }

cannedModel :: Model
cannedModel = knownModel {api = cannedApi}

ctxHello :: Context
ctxHello = _Context {messages = V.fromList [user "Hello world"]}

optsZero :: Options
optsZero = _Options

callLogTests :: TestTree
callLogTests =
  testGroup
    "CallLog"
    [ testCase "disabled handle skips disk I/O" $ do
        registerCanned cannedHaiku
        let cfg = CallLogConfig {path = "/dev/null", enabled = False}
        withCallLog cfg $ \h -> do
          resp <- runRequestWithLog h cannedModel ctxHello optsZero
          flattenAssistantBlocks resp
            @?= V.singleton (AssistantText (TextContent "ok"))
    , testCase "enabled handle writes one JSONL record per call" $ do
        registerCanned cannedHaiku
        tmp <- getTemporaryDirectory
        let path' = tmp </> "baikai-cost-test.jsonl"
        writeFile path' ""
        let cfg = CallLogConfig {path = path', enabled = True}
        withCallLog cfg $ \h -> do
          _ <- runRequestWithLog h cannedModel ctxHello optsZero
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
