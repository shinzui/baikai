{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}

module FableContractsSpec (tests) where

import Baikai hiding (messages, model)
import Baikai.Models.Generated (anthropic_claude_fable_5_1, anthropic_claude_haiku_4_5, anthropic_claude_haiku_5_5, anthropic_claude_opus_5_5, anthropic_claude_sonnet_4_6, anthropic_claude_sonnet_5_5)
import Baikai.Provider.Claude.Api (claudeMessagesProvider, claudeMessagesStream)
import Baikai.Provider.Claude.Internal.Request qualified as R
import Baikai.Provider.Claude.Internal.Stream (claudeMessagesStreamWith)
import Claude.Streaming qualified as C
import Contract (assertErrorContract)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (testWithApplication)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Fable contracts"
    [ summaryTests,
      prefillTests,
      legacySamplingVersion,
      candidateCompleteAndStream,
      testCase "Opus 5.5 and Sonnet 5.5 reject forced tools and replay signed empty thinking" $
        forM_ [anthropic_claude_opus_5_5, anthropic_claude_sonnet_5_5] $ \opus -> do
          opus.api @?= AnthropicMessages
          forM_ [ToolChoiceRequired, ToolChoiceSpecific "lookup"] $ \choice ->
            case R.mapRequest opus context (options & #toolChoice .~ Just choice) of
              Left _ -> pure ()
              Right _ -> assertFailure (T.unpack opus.modelId <> " accepted forced tool choice")
          forM_ [(ToolChoiceAuto, "auto"), (ToolChoiceNone, "none")] $ \(choice, expected) -> do
            body <- newIORef Null
            let capture call _ emit = writeIORef body (call ^. #requestBody) >> send finalTurn emit
            _ <- streamingComplete (claudeMessagesStreamWith capture) opus context (options & #toolChoice .~ Just choice)
            raw <- readIORef body
            (field "tool_choice" raw >>= field "type") @?= Just (String expected)
          let response =
                emptyResponse
                  & #message . #content .~ V.fromList [AssistantThinking (emptyThinkingContent & #signature .~ Just "sig-one"), AssistantToolCall (ToolCall "toolu_1" "lookup" (object []))]
                  & #message . #stopReason .~ ToolUse
          next <- appendToolResult context response (\_ -> pure (toolResultText "found"))
          (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest opus next options)
          let raw = Aeson.toJSON req
              replayed = messages raw
          (firstReq, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest opus context options)
          field "system" raw @?= field "system" (Aeson.toJSON firstReq)
          field "tools" raw @?= field "tools" (Aeson.toJSON firstReq)
          contentAt 1 replayed @?= V.fromList [signed "" "sig-one", toolItem "toolu_1"]
          field "tool_use_id" (contentAt 2 replayed V.! 0) @?= Just (String "toolu_1"),
      testCase "Haiku 5.5 forwards a forced tool choice with adaptive thinking" $ do
        (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest anthropic_claude_haiku_5_5 haikuContext haikuForcedOptions)
        Aeson.toJSON req @?= haikuForcedBody,
      testCase "Haiku 5.5 drops temperature and records why" $ do
        (req, translation) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest anthropic_claude_haiku_5_5 context (options & #temperature .~ Just 0.2))
        field "temperature" (Aeson.toJSON req) @?= Nothing
        translation ^. #adjustments @?= [SamplingDroppedUnsupportedModel ["temperature"]],
      testCase "forced choices fail before the driver for complete and stream, including renamed models" $
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
      testCase "candidate HTTP two consecutive tool rounds preserve signed empty, visible and redacted thinking" $ do
        requests <- newIORef ([] :: [Value])
        executed <- newIORef ([] :: [Text])
        let respond request reply = do
              Wai.pathInfo request @?= ["v1", "messages"]
              lookup "x-api-key" (Wai.requestHeaders request) @?= Just "fable-contract-key"
              lookup "anthropic-version" (Wai.requestHeaders request) @?= Just "2023-06-01"
              body <- Wai.strictRequestBody request >>= either fail pure . Aeson.eitherDecode
              num <- atomicModifyIORef' requests (\previous -> (previous <> [body], length previous))
              let frames = case num of 0 -> toolTurn "" "sig-one" "toolu_1" True; 1 -> toolTurn "visible summary" "sig-two" "toolu_2" False; _ -> finalTurn
              reply (Wai.responseLBS status200 [("Content-Type", "text/event-stream"), ("request-id", "req_trial_tools")] (foldMap (\frame -> "data: " <> Aeson.encode frame <> "\n\n") frames))
        (history, response) <- testWithApplication (pure respond) $ \port -> do
          let liveModel = model & #baseUrl .~ ("http://127.0.0.1:" <> T.pack (show port))
              liveOptions = summaryOptions & #apiKey .~ Just (ApiKeyLiteral "fable-contract-key")
          reg <- newProviderRegistryFrom [claudeMessagesProvider]
          runToolLoopWith reg 4 (\tc -> do xs <- readIORef executed; writeIORef executed (xs <> [tc.id_]); pure (toolResultText "found")) liveModel context liveOptions
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
            forM_ bodies $ \body -> (field "thinking" body >>= field "display") @?= Just (String "summarized")
            contentAt 1 b @?= V.fromList [signed "" "sig-one", redactedItem, toolItem "toolu_1"]
            contentAt 3 c @?= V.fromList [signed "visible summary" "sig-two", toolItem "toolu_2"]
            field "tool_use_id" (contentAt 2 b V.! 0) @?= Just (String "toolu_1")
            field "tool_use_id" (contentAt 4 c V.! 0) @?= Just (String "toolu_2")
            persisted <- V.mapM persistThinking (history ^. #messages)
            (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest model (history & #messages .~ persisted) summaryOptions)
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

prefillTests :: TestTree
prefillTests =
  testGroup
    "assistant prefills"
    [ testCase "restricted tails fail before credentials or the driver via registered stream and completion" $ do
        sent <- newIORef (0 :: Int)
        let never _ _ _ = atomicModifyIORef' sent (\n -> (n + 1, ()))
            produce = claudeMessagesStreamWith never
            opts = options & #apiKey .~ Just (ApiKeyEnvChain [])
            renamed = model & #modelId .~ "renamed-generation"
        registry <- newProviderRegistryFrom [claudeMessagesProvider & #stream .~ produce & #complete .~ streamingComplete produce]
        let restricted = [(model, textTail), (renamed, textTail), (model, addMessage emptyAssistant textTail), (model, toolTail), (model, signedTail)]
            cases = [(m, ctx, opts) | (m, ctx) <- restricted] <> [(anthropic_claude_haiku_4_5, textTail, opts & #thinking .~ Just ThinkingLow)]
        forM_ cases $ \(selected, ctx, configured) -> do
          events <- Stream.toList (streamRequestWith registry selected ctx configured)
          assertErrorContract events
          streamed <- streamingComplete (\_ _ _ -> Stream.fromList events) selected ctx configured
          completed <- completeRequestWith registry selected ctx configured
          forM_ [streamed, completed] $ \response -> do
            fmap (.category) (responseError response) @?= Just InvalidRequest
            assertBool "names the prefill and corrections" $
              maybe False (\err -> all (\hint -> hint `T.isInfixOf` err.message) ["assistant prefill", "user turn", "system prompt", "matching tool result"]) (responseError response)
        readIORef sent >>= (@?= 0),
      testCase "only the final mapped role matters" $ do
        afterTool <- appendToolResult context toolResponse (\_ -> pure (toolResultText "found"))
        forM_ [(addMessage emptyAssistant context, ["user"]), (addUser "Continue" textTail, ["user", "assistant", "user"]), (afterTool, ["user", "assistant", "user"])] $ \(ctx, expected) -> do
          raw <- mapped model ctx options
          V.toList (V.map (field "role") (messages raw)) @?= map (Just . String) expected,
      testCase "4.5 prefills are allowed with omitted, disabled or dropped thinking" $ do
        let haiku = anthropic_claude_haiku_4_5
            check selected opts thinking = do
              raw <- mapped selected textTail opts
              (field "thinking" raw >>= field "type") @?= thinking
              (messages raw V.!? 1 >>= field "role") @?= Just (String "assistant")
        check haiku options Nothing
        check haiku (options & #thinking .~ Just ThinkingNone) (Just (String "disabled"))
        check (haiku & #maxOutputTokens .~ 1024) (options & #maxTokens .~ Just 1024 & #thinking .~ Just ThinkingLow) Nothing,
      testCase "legacy serialized compat and auto detection preserve prefill pass-through" $ do
        let raw = case Aeson.toJSON defaultAnthropicMessagesCompat of
              Object o -> Object (KM.delete "assistantPrefillPolicy" o)
              value -> value
        case Aeson.fromJSON raw of
          Aeson.Error err -> assertFailure err
          Aeson.Success compat -> do
            compat.assistantPrefillPolicy @?= Nothing
            forM_ [CompatAnthropicMessages compat, CompatNone] $ \compatSetting -> do
              body <- mapped (model & #compat .~ compatSetting) textTail options
              (messages body V.!? 1 >>= field "role") @?= Just (String "assistant")
    ]
  where
    emptyAssistant = assistant ""
    textTail = addMessage (assistant "The answer is") context
    signedTail = addMessage (AssistantMessage (emptyResponse.message & #content .~ V.singleton signedBlock)) context
    signedBlock = AssistantThinking (emptyThinkingContent & #signature .~ Just "sig-one")
    toolResponse =
      emptyResponse
        & #message . #content .~ V.singleton (AssistantToolCall (ToolCall "toolu_1" "lookup" (object [])))
        & #message . #stopReason .~ ToolUse
    toolTail = addMessage (AssistantMessage toolResponse.message) context
    mapped selected ctx opts = either (\err -> assertFailure (T.unpack err) >> fail "mapRequest") (pure . Aeson.toJSON . fst) (R.mapRequest selected ctx opts)

legacySamplingVersion :: TestTree
legacySamplingVersion = testCase "the explicit current API version rejects sampling before dispatch" $ do
  captured <- newIORef ([] :: [(Maybe ByteString, Value)])
  let app request respond = do
        body <- Wai.strictRequestBody request >>= either fail pure . Aeson.eitherDecode
        let version = lookup "anthropic-version" (Wai.requestHeaders request)
        atomicModifyIORef' captured (\prior -> (prior <> [(version, body)], ()))
        respond (Wai.responseLBS status200 [("Content-Type", "text/event-stream")] (foldMap (\frame -> "data: " <> Aeson.encode frame <> "\n\n") finalTurn))
  testWithApplication (pure app) $ \port -> do
    let selected = anthropic_claude_sonnet_4_6 & #baseUrl .~ ("http://127.0.0.1:" <> T.pack (show port))
        configured = options & #temperature .~ Just 0.2
        current = configured & #headers .~ Map.singleton "anthropic-version" "2026-10-21"
        regularContext = systemUser "Policy" "Hello"
    registry <- newProviderRegistryFrom [claudeMessagesProvider]
    legacy <- completeRequestWith registry selected regularContext configured
    responseError legacy @?= Nothing
    rejected <- completeRequestWith registry selected regularContext current
    fmap (.category) (responseError rejected) @?= Just InvalidRequest
    assertBool "migration error names sampling" (maybe False (T.isInfixOf "sampling" . (.message)) (responseError rejected))
    readIORef captured >>= \case
      [(Just "2023-06-01", body)] -> field "temperature" body @?= Just (Number 0.2)
      _ -> assertFailure "only the legacy call should dispatch"

candidateCompleteAndStream :: TestTree
candidateCompleteAndStream = testCase "candidate HTTP complete and stream agree on the same transcript" $ do
  requests <- newIORef ([] :: [Value])
  let app req respond = do
        body <- Wai.strictRequestBody req >>= either fail pure . Aeson.eitherDecode
        atomicModifyIORef' requests (\previous -> (previous <> [body], ()))
        respond
          ( Wai.responseLBS
              status200
              [("Content-Type", "text/event-stream"), ("request-id", "req_compare")]
              (foldMap (\frame -> "data: " <> Aeson.encode frame <> "\n\n") finalTurn)
          )
  testWithApplication (pure app) $ \port -> do
    registry <- newProviderRegistryFrom [claudeMessagesProvider]
    let selected = model & #baseUrl .~ ("http://127.0.0.1:" <> T.pack (show port))
        configured = options & #apiKey .~ Just (ApiKeyLiteral "candidate-comparison-key")
    complete <- completeRequestWith registry selected context configured
    events <- Stream.toList (claudeMessagesStream selected context configured)
    streamed <- streamingComplete (\_ _ _ -> Stream.fromList events) selected context configured
    let expected = V.singleton (AssistantText (TextContent "done"))
    map (\reply -> reply ^. #message . #content) [complete, streamed] @?= [expected, expected]
    map responseError [complete, streamed] @?= [Nothing, Nothing]
  readIORef requests >>= \case
    [complete, streamed] -> complete @?= streamed
    received -> assertFailure ("expected two dispatches, got " <> show (length received))

model :: Model
model = anthropic_claude_fable_5_1

-- | The one request plan 91 sends live to settle whether Haiku 5.5 accepts
-- a forced tool choice alongside baikai's explicit adaptive thinking. The
-- same JSON is saved as docs/validation/plan-91/forced-tool-choice-request.json.
haikuContext :: Context
haikuContext = systemUser "Answer by calling the lookup tool." "What is the capital of France?" & #tools .~ V.singleton (mkTool "lookup" "Look up a fact." (object ["type" .= ("object" :: Text), "properties" .= object ["query" .= object ["type" .= ("string" :: Text)]], "required" .= ["query" :: Text]]))

haikuForcedOptions :: Options
haikuForcedOptions = options & #toolChoice .~ Just ToolChoiceRequired & #thinking .~ Just ThinkingLow & #maxTokens .~ Just 1024

haikuForcedBody :: Value
haikuForcedBody =
  object
    [ "model" .= ("claude-haiku-5-5" :: Text),
      "max_tokens" .= (1024 :: Int),
      "system" .= ("Answer by calling the lookup tool." :: Text),
      "messages" .= [object ["role" .= ("user" :: Text), "content" .= [object ["type" .= ("text" :: Text), "text" .= ("What is the capital of France?" :: Text)]]]],
      "tools" .= [object ["name" .= ("lookup" :: Text), "description" .= ("Look up a fact." :: Text), "input_schema" .= object ["type" .= ("object" :: Text), "properties" .= object ["query" .= object ["type" .= ("string" :: Text)]], "required" .= ["query" :: Text]]]],
      "tool_choice" .= object ["type" .= ("any" :: Text)],
      "thinking" .= object ["type" .= ("adaptive" :: Text), "display" .= ("summarized" :: Text)],
      "output_config" .= object ["effort" .= ("low" :: Text)]
    ]

options :: Options
options = emptyOptions & #apiKey .~ Just (ApiKeyLiteral "offline-key")

context :: Context
context = systemUser "unchanged system" "look twice" & #tools .~ V.singleton (mkTool "lookup" "lookup" (object ["type" .= ("object" :: Text)]))

send :: [Value] -> (Either BaikaiError C.StreamPayload -> IO ()) -> IO ()
send frames emit = forM_ frames $ \raw -> case C.decodeStreamEvent raw of
  Left err -> assertFailure err
  Right (Left _) -> assertFailure "expected a successful stream event"
  Right (Right ev) -> emit (Right (C.eventPayload ev))

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

summaryOptions :: Options
summaryOptions = options & #thinking .~ Just ThinkingLow & #evidence .~ Just (evidenceRequest "summary-replay")

summaryTests :: TestTree
summaryTests =
  testGroup
    "summary visibility"
    [ testCase "summarized reasoning assembles into non-empty thinking content" $ do
        response <- completeFrames (toolTurn "visible summary" "signed-summary" "toolu_summary" False) summaryOptions
        let blocks = [t | AssistantThinking t <- V.toList (response ^. #message . #content)]
        map (^. #thinking) blocks @?= ["visible summary"]
        map (^. #signature) blocks @?= [Just "signed-summary"]
        ev <- evidenceOf response
        ev ^. #thinking . #displayText @?= Just "summarized"
        ev ^. #thinking . #adjustments @?= []
        ev ^. #observedThinking @?= Unobserved,
      testCase "reasoning requested but returned empty is recorded in the evidence" $ do
        forM_ [[signed "" "empty-signature"], [redactedItem], [signed "" "empty-signature", redactedItem]] $ \blocks -> do
          response <- completeFrames (blocksTurn blocks) summaryOptions
          ev <- evidenceOf response
          ev ^. #thinking . #adjustments @?= [ThinkingSummaryUnavailable]
          ev ^. #thinking . #displayText @?= Just "summarized"
          ev ^. #observedThinking @?= Unobserved
          ev ^. #status @?= CallSucceeded
          responseError response @?= Nothing
          weakensThinking ThinkingSummaryUnavailable @?= False
          let actual = [t | AssistantThinking t <- V.toList (response ^. #message . #content)]
          length actual @?= length blocks
          -- Encrypted payloads and signed empty blocks remain usable history.
          let history = addUser "Continue" (contextOf [AssistantMessage (response ^. #message)])
          (req, _) <- either (\e -> assertFailure (T.unpack e) >> fail "map") pure (R.mapRequest model history summaryOptions)
          contentAt 0 (messages (Aeson.toJSON req)) @?= V.fromList blocks,
      testCase "one visible block among empty and redacted blocks is a readable summary" $ do
        response <- completeFrames (blocksTurn [signed "" "empty", redactedItem, signed "visible" "visible-signature"]) summaryOptions
        ev <- evidenceOf response
        ev ^. #thinking . #adjustments @?= [],
      testCase "no thinking block and no thinking preference do not invent missing summaries" $ do
        noBlocks <- completeFrames finalTurn summaryOptions
        ev <- evidenceOf noBlocks
        ev ^. #thinking . #adjustments @?= []
        noPreference <- completeFrames (blocksTurn [signed "" "sig"]) (options & #evidence .~ Just (evidenceRequest "no-thinking"))
        ev2 <- evidenceOf noPreference
        ev2 ^. #thinking @?= noThinkingRequested,
      testCase "failed streams do not label partial thinking as a missing completed summary" $ do
        let driver _ _ emit = send [start, block 0 (signed "" "sig"), stopBlock 0] emit >> emit (Left (providerError "interrupted"))
        response <- streamingComplete (claudeMessagesStreamWith driver) model emptyContext summaryOptions
        ev <- evidenceOf response
        ev ^. #status @?= CallFailed
        ev ^. #thinking . #adjustments @?= []
        assertBool "failure retained" (responseError response /= Nothing)
    ]
  where
    completeFrames frames opts = streamingComplete (claudeMessagesStreamWith (\_ _ emit -> send frames emit)) model emptyContext opts
    blocksTurn blocks = [start] <> concat [blockFrames i b | (i, b) <- zip [0 ..] blocks] <> end "end_turn"
    blockFrames i b = case (field "type" b, field "thinking" b, field "signature" b) of
      (Just (String "thinking"), Just (String text), Just (String sig)) ->
        [ block i (signed "" ""),
          object ["type" .= ("content_block_delta" :: Text), "index" .= i, "delta" .= object ["type" .= ("thinking_delta" :: Text), "thinking" .= text]],
          object ["type" .= ("content_block_delta" :: Text), "index" .= i, "delta" .= object ["type" .= ("signature_delta" :: Text), "signature" .= sig]],
          stopBlock i
        ]
      _ -> [block i b, stopBlock i]
    evidenceOf response = maybe (assertFailure "missing evidence" >> fail "evidence") pure (response ^. #evidence)
