module SurfaceSpec (tests) where

import Baikai
import Baikai.Cost.Log (callLogConfig)
import Baikai.Embedding qualified as Embedding
import Baikai.Prelude
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "surface"
    [ testCase "abstract records build from public bases and selectors" $ do
        let opts =
              emptyOptions
                & #maxTokens
                .~ Just 32
                & #topP
                .~ Just 0.9
            ctx =
              emptyContext
                & #systemPrompt
                .~ Just "Be brief."
                & #messages
                .~ V.singleton (user "hello")
            model =
              mkModel OpenAIChatCompletions "gpt-test" "https://api.example.test"
                & #headers
                .~ Map.singleton "x-test" "1"
            response =
              emptyResponse
                & #model
                .~ model
                & #message
                . #content
                .~ V.singleton (AssistantText emptyTextContent {text = "ok"})
            req = interactiveLaunchRequest "inspect" & #modelId .~ Just "gpt-test"
        opts ^. #maxTokens @?= Just 32
        ctx ^. #systemPrompt @?= Just "Be brief."
        (response ^. #model) ^. #modelId @?= "gpt-test"
        req ^. #modelId @?= Just "gpt-test",
      testCase "zero and empty bases cover the public rename map" $ do
        zeroUsage ^. #totalTokens @?= 0
        zeroCost ^. #usd @?= 0
        zeroCostBreakdown ^. #inputUsd @?= 0
        zeroModelCost ^. #inputCost @?= 0
        emptyTool ^. #parameters @?= Aeson.Null
        emptyToolCall ^. #arguments @?= Aeson.Null
        Embedding.modelId Embedding.emptyEmbeddingModel @?= "",
      -- Every record whose constructor this release hid must still be
      -- reachable: build each from its exported base and read one field
      -- back. A base value that disappears, or a field that stops being
      -- exported, fails to compile here rather than at a consumer.
      testCase "hidden records build from their bases" $ do
        let provider = apiProvider (Custom "probe") (\_ _ _ -> Stream.nil)
            req = evidenceRequest "r" & #attempt .~ 2
            tool = mkTool "t" "d" Aeson.Null
            embedding = Embedding.emptyEmbeddingModel & #modelId .~ "e"
            logCfg = callLogConfig "/dev/null"
        provider ^. #apiTag @?= Custom "probe"
        provider ^. #strengthCeiling @?= EvidenceRequestedOnly
        req ^. #attempt @?= 2
        req ^. #runId @?= "r"
        tool ^. #name @?= "t"
        tool ^. #parameters @?= Aeson.Null
        embedding ^. #modelId @?= "e"
        logCfg ^. #path @?= "/dev/null"
        logCfg ^. #enabled @?= True
    ]
