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
    translate,
  )
import Baikai.Provider.OpenAI.Internal.Request (mapRequest)
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
      nativeHigherEffortTests,
      compatibleHigherEffortClampTest,
      translationTableTests,
      nativeVersusCompatibleTests,
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

nativeHigherEffortTests :: TestTree
nativeHigherEffortTests =
  testGroup
    "native OpenAI higher reasoning effort"
    [ testCase name $ do
        value <-
          shapedBody
            Models.openai_gpt_5_6_terra
            (emptyOptions & #thinking .~ Just level)
            emptyContext
        lookupTop "reasoning_effort" value @?= Just (String expected)
    | (name, level, expected) <-
        [ ("xhigh survives SDK staging", ThinkingXHigh, "xhigh"),
          ("max survives SDK staging", ThinkingMax, "max")
        ]
    ]

compatibleHigherEffortClampTest :: TestTree
compatibleHigherEffortClampTest =
  testCase "OpenAI-compatible higher reasoning effort clamps to high" $ do
    value <-
      shapedBody
        Models.deepseek_deepseek_chat
        (emptyOptions & #thinking .~ Just ThinkingMax)
        emptyContext
    lookupTop "reasoning_effort" value @?= Just (String "high")

-- ============================================================
-- The forty-two-row translation table
-- ============================================================

-- | Every canonical level against every wire shape: what goes on the
-- wire, and what the evidence record says went on it.
--
-- Both halves are asserted on every row. Checking only the description
-- would let it drift away from the request it claims to describe, which
-- is the one failure this whole record exists to prevent.
translationTableTests :: TestTree
translationTableTests =
  testGroup
    "thinking translation across all seven wire shapes"
    [ testCase (shapeName fmt <> " at " <> Text.unpack (renderThinkingLevel lvl)) $ do
        (body, translation) <-
          shapedCall (hostWith fmt) (emptyOptions & #thinking .~ Just lvl) emptyContext
        translation @?= expected
        mapM_ (\(k, v) -> lookupTop k body @?= Just v) present
        mapM_ (\k -> lookupTop k body @?= Nothing) absent
    | (lvl, nativeWord, compatWord, clamps) <- effortRows,
      fmt <- everyThinkingFormat,
      let (expected, present, absent) = expectationFor fmt lvl nativeWord compatWord clamps
    ]

-- | The seven shapes, listed so a new constructor added to
-- 'ThinkingFormat' shows up here as a missing case in 'expectationFor'
-- and 'shapeName' rather than as a silently untested shape.
everyThinkingFormat :: [ThinkingFormat]
everyThinkingFormat =
  [ ThinkingFormatOpenAI,
    ThinkingFormatOpenRouter,
    ThinkingFormatDeepseek,
    ThinkingFormatTogether,
    ThinkingFormatZai,
    ThinkingFormatQwen,
    ThinkingFormatNone
  ]

-- | The exact effort word each of the two vocabularies sends for each
-- canonical level, and the adjustment a clamping vocabulary records.
--
-- Every value is written out rather than computed from the code under
-- test, so this is an independent statement of the intended behaviour
-- and not a second copy of the implementation. The native column never
-- clamps: it forwards the canonical name, which is exactly what an
-- empty adjustment list means.
effortRows :: [(ThinkingLevel, Text.Text, Text.Text, [ThinkingAdjustment])]
effortRows =
  [ (ThinkingMinimal, "minimal", "low", [EffortClamped ThinkingMinimal "low"]),
    (ThinkingLow, "low", "low", []),
    (ThinkingMedium, "medium", "medium", []),
    (ThinkingHigh, "high", "high", []),
    (ThinkingXHigh, "xhigh", "high", [EffortClamped ThinkingXHigh "high"]),
    (ThinkingMax, "max", "high", [EffortClamped ThinkingMax "high"])
  ]

-- | The translation, the body keys that must be present, and the body
-- keys that must be absent, for one shape at one level.
expectationFor ::
  ThinkingFormat ->
  ThinkingLevel ->
  -- | The word the native vocabulary sends.
  Text.Text ->
  -- | The word the compatible vocabulary sends.
  Text.Text ->
  -- | The adjustment the compatible vocabulary records, if any.
  [ThinkingAdjustment] ->
  (ThinkingTranslation, [(Text.Text, Value)], [Text.Text])
expectationFor fmt lvl nativeWord compatWord clamps = case fmt of
  ThinkingFormatOpenAI ->
    ( adaptiveTranslation lvl nativeWord "reasoning_effort" [],
      [("reasoning_effort", String nativeWord)],
      ["reasoning", "thinking", "enable_thinking"]
    )
  ThinkingFormatOpenRouter ->
    ( adaptiveTranslation lvl compatWord "reasoning" clamps,
      [("reasoning", Aeson.object ["effort" .= compatWord])],
      ["reasoning_effort", "thinking", "enable_thinking"]
    )
  ThinkingFormatDeepseek ->
    ( adaptiveTranslation lvl compatWord "reasoning_effort" clamps,
      [ ("reasoning_effort", String compatWord),
        ("thinking", Aeson.object ["type" .= ("enabled" :: Text.Text)])
      ],
      ["reasoning", "enable_thinking"]
    )
  ThinkingFormatTogether ->
    ( adaptiveTranslation lvl compatWord "reasoning_effort" clamps,
      [ ("reasoning_effort", String compatWord),
        ("reasoning", Aeson.object ["enabled" .= True])
      ],
      ["thinking", "enable_thinking"]
    )
  ThinkingFormatZai -> collapsed
  ThinkingFormatQwen -> collapsed
  ThinkingFormatNone ->
    ( ThinkingTranslation
        { requested = Just lvl,
          mode = ThinkingModeUnsupported,
          effortText = Nothing,
          budgetTokens = Nothing,
          wireField = Nothing,
          adjustments = [ThinkingDroppedUnsupportedHost lvl]
        },
      [],
      ["reasoning_effort", "reasoning", "thinking", "enable_thinking"]
    )
  where
    -- Z.ai and Qwen carry no depth at all, so every level collapses --
    -- including the ones a richer host would have accepted verbatim.
    collapsed =
      ( ThinkingTranslation
          { requested = Just lvl,
            mode = ThinkingModeToggle,
            effortText = Nothing,
            budgetTokens = Nothing,
            wireField = Just "enable_thinking",
            adjustments = [EffortCollapsedToToggle lvl]
          },
        [("enable_thinking", Bool True)],
        ["reasoning_effort", "reasoning", "thinking"]
      )

adaptiveTranslation ::
  ThinkingLevel -> Text.Text -> Text.Text -> [ThinkingAdjustment] -> ThinkingTranslation
adaptiveTranslation lvl wire field adjs =
  ThinkingTranslation
    { requested = Just lvl,
      mode = ThinkingModeAdaptive,
      effortText = Just wire,
      budgetTokens = Nothing,
      wireField = Just field,
      adjustments = adjs
    }

shapeName :: ThinkingFormat -> String
shapeName = \case
  ThinkingFormatOpenAI -> "openai-native"
  ThinkingFormatOpenRouter -> "openrouter"
  ThinkingFormatDeepseek -> "deepseek"
  ThinkingFormatTogether -> "together"
  ThinkingFormatZai -> "zai"
  ThinkingFormatQwen -> "qwen"
  ThinkingFormatNone -> "no-reasoning-controls"

-- | A reasoning-capable model pinned to one wire shape, so the table
-- exercises a shape rather than whichever host a catalog entry happens
-- to point at.
hostWith :: ThinkingFormat -> Model
hostWith fmt =
  Models.openai_gpt_5_6_terra
    & #compat
      .~ CompatOpenAICompletions
        defaultOpenAICompletionsCompat {thinkingFormat = fmt}

-- | The same request against a native host and against a clamping one,
-- written side by side because the contrast is the design.
--
-- The native rows are the ones that look wrong at a glance and are not:
-- `xhigh` and `max` reach the wire intact and the translation records no
-- adjustment, because nothing was adjusted. Clamping them here would
-- silently weaken every high-effort request against a current OpenAI
-- model.
nativeVersusCompatibleTests :: TestTree
nativeVersusCompatibleTests =
  testGroup
    "the native vocabulary forwards what the compatible one clamps"
    [ testCase "native xhigh reaches the wire and adjusts nothing" $
        assertEffort Models.openai_gpt_5_6_terra ThinkingXHigh "xhigh" [],
      testCase "deepseek xhigh clamps to high and records it" $
        assertEffort
          Models.deepseek_deepseek_chat
          ThinkingXHigh
          "high"
          [EffortClamped ThinkingXHigh "high"],
      testCase "native max reaches the wire and adjusts nothing" $
        assertEffort Models.openai_gpt_5_6_terra ThinkingMax "max" [],
      testCase "deepseek max clamps to high and records it" $
        assertEffort
          Models.deepseek_deepseek_chat
          ThinkingMax
          "high"
          [EffortClamped ThinkingMax "high"]
    ]
  where
    assertEffort model lvl wire adjs = do
      (body, translation) <-
        shapedCall model (emptyOptions & #thinking .~ Just lvl) emptyContext
      lookupTop "reasoning_effort" body @?= Just (String wire)
      effortText translation @?= Just wire
      adjustments translation @?= adjs

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
shapedBody model opts ctx = fst <$> shapedCall model opts ctx

-- | The shaped request body together with the description of what the
-- caller's reasoning-effort preference became inside it.
shapedCall :: Model -> Options -> Context -> IO (Value, ThinkingTranslation)
shapedCall model opts ctx = do
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
