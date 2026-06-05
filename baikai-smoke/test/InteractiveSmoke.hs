-- | Non-authenticated smoke checks for interactive CLI launch support.
--
-- These checks do not start an interactive session. They only verify
-- that locally installed CLI binaries expose the flags Baikai's
-- interactive command builders render.
module InteractiveSmoke
  ( runInteractiveHelpCases,
  )
where

import Control.Monad (when)
import Data.List (isInfixOf)
import System.Directory (findExecutable)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

runInteractiveHelpCases :: IO Bool
runInteractiveHelpCases = do
  claudeRan <- runHelpCase claudeCase
  codexRan <- runHelpCase codexCase
  pure (claudeRan || codexRan)

data HelpCase = HelpCase
  { label :: !String,
    binary :: !String,
    requiredNeedles :: ![String]
  }

claudeCase :: HelpCase
claudeCase =
  HelpCase
    { label = "claude interactive flags",
      binary = "claude",
      requiredNeedles =
        [ "--model",
          "--system-prompt",
          "--add-dir",
          "--allowedTools"
        ]
    }

codexCase :: HelpCase
codexCase =
  HelpCase
    { label = "codex interactive flags",
      binary = "codex",
      requiredNeedles =
        [ "--model",
          "--cd",
          "--add-dir",
          "--sandbox",
          "--ask-for-approval"
        ]
    }

runHelpCase :: HelpCase -> IO Bool
runHelpCase HelpCase {label, binary, requiredNeedles} = do
  found <- findExecutable binary
  case found of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> binary
          <> " not on PATH; skipping "
          <> label
          <> "."
      pure False
    Just path -> do
      (code, out, err) <- readProcessWithExitCode path ["--help"] ""
      let helpText = out <> err
          missing = filter (`notElemInfix` helpText) requiredNeedles
      when (code /= ExitSuccess || not (null missing)) $ do
        hPutStrLn stderr $
          "[baikai-smoke] "
            <> label
            <> " failed for "
            <> path
            <> "; exit="
            <> show code
            <> "; missing="
            <> show missing
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> label
          <> " ok via "
          <> path
          <> "."
      pure True

notElemInfix :: String -> String -> Bool
notElemInfix needle haystack = not (needle `isInfixOf` haystack)
