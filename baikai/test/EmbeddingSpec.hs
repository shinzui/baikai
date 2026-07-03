-- | Tests for the embeddings client (EP-15, M1).
--
-- The request-mapping test is hermetic: it asserts on the pure
-- 'mkEmbeddingRequest' (no network), proving the input text, model id, and
-- dimensions land where the OpenAI @\/v1\/embeddings@ wire expects them. The live
-- test is gated on @BAIKAI_EMBEDDING_LIVE=1@ (and a real @OPENAI_API_KEY@) so the
-- default run stays offline.
module EmbeddingSpec (tests) where

import Baikai.Embedding (embedOne, firstEmbedding, mkEmbeddingRequest, openAIEmbeddingModel)
import Baikai.Error (decodeError)
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
      testCase "firstEmbedding reports an empty data array as a typed decode error" $ do
        firstEmbedding V.empty @?= Left (decodeError "embeddings response contained no data"),
      testCase "firstEmbedding extracts the first vector" $ do
        let vec = V.fromList [0.1, 0.2, 0.3]
            obj =
              Emb.EmbbeddingObject
                { Emb.index = 0,
                  Emb.embedding = vec,
                  Emb.object = "embedding"
                }
        firstEmbedding (V.singleton obj) @?= Right vec,
      testCase "live embedding returns a 1536-length vector" $ do
        live <- lookupEnv "BAIKAI_EMBEDDING_LIVE"
        case live of
          Just "1" -> do
            v <- embedOne (openAIEmbeddingModel "text-embedding-3-small") "hello"
            V.length v @?= 1536
          _ -> putStrLn "BAIKAI_EMBEDDING_LIVE not set; skipping live test"
    ]
