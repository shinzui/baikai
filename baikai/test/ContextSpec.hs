module ContextSpec (tests) where

import Baikai
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Context helpers"
    [ replayStateTests,
      monoidTests,
      constructorTests,
      timestampTests,
      flattenTextTests,
      toolResultTests
    ]

-- | A failed call has no assistant turn worth replaying and no tool
-- calls to answer, so 'appendToolResult' appends nothing and runs
-- nothing. 'runToolLoop' has always stopped on such a response; the
-- documented direct round trip reaches here instead.
toolResultTests :: TestTree
toolResultTests =
  testGroup
    "appendToolResult"
    [ testCase "an error-shaped response leaves the context unchanged and never dispatches" $ do
        let ctx = contextOf [user "go"]
            failed =
              errorResponse
                emptyModel
                (read "2026-06-05 01:02:03 UTC" :: UTCTime)
                12
                (providerError "upstream died")
            explode _ = error "the dispatcher must not run for an error-shaped response"
        after <- appendToolResult ctx failed explode
        after @?= ctx
    ]

monoidTests :: TestTree
monoidTests =
  testGroup
    "Monoid"
    [ testCase "has left and right identity" $ do
        let ctx =
              emptyContext
                { systemPrompt = Just "sys",
                  messages = V.fromList [user "one"],
                  tools = V.singleton sampleTool
                }
        mempty <> ctx @?= ctx
        ctx <> mempty @?= ctx,
      testCase "is associative and keeps the first system prompt" $ do
        let a = systemUser "a-system" "a"
            b = addUser "b" emptyContext
            c =
              emptyContext
                { systemPrompt = Just "c-system",
                  messages = V.fromList [assistant "c"],
                  tools = V.singleton sampleTool
                }
        (a <> b) <> c @?= a <> (b <> c)
        (a <> b <> c) ^. #systemPrompt @?= Just "a-system"
        (b <> c) ^. #systemPrompt @?= Just "c-system"
    ]

constructorTests :: TestTree
constructorTests =
  testGroup
    "constructors"
    [ testCase "contextOf preserves message order" $ do
        contextOf [user "one", assistant "two"] ^. #messages
          @?= V.fromList [user "one", assistant "two"],
      testCase "systemUser creates a system prompt and one user message" $ do
        let ctx = systemUser "system" "prompt"
        ctx ^. #systemPrompt @?= Just "system"
        ctx ^. #messages @?= V.singleton (user "prompt"),
      testCase "addMessage, addUser, and addResponse append in order" $ do
        let resp =
              emptyResponse
                & #message
                  .~ AssistantPayload
                    { content = V.singleton (AssistantText (TextContent "response")),
                      usage = zeroUsage,
                      stopReason = Stop,
                      errorMessage = Nothing,
                      timestamp = Nothing
                    }
            ctx =
              emptyContext
                |> addUser "first"
                |> addMessage (assistant "second")
                |> addResponse resp
        ctx ^. #messages
          @?= V.fromList
            [ user "first",
              assistant "second",
              responseMessage resp
            ]
    ]

timestampTests :: TestTree
timestampTests =
  testGroup
    "timestamps"
    [ testCase "pure constructors do not invent timestamps" $ do
        payloadTimestamp (user "plain") @?= Nothing
        payloadTimestamp (assistant "plain") @?= Nothing
        payloadTimestamp (toolResult "call" "tool" "ok" False) @?= Nothing,
      testCase "explicit constructors preserve timestamps" $ do
        let ts = read "2026-06-05 01:02:03 UTC"
        payloadTimestamp (userAt ts "plain") @?= Just ts
        payloadTimestamp (assistantAt ts "plain") @?= Just ts
        payloadTimestamp (toolResultAt ts "call" "tool" "ok" False) @?= Just ts
    ]

flattenTextTests :: TestTree
flattenTextTests =
  testGroup
    "flattenAssistantText"
    [ testCase "concatenates only text blocks" $ do
        flattenAssistantText
          ( V.fromList
              [ AssistantText (TextContent "hello"),
                AssistantThinking
                  ThinkingContent
                    { thinking = "hidden",
                      signature = Nothing,
                      redacted = False,
                      replayState = Nothing
                    },
                AssistantToolCall emptyToolCall {name = "lookup", arguments = Aeson.object []},
                AssistantText (TextContent " world")
              ]
          )
          @?= "hello world"
    ]

sampleTool :: Tool
sampleTool =
  emptyTool
    { name = "lookup",
      description = "Lookup a value",
      parameters = Aeson.object []
    }

payloadTimestamp :: Message -> Maybe UTCTime
payloadTimestamp (UserMessage UserPayload {timestamp = ts}) = ts
payloadTimestamp (AssistantMessage AssistantPayload {timestamp = ts}) = ts
payloadTimestamp (ToolResultMessage ToolResultPayload {timestamp = ts}) = ts

(|>) :: a -> (a -> b) -> b
(|>) x f = f x

replayStateTests :: TestTree
replayStateTests =
  testGroup
    "provider-scoped reasoning replay"
    [ testCase "legacy JSON remains valid and byte-compatible" $ do
        let old = Aeson.object ["thinking" Aeson..= ("" :: Text.Text), "signature" Aeson..= Aeson.Null, "redacted" Aeson..= False]
        Aeson.fromJSON old @?= Aeson.Success emptyThinkingContent
        Aeson.toJSON emptyThinkingContent @?= old,
      testCase "empty summary and ordered encrypted items survive content persistence and context appending" $ do
        let saved = Aeson.eitherDecode (Aeson.encode thought)
        saved @?= Right thought
        let resp = emptyResponse & #message . #content .~ V.singleton (AssistantThinking thought)
            context = addResponse resp (contextOf [user "go"])
        context ^. #messages @?= V.fromList [user "go", responseMessage resp]
        flattenAssistantText (resp ^. #message . #content) @?= ""
        assertBool "Show omits encrypted content" (not ("encrypted-secret" `Text.isInfixOf` Text.pack (show resp))),
      testCase "response content commitment binds replay scope, identity, payload and order" $ do
        let digest t = commitmentDigest (Aeson.object ["content" Aeson..= V.singleton (AssistantThinking t)])
            changed r = thought & #replayState .~ Just r
        mapM_
          (\r -> assertBool "replay mutation must change commitment" (digest thought /= digest (changed r)))
          [ state & #replayApi .~ AnthropicMessages,
            state & #replayModel .~ "other-model",
            state & #replayItems .~ V.reverse items,
            state & #replayItems .~ V.singleton (Aeson.object ["id" Aeson..= ("different" :: Text.Text)])
          ]
    ]
  where
    items = V.fromList [Aeson.object ["type" Aeson..= ("reasoning" :: Text.Text), "id" Aeson..= ("rs_1" :: Text.Text), "summary" Aeson..= ([] :: [Aeson.Value]), "encrypted_content" Aeson..= ("encrypted-secret" :: Text.Text)], Aeson.object ["id" Aeson..= ("rs_2" :: Text.Text)]]
    state = ThinkingReplay OpenAIResponses "gpt-6-astra" items
    thought = emptyThinkingContent & #replayState .~ Just state
