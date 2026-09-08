module TransportSpec (tests) where

import Baikai
import Baikai.Provider.OpenAI.Api (openaiChatStream)
import Baikai.Provider.OpenAI.Internal.Stream (openaiChatStreamWith)
import Baikai.Provider.OpenAI.Shape (describeThinkingShape)
import Baikai.Provider.OpenAI.Transport qualified as Transport
import Contract (assertErrorContract)
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.CaseInsensitive qualified as CI
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Vector qualified as Vector
import EndpointModels (chatRestrictedModel)
import Network.HTTP.Types.Header (RequestHeaders)
import Servant.Client qualified as Client
import Streamly.Data.Stream qualified as Stream
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.OpenAI.Transport"
    [ endpointRejectionTest,
      clientEnvCacheTest,
      requestHeadersTest,
      timeoutTest,
      nonPositiveTimeoutTest,
      unknownHostKeyTest,
      unusableBaseUrlTest
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
    let url = "https://cache-openai.test"
    before <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterFirst <- Transport.cachedClientEnvCount
    _ <- Transport.getClientEnvCached url
    afterSecond <- Transport.cachedClientEnvCount
    afterFirst @?= before + 1
    afterSecond @?= afterFirst
    -- A different spelling of the same target: capitalised host,
    -- trailing slash.
    env <- Transport.getClientEnvCached "https://Cache-openai.test/"
    afterVariant <- Transport.cachedClientEnvCount
    afterVariant @?= afterSecond
    Client.baseUrlHost (Client.baseUrl env) @?= "cache-openai.test"
    Client.baseUrlPath (Client.baseUrl env) @?= ""

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

nonPositiveTimeoutTest :: TestTree
nonPositiveTimeoutTest =
  testCase "runWithTimeout rejects a non-positive bound without running the action" $ do
    -- System.Timeout.timeout returns immediately at zero and runs
    -- unbounded below it, so both spellings used to fail instantly as a
    -- retryable TransientError, which a retry loop re-issues forever for
    -- what is a caller-side mistake.
    forM_ [0, -5] $ \ms -> do
      ran <- newIORef False
      result <- Transport.runWithTimeout (Just ms) (writeIORef ran True)
      case result of
        Just be -> do
          be ^. #category @?= InvalidRequest
          isRetryable be @?= False
        Nothing -> assertFailure ("expected an InvalidRequest for timeoutMs=" <> show ms)
      readIORef ran >>= (@?= False)

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

-- | A base URL baikai will not send to is refused before a key is read.
--
-- The order matters as much as the refusal. These cases run with the
-- provider's own key variable *unset*, so an AuthError would prove the
-- check ran too late; an InvalidRequest proves nothing was looked up.
-- The messages also have to say what is wrong without echoing the part
-- of the URL that could be a credential.
unusableBaseUrlTest :: TestTree
unusableBaseUrlTest =
  testCase "an unusable base URL is refused before any key is read"
    $ withoutEnv "OPENAI_OpenAIChatCompletions_KEY"
    $ forM_
      [ ("https://h.test/v1?api-version=2024-01", "query string"),
        ("https://u:pw@h.test", "credentials"),
        ("h.test", "https://"),
        ("https://h.test/v1/chat/completions", "endpoint path")
      ]
    $ \(url, needle) -> do
      let model = emptyModel & #api .~ OpenAIChatCompletions & #baseUrl .~ url
      events <- Stream.toList (openaiChatStream model emptyContext emptyOptions)
      case events of
        [EventStart _, EventError payload] -> case payload ^. #errorInfo of
          Nothing -> assertFailure (Text.unpack url <> ": the error carried no errorInfo")
          Just err -> do
            let message = err ^. #message
            (url, err ^. #category) @?= (url, InvalidRequest)
            assertBool
              (Text.unpack (url <> " should name the problem: " <> message))
              (needle `Text.isInfixOf` message)
            assertBool
              (Text.unpack (url <> " must not echo the query: " <> message))
              (not ("api-version=2024-01" `Text.isInfixOf` message))
            assertBool
              (Text.unpack (url <> " must not echo the password: " <> message))
              (not ("pw@" `Text.isInfixOf` message))
        other ->
          assertFailure
            (Text.unpack url <> ": expected [EventStart, EventError], got: " <> show other)

withoutEnv :: String -> IO a -> IO a
withoutEnv name =
  bracket
    (lookupEnv name <* unsetEnv name)
    (maybe (unsetEnv name) (setEnv name))
    . const

endpointRejectionTest :: TestTree
endpointRejectionTest = testCase "endpoint capability rejection precedes network on complete and stream" $ do
  calls <- newIORef (0 :: Int)
  let driver _ _ _ _ _ = modifyIORef' calls (+ 1)
      stream = openaiChatStreamWith driver
      model = chatRestrictedModel & #modelId .~ "renamed-text-only"
      tool = mkTool "lookup" "lookup" (Aeson.object [])
      provider =
        apiProviderWith OpenAIChatCompletions stream (streamingComplete stream)
          & #describeThinking .~ (\m opts -> describeThinkingShape (openaiCompletionsCompatFor m) (m ^. #reasoning) opts)
      options = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "unused")
  reg <- newProviderRegistry
  registerApiProviderWith reg provider
  forM_
    [ (emptyContext & #tools .~ Vector.singleton tool, options),
      (emptyContext, options & #toolChoice .~ Just ToolChoiceRequired),
      (emptyContext, options & #toolChoice .~ Just (ToolChoiceSpecific "lookup"))
    ]
    $ \(ctx, opts) -> do
      events <- Stream.toList (streamRequestWith reg model ctx opts)
      assertErrorContract events
      case last events of
        EventError payload -> case payload ^. #errorInfo of
          Just err -> do
            err ^. #category @?= InvalidRequest
            assertBool "actionable Responses explanation" ("Responses" `Text.isInfixOf` (err ^. #message))
          _ -> assertFailure "missing error"
        _ -> assertFailure "expected error terminal"
      response <- completeRequestWith reg model ctx opts
      response ^. (#message . #stopReason) @?= ErrorReason
  let strict =
        options
          & #thinking .~ Just ThinkingMinimal
          & #evidence .~ Just (evidenceRequest "strict-endpoint" & #strictness .~ EvidenceRequired EvidenceRequestedOnly)
  strictEvents <- Stream.toList (streamRequestWith reg model emptyContext strict)
  assertErrorContract strictEvents
  strictResponse <- completeRequestWith reg model emptyContext strict
  case responseError strictResponse of
    Just err -> err ^. #category @?= InvalidRequest
    _ -> assertFailure "strict complete must refuse adjusted reasoning"
  readIORef calls >>= (@?= 0)
