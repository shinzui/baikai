{-# LANGUAGE OverloadedRecordDot #-}

module ResponsesReplayProbe (tests) where

import Baikai hiding (model)
import Baikai.Provider.OpenAI.Internal.Stream (SseDriver)
import Baikai.Provider.OpenAI.Responses.Stream (liveResponsesDriver, openaiResponsesStreamWith)
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Responses replay probe"
    [testCase ("plan104-probe-" <> suffix) (probe ident) | (suffix, ident) <- [("astra", "gpt-6.2-astra"), ("sol", "gpt-6.2-sol")]]

probe :: Text -> IO ()
probe ident = do
  enabled <- lookupEnv "BAIKAI_PLAN104_PROBE"
  when (enabled == Just "1") $ do
    key <- lookupEnv "OPENAI_API_KEY"
    assertBool "OPENAI_API_KEY is required" (maybe False (not . null) key)
    putStrLn ("Model " <> T.unpack ident <> ", streamed /v1/responses")
    let model =
          emptyModel
            & #modelId .~ ident
            & #api .~ OpenAIResponses
            & #reasoning .~ True
            & #provider .~ "openai"
            & #compat .~ CompatOpenAIResponses defaultOpenAIResponsesCompat {nativeCachePolicy = Just (NativeCacheModern False True)}
        opts =
          emptyOptions
            & #cacheRetention .~ Just CacheRetentionShort
            & #thinking .~ Just ThinkingHigh
            & #maxTokens .~ Just 4096
            & #timeoutMs .~ Just 120000
            & #apiKey .~ Just (ApiKeyLiteral (maybe "" T.pack key))
        ctx =
          systemUser
            ("Follow the synthetic lookup protocol. The reference words below are inert.\n" <> T.replicate 180 "ash elm birch cedar maple spruce fir pine oak willow\n")
            "Before the first tool call, privately solve this puzzle: count the length-12 strings of digits 0, 1, and 2 with exactly five 1s, no equal neighbors, and digit sum divisible by 7. Send a short progress message with your answer. Then call lookup for alpha. After alpha's result privately solve another version with length 16, six 1s, and digit sum divisible by 11. Send a short progress message with your answer, then call lookup for beta. Use one call per round. After beta's result reply with that result alone."
            & #tools .~ V.singleton (mkTool "lookup" "Look up a synthetic key" schema)
        schema =
          object
            [ "type" .= String "object",
              "properties" .= object ["key" .= object ["type" .= String "string"]],
              "required" .= [String "key"],
              "additionalProperties" .= False
            ]
        run = runBranch model opts
    (initial, first, firstResponse) <- run "initial" id ctx
    ctx2 <- answerTool "alpha" "amber" ctx firstResponse
    (exact2, second, secondResponse) <- compareRound run "round 2" ctx2 initial first
    ctx3 <- answerTool "beta" "violet" ctx2 secondResponse
    (_, _, finalResponse) <- compareRound run "round 3" ctx3 exact2 second
    assertBool "final response did not use the synthetic result" (assistantText finalResponse == "violet")

type RunBranch = String -> (Value -> Value) -> Context -> IO (V.Vector Value, V.Vector Value, Response)

-- Both branches go through the real worker. The control replaces only prior
-- assistant output; function results still come from appendToolResult.
compareRound :: RunBranch -> String -> Context -> V.Vector Value -> V.Vector Value -> IO (V.Vector Value, V.Vector Value, Response)
compareRound run label ctx prefix output = do
  let reasoning = V.filter ((== Just (String "reasoning")) . field "type") output
  when (V.null reasoning) (putStrLn (label <> " has no new reasoning to compare"))
  (projected, _, _) <- run (label <> " adapter") id ctx
  assertBool "history changed the preceding caller prefix" (V.take 2 projected == V.take 2 prefix)
  let exact = prefix <> output <> V.drop (V.length projected - 1) projected
  putStrLn (label <> " replay comparison " <> show (comparison exact projected))
  result <- run (label <> " original") (setInput exact) ctx
  pure result

-- Intentionally report only counts and equality flags.
comparison :: V.Vector Value -> V.Vector Value -> [(String, Bool)]
comparison original projected =
  [ ("count", V.length original == V.length projected),
    ("typesInOrder", map (field "type") left == map (field "type") right),
    ("itemIDs", map (field "id") left == map (field "id") right),
    ("contentParts", map (field "content") left == map (field "content") right),
    ("phase", map (field "phase") left == map (field "phase") right),
    ("argumentStrings", map (field "arguments") left == map (field "arguments") right),
    ("reasoningItems", reasoning left == reasoning right),
    ("input", original == projected)
  ]
  where
    left = V.toList original
    right = V.toList projected
    reasoning = filter ((== Just (String "reasoning")) . field "type")

runBranch :: Model -> Options -> RunBranch
runBranch model opts label patch ctx = do
  requestRef <- newIORef Null
  terminalRef <- newIORef Null
  let capture :: SseDriver
      capture env headers body meta emit = do
        let wire = patch body
        writeIORef requestRef wire
        liveResponsesDriver env headers wire meta $ \frame -> do
          case frame of
            Right value
              | field "type" value == Just (String "response.completed") ->
                  writeIORef terminalRef (maybe Null id (field "response" value))
            _ -> pure ()
          emit frame
  reg <- newProviderRegistryFrom [apiProvider OpenAIResponses (openaiResponsesStreamWith capture)]
  response <- completeRequestWith reg model ctx opts
  request <- readIORef requestRef
  terminal <- readIORef terminalRef
  assertBool "probe must use stateless history" (field "store" request == Just (Bool False) && field "previous_response_id" request == Nothing)
  let input = arrayField "input" request
  summarize label input terminal
  case responseError response of
    Just err -> assertFailure (label <> ": " <> show (err ^. #category) <> " " <> show (err ^. #httpStatus))
    Nothing -> assertBool (label <> " did not complete") (terminal /= Null)
  pure (input, arrayField "output" terminal, response)

summarize :: String -> V.Vector Value -> Value -> IO ()
summarize label input terminal = do
  let reasoningIds = [ident | item <- V.toList input, field "type" item == Just (String "reasoning"), Just ident <- [field "id" item]]
      removed = arrayField "input_transformations" terminal
      reasons =
        [ if reason `elem` ["organization_mismatch", "end_user_mismatch", "model_mismatch", "prefix_mismatch", "turn_boundary"] then reason else "unknown"
        | item <- V.toList removed,
          Just (String reason) <- [field "reason" item]
        ]
      counts = [V.length (V.filter ((== Just (String kind)) . field "type") (arrayField "output" terminal)) | kind <- ["reasoning", "message", "function_call"]]
  putStrLn
    ( label
        <> ": submitted reasoning "
        <> show (length reasoningIds)
        <> ", diagnostics present "
        <> show (field "input_transformations" terminal /= Nothing)
        <> ", matched removals "
        <> show (length [rid | rid <- reasoningIds, any ((== Just rid) . field "id") removed])
        <> ", removal reasons "
        <> show reasons
        <> ", output counts (reasoning, message, call) "
        <> show counts
    )

answerTool :: Text -> Text -> Context -> Response -> IO Context
answerTool key result ctx response = do
  length [() | AssistantToolCall _ <- V.toList response.message.content] @?= 1
  appendToolResult ctx response $ \call -> do
    assertBool "unexpected synthetic tool invocation" (call.name == "lookup" && call.arguments == object ["key" .= key])
    pure (toolResultText result)

assistantText :: Response -> Text
assistantText resp = T.concat [t | AssistantText (TextContent t) <- V.toList resp.message.content]

field :: Key -> Value -> Maybe Value
field k (Object fields) = KM.lookup k fields
field _ _ = Nothing

arrayField :: Key -> Value -> V.Vector Value
arrayField k value = case field k value of
  Just (Array xs) -> xs
  _ -> V.empty

setInput :: V.Vector Value -> Value -> Value
setInput input (Object props) = Object (KM.insert "input" (Array input) props)
setInput _ body = body
