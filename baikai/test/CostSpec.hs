module CostSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.CacheRetention (CacheRetention (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..), emptyContext)
import Baikai.Cost qualified as Cost
import Baikai.Cost.Log
  ( CallLogEntry (..),
    appendEntry,
    callLogConfig,
    closeCallLog,
    openCallLog,
    runRequestWithLog,
    withCallLog,
  )
import Baikai.Cost.Pricing (attachCost, computeCost, computeCostAtSpeed, computeCostForService)
import Baikai.Message (AssistantPayload (..), user)
import Baikai.Model (InputPriceTier (..), Model (..), ModelCost (..), PricingPolicy (..), emptyModel)
import Baikai.Models.Generated qualified as Models
import Baikai.Options (Options, emptyOptions)
import Baikai.Prelude
import Baikai.Provider
  ( apiProviderWith,
    registerApiProvider,
  )
import Baikai.Response (Response (..), flattenAssistantBlocks)
import Baikai.Speed (Speed (..))
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Usage (Usage, zeroUsage)
import Baikai.Usage qualified as Usage
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as BSL
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty)
import Data.Maybe (fromJust, isJust)
import Data.Set qualified as Set
import Data.Time (UTCTime, getCurrentTime)
import Data.Vector qualified as V
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Cost"
    [ fastCostTests,
      computeTests,
      attachCostTests,
      callLogTests
    ]

-- Sample: 1000 input + 500 output tokens against a claude-haiku
-- pricing record (input $1/M, output $5/M) is exactly
-- 1000*(1/1_000_000) + 500*(5/1_000_000) = 7/2000 USD.
sampleUsage :: Usage
sampleUsage =
  zeroUsage
    & #inputTokens
    .~ 1000
    & #outputTokens
    .~ 500

-- Build a known-pricing model that matches the prior
-- claude-haiku-4-5-20251001 rates: input $1/M, output $5/M,
-- cache-read $0.10/M, cache-write $1.25/M.
knownModel :: Model
knownModel =
  emptyModel
    & #modelId
    .~ "claude-haiku-4-5-20251001"
    & #api
    .~ Custom "test"
    & #provider
    .~ "anthropic"
    & #cost
    .~ ModelCost
      { inputCost = 1,
        outputCost = 5,
        cacheReadCost = 1 / 10,
        cacheWriteCost = 5 / 4
      }

unknownModel :: Model
unknownModel =
  emptyModel
    & #modelId
    .~ "totally-fake-model"
    & #api
    .~ Custom "test"

computeTests :: TestTree
computeTests =
  testGroup
    "computeCost"
    [ testCase "deterministic cost for the known model" $
        Cost.usd (computeCost knownModel sampleUsage)
          @?= 7 / 2000,
      testCase "zero cost for unknown models" $
        Cost.usd (computeCost unknownModel sampleUsage)
          @?= 0,
      testCase "cacheReadTokens contribute when present" $ do
        let u :: Usage
            u =
              zeroUsage
                & #cacheReadTokens
                .~ 1000
        Cost.usd (computeCost knownModel u) @?= 1 / 10000,
      testCase "cacheWriteTokens contribute against the known model" $ do
        let u :: Usage
            u =
              zeroUsage
                & #cacheWriteTokens
                .~ 1000
        Cost.usd (computeCost knownModel u) @?= 1 / 800
    ]

attachCostTests :: TestTree
attachCostTests =
  testGroup
    "attachCost"
    [ testCase "fills the cost field on known models" $
        attachedUsd knownModel @?= 7 / 2000,
      testCase "leaves cost zero on unknown models" $
        attachedUsd unknownModel @?= 0,
      testCase "leaves the response's content alone" $ do
        let resp = attachCost knownModel (mkResp knownModel)
        flattenAssistantBlocks resp
          @?= V.singleton (AssistantText (TextContent "hi"))
    ]
  where
    attachedUsd m =
      let AssistantPayload {usage = u} = attachCost m (mkResp m) ^. #message
       in Cost.usd (u ^. #cost)
    mkResp m =
      Response
        { message =
            AssistantPayload
              { content = V.singleton (AssistantText (TextContent "hi")),
                usage = sampleUsage,
                stopReason = Stop,
                errorMessage = Nothing,
                timestamp = Just (read "2026-05-14 00:00:00 UTC")
              },
          model = m,
          api = Custom "test",
          provider = "claude-api",
          responseId = Nothing,
          latencyMs = 100,
          errorInfo = Nothing,
          evidence = Nothing
        }

-- Register a handler under a private API tag that returns a canned
-- response. Used by the call-log tests below.
cannedApi :: Api
cannedApi = Custom "baikai-cost-canned"

cannedHaiku :: Response
cannedHaiku =
  let u = sampleUsage & #cost .~ computeCost knownModel sampleUsage
   in Response
        { message =
            AssistantPayload
              { content = V.singleton (AssistantText (TextContent "ok")),
                usage = u,
                stopReason = Stop,
                errorMessage = Nothing,
                timestamp = Just (read "2026-05-14 00:00:00 UTC")
              },
          model = knownModel & #api .~ cannedApi,
          api = cannedApi,
          provider = "canned",
          responseId = Nothing,
          latencyMs = 7,
          errorInfo = Nothing,
          evidence = Nothing
        }

registerCanned :: Response -> IO ()
registerCanned resp =
  let handler _m _ctx _opts = pure resp
   in registerApiProvider
        ( apiProviderWith
            cannedApi
            (liftCompleteToStream handler)
            (handler)
        )

cannedModel :: Model
cannedModel = knownModel & #api .~ cannedApi

ctxHello :: Context
ctxHello = emptyContext & #messages .~ V.fromList [user "Hello world"]

optsZero :: Options
optsZero = emptyOptions

callLogTests :: TestTree
callLogTests =
  testGroup
    "CallLog"
    [ testCase "disabled handle skips disk I/O" $ do
        registerCanned cannedHaiku
        let cfg = callLogConfig "/dev/null" & #enabled .~ False
        withCallLog cfg $ \h -> do
          resp <- runRequestWithLog h cannedModel ctxHello optsZero
          flattenAssistantBlocks resp
            @?= V.singleton (AssistantText (TextContent "ok")),
      testCase "enabled handle writes one JSONL record per call" $ do
        registerCanned cannedHaiku
        tmp <- getTemporaryDirectory
        let path' = tmp </> "baikai-cost-test.jsonl"
        writeFile path' ""
        let cfg = callLogConfig path'
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
        entry ^. #costBasis @?= Just (cannedHaiku ^. #message . #usage . #cost . #basis)
        entry ^. #cacheWriteTokens @?= Just (cannedHaiku ^. #message . #usage . #cacheWriteTokens)
        removeFile path',
      testCase "closeCallLog returns even when the log path is unwritable" $ do
        tmp <- getTemporaryDirectory
        let missing = tmp </> "baikai-costspec-no-such-dir" </> "entries.jsonl"
            cfg = callLogConfig missing
        now <- getCurrentTime
        result <- timeout 5000000 (withCallLog cfg (\h -> appendEntry h (sampleEntry now)))
        result @?= Just (),
      -- 'withCallLog' brackets a close around a body that may also close
      -- the handle, so the second close is a shape a caller reaches by
      -- accident. Before the claim it blocked forever on an 'MVar' the
      -- worker had already emptied.
      testCase "closeCallLog twice returns and appendEntry after close is a no-op" $ do
        tmp <- getTemporaryDirectory
        let path' = tmp </> "baikai-costspec-double-close.jsonl"
        writeFile path' ""
        let cfg = callLogConfig path'
        h <- openCallLog cfg
        result <- timeout 5000000 (closeCallLog h >> closeCallLog h)
        result @?= Just ()
        now <- getCurrentTime
        appendEntry h (sampleEntry now)
        raw <- BSL.readFile path'
        BSL.length raw @?= 0
        removeFile path'
    ]

-- | A minimal entry, shared by the call-log cases that need one to
-- enqueue rather than one to inspect.
sampleEntry :: UTCTime -> CallLogEntry
sampleEntry now =
  CallLogEntry
    { timestamp = now,
      provider = "test",
      model = "m",
      inputTokens = Nothing,
      outputTokens = Nothing,
      cachedInputTokens = Nothing,
      reasoningTokens = Nothing,
      cacheWriteTokens = Nothing,
      costBasis = Nothing,
      usageAvailability = Nothing,
      usd = Nothing,
      latencyMs = 0,
      promptSummary = ""
    }

fastCostTests :: TestTree
fastCostTests =
  testGroup
    "fast pricing"
    [ testCase "fast premiums compose with context tiers before pricing" $ do
        let m = Models.anthropic_claude_opus_5 & #pricingPolicy .~ Just (PricingPolicy [InputPriceTier 1000 (ModelCost 10 50 1 12.5)] Nothing)
        Cost.usd (computeCostAtSpeed m SpeedFast u) @?= 2 * Cost.usd (computeCost m u),
      testCase "invalid premium rates and undefined policy ratios are explicit" $ do
        let negative = knownModel & #fastModeCost .~ Just (ModelCost (-1) 10 0.2 2.5)
            undefinedRatio = knownModel & #cost .~ ModelCost 0 5 0.1 1.25 & #fastModeCost .~ Just (ModelCost 10 10 0.2 2.5) & #pricingPolicy .~ Just (PricingPolicy [InputPriceTier 1 (ModelCost 5 5 0.1 1.25)] Nothing)
        mapM_ (\m -> Set.member Cost.InvalidPricingPolicy (Cost.estimateReasons (Cost.basis (computeCostAtSpeed m SpeedFast u))) @?= True) [negative, undefinedRatio],
      testCase "contradictory speed observations remain an explicit standard estimate" $ do
        let usage = Usage.observeBilling [Usage.BillingSpeed "fast", Usage.BillingSpeed "standard"] u
            result = computeCostForService Nothing Nothing Models.anthropic_claude_opus_5 usage
        Cost.usd result @?= Cost.usd (computeCost Models.anthropic_claude_opus_5 u)
        Set.member Cost.InconsistentUsage (Cost.estimateReasons (Cost.basis result)) @?= True,
      testCase "fast Opus costs exactly twice standard across all four token categories" $ do
        mapM_
          ( \m -> do
              let standard = computeCost m u
                  fast = computeCostAtSpeed m SpeedFast u
              Cost.usd fast @?= 2 * Cost.usd standard
              Cost.breakdown fast @?= Cost.breakdown (standard <> standard)
              computeCostAtSpeed m SpeedStandard u @?= standard
              Cost.sources (Cost.basis fast) @?= Set.singleton Cost.ResolvedTokenRates
          )
          [Models.anthropic_claude_opus_5, Models.anthropic_claude_opus_4_8],
      testCase "uncurated fast pricing retains the standard amount and marks the estimate" $ do
        let m = Models.anthropic_claude_sonnet_5
            fast = computeCostAtSpeed m SpeedFast u
        Cost.usd fast @?= Cost.usd (computeCost m u)
        Set.member (Cost.UnsupportedSpeed "fast") (Cost.estimateReasons (Cost.basis fast)) @?= True,
      testCase "observed fast speed selects premium long-cache rates once" $ do
        let usage = Usage.observeBilling [Usage.BillingSpeed "fast", Usage.BillingServiceTier "standard"] (zeroUsage & #cacheWriteTokens .~ 1000000)
            price = computeCostForService (Just CacheRetentionLong) Nothing Models.anthropic_claude_opus_5 usage
        Cost.usd price @?= 20
        Set.member (Cost.UnsupportedSpeed "fast") (Cost.estimateReasons (Cost.basis price)) @?= False,
      testCase "observed standard speed retains standard long-cache rates" $ do
        let usage = Usage.observeBilling [Usage.BillingSpeed "standard", Usage.BillingServiceTier "standard"] (zeroUsage & #cacheWriteTokens .~ 1000000)
        Cost.usd (computeCostForService (Just CacheRetentionLong) Nothing Models.anthropic_claude_opus_5 usage) @?= 10
    ]
  where
    u = sampleUsage & #cacheReadTokens .~ 200 & #cacheWriteTokens .~ 300
