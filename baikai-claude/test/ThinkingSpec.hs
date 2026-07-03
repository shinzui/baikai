{-# LANGUAGE LambdaCase #-}

module ThinkingSpec (tests) where

import Baikai
import Baikai.Models.Generated
import Baikai.Provider.Claude.Api (Assembler, emptyAssembler, mapRequest, translate)
import Claude.V1.Messages qualified as Messages
import Control.Lens ((&), (.~), (^.))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Generics.Labels ()
import Data.IntMap.Strict qualified as IntMap
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ThinkingSpec"
    [ testGroup "mapRequest max_tokens" (neverExceedsCapTests <> styleTests),
      explicitMaxTokensTest,
      handRolledUnclampedTest,
      tooSmallCapDropsThinkingTest,
      mergedOutputConfigTest,
      explicitCompatOverridesDefaultTest,
      streamFidelityTests
    ]

anthropicModels :: [(String, Model, AnthropicThinkingStyle)]
anthropicModels =
  [ ("claude-fable-5", anthropic_claude_fable_5, AnthropicThinkingAdaptive),
    ("claude-haiku-4-5", anthropic_claude_haiku_4_5, AnthropicThinkingBudget),
    ("claude-opus-4-5", anthropic_claude_opus_4_5, AnthropicThinkingBudget),
    ("claude-opus-4-6", anthropic_claude_opus_4_6, AnthropicThinkingAdaptive),
    ("claude-opus-4-7", anthropic_claude_opus_4_7, AnthropicThinkingAdaptive),
    ("claude-opus-4-8", anthropic_claude_opus_4_8, AnthropicThinkingAdaptive),
    ("claude-sonnet-4-5", anthropic_claude_sonnet_4_5, AnthropicThinkingBudget),
    ("claude-sonnet-4-6", anthropic_claude_sonnet_4_6, AnthropicThinkingBudget)
  ]

thinkingLevels :: [(String, ThinkingLevel)]
thinkingLevels =
  [ ("minimal", ThinkingMinimal),
    ("low", ThinkingLow),
    ("medium", ThinkingMedium),
    ("high", ThinkingHigh)
  ]

neverExceedsCapTests :: [TestTree]
neverExceedsCapTests =
  [ testCase (name <> " " <> levelName <> " stays within catalog cap") $ do
      req <- requestFor model (_Options & #thinking .~ Just level)
      Messages.max_tokens req <= model ^. #maxOutputTokens
        @?= True
  | (name, model, _) <- anthropicModels,
    (levelName, level) <- thinkingLevels
  ]

styleTests :: [TestTree]
styleTests =
  [ testCase (name <> " " <> levelName <> " selects expected thinking style") $ do
      req <- requestFor model (_Options & #thinking .~ Just level)
      case style of
        AnthropicThinkingBudget -> do
          let expectedBudget = thinkingTokenBudget level
          requestThinking req
            @?= Just Messages.ThinkingEnabled {Messages.budget_tokens = expectedBudget}
          assertBool
            "max_tokens leaves visible-output room beyond budget"
            (Messages.max_tokens req > expectedBudget)
        AnthropicThinkingAdaptive -> do
          requestThinking req @?= Just Messages.ThinkingAdaptive
          Messages.max_tokens req @?= model ^. #maxOutputTokens
          (Messages.output_config req >>= Messages.effort)
            @?= adaptiveEffort level
  | (name, model, style) <- anthropicModels,
    (levelName, level) <- thinkingLevels
  ]

explicitMaxTokensTest :: TestTree
explicitMaxTokensTest =
  testCase "explicit maxTokens participates as visible output plus budget, then clamps" $ do
    let opts =
          _Options
            & #thinking .~ Just ThinkingHigh
            & #maxTokens .~ Just 60000
        budget = thinkingTokenBudget ThinkingHigh
    req <- requestFor anthropic_claude_haiku_4_5 opts
    requestThinking req
      @?= Just Messages.ThinkingEnabled {Messages.budget_tokens = budget}
    Messages.max_tokens req @?= anthropic_claude_haiku_4_5 ^. #maxOutputTokens

handRolledUnclampedTest :: TestTree
handRolledUnclampedTest =
  testCase "hand-rolled model with unknown cap is not clamped" $ do
    let model =
          _Model
            & #modelId .~ "custom-claude"
            & #api .~ AnthropicMessages
            & #reasoning .~ True
            & #maxOutputTokens .~ 0
            & #compat .~ CompatAnthropicMessages defaultAnthropicMessagesCompat
        opts =
          _Options
            & #thinking .~ Just ThinkingLow
            & #maxTokens .~ Just 100
        expected = 100 + thinkingTokenBudget ThinkingLow
    req <- requestFor model opts
    Messages.max_tokens req @?= expected

tooSmallCapDropsThinkingTest :: TestTree
tooSmallCapDropsThinkingTest =
  testCase "cap at or below the budget drops the thinking field" $ do
    let model =
          anthropic_claude_haiku_4_5
            & #maxOutputTokens .~ 1000
        opts = _Options & #thinking .~ Just ThinkingMinimal
    req <- requestFor model opts
    requestThinking req @?= Nothing
    Messages.max_tokens req @?= 1000

mergedOutputConfigTest :: TestTree
mergedOutputConfigTest =
  testCase "adaptive effort merges with responseFormat output_config" $ do
    let schema = Aeson.object ["type" Aeson..= ("object" :: Text.Text)]
        opts =
          _Options
            & #thinking .~ Just ThinkingMedium
            & #responseFormat
              .~ Just (JsonSchema {name = "answer", schema = schema, strict = True})
        expected = (Messages.jsonSchemaConfig schema) {Messages.effort = Just "medium"}
    req <- requestFor anthropic_claude_opus_4_6 opts
    requestThinking req @?= Just Messages.ThinkingAdaptive
    Messages.output_config req @?= Just expected

explicitCompatOverridesDefaultTest :: TestTree
explicitCompatOverridesDefaultTest =
  testCase "explicit CompatAnthropicMessages thinkingStyle overrides model generation default" $ do
    let compat =
          defaultAnthropicMessagesCompat
            { thinkingStyle = AnthropicThinkingAdaptive
            }
        model =
          anthropic_claude_haiku_4_5
            & #compat .~ CompatAnthropicMessages compat
        opts = _Options & #thinking .~ Just ThinkingLow
    req <- requestFor model opts
    requestThinking req @?= Just Messages.ThinkingAdaptive
    (Messages.output_config req >>= Messages.effort) @?= Just "low"

requestFor :: Model -> Options -> IO Messages.CreateMessage
requestFor model opts = case mapRequest model _Context opts of
  Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
  Right req -> pure req

requestThinking :: Messages.CreateMessage -> Maybe Messages.Thinking
requestThinking Messages.CreateMessage {Messages.thinking = t} = t

adaptiveEffort :: ThinkingLevel -> Maybe Text.Text
adaptiveEffort = \case
  ThinkingMinimal -> Just "low"
  ThinkingLow -> Just "low"
  ThinkingMedium -> Just "medium"
  ThinkingHigh -> Nothing

streamFidelityTests :: TestTree
streamFidelityTests =
  testGroup
    "stream fidelity and replay"
    [ testCase "thinking and redacted blocks close with full ThinkingContent" $ do
        let (events, _) = runClaudeEvents signedAndRedactedStream
            expectedSigned =
              ThinkingContent
                { thinking = "because therefore",
                  signature = Just "sig-final",
                  redacted = False
                }
            expectedRedacted =
              ThinkingContent
                { thinking = "ENCRYPTED==",
                  signature = Nothing,
                  redacted = True
                }
        thinkingEnds events
          @?= [expectedSigned, expectedRedacted]
        assistantContentFromTerminal events
          @?= Vector.fromList
            [ AssistantThinking expectedSigned,
              AssistantThinking expectedRedacted
            ],
      testCase "assembled thinking blocks replay signature and redacted payload verbatim" $ do
        let (events, _) = runClaudeEvents signedAndRedactedStream
            msg = terminalMessage events
            ctx =
              _Context
                & #messages
                  .~ Vector.fromList
                    [ msg,
                      user "continue"
                    ]
        req <- requestForContext anthropic_claude_haiku_4_5 ctx _Options
        case Vector.toList (requestMessages req) of
          (assistantMsg : _) ->
            BSL.toStrict (Aeson.encode (messageContent assistantMsg))
              @?= BSL.toStrict
                ( Aeson.encode
                    ( Vector.fromList
                        [ Messages.Content_Thinking
                            { Messages.thinking = "because therefore",
                              Messages.signature = "sig-final"
                            },
                          Messages.Content_Redacted_Thinking
                            { Messages.data_ = "ENCRYPTED=="
                            }
                        ]
                    )
                )
          _ -> assertFailure "mapped request contained no assistant message",
      testCase "signature-less non-redacted thinking is omitted on replay" $ do
        let msg =
              AssistantMessage
                AssistantPayload
                  { content =
                      Vector.fromList
                        [ AssistantThinking
                            ThinkingContent
                              { thinking = "draft",
                                signature = Nothing,
                                redacted = False
                              },
                          AssistantText (TextContent "visible")
                        ],
                    usage = _Usage,
                    stopReason = Stop,
                    errorMessage = Nothing,
                    timestamp = testTime
                  }
            ctx = _Context & #messages .~ Vector.fromList [msg]
        req <- requestForContext anthropic_claude_haiku_4_5 ctx _Options
        case Vector.toList (requestMessages req) of
          [assistantMsg] ->
            BSL.toStrict (Aeson.encode (messageContent assistantMsg))
              @?= BSL.toStrict
                ( Aeson.encode
                    ( Vector.singleton
                        Messages.Content_Text
                          { Messages.text = "visible",
                            Messages.cache_control = Nothing
                          }
                    )
                )
          _ -> assertFailure "expected exactly one mapped assistant message",
      testCase "unopened block deltas do not fabricate events or closed blocks" $ do
        let (events, ass) =
              runClaudeEvents
                [ Messages.Content_Block_Delta
                    { Messages.index = 7,
                      Messages.delta = Messages.Delta_Thinking_Delta {Messages.thinking = "ghost"}
                    },
                  Messages.Content_Block_Delta
                    { Messages.index = 8,
                      Messages.delta = Messages.Delta_Input_Json_Delta {Messages.partial_json = "{\"x\""}
                    },
                  Messages.Content_Block_Stop {Messages.index = 8}
                ]
        events @?= []
        IntMap.null (ass ^. #closed) @?= True
        IntMap.null (ass ^. #toolArgsBuf) @?= True
    ]

signedAndRedactedStream :: [Messages.MessageStreamEvent]
signedAndRedactedStream =
  [ messageStart,
    Messages.Content_Block_Start
      { Messages.index = 0,
        Messages.content_block = Messages.ContentBlock_Thinking {Messages.thinking = "", Messages.signature = ""}
      },
    Messages.Content_Block_Delta
      { Messages.index = 0,
        Messages.delta = Messages.Delta_Thinking_Delta {Messages.thinking = "because "}
      },
    Messages.Content_Block_Delta
      { Messages.index = 0,
        Messages.delta = Messages.Delta_Thinking_Delta {Messages.thinking = "therefore"}
      },
    Messages.Content_Block_Delta
      { Messages.index = 0,
        Messages.delta = Messages.Delta_Signature_Delta {Messages.signature = "sig-"}
      },
    Messages.Content_Block_Delta
      { Messages.index = 0,
        Messages.delta = Messages.Delta_Signature_Delta {Messages.signature = "final"}
      },
    Messages.Content_Block_Stop {Messages.index = 0},
    Messages.Content_Block_Start
      { Messages.index = 1,
        Messages.content_block = Messages.ContentBlock_Redacted_Thinking {Messages.data_ = "ENCRYPTED=="}
      },
    Messages.Content_Block_Stop {Messages.index = 1},
    Messages.Message_Delta
      { Messages.message_delta =
          Messages.MessageDelta
            { Messages.stop_reason = Just Messages.End_Turn,
              Messages.stop_sequence = Nothing
            },
        Messages.usage = Messages.StreamUsage {Messages.output_tokens = 12}
      },
    Messages.Message_Stop
  ]

messageStart :: Messages.MessageStreamEvent
messageStart =
  Messages.Message_Start
    { Messages.message =
        Messages.MessageResponse
          { Messages.id = "msg_test",
            Messages.type_ = "message",
            Messages.role = Messages.Assistant,
            Messages.content = Vector.empty,
            Messages.model = "claude-haiku-4-5",
            Messages.stop_reason = Nothing,
            Messages.stop_sequence = Nothing,
            Messages.usage =
              Messages.Usage
                { Messages.input_tokens = 10,
                  Messages.output_tokens = 0,
                  Messages.cache_creation_input_tokens = Nothing,
                  Messages.cache_read_input_tokens = Nothing,
                  Messages.server_tool_use = Nothing
                },
            Messages.container = Nothing
          }
    }

runClaudeEvents :: [Messages.MessageStreamEvent] -> ([AssistantMessageEvent], Assembler)
runClaudeEvents =
  foldl'
    ( \(events, ass) ev ->
        let (newEvents, ass') = translate (Right ev) ass testTime
         in (events <> newEvents, ass')
    )
    ([], emptyAssembler anthropic_claude_haiku_4_5 testTime)

thinkingEnds :: [AssistantMessageEvent] -> [ThinkingContent]
thinkingEnds events =
  [th | ThinkingEnd ThinkingEndPayload {content = th} <- events]

assistantContentFromTerminal :: [AssistantMessageEvent] -> Vector.Vector AssistantContent
assistantContentFromTerminal events =
  case terminalMessage events of
    AssistantMessage AssistantPayload {content = blocks} -> blocks
    _ -> Vector.empty

terminalMessage :: [AssistantMessageEvent] -> Message
terminalMessage events =
  case last events of
    EventDone TerminalPayload {message = msg} -> msg
    EventError TerminalPayload {message = msg} -> msg
    _ -> error "last event was not terminal"

requestForContext :: Model -> Context -> Options -> IO Messages.CreateMessage
requestForContext model ctx opts = case mapRequest model ctx opts of
  Left e -> assertFailure ("mapRequest failed: " <> Text.unpack e)
  Right req -> pure req

requestMessages :: Messages.CreateMessage -> Vector.Vector Messages.Message
requestMessages Messages.CreateMessage {Messages.messages = msgs} = msgs

messageContent :: Messages.Message -> Vector.Vector Messages.Content
messageContent Messages.Message {Messages.content = blocks} = blocks

testTime :: UTCTime
testTime = read "2026-07-03 12:00:00 UTC"
