-- | Provider that drives the @claude -p@ non-interactive CLI as a
-- subprocess.
--
-- Call 'register' once (typically from @main@) to install the
-- 'Baikai.Api.AnthropicMessagesCli' handler with default config.
-- For non-default executable paths or extra args, use 'registerWith'
-- and supply a custom 'ClaudeCliConfig'.
--
-- The CLI provider always returns a 'Response' whose embedded
-- assistant message carries zero token counts (and therefore zero
-- cost): the @claude@ CLI runs under a flat subscription, so
-- per-token billing does not apply. CLI providers do not participate
-- in tool calling — the masterplan's Decision Log records the
-- reasoning.
module Baikai.Provider.Claude.Cli
  ( ClaudeCliConfig (..),
    claudeCliCommand,
    defaultClaudeCliConfig,
    register,
    registerWith,
    registerWithRegistry,
    registerWithRegistryAndConfig,
  )
where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), TextContent (..))
import Baikai.Context (Context (..))
import Baikai.Error (decodeError, processError, providerError)
import Baikai.Message (AssistantPayload (..))
import Baikai.Model (Model)
import Baikai.Options (Options)
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.Provider.Registry
  ( ApiProvider (..),
    ProviderRegistry,
    globalProviderRegistry,
    registerApiProviderWith,
  )
import Baikai.Response qualified as Resp
import Baikai.StopReason (StopReason (..))
import Baikai.Stream (liftCompleteToStream)
import Baikai.Usage (_Usage)
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Cradle
  ( ExitCode (..),
    StderrRaw (..),
    StdoutRaw (..),
    addArgs,
    cmd,
    run,
    setNoStdin,
    setWorkingDir,
  )
import Data.Aeson (FromJSON, Value (..), eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither, parseJSON)
import Data.ByteString (ByteString)
import Data.Function ((&))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import GHC.Generics (Generic)

-- | Configuration for the @claude -p@ subprocess.
data ClaudeCliConfig = ClaudeCliConfig
  { executable :: !FilePath,
    extraArgs :: !(Vector Text),
    workingDir :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeCliConfig :: ClaudeCliConfig
defaultClaudeCliConfig =
  ClaudeCliConfig
    { executable = "claude",
      extraArgs = mempty,
      workingDir = Nothing
    }

-- | Install the CLI handler with 'defaultClaudeCliConfig'.
register :: IO ()
register = registerWith defaultClaudeCliConfig

-- | Install the CLI handler with a caller-supplied config.
--
-- The CLI binary runs in batch mode; there is no intra-response
-- streaming on the wire. The 'stream' field therefore wraps the
-- batch 'runClaudeCli' through 'liftCompleteToStream', producing a
-- synthetic one-shot event stream
-- (@EventStart, TextStart 0, TextDelta 0 body, TextEnd 0, EventDone@)
-- the moment the subprocess returns. 'complete' is left as the
-- direct batch path so it preserves 'Response.responseId' and the
-- measured 'Response.latencyMs' (going through a
-- 'streamingComplete' round trip would lose the former and recompute
-- the latter from synthetic events). EP-3's Decision Log explains
-- the deviation from the plan's "complete = streamingComplete .
-- stream" default.
registerWith :: ClaudeCliConfig -> IO ()
registerWith = registerWithRegistryAndConfig globalProviderRegistry

-- | Install the CLI handler with 'defaultClaudeCliConfig' into an explicit
-- registry.
registerWithRegistry :: ProviderRegistry -> IO ()
registerWithRegistry reg = registerWithRegistryAndConfig reg defaultClaudeCliConfig

-- | Install the CLI handler with a caller-supplied config into an explicit
-- registry.
registerWithRegistryAndConfig :: ProviderRegistry -> ClaudeCliConfig -> IO ()
registerWithRegistryAndConfig reg cfg =
  registerApiProviderWith
    reg
    ApiProvider
      { apiTag = AnthropicMessagesCli,
        stream = liftCompleteToStream (runClaudeCli cfg),
        complete = runClaudeCli cfg
      }

-- | Render the executable and arguments for a @claude -p@ batch call.
-- The prompt is preceded by @--@ so dash-leading prompts and variadic
-- flags in 'extraArgs' cannot be parsed as options.
claudeCliCommand :: ClaudeCliConfig -> Model -> Context -> (FilePath, [String])
claudeCliCommand cfg m ctx =
  ( cfg ^. #executable,
    ["-p"]
      <> modelArgs m
      <> ["--output-format", "json", "--no-session-persistence"]
      <> systemPromptArgs ctx
      <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
      <> ["--", Text.unpack (Internal.renderPrompt ctx)]
  )

-- | The shape of @claude -p --output-format json@ stdout.
data ClaudeCliResult = ClaudeCliResult
  { result :: !Text,
    is_error :: !Bool,
    session_id :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

systemPromptArgs :: Context -> [String]
systemPromptArgs ctx = case ctx ^. #systemPrompt of
  Nothing -> []
  Just sp -> ["--system-prompt", Text.unpack sp]

modelArgs :: Model -> [String]
modelArgs m = case Text.strip (m ^. #modelId) of
  "" -> []
  mid -> ["--model", Text.unpack mid]

decodeResult :: ByteString -> IO ClaudeCliResult
decodeResult bs = case eitherDecodeStrict bs of
  Left err -> throwIO (decodeError (Text.pack err))
  Right (Aeson.Array events) -> case findResultEvent events of
    Nothing -> throwIO (decodeError "claude -p: no result event in stdout array")
    Just ev -> case parseEither parseJSON ev of
      Left err -> throwIO (decodeError (Text.pack err))
      Right r -> pure r
  Right v@(Aeson.Object _) -> case parseEither parseJSON v of
    Left err -> throwIO (decodeError (Text.pack err))
    Right r -> pure r
  Right _ -> throwIO (decodeError "claude -p: expected JSON object or array")

findResultEvent :: Vector Value -> Maybe Value
findResultEvent = Vector.find isResult
  where
    isResult (Aeson.Object o) = case KeyMap.lookup "type" o of
      Just (Aeson.String "result") -> True
      _ -> False
    isResult _ = False

runClaudeCli :: ClaudeCliConfig -> Model -> Context -> Options -> IO Resp.Response
runClaudeCli cfg m ctx _opts = do
  let (exe, args) = claudeCliCommand cfg m ctx
  start <- getCurrentTime
  (exitCode, StdoutRaw out, StderrRaw err) <-
    run $
      cmd exe
        & addArgs args
        & setNoStdin
        & Internal.maybeApply (cfg ^. #workingDir) setWorkingDir
  end <- getCurrentTime
  case exitCode of
    ExitFailure n -> throwIO (processError n (Internal.decodeUtf8Lenient err))
    ExitSuccess -> do
      r <- decodeResult out
      if is_error r
        then throwIO (providerError (result r))
        else pure (mkResponse m start end (result r))

mkResponse :: Model -> UTCTime -> UTCTime -> Text -> Resp.Response
mkResponse m start end body =
  Resp.Response
    { Resp.message =
        AssistantPayload
          { content = Vector.singleton (AssistantText (TextContent body)),
            usage = _Usage,
            stopReason = Stop,
            errorMessage = Nothing,
            timestamp = end
          },
      Resp.model = m,
      Resp.api = AnthropicMessagesCli,
      Resp.provider = m ^. #provider,
      Resp.responseId = Nothing,
      Resp.latencyMs = millisBetween start end,
      Resp.errorInfo = Nothing
    }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
