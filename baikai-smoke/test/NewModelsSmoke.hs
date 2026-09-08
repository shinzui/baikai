-- | Bounded, explicitly selected live acceptance. Never renders conversations,
-- exceptions, credentials, signatures, or encrypted reasoning items.
module NewModelsSmoke (runNewModels, credentialGroups) where

import Baikai
import Baikai.Error qualified as Err
import Baikai.Evidence qualified as Ev
import Baikai.Models.Generated qualified as Models
import Control.Exception qualified as Exception
import Control.Lens ((&), (.~), (^.))
import Control.Monad (forM)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import SmokeOptions (caseNames, missingKeys)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)

credentialGroups :: [[String]]
credentialGroups = [["OPENAI_KEY", "OPENAI_API_KEY"], ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]]

cases :: [(Model, [String])]
cases = zip [Models.openai_gpt_6_astra, Models.anthropic_claude_fable_5_1] credentialGroups

runNewModels :: Bool -> Maybe String -> IO Bool
runNewModels required selected = do
  env <- traverse (\name -> (name,) <$> lookupEnv name) (concat credentialGroups)
  let selectedCases = filter (\(name, _) -> maybe True (== name) selected) (zip caseNames [(model, keys, tool) | (model, keys) <- cases, tool <- [False, True]])
      missing = missingKeys env [keys | keys <- credentialGroups, any (\(_, (_, group, _)) -> group == keys) selectedCases]
      preflightFailed = required && not (null missing)
  if preflightFailed
    then hPutStrLn stderr ("[baikai-smoke] missing required environment alternatives: " <> show missing)
    else pure ()
  results <- forM selectedCases $ \(_, (model, keys, toolsCase)) ->
    if preflightFailed || keys `elem` missing
      then do
        let status = if preflightFailed then "failed" else "skipped"
            reason = if preflightFailed then "required_credentials_missing" else "credentials_missing"
        report model toolsCase status False reason 0 0 []
      else runCase model keys toolsCase
  LBS.putStrLn (Aeson.encode (Aeson.object ["schema" .= ("baikai.new-model-smoke/1" :: Text), "results" .= map snd results, "missing_environment_alternatives" .= missing]))
  pure (all fst results)

runCase :: Model -> [String] -> Bool -> IO (Bool, Aeson.Value)
runCase model keys toolsCase = do
  dispatched <- newIORef (0 :: Int)
  attempted <- newIORef (0 :: Int)
  observations <- newIORef ([] :: [Aeson.Value])
  historyValid <- newIORef True
  let opts =
        emptyOptions
          & #maxTokens .~ Just 4096
          & #thinking .~ Just ThinkingLow
          & #timeoutMs .~ Just 120000
          & #apiKey .~ Just (ApiKeyEnvChain keys)
          & #evidence .~ Just (Ev.evidenceRequest "new-model-smoke")
      timestamp = "2041-03-17T09:26:53Z" :: Text
      timeTool =
        emptyTool
          { name = "get_time",
            description = "Return the test clock's exact UTC timestamp.",
            parameters = Aeson.object ["type" .= ("object" :: Text), "properties" .= Aeson.object [], "required" .= ([] :: [Text])]
          }
      ctx =
        if toolsCase
          then contextOf [user "Call get_time to read the test clock. Reply with its exact timestamp, unchanged. Do not guess the time."] & #tools .~ Vector.singleton timeTool
          else contextOf [user "Reply with the single word pong."]
      dispatcher tc
        | tc ^. #name == "get_time" = modifyIORef' dispatched (+ 1) >> pure (toolResultText timestamp)
        | otherwise = pure (toolResultErrorText "unknown tool")
      loop remaining context = do
        modifyIORef' attempted (+ 1)
        resp <- completeRequest model context opts
        modifyIORef' observations (<> [responseSummary resp])
        let valid = isJust (resp ^. #evidence) && all replayValid (Vector.toList (flattenAssistantBlocks resp))
        modifyIORef' historyValid (&& valid)
        if valid && resp ^. #message ^. #stopReason == ToolUse && responseError resp == Nothing && remaining > (1 :: Int)
          then do
            let calls = [tc | AssistantToolCall tc <- Vector.toList (flattenAssistantBlocks resp)]
            if null calls || any isCutOffToolCall calls
              then pure resp
              else appendToolResult context resp dispatcher >>= loop (remaining - 1)
          else pure resp
  result <- trySync (loop (if toolsCase then 4 else 1) ctx)
  count <- readIORef dispatched
  attempts <- readIORef attempted
  observed <- readIORef observations
  validHistory <- readIORef historyValid
  let failure = case result of
        Left _ -> Just "exception"
        Right resp
          | responseError resp /= Nothing -> Just "provider_error"
          | not validHistory -> Just "missing_evidence_or_invalid_continuation"
          | resp ^. #message ^. #stopReason /= Stop -> Just "unfinished_response"
          | not (all replayValid (Vector.toList (flattenAssistantBlocks resp))) -> Just "invalid_reasoning_continuation"
          | toolsCase && count == 0 -> Just "dispatcher_not_called"
          | toolsCase && not (timestamp `Text.isInfixOf` flattenAssistantText (flattenAssistantBlocks resp)) -> Just "timestamp_missing"
          | not toolsCase && Text.null (flattenAssistantText (flattenAssistantBlocks resp)) -> Just "text_missing"
          | otherwise -> Nothing
  report model toolsCase (if isJust failure then "failed" else "passed") (attempts > 0) (maybe "ok" id failure) attempts count observed

-- Keep opaque state opaque. A summary may be empty; its continuation must still
-- be suitable for the provider that emitted it.
replayValid :: AssistantContent -> Bool
replayValid (AssistantThinking t) = case t ^. #replayState of
  Just replay -> not (Vector.null (replay ^. #replayItems))
  Nothing -> t ^. #redacted || maybe False (not . Text.null) (t ^. #signature)
replayValid _ = True

responseSummary :: Response -> Aeson.Value
responseSummary resp =
  Aeson.object
    [ "observed_model" .= fmap Ev.observedModel (resp ^. #evidence),
      "endpoint" .= fmap (^. #endpoint) (resp ^. #evidence),
      "thinking_translation" .= fmap Ev.thinking (resp ^. #evidence),
      "response_id" .= (resp ^. #responseId),
      "provider_request_id" .= fmap Ev.providerRequestId (resp ^. #evidence),
      "error_category" .= fmap Err.category (responseError resp),
      "http_status" .= (responseError resp >>= Err.httpStatus),
      "stop_reason" .= show (resp ^. #message ^. #stopReason),
      "cost" .= (resp ^. #message ^. #usage ^. #cost),
      "reasoning_blocks" .= length [() | AssistantThinking _ <- Vector.toList (flattenAssistantBlocks resp)],
      "reasoning_continuation_valid" .= all replayValid (Vector.toList (flattenAssistantBlocks resp))
    ]

report :: Model -> Bool -> Text -> Bool -> Text -> Int -> Int -> [Aeson.Value] -> IO (Bool, Aeson.Value)
report model toolsCase status ran detail attempts dispatches observations = do
  let caseName = if toolsCase then "tools" else "text" :: Text
  hPutStrLn stderr ("[baikai-smoke] " <> Text.unpack (model ^. #modelId) <> " " <> Text.unpack caseName <> ": " <> Text.unpack status <> " (" <> Text.unpack detail <> ")")
  pure
    ( status /= "failed",
      Aeson.object
        [ "requested_model" .= (model ^. #modelId),
          "api" .= show (model ^. #api),
          "case" .= caseName,
          "status" .= status,
          "ran" .= ran,
          "detail" .= detail,
          "call_count" .= attempts,
          "tool_dispatch_count" .= dispatches,
          "options" .= Aeson.object ["max_tokens" .= (4096 :: Int), "thinking" .= ("low" :: Text), "timeout_ms" .= (120000 :: Int), "max_turns" .= (if toolsCase then 4 else 1 :: Int)],
          "responses" .= observations
        ]
    )

trySync :: IO a -> IO (Either Exception.SomeException a)
trySync action = do
  result <- Exception.try action
  case result of
    Left err | Just (_ :: Exception.SomeAsyncException) <- Exception.fromException err -> Exception.throwIO err
    _ -> pure result
