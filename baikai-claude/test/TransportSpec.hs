module TransportSpec (tests) where

import Baikai
import Baikai.Provider.Claude.Transport qualified as Transport
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Control.Lens ((&), (.~), (^.))
import Data.CaseInsensitive qualified as CI
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import Network.HTTP.Types.Header (RequestHeaders)
import Servant.Client qualified as Client
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Claude.Transport"
    [ clientEnvCacheTest,
      requestHeadersTest,
      sessionAffinityTest,
      timeoutTest,
      unknownHostKeyTest
    ]

-- | One entry per target, and one notion of what a target is.
--
-- Both halves are asserted in a single case because the cache is
-- process-global and this suite runs in parallel: two cases each reading
-- a count and expecting it to move by exactly one would race each other.
--
-- The normalisation half is what makes the count meaningful. The key is
-- the canonical rendering of "Baikai.Url"'s parse rather than the
-- caller's text, so a trailing slash and a capitalised host do not each
-- open their own connection pool to the same host — and the two provider
-- packages, which now share one cache in @Baikai.Http@, cannot disagree
-- about which target a URL names.
clientEnvCacheTest :: TestTree
clientEnvCacheTest =
  testCase "the ClientEnv cache allocates once per normalised base URL" $ do
    let url = "https://cache-anthropic.test"
    before <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterFirst <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterSecond <- Transport.cachedClientEnvCount
    afterFirst @?= before + 1
    afterSecond @?= afterFirst
    -- A different spelling of the same target: capitalised host,
    -- trailing slash.
    env <- Transport.getClientEnvCached "https://Cache-Anthropic.test/"
    afterVariant <- Transport.cachedClientEnvCount
    afterVariant @?= afterSecond
    Client.baseUrlHost (Client.baseUrl env) @?= "cache-anthropic.test"
    Client.baseUrlPath (Client.baseUrl env) @?= ""

requestHeadersTest :: TestTree
requestHeadersTest =
  testCase "model and option headers reach the wire, options winning case-insensitively" $ do
    let model =
          emptyModel
            & #headers .~ Map.fromList [("X-Trace", "model"), ("x-api-key", "model-key")]
        opts =
          emptyOptions
            & #headers .~ Map.fromList [("x-trace", "option"), ("X-API-Key", "option-key")]
        headers = Transport.requestHeaders "secret" (Just "2023-06-01") defaultAnthropicMessagesCompat emptyContext model opts
    header "X-Trace" headers @?= Just "option"
    header "x-api-key" headers @?= Just "option-key"
    header "anthropic-version" headers @?= Just "2023-06-01"

sessionAffinityTest :: TestTree
sessionAffinityTest =
  testCase "sendSessionAffinityHeaders adds a stable session header" $ do
    let compat = defaultAnthropicMessagesCompat {sendSessionAffinityHeaders = True}
        ctx =
          emptyContext
            & #systemPrompt .~ Just "system"
            & #messages .~ Vector.singleton (user "first")
        headers = Transport.requestHeaders "secret" Nothing compat ctx emptyModel emptyOptions
        affinity = Transport.sessionAffinityValue ctx
    Text.length affinity @?= 64
    header "x-session-affinity" headers @?= Just affinity

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
  testCase "unknown hosts do not fall back to ANTHROPIC_API_KEY" $
    withEnv "ANTHROPIC_API_KEY" "anthropic-secret" $ do
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
