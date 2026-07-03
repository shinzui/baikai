module Main (main) where

import Baikai
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.Claude.Cli qualified as ClaudeCli
import Baikai.Provider.OpenAI.Api qualified as OpenAIApi
import Baikai.Provider.OpenAI.Cli qualified as CodexCli
import Control.Lens ((&), (.~), (^.))
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Foldable (find)
import Data.Generics.Labels ()
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import InteractiveSmoke qualified
import MultiHostSmoke qualified
import Streamly.Data.Stream qualified as Stream
import StructuredSmoke qualified
import System.Directory (findExecutable)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import ToolsSmoke qualified

main :: IO ()
main = do
  ClaudeApi.register
  OpenAIApi.register
  ClaudeCli.register
  CodexCli.register
  hadApi <- mapM runApiCase apiCases
  hadStream <- mapM runStreamCase apiCases
  hadCli <- mapM runCliCase cliCases
  hadInteractiveCliHelp <- InteractiveSmoke.runInteractiveHelpCases
  hadImage <- runImageCase
  hadTools <- mapM runToolCase apiCases
  hadStructured <- mapM runStructuredCase apiCases
  hadMultiHost <- MultiHostSmoke.runMultiHostCase
  unless
    ( or hadApi
        || or hadStream
        || or hadCli
        || hadInteractiveCliHelp
        || hadImage
        || or hadTools
        || or hadStructured
        || hadMultiHost
    )
    $ hPutStrLn
      stderr
      "[baikai-smoke] no provider keys or CLI binaries available; skipping all cases."

runToolCase :: ApiCase -> IO Bool
runToolCase ApiCase {caseLabel, caseEnvVars, caseModel} =
  ToolsSmoke.runToolCase
    ToolsSmoke.ApiCase
      { ToolsSmoke.caseLabel = caseLabel,
        ToolsSmoke.caseEnvVars = caseEnvVars,
        ToolsSmoke.caseModel = caseModel
      }

runStructuredCase :: ApiCase -> IO Bool
runStructuredCase ApiCase {caseLabel, caseEnvVars, caseModel} =
  StructuredSmoke.runStructuredCase
    StructuredSmoke.ApiCase
      { StructuredSmoke.caseLabel = caseLabel,
        StructuredSmoke.caseEnvVars = caseEnvVars,
        StructuredSmoke.caseModel = caseModel
      }

-- | An API smoke case: matching env-var candidates for the key, the
-- model record to dispatch under, and a label.
data ApiCase = ApiCase
  { caseLabel :: !String,
    caseEnvVars :: ![String],
    caseModel :: !Model
  }

apiCases :: [ApiCase]
apiCases =
  [ ApiCase
      { caseLabel = "claude-haiku-4-5-20251001",
        caseEnvVars = ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"],
        caseModel =
          Models.anthropic_claude_haiku_4_5
            & #maxOutputTokens .~ 1024
      },
    ApiCase
      { caseLabel = "gpt-4o-mini",
        caseEnvVars = ["OPENAI_KEY", "OPENAI_API_KEY"],
        caseModel =
          Models.openai_gpt_4o_mini & #maxOutputTokens .~ 1024
      }
  ]

sampleContext :: Context
sampleContext =
  _Context
    & #systemPrompt .~ Just "You are terse."
    & #messages .~ Vector.singleton (user "Reply with the single word: pong.")

runApiCase :: ApiCase -> IO Bool
runApiCase ApiCase {caseLabel, caseEnvVars, caseModel} = do
  matched <- firstSetEnv caseEnvVars
  case matched of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] none of "
          <> show caseEnvVars
          <> " set; skipping "
          <> caseLabel
          <> "."
      pure False
    Just (envVar, key) -> do
      let opts =
            _Options
              & #maxTokens .~ Just 16
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp <- completeRequest caseModel sampleContext opts
      let blocks = flattenAssistantBlocks resp
          flat = flattenAssistantText blocks
          contentOk = not (Text.null flat)
          u = (resp ^. #message) ^. #usage
          uOk = (u ^. #inputTokens) > 0 && (u ^. #outputTokens) > 0
      when (not contentOk || not uOk) $ do
        hPutStrLn stderr $ "[baikai-smoke] failed for " <> caseLabel <> "."
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> caseLabel
          <> " ok via "
          <> envVar
          <> "; "
          <> show (Vector.length blocks)
          <> " block(s); usage tokens > 0"
      pure True

-- | Streaming smoke: subscribe to 'streamRequest' for a given API
-- case, fold the event stream into a list, and assert (a) at least
-- one 'TextDelta' was emitted before the terminal event, (b) the
-- terminal event is 'EventDone' with @stopReason = Stop@, (c) the
-- terminal message's 'Usage' has non-zero @inputTokens@ +
-- @outputTokens@.
runStreamCase :: ApiCase -> IO Bool
runStreamCase ApiCase {caseLabel, caseEnvVars, caseModel} = do
  matched <- firstSetEnv caseEnvVars
  case matched of
    Nothing -> pure False
    Just (envVar, key) -> do
      let opts =
            _Options
              & #maxTokens .~ Just 32
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      events <- Stream.toList (streamRequest caseModel sampleContext opts)
      let textDeltas =
            [ d
            | TextDelta (DeltaPayload _ d) <- events
            ]
          textOk = not (null textDeltas)
          terminalOk = case lastMay events of
            Just (EventDone TerminalPayload {reason = Stop, message = msg}) -> usageNonZero msg
            _ -> False
      when (not textOk || not terminalOk) $ do
        hPutStrLn stderr $
          "[baikai-smoke] streaming failed for "
            <> caseLabel
            <> " via "
            <> envVar
            <> "; deltas="
            <> show (length textDeltas)
            <> " terminal_ok="
            <> show terminalOk
        exitFailure
      hPutStrLn stderr $
        "[baikai-smoke] streaming "
          <> caseLabel
          <> " ok via "
          <> envVar
          <> "; "
          <> show (length textDeltas)
          <> " TextDelta event(s)"
      pure True

lastMay :: [a] -> Maybe a
lastMay [] = Nothing
lastMay xs = Just (last xs)

usageNonZero :: Message -> Bool
usageNonZero = \case
  AssistantMessage AssistantPayload {usage = u} ->
    (u ^. #inputTokens) > 0 && (u ^. #outputTokens) > 0
  _ -> False

firstSetEnv :: [String] -> IO (Maybe (String, String))
firstSetEnv vars = do
  results <- traverse (\v -> fmap (\m -> (v, m)) (lookupEnv v)) vars
  pure $ case find (\(_, m) -> isJust m) results of
    Just (v, Just val) -> Just (v, val)
    _ -> Nothing

-- | A CLI smoke case: the binary on PATH, the model dispatched
-- (typed under the CLI's API tag), and a label.
data CliCase = CliCase
  { cliLabel :: !String,
    cliBinary :: !String,
    cliModel :: !Model
  }

cliCases :: [CliCase]
cliCases =
  [ CliCase
      { cliLabel = "sonnet",
        cliBinary = "claude",
        cliModel =
          _Model
            & #modelId .~ "sonnet"
            & #api .~ AnthropicMessagesCli
            & #provider .~ "anthropic"
      },
    CliCase
      { cliLabel = "<codex-default>",
        cliBinary = "codex",
        cliModel =
          _Model
            & #modelId .~ ""
            & #api .~ OpenAICompletionsCli
            & #provider .~ "openai"
      }
  ]

runCliCase :: CliCase -> IO Bool
runCliCase CliCase {cliLabel, cliBinary, cliModel} = do
  found <- findExecutable cliBinary
  case found of
    Nothing -> do
      hPutStrLn stderr $
        "[baikai-smoke] "
          <> cliBinary
          <> " not on PATH; skipping "
          <> cliLabel
          <> "."
      pure False
    Just path -> do
      resp <- completeRequest cliModel sampleContext _Options
      let blocks = flattenAssistantBlocks resp
          flat = flattenAssistantText blocks
          contentOk = not (Text.null flat)
          u = (resp ^. #message) ^. #usage
          usageZero = (u ^. #inputTokens) == 0 && (u ^. #outputTokens) == 0
          latencyOk = resp ^. #latencyMs > 0
      when (not contentOk || not usageZero || not latencyOk) $ do
        hPutStrLn stderr $
          "[baikai-smoke] failed for "
            <> cliLabel
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
          <> cliLabel
          <> " ok via "
          <> path
          <> "; latency_ms = "
          <> show (resp ^. #latencyMs)
      pure True

-- | Send a user message with an inline image to Claude and assert
-- that the response carries at least one assistant text block.
runImageCase :: IO Bool
runImageCase = do
  matched <- firstSetEnv ["ANTHROPIC_KEY", "ANTHROPIC_API_KEY"]
  case matched of
    Nothing -> do
      hPutStrLn stderr "[baikai-smoke] no Anthropic key; skipping image content-block case."
      pure False
    Just (_envVar, key) -> do
      let img =
            ImageContent
              { imageData = dotPngBytes,
                mimeType = "image/png"
              }
          model =
            Models.anthropic_claude_haiku_4_5
              & #maxOutputTokens .~ 64
          ctx =
            _Context
              & #systemPrompt .~ Just "Reply in one word."
              & #messages
                .~ Vector.singleton
                  (userImage img (Just "What single colour is this image?"))
          opts =
            _Options
              & #maxTokens .~ Just 64
              & #temperature .~ Just 0.0
              & #apiKey .~ Just (ApiKeyLiteral (Text.pack key))
      resp <- completeRequest model ctx opts
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

-- | A 1×1 transparent PNG, base64-encoded inline so the smoke test
-- ships no binary data files.
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
