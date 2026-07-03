-- | Live checks for EP-8 compatibility request shaping.
--
-- These cases prove provider-specific wire shapes against real hosts
-- when keys are available. They intentionally do not try to prove
-- timeout handling or manager reuse: those are transport mechanics
-- covered by the M4 unit tests in the provider packages.
module CompatSmoke
  ( runCompatCases,
  )
where

import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runCompatCases :: IO Bool
runCompatCases = do
  results <-
    sequence
      [ runDeepSeekMaxTokensCase,
        runClaudeVerbatimToolSchemaAndNoneCase,
        runOpenRouterHeadersCacheCase
      ]
  pure (or results)

runDeepSeekMaxTokensCase :: IO Bool
runDeepSeekMaxTokensCase = do
  matched <- firstSetEnv ["DEEPSEEK_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no DEEPSEEK_API_KEY set; skipping deepseek max_tokens case."
      pure False
    Just (envVar, key) -> do
      let model = Models.deepseek_deepseek_chat & #maxOutputTokens .~ 64
          ctx =
            _Context
              & #messages .~ Vector.singleton (user "Reply with the single word: pong.")
          opts =
            _Options
              & #maxTokens .~ Just 16
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp <- completeRequest model ctx opts
      assertNonEmptyText "deepseek max_tokens" envVar resp
      pure True

runClaudeVerbatimToolSchemaAndNoneCase :: IO Bool
runClaudeVerbatimToolSchemaAndNoneCase = do
  matched <- firstSetEnv ["ANTHROPIC_API_KEY", "ANTHROPIC_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no ANTHROPIC_API_KEY set; skipping claude verbatim tool schema/tool_choice none case."
      pure False
    Just (envVar, key) -> do
      let model = Models.anthropic_claude_haiku_4_5 & #maxOutputTokens .~ 1024
          lookupWeather =
            _Tool
              { name = "lookup_weather",
                description = "Return a compact weather report for a timezone.",
                parameters =
                  Aeson.object
                    [ "type" .= ("object" :: Text),
                      "$defs"
                        .= Aeson.object
                          [ "zone"
                              .= Aeson.object
                                [ "type" .= ("string" :: Text),
                                  "enum" .= (["UTC"] :: [Text])
                                ]
                          ],
                      "properties"
                        .= Aeson.object
                          [ "zone" .= Aeson.object ["$ref" .= ("#/$defs/zone" :: Text)]
                          ],
                      "required" .= (["zone"] :: [Text]),
                      "additionalProperties" .= False
                    ]
              }
          ctx0 =
            _Context
              & #messages
                .~ Vector.singleton
                  (user "Use lookup_weather for UTC, then report the result.")
              & #tools .~ Vector.singleton lookupWeather
          baseOpts =
            _Options
              & #maxTokens .~ Just 1024
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp1 <- completeRequest model ctx0 (baseOpts & #toolChoice .~ Just ToolChoiceRequired)
      let toolCalls = [tc | AssistantToolCall tc <- Vector.toList (flattenAssistantBlocks resp1)]
      case toolCalls of
        [] -> do
          hPutStrLn stderr "[baikai-smoke] claude compat failed: expected tool call in first turn."
          exitFailure
        _ -> pure ()
      ctx1 <- appendToolResultText ctx0 resp1 (\_ -> pure ("UTC is clear and 21 C." :: Text))
      resp2 <- completeRequest model ctx1 (baseOpts & #toolChoice .~ Just ToolChoiceNone)
      assertNonEmptyText "claude verbatim tool schema/tool_choice none" envVar resp2
      pure True

runOpenRouterHeadersCacheCase :: IO Bool
runOpenRouterHeadersCacheCase = do
  matched <- firstSetEnv ["OPENROUTER_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no OPENROUTER_API_KEY set; skipping openrouter headers/cache_control case."
      pure False
    Just (envVar, key) -> do
      let model = Models.openrouter_openai_gpt_4o_mini & #maxOutputTokens .~ 64
          ctx =
            _Context
              & #systemPrompt .~ Just "You are terse."
              & #messages .~ Vector.singleton (user "Reply with the single word: pong.")
          opts =
            _Options
              & #maxTokens .~ Just 32
              & #temperature .~ Just 0.0
              & #cacheRetention .~ Just CacheRetentionLong
              & #headers .~ Map.fromList [("X-Title", "baikai-smoke-compat")]
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp <- completeRequest model ctx opts
      assertNonEmptyText "openrouter headers/cache_control" envVar resp
      pure True

assertNonEmptyText :: String -> String -> Response -> IO ()
assertNonEmptyText label envVar resp = do
  let text = flattenAssistantText (flattenAssistantBlocks resp)
  when (Text.null text) $ do
    hPutStrLn stderr $ "[baikai-smoke] " <> label <> " via " <> envVar <> " returned empty text."
    exitFailure
  hPutStrLn stderr $
    "[baikai-smoke] "
      <> label
      <> " ok via "
      <> envVar
      <> "; "
      <> show (Text.length text)
      <> " chars"

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
