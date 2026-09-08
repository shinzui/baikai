module ResponsesTransportSpec (tests) where

import Baikai.Provider.OpenAI.Sse (buildResponsesRequest)
import Baikai.Provider.OpenAI.Transport (getClientEnvCached)
import Data.Aeson qualified as Aeson
import Network.HTTP.Client qualified as HTTP
import Servant.Client qualified as Client
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses HTTP request"
    [ testCase "POST path normalizes one version segment and never redirects" $ do
        mapM_
          ( \url -> do
              env <- getClientEnvCached url
              let body = Aeson.object ["store" Aeson..= False]
                  req = buildResponsesRequest (Client.baseUrl env) [("Authorization", "Bearer fixture")] body
              HTTP.path req @?= "/v1/responses"
              HTTP.method req @?= "POST"
              case HTTP.requestBody req of
                HTTP.RequestBodyLBS encoded -> encoded @?= Aeson.encode body
                _ -> assertFailure "expected the prepared JSON body"
              HTTP.redirectCount req @?= 0
              HTTP.requestHeaders req @?= [("Authorization", "Bearer fixture")]
          )
          ["https://api.openai.com", "https://api.openai.com/v1", "https://api.openai.com/v1/"]
    ]
