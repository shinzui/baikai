module ShapeSpec (tests) where

import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api (mapRequest)
import Baikai.Provider.Claude.Shape (streamRequestBody)
import Control.Lens ((&), (.~))
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ShapeSpec"
    [ verbatimToolSchemaTest,
      toolChoiceNoneTest,
      toolCacheControlTest,
      toolCacheControlCompatGateTest
    ]

verbatimToolSchemaTest :: TestTree
verbatimToolSchemaTest =
  testCase "tool input_schema is the caller's verbatim JSON Schema" $ do
    let schema =
          Aeson.object
            [ "type" .= ("object" :: Text.Text),
              "$defs"
                .= Aeson.object
                  [ "unit"
                      .= Aeson.object
                        [ "enum" .= (["c", "f"] :: [Text.Text])
                        ]
                  ],
              "additionalProperties" .= False
            ]
        ctx =
          _Context
            & #tools
              .~ Vector.singleton
                (_Tool & #name .~ "weather" & #description .~ "Weather" & #parameters .~ schema)
    value <- shapedBody Models.anthropic_claude_haiku_4_5 ctx _Options
    lookupPath ["tools", "0", "input_schema"] value @?= Just schema

toolChoiceNoneTest :: TestTree
toolChoiceNoneTest =
  testCase "ToolChoiceNone keeps tools and sends tool_choice none" $ do
    let ctx =
          _Context
            & #tools
              .~ Vector.singleton
                (_Tool & #name .~ "lookup" & #description .~ "Lookup" & #parameters .~ objectSchema)
        opts = _Options & #toolChoice .~ Just ToolChoiceNone
    value <- shapedBody Models.anthropic_claude_haiku_4_5 ctx opts
    assertBool "tools should remain present" (hasNonEmptyTools value)
    lookupPath ["tool_choice", "type"] value @?= Just (String "none")

toolCacheControlTest :: TestTree
toolCacheControlTest =
  testCase "cache marker lands on the last tool definition with ttl" $ do
    let ctx =
          _Context
            & #tools
              .~ Vector.fromList
                [ _Tool & #name .~ "first" & #description .~ "First" & #parameters .~ objectSchema,
                  _Tool & #name .~ "second" & #description .~ "Second" & #parameters .~ objectSchema
                ]
        opts = _Options & #cacheRetention .~ Just CacheRetentionLong
    value <- shapedBody Models.anthropic_claude_haiku_4_5 ctx opts
    lookupPath ["tools", "0", "cache_control"] value @?= Nothing
    lookupPath ["tools", "1", "cache_control"] value
      @?= Just
        ( Aeson.object
            [ "type" .= ("ephemeral" :: Text.Text),
              "ttl" .= ("1h" :: Text.Text)
            ]
        )

toolCacheControlCompatGateTest :: TestTree
toolCacheControlCompatGateTest =
  testCase "supportsCacheControlOnTools gates tool cache markers" $ do
    let compat =
          defaultAnthropicMessagesCompat
            { supportsCacheControlOnTools = False
            }
        model =
          Models.anthropic_claude_haiku_4_5
            & #compat .~ CompatAnthropicMessages compat
        ctx =
          _Context
            & #tools
              .~ Vector.singleton
                (_Tool & #name .~ "lookup" & #description .~ "Lookup" & #parameters .~ objectSchema)
        opts = _Options & #cacheRetention .~ Just CacheRetentionShort
    value <- shapedBody model ctx opts
    lookupPath ["tools", "0", "cache_control"] value @?= Nothing

shapedBody :: Model -> Context -> Options -> IO Value
shapedBody model ctx opts = do
  req <- either (assertFailure . Text.unpack) pure (mapRequest model ctx opts)
  pure (streamRequestBody (anthropicMessagesCompatFor model) ctx opts req)

objectSchema :: Value
objectSchema = Aeson.object ["type" .= ("object" :: Text.Text)]

hasNonEmptyTools :: Value -> Bool
hasNonEmptyTools value =
  case lookupPath ["tools"] value of
    Just (Array xs) -> not (Vector.null xs)
    _ -> False

lookupPath :: [Text.Text] -> Value -> Maybe Value
lookupPath [] value = Just value
lookupPath (field : rest) (Object obj) =
  KeyMap.lookup (AesonKey.fromText field) obj >>= lookupPath rest
lookupPath (field : rest) (Array xs)
  | [(i, "")] <- reads (Text.unpack field),
    i >= 0,
    i < Vector.length xs =
      lookupPath rest (xs Vector.! i)
lookupPath _ _ = Nothing
