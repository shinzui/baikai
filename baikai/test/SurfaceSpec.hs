module SurfaceSpec (tests) where

import Baikai
import Baikai.Embedding qualified as Embedding
import Baikai.Prelude
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Vector qualified as V
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
        Embedding.modelId Embedding.emptyEmbeddingModel @?= ""
    ]
