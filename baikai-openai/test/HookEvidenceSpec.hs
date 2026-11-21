module HookEvidenceSpec (tests) where

import Baikai.Provider.OpenAI.HookEvidence
import Data.Aeson (Value (Bool, Object, String), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "app-server pre-tool evidence"
    [ testCase "check the reviewed gate within the thread's inventory" $
        verify (inventory [gate]) @?= Right (),
      testCase "missing, duplicate and partial inventories fail" $ do
        assertBool "missing" (isLeft (verify (inventory [])))
        assertBool "ambiguous" (isLeft (verify (inventory [gate, gate])))
        assertBool "inventory error" (isLeft (verify (object ["data" .= [object ["errors" .= [True], "hooks" .= [gate]]]]))),
      testCase "only the exact reviewed and executable session gate qualifies" $
        mapM_
          (\(key, val) -> assertBool (show key) (isLeft (verify (inventory [KeyMap.insert key val gate]))))
          [ ("currentHash", String "changed"),
            ("trustStatus", String "untrusted"),
            ("trustStatus", String "modified"),
            ("source", String "user"),
            ("handlerType", String "prompt"),
            ("eventName", String "postToolUse"),
            ("enabled", Bool False),
            ("async", Bool True)
          ],
      testCase "structured denial survives a successful turn" $
        parse (hook "preToolUse" "blocked") @?= Right (Just (CodexPreToolUse "t" "u" "r" Blocked)),
      testCase "exit 7 is ordinary command failure" $
        parse (object ["method" .= ("item/completed" :: Text), "params" .= object ["item" .= object ["status" .= ("failed" :: Text), "exitCode" .= (7 :: Int)]]]) @?= Right Nothing,
      testCase "a different hook can also report blocked" $
        parse (hook "postToolUse" "blocked") @?= Right Nothing,
      testCase "hook failure, stop and completion are distinct" $
        traverse (parse . hook "preToolUse") ["failed", "stopped", "completed"]
          @?= Right [Just (CodexPreToolUse "t" "u" "r" x) | x <- [Failed, Stopped, Completed]],
      testCase "unknown or malformed evidence cannot be treated as success" $ do
        assertBool "unexpected status" (isLeft (parse (hook "preToolUse" "running")))
        assertBool "missing run" (isLeft (parse (object ["method" .= ("hook/completed" :: Text), "params" .= object []])))
    ]
  where
    verify = parseEither (requireReviewedPreToolUseHook "gate" "digest")
    inventory hooks = object ["data" .= [object ["errors" .= ([] :: [Value]), "hooks" .= (map Object hooks)]]]
    gate =
      KeyMap.fromList
        [ ("key", String "gate"),
          ("currentHash", String "digest"),
          ("source", String "sessionFlags"),
          ("eventName", String "preToolUse"),
          ("handlerType", String "command"),
          ("trustStatus", String "trusted"),
          ("enabled", Bool True),
          ("async", Bool False)
        ]
    parse = parseEither parsePreToolUseCompletion
    hook :: Text -> Text -> Value
    hook event status =
      object
        [ "method" .= ("hook/completed" :: Text),
          "params" .= object ["threadId" .= ("t" :: Text), "turnId" .= ("u" :: Text), "run" .= object ["id" .= ("r" :: Text), "eventName" .= event, "status" .= status]]
        ]
