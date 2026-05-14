module Main (main) where

import Baikai.Auth (ApiKeySource (..))
import Baikai.Content
  ( AssistantContent (..)
  , ImageContent (..)
  , TextContent (..)
  )
import Baikai.Message (Message (..), user, userImage)
import Baikai.Model (Model (..))
import Baikai.Provider (runRequest)
import Baikai.Provider.Claude.Api (claudeApi)
import Baikai.Provider.Claude.Cli (claudeCli, defaultClaudeCliConfig)
import Baikai.Provider.OpenAI.Api (openaiApi)
import Baikai.Provider.OpenAI.Cli (codexCli, defaultCodexCliConfig)
import Baikai.Request qualified as Req
import Baikai.Response (Response, flattenAssistantBlocks)
import Baikai.Usage qualified as Usage
import Control.Lens ((^.))
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  hadApi <- mapM runCase cases
  hadCli <- mapM runCliCase cliCases
  hadImage <- runImageCase
  unless (or hadApi || or hadCli || hadImage) $
    hPutStrLn stderr "[baikai-smoke] no provider keys or CLI binaries available; skipping all cases."

-- (env-var candidates, model, action factory taking the env var that matched)
cases :: [([String], String, String -> IO Response)]
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

runCase :: ([String], String, String -> IO Response) -> IO Bool
runCase (envVars, modelName, mkAct) = do
  matched <- firstSetEnv envVars
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of " <> show envVars <> " set; skipping " <> modelName <> "."
      pure False
    Just envVar -> do
      resp <- mkAct envVar
      let blocks = flattenAssistantBlocks resp
          flat = flattenAssistantText blocks
          contentOk = not (Text.null flat)
          uOk = case resp ^. #message of
            AssistantMessage {usage = u} ->
              Usage.inputTokens u > 0 && Usage.outputTokens u > 0
            _ -> False
      when (not contentOk || not uOk) $ do
        hPutStrLn stderr $ "[baikai-smoke] failed for " <> modelName <> "."
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] " <> modelName <> " ok via " <> envVar
          <> "; " <> show (Vector.length blocks) <> " block(s); usage tokens > 0"
      pure True

firstSetEnv :: [String] -> IO (Maybe String)
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure (fst <$> find (\(_, m) -> isJust m) results)

-- (binary on PATH, model alias, action factory)
cliCases :: [(String, String, IO Response)]
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
        p <- codexCli defaultCodexCliConfig
        runRequest p (sampleRequest "")
    )
  ]

runCliCase :: (String, String, IO Response) -> IO Bool
runCliCase (binary, modelName, act) = do
  found <- findExecutable binary
  case found of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] " <> binary <> " not on PATH; skipping " <> modelName <> "."
      pure False
    Just path -> do
      resp <- act
      let blocks = flattenAssistantBlocks resp
          flat = flattenAssistantText blocks
          contentOk = not (Text.null flat)
          usageZero = case resp ^. #message of
            AssistantMessage {usage = u} ->
              Usage.inputTokens u == 0 && Usage.outputTokens u == 0
            _ -> False
          latencyOk = resp ^. #latencyMs > 0
      when (not contentOk || not usageZero || not latencyOk) $ do
        hPutStrLn stderr $
          "[baikai-smoke] failed for "
            <> modelName
            <> " via "
            <> path
            <> "; content_nonempty="
            <> show contentOk
            <> " usage_zero="
            <> show usageZero
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

-- | Send a user message with an inline image to Claude and assert that
-- the response carries at least one assistant text block. Skips when
-- no Anthropic key is available.
runImageCase :: IO Bool
runImageCase = do
  matched <- firstSetEnv ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no Anthropic key; skipping image content-block case."
      pure False
    Just envVar -> do
      p <- claudeApi (ApiKeyEnv envVar)
      let img =
            ImageContent
              { imageData = dotPngBytes
              , mimeType = "image/png"
              }
          req =
            Req._Request
              { Req.model = Model "claude-haiku-4-5-20251001"
              , Req.messages =
                  Vector.singleton
                    (userImage img (Just "What single colour is this image?"))
              , Req.maxTokens = 64
              , Req.temperature = Just 0.0
              , Req.systemPrompt = Just "Reply in one word."
              }
      resp <- runRequest p req
      let blocks = flattenAssistantBlocks resp
          hasText = any isText (Vector.toList blocks)
      when (not hasText) $ do
        hPutStrLn stderr "[baikai-smoke] image case: response had no AssistantText."
        exitFailure
      hPutStrLn stderr "[baikai-smoke] image content-block case ok via Claude."
      pure True
  where
    isText (AssistantText _) = True
    isText _ = False

-- | A 1×1 transparent PNG. Generated from @python -c "import sys; sys.stdout.buffer.write(b'\\x89PNG\\r\\n\\x1a\\n...')"@
-- and base64-encoded inline so the smoke test ships no binary data files.
dotPngBytes :: BS.ByteString
dotPngBytes = case Base64.decode dotPngBase64 of
  Left err -> error ("dotPngBytes: invalid base64: " <> err)
  Right bs -> bs

dotPngBase64 :: BS.ByteString
dotPngBase64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

flattenAssistantText :: Vector.Vector AssistantContent -> Text
flattenAssistantText =
  Text.concat
    . Vector.toList
    . Vector.mapMaybe
      ( \b -> case b of
          AssistantText (TextContent t) -> Just t
          _ -> Nothing
      )

sampleRequest :: Text -> Req.Request
sampleRequest m =
  Req.Request
    { Req.model = Model m
    , Req.messages = Vector.singleton (user "Reply with the single word: pong.")
    , Req.maxTokens = 16
    , Req.temperature = Just 0.0
    , Req.systemPrompt = Just "You are terse."
    }

