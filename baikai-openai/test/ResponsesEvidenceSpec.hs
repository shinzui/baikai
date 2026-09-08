{-# LANGUAGE OverloadedRecordDot #-}

module ResponsesEvidenceSpec (tests) where

import Baikai hiding (describeThinking, model)
import Baikai.Models.Generated (openai_gpt_6_astra)
import Baikai.Provider.OpenAI.Internal.Stream (SseDriver)
import Baikai.Provider.OpenAI.Responses.Request (describeThinking)
import Baikai.Provider.OpenAI.Responses.Stream (openaiResponsesStreamWith)
import Baikai.Provider.OpenAI.Sse (sseFromResponse)
import Baikai.Trace (withTraceStreamWith)
import Baikai.Trace.Event qualified as Trace
import Baikai.Trace.Sink (TraceSink (..))
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket, finally)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Vector qualified as V
import Network.HTTP.Client.Internal qualified as HTTP
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses strict evidence over SSE bytes"
    [ testCase "strict success observes host facts and commits exact request and replay" $ do
        (response, body) <- replay 200 [wire success] strictOptions
        responseError response @?= Nothing
        ev <- proof response
        ev.observedModel @?= Observed "server-version"
        ev.providerRequestId @?= Observed "req-wire"
        ev.responseId @?= Observed "response-wire"
        ev.requestCommitment @?= commitmentDigest body
        ev.strength @?= EvidenceModelObserved
        ev.usage @?= Unobserved
        case V.toList response.message.content of
          [AssistantThinking t, AssistantText (TextContent "hello")] -> fmap (.replayItems) t.replayState @?= Just (V.singleton reasoningItem)
          _ -> assertFailure "lost reasoning continuation",
      testCase "arbitrary byte fragmentation keeps the same response commitment" $ do
        (whole, _) <- replay 200 [wire success] strictOptions
        (split, _) <- replay 200 (map BS.singleton (BS.unpack (wire success))) strictOptions
        a <- proof whole
        b <- proof split
        a.responseCommitment @?= b.responseCommitment
        split.message.content @?= whole.message.content,
      testCase "minimal effort is refused before transport with strict evidence" $ do
        (response, body) <- replay 200 [wire success] (strictOptions & #thinking .~ Just ThinkingMinimal)
        assertBool "strict adjustment refused" (responseError response /= Nothing)
        body @?= Null
        ev <- proof response
        ev.status @?= CallFailed
        ev.observedModel @?= Unobserved,
      testCase "local request validation still produces a strict evidence record" $ do
        (response, body) <- replay 200 [wire success] (strictOptions & #seed .~ Just 7)
        assertBool "unsupported option refused" (responseError response /= Nothing)
        body @?= Null
        ev <- proof response
        ev.status @?= CallFailed,
      testCase "non-2xx failure uses HTTP classification and captured request ID" $ do
        (response, _) <- replay 429 ["{\"error\":{\"message\":\"slow down\"}}"] strictOptions
        fmap (.category) (responseError response) @?= Just RateLimited
        ev <- proof response
        ev.status @?= CallFailed
        ev.providerRequestId @?= Observed "req-wire"
        ev.observedModel @?= Unobserved
        ev.responseCommitment @?= Unobserved,
      testCase "nested in-band error has one failed evidence record" $ do
        let failure = object ["type" .= ("response.failed" :: Text), "response" .= object ["id" .= ("failed-response" :: Text), "error" .= object ["code" .= ("rate_limit_exceeded" :: Text), "message" .= ("busy" :: Text)]]]
        (response, _) <- replay 200 [wire failure] strictOptions
        fmap (.category) (responseError response) @?= Just RateLimited
        ev <- proof response
        ev.responseId @?= Observed "failed-response"
        ev.status @?= CallFailed,
      testCase "malformed SSE JSON retains the streamed prefix and fails" $ do
        (response, _) <- replay 200 [wire added, wire deltaFrame, "data: {broken}\n\n"] strictOptions
        assertBool "decode failure" (responseError response /= Nothing)
        response.message.content @?= V.singleton (AssistantText (TextContent "partial"))
        ev <- proof response
        ev.status @?= CallFailed,
      testCase "EOF retains prefix without manufacturing a successful response" $ do
        (response, _) <- replay 200 [wire added, wire deltaFrame] strictOptions
        assertBool "EOF failure" (responseError response /= Nothing)
        response.message.content @?= V.singleton (AssistantText (TextContent "partial"))
        ev <- proof response
        ev.responseCommitment @?= Unobserved,
      testCase "observations absent from response remain absent under best effort" $ do
        let silent = object ["type" .= ("response.completed" :: Text), "response" .= object ["output" .= ([] :: [Value])]]
        (response, _) <- replay 200 [wire silent] (strictOptions & #evidence .~ Just (evidenceRequest "silent"))
        ev <- proof response
        ev.observedModel @?= Unobserved
        ev.responseId @?= Unobserved
        ev.usage @?= Unobserved,
      testCase "strict trace cancellation records one abort and releases the worker" $ do
        closed <- newEmptyMVar
        forever <- newEmptyMVar
        captured <- newIORef ([] :: [Trace.TraceEvent])
        recorded <- newEmptyMVar
        let blocked _ _ _ _ emit = (emit (Right added) >> emit (Right deltaFrame) >> takeMVar forever) `finally` putMVar closed ()
            save () e = do
              atomicModifyIORef' captured (\xs -> (e : xs, ()))
              case e of Trace.CallEvidence {} -> putMVar recorded (); _ -> pure ()
            sink = TraceSink (Fold.foldlM' save (pure ()))
        reg <- registryFor blocked
        result <- timeout 100000 (Stream.toList (withTraceStreamWith reg sink openai_gpt_6_astra emptyContext strictOptions))
        assertBool "consumer was cancelled" (case result of Nothing -> True; _ -> False)
        timeout 1000000 (takeMVar closed) >>= (@?= Just ())
        timeout 1000000 (takeMVar recorded) >>= (@?= Just ())
        events <- readIORef captured
        case [ev | Trace.CallEvidence {Trace.evidence = ev} <- events] of
          [ev] -> ev.status @?= CallAborted
          _ -> assertFailure "expected one abort evidence record",
      testCase "opting out does not attach evidence" $ do
        (response, _) <- replay 200 [wire success] (strictOptions & #evidence .~ Nothing)
        response.evidence @?= Nothing
    ]

proof :: Response -> IO ModelCallEvidence
proof response = case response.evidence of Just ev -> pure ev; Nothing -> assertFailure "missing evidence" >> fail "missing evidence"

strictOptions :: Options
strictOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "offline-key") & #evidence .~ Just (evidenceRequest "responses-strict" & #strictness .~ EvidenceRequired EvidenceRequestedOnly)

replay :: Int -> [ByteString] -> Options -> IO (Response, Value)
replay status chunks opts = do
  sent <- newIORef Null
  reg <- registryFor (byteDriver sent status chunks)
  response <- completeRequestWith reg openai_gpt_6_astra emptyContext opts
  body <- readIORef sent
  pure (response, body)

registryFor :: SseDriver -> IO ProviderRegistry
registryFor driver =
  newProviderRegistryFrom
    [ apiProvider OpenAIResponses (openaiResponsesStreamWith driver)
        & #describeThinking .~ describeThinking
        & #strengthCeiling .~ declaredStrength OpenAIResponses
    ]

byteDriver :: IORef Value -> Int -> [ByteString] -> SseDriver
byteDriver sent status chunks _ _ body onMetadata emit = do
  writeIORef sent body
  remaining <- newIORef chunks
  let reader = do
        xs <- readIORef remaining
        case xs of [] -> pure ""; x : rest -> writeIORef remaining rest >> pure x
      response =
        HTTP.Response
          { HTTP.responseStatus = mkStatus status "",
            HTTP.responseVersion = http11,
            HTTP.responseHeaders = [("x-request-id", "req-wire")],
            HTTP.responseBody = reader,
            HTTP.responseCookieJar = HTTP.createCookieJar [],
            HTTP.responseClose' = HTTP.ResponseClose (pure ()),
            HTTP.responseOriginalRequest = HTTP.defaultRequest,
            HTTP.responseEarlyHints = []
          }
  bracket (pure response) HTTP.responseClose (\r -> sseFromResponse r onMetadata emit)

wire :: Value -> ByteString
wire v = "event: response.event\ndata: " <> LBS.toStrict (Aeson.encode v) <> "\n\n"

reasoningItem :: Value
reasoningItem = object ["type" .= ("reasoning" :: Text), "id" .= ("rs" :: Text), "summary" .= ([] :: [Value]), "encrypted_content" .= ("opaque" :: Text), "future" .= True]

item :: Text -> Value
item text = object ["type" .= ("message" :: Text), "id" .= ("msg" :: Text), "content" .= [object ["type" .= ("output_text" :: Text), "text" .= text]]]

success :: Value
success = object ["type" .= ("response.completed" :: Text), "response" .= object ["id" .= ("response-wire" :: Text), "model" .= ("server-version" :: Text), "output" .= [reasoningItem, item "hello"]]]

added :: Value
added = object ["type" .= ("response.output_item.added" :: Text), "output_index" .= (0 :: Int), "item" .= item ""]

deltaFrame :: Value
deltaFrame = object ["type" .= ("response.output_text.delta" :: Text), "output_index" .= (0 :: Int), "content_index" .= (0 :: Int), "item_id" .= ("msg" :: Text), "delta" .= ("partial" :: Text)]
