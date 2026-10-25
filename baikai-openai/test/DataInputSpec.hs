module DataInputSpec (tests) where

import Baikai
import Baikai.Prelude
import Baikai.Provider.OpenAI.Cli qualified as Cli
import Baikai.Provider.OpenAI.Internal.Request qualified as R
import Baikai.Provider.OpenAI.Internal.Stream qualified as S
import Baikai.Provider.OpenAI.Responses.Request qualified as RR
import Baikai.Provider.OpenAI.Responses.Stream qualified as RS
import Control.Exception (try)
import Data.Aeson qualified as A
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.IORef
import Data.Text qualified as T
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import Test.Tasty
import Test.Tasty.HUnit

modelFixture :: Model
modelFixture = emptyModel & #modelId .~ "fixture" & #api .~ OpenAIChatCompletions

dataFixture :: A.Value
dataFixture = A.object ["z" A..= [1 :: Int, 2], "a" A..= ("日本語" :: T.Text)]

history :: Context
history = contextOf [AssistantMessage ((emptyResponse ^. #message) & #content .~ V.singleton (AssistantData (DataContent A.Null Nothing Nothing Nothing)))]

tests :: TestTree
tests =
  testGroup
    "structured input and history"
    [ testCase "Responses sends structured input canonically and refuses assistant data before driver" $ do
        req <- either (assertFailure . T.unpack) pure (RR.mapRequest (modelFixture & #api .~ OpenAIResponses) (contextOf [userData dataFixture]) emptyOptions)
        let bytes = BL.unpack (A.encode (req ^. #requestBody))
        assertBool "canonical data reaches Responses wire" (T.pack (BL.unpack (A.encode (canonicalDataText dataFixture))) `T.isInfixOf` T.pack bytes)
        calls <- newIORef (0 :: Int)
        es <- Stream.toList (RS.openaiResponsesStreamWith (\_ _ _ _ _ -> modifyIORef' calls (+ 1)) (modelFixture & #api .~ OpenAIResponses) history emptyOptions)
        readIORef calls >>= (@?= 0)
        case [e | EventError p <- es, Just e <- [p ^. #errorInfo]] of
          [e] -> e ^. #requestProblem @?= Just (UnsupportedFeature "messages[0].content[0]")
          _ -> assertFailure (show es),
      testCase "actual wire request contains canonical JSON in block position" $ do
        let ctx = contextOf [UserMessage (UserPayload (V.fromList [UserText (TextContent "before"), UserData dataFixture, UserText (TextContent "after")]) Nothing)]
        req <- either (assertFailure . T.unpack) pure (R.mapRequest modelFixture ctx emptyOptions)
        let wire = A.toJSON req
            bytes = BL.unpack (A.encode wire)
            jsonText = BL.unpack (A.encode (canonicalDataText dataFixture))
        assertBool ("structured text missing: " <> bytes) (T.pack jsonText `T.isInfixOf` T.pack bytes),
      testCase "OpenAIChatCompletions refuses assistant data with zero driver calls" $ do
        calls <- newIORef (0 :: Int)
        let driver _ _ _ _ _ = modifyIORef' calls (+ 1)
        es <- Stream.toList (S.openaiChatStreamWith driver modelFixture history emptyOptions)
        readIORef calls >>= (@?= 0)
        case [e | EventError p <- es, Just e <- [p ^. #errorInfo]] of
          [e] -> e ^. #requestProblem @?= Just (UnsupportedFeature "messages[0].content[0]")
          _ -> assertFailure (show es),
      testCase "CLI request carries JSON and refuses data history before spawning" $ do
        let cfg = Cli.defaultCodexCliConfig & #executable .~ "/nonexistent-baikai-data-test"
            (_, args) = Cli.codexCliCommand cfg modelFixture (contextOf [userData dataFixture]) emptyOptions
        assertBool "canonical JSON reaches argument vector" (any (T.isInfixOf (canonicalDataText dataFixture) . T.pack) args)
        result <- try ((Cli.codexCliProvider cfg ^. #complete) modelFixture history emptyOptions) :: IO (Either BaikaiError Response)
        case result of
          Left e -> e ^. #requestProblem @?= Just (UnsupportedFeature "messages[0].content[0]")
          Right r -> assertFailure (show r)
    ]
