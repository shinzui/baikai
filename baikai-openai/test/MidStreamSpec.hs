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
    emptyOptions,
  )
import Baikai.Api (Api (..))
import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Model (Model)
import Baikai.Models.Generated (openai_gpt_4o_mini)
import Baikai.Provider.OpenAI.Api (SseDriver, openaiChatStreamWith)
import Baikai.Provider.OpenAI.Sse (sseFromResponse)
import Contract (assertErrorContract)
import Control.Exception (SomeException, throwIO, toException)
import Control.Lens ((&), (.~))
import Data.ByteString (ByteString)
import Data.CaseInsensitive qualified as CI
import Data.Generics.Labels ()
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Foreign.C.Error (Errno (..), eCONNRESET)
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.Internal qualified as HTTPI
import Network.HTTP.Types.Status (mkStatus)
import Network.HTTP.Types.Version (http11)
import Network.TLS qualified as TLS
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "mid-stream failures (OpenAI-compatible)"
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

-- | Two ordinary content frames, @"Hel"@ then @"lo"@, with no
-- @finish_reason@: the stream is healthy right up to the failure.
contentChunks :: [ByteString]
contentChunks =
  [ "data: {\"id\":\"chatcmpl-1\",\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"}}]}\n\n",
    "data: {\"id\":\"chatcmpl-1\",\"model\":\"gpt-4o-mini\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo\"}}]}\n\n"
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
  Stream.toList (openaiChatStreamWith (failingDriver chunks ex) testModel emptyContext testOptions)

failingDriver :: [ByteString] -> SomeException -> SseDriver
failingDriver chunks ex _env _headers _body onMetadata onEvent = do
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
  openai_gpt_4o_mini
    & #api .~ OpenAIChatCompletions
    & #baseUrl .~ "https://api.openai.com"

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
