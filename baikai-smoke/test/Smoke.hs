module Main (main) where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Message (Message (..), Role (..))
import Baikai.Model (Model (..))
import Baikai.Provider (runRequest)
import Baikai.Provider.Claude.Api (claudeApi)
import Baikai.Provider.Claude.Cli (claudeCli, defaultClaudeCliConfig)
import Baikai.Provider.OpenAI.Api (openaiApi)
import Baikai.Provider.OpenAI.Cli (codexCli, defaultCodexCliConfig)
import qualified Baikai.Request as Req
import qualified Baikai.Response as Resp
import Control.Lens ((^.))
import Control.Monad (unless, when)
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  hadAny <- mapM runCase cases
  hadCli <- mapM runCliCase cliCases
  unless (or hadAny || or hadCli) $
    hPutStrLn stderr "[baikai-smoke] no provider keys or CLI binaries available; skipping all cases."

-- (env-var candidates, model, action factory taking the env var that matched)
cases :: [([String], String, String -> IO Resp.Response)]
cases =
  [
    ( ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
    , "claude-haiku-4-5-20251001"
    , \envVar -> do
        p <- claudeApi (ApiKeyEnv envVar)
        runRequest p (sampleRequest "claude-haiku-4-5-20251001")
    )
  ,
    ( ["OPENAI_KEY", "OPENAI_API_KEY"]
    , "gpt-4o-mini"
    , \envVar -> do
        p <- openaiApi (ApiKeyEnv envVar)
        runRequest p (sampleRequest "gpt-4o-mini")
    )
  ]

runCase :: ([String], String, String -> IO Resp.Response) -> IO Bool
runCase (envVars, modelName, mkAct) = do
  matched <- firstSetEnv envVars
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of " <> show envVars <> " set; skipping " <> modelName <> "."
      pure False
    Just envVar -> do
      resp <- mkAct envVar
      let contentOk = not (Text.null (resp ^. #content))
          uOk = case resp ^. #usage of
            Nothing -> False
            Just u -> u ^. #inputTokens > 0 && u ^. #outputTokens > 0
      when (not contentOk || not uOk) $ do
        hPutStrLn stderr $ "[baikai-smoke] failed for " <> modelName <> "."
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] " <> modelName <> " ok via " <> envVar <> "; usage present = "
          <> show (isJust (resp ^. #usage))
      pure True

firstSetEnv :: [String] -> IO (Maybe String)
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure (fst <$> find (\(_, m) -> isJust m) results)

-- (binary on PATH, model alias, action factory)
cliCases :: [(String, String, IO Resp.Response)]
cliCases =
  [
    ( "claude"
    , "sonnet"
    , do
        p <- claudeCli defaultClaudeCliConfig
        runRequest p (sampleRequest "sonnet")
    )
  ,
    ( "codex"
    , "<codex-default>"
    , do
        -- Empty model => let the codex CLI pick whatever its default is.
        -- ChatGPT-account installations don't expose names like "gpt-5",
        -- so we don't try to guess one; the binary's own default is the
        -- only string we know will work across accounts.
        p <- codexCli defaultCodexCliConfig
        runRequest p (sampleRequest "")
    )
  ]

runCliCase :: (String, String, IO Resp.Response) -> IO Bool
runCliCase (binary, modelName, act) = do
  found <- findExecutable binary
  case found of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] " <> binary <> " not on PATH; skipping " <> modelName <> "."
      pure False
    Just path -> do
      resp <- act
      let contentOk = not (Text.null (resp ^. #content))
          noUsage = isNothing' (resp ^. #usage)
          noCost = isNothing' (resp ^. #cost)
          latencyOk = resp ^. #latencyMs > 0
      when (not contentOk || not noUsage || not noCost || not latencyOk) $ do
        hPutStrLn stderr $
          "[baikai-smoke] failed for "
            <> modelName
            <> " via "
            <> path
            <> "; content_nonempty="
            <> show contentOk
            <> " usage_nothing="
            <> show noUsage
            <> " cost_nothing="
            <> show noCost
            <> " latency_positive="
            <> show latencyOk
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> modelName
          <> " ok via "
          <> path
          <> "; latency_ms = "
          <> show (resp ^. #latencyMs)
      pure True
  where
    isNothing' Nothing = True
    isNothing' Just {} = False

sampleRequest :: Text.Text -> Req.Request
sampleRequest m =
  Req.Request
    { Req.model = Model m
    , Req.messages =
        Vector.singleton
          Message
            { role = User
            , content = "Reply with the single word: pong."
            }
    , Req.maxTokens = 16
    , Req.temperature = Just 0.0
    , Req.systemPrompt = Just "You are terse."
    }
