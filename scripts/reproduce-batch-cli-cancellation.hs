{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- Offline negative reproduction of BUG-1. Success means the child survived
-- the cancellation request, not that cancellation cleanup worked.
-- The fixture signals only its own recorded child and parent PIDs.
module Main where

import Baikai
import Baikai.Model qualified as Model
import Baikai.Provider.Claude.Cli qualified as Claude
import Baikai.Provider.OpenAI.Cli qualified as Codex
import Control.Concurrent
import Control.Exception
import Control.Lens ((^.))
import Control.Monad
import System.Directory
import System.Exit
import System.FilePath
import System.IO.Temp
import System.Process
import System.Timeout

main :: IO ()
main = mapM_ probe [AnthropicMessagesCli, OpenAICompletionsCli]

probe :: Api -> IO ()
probe apiTag = withSystemTempDirectory "baikai-batch-validation" $ \dir -> do
  let exe = dir </> "vendor"
      model = emptyModel {Model.api = apiTag, Model.provider = "fake", Model.modelId = "fake"}
      provider =
        if apiTag == AnthropicMessagesCli
          then Claude.claudeCliProvider (Claude.defaultClaudeCliConfig {Claude.executable = exe, Claude.workingDir = Just dir})
          else Codex.codexCliProvider (Codex.defaultCodexCliConfig {Codex.executable = exe, Codex.workingDir = Just dir})
  writeFile exe "#!/bin/sh\nsleep 5 &\necho $! > child\necho $$ > parent\nwait\n"
  permissions <- getPermissions exe
  setPermissions exe (setOwnerExecutable True permissions)
  finished <- newEmptyMVar
  worker <- forkIO $ do
    result <- try ((provider ^. #complete) model emptyContext emptyOptions) :: IO (Either SomeException Response)
    putMVar finished (either (\e -> if isAsync e then "async" else "sync") (const "response") result)
  let readPid name = takeWhile (/= '\n') <$> readFile (dir </> name)
      waitReady = do
        ready <- doesFileExist (dir </> "parent")
        if ready then pure () else threadDelay 10000 >> waitReady
      cleanup = do
        forM_ ["child", "parent"] $ \name -> do
          exists <- doesFileExist (dir </> name)
          when exists $ do
            pid <- readPid name
            void (readProcessWithExitCode "/bin/kill" ["-TERM", pid] "")
        done <- timeout 6000000 (takeMVar finished)
        putStrLn (show apiTag <> " worker_after_fixture_cleanup=" <> show done)
  flip finally cleanup $ do
    ready <- timeout 2000000 waitReady
    unless (ready == Just ()) (error "fixture did not start")
    void (forkIO (killThread worker))
    threadDelay 200000
    pid <- readPid "child"
    (code, _, _) <- readProcessWithExitCode "/bin/kill" ["-0", pid] ""
    pending <- isEmptyMVar finished
    putStrLn (show apiTag <> " child_alive_200ms=" <> show (code == ExitSuccess) <> " worker_pending=" <> show pending)
    unless (code == ExitSuccess) (error "reported defect did not reproduce")
  where
    isAsync e = case fromException e :: Maybe SomeAsyncException of
      Just _ -> True
      Nothing -> False
