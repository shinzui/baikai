-- | Multi-host smoke: prove that the same OpenAI Chat Completions
-- handler can serve two different hosts without per-host code, by
-- sending the same prompt to OpenAI and to a second OpenAI-compatible
-- host (OpenRouter, DeepSeek, or Together — whichever has a key set
-- in the environment) and asserting both come back with non-empty
-- assistant text.
--
-- The test is the user-visible artifact for EP-5
-- (`docs/plans/11-compat-shims-cache-retention-and-multi-host-providers.md`):
-- it demonstrates that the compat-record-driven request shaping
-- introduced by M3 actually lets one provider implementation cover
-- multiple hosts.
--
-- Skip rules — the test prints a message and returns 'False' (no
-- failure) when:
--
-- * @OPENAI_API_KEY@ (or @OPENAI_KEY@) is not set; or
-- * none of @DEEPSEEK_API_KEY@, @OPENROUTER_API_KEY@,
--   @TOGETHER_API_KEY@ is set.
--
-- When the test does run, it calls 'completeRequest' twice (once per
-- host) and asserts both responses contain at least one
-- 'AssistantText' block whose body is non-empty. The OpenAI provider
-- handler is registered exactly once; the second host inherits the
-- registration via its 'Model.api = OpenAIChatCompletions'.
module MultiHostSmoke
  ( runMultiHostCase,
  )
where

import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~))
import Control.Monad (when)
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- | Pair a label with the env-var candidates and a function that
-- builds a 'Model' once a key is found. Two such records define the
-- two hosts the smoke compares.
data SecondHost = SecondHost
  { hostLabel :: !String,
    hostEnvVars :: ![String],
    hostModel :: !Model
  }

runMultiHostCase :: IO Bool
runMultiHostCase = do
  matchedOpenai <- firstSetEnv ["OPENAI_API_KEY", "OPENAI_KEY"]
  case matchedOpenai of
    Nothing -> do
      hPutStrLn
        stderr
        "[baikai-smoke] no OpenAI key set; skipping multi-host case."
      pure False
    Just (openaiVar, openaiKey) -> do
      mSecond <- pickSecondHost
      case mSecond of
        Nothing -> do
          hPutStrLn
            stderr
            "[baikai-smoke] no second-host key (DEEPSEEK_API_KEY / \
            \OPENROUTER_API_KEY / TOGETHER_API_KEY); skipping multi-host case."
          pure False
        Just (SecondHost label _envVars secondModel, envVar, secondKey) -> do
          let openaiModel =
                Models.openai_gpt_4o_mini & #maxOutputTokens .~ 64
              ctx =
                emptyContext
                  & #systemPrompt .~ Just "Reply in two words."
                  & #messages
                    .~ Vector.singleton (user "Say hello.")
              openaiOpts =
                emptyOptions
                  & #maxTokens .~ Just 32
                  & #temperature .~ Just 0.0
                  & #apiKey .~ Just (ApiKeyLiteral (Text.pack openaiKey))
              secondOpts =
                emptyOptions
                  & #maxTokens .~ Just 32
                  & #temperature .~ Just 0.0
                  & #apiKey .~ Just (ApiKeyLiteral (Text.pack secondKey))
          resp1 <- completeRequest openaiModel ctx openaiOpts
          resp2 <- completeRequest secondModel ctx secondOpts
          let blocksOpenai = flattenAssistantBlocks resp1
              blocksSecond = flattenAssistantBlocks resp2
              textOpenai = flattenText blocksOpenai
              textSecond = flattenText blocksSecond
              ok =
                not (Text.null textOpenai) && not (Text.null textSecond)
          when (not ok) $ do
            hPutStrLn stderr $
              "[baikai-smoke] multi-host failed: openai_text="
                <> show textOpenai
                <> " "
                <> label
                <> "_text="
                <> show textSecond
            exitFailure
          hPutStrLn stderr $
            "[baikai-smoke] multi-host ok: openai via "
              <> openaiVar
              <> " ("
              <> show (Text.length textOpenai)
              <> " chars), "
              <> label
              <> " via "
              <> envVar
              <> " ("
              <> show (Text.length textSecond)
              <> " chars)"
          pure True

-- | Inspect the environment for the second host. Order is
-- DeepSeek > OpenRouter > Together; the first key found wins. The
-- 'SecondHost' returned carries the model record to use, including
-- the host's @baseUrl@ — the OpenAI provider auto-detects the right
-- compat from the URL.
pickSecondHost :: IO (Maybe (SecondHost, String, String))
pickSecondHost = do
  let candidates =
        [ SecondHost
            { hostLabel = "deepseek",
              hostEnvVars = ["DEEPSEEK_API_KEY"],
              hostModel =
                Models.deepseek_deepseek_chat & #maxOutputTokens .~ 64
            },
          SecondHost
            { hostLabel = "openrouter",
              hostEnvVars = ["OPENROUTER_API_KEY"],
              hostModel =
                Models.openrouter_openai_gpt_4o_mini & #maxOutputTokens .~ 64
            },
          -- One hand-rolled entry kept here to demonstrate that
          -- callers can still target hosts the generated catalog
          -- does not (yet) cover. The OpenAI auto-detection in
          -- 'Baikai.Compat' picks ThinkingFormatTogether from the
          -- @api.together.xyz@ host name.
          SecondHost
            { hostLabel = "together",
              hostEnvVars = ["TOGETHER_API_KEY"],
              hostModel =
                emptyModel
                  & #modelId .~ "meta-llama/Meta-Llama-3-8B-Instruct-Turbo"
                  & #name .~ "Llama 3 8B Instruct Turbo"
                  & #api .~ OpenAIChatCompletions
                  & #provider .~ "together"
                  & #baseUrl .~ "https://api.together.xyz"
                  & #maxOutputTokens .~ 64
            }
        ]
  pickFirst candidates
  where
    pickFirst :: [SecondHost] -> IO (Maybe (SecondHost, String, String))
    pickFirst [] = pure Nothing
    pickFirst (h : rest) = do
      matched <- firstSetEnv (hostEnvVars h)
      case matched of
        Just (envVar, key) -> pure (Just (h, envVar, key))
        Nothing -> pickFirst rest

flattenText :: Vector.Vector AssistantContent -> Text
flattenText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \b -> case b of
          AssistantText (TextContent t) -> Just t
          _ -> Nothing
      )

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
