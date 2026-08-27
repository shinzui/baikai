-- | What the caller sees when a stream that started healthily stops
-- badly.
--
-- Every case here drives the real provider stream — @translate@, the
-- assembler, the worker's error path — over a body reader that raises
-- from @brRead@ after handing out the chunks it was given. That is
-- exactly what a socket reset, a server closing mid-chunk, and a TLS
-- session torn down after the handshake look like to the transport, and
-- it is the shape the classifier could not see before the shared core
-- rule: @http-client@ wraps the connect phase but not the body read, so
-- these exceptions reach the worker raw.
module MidStreamSpec (tests) where

import Baikai
  ( ApiKeySource (..),
    AssistantContent (..),
    AssistantMessageEvent (..),
    AssistantPayload (..),
    Message (..),
    Options,
    TerminalPayload (..),
    TextContent (..),
    emptyContext,
    emptyModel,
    emptyOptions,
  )
import Baikai.Api (Api (..))
import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Model (Model)
import Baikai.Models.Generated (anthropic_claude_haiku_4_5)
import Baikai.Provider.Claude.Api (SseDriver, claudeMessagesStream, claudeMessagesStreamWith)
import Baikai.Provider.Claude.Sse (sseFromResponse)
import Contract (assertErrorContract)
import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Exception (SomeException, bracket, finally, handle, throwIO, toException)
import Control.Lens ((&), (.~), (^.))
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Internal qualified as HTTPI
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Network.Socket qualified as Socket
import Network.TLS qualified as TLS
import Streamly.Data.Stream qualified as Stream
import System.Timeout qualified as Timeout
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "mid-stream failures (Anthropic Messages)"
    [ testCase "a connection reset after two chunks ends with a retryable EventError carrying the partial text" $ do
        events <- drainFailing contentChunks (toException connectionReset)
        assertErrorContract events
        be <- terminalError events
        category be @?= TransientError
        assertBool "a mid-stream reset is retryable" (isRetryable be)
        assertBool
          ("the drained text survives the failure: " <> show events)
          ("Hel" `Text.isInfixOf` terminalText events),
      testCase "a chunked-encoding EOF classifies as TransientError" $ do
        events <-
          drainFailing
            contentChunks
            (toException (HTTP.HttpExceptionRequest HTTP.defaultRequest HTTP.InvalidChunkHeaders))
        assertErrorContract events
        be <- terminalError events
        category be @?= TransientError
        assertBool "a mid-chunk close is retryable" (isRetryable be),
      -- Raised raw, as it is from brRead: http-client installs no
      -- wrapper around the body reader that would convert it.
      testCase "a TLS termination mid-body classifies as TransientError" $ do
        events <- drainFailing contentChunks (toException (TLS.PostHandshake TLS.Error_EOF))
        assertErrorContract events
        be <- terminalError events
        category be @?= TransientError
        assertBool "a torn-down TLS session is retryable" (isRetryable be),
      testCase "a stalled socket is cut off by timeoutMs as TransientError" $ do
        (events, _) <- withStalledServer $ \port -> drainLive port (Just 200)
        assertErrorContract events
        be <- terminalError events
        category be @?= TransientError
        assertBool "a timed-out call is retryable" (isRetryable be)
        assertBool
          ("the message names the bound that fired: " <> show (be ^. #message))
          ("timeoutMs=200" `Text.isInfixOf` (be ^. #message)),
      testCase "timeoutMs of zero is rejected as InvalidRequest before any connection" $ do
        (events, accepted) <- withStalledServer $ \port -> drainLive port (Just 0)
        assertErrorContract events
        be <- terminalError events
        category be @?= InvalidRequest
        assertBool "a caller-side mistake is not retryable" (not (isRetryable be))
        accepted @?= 0,
      testCase "a negative timeoutMs is rejected as InvalidRequest" $ do
        (events, accepted) <- withStalledServer $ \port -> drainLive port (Just (-1))
        assertErrorContract events
        be <- terminalError events
        category be @?= InvalidRequest
        assertBool "a caller-side mistake is not retryable" (not (isRetryable be))
        accepted @?= 0,
      testCase "a programming error in the body path stays OtherError" $ do
        events <- drainFailing contentChunks (toException (userError "bug in callback"))
        assertErrorContract events
        be <- terminalError events
        category be @?= OtherError
        assertBool "a callback bug is not retryable" (not (isRetryable be))
    ]

-- ============================================================
-- Fixtures
-- ============================================================

-- | A @message_start@, a text block opened at index 0, and one delta of
-- @"Hel"@: the stream is healthy right up to the failure, and one block
-- is still open when it lands.
contentChunks :: [ByteString]
contentChunks =
  [ "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_observed\",\"type\":\"message\",",
    "\"role\":\"assistant\",\"content\":[],\"model\":\"claude-haiku-4-5-20990101-server-side\",",
    "\"stop_reason\":null,\"stop_sequence\":null,",
    "\"usage\":{\"input_tokens\":11,\"output_tokens\":0}}}\n\n",
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}\n\n"
  ]

-- | The canonical mid-stream reset: the peer sent RST while the
-- response body was still arriving.
connectionReset :: IOE.IOException
connectionReset =
  IOE.IOError
    { IOE.ioe_handle = Nothing,
      IOE.ioe_type = IOE.ResourceVanished,
      IOE.ioe_location = "Network.Socket.recvBuf",
      IOE.ioe_description = "Connection reset by peer",
      IOE.ioe_errno = Just (case eCONNRESET of Errno n -> n),
      IOE.ioe_filename = Nothing
    }

-- | Drain the provider stream over a body reader that yields @chunks@
-- and then raises @ex@ from the next @brRead@.
drainFailing :: [ByteString] -> SomeException -> IO [AssistantMessageEvent]
drainFailing chunks ex =
  Stream.toList (claudeMessagesStreamWith (failingDriver chunks ex) testModel emptyContext testOptions)

failingDriver :: [ByteString] -> SomeException -> SseDriver
failingDriver chunks ex _call onMetadata onEvent = do
  resp <- mkFailingResponse chunks ex
  sseFromResponse resp onMetadata onEvent

-- | 'EvidenceSpec.mkResponse' with one difference: the exhausted branch
-- of the body reader raises instead of returning the empty string that
-- means end-of-body.
mkFailingResponse :: [ByteString] -> SomeException -> IO (HTTP.Response HTTP.BodyReader)
mkFailingResponse chunks ex = do
  ref <- newIORef chunks
  let bodyReader = do
        remaining <- readIORef ref
        case remaining of
          [] -> throwIO ex
          (x : xs) -> writeIORef ref xs >> pure x
  pure
    HTTPI.Response
      { HTTPI.responseStatus = mkStatus 200 "OK",
        HTTPI.responseVersion = http11,
        HTTPI.responseHeaders = [(CI.mk "content-type", "text/event-stream")],
        HTTPI.responseBody = bodyReader,
        HTTPI.responseCookieJar = HTTP.createCookieJar [],
        HTTPI.responseClose' = HTTPI.ResponseClose (pure ()),
        HTTPI.responseOriginalRequest = HTTP.defaultRequest,
        HTTPI.responseEarlyHints = []
      }

testModel :: Model
testModel =
  anthropic_claude_haiku_4_5
    & #api .~ AnthropicMessages
    & #baseUrl .~ "https://api.anthropic.com"

-- | A literal key so no environment variable is consulted.
testOptions :: Options
testOptions = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "test-key")

-- ============================================================
-- Assertions
-- ============================================================

terminalError :: [AssistantMessageEvent] -> IO BaikaiError
terminalError events = case reverse events of
  (EventError TerminalPayload {errorInfo = Just be} : _) -> pure be
  other -> assertFailure ("expected a terminal EventError carrying errorInfo, got: " <> show (take 1 other))

-- | The text the terminal message carries. This is where the drained
-- partial text has to survive: the assembler closes the blocks that
-- were open when the failure landed.
terminalText :: [AssistantMessageEvent] -> Text
terminalText events = case reverse events of
  (EventError TerminalPayload {message = AssistantMessage AssistantPayload {content = blocks}} : _) ->
    Text.concat [t | AssistantText TextContent {text = t} <- Vector.toList blocks]
  _ -> ""

-- ============================================================
-- A socket that never answers
-- ============================================================

-- | A TCP listener on @127.0.0.1@ that accepts one connection and holds
-- it open without ever reading or writing: an HTTP server that has
-- stalled after the connect succeeded.
--
-- Port @0@ asks the kernel for a free port, so the test never collides
-- with anything else on the machine or with a parallel run of itself.
-- The returned count is how many connections were accepted, which is
-- what proves a refused bound opened no socket at all.
withStalledServer :: (Int -> IO a) -> IO (a, Int)
withStalledServer body = bracket open Socket.close $ \listener -> do
  port <- Socket.socketPort listener
  accepted <- newIORef (0 :: Int)
  release <- newEmptyMVar
  acceptor <- forkIO . handle (\(_ :: SomeException) -> pure ()) $ do
    (conn, _) <- Socket.accept listener
    modifyIORef' accepted (+ 1)
    takeMVar release
    Socket.close conn
  result <- body (fromIntegral port) `finally` (tryPutMVar release () >> killThread acceptor)
  count <- readIORef accepted
  pure (result, count)
  where
    open = do
      s <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
      Socket.setSocketOption s Socket.ReuseAddr 1
      Socket.bind s (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
      Socket.listen s 1
      pure s

-- | Drain the /live/ stream against a local port, under a guard that
-- turns a stuck run into a failure rather than a hung suite.
drainLive :: Int -> Maybe Int -> IO [AssistantMessageEvent]
drainLive port bound = do
  let model = stallModel port
      opts = testOptions & #timeoutMs .~ bound
  result <- Timeout.timeout 10_000_000 (Stream.toList (claudeMessagesStream model emptyContext opts))
  case result of
    Just events -> pure events
    Nothing -> assertFailure "the ten-second guard fired: timeoutMs never did"

-- | A model pointed at the local listener. Built from 'emptyModel' so no
-- catalog base URL can override the port under test.
stallModel :: Int -> Model
stallModel port =
  emptyModel
    & #modelId
      .~ "stall-test"
    & #provider
      .~ "test"
    & #api
      .~ AnthropicMessages
    & #baseUrl
      .~ Text.pack ("http://127.0.0.1:" <> show port)
