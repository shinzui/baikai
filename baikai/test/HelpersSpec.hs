module HelpersSpec (tests) where

import Baikai
import Baikai.Prelude
import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Vector qualified as Vector
import Streamly.Data.Stream qualified as Stream
import System.Environment qualified as Environment
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

helpersApi :: Api
helpersApi = Custom "baikai-helpers-test"

helpersModel :: Model
helpersModel =
  _Model
    & #modelId
    .~ "helpers-model"
    & #api
    .~ helpersApi
    & #provider
    .~ "helpers"

epoch :: UTCTime
epoch = read "2026-06-05 00:00:00 UTC"

tests :: TestTree
tests =
  testGroup
    "Baikai helpers"
    [ testCase "runToolLoop resolves repeated tool turns and leaves final response separate" $ do
        scripted <- newScripted [toolUseResponse "call_1" "get_time", toolUseResponse "call_2" "get_time", textResponse "done"] []
        let ctx0 = addUser "start" _Context
            dispatcher _ = pure (toolResultText "2026-06-05T00:00:00Z")
        (ctx1, resp) <- runToolLoopWith (scriptRegistry scripted) 5 dispatcher helpersModel ctx0 _Options
        calls <- scriptCalls scripted
        calls @?= 3
        responseStop resp @?= Stop
        Vector.length (ctx1 ^. #messages) @?= 5
        assertResolvedExchange "call_1" "2026-06-05T00:00:00Z" (Vector.toList (ctx1 ^. #messages) !! 1) (Vector.toList (ctx1 ^. #messages) !! 2)
        assertResolvedExchange "call_2" "2026-06-05T00:00:00Z" (Vector.toList (ctx1 ^. #messages) !! 3) (Vector.toList (ctx1 ^. #messages) !! 4),
      testCase "runToolLoop returns a replay-valid context on budget exhaustion" $ do
        scripted <- newScripted [toolUseResponse "call_1" "get_time", toolUseResponse "call_2" "get_time", textResponse "done"] []
        (ctx1, resp) <- runToolLoopWith (scriptRegistry scripted) 2 (const (pure (toolResultText "ok"))) helpersModel (addUser "start" _Context) _Options
        calls <- scriptCalls scripted
        calls @?= 2
        responseStop resp @?= ToolUse
        Vector.length (ctx1 ^. #messages) @?= 3
        assertResolvedExchange "call_1" "ok" (Vector.toList (ctx1 ^. #messages) !! 1) (Vector.toList (ctx1 ^. #messages) !! 2),
      testCase "runToolLoop returns an error response without appending it" $ do
        scripted <- newScripted [errorResponse helpersModel epoch 0 (providerError "broken")] []
        let ctx0 = addUser "start" _Context
        (ctx1, resp) <- runToolLoopWith (scriptRegistry scripted) 3 (const (pure (toolResultText "unused"))) helpersModel ctx0 _Options
        calls <- scriptCalls scripted
        calls @?= 1
        ctx1 @?= ctx0
        case responseError resp of
          Just err -> err ^. #message @?= "broken"
          Nothing -> assertFailure "expected error response",
      testCase "runToolLoop converts synchronous dispatcher exceptions into error tool results" $ do
        scripted <- newScripted [toolUseResponse "call_1" "explode", textResponse "recovered"] []
        (ctx1, resp) <-
          runToolLoopWith
            (scriptRegistry scripted)
            3
            (\_ -> Exception.throwIO (userError "boom"))
            helpersModel
            (addUser "start" _Context)
            _Options
        responseStop resp @?= Stop
        case Vector.toList (ctx1 ^. #messages) of
          [_, _, ToolResultMessage ToolResultPayload {content = blocks, isError = err}] -> do
            err @?= True
            assertBool "tool error should include exception text" ("boom" `Text.isInfixOf` toolText blocks)
          msgs -> assertFailure ("unexpected messages: " <> show msgs),
      testCase "runToolLoop terminates a ToolUse response with no tool calls" $ do
        scripted <- newScripted [toolUseNoCallsResponse] []
        let ctx0 = addUser "start" _Context
        (ctx1, resp) <- runToolLoopWith (scriptRegistry scripted) 3 (const (pure (toolResultText "unused"))) helpersModel ctx0 _Options
        calls <- scriptCalls scripted
        calls @?= 1
        responseStop resp @?= ToolUse
        ctx1 @?= ctx0,
      testCase "completeText returns text and throws BaikaiError on failures" $ do
        registerOneShot (Custom "baikai-helpers-text-ok") (textResponse "plain text")
        ok <-
          completeText
            (helpersModel & #api .~ Custom "baikai-helpers-text-ok")
            "prompt"
        ok @?= "plain text"
        registerApiProvider
          (errorProvider (Custom "baikai-helpers-text-error") (providerError "text failed"))
        thrown <-
          Exception.try
            ( completeText
                (helpersModel & #api .~ Custom "baikai-helpers-text-error")
                "prompt"
            ) ::
            IO (Either BaikaiError Text)
        case thrown of
          Left err -> err ^. #message @?= "text failed"
          Right txt -> assertFailure ("expected BaikaiError, got text: " <> Text.unpack txt),
      testCase "streamRequestEachWith and streamRequestListWith expose streamRequest without streamly imports" $ do
        let events = textEvents "stream-id" "streamed"
        scripted <- newScripted [] events
        seenRef <- newIORef []
        resp <- streamRequestEachWith (scriptRegistry scripted) (\event -> atomicModifyIORef' seenRef (\xs -> (xs <> [event], ()))) helpersModel _Context _Options
        seen <- readIORef seenRef
        expected <- streamingComplete (\_ _ _ -> Stream.fromList events) helpersModel _Context _Options
        listed <- streamRequestListWith (scriptRegistry scripted) helpersModel _Context _Options
        seen @?= events
        listed @?= events
        resp @?= expected,
      testCase "ApiKeyEnvChain resolves the first set environment variable" $ do
        let first = "BAIKAI_HELPERS_CHAIN_FIRST"
            second = "BAIKAI_HELPERS_CHAIN_SECOND"
        withUnsetEnv first $
          withUnsetEnv second $ do
            Environment.setEnv second "second-key"
            resolved <- resolveApiKey (ApiKeyEnvChain [first, second])
            resolved @?= "second-key"
            Environment.setEnv first "first-key"
            resolvedFirst <- resolveApiKey (ApiKeyEnvChain [first, second])
            resolvedFirst @?= "first-key",
      testCase "ApiKeyEnvChain reports all probed names when unset" $ do
        let first = "BAIKAI_HELPERS_CHAIN_MISSING_A"
            second = "BAIKAI_HELPERS_CHAIN_MISSING_B"
        withUnsetEnv first $
          withUnsetEnv second $ do
            thrown <- Exception.try (resolveApiKey (ApiKeyEnvChain [first, second])) :: IO (Either BaikaiError Text)
            case thrown of
              Left err -> do
                err ^. #category @?= AuthError
                assertBool "message should include first name" (Text.pack first `Text.isInfixOf` (err ^. #message))
                assertBool "message should include second name" (Text.pack second `Text.isInfixOf` (err ^. #message))
              Right key -> assertFailure ("expected auth error, got key: " <> Text.unpack key),
      testCase "mkModel fills dispatch discriminators and defaults" $ do
        let model = mkModel OpenAIChatCompletions "gpt-test" "https://example.test"
        model ^. #api @?= OpenAIChatCompletions
        model ^. #modelId @?= "gpt-test"
        model ^. #baseUrl @?= "https://example.test"
        model ^. #name @?= "gpt-test"
        model ^. #provider @?= renderApi OpenAIChatCompletions,
      testCase "newProviderRegistryFrom uses last provider for duplicate tags" $ do
        reg <-
          newProviderRegistryFrom
            [oneShotProvider helpersApi "first", oneShotProvider helpersApi "second"]
        resp <- completeRequestWith reg helpersModel _Context _Options
        flattenAssistantText (flattenAssistantBlocks resp) @?= "second",
      testCase "assertRegistered passes when all tags exist and throws for missing tags" $ do
        reg <- newProviderRegistryFrom [oneShotProvider helpersApi "ok"]
        assertRegistered reg [helpersApi]
        thrown <-
          Exception.try (assertRegistered reg [helpersApi, Custom "missing-one", Custom "missing-two"]) ::
            IO (Either BaikaiError ())
        case thrown of
          Left err -> do
            err ^. #category @?= ProviderUnavailable
            assertBool "message should include first missing tag" ("missing-one" `Text.isInfixOf` (err ^. #message))
            assertBool "message should include second missing tag" ("missing-two" `Text.isInfixOf` (err ^. #message))
          Right () -> assertFailure "expected ProviderUnavailable"
    ]

data Scripted = Scripted
  { scriptRegistry :: !ProviderRegistry,
    scriptCallRef :: !(IORef Int)
  }

newScripted :: [Response] -> [AssistantMessageEvent] -> IO Scripted
newScripted responses events = do
  reg <- newProviderRegistry
  responsesRef <- newIORef responses
  callsRef <- newIORef 0
  registerApiProviderWith reg $
    ApiProvider
      { apiTag = helpersApi,
        complete = scriptedComplete responsesRef callsRef,
        stream = \_ _ _ -> Stream.fromList events
      }
  pure Scripted {scriptRegistry = reg, scriptCallRef = callsRef}

scriptedComplete :: IORef [Response] -> IORef Int -> Model -> Context -> Options -> IO Response
scriptedComplete responsesRef callsRef model _ctx _opts = do
  atomicModifyIORef' callsRef (\n -> (n + 1, ()))
  mResp <-
    atomicModifyIORef' responsesRef $ \case
      [] -> ([], Nothing)
      r : rs -> (rs, Just r)
  pure $
    maybe
      (errorResponse model epoch 0 (providerError "script exhausted"))
      (stampModel model)
      mResp

scriptCalls :: Scripted -> IO Int
scriptCalls scripted = readIORef (scriptCallRef scripted)

registerOneShot :: Api -> Response -> IO ()
registerOneShot apiTag resp =
  registerApiProvider
    ApiProvider
      { apiTag,
        complete = \model _ctx _opts -> pure (stampModel model resp),
        stream = \_ _ _ -> Stream.fromList []
      }

oneShotProvider :: Api -> Text -> ApiProvider
oneShotProvider apiTag body =
  ApiProvider
    { apiTag,
      complete = \model _ctx _opts -> pure (stampModel model (textResponse body)),
      stream = \_ _ _ -> Stream.fromList []
    }

errorProvider :: Api -> BaikaiError -> ApiProvider
errorProvider apiTag err =
  ApiProvider
    { apiTag,
      complete = \model _ctx _opts -> pure (errorResponse model epoch 0 err),
      stream = \_ _ _ -> Stream.fromList []
    }

stampModel :: Model -> Response -> Response
stampModel model resp =
  resp
    & #model
    .~ model
    & #api
    .~ (model ^. #api)
    & #provider
    .~ (model ^. #provider)

toolUseResponse :: Text -> Text -> Response
toolUseResponse callId toolName =
  responseWith
    ToolUse
    (Vector.singleton (AssistantToolCall (_ToolCall {id_ = callId, name = toolName, arguments = Aeson.object []})))
    Nothing

toolUseNoCallsResponse :: Response
toolUseNoCallsResponse =
  responseWith ToolUse (Vector.singleton (AssistantText (TextContent "no calls"))) Nothing

textResponse :: Text -> Response
textResponse body =
  responseWith Stop (Vector.singleton (AssistantText (TextContent body))) Nothing

responseWith :: StopReason -> Vector AssistantContent -> Maybe Text -> Response
responseWith sr blocks err =
  _Response
    & #message
    .~ AssistantPayload
      { content = blocks,
        usage = _Usage,
        stopReason = sr,
        errorMessage = err,
        timestamp = Just epoch
      }
    & #model
    .~ helpersModel
    & #api
    .~ helpersApi
    & #provider
    .~ "helpers"

responseStop :: Response -> StopReason
responseStop Response {message = AssistantPayload {stopReason = sr}} = sr

assertResolvedExchange :: Text -> Text -> Message -> Message -> IO ()
assertResolvedExchange callId expectedText assistantMsg resultMsg = do
  case assistantMsg of
    AssistantMessage AssistantPayload {content = blocks, stopReason = sr} -> do
      sr @?= ToolUse
      case [tc | AssistantToolCall tc <- Vector.toList blocks] of
        [tc] -> tc ^. #id_ @?= callId
        calls -> assertFailure ("expected one tool call, got: " <> show calls)
    _ -> assertFailure ("expected assistant tool-use message, got: " <> show assistantMsg)
  case resultMsg of
    ToolResultMessage ToolResultPayload {toolCallId = actual, content = blocks, isError = err} -> do
      actual @?= callId
      err @?= False
      toolText blocks @?= expectedText
    _ -> assertFailure ("expected tool result message, got: " <> show resultMsg)

toolText :: Vector ToolResultContent -> Text
toolText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \case
          ToolResultText (TextContent t) -> Just t
          _ -> Nothing
      )

textEvents :: Text -> Text -> [AssistantMessageEvent]
textEvents rid body =
  let msg =
        AssistantMessage
          AssistantPayload
            { content = Vector.singleton (AssistantText (TextContent body)),
              usage = _Usage,
              stopReason = Stop,
              errorMessage = Nothing,
              timestamp = Just epoch
            }
      start =
        AssistantMessage
          AssistantPayload
            { content = Vector.empty,
              usage = _Usage,
              stopReason = Stop,
              errorMessage = Nothing,
              timestamp = Just epoch
            }
   in [ EventStart StartPayload {partial = start, responseId = Just rid},
        TextStart IndexPayload {contentIndex = 0},
        TextDelta DeltaPayload {contentIndex = 0, delta = body},
        TextEnd BlockEndPayload {contentIndex = 0, content = body},
        EventDone (doneTerminal (Just rid) Stop msg)
      ]

withUnsetEnv :: String -> IO a -> IO a
withUnsetEnv name action =
  Exception.bracket
    ( do
        old <- Environment.lookupEnv name
        Environment.unsetEnv name
        pure old
    )
    restore
    (const action)
  where
    restore Nothing = Environment.unsetEnv name
    restore (Just value) = Environment.setEnv name value
