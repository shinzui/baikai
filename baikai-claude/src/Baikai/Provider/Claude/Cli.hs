-- | Provider that drives the @claude -p@ non-interactive CLI as a subprocess.
--
-- Construct a 'ClaudeCli' with 'claudeCli' and the desired 'ClaudeCliConfig'
-- (or just 'defaultClaudeCliConfig'), then call 'Baikai.Provider.runRequest'
-- like any other provider. The provider name is @"anthropic.claude.cli"@.
--
-- The provider always returns 'Baikai.Response.Response' with
-- @usage = Nothing@ and @cost = Nothing@: the @claude@ CLI runs under a flat
-- subscription, so per-token billing does not apply.
module Baikai.Provider.Claude.Cli
  ( ClaudeCli
  , ClaudeCliConfig (..)
  , defaultClaudeCliConfig
  , claudeCli
  ) where

import Baikai.Error (BaikaiError (..))
import Baikai.Model qualified as Model
import Baikai.Provider (Provider (..))
import Baikai.Provider.Cli.Internal qualified as Internal
import Baikai.Request qualified as Req
import Baikai.Response qualified as Resp
import Control.Exception (throwIO)
import Control.Lens ((^.))
import Control.Monad.IO.Class (MonadIO, liftIO)
import Cradle
  ( ExitCode (..)
  , StderrRaw (..)
  , StdoutRaw (..)
  , addArgs
  , cmd
  , run
  , setNoStdin
  , setWorkingDir
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
--
-- 'executable' defaults to the bare string @"claude"@ so the OS resolves the
-- binary via @PATH@; override it for non-standard layouts. 'extraArgs' are
-- appended verbatim after the flags that this module sets internally, before
-- the rendered prompt. 'workingDir' is forwarded to the subprocess.
data ClaudeCliConfig = ClaudeCliConfig
  { executable :: !FilePath
  , extraArgs :: !(Vector Text)
  , workingDir :: !(Maybe FilePath)
  }
  deriving stock (Eq, Show, Generic)

defaultClaudeCliConfig :: ClaudeCliConfig
defaultClaudeCliConfig =
  ClaudeCliConfig
    { executable = "claude"
    , extraArgs = mempty
    , workingDir = Nothing
    }

-- | A configured Claude CLI provider. Holding a value of this type does not
-- spawn any processes; the subprocess is only spawned on 'runRequest'.
newtype ClaudeCli = ClaudeCli {config :: ClaudeCliConfig}
  deriving stock (Eq, Show, Generic)

claudeCli :: MonadIO m => ClaudeCliConfig -> m ClaudeCli
claudeCli = pure . ClaudeCli

-- | The shape of @claude -p --output-format json@ stdout. Only @result@ and
-- @is_error@ are load-bearing; the other fields are decoded opportunistically.
data ClaudeCliResult = ClaudeCliResult
  { result :: !Text
  , is_error :: !Bool
  , session_id :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

systemPromptArgs :: Req.Request -> [String]
systemPromptArgs req = case req ^. #systemPrompt of
  Nothing -> []
  Just sp -> ["--system-prompt", Text.unpack sp]

-- | Emit @--model M@ unless 'Req.Request.model' is empty, in which case the
-- CLI's built-in default is used. Empty is the sentinel because the unified
-- 'Baikai.Model.Model' newtype wraps 'Text' and a blank value is the
-- least-surprising "don't override" signal for CLI providers.
modelArgs :: Req.Request -> [String]
modelArgs req = case Text.strip (Model.unModel (req ^. #model)) of
  "" -> []
  m -> ["--model", Text.unpack m]

-- | Find and decode the @{"type":"result", ...}@ event in @claude -p
-- --output-format json@ stdout.
--
-- The current CLI (@2.x@) emits a JSON array of typed events; the terminal
-- one is @"type":"result"@. Older builds emitted a single bare object with
-- the same fields. We accept both: if stdout is an array we walk it for the
-- result event, otherwise we decode the top-level object directly.
decodeResult :: ByteString -> IO ClaudeCliResult
decodeResult bs = case eitherDecodeStrict bs of
  Left err -> throwIO (DecodeError (Text.pack err))
  Right (Aeson.Array events) -> case findResultEvent events of
    Nothing -> throwIO (DecodeError "claude -p: no result event in stdout array")
    Just ev -> case parseEither parseJSON ev of
      Left err -> throwIO (DecodeError (Text.pack err))
      Right r -> pure r
  Right v@(Aeson.Object _) -> case parseEither parseJSON v of
    Left err -> throwIO (DecodeError (Text.pack err))
    Right r -> pure r
  Right _ -> throwIO (DecodeError "claude -p: expected JSON object or array")

findResultEvent :: Vector Value -> Maybe Value
findResultEvent = Vector.find isResult
  where
    isResult (Aeson.Object o) = case KeyMap.lookup "type" o of
      Just (Aeson.String "result") -> True
      _ -> False
    isResult _ = False

instance Provider ClaudeCli where
  providerName _ = "anthropic.claude.cli"
  runRequest (ClaudeCli cfg) req = liftIO $ do
    let prompt = Internal.renderPrompt req
        args =
          ["-p"]
            <> modelArgs req
            <> ["--output-format", "json", "--no-session-persistence"]
            <> systemPromptArgs req
            <> fmap Text.unpack (Vector.toList (cfg ^. #extraArgs))
            <> [Text.unpack prompt]
    start <- getCurrentTime
    (exitCode, StdoutRaw out, StderrRaw err) <-
      run $
        cmd (cfg ^. #executable)
          & addArgs args
          & setNoStdin
          & Internal.maybeApply (cfg ^. #workingDir) setWorkingDir
    end <- getCurrentTime
    case exitCode of
      ExitFailure n -> throwIO (ProcessError n (Internal.decodeUtf8Lenient err))
      ExitSuccess -> do
        r <- decodeResult out
        if is_error r
          then throwIO (ProviderError (result r))
          else pure (mkResponse req start end (result r))

mkResponse :: Req.Request -> UTCTime -> UTCTime -> Text -> Resp.Response
mkResponse req start end body =
  Resp.Response
    { Resp.content = body
    , Resp.model = req ^. #model
    , Resp.usage = Nothing
    , Resp.cost = Nothing
    , Resp.provider = "anthropic.claude.cli"
    , Resp.latencyMs = millisBetween start end
    }

millisBetween :: UTCTime -> UTCTime -> Integer
millisBetween a b = round (realToFrac (diffUTCTime b a) * (1000 :: Double))
