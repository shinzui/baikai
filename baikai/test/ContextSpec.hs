module ContextSpec (tests) where

import Baikai
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.Time (UTCTime)
import Data.Vector qualified as V
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Context helpers"
    [ monoidTests,
      constructorTests,
      timestampTests,
      flattenTextTests
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
                      redacted = False
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
