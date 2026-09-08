{-# LANGUAGE OverloadedRecordDot #-}

module FableContractsSpec (tests) where

import Baikai hiding (messages, model)
import Baikai.Models.Generated (anthropic_claude_fable_5_1)
import Baikai.Provider.Claude.Internal.Request qualified as R
import Baikai.Provider.Claude.Internal.Stream (SseDriver, claudeMessagesStreamWith)
import Claude.V1.Messages qualified as C
import Contract (assertErrorContract)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Fable contracts"
    [ testCase "forced choices fail before the driver for complete and stream, including renamed models" $
        forM_ [model, model & #modelId .~ "renamed-generation"] $ \m ->
          forM_ [ToolChoiceRequired, ToolChoiceSpecific "lookup"] $ \choice -> do
            sent <- newIORef False
            let never _ _ _ = writeIORef sent True
                opts = options & #toolChoice .~ Just choice
            events <- Stream.toList (claudeMessagesStreamWith never m context opts)
            assertErrorContract events
            response <- streamingComplete (claudeMessagesStreamWith never) m context opts
            fmap (.category) (responseError response) @?= Just InvalidRequest
            assertBool "useful correction" (maybe False (T.isInfixOf "ToolChoiceAuto" . (.message)) (responseError response))
            readIORef sent >>= (@?= False),
      testCase "auto and none keep their exact wire meaning" $
        forM_ [(ToolChoiceAuto, "auto"), (ToolChoiceNone, "none")] $ \(choice, expected) -> do
          body <- newIORef Null
          let capture call _ emit = writeIORef body (call ^. #requestBody) >> send finalTurn emit
          _ <- streamingComplete (claudeMessagesStreamWith capture) model context (options & #toolChoice .~ Just choice)
          raw <- readIORef body
          (field "tool_choice" raw >>= field "type") @?= Just (String expected),
      testCase "supporting compatibility retains required and named choice" $
        forM_ [(ToolChoiceRequired, "any"), (ToolChoiceSpecific "lookup", "tool")] $ \(choice, expected) -> do
          let m = model & #modelId .~ "supporting-generation" & #compat .~ CompatAnthropicMessages (anthropicMessagesCompatFor model & #supportsForcedToolChoice .~ True)
          (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest m context (options & #toolChoice .~ Just choice))
          (field "tool_choice" (Aeson.toJSON req) >>= field "type") @?= Just (String expected),
      testCase "unset effort is no preference and small caps never create a manual budget" $
        forM_ [Nothing, Just ThinkingMinimal, Just ThinkingLow, Just ThinkingMedium, Just ThinkingHigh, Just ThinkingXHigh, Just ThinkingMax] $ \level -> do
          let opts = options & #thinking .~ level & #maxTokens .~ Just 1
          (req, translation) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest model context opts)
          let raw = Aeson.toJSON req
          field "max_tokens" raw @?= Just (Number 1)
          translation @?= R.describeThinkingFor model opts
          case level of
            Nothing -> do
              field "thinking" raw @?= Nothing
              translation @?= noThinkingRequested
            Just _ -> do
              (field "thinking" raw >>= field "type") @?= Just (String "adaptive")
              (field "thinking" raw >>= field "budget_tokens") @?= Nothing,
      testCase "legacy serialized compat defaults to supporting forced choice" $ do
        let raw = case Aeson.toJSON defaultAnthropicMessagesCompat of Object o -> Object (KM.delete "supportsForcedToolChoice" o); v -> v
        case Aeson.fromJSON raw of
          Aeson.Success c -> (c :: AnthropicMessagesCompat).supportsForcedToolChoice @?= True
          Aeson.Error err -> assertFailure err,
      testCase "two consecutive tool rounds preserve signed empty, visible and redacted thinking" $ do
        requests <- newIORef ([] :: [Value])
        executed <- newIORef ([] :: [Text])
        let scripted call _ emit = do
              previous <- readIORef requests
              writeIORef requests (previous <> [call ^. #requestBody])
              send (case length previous of 0 -> toolTurn "" "sig-one" "toolu_1" True; 1 -> toolTurn "visible summary" "sig-two" "toolu_2" False; _ -> finalTurn) emit
        reg <- newProviderRegistryFrom [apiProvider AnthropicMessages (claudeMessagesStreamWith scripted)]
        (history, response) <- runToolLoopWith reg 4 (\tc -> do xs <- readIORef executed; writeIORef executed (xs <> [tc.id_]); pure (toolResultText "found")) model context options
        response.message.content @?= V.singleton (AssistantText (TextContent "done"))
        readIORef executed >>= (@?= ["toolu_1", "toolu_2"])
        bodies <- readIORef requests
        length bodies @?= 3
        case bodies of
          [first, second, third] -> do
            let a = messages first; b = messages second; c = messages third
            V.take (V.length a) b @?= a
            V.take (V.length b) c @?= b
            field "system" first @?= field "system" third
            field "tools" first @?= field "tools" third
            contentAt 1 b @?= V.fromList [signed "" "sig-one", redactedItem, toolItem "toolu_1"]
            contentAt 3 c @?= V.fromList [signed "visible summary" "sig-two", toolItem "toolu_2"]
            field "tool_use_id" (contentAt 2 b V.! 0) @?= Just (String "toolu_1")
            field "tool_use_id" (contentAt 4 c V.! 0) @?= Just (String "toolu_2")
            persisted <- V.mapM persistThinking (history ^. #messages)
            (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest model (history & #messages .~ persisted) options)
            messages (Aeson.toJSON req) @?= c
          _ -> assertFailure "expected three requests",
      testCase "error cleanup retains completed signed thinking for persistence" $ do
        let partial _ _ emit = send (take 4 (toolTurn "" "sig-one" "toolu_1" False)) emit >> emit (Left (providerError "interrupted"))
        response <- streamingComplete (claudeMessagesStreamWith partial) model context options
        assertBool "failed response" (responseError response /= Nothing)
        case V.toList response.message.content of
          [AssistantThinking t] -> do
            t.thinking @?= ""
            t.signature @?= Just "sig-one"
            t.replayState @?= Nothing
          _ -> assertFailure "signed state was discarded on error"
    ]

model :: Model
model = anthropic_claude_fable_5_1

options :: Options
options = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "offline-key")

context :: Context
context = systemUser "unchanged system" "look twice" & #tools .~ V.singleton (mkTool "lookup" "lookup" (object ["type" .= ("object" :: Text)]))

send :: [Value] -> (Either BaikaiError C.MessageStreamEvent -> IO ()) -> IO ()
send frames emit = forM_ frames $ \raw -> case Aeson.fromJSON raw of
  Aeson.Error err -> assertFailure err
  Aeson.Success ev -> emit (Right ev)

start :: Value
start = object ["type" .= ("message_start" :: Text), "message" .= object ["id" .= ("msg" :: Text), "type" .= ("message" :: Text), "role" .= ("assistant" :: Text), "model" .= ("claude-fable-5-1" :: Text), "content" .= ([] :: [Value]), "usage" .= object ["input_tokens" .= (5 :: Int), "output_tokens" .= (0 :: Int)]]]

block :: Int -> Value -> Value
block n b = object ["type" .= ("content_block_start" :: Text), "index" .= n, "content_block" .= b]

stopBlock :: Int -> Value
stopBlock n = object ["type" .= ("content_block_stop" :: Text), "index" .= n]

end :: Text -> [Value]
end reason = [object ["type" .= ("message_delta" :: Text), "delta" .= object ["stop_reason" .= reason], "usage" .= object ["output_tokens" .= (5 :: Int)]], object ["type" .= ("message_stop" :: Text)]]

signed :: Text -> Text -> Value
signed text sig = object ["type" .= ("thinking" :: Text), "thinking" .= text, "signature" .= sig]

redactedItem :: Value
redactedItem = object ["type" .= ("redacted_thinking" :: Text), "data" .= ("encrypted-redacted" :: Text)]

toolItem :: Text -> Value
toolItem ident = object ["type" .= ("tool_use" :: Text), "id" .= ident, "name" .= ("lookup" :: Text), "input" .= object []]

toolTurn :: Text -> Text -> Text -> Bool -> [Value]
toolTurn text sig ident redacted =
  [start, block 0 (signed "" "")]
    <> (if T.null text then [] else [object ["type" .= ("content_block_delta" :: Text), "index" .= (0 :: Int), "delta" .= object ["type" .= ("thinking_delta" :: Text), "thinking" .= text]]])
    <> [object ["type" .= ("content_block_delta" :: Text), "index" .= (0 :: Int), "delta" .= object ["type" .= ("signature_delta" :: Text), "signature" .= sig]], stopBlock 0]
    <> (if redacted then [block 1 redactedItem, stopBlock 1] else [])
    <> [block (if redacted then 2 else 1) (toolItem ident), stopBlock (if redacted then 2 else 1)]
    <> end "tool_use"

finalTurn :: [Value]
finalTurn = [start, block 0 (object ["type" .= ("text" :: Text), "text" .= ("" :: Text)]), object ["type" .= ("content_block_delta" :: Text), "index" .= (0 :: Int), "delta" .= object ["type" .= ("text_delta" :: Text), "text" .= ("done" :: Text)]], stopBlock 0] <> end "end_turn"

field :: Key -> Value -> Maybe Value
field k (Object o) = KM.lookup k o
field _ _ = Nothing

messages :: Value -> V.Vector Value
messages raw = case field "messages" raw of Just (Array xs) -> xs; _ -> V.empty

contentAt :: Int -> V.Vector Value -> V.Vector Value
contentAt n xs = case xs V.!? n >>= field "content" of Just (Array cs) -> cs; _ -> V.empty

-- Applications own the surrounding history store; ThinkingContent supplies
-- its JSON round trip. Exercise that payload without inventing a Context decoder.
persistThinking :: Message -> IO Message
persistThinking (AssistantMessage payload) = do
  blocks <- V.mapM persist (payload ^. #content)
  pure (AssistantMessage (payload & #content .~ blocks))
  where
    persist (AssistantThinking t) = AssistantThinking <$> either assertFailure pure (Aeson.eitherDecode (Aeson.encode t))
    persist block = pure block
persistThinking other = pure other
