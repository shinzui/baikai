-- | Tests for the embeddings client (EP-15, M1).
--
-- The request-mapping test is hermetic: it asserts on the pure
-- 'mkEmbeddingRequest' (no network), proving the input text, model id, and
-- dimensions land where the OpenAI @\/v1\/embeddings@ wire expects them. The live
-- test is gated on @BAIKAI_EMBEDDING_LIVE=1@ (and a real @OPENAI_API_KEY@) so the
-- default run stays offline.
module EmbeddingSpec (tests) where

import Baikai.Embedding (embedOne, mkEmbeddingRequest, openAIEmbeddingModel)
import Data.Vector qualified as V
import OpenAI.V1.Embeddings qualified as Emb
import OpenAI.V1.Models qualified as OpenAIModels
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Embedding"
    [ testCase "mkEmbeddingRequest maps input, model id, and dimensions" $ do
        let req = mkEmbeddingRequest (openAIEmbeddingModel "text-embedding-3-small") "hello"
        Emb.input req @?= "hello"
        OpenAIModels.text (Emb.model req) @?= "text-embedding-3-small"
        Emb.dimensions req @?= Nothing,
      testCase "live embedding returns a 1536-length vector" $ do
        live <- lookupEnv "BAIKAI_EMBEDDING_LIVE"
        case live of
          Just "1" -> do
            v <- embedOne (openAIEmbeddingModel "text-embedding-3-small") "hello"
            V.length v @?= 1536
          _ -> putStrLn "BAIKAI_EMBEDDING_LIVE not set; skipping live test"
    ]
