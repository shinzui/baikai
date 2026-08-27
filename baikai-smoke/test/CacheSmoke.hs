-- | Live check for prompt-cache retention end-to-end.
--
-- Proves the request-side preference and the response-side accounting
-- line up: a first call with a large, stable prefix seeds the cache
-- ('cacheWriteTokens' > 0), and an identical second call reuses it
-- ('cacheReadTokens' > 0). Anthropic only caches a prefix above a
-- per-model token floor, so the case uses a deliberately oversized
-- system prompt held byte-for-byte identical across both calls.
--
-- Skips cleanly when no Anthropic key is present, like the other
-- smoke cases.
module CacheSmoke
  ( runCacheCases,
  )
where

import Baikai
import Baikai.Models.Generated qualified as Models
import Control.Lens ((&), (.~), (^.))
import Control.Monad (when)
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

runCacheCases :: IO Bool
runCacheCases = runClaudeCacheReadWriteCase

runClaudeCacheReadWriteCase :: IO Bool
runClaudeCacheReadWriteCase = do
  matched <- firstSetEnv ["ANTHROPIC_API_KEY", "ANTHROPIC_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no ANTHROPIC_API_KEY set; skipping cache read/write case."
      pure False
    Just (envVar, key) -> do
      let model = Models.anthropic_claude_sonnet_4_6 & #maxOutputTokens .~ 64
          ctx =
            emptyContext
              & #systemPrompt .~ Just bigStablePreamble
              & #messages .~ Vector.singleton (user "Reply with the single word: pong.")
          opts =
            emptyOptions
              & #maxTokens .~ Just 16
              & #temperature .~ Just 0.0
              & #cacheRetention .~ Just CacheRetentionLong
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))

      -- First call seeds the cache.
      firstResp <- completeRequest model ctx opts
      let firstUsage = firstResp ^. #message ^. #usage
          written = firstUsage ^. #cacheWriteTokens
      logUsage "write call" envVar firstUsage

      -- Identical second call should read it back.
      secondResp <- completeRequest model ctx opts
      let secondUsage = secondResp ^. #message ^. #usage
          readBack = secondUsage ^. #cacheReadTokens
      logUsage "read call" envVar secondUsage

      assertCachePositive envVar written readBack
      -- Tokens alone do not prove the money: a rate the catalog left at
      -- zero, or a breakdown that never attributed the cached classes,
      -- would report positive counts and a zero bill. (Note that a
      -- one-hour write is priced at the five-minute rate — see
      -- docs/user/prompt-caching.md.)
      assertCacheCosts
        envVar
        (firstUsage ^. #cost ^. #breakdown ^. #cachedWriteUsd)
        (secondUsage ^. #cost ^. #breakdown ^. #cachedInputUsd)
      pure True

-- | Fail loudly if the cached token classes cost nothing.
assertCacheCosts :: String -> Rational -> Rational -> IO ()
assertCacheCosts envVar writeUsd readUsd = do
  hPutStrLn stderr $
    "[baikai-smoke] cache costs via "
      <> envVar
      <> "; cachedWriteUsd "
      <> show (realToFrac writeUsd :: Double)
      <> ", cachedInputUsd "
      <> show (realToFrac readUsd :: Double)
  when (writeUsd <= 0) $ do
    hPutStrLn
      stderr
      "[baikai-smoke] the write call reported cacheWriteTokens but priced them at zero."
    exitFailure
  when (readUsd <= 0) $ do
    hPutStrLn
      stderr
      "[baikai-smoke] the read call reported cacheReadTokens but priced them at zero."
    exitFailure

-- | Fail loudly if the cache never engaged. A write of zero means the
-- prefix fell under the provider's cacheable floor (or the marker
-- never reached the host); a read of zero means the second call did not
-- reuse the seeded prefix.
assertCachePositive :: String -> Natural -> Natural -> IO ()
assertCachePositive envVar written readBack = do
  case (written > 0, readBack > 0) of
    (True, True) ->
      hPutStrLn stderr $
        "[baikai-smoke] cache read/write ok via "
          <> envVar
          <> "; wrote "
          <> show written
          <> " tokens, read "
          <> show readBack
          <> " tokens"
    (False, _) -> do
      hPutStrLn stderr $
        "[baikai-smoke] cache read/write via "
          <> envVar
          <> " reported no cacheWriteTokens on the first call; caching did not engage."
      exitFailure
    (True, False) -> do
      hPutStrLn stderr $
        "[baikai-smoke] cache read/write via "
          <> envVar
          <> " wrote "
          <> show written
          <> " tokens but the second call reported no cacheReadTokens."
      exitFailure

logUsage :: String -> String -> Usage -> IO ()
logUsage label envVar u =
  hPutStrLn stderr $
    "[baikai-smoke] cache "
      <> label
      <> " via "
      <> envVar
      <> ": input="
      <> show (u ^. #inputTokens)
      <> " cacheWrite="
      <> show (u ^. #cacheWriteTokens)
      <> " cacheRead="
      <> show (u ^. #cacheReadTokens)
      <> " total="
      <> show (u ^. #totalTokens)

-- | A prefix comfortably above Anthropic's minimum cacheable size,
-- generated deterministically so it is identical on every call.
bigStablePreamble :: Text
bigStablePreamble =
  Text.intercalate
    " "
    [ "Section "
        <> Text.pack (show i)
        <> ": You are a terse assistant. Follow instructions exactly and answer with a single word when asked."
    | i <- [1 :: Int .. 220]
    ]

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing
