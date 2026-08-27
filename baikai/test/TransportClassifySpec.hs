-- | The one transport classifier, pinned against the exception shapes
-- @http-client@, @tls@ and the socket layer actually raise.
--
-- The rule under test is /where/ the failure happened, not what type it
-- is: a connection that existed and broke is retryable, a connection
-- that could never work is not, and a programming error is neither. The
-- cases below therefore pair each constructor with the phase it belongs
-- to, and the negative cases matter as much as the positive ones — a
-- classifier that calls a @userError@ a network blip feeds a retry loop
-- a bug it can never retry away.
module TransportClassifySpec (tests) where

import Baikai.Error (BaikaiError (..), ErrorCategory (..), isRetryable)
import Baikai.Provider.Transport.Classify
  ( classifyHttpException,
    classifyHttpExceptionContent,
    classifyIOException,
    classifyTlsException,
    classifyTransportException,
  )
import Control.Exception (toException)
import Data.Text qualified as Text
import Foreign.C.Error (Errno (..), eCONNABORTED, eCONNRESET)
import GHC.IO.Exception qualified as IOE
import Network.HTTP.Client qualified as HTTP
import Network.TLS qualified as TLS
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Baikai.Provider.Transport.Classify"
    [ testGroup "socket failures during the body read" ioTests,
      testGroup "http-client exception content" httpContentTests,
      testGroup "TLS failures" tlsTests,
      testGroup "the top-level dispatcher" dispatchTests
    ]

-- ============================================================
-- Fixtures
-- ============================================================

-- | An 'IOError' shaped the way the socket layer raises one during a
-- body read: a location naming the recv call, a description from the
-- kernel, an error type and an errno.
socketError :: IOE.IOErrorType -> Errno -> String -> IOE.IOException
socketError ty (Errno n) description =
  IOE.IOError
    { IOE.ioe_handle = Nothing,
      IOE.ioe_type = ty,
      IOE.ioe_location = "Network.Socket.recvBuf",
      IOE.ioe_description = description,
      IOE.ioe_errno = Just n,
      IOE.ioe_filename = Nothing
    }

-- | The canonical mid-stream reset: the peer sent RST while the
-- response body was still arriving.
connectionReset :: IOE.IOException
connectionReset = socketError IOE.ResourceVanished eCONNRESET "Connection reset by peer"

assertTransient :: BaikaiError -> Assertion
assertTransient be = do
  category be @?= TransientError
  isRetryable be @?= True

assertNotRetryable :: ErrorCategory -> BaikaiError -> Assertion
assertNotRetryable expected be = do
  category be @?= expected
  isRetryable be @?= False

assertJustTransient :: Maybe BaikaiError -> Assertion
assertJustTransient = \case
  Just be -> assertTransient be
  Nothing -> assertFailure "expected a classified transport failure, got Nothing"

-- ============================================================
-- Raw IOExceptions
-- ============================================================

ioTests :: [TestTree]
ioTests =
  [ testCase "a connection reset during the body read is transient" $
      assertJustTransient (classifyIOException connectionReset),
    -- base maps ECONNABORTED to the IOErrorType constructor named
    -- OtherError, so a rule that looked only at the type would call an
    -- aborted connection a programming error.
    testCase "ECONNABORTED is recognised by errno when the error type is OtherError" $
      assertJustTransient
        ( classifyIOException
            (socketError IOE.OtherError eCONNABORTED "Software caused connection abort")
        ),
    testCase "an end-of-file on the socket is transient" $
      assertJustTransient
        ( classifyIOException
            (IOE.IOError Nothing IOE.EOF "brRead" "end of input" Nothing Nothing)
        ),
    testCase "a timed-out read is transient" $
      assertJustTransient
        ( classifyIOException
            (IOE.IOError Nothing IOE.TimeExpired "recv" "operation timed out" Nothing Nothing)
        ),
    testCase "a userError is not a transport failure" $ do
      classifyIOException (userError "bug") @?= Nothing
      classifyTransportException (toException (userError "bug")) @?= Nothing,
    testCase "a missing file is not a transport failure" $
      classifyIOException
        (IOE.IOError Nothing IOE.NoSuchThing "openFile" "does not exist" Nothing (Just "/nope"))
        @?= Nothing,
    testCase "the classified message keeps the socket detail" $
      case classifyIOException connectionReset of
        Just be -> assertBool "message names the reset" ("reset by peer" `Text.isInfixOf` message be)
        Nothing -> assertFailure "expected a classified transport failure"
  ]

-- ============================================================
-- HttpExceptionContent
-- ============================================================

httpContentTests :: [TestTree]
httpContentTests =
  [ testCase "InvalidChunkHeaders is transient" $
      assertTransient (classifyHttpExceptionContent HTTP.InvalidChunkHeaders),
    testCase "ResponseBodyTooShort is transient" $
      assertTransient (classifyHttpExceptionContent (HTTP.ResponseBodyTooShort 100 40)),
    testCase "ConnectionClosed is transient" $
      assertTransient (classifyHttpExceptionContent HTTP.ConnectionClosed),
    testCase "IncompleteHeaders is transient" $
      assertTransient (classifyHttpExceptionContent HTTP.IncompleteHeaders),
    testCase "NoResponseDataReceived is transient" $
      assertTransient (classifyHttpExceptionContent HTTP.NoResponseDataReceived),
    testCase "ConnectionTimeout and ResponseTimeout are transient" $ do
      assertTransient (classifyHttpExceptionContent HTTP.ConnectionTimeout)
      assertTransient (classifyHttpExceptionContent HTTP.ResponseTimeout),
    testCase "ConnectionFailure is transient" $
      assertTransient
        (classifyHttpExceptionContent (HTTP.ConnectionFailure (toException connectionReset))),
    testCase "InternalException unwraps to the inner socket rule" $
      assertTransient
        (classifyHttpExceptionContent (HTTP.InternalException (toException connectionReset))),
    testCase "InternalException unwraps to the inner TLS rule" $
      assertNotRetryable
        OtherError
        ( classifyHttpExceptionContent
            ( HTTP.InternalException
                (toException (TLS.HandshakeFailed (TLS.Error_Misc "certificate rejected")))
            )
        ),
    testCase "InvalidUrlException is InvalidRequest" $
      assertNotRetryable
        InvalidRequest
        (classifyHttpException (HTTP.InvalidUrlException "http://%%%" "invalid escape")),
    testCase "InvalidRequestHeader is InvalidRequest" $
      assertNotRetryable
        InvalidRequest
        (classifyHttpExceptionContent (HTTP.InvalidRequestHeader "X-Bad: \n")),
    testCase "InvalidDestinationHost is InvalidRequest" $
      assertNotRetryable
        InvalidRequest
        (classifyHttpExceptionContent (HTTP.InvalidDestinationHost "bad host")),
    testCase "WrongRequestBodyStreamSize is InvalidRequest" $
      assertNotRetryable
        InvalidRequest
        (classifyHttpExceptionContent (HTTP.WrongRequestBodyStreamSize 10 4)),
    -- A server that does not speak HTTP, or a proxy or TLS setup that
    -- cannot work, will answer the retry exactly the same way.
    testCase "InvalidStatusLine, TooManyHeaderFields and TlsNotSupported are not retryable" $ do
      assertNotRetryable OtherError (classifyHttpExceptionContent (HTTP.InvalidStatusLine "gibberish"))
      assertNotRetryable OtherError (classifyHttpExceptionContent HTTP.TooManyHeaderFields)
      assertNotRetryable OtherError (classifyHttpExceptionContent HTTP.TlsNotSupported)
      assertNotRetryable OtherError (classifyHttpExceptionContent (HTTP.TooManyRedirects []))
  ]

-- ============================================================
-- TLS
-- ============================================================

tlsTests :: [TestTree]
tlsTests =
  [ -- Upstream's own manager agrees: http-client-tls treats a
    -- post-handshake EOF as retryable.
    testCase "a TLS end-of-file after the handshake is transient" $
      assertTransient (classifyTlsException (TLS.PostHandshake TLS.Error_EOF)),
    testCase "a terminated TLS session is transient" $
      assertTransient (classifyTlsException (TLS.Terminated True "peer closed" TLS.Error_EOF)),
    testCase "an uncontextualized TLS failure is transient" $
      assertTransient (classifyTlsException (TLS.Uncontextualized TLS.Error_EOF)),
    -- Against a well-known API host a handshake failure is a trust-store
    -- or protocol mismatch, which the retry reproduces. A socket reset
    -- during connect arrives as ConnectionFailure instead, and is
    -- transient.
    testCase "a failed TLS handshake is not retryable" $
      assertNotRetryable
        OtherError
        (classifyTlsException (TLS.HandshakeFailed (TLS.Error_Misc "certificate rejected"))),
    testCase "a session that never existed is not retryable" $ do
      assertNotRetryable OtherError (classifyTlsException TLS.ConnectionNotEstablished)
      assertNotRetryable OtherError (classifyTlsException TLS.MissingHandshake)
  ]

-- ============================================================
-- Dispatch
-- ============================================================

dispatchTests :: [TestTree]
dispatchTests =
  [ testCase "a raw IOException reaches the socket rule" $
      assertJustTransient (classifyTransportException (toException connectionReset)),
    -- This is the shape that reaches a worker raw: http-client wraps the
    -- body reader with nothing that would convert it.
    testCase "a raw TLSException reaches the TLS rule" $
      assertJustTransient
        (classifyTransportException (toException (TLS.PostHandshake TLS.Error_EOF))),
    testCase "an HttpException reaches the http-client rule" $
      assertJustTransient
        ( classifyTransportException
            (toException (HTTP.HttpExceptionRequest HTTP.defaultRequest HTTP.InvalidChunkHeaders))
        ),
    testCase "anything else is not a transport failure" $
      classifyTransportException (toException (userError "callback bug")) @?= Nothing
  ]
