module Main (main) where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Message (Message (..), Role (..))
import Baikai.Model (Model (..))
import Baikai.Provider (runRequest)
import Baikai.Provider.Claude.Api (claudeApi)
import Baikai.Provider.OpenAI.Api (openaiApi)
import qualified Baikai.Request as Req
import qualified Baikai.Response as Resp
import Control.Lens ((^.))
import Control.Monad (unless, when)
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  hadAny <- mapM runCase cases
  unless (or hadAny) $
    hPutStrLn stderr "[baikai-smoke] no provider keys set; skipping all cases."

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
