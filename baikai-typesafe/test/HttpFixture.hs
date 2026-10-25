module HttpFixture (Fixture (..), Captured (..), Body (..), withFixture) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Exception (IOException, catch, finally)
import Control.Monad (forever, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Network.HTTP.Types
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp qualified as Warp

data Captured = Captured {path :: ByteString, headers :: RequestHeaders, body :: BL.ByteString}
  deriving stock (Eq, Show)

data Body = Reply BL.ByteString | Stalled

data Fixture = Fixture {base :: Text, captures :: IO [Captured], requested :: MVar (), closed :: MVar ()}

withFixture :: Int -> ResponseHeaders -> Body -> (Fixture -> IO a) -> IO a
withFixture code responseHeaders responseBody action = do
  ref <- newIORef []
  started <- newEmptyMVar
  ended <- newEmptyMVar
  let app request respond = do
        bytes <- Wai.strictRequestBody request
        modifyIORef' ref (<> [Captured (Wai.rawPathInfo request) (Wai.requestHeaders request) bytes])
        void (tryPutMVar started ())
        case responseBody of
          Reply response -> respond (Wai.responseLBS (mkStatus code "fixture") responseHeaders response)
          Stalled ->
            respond
              ( Wai.responseStream
                  status200
                  responseHeaders
                  ( \write flush ->
                      (flush >> forever (write (Builder.byteString (BS.replicate 65536 120)) >> flush >> threadDelay 10000))
                        `finally` void (tryPutMVar ended ())
                  )
              )
  Warp.testWithApplication (pure app) $ \port ->
    action (Fixture ("http://127.0.0.1:" <> T.pack (show port)) (readIORef ref) started ended)
