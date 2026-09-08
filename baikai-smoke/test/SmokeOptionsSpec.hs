module Main (main) where

import Control.Monad (unless)
import SmokeOptions

main :: IO ()
main = do
  check "ordinary mode" (parseSmokeOptions [] == Right (SmokeOptions False False))
  check "focused required mode" (parseSmokeOptions ["--new-models", "--require-keys"] == Right (SmokeOptions True True))
  check "reversed flags" (parseSmokeOptions ["--require-keys", "--new-models"] == Right (SmokeOptions True True))
  check "required ordinary mode" (parseSmokeOptions ["--require-keys"] == Right (SmokeOptions False True))
  check "reject unknown option" (case parseSmokeOptions ["--new-model"] of Left _ -> True; _ -> False)
  let groups = [["OPENAI_KEY", "OPENAI_API_KEY"], ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]]
  check "absent credentials" (missingKeys [] groups == groups)
  check "empty credentials" (missingKeys [("OPENAI_KEY", Just ""), ("ANTHROPIC_KEY", Nothing)] groups == groups)
  check "fallback keys accepted" (null (missingKeys [("OPENAI_API_KEY", Just "synthetic"), ("ANTHROPIC_API_KEY", Just "synthetic")] groups))
  check "one missing provider" (missingKeys [("OPENAI_KEY", Just "synthetic")] groups == [last groups])
  putStrLn "9 smoke option and credential checks passed (no environment access)."
  where
    check label ok = unless ok (fail label)
