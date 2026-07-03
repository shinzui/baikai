-- | Live smoke checks for provider thinking/reasoning support.
--
-- Each case skips when its API key is absent. When a key is present,
-- failures are hard failures because this module is the end-to-end
-- proof for replayable Anthropic thinking and OpenAI-compatible
-- reasoning extraction.
module ThinkingSmoke
  ( runThinkingCases,
  )
where

import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runThinkingCases :: IO Bool
runThinkingCases = do
  results <-
    sequence
      [ runAnthropicCase
          "claude-sonnet-4-5-thinking-budget"
          Models.anthropic_claude_sonnet_4_5
          ThinkingLow,
        runAnthropicCase
          "claude-opus-4-6-thinking-adaptive"
          Models.anthropic_claude_opus_4_6
          ThinkingMedium,
        runDeepSeekCase
      ]
  pure (or results)

runAnthropicCase :: String -> Model -> ThinkingLevel -> IO Bool
runAnthropicCase caseLabel caseModel thinkingLevel = do
  matched <- firstSetEnv ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of [\"ANTHROPIC_KEY\",\"ANTHROPIC_API_KEY\"] set; skipping "
          <> caseLabel
          <> "."
      pure False
    Just (envVar, key) -> do
      let opts =
            _Options
              & #thinking .~ Just thinkingLevel
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
          ctx =
            _Context
              & #systemPrompt .~ Just "Answer tersely."
              & #messages
                .~ Vector.singleton
                  (user "Think briefly, then answer with exactly: first-ok")
      firstResp <- completeRequest caseModel ctx opts
      assertAnthropicThinking caseLabel "first turn" firstResp
      let followCtx =
            ctx
              & #messages
                .~ Vector.fromList
                  [ user "Think briefly, then answer with exactly: first-ok",
                    responseMessage firstResp,
                    user "Now answer with exactly: replay-ok"
                  ]
      secondResp <- completeRequest caseModel followCtx opts
      assertSucceeded caseLabel "replay turn" secondResp
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> caseLabel
          <> " ok via "
          <> envVar
          <> "; thinking signature replay accepted"
      pure True

runDeepSeekCase :: IO Bool
runDeepSeekCase = do
  matched <- firstSetEnv ["DEEPSEEK_KEY", "DEEPSEEK_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of [\"DEEPSEEK_KEY\",\"DEEPSEEK_API_KEY\"] set; skipping deepseek-reasoner-thinking."
      pure False
    Just (envVar, key) -> do
      let opts =
            _Options
              & #thinking .~ Just ThinkingMedium
              & #maxTokens .~ Just 128
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
          ctx =
            _Context
              & #systemPrompt .~ Just "Answer tersely."
              & #messages
                .~ Vector.singleton
                  (user "Think briefly, then answer with exactly: deepseek-ok")
      resp <- completeRequest Models.deepseek_deepseek_reasoner ctx opts
      assertDeepSeekReasoning resp
      hPutStrLn stderr $
        "[baikai-smoke] deepseek-reasoner-thinking ok via "
          <> envVar
          <> "; reasoning separated from visible text"
      pure True

assertAnthropicThinking :: String -> String -> Response -> IO ()
assertAnthropicThinking caseLabel phase resp = do
  assertSucceeded caseLabel phase resp
  let thinkingBlocks = assistantThinking (flattenAssistantBlocks resp)
      replayable =
        [ th
        | th@ThinkingContent {thinking = body, signature = Just sig, redacted = False} <- thinkingBlocks,
          not (Text.null body),
          not (Text.null sig)
        ]
  when (null replayable) $ do
    hPutStrLn stderr $
      "[baikai-smoke] "
        <> caseLabel
        <> " "
        <> phase
        <> " had no replayable non-redacted AssistantThinking block; blocks="
        <> show (flattenAssistantBlocks resp)
    exitFailure

assertDeepSeekReasoning :: Response -> IO ()
assertDeepSeekReasoning resp = do
  assertSucceeded "deepseek-reasoner-thinking" "first turn" resp
  let blocks = flattenAssistantBlocks resp
      hasReasoning =
        any
          (\ThinkingContent {thinking = body} -> not (Text.null body))
          (assistantThinking blocks)
      visibleText = flattenAssistantText blocks
  when (not hasReasoning || Text.null visibleText) $ do
    hPutStrLn stderr $
      "[baikai-smoke] deepseek-reasoner-thinking failed; has_reasoning="
        <> show hasReasoning
        <> " visible_text_chars="
        <> show (Text.length visibleText)
        <> " blocks="
        <> show blocks
    exitFailure

assertSucceeded :: String -> String -> Response -> IO ()
assertSucceeded caseLabel phase resp =
  case responseError resp of
    Nothing -> pure ()
    Just err -> do
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> caseLabel
          <> " "
          <> phase
          <> " failed: "
          <> show err
          <> "; message="
          <> show (resp ^. #message)
      exitFailure

assistantThinking :: Vector.Vector AssistantContent -> [ThinkingContent]
assistantThinking =
  Vector.toList
    . Vector.mapMaybe
      ( \case
          AssistantThinking th -> Just th
          _ -> Nothing
      )

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
