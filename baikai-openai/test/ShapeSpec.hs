{-# LANGUAGE LambdaCase #-}

module ShapeSpec (tests) where

import Baikai
import Baikai.Content qualified as Content
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.OpenAI.Api
  ( RawChunk (..),
    RawToolDelta (..),
    closeOpenStream,
    emptyAssembler,
    mapRequest,
    translate,
  )
import Baikai.Provider.OpenAI.Shape (streamRequestBody)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ShapeSpec"
    [ deepseekShapeTest,
      openRouterCacheControlTest,
      strictModeGateTest,
      usageStreamingGateTest,
      zeroCapOmissionTest,
      indexlessToolDeltaTest
    ]

deepseekShapeTest :: TestTree
deepseekShapeTest =
  testCase "DeepSeek request body uses max_tokens and reasoning shape" $ do
    value <-
      shapedBody
        Models.deepseek_deepseek_chat
        (emptyOptions & #thinking .~ Just ThinkingHigh)
        emptyContext
    lookupTop "max_completion_tokens" value @?= Nothing
    lookupTop "max_tokens" value @?= Just (Number 8192)
    lookupTop "thinking" value
      @?= Just (Aeson.object ["type" .= ("enabled" :: Text.Text)])
    lookupTop "reasoning_effort" value @?= Just (String "high")

openRouterCacheControlTest :: TestTree
openRouterCacheControlTest =
  testCase "OpenRouter cache marker lands on the system content part with ttl" $ do
    let ctx =
          emptyContext
            & #systemPrompt .~ Just "cache this prefix"
            & #messages .~ Vector.singleton (user "answer")
        opts = emptyOptions & #cacheRetention .~ Just CacheRetentionLong
    value <- shapedBody Models.openrouter_openai_gpt_4o_mini opts ctx
    systemCacheControl value
      @?= Just
        ( Aeson.object
            [ "type" .= ("ephemeral" :: Text.Text),
              "ttl" .= ("1h" :: Text.Text)
            ]
        )

strictModeGateTest :: TestTree
strictModeGateTest =
  testCase "supportsStrictMode gates response_format json_schema strict" $ do
    let schema = Aeson.object ["type" .= ("object" :: Text.Text)]
        opts =
          emptyOptions
            & #responseFormat
              .~ Just (JsonSchema {name = "shape", schema = schema, strict = True})
    value <- shapedBody Models.deepseek_deepseek_chat opts emptyContext
    lookupPath ["response_format", "json_schema", "strict"] value
      @?= Nothing

usageStreamingGateTest :: TestTree
usageStreamingGateTest =
  testCase "supportsUsageInStreaming gates stream_options" $ do
    let compat = defaultOpenAICompletionsCompat {supportsUsageInStreaming = False}
        model =
          Models.openai_gpt_4o_mini
            & #compat .~ CompatOpenAICompletions compat
    value <- shapedBody model emptyOptions emptyContext
    lookupTop "stream" value @?= Just (Bool True)
    lookupTop "stream_options" value @?= Nothing

zeroCapOmissionTest :: TestTree
zeroCapOmissionTest =
  testCase "unknown zero maxOutputTokens omits max_completion_tokens" $ do
    let model =
          emptyModel
            & #modelId .~ "custom"
            & #api .~ OpenAIChatCompletions
            & #provider .~ "custom"
            & #maxOutputTokens .~ 0
    req <- either (assertFailure . Text.unpack) pure (mapRequest model emptyContext emptyOptions)
    lookupTop "max_completion_tokens" (Aeson.toJSON req) @?= Nothing

indexlessToolDeltaTest :: TestTree
indexlessToolDeltaTest =
  testCase "id-bearing index-less tool deltas remain separate" $ do
    let chunks =
          [ emptyChunk
              { toolDeltas =
                  [ RawToolDelta
                      { index = Nothing,
                        id_ = Just "call_a",
                        name = Just "first",
                        args = Just "{\"a\":"
                      },
                    RawToolDelta
                      { index = Nothing,
                        id_ = Just "call_b",
                        name = Just "second",
                        args = Just "{\"b\":"
                      }
                  ]
              },
            emptyChunk
              { toolDeltas =
                  [ RawToolDelta
                      { index = Nothing,
                        id_ = Just "call_a",
                        name = Nothing,
                        args = Just "1}"
                      },
                    RawToolDelta
                      { index = Nothing,
                        id_ = Just "call_b",
                        name = Nothing,
                        args = Just "2}"
                      }
                  ]
              },
            emptyChunk {finishReason = Just "tool_calls"}
          ]
        events = runChunks chunks
        toolCalls =
          [ toolCall
          | ToolCallEnd ToolCallEndPayload {toolCall = toolCall} <- events
          ]
    fmap Content.id_ toolCalls @?= ["call_a", "call_b"]
    fmap Content.name toolCalls @?= ["first", "second"]
    fmap Content.arguments toolCalls
      @?= [ Aeson.object ["a" .= (1 :: Int)],
            Aeson.object ["b" .= (2 :: Int)]
          ]

shapedBody :: Model -> Options -> Context -> IO Value
shapedBody model opts ctx = do
  req <- either (assertFailure . Text.unpack) pure (mapRequest model ctx opts)
  pure (streamRequestBody (openaiCompletionsCompatFor model) opts req)

lookupTop :: Text.Text -> Value -> Maybe Value
lookupTop field = lookupPath [field]

lookupPath :: [Text.Text] -> Value -> Maybe Value
lookupPath [] value = Just value
lookupPath (field : rest) (Object obj) =
  KeyMap.lookup (AesonKey.fromText field) obj >>= lookupPath rest
lookupPath _ _ = Nothing

systemCacheControl :: Value -> Maybe Value
systemCacheControl value = do
  Array messages <- lookupTop "messages" value
  systemMessage <-
    firstMay
      [ msg
      | msg@(Object _) <- Vector.toList messages,
        lookupPath ["role"] msg == Just (String "system")
      ]
  Array content <- lookupPath ["content"] systemMessage
  contentPart <- lastMay (Vector.toList content)
  lookupPath ["cache_control"] contentPart

firstMay :: [a] -> Maybe a
firstMay [] = Nothing
firstMay (x : _) = Just x

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

emptyChunk :: RawChunk
emptyChunk =
  RawChunk
    { contentDelta = Nothing,
      reasoningDelta = Nothing,
      finishReason = Nothing,
      toolDeltas = [],
      usage = Nothing
    }

runChunks :: [RawChunk] -> [AssistantMessageEvent]
runChunks chunks =
  let (events, ass) =
        foldl
          ( \(acc, st) chunk ->
              let (newEvents, st') = translate (Right chunk) st testTime
               in (acc <> newEvents, st')
          )
          ([], emptyAssembler Models.openai_gpt_4o_mini testTime)
          chunks
      (terminalEvents, _) = closeOpenStream testTime Nothing ass
   in events <> terminalEvents

testTime :: UTCTime
testTime = read "2026-07-03 12:00:00 UTC"
