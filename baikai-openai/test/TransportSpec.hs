module TransportSpec (tests) where

import Baikai
import Baikai.Provider.OpenAI.Transport qualified as Transport
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Control.Lens ((&), (.~), (^.))
import Data.CaseInsensitive qualified as CI
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types.Header (RequestHeaders)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.OpenAI.Transport"
    [ clientEnvCacheTest,
      requestHeadersTest,
      timeoutTest,
      unknownHostKeyTest
    ]

clientEnvCacheTest :: TestTree
clientEnvCacheTest =
  testCase "cached ClientEnv is allocated once for a base URL" $ do
    let url = "https://cache-openai.test"
    before <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterFirst <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterSecond <- Transport.cachedClientEnvCount
    afterFirst @?= before + 1
    afterSecond @?= afterFirst

requestHeadersTest :: TestTree
requestHeadersTest =
  testCase "model and option headers reach the wire, options winning case-insensitively" $ do
    let model =
          emptyModel
            & #headers .~ Map.fromList [("X-Trace", "model"), ("authorization", "model-auth")]
        opts =
          emptyOptions
            & #headers .~ Map.fromList [("x-trace", "option"), ("Authorization", "option-auth")]
        headers = Transport.requestHeaders "secret" model opts
    header "X-Trace" headers @?= Just "option"
    header "authorization" headers @?= Just "option-auth"
    header "Accept" headers @?= Just "text/event-stream"

timeoutTest :: TestTree
timeoutTest =
  testCase "runWithTimeout classifies an elapsed whole-call timeout as transient" $ do
    result <- Transport.runWithTimeout (Just 1) (threadDelay 100000)
    case result of
      Just be -> do
        be ^. #category @?= TransientError
        "timeoutMs=1" `Text.isInfixOf` (be ^. #message) @?= True
      Nothing -> assertFailure "expected timeout error"

unknownHostKeyTest :: TestTree
unknownHostKeyTest =
  testCase "unknown hosts do not fall back to OPENAI_API_KEY" $
    withEnv "OPENAI_API_KEY" "openai-secret" $ do
      result <- try (Transport.resolveKey "https://unknown.example" emptyOptions) :: IO (Either BaikaiError Text.Text)
      case result of
        Left be -> be ^. #category @?= AuthError
        Right _ -> assertFailure "expected AuthError for unknown host"

header :: Text.Text -> RequestHeaders -> Maybe Text.Text
header name headers =
  Text.decodeUtf8 <$> lookup (CI.mk (Text.encodeUtf8 name)) headers

withEnv :: String -> String -> IO a -> IO a
withEnv name value =
  bracket
    (lookupEnv name <* setEnv name value)
    (maybe (unsetEnv name) (setEnv name))
    . const
