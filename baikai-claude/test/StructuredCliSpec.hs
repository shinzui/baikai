-- | Structured-output passthrough for the @claude -p@ subprocess
-- provider.
--
-- The process cases run a real child process: a few lines of @sh@
-- written into a temporary directory that record the argument vector,
-- print a canned stdout and stderr, and exit with a chosen code. The
-- argument vector is rendered by 'ClaudeCli.claudeCliCommand', spawned
-- by the real provider, and decoded by the real parser.
module StructuredCliSpec (tests) where

import Baikai
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Control.Lens ((&), (.~), (^.))
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Vector qualified as Vector
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "StructuredCliSpec: claude -p --json-schema passthrough"
    [ renderingTests,
      processTests,
      testCase "the provider declares NativeJsonSchema without spawning anything" $
        ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig ^. #structuredOutput
          @?= NativeJsonSchema
    ]

-- ============================================================
-- Pure argument rendering
-- ============================================================

renderingTests :: TestTree
renderingTests =
  testGroup
    "argument rendering"
    [ testCase "JsonObject renders the same vector as no response format" $
        render (emptyOptions & #responseFormat .~ Just JsonObject) @?= render emptyOptions,
      testCase "no response format renders no --json-schema" $
        assertBool "no schema flag" ("--json-schema" `notElem` snd (render emptyOptions)),
      testCase "JsonSchema renders --json-schema <compact schema> before the extra args" $ do
        let (_, args) = render schemaOptions
        case break (== "--json-schema") args of
          (_, "--json-schema" : value : rest) -> do
            Aeson.decode (LBS.fromStrict (Text.encodeUtf8 (Text.pack value))) @?= Just itemsSchema
            assertBool
              ("extra args follow the schema: " <> show rest)
              (["--allowedTools", "Read"] `isPrefixOf` rest)
          _ -> assertFailure ("no --json-schema in " <> show args)
    ]
  where
    cfg =
      ClaudeCli.defaultClaudeCliConfig
        { ClaudeCli.executable = "/bin/claude",
          ClaudeCli.extraArgs = ["--allowedTools", "Read"]
        }
    render = ClaudeCli.claudeCliCommand cfg testModel testContext

-- ============================================================
-- A real child process
-- ============================================================

processTests :: TestTree
processTests =
  testGroup
    "fake claude process"
    [ testCase "a nested schema round-trips: the result text is returned byte for byte" $ do
        (resp, argv) <- runFake schemaOptions (Fake (resultEvent (Just conformingText) (Just conformingValue)) "" 0)
        responseError resp @?= Nothing
        flattenAssistantText (resp ^. #message . #content) @?= conformingText
        case break (== "--json-schema") argv of
          (_, "--json-schema" : value : _) ->
            Aeson.decode (LBS.fromStrict (Text.encodeUtf8 value)) @?= Just itemsSchema
          _ -> assertFailure ("the schema never reached the tool: " <> show argv),
      testCase "prose in result yields the compact structured_output instead" $ do
        (resp, _) <- runFake schemaOptions (Fake (resultEvent (Just "Here you go.") (Just conformingValue)) "" 0)
        responseError resp @?= Nothing
        let body = flattenAssistantText (resp ^. #message . #content)
        Aeson.decode (LBS.fromStrict (Text.encodeUtf8 body)) @?= Just conformingValue,
      testCase "a schema run without structured_output is a DecodeFailure" $ do
        (resp, _) <- runFake schemaOptions (Fake (resultEvent (Just conformingText) Nothing) "" 0)
        fmap (^. #category) (responseError resp) @?= Just DecodeFailure,
      testCase "claude rejecting --json-schema is InvalidRequest with the exit code" $ do
        (resp, _) <- runFake schemaOptions (Fake "" "error: unknown option '--json-schema'\n" 1)
        case responseError resp of
          Nothing -> assertFailure "expected an error-shaped response"
          Just e -> do
            e ^. #category @?= InvalidRequest
            e ^. #exitCode @?= Just 1
            assertBool (show (e ^. #message)) ("--json-schema" `Text.isInfixOf` (e ^. #message)),
      testCase "the same stderr without a schema request stays a ProcessFailure" $ do
        (resp, argv) <- runFake emptyOptions (Fake "" "error: unknown option '--json-schema'\n" 1)
        assertBool "no schema flag sent" ("--json-schema" `notElem` argv)
        fmap (^. #category) (responseError resp) @?= Just ProcessFailure
    ]

-- | What the fake prints and how it exits.
data Fake = Fake
  { stdoutBody :: LBS.ByteString,
    stderrBody :: Text,
    code :: Int
  }

runFake :: Options -> Fake -> IO (Response, [Text])
runFake opts fake =
  withSystemTempDirectory "baikai-claude-structured" $ \dir -> do
    let argvPath = dir </> "argv"
        outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    LBS.writeFile outPath (stdoutBody fake)
    TextIO.writeFile errPath (stderrBody fake)
    exe <-
      writeFakeExecutable dir "claude" $
        unlines
          [ "#!/bin/sh",
            "printf '%s\\n' \"$@\" > '" <> argvPath <> "'",
            "cat '" <> outPath <> "'",
            "cat '" <> errPath <> "' >&2",
            "exit " <> show (code fake)
          ]
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      (ClaudeCli.claudeCliProvider ClaudeCli.defaultClaudeCliConfig {ClaudeCli.executable = exe})
    resp <- completeRequestWith reg testModel testContext opts
    argv <- Text.lines <$> TextIO.readFile argvPath
    pure (resp, argv)

writeFakeExecutable :: FilePath -> String -> String -> IO FilePath
writeFakeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

-- | A @result@ event in the shape Claude Code 2.1.285 emits for a
-- @--json-schema@ run.
resultEvent :: Maybe Text -> Maybe Aeson.Value -> LBS.ByteString
resultEvent body structured =
  Aeson.encode
    [ Aeson.object ["type" .= ("system" :: Text), "subtype" .= ("init" :: Text)],
      Aeson.object
        ( [ "type" .= ("result" :: Text),
            "subtype" .= ("success" :: Text),
            "is_error" .= False,
            "stop_reason" .= ("tool_use" :: Text),
            "session_id" .= ("01890000-0000-4000-8000-000000000002" :: Text)
          ]
            <> maybe [] (\b -> ["result" .= b]) body
            <> maybe [] (\v -> ["structured_output" .= v]) structured
        )
    ]

-- ============================================================
-- Fixtures
-- ============================================================

testModel :: Model
testModel =
  emptyModel
    & #modelId .~ "sonnet"
    & #api .~ AnthropicMessagesCli
    & #provider .~ "anthropic"

testContext :: Context
testContext = emptyContext & #messages .~ Vector.singleton (user "List two fruits.")

schemaOptions :: Options
schemaOptions =
  emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "fruits" itemsSchema))

-- | An object holding an array of objects, one field an enum.
itemsSchema :: Aeson.Value
itemsSchema =
  Aeson.object
    [ "type" .= ("object" :: Text),
      "properties"
        .= Aeson.object
          [ "items"
              .= Aeson.object
                [ "type" .= ("array" :: Text),
                  "items"
                    .= Aeson.object
                      [ "type" .= ("object" :: Text),
                        "properties"
                          .= Aeson.object
                            [ "label" .= Aeson.object ["type" .= ("string" :: Text)],
                              "level"
                                .= Aeson.object
                                  [ "type" .= ("string" :: Text),
                                    "enum" .= (["low", "high"] :: [Text])
                                  ]
                            ],
                        "required" .= (["label", "level"] :: [Text]),
                        "additionalProperties" .= False
                      ]
                ]
          ],
      "required" .= (["items"] :: [Text]),
      "additionalProperties" .= False
    ]

conformingText :: Text
conformingText =
  "{\"items\":[{\"label\":\"Strawberry\",\"level\":\"low\"},{\"label\":\"Mango\",\"level\":\"high\"}]}"

conformingValue :: Aeson.Value
conformingValue =
  fromMaybe (error "conformingText is JSON") (Aeson.decodeStrict (Text.encodeUtf8 conformingText))
