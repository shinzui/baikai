module Main (main) where

import Control.Monad (forM_, unless)
import SmokeOptions

main :: IO ()
main = do
  check "ordinary mode" (parseSmokeOptions [] == Right (SmokeOptions False False Nothing))
  check "focused required mode" (parseSmokeOptions ["--new-models", "--require-keys"] == Right (SmokeOptions True True Nothing))
  check "reversed flags" (parseSmokeOptions ["--require-keys", "--new-models"] == Right (SmokeOptions True True Nothing))
  check "required ordinary mode" (parseSmokeOptions ["--require-keys"] == Right (SmokeOptions False True Nothing))
  check "reject unknown option" (case parseSmokeOptions ["--new-model"] of Left _ -> True; _ -> False)
  check "named case" (parseSmokeOptions ["--new-models", "--case", "astra-tools"] == Right (SmokeOptions True False (Just "astra-tools")))
  check "ten unique cases" (length caseNames == 10 && length (filter (`elem` caseNames) ["sol-text", "sol-tools", "luna-text", "luna-tools", "opus55-text", "opus55-tools"]) == 6)
  forM_ caseNames $ \name -> do
    check (name <> " selected alone") (parseSmokeOptions ["--new-models", "--require-keys", "--case", name] == Right (SmokeOptions True True (Just name)))
    check (name <> " excludes other cases") (selectCaseNames (Just name) == [name])
    let expected = if name `elem` ["fable-text", "fable-tools", "opus55-text", "opus55-tools"] then Just "anthropic" else Just "openai"
    check (name <> " credential group") (caseProvider name == expected)
  check "case needs focused mode" (case parseSmokeOptions ["--case", "astra-tools"] of Left _ -> True; _ -> False)
  check "unknown case rejected" (case parseSmokeOptions ["--new-models", "--case", "typo"] of Left _ -> True; _ -> False)
  let openaiKeys = ["OPENAI_KEY", "OPENAI_API_KEY"]
      anthropicKeys = ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
      groups = [openaiKeys, anthropicKeys]
  check "absent credentials" (missingKeys [] groups == groups)
  check "empty credentials" (missingKeys [("OPENAI_KEY", Just ""), ("ANTHROPIC_KEY", Nothing)] groups == groups)
  check "fallback keys accepted" (null (missingKeys [("OPENAI_API_KEY", Just "synthetic"), ("ANTHROPIC_API_KEY", Just "synthetic")] groups))
  check "one missing provider" (missingKeys [("OPENAI_KEY", Just "synthetic")] groups == [last groups])
  forM_ caseNames $ \name -> do
    let (key, keys) = if caseProvider name == Just "openai" then ("OPENAI_KEY", openaiKeys) else ("ANTHROPIC_KEY", anthropicKeys)
    check (name <> " requires only its provider") (null (missingKeys [(key, Just "synthetic")] [keys]))
    check (name <> " missing key fails preflight") (missingKeys [] [keys] == [keys])
  putStrLn "all smoke option and credential checks passed (no environment access)."
  where
    check label ok = unless ok (fail label)
