-- | Structured-output passthrough for the @codex exec --json@
-- subprocess provider.
--
-- The process cases run a real child process: a few lines of @sh@
-- written into a temporary directory that record the argument vector,
-- copy the @--output-schema@ file before the provider can delete it,
-- print a canned event stream and stderr, and exit with a chosen code.
module StructuredCliSpec (tests) where

import Baikai
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Control.Lens ((&), (.~), (^.))
import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Vector qualified as Vector
import System.Directory (doesFileExist, getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "StructuredCliSpec: codex exec --output-schema passthrough"
    [ renderingTests,
      processTests,
      testCase "the provider declares NativeJsonSchema without spawning anything" $
        CodexCli.codexCliProvider CodexCli.defaultCodexCliConfig ^. #structuredOutput
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
        CodexCli.codexCliCommand cfg testModel testContext (emptyOptions & #responseFormat .~ Just JsonObject)
          @?= CodexCli.codexCliCommand cfg testModel testContext emptyOptions,
      testCase "codexCliCommand renders no --output-schema even for a JsonSchema request" $
        assertBool
          "no schema flag"
          ("--output-schema" `notElem` snd (CodexCli.codexCliCommand cfg testModel testContext schemaOptions)),
      testCase "codexCliCommandWith Nothing is codexCliCommand" $
        CodexCli.codexCliCommandWith cfg Nothing testModel testContext schemaOptions
          @?= CodexCli.codexCliCommand cfg testModel testContext schemaOptions,
      testCase "codexCliCommandWith places --output-schema <file> before the extra args" $ do
        let (_, args) = CodexCli.codexCliCommandWith cfg (Just "/tmp/s.json") testModel testContext schemaOptions
        case break (== "--output-schema") args of
          (_, "--output-schema" : "/tmp/s.json" : rest) ->
            assertBool ("extra args follow the schema: " <> show rest) (["--color", "never"] `isPrefixOf` rest)
          _ -> assertFailure ("no --output-schema in " <> show args)
    ]
  where
    cfg = CodexCli.defaultCodexCliConfig {CodexCli.extraArgs = ["--color", "never"]}

-- ============================================================
-- A real child process
-- ============================================================

processTests :: TestTree
processTests =
  testGroup
    "fake codex process"
    [ testCase "the schema file carries the schema, the reply is returned unchanged, the file is removed" $
        withFakeCodex $ \run -> do
          (resp, captured) <- run schemaOptions (Fake conformingEvents "" 0)
          responseError resp @?= Nothing
          flattenAssistantText (resp ^. #message . #content) @?= conformingText
          case captured of
            Nothing -> assertFailure "the tool received no --output-schema"
            Just (path, bytes) -> do
              Aeson.decodeStrict bytes @?= Just itemsSchema
              doesFileExist (Text.unpack path) >>= (@?= False),
      testCase "the schema file is removed after a failed run too" $
        withFakeCodex $ \run -> do
          (resp, captured) <- run schemaOptions (Fake [] "the tool refused\n" 3)
          fmap (^. #category) (responseError resp) @?= Just ProcessFailure
          case captured of
            Nothing -> assertFailure "the tool received no --output-schema"
            Just (path, _) -> doesFileExist (Text.unpack path) >>= (@?= False),
      testCase "no response format sends no --output-schema" $
        withFakeCodex $ \run -> do
          (resp, captured) <- run emptyOptions (Fake conformingEvents "" 0)
          responseError resp @?= Nothing
          fmap fst captured @?= Nothing,
      testCase "codex rejecting --output-schema is InvalidRequest with the exit code" $
        withFakeCodex $ \run -> do
          (resp, _) <- run schemaOptions (Fake [] "error: unexpected argument '--output-schema' found\n" 2)
          case responseError resp of
            Nothing -> assertFailure "expected an error-shaped response"
            Just e -> do
              e ^. #category @?= InvalidRequest
              e ^. #exitCode @?= Just 2,
      testCase "the same stderr without a schema request stays a ProcessFailure" $
        withFakeCodex $ \run -> do
          (resp, _) <- run emptyOptions (Fake [] "error: unexpected argument '--output-schema' found\n" 2)
          fmap (^. #category) (responseError resp) @?= Just ProcessFailure,
      -- The spawned vector names a fresh random path each call; the
      -- evidence envelope names the schema instead, so the commitment
      -- is reproducible and still changes with the schema.
      testCase "the request commitment is reproducible and commits to the schema" $
        withFakeCodex $ \run -> do
          (first, _) <- run (schemaOptions & #evidence .~ Just (evidenceRequest "run-87")) (Fake conformingEvents "" 0)
          (second, _) <- run (schemaOptions & #evidence .~ Just (evidenceRequest "run-87")) (Fake conformingEvents "" 0)
          (plain, _) <- run (emptyOptions & #evidence .~ Just (evidenceRequest "run-87")) (Fake conformingEvents "" 0)
          let c1 = encodedCommitment first
          assertBool ("a commitment was recorded: " <> show c1) (c1 /= Nothing)
          c1 @?= encodedCommitment second
          assertBool "the schema is part of the commitment" (c1 /= encodedCommitment plain)
    ]

-- | What the fake prints and how it exits.
data Fake = Fake
  { eventLines :: [Text],
    stderrBody :: Text,
    code :: Int
  }

-- | Write one fake @codex@ and hand back a function that runs a call
-- against it and returns the response with the schema path and bytes
-- the tool received.
--
-- Calls whose commitments are compared must share one fake, because
-- the argument vector the commitment digests begins with the
-- executable's path.
withFakeCodex :: ((Options -> Fake -> IO (Response, Maybe (Text, BS.ByteString))) -> IO a) -> IO a
withFakeCodex k =
  withSystemTempDirectory "baikai-codex-structured" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
        codePath = dir </> "code"
        pathPath = dir </> "schema-path"
        copyPath = dir </> "schema-copy"
    exe <-
      writeFakeExecutable dir "codex" $
        unlines
          [ "#!/bin/sh",
            "if [ \"$1\" = \"--version\" ]; then echo 'codex-cli 9.9.9'; exit 0; fi",
            "rm -f '" <> pathPath <> "' '" <> copyPath <> "'",
            "prev=",
            "for a in \"$@\"; do",
            "  if [ \"$prev\" = \"--output-schema\" ]; then",
            "    printf '%s' \"$a\" > '" <> pathPath <> "'",
            "    cp \"$a\" '" <> copyPath <> "'",
            "  fi",
            "  prev=\"$a\"",
            "done",
            "cat '" <> outPath <> "'",
            "cat '" <> errPath <> "' >&2",
            "exit $(cat '" <> codePath <> "')"
          ]
    reg <- newProviderRegistry
    registerApiProviderWith
      reg
      (CodexCli.codexCliProvider CodexCli.defaultCodexCliConfig {CodexCli.executable = exe})
    k $ \opts fake -> do
      TextIO.writeFile outPath (Text.unlines (eventLines fake))
      TextIO.writeFile errPath (stderrBody fake)
      writeFile codePath (show (code fake))
      resp <- completeRequestWith reg testModel testContext opts
      sent <- doesFileExist pathPath
      captured <-
        if sent
          then do
            path <- TextIO.readFile pathPath
            bytes <- BS.readFile copyPath
            pure (Just (path, bytes))
          else pure Nothing
      pure (resp, captured)

writeFakeExecutable :: FilePath -> String -> String -> IO FilePath
writeFakeExecutable dir name body = do
  let path = dir </> name
  writeFile path body
  perms <- getPermissions path
  setPermissions path (setOwnerExecutable True perms)
  pure path

-- | The encoded @request_commitment@ of a response's evidence record.
encodedCommitment :: Response -> Maybe Value
encodedCommitment resp = case Aeson.toJSON <$> (resp ^. #evidence) of
  Just (Object o) -> KeyMap.lookup "request_commitment" o
  _ -> Nothing

-- ============================================================
-- Fixtures
-- ============================================================

testModel :: Model
testModel =
  emptyModel
    & #modelId .~ "gpt-5.6"
    & #api .~ OpenAICompletionsCli
    & #provider .~ "openai"

testContext :: Context
testContext = emptyContext & #messages .~ Vector.singleton (user "List two fruits.")

schemaOptions :: Options
schemaOptions =
  emptyOptions & #responseFormat .~ Just (JsonSchema (jsonSchemaFormat "fruits" itemsSchema))

-- | An object holding an array of objects, one field an enum, in the
-- strict shape codex requires.
itemsSchema :: Value
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

-- | The event stream @codex-cli 0.159.0@ emits for an @--output-schema@
-- run: the structured reply is the text of the ordinary final
-- @agent_message@.
conformingEvents :: [Text]
conformingEvents =
  [ "{\"type\":\"thread.started\",\"thread_id\":\"019fd471-4a48-7c83-be67-6b7c49646e87\"}",
    "{\"type\":\"turn.started\"}",
    Text.decodeUtf8 . LBS.toStrict . Aeson.encode $
      Aeson.object
        [ "type" .= ("item.completed" :: Text),
          "item"
            .= Aeson.object
              [ "id" .= ("item_0" :: Text),
                "type" .= ("agent_message" :: Text),
                "text" .= conformingText
              ]
        ],
    "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,\"output_tokens\":20}}"
  ]
