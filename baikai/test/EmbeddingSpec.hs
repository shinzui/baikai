-- | Tests for the embeddings client (EP-15, M1).
--
-- The request-mapping test is hermetic: it asserts on the pure
-- 'mkEmbeddingRequest' (no network), proving the input text, model id, and
-- dimensions land where the OpenAI @\/v1\/embeddings@ wire expects them. The live
-- test is gated on @BAIKAI_EMBEDDING_LIVE=1@ (and a real @OPENAI_API_KEY@) so the
-- default run stays offline.
module EmbeddingSpec (tests) where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Embedding
  ( EmbeddingModel (..),
    embedOne,
    embeddingClientEnv,
    emptyEmbeddingModel,
    firstEmbedding,
    mkEmbeddingRequest,
    openAIEmbeddingModel,
    resolveEmbeddingKey,
  )
import Baikai.Error (BaikaiError, ErrorCategory (..), decodeError)
import Baikai.Http qualified as Http
import Control.Exception qualified as Exception
import Control.Lens ((&), (.~), (^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as V
import OpenAI.V1.Embeddings qualified as Emb
import OpenAI.V1.Models qualified as OpenAIModels
import Servant.Client qualified as Client
import System.Environment (lookupEnv)
import System.Environment qualified as Environment
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

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
      testCase "an embedding host resolves its own key, not OpenAI's" $ do
        -- The defect: whatever the base URL said, the default key was
        -- OPENAI_API_KEY. Pointing an EmbeddingModel at DeepSeek sent an
        -- OpenAI key to DeepSeek.
        withEnv "OPENAI_API_KEY" (Just "openai-secret") $
          withEnv "DEEPSEEK_API_KEY" Nothing $ do
            err <-
              expectAuthError
                (emptyEmbeddingModel & #baseUrl .~ "https://api.deepseek.com")
            assertBool
              ("names the host's own variable: " <> Text.unpack (err ^. #message))
              ("DEEPSEEK_API_KEY" `Text.isInfixOf` (err ^. #message)),
      testCase "an unknown embedding host refuses rather than sending OpenAI's key" $
        withEnv "OPENAI_API_KEY" (Just "openai-secret") $ do
          err <-
            expectAuthError
              (emptyEmbeddingModel & #baseUrl .~ "https://vectors.example")
          assertBool
            ("says what to set: " <> Text.unpack (err ^. #message))
            ("EmbeddingModel.apiKey" `Text.isInfixOf` (err ^. #message)),
      testCase "the OpenAI default still resolves OPENAI_API_KEY" $
        withEnv "OPENAI_API_KEY" (Just "openai-secret") $ do
          resolved <- resolveEmbeddingKey (openAIEmbeddingModel "text-embedding-3-small")
          resolved @?= "openai-secret",
      testCase "an explicit key source wins over the per-host table" $
        withEnv "OPENAI_API_KEY" (Just "openai-secret") $ do
          resolved <-
            resolveEmbeddingKey
              ( openAIEmbeddingModel "m"
                  & #apiKey
                    .~ Just (ApiKeyLiteral "explicit-key")
              )
          resolved @?= "explicit-key",
      testCase "embeddings share the connection cache with the chat providers" $ do
        -- One TLS manager per host, not one per call: the SDK's own
        -- getClientEnv allocated a fresh manager every time embed ran.
        before <- Http.cachedClientEnvCount
        _ <- embeddingClientEnv (emptyEmbeddingModel & #baseUrl .~ "https://embed-cache.test")
        env <- embeddingClientEnv (emptyEmbeddingModel & #baseUrl .~ "https://Embed-Cache.test/")
        afterBoth <- Http.cachedClientEnvCount
        afterBoth @?= before + 1
        Client.baseUrlHost (Client.baseUrl env) @?= "embed-cache.test"
        Client.baseUrlPath (Client.baseUrl env) @?= "",
      testCase "the #field idiom compiles on EmbeddingModel" $ do
        -- It could not before: the record derived neither Generic nor Eq.
        let m = openAIEmbeddingModel "m" & #dimensions .~ Just 256
        m ^. #dimensions @?= Just 256
        m @?= (openAIEmbeddingModel "m" & #dimensions .~ Just 256),
      testCase "live embedding returns a 1536-length vector" $ do
        live <- lookupEnv "BAIKAI_EMBEDDING_LIVE"
        case live of
          Just "1" -> do
            v <- embedOne (openAIEmbeddingModel "text-embedding-3-small") "hello"
            V.length v @?= 1536
          _ -> putStrLn "BAIKAI_EMBEDDING_LIVE not set; skipping live test"
    ]

-- | Resolve a model's key, expecting it to refuse.
expectAuthError :: EmbeddingModel -> IO BaikaiError
expectAuthError m = do
  thrown <- Exception.try (resolveEmbeddingKey m) :: IO (Either BaikaiError Text)
  case thrown of
    Right key -> assertFailure ("expected an AuthError, got a key: " <> Text.unpack key)
    Left err -> do
      err ^. #category @?= AuthError
      pure err

-- | Run an action with one environment variable set to a value, or
-- removed, restoring whatever was there before.
withEnv :: String -> Maybe String -> IO a -> IO a
withEnv name value action =
  Exception.bracket
    ( do
        old <- Environment.lookupEnv name
        apply value
        pure old
    )
    apply
    (const action)
  where
    apply Nothing = Environment.unsetEnv name
    apply (Just v) = Environment.setEnv name v
